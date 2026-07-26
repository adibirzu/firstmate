#!/usr/bin/env bash
# Comprehensive federation test. Run from ~/kun-agent-workspace:
#   bash tests/federation/test_fleet.sh
# Exercises: init, atomic no-overlap claim race, TTL reap, scope routing,
# cross-operator handoff, view/status, and the cross-uid safety guard.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
FLEET_CLI="bin/fm-fleet.sh"
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

# ---- 1. init ----
D=$(mktemp -d); export FM_FLEET_DIR="$D/fleet"
"$FLEET_CLI" init >/dev/null
allok=1
for f in operators.md projects.md backlog.md events.log locks; do
  [ -e "$FM_FLEET_DIR/$f" ] || { allok=0; echo "  missing $f"; }
done
grep -q '## Queued' "$FM_FLEET_DIR/backlog.md" && [ "$allok" = 1 ] && ok "init creates KB" || bad "init"

# ---- 2. atomic claim race (the crux) ----
"$FLEET_CLI" queue FL-1 backend "race item" >/dev/null
( "$FLEET_CLI" claim FL-1 adi   >/dev/null 2>&1; echo $? >"$D/a.rc" ) &
( "$FLEET_CLI" claim FL-1 royce >/dev/null 2>&1; echo $? >"$D/b.rc" ) &
wait
wins=$(( $(cat "$D/a.rc")==0 ? 1 : 0 ))
wins=$(( wins + ($(cat "$D/b.rc")==0 ? 1 : 0) ))
claims=$(grep -c 'claimed-by:' "$FM_FLEET_DIR/backlog.md")
{ [ "$wins" -eq 1 ] && [ "$claims" -eq 1 ]; } && ok "atomic claim: exactly one winner, one record" || bad "atomic claim (winners=$wins claims=$claims)"

# ---- 3. TTL reap ----
D2=$(mktemp -d); export FM_FLEET_DIR="$D2/fleet"
"$FLEET_CLI" init >/dev/null
"$FLEET_CLI" queue FL-9 backend demo >/dev/null; "$FLEET_CLI" claim FL-9 royce >/dev/null
# stale claimed -> should requeue
sed -i 's/@[0-9TZ:-]\{1,\}/@2000-01-01T00:00:00Z/' "$FM_FLEET_DIR/backlog.md"
"$FLEET_CLI" reap 3600 >/dev/null
grep -q '\[id:FL-9\].*status:queued' "$FM_FLEET_DIR/backlog.md" && ok "reap requeues stale claim" || bad "reap requeue"
# in-flight with old ts must NOT be requeued
"$FLEET_CLI" queue FL-10 backend demo2 >/dev/null; "$FLEET_CLI" claim FL-10 royce >/dev/null
sed -i 's/\(FL-10.*\)status:claimed/\1status:in-flight/' "$FM_FLEET_DIR/backlog.md"
sed -i 's/@[0-9TZ:-]\{1,\}/@2000-01-01T00:00:00Z/' "$FM_FLEET_DIR/backlog.md"
"$FLEET_CLI" reap 3600 >/dev/null
grep -q '\[id:FL-10\].*status:in-flight' "$FM_FLEET_DIR/backlog.md" && ok "reap leaves in-flight alone" || bad "reap in-flight"

# ---- 4. scope routing ----
D3=$(mktemp -d); export FM_FLEET_DIR="$D3/fleet"
"$FLEET_CLI" init >/dev/null
cat >> "$FM_FLEET_DIR/operators.md" <<'OPS'
| adi | backend,infra,deploy | /home/adi/kun-agent-workspace | claude:default | online |
| royce | web,mobile,product | /home/royce/kun-agent-workspace | claude:default | online |
| barf-ai | overflow | /home/barf-ai/kun-agent-workspace | claude:default | online |
OPS
r_back=$("$FLEET_CLI" route backend); r_web=$("$FLEET_CLI" route web)
{ [ "$r_back" = adi ] && [ "$r_web" = royce ]; } && ok "route: backend->adi, web->royce" || bad "route primary (got '$r_back'/'$r_web')"
# adi offline -> backend falls to overflow (barf-ai)
sed -i 's/| adi \(.*\)| online |/| adi \1| offline |/' "$FM_FLEET_DIR/operators.md"
r_off=$("$FLEET_CLI" route backend)
[ "$r_off" = barf-ai ] && ok "route: offline owner -> overflow" || bad "route overflow (got '$r_off')"

# ---- 5. handoff ----
D4=$(mktemp -d); export FM_FLEET_DIR="$D4/fleet"
"$FLEET_CLI" init >/dev/null
"$FLEET_CLI" queue FL-2 web "handoff item" >/dev/null
"$FLEET_CLI" claim FL-2 adi >/dev/null
"$FLEET_CLI" handoff FL-2 royce >/dev/null
grep -q '\[id:FL-2\].*claimed-by:royce@' "$FM_FLEET_DIR/backlog.md" \
  && grep -q $'\thandoff\tFL-2' "$FM_FLEET_DIR/events.log" \
  && ok "handoff reassigns + logs event" || bad "handoff"

# ---- 6. view + status ----
vlines=$("$FLEET_CLI" view | grep -c 'FL-2' || true)
[ "$vlines" -ge 1 ] && ok "view renders events" || bad "view"
status_out=$("$FLEET_CLI" status); echo "$status_out" | grep -q 'operator' && ok "status renders header" || bad "status"

# ---- 7. cross-uid safety guard ----
# sourcing the lib and asserting a foreign home is refused
( . bin/fm-fleet-lib.sh; fm_fleet_assert_shared "/home/someoneelse/kun-agent-workspace" ) 2>/dev/null \
  && bad "safety: foreign home NOT refused" || ok "safety: foreign home refused"
( . bin/fm-fleet-lib.sh; fm_fleet_assert_shared "/opt/agents/fleet" ) 2>/dev/null \
  && ok "safety: /opt shared dir allowed" || bad "safety: /opt wrongly refused"

echo "-----"
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
