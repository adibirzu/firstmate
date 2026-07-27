#!/usr/bin/env bash
# Tests the per-surface quota view + model->surface map + failover selector + authed
# override hook. Hermetic: a temp FM_HOME supplies a controlled model map + a stub
# `cline` quota-source, and `quota-axi` is stubbed on PATH, so the LOGIC is asserted
# (not live CLI state / real numbers): grok drained (2%), cursor healthy (80%) -> a
# grok task fails over to cursor.
set -uo pipefail
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

HOMEDIR=$(mktemp -d)
mkdir -p "$HOMEDIR/config" "$HOMEDIR/bin/quota-sources"
cp "$REAL/config/model-surfaces.json" "$HOMEDIR/config/"
# controlled cline source: configured + blind by default; honors config/quota-overrides.json
cat > "$HOMEDIR/bin/quota-sources/cline.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
ov="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config/quota-overrides.json"
hr=null
if command -v jq >/dev/null 2>&1 && [ -f "$ov" ]; then
  cmd=$(jq -r '.cline // ""' "$ov" 2>/dev/null)
  [ -n "$cmd" ] && { o=$(bash -c "$cmd" 2>/dev/null | tr -dc '0-9'); [ -n "$o" ] && hr=$o; }
fi
printf '{"surface":"cline","status":"configured","headroom":%s,"unit":"credits","models":["kimi3"],"note":"test"}\n' "$hr"
EOF
chmod +x "$HOMEDIR/bin/quota-sources/cline.sh"

STUB=$(mktemp -d)
cat > "$STUB/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[
 {"provider":"grok","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":2}]},
 {"provider":"cursor","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":80}]},
 {"provider":"claude","source":"oauth","state":{"status":"fresh"},"windows":[{"percentRemaining":90}]},
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

[ "$(Q pick grok)"   = cursor ] && ok "pick grok fails over to cursor when grok drained" || no "pick grok -> $(Q pick grok)"
[ "$(Q pick kimi)"   = cline  ] && ok "pick kimi -> cline (kimi3 via cline gateway)"      || no "pick kimi -> $(Q pick kimi)"
[ "$(Q pick open)"   = cline  ] && ok "pick open -> cline"                                 || no "pick open -> $(Q pick open)"
[ "$(Q pick claude)" = claude ] && ok "pick claude -> claude (has headroom)"               || no "pick claude -> $(Q pick claude)"
b=$(Q pick bogus); printf '%s' "$b" | grep -qi unknown && ok "pick unknown family is flagged" || no "pick bogus not flagged (got: $b)"
Q quota  | grep -E '^cline'  | grep -q custom && ok "quota view includes cline (custom source)" || no "cline missing from quota view"
Q models | grep -E '^grok'   | grep -q cursor && ok "models view: grok reachable via cursor"    || no "grok->cursor missing in models view"
printf '{"cline":"echo 55"}\n' > "$HOMEDIR/config/quota-overrides.json"
Q quota | grep -E '^cline' | grep -q '55%' && ok "authed override: cline headroom reads 55% from configured reader" || no "override not applied ($(Q quota | grep -E '^cline'))"

rm -rf "$STUB" "$FLEET" "$HOMEDIR"
echo "-----"
[ "$fail" -eq 0 ] && echo "ALL PASS ($pass)" || { echo "$fail FAILED"; exit 1; }
