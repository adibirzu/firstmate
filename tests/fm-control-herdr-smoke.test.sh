#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real agent is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, so registering and not registering an agent on a plain
# shell pane exercises exactly the classification the control plane gates on.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
cat > "$HOME_DIR/data/hsmoke/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Herdr lifecycle control safely.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
EOF

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"
PROJ_REAL=$(cd "$PROJ" && pwd -P)
WT_REAL=$(cd "$WT" && pwd -P)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

# --- the recovery-grade read, against the real binary ------------------------
#
# The classification that decides whether a task can be recovered at all is read
# out of what herdr actually answers, so a stub can only confirm the assumption
# already written into the stub. Its logic is pinned portably in
# tests/fm-backend-herdr.test.sh; this is the check that notices when the real
# client stops answering the way that logic expects, and it names the version so
# a release change is attributed rather than mysterious.
HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || version_fail "a real, present, agent-free pane reads '$STATE' rather than 'dead'; every relaunch would be refused"

# `status --json` is the second signal, and the only one that answers for a
# session whose operational calls cannot be reached at all. A release that drops
# or renames `.server.running` would silently make every gone endpoint
# unrecoverable again, so it is asserted by name on both a live and an absent
# session.
[ "$(fm_backend_herdr_server_running_state "$SESSION")" = running ] \
  || version_fail "this run's own live lab session does not report .server.running=true through status --json"
[ "$(fm_backend_herdr_server_running_state "fm-lab-never-started-$$")" = stopped ] \
  || version_fail "a session with no server does not report .server.running=false, so authoritative absence can no longer be told from an unreadable read"

# Issue #4091's exact stranding shape: an endpoint recorded in a session whose
# server is not running used to read `unreadable` and block recovery.
[ "$(fm_backend_agent_state herdr "fm-lab-never-started-$$:w1:p2")" = missing ] \
  || version_fail "an endpoint in a session with no running server is not classified as recoverable"

# And the safety direction: an uninterpretable read must never license recovery.
[ "$(fm_backend_agent_state herdr "no-separator-here")" = unreadable ] \
  || version_fail "a malformed endpoint target does not stay unreadable"
pass "real herdr $HERDR_VERSION: a gone session reads recoverable while a live pane and a malformed target do not"

FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
printf -v PROJ_Q '%q' "$PROJ"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the inert test harness on the pane PATH"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd -- $PROJ_Q" \
  || fail "could not move the agent-free pane out of its recorded worktree"
for _ in $(seq 1 20); do
  [ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" != "$PROJ_REAL" ] || break
  sleep 0.1
done
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$PROJ_REAL" ] \
  || fail "the real Herdr pane did not drift out of its recorded worktree"

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a drifted, agent-free Herdr pane should be re-homed and relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$WT_REAL" ] \
  || fail "the relaunched Herdr shell did not end up in its recorded worktree"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the Herdr relaunch replaced its endpoint instead of reusing it"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the Herdr relaunch removed the endpoint it was required to reuse"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint"
# A bare shell in a continuation must be reset before a launch can rely on it.
# An exited agent can leave its shell mid-heredoc/`quote>`, and the launch
# command typed next would be swallowed; the reset clears it and proves the
# shell executes commands by moving its cwd.
RESET_DIR="$SCRATCH/shell-reset"
mkdir -p "$RESET_DIR"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cat <<'FMEOF'" \
  || fail "could not type the heredoc opener into the herdr pane"
sleep 1
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] || fail "a bare herdr shell in a continuation should classify dead, got '$STATE'"
if ! fm_backend_reset_shell herdr "$SESSION:$PANE_ID" "$RESET_DIR"; then
  fail "the herdr shell reset did not clear the pane's continuation"
fi
RESET_EXPECTED=$(cd "$RESET_DIR" && pwd -P)
RESET_OBSERVED=$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)
[ -n "$RESET_OBSERVED" ] \
  && RESET_OBSERVED=$(cd "$RESET_OBSERVED" 2>/dev/null && pwd -P) \
  || RESET_OBSERVED=
[ "$RESET_OBSERVED" = "$RESET_EXPECTED" ] \
  || fail "the herdr shell reset did not move the pane cwd to '$RESET_EXPECTED' (got '$RESET_OBSERVED')"
pass "real herdr: the shell reset clears an inherited continuation and proves the cwd"

# --- the keyboard-protocol half of that reset, against the real binary --------
#
# The incident this pins: `pane send-keys` encodes a named key in whichever
# keyboard protocol the pane's terminal has active, and those flags outlive the
# agent that set them. A pane whose agent pushed the kitty keyboard protocol and
# then exited - exactly the bare shell this reset exists for - keeps them, so
# ctrl+c arrived as ESC [ 99 ; 5 : 1 u and ctrl+u as ESC [ 117 ; 5 : 1 u
# (captured byte-exact off a real pane with `cat` in the foreground, herdr
# 0.9.1). A bare shell decodes neither, so both keys landed as literal text, the
# reset's `cd` proof never moved, and every relaunch retry was refused.
#
# Which encoding herdr picks is herdr's own decision, so it is pinned here
# end-to-end against the real binary rather than against a stub, and the same
# pane is driven all four ways so the check cannot pass against the defect: the
# reset is proven to work before the protocol is pushed, proven to fail once it
# is, and proven to work again through the raw-byte path that replaced the named
# keys. A pane read alone would only say a shell is idle.
#
# Only the recording step below reads how the shell renders an unknown key
# sequence. Every verdict here is a line-editor-independent fact about whether
# the reset's bytes reached the shell, so the block holds on any line editor
# that keeps a heredoc continuation.
pane_cwd() {
  local raw
  raw=$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)
  if [ -n "$raw" ]; then
    cd "$raw" 2>/dev/null && pwd -P || printf '%s' "$raw"
  fi
}

# Positive proofs poll the way the production reset does, so a loaded host
# cannot fail a check whose reset actually worked. Negative proofs keep a single
# read: polling there could only make them stricter, never looser.
wait_pane_cwd() {
  local want i=0
  want=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  while [ "$i" -lt 20 ]; do
    [ "$(pane_cwd)" = "$want" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

CONTINUE_PANE() {
  fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cat <<'FMEOF'" \
    || fail "could not type the heredoc opener into the herdr pane"
  sleep 1
  [ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = dead ] \
    || fail "a bare herdr shell in a continuation should classify dead, got '$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")'"
}

# Baseline: with no keyboard protocol active, a named-key reset clears the
# continuation. This is what makes the later failure attributable to the
# encoding rather than to the fixture or to the reset itself.
PRE_RESET_DIR="$SCRATCH/shell-reset-protocol-off"
mkdir -p "$PRE_RESET_DIR"
CONTINUE_PANE
fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-c || fail "could not deliver the baseline C-c"
fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-u || fail "could not deliver the baseline C-u"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd $(fm_backend_shell_quote "$PRE_RESET_DIR")" \
  || fail "could not type the baseline reset cd"
wait_pane_cwd "$PRE_RESET_DIR" \
  || fail "the baseline named-key reset should move the pane cwd before the keyboard protocol is active; it read '$(pane_cwd)', so a later failure could not be attributed to the protocol"
pass "real herdr: with no keyboard protocol active, a named-key reset clears the continuation and proves the cwd"

# The pane's own output pushes the kitty keyboard protocol, which is the state a
# departed agent leaves behind. Nothing else here simulates it.
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "printf '\\033[>3u'" \
  || fail "could not make the herdr pane's terminal push the keyboard protocol"
sleep 1

# The defect, observed: the same named C-c now arrives as visible CSI-u text at
# the prompt instead of interrupting the line. Recorded as evidence only - a line
# editor is free to swallow an unknown key sequence instead of showing it, so a
# missing trace must not stop the test. The named-key reset failing below is the
# precondition, and it fails on any line editor.
fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-c || fail "could not deliver the post-protocol C-c"
sleep 1
PROTOCOL_TAIL=$(fm_backend_herdr_capture "$SESSION:$PANE_ID" 6 | tail -2)
case "$PROTOCOL_TAIL" in
  *":1u"*)
    pass "real herdr: with the keyboard protocol pushed, a named ctrl+c lands as visible CSI-u text, not as a raw interrupt (evidence: '$PROTOCOL_TAIL')"
    ;;
  *)
    printf '# note: this shell renders no visible CSI-u text for the post-protocol ctrl+c (last lines: %s); the verdict below rests on the named-key reset failing, not on this\n' "$PROTOCOL_TAIL"
    ;;
esac

NAMED_RESET_DIR="$SCRATCH/shell-reset-named-keys"
mkdir -p "$NAMED_RESET_DIR"
CONTINUE_PANE
fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-c || fail "could not deliver the named-key reset C-c"
fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-u || fail "could not deliver the named-key reset C-u"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd $(fm_backend_shell_quote "$NAMED_RESET_DIR")" \
  || fail "could not type the named-key reset cd"
sleep 1
NAMED_RESET_OBSERVED=$(pane_cwd)
NAMED_RESET_EXPECTED=$(cd "$NAMED_RESET_DIR" && pwd -P)
[ "$NAMED_RESET_OBSERVED" != "$NAMED_RESET_EXPECTED" ] \
  || fail "the named-key reset unexpectedly cleared the continuation under the active keyboard protocol; the regression this pins is not reproducing, so the fix below is unproven"
pass "real herdr: under the active keyboard protocol the named-key reset leaves the continuation standing and the cwd never moves - the exact refusal the relaunch hit"

# The fix, on the same pane, still in that continuation: raw control bytes
# clear it and the cwd proof lands.
FIXED_RESET_DIR="$SCRATCH/shell-reset-raw-bytes"
mkdir -p "$FIXED_RESET_DIR"
fm_backend_reset_shell herdr "$SESSION:$PANE_ID" "$FIXED_RESET_DIR" \
  || fail "the raw-control-byte reset did not recover a pane the named-key reset left inside a continuation"
FIXED_RESET_EXPECTED=$(cd "$FIXED_RESET_DIR" && pwd -P)
wait_pane_cwd "$FIXED_RESET_DIR" \
  || fail "the raw-control-byte reset did not move the pane cwd to '$FIXED_RESET_EXPECTED' (got '$(pane_cwd)')"
pass "real herdr: the raw-control-byte reset clears the same continuation and proves the cwd where the named-key reset could not"

# And once more from a fresh continuation, so the fixed path is not credited
# only with cleaning up after the failed one.
CONTINUE_PANE
fm_backend_reset_shell herdr "$SESSION:$PANE_ID" "$FIXED_RESET_DIR" \
  || fail "the raw-control-byte reset did not clear a fresh continuation under the active keyboard protocol"
wait_pane_cwd "$FIXED_RESET_DIR" \
  || fail "the raw-control-byte reset left the pane cwd at '$(pane_cwd)' instead of '$FIXED_RESET_EXPECTED'"
pass "real herdr: the raw-control-byte reset clears a fresh continuation under the active keyboard protocol"

# Restore the pane to the state it was in before this block pushed the protocol,
# so the rest of this smoke test runs against a normal terminal instead of
# inheriting flags no later step is meant to be reading through.
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "printf '\\033[<u'" \
  || fail "could not pop the keyboard protocol off the herdr pane's terminal"
sleep 1
# Prove the pop landed by repeating the baseline: a raw-byte reset would clear
# this continuation either way, so only a named-key reset can show the flags are
# gone.
POPPED_DIR="$SCRATCH/shell-reset-protocol-popped"
mkdir -p "$POPPED_DIR"
CONTINUE_PANE
fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-c || fail "could not deliver the post-pop C-c"
fm_backend_herdr_send_key "$SESSION:$PANE_ID" C-u || fail "could not deliver the post-pop C-u"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd $(fm_backend_shell_quote "$POPPED_DIR")" \
  || fail "could not type the post-pop reset cd"
wait_pane_cwd "$POPPED_DIR" \
  || fail "a named-key reset still fails after popping the keyboard protocol, so the pane is still carrying this block's flags and the later checks below would read through them"
pass "real herdr: the keyboard protocol is popped and a named-key reset works again, so the rest of this smoke test sees a normal terminal"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent: classification flips, and the verbs follow ---------

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it deliberately types a harness command into a pane that hosts
# a plain shell: the registered agent cannot actually be stopped that way, and
# the control plane must say so rather than report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
