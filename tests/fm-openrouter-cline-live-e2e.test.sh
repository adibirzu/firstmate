#!/usr/bin/env bash
# Live opt-in drift guard for the OpenRouter-via-Cline adapter.
#
# Proves a real completion round-trips through firstmate's openrouter-via-cline
# launch path when credentials are present. Requires:
#   - FM_OPENROUTER_CLINE_LIVE=1 (env gate)
#   - real `cline` binary installed (verified on 3.0.57)
#   - real `tmux` binary
#   - OPENROUTER_API_KEY_TOKENS or OPENROUTER_API_KEY in the environment
#
# Refresh docs/verification/cline-adapter.md from this guard after every cline
# upgrade or when the openrouter path behavior changes.
set -u

CLINE_BIN=$(command -v cline 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-openrouter-cline-$$"
SESSION=or-cline
TARGET="$SESSION:or"
VERSION=
MODEL_USED=

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - cline %s: %s\n' "${VERSION:-unknown-version}" "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - cline %s: %s\n' "$VERSION" "$1"
}

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true
}

wait_for_pane() {
  local budget=$1 pattern=$2 i=0
  while [ "$i" -lt "$((budget * 5))" ]; do
    capture | grep -qE "$pattern" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

if [ "${FM_OPENROUTER_CLINE_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_OPENROUTER_CLINE_LIVE=1 to run the real openrouter-via-cline drift guard"
  exit 0
fi

[ -x "$CLINE_BIN" ] || fail "FM_OPENROUTER_CLINE_LIVE=1 but no real cline executable is installed on PATH"
[ -x "$REAL_TMUX" ] || fail "FM_OPENROUTER_CLINE_LIVE=1 but tmux is not installed"
command -v jq >/dev/null 2>&1 || fail "jq is required to read cline's own session records"

VERSION=$("$CLINE_BIN" --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || fail "the installed cline did not report a version"

set -a; source "$HOME/.claude/.env" >/dev/null 2>&1; set +a
CANDIDATE_KEY=${OPENROUTER_API_KEY_TOKENS:-}
[ -n "$CANDIDATE_KEY" ] || CANDIDATE_KEY=${OPENROUTER_API_KEY:-}
[ -n "$CANDIDATE_KEY" ] || fail "FM_OPENROUTER_CLINE_LIVE=1 but neither OPENROUTER_API_KEY_TOKENS nor OPENROUTER_API_KEY is set in the environment"

CANDIDATE_MODELS=(
  "openai/gpt-oss-20b"
  "openai/gpt-oss-120b"
  "google/gemma-3-12b-it"
)

probe_model() {
  local model=$1
  code=$(printf '{"model":"%s","messages":[{"role":"user","content":"say ok"}],"max_tokens":5}' "$model" | \
    curl -s -o /tmp/fm-or-probe.json -w '%{http_code}' -m 30 \
      https://openrouter.ai/api/v1/chat/completions \
      -H "Authorization: Bearer $CANDIDATE_KEY" \
      -H "Content-Type: application/json" --data-binary @- 2>/dev/null)
  if [ "$code" = "200" ]; then
    echo "$model"
    return 0
  fi
  return 1
}

MODEL_USED=
for m in "${CANDIDATE_MODELS[@]}"; do
  if MODEL_USED=$(probe_model "$m"); then
    break
  fi
done
[ -n "$MODEL_USED" ] || fail "no candidate model answered (tried: ${CANDIDATE_MODELS[*]}); check credentials and eligibility"
pass "selected model for live round-trip: $MODEL_USED (date $(date -u +%Y-%m-%d))"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-openrouter-cline.XXXXXX") || fail "could not create the isolated cline lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace" "$LAB/state"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated cline workspace"

cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "\$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
PATH="$LAB/bin:$PATH"
export PATH
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated cline workspace"

printf '{\n  "planActMode": "act"\n}\n' > "$LAB/act.json"

NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
cat > "$LAB/providers.json" <<EOF
{
  "version": 1,
  "lastUsedProvider": "openrouter",
  "modes": {},
  "providers": {
    "openrouter": {
      "settings": {"provider": "openrouter", "model": "$MODEL_USED"},
      "updatedAt": "$NOW",
      "tokenSource": "manual"
    }
  }
}
EOF

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n or -c "$WORKSPACE" -x 220 -y 50 \
  || fail "could not start the isolated tmux server"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "printf 'FM_OPENROUTER_KEY_ARMED\n'; IFS= read -rs OPENROUTER_API_KEY && export OPENROUTER_API_KEY"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.6
for _ in $(seq 1 40); do
  if capture | grep -q 'FM_OPENROUTER_KEY_ARMED'; then
    break
  fi
  sleep 0.25
done
sleep 0.3
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "$CANDIDATE_KEY"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.2

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "CLINE_GLOBAL_SETTINGS_PATH='$LAB/act.json' CLINE_PROVIDER_SETTINGS_PATH='$LAB/providers.json' cline -i --tui --auto-approve true -P openrouter -k \"\$OPENROUTER_API_KEY\" -m $MODEL_USED 'Reply with exactly: ok'"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter

wait_for_pane 30 'esc to cancel' || fail "cline did not start the turn within budget; pane may be stuck on onboarding"

for i in $(seq 1 180); do
  if ! capture | grep -q 'esc to cancel'; then
    break
  fi
  sleep 1
done
if capture | grep -q 'esc to cancel'; then
  fail "cline turn did not complete within 180s (spinner still present)"
fi

sleep 2
SESSION_DIR=$(ls -t ~/.cline/data/sessions/ | head -1)
[ -n "$SESSION_DIR" ] || fail "no cline session recorded"
FULL_SESSION_PATH="$HOME/.cline/data/sessions/$SESSION_DIR"
SESSION_JSON="$FULL_SESSION_PATH/$SESSION_DIR.json"
MESSAGES_JSON="$FULL_SESSION_PATH/$SESSION_DIR.messages.json"

[ -f "$SESSION_JSON" ] || fail "session JSON not found at $SESSION_JSON"
STATUS=$(LC_ALL=C jq -r '.status // empty' "$SESSION_JSON")
[ "$STATUS" = idle ] || fail "session record status is '$STATUS', expected idle (completed)"
PROVIDER=$(LC_ALL=C jq -r '.provider // empty' "$SESSION_JSON")
[ "$PROVIDER" = openrouter ] || fail "session record provider is '$PROVIDER', expected openrouter"
MODEL_REC=$(LC_ALL=C jq -r '.model // empty' "$SESSION_JSON")
[ "$MODEL_REC" = "$MODEL_USED" ] || fail "session record model is '$MODEL_REC', expected $MODEL_USED"

if [ ! -f "$MESSAGES_JSON" ]; then
  fail "messages JSON not found at $MESSAGES_JSON"
fi
ASSISTANT_REPLY=$(LC_ALL=C jq -r '.messages[]? | select(.role=="assistant") | .content[]? | select(.type=="text") | .text' "$MESSAGES_JSON" 2>/dev/null | head -1)
[ -n "$ASSISTANT_REPLY" ] || fail "no assistant reply found in session messages"

ASSISTANT_REPLY_TRIMMED=$(printf '%s' "$ASSISTANT_REPLY" | tr -d '[:space:]')
[ "$ASSISTANT_REPLY_TRIMMED" = "ok" ] || fail "assistant reply was '$ASSISTANT_REPLY', expected 'ok'"

pass "openrouter-via-cline completed a real round-trip: provider=$PROVIDER model=$MODEL_REC reply='$ASSISTANT_REPLY'"

if grep -q "$CANDIDATE_KEY" "$LAB/providers.json" 2>/dev/null; then
  fail "the redirected providers file was modified and contains key material (clobbered no-secret design)"
fi
pass "redirected providers file remains no-secret (no key material persisted)"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-c
sleep 2
case "$("$REAL_TMUX" -L "$SOCKET" display -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)" in
  node) fail "cline exit key did not return pane to shell (still running node)" ;;
  *) pass "cline exit key (Ctrl+C) returned the pane to its shell" ;;
esac

cleanup
trap - EXIT
echo "ALL PASS: fm-openrouter-cline-live-e2e (cline $VERSION, model $MODEL_USED, date $(date -u +%Y-%m-%d))"
