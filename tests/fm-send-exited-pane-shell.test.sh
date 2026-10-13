#!/usr/bin/env bash
# tests/fm-send-exited-pane-shell.test.sh - real-process regression for the
# exited-pane shell-continuation defect.
#
# The incident this pins: an agent had already exited, leaving a bare shell in a
# `quote>`/heredoc continuation. A steer typed into that pane vanished into the
# shell input instead of reaching a worker, and the relaunch that followed typed
# its launch command into the same continuation, so the task appeared wedged and
# the relaunch did nothing.
#
# Both halves run REAL processes in a REAL tmux server on a private socket
# (`-L`), with a REAL interactive shell and a REAL "agent" process (a sleep
# symlink named `claude`), and assert only through the executable interfaces
# (bin/fm-send.sh, bin/fm-control.sh) and the pane they act on:
#   1. bin/fm-send.sh REFUSES to type a typed-plane steer into the bare shell,
#      with a clear diagnostic, and the pane is untouched (the token never
#      appears in the continuation).
#   2. bin/fm-control.sh relaunch clears that same continuation first, so the
#      launch command reaches a fresh agent and the replacement comes up alive.
#   3. The reset primitive itself (fm_backend_reset_shell) clears every input
#      shape an exited agent can leave behind - heredoc, `quote>`, `dquote>`,
#      a for-loop continuation, and a half-typed line - and proves the shell
#      executes again by moving its cwd. This is the tmux counterpart of the
#      proven herdr reset smoke (tests/fm-control-herdr-smoke.test.sh).
#
# Skips cleanly when tmux is absent; needs no harness and no credentials.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

SEND="$ROOT/bin/fm-send.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-exited-pane-$$"
SESSION="exitedpane"
WINDOW="fm-exitedpane"
ID="exitedpane"
LAB=

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "$LAB" ] && rm -rf "$LAB"
  fm_test_cleanup
}
trap cleanup_all EXIT

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-exited-pane.XXXXXX")
LAB=$(cd "$LAB" && pwd)
mkdir -p "$LAB/shim" "$LAB/fakebin" "$LAB/home/state" "$LAB/home/data/$ID"

# A `tmux` shim on PATH so every bare `tmux` call reaches the private socket and
# never touches the host's real sessions.
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
# The replacement "agent" is a sleep symlink named claude: the symlink name is
# what the tmux liveness classifier reads as the harness identity.
CLAUDE_BIN="$LAB/fakebin/claude"
ln -s "$SLEEP_BIN" "$CLAUDE_BIN"
PATH="$LAB/shim:$LAB/fakebin:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

TARGET="$SESSION:$WINDOW"

wait_for_capture_text() {  # <text> [samples]
  local text=$1 samples=${2:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -200 2>/dev/null || true
}

# --- bring up a real shell and prove it ready --------------------------------

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "could not create the private tmux session"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WINDOW" \
  || fail "could not create the task window"

SHELL_READY=0
for _ in $(seq 1 100); do
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-c
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "printf 'fm-shell-%s\\n' ready"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
  if wait_for_capture_text "fm-shell-ready" 10; then
    SHELL_READY=1
    break
  fi
done
[ "$SHELL_READY" = 1 ] || fail "the interactive shell never became ready"

# Leave the shell mid-continuation: `cat <<'FMEOF'` accepts input until the
# delimiter line, so any later typed line is swallowed into the heredoc body
# instead of executing.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" "cat <<'FMEOF'" Enter
wait_for_capture_text "FMEOF" 20 || fail "the heredoc opener never rendered"

agent=$(fm_backend_agent_state tmux "$TARGET")
[ "$agent" = dead ] \
  || fail "a bare shell in a continuation should classify dead, got '$agent'"

# --- a real worktree and task record for the relaunch ------------------------

PROJ="$LAB/proj"
WT="$LAB/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b "$ID" "$WT"

{
  echo "window=$TARGET"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=direct-PR"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
} > "$LAB/home/state/$ID.meta"
printf '# Task\n\nregression fixture\n' > "$LAB/home/data/$ID/brief.md"

# --- 1. fm-send refuses to type into the exited pane -------------------------

TOKEN="FMSTEERTOKEN-$RANDOM"
out=$(FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$LAB/home" FM_SEND_SETTLE=0 \
  "$SEND" "$ID" "/$TOKEN" 2>&1)
rc=$?
expect_code 1 "$rc" "fm-send must refuse to type into an exited pane"$'\n'"$out"
if capture | grep -qF "$TOKEN"; then
  fail "the steer token reached the pane and disappeared into the shell continuation"
fi
case "$out" in
  *"no agent is running"*) : ;;
  *) fail "the refusal should name the absent agent, got:"$'\n'"$out" ;;
esac
capture | grep -qF "FMEOF" \
  || fail "the pane should still be in its continuation after the refused steer"
pass "fm-send: a typed steer is refused, not swallowed, by an exited pane in a shell continuation"

# --- 2. relaunch resets the shell and reaches the new agent ------------------

# A test-local launch owner: the real launch is a build+send sequence, so this
# double performs the same two observable steps fm-spawn does against the real
# pane - `cd` into the recorded worktree, then start the harness - and starts a
# real process that the real agent-state classifier can prove alive.
mkdir -p "$LAB/bin"
for entry in "$ROOT"/bin/*; do
  ln -s "$entry" "$LAB/bin/${entry##*/}"
done
rm -f "$LAB/bin/fm-spawn.sh"
cat > "$LAB/bin/fm-spawn.sh" <<SH
#!/usr/bin/env bash
set -eu
id=\$1
meta="\${FM_HOME:?}/state/\$id.meta"
target=\$(sed -n 's/^window=//p' "\$meta")
wt=\$(sed -n 's/^worktree=//p' "\$meta")
. "$LAB/bin/fm-backend.sh"
fm_backend_source tmux
fm_backend_tmux_send_text_line "\$target" "cd \$wt"
fm_backend_tmux_send_text_line "\$target" "$CLAUDE_BIN 300"
exit 0
SH
chmod +x "$LAB/bin/fm-spawn.sh"

out=$(FM_HOME="$LAB/home" PATH="$LAB/shim:$LAB/fakebin:$PATH" \
  FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=2 FM_CONTROL_LAUNCH_WAIT=15 \
  "$LAB/bin/fm-control.sh" "$ID" relaunch --note "regression: continue after reset" 2>&1)
rc=$?
expect_code 0 "$rc" "relaunch should reset the continuation and launch the replacement"$'\n'"$out"
case "$out" in
  *"relaunched $ID"*) : ;;
  *) fail "relaunch should report the completed transition, got:"$'\n'"$out" ;;
esac
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = alive ] \
  || fail "the replacement agent should be alive after relaunch, got '$state'"$'\n'"$(capture)"
pass "fm-control relaunch: the shell reset clears the continuation and the launch reaches a new live agent"

pass "fm-send/fm-control: exited-pane shell continuations can no longer swallow a steer or a relaunch"

# --- 3. the reset primitive clears every inherited input shape ---------------
#
# A relaunch whose reset cannot clear the inherited input will type its launch
# command straight into that construct. This drives a REAL tmux pane through a
# heredoc, a `quote>`, a `dquote>`, a for-loop continuation, and a half-typed
# line, and asserts fm_backend_reset_shell clears each one and PROVES the shell
# executes commands again by moving its cwd to the reset directory - the same
# guarantee the herdr smoke proves for herdr.

RESET_WINDOW="fm-resetshapes"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$RESET_WINDOW" \
  || fail "could not create the reset-shapes window"
RESET_TARGET="$SESSION:$RESET_WINDOW"

reset_capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$RESET_TARGET" -S -200 2>/dev/null || true
}
reset_ready=0
for _ in $(seq 1 100); do
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$RESET_TARGET" C-c
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$RESET_TARGET" -l "printf 'fm-reset-%s\\n' ready"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$RESET_TARGET" Enter
  case "$(reset_capture)" in *fm-reset-ready*) reset_ready=1; break ;; esac
  sleep 0.1
done
[ "$reset_ready" = 1 ] || fail "the reset-probe shell never became ready"

# reset_shape <label> <typing> <submit 0|1>: leave the pane holding that input
# shape, then reset it and assert the cwd proof moved to a fresh reset dir. Each
# shape uses its own dir, so a swallowed `cd` can never coincidentally match.
reset_shape() {
  local label=$1 typing=$2 submit=$3 dir expected raw observed
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$RESET_TARGET" -l "$typing"
  [ "$submit" = 1 ] \
    && "$REAL_TMUX" -L "$SOCKET" send-keys -t "$RESET_TARGET" Enter
  sleep 0.3
  dir="$LAB/reset-$label"
  mkdir -p "$dir"
  fm_backend_reset_shell tmux "$RESET_TARGET" "$dir" \
    || fail "the tmux reset did not clear the '$label' input shape"$'\n'"$(reset_capture)"
  expected=$(cd "$dir" && pwd -P)
  raw=$(fm_backend_tmux_current_path "$RESET_TARGET" 2>/dev/null || true)
  observed=$(cd "$raw" 2>/dev/null && pwd -P) || observed=$raw
  [ "$observed" = "$expected" ] \
    || fail "the '$label' input shape swallowed the reset's cd (cwd '$observed', expected '$expected')"
}
reset_shape heredoc "cat <<'FMEOF'" 1
reset_shape single-quote "echo 'unterminated" 1
reset_shape double-quote 'echo "unterminated' 1
reset_shape for-loop "for x in a b; do" 1
reset_shape half-typed "echo half-typed-line" 0
pass "fm_backend_reset_shell: heredoc, quote>, dquote>, for-loop, and half-typed input are all cleared and proven on real tmux"
