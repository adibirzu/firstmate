#!/usr/bin/env bash
# --account axis test (Phase 4, Task 11). Run from ~/kun-agent-workspace:
#   bash tests/federation/test_spawn_account.sh
# Exercises: launch-command composition for each config-dir isolation method,
# model/effort folding, api-key refusal (no secret on argv), unknown-account
# refusal, and the wrapper handing the composed command to fm-spawn (stubbed).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
FM_HOME="$(pwd)"; export FM_HOME
# shellcheck source=bin/fm-account-env.sh disable=SC1091
. bin/fm-account-env.sh
fails=0
ok(){ echo "PASS: $1"; }
bad(){ echo "FAIL: $1"; fails=$((fails+1)); }

TMP=$(mktemp -d); export FM_ACCOUNTS_FILE="$TMP/accounts.json"
CD="$TMP/cd"; mkdir -p "$CD"
echo "sk-fake-not-a-real-key" > "$TMP/grok.key"

cat > "$FM_ACCOUNTS_FILE" <<JSON
{
  "claude-alt": {"provider":"anthropic","harness":"claude","isolation":"config-dir-env","env":"CLAUDE_CONFIG_DIR","config_dir":"$CD","scopes":["backend"]},
  "codex-x":    {"provider":"openai","harness":"codex","isolation":"config-dir-env","env":"CODEX_HOME","config_dir":"$CD","scopes":["backend"]},
  "cline-x":    {"provider":"anthropic","harness":"cline","isolation":"config-dir-flag","flag":"--config","config_dir":"$CD","scopes":["web"]},
  "grok-x":     {"provider":"xai","harness":"grok","isolation":"api-key-env","env":"GROK_API_KEY","key_file":"$TMP/grok.key","scopes":["research"]}
}
JSON

# 1. config-dir-env compose (env prefix, harness detected after it)
c=$(fm_account_compose_launch claude-alt)
[ "$c" = "CLAUDE_CONFIG_DIR=$CD claude" ] && ok "compose config-dir-env (claude)" || bad "compose claude (got '$c')"

# 2. model+effort folding
c=$(fm_account_compose_launch claude-alt opus high)
[ "$c" = "CLAUDE_CONFIG_DIR=$CD claude --model opus --effort high" ] && ok "compose folds model+effort" || bad "compose model/effort (got '$c')"

# 3. codex uses CODEX_HOME
c=$(fm_account_compose_launch codex-x)
[ "$c" = "CODEX_HOME=$CD codex" ] && ok "compose codex (CODEX_HOME)" || bad "compose codex (got '$c')"

# 4. config-dir-flag compose (flag on argv, no env)
c=$(fm_account_compose_launch cline-x)
[ "$c" = "cline --config $CD" ] && ok "compose config-dir-flag (cline)" || bad "compose cline (got '$c')"

# 5. api-key refusal (rc==2, nothing on stdout)
out=$(fm_account_compose_launch grok-x 2>/dev/null); rc=$?
{ [ "$rc" -eq 2 ] && [ -z "$out" ]; } && ok "api-key compose refused (no key on argv)" || bad "api-key refusal (rc=$rc out='$out')"

# 6. unknown account refused
fm_account_compose_launch nope >/dev/null 2>&1 && bad "unknown account composed" || ok "unknown account refused"

# 7. wrapper hands composed command to fm-spawn (stub captures argv)
STUB="$TMP/spawn-stub.sh"
cat > "$STUB" <<'S'
#!/usr/bin/env bash
: > "$FM_STUB_OUT"
for a in "$@"; do printf '%s\n' "$a" >> "$FM_STUB_OUT"; done
S
chmod +x "$STUB"
FM_STUB_OUT="$TMP/out.txt" FM_SPAWN_BIN="$STUB" \
  bash bin/fm-spawn-acct.sh T-1 /proj --account claude-alt --model opus >/dev/null 2>&1
n=$(wc -l < "$TMP/out.txt")
a1=$(sed -n '1p' "$TMP/out.txt"); a2=$(sed -n '2p' "$TMP/out.txt"); a3=$(sed -n '3p' "$TMP/out.txt")
{ [ "$n" -eq 3 ] && [ "$a1" = "T-1" ] && [ "$a2" = "/proj" ] && [ "$a3" = "CLAUDE_CONFIG_DIR=$CD claude --model opus" ]; } \
  && ok "wrapper passes (id, dir, composed-launch) to fm-spawn" || bad "wrapper passthrough (n=$n a1='$a1' a2='$a2' a3='$a3')"

# 8. wrapper refuses api-key account (fail-closed; stub NOT invoked)
: > "$TMP/out2.txt"
FM_STUB_OUT="$TMP/out2.txt" FM_SPAWN_BIN="$STUB" \
  bash bin/fm-spawn-acct.sh T-2 /proj --account grok-x >/dev/null 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && [ ! -s "$TMP/out2.txt" ]; } && ok "wrapper fail-closed on api-key account" || bad "wrapper api-key (rc=$rc, stub-called=$( [ -s "$TMP/out2.txt" ] && echo yes || echo no ))"

# 9. apply_env exports in the CALLER's shell (regression: must NOT be a subshell)
( unset CLAUDE_CONFIG_DIR; fm_account_apply_env claude-alt && [ "$CLAUDE_CONFIG_DIR" = "$CD" ] ) \
  && ok "apply_env exports config-dir-env in caller shell" || bad "apply_env export (subshell regression)"

# 10. config-dir-flag sets FM_ACCT_ARGV_SUFFIX (not stdout)
( fm_account_apply_env cline-x && [ "$FM_ACCT_ARGV_SUFFIX" = "--config $CD" ] ) \
  && ok "apply_env sets argv suffix for flag method" || bad "apply_env suffix"

rm -rf "$TMP"
echo "-----"; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
