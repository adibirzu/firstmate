#!/usr/bin/env bash
# Tests the per-surface quota view + model->surface map + failover selector + authed
# override hook. Hermetic: a temp FM_HOME supplies a controlled model map + a stub
# `cursor` quota-source (honoring config/quota-overrides.json), and `quota-axi` is
# stubbed on PATH, so the LOGIC is asserted (not live numbers): grok drained (2%),
# cursor healthy (80% via its authed reader) -> a grok task fails over to cursor.
set -uo pipefail
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

HOMEDIR=$(mktemp -d)
mkdir -p "$HOMEDIR/config" "$HOMEDIR/bin/quota-sources"
cp "$REAL/config/model-surfaces.json" "$HOMEDIR/config/"
# stub cursor source: headroom comes from the override command (mirrors the real reader)
cat > "$HOMEDIR/bin/quota-sources/cursor.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
ov="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/quota-overrides.json"
hr=null
if command -v jq >/dev/null 2>&1 && [ -f "$ov" ]; then
  cmd=$(jq -r '.cursor // ""' "$ov" 2>/dev/null)
  [ -n "$cmd" ] && { o=$(bash -c "$cmd" 2>/dev/null | tr -dc '0-9'); [ -n "$o" ] && hr=$o; }
fi
printf '{"surface":"cursor","status":"logged_in","headroom":%s,"unit":"requests","models":["grok"],"note":"test"}\n' "$hr"
EOF
chmod +x "$HOMEDIR/bin/quota-sources/cursor.sh"
# stub copilot source: same override contract. Mirrors the real one, whose reason for
# existing is that quota-axi's native copilot provider only probes the OLD IDE credential
# path (~/.config/github-copilot/apps.json) and so stays auth_required for a CLI login.
cat > "$HOMEDIR/bin/quota-sources/copilot.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
ov="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/quota-overrides.json"
hr=null
if command -v jq >/dev/null 2>&1 && [ -f "$ov" ]; then
  cmd=$(jq -r '.copilot // ""' "$ov" 2>/dev/null)
  [ -n "$cmd" ] && { o=$(bash -c "$cmd" 2>/dev/null | tr -dc '0-9'); [ -n "$o" ] && hr=$o; }
fi
printf '{"surface":"copilot","status":"logged_in","headroom":%s,"unit":"premium interactions","models":["claude","gpt"],"note":"test"}\n' "$hr"
EOF
chmod +x "$HOMEDIR/bin/quota-sources/copilot.sh"

STUB=$(mktemp -d)
cat > "$STUB/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
 {"provider":"grok","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":2}]},
 {"provider":"cursor","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":15}]},
 {"provider":"claude","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":90}]},
 {"provider":"copilot","source":"unavailable","state":{"status":"auth_required"},"windows":[]},
 {"provider":"codex","source":"cli-rpc","state":{"status":"fresh"},"windows":[{"percentRemaining":90}]}
]}
JSON
EOF
chmod +x "$STUB/quota-axi"
export PATH="$STUB:$PATH"
export FM_HOME="$HOMEDIR"
FLEET=$(mktemp -d); export FM_FLEET_DIR="$FLEET"
cd "$REAL"
Q(){ bin/fm-fleet.sh "$@" 2>&1; }

# cursor's authed reader reports 80 -> supersedes quota-axi's 15
printf '{"cursor":"echo 80"}\n' > "$HOMEDIR/config/quota-overrides.json"
[ "$(Q pick grok)"   = cursor ] && ok "pick grok fails over to cursor when grok drained" || no "pick grok -> $(Q pick grok)"
[ "$(Q pick claude)" = claude ] && ok "pick claude -> claude (has headroom)"               || no "pick claude -> $(Q pick claude)"
[ "$(Q pick kimi)"   = kimi   ] && ok "pick kimi -> kimi (only surface; cline unmonitored)" || no "pick kimi -> $(Q pick kimi)"
b=$(Q pick bogus); printf '%s' "$b" | grep -qi unknown && ok "pick unknown family is flagged" || no "pick bogus not flagged (got: $b)"
Q quota  | grep -E '^cursor' | grep -q custom && ok "quota view includes cursor (custom source)" || no "cursor missing from quota view"
Q models | grep -E '^grok'   | grep -q cursor && ok "models view: grok reachable via cursor"    || no "grok->cursor missing in models view"
Q quota  | grep -qE '^cline' && no "cline should be removed from monitoring" || ok "cline is not a monitored surface"
# authed override precedence: cursor reader -> 55 shows as 55%
printf '{"cursor":"echo 55"}\n' > "$HOMEDIR/config/quota-overrides.json"
Q quota | grep -E '^cursor' | grep -q '55%' && ok "authed override: cursor headroom reads 55% from its reader" || no "override not applied ($(Q quota | grep -E '^cursor'))"

# --- copilot surface (GitHub Copilot CLI) -------------------------------------------
# Its custom source must SUPERSEDE quota-axi's native auth_required row (the native probe
# reads the old IDE credential path and can never see a standalone CLI login).
printf '{"cursor":"echo 55","copilot":"echo 88"}\n' > "$HOMEDIR/config/quota-overrides.json"
Q quota | grep -E '^copilot' | grep -q '88%' \
  && ok "copilot custom source supersedes quota-axi auth_required row (88%)" \
  || no "copilot row wrong ($(Q quota | grep -E '^copilot'))"
Q models | grep -E '^claude' | grep -q copilot \
  && ok "models view: claude reachable via copilot" \
  || no "claude->copilot missing in models view"
Q models | grep -E '^gpt' | grep -q copilot \
  && ok "models view: gpt reachable via copilot" \
  || no "gpt->copilot missing in models view"

# Failover INTO copilot: drain claude's native pool, copilot stays healthy.
cat > "$STUB/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
 {"provider":"claude","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":1}]},
 {"provider":"cursor","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":15}]},
 {"provider":"copilot","source":"unavailable","state":{"status":"auth_required"},"windows":[]},
 {"provider":"codex","source":"cli-rpc","state":{"status":"fresh"},"windows":[{"percentRemaining":90}]}
]}
JSON
EOF
chmod +x "$STUB/quota-axi"
[ "$(Q pick claude)" = copilot ] \
  && ok "pick claude fails over to copilot when the claude pool is drained" \
  || no "pick claude -> $(Q pick claude) (expected copilot)"

rm -rf "$STUB" "$FLEET" "$HOMEDIR"
echo "-----"
[ "$fail" -eq 0 ] && echo "ALL PASS ($pass)" || { echo "$fail FAILED"; exit 1; }
