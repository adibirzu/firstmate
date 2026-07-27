#!/usr/bin/env bash
# Operator-lifecycle + token-economy tests (fleet-ops). Run from ~/kun-agent-workspace:
#   bash tests/federation/test_fleet_ops.sh
# Exercises the per-operator lifecycle that makes each user's own firstmate joinable,
# in-sync, and token-cheap:
#   register (self-onboard, upsert, own-home-only), heartbeat (refresh seen+quota),
#   leave (offline), online = status:online AND heartbeat-fresh AND quota>=floor,
#   quota-aware routing (published headroom, no cross-user auth), and fm_fleet_budget_ok.
#
# operators.md row schema (backward-compatible superset of the 5-col form):
#   | <op> | <scopes> | <home> | <accounts> | <status> | <seen-iso> | <quota%|-> |
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
CLI="bin/fm-fleet.sh"
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

# shellcheck source=bin/fm-fleet-lib.sh disable=SC1091
. bin/fm-fleet-lib.sh

now_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
old_iso(){ echo "2000-01-01T00:00:00Z"; }

# 1. register self-onboards a fresh online row that route finds
D=$(mktemp -d); export FM_FLEET_DIR="$D/fleet"; unset FM_FLEET_HEARTBEAT_TTL FM_FLEET_QUOTA_MIN
"$CLI" init >/dev/null
"$CLI" register adi backend,infra "$HOME/kun-agent-workspace" claude-default >/dev/null 2>&1
grep -qE "^\| *adi *\|" "$FM_FLEET_DIR/operators.md" && ok "register writes an operator row" || bad "register writes row"
[ "$("$CLI" route backend)" = adi ] && ok "route finds a freshly-registered operator" || bad "route fresh register (got '$("$CLI" route backend)')"

# 2. register is idempotent (upsert, not duplicate)
"$CLI" register adi backend,infra "$HOME/kun-agent-workspace" claude-default >/dev/null 2>&1
n=$(grep -cE "^\| *adi *\|" "$FM_FLEET_DIR/operators.md")
[ "$n" -eq 1 ] && ok "register is idempotent (one row)" || bad "register duplicated (n=$n)"

# 3. heartbeat refreshes seen; a stale operator routes as offline
"$CLI" register royce web,mobile "$HOME/kun-agent-workspace" claude-default >/dev/null 2>&1
"$CLI" register barf-ai overflow "$HOME/kun-agent-workspace" claude-default >/dev/null 2>&1
# force royce's seen stale (replace the seen column in royce's row with an old ts)
sed -i "/^| royce /s#| [0-9][0-9TZ:-]\{1,\} |#| $(old_iso) |#" "$FM_FLEET_DIR/operators.md"
export FM_FLEET_HEARTBEAT_TTL=90
r=$("$CLI" route web)
[ "$r" = barf-ai ] && ok "route: stale-heartbeat operator treated offline -> overflow" || bad "route stale->overflow (got '$r')"
# heartbeat royce back to fresh -> route returns royce
"$CLI" heartbeat royce >/dev/null 2>&1
r=$("$CLI" route web)
[ "$r" = royce ] && ok "heartbeat refreshes seen -> operator online again" || bad "heartbeat refresh (got '$r')"

# 4. leave marks offline -> route skips to overflow
"$CLI" leave royce >/dev/null 2>&1
r=$("$CLI" route web)
[ "$r" = barf-ai ] && ok "leave -> offline -> overflow" || bad "leave offline (got '$r')"

# 5. quota-aware routing: publish low headroom for the scope owner -> skip to overflow
D2=$(mktemp -d); export FM_FLEET_DIR="$D2/fleet"
"$CLI" init >/dev/null
ts=$(now_iso)
cat >> "$FM_FLEET_DIR/operators.md" <<OPS
| adi | backend | $HOME/kun-agent-workspace | claude-default | online | $ts | 3 |
| barf-ai | overflow | $HOME/kun-agent-workspace | claude-default | online | $ts | 80 |
OPS
export FM_FLEET_QUOTA_MIN=5
r=$("$CLI" route backend)
[ "$r" = barf-ai ] && ok "route: owner below quota floor -> overflow" || bad "route quota floor (got '$r')"
# raise adi's quota -> owner wins again
sed -i "/^| adi /s#| 3 |#| 50 |#" "$FM_FLEET_DIR/operators.md"
r=$("$CLI" route backend)
[ "$r" = adi ] && ok "route: owner above quota floor -> owner" || bad "route quota ok (got '$r')"

# 6. fm_fleet_budget_ok reflects a stubbed quota-axi min headroom vs floor
STUB=$(mktemp -d)
cat > "$STUB/quota-axi" <<'Q'
#!/usr/bin/env bash
echo "$FAKE_QUOTA_JSON"
Q
chmod +x "$STUB/quota-axi"
export FM_FLEET_QUOTA_MIN=5
FAKE_QUOTA_JSON='{"providers":[{"provider":"claude","windows":[{"percentRemaining":40}]}]}' \
  PATH="$STUB:$PATH" fm_fleet_budget_ok && ok "budget_ok: above floor passes" || bad "budget_ok above floor"
FAKE_QUOTA_JSON='{"providers":[{"provider":"claude","windows":[{"percentRemaining":2}]}]}' \
  PATH="$STUB:$PATH" fm_fleet_budget_ok && bad "budget_ok below floor should fail" || ok "budget_ok: below floor fails"

# 7. register refuses a foreign home (cross-uid safety)
D3=$(mktemp -d); export FM_FLEET_DIR="$D3/fleet"; "$CLI" init >/dev/null
"$CLI" register evil backend /home/someoneelse/kun-agent-workspace claude-default >/dev/null 2>&1 \
  && bad "register accepted a foreign home" || ok "register refuses a foreign home"

# 8. fm-fleet-wait.sh (token economy): a fresh claim wakes; nothing else does
D4=$(mktemp -d); export FM_FLEET_DIR="$D4/fleet"; "$CLI" init >/dev/null
"$CLI" register adi backend "$HOME/kun-agent-workspace" claude-default >/dev/null 2>&1
"$CLI" queue W-1 backend "wake item" >/dev/null; "$CLI" claim W-1 adi >/dev/null
out=$(bin/fm-fleet-wait.sh adi --once --no-heartbeat); rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'W-1'; } && ok "wait --once: fresh claim wakes (exit 0 + id)" || bad "wait fresh claim (rc=$rc out='$out')"
bin/fm-fleet-wait.sh royce --once --no-heartbeat >/dev/null 2>&1 && bad "wait woke with no claim" || ok "wait --once: no claim -> exit 1 (LLM stays idle)"
sed -i 's/\(W-1.*\)status:claimed/\1status:in-flight/' "$FM_FLEET_DIR/backlog.md"
bin/fm-fleet-wait.sh adi --once --no-heartbeat >/dev/null 2>&1 && bad "wait woke on in-flight (already started)" || ok "wait --once: in-flight item is not a fresh wake"

# 9. fm-fleet-join.sh: self-onboard writes config/fleet-dir + registers; idempotent.
# HOME is overridden to a temp home so the own-home guard passes for the fixture.
JH=$(mktemp -d)/home; mkdir -p "$JH"; JF=$(mktemp -d)/fleet
FM_FLEET_DIR="$JF" "$CLI" init >/dev/null
out=$(HOME="$JH" FM_HOME="$JH" FM_FLEET_DIR="$JF" bin/fm-fleet-join.sh adi backend claude-default 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cat "$JH/config/fleet-dir" 2>/dev/null)" = "$JF" ] && grep -qE "^\| *adi *\|" "$JF/operators.md"; } \
  && ok "join: writes config/fleet-dir + registers self" || bad "join (rc=$rc)"
HOME="$JH" FM_HOME="$JH" FM_FLEET_DIR="$JF" bin/fm-fleet-join.sh adi backend claude-default >/dev/null 2>&1
n=$(grep -cE "^\| *adi *\|" "$JF/operators.md"); [ "$n" -eq 1 ] && ok "join: idempotent (one row on rejoin)" || bad "join dup (n=$n)"

echo "-----"
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
