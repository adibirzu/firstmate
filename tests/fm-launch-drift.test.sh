#!/usr/bin/env bash
# Behavior tests for the launch-drift detector: bin/fm-launch-drift-lib.sh's
# verdict policy, and its surfacing through bin/fm-crew-state.sh.
#
# What this protects: a restored worker can come back without the flags it was
# launched with, or in a different working directory, and the severe case is one
# restored into the project's PRIMARY CHECKOUT instead of its task worktree. No
# supported backend replays a launch command - Herdr persists none at all from
# 0.8.0 (docs/herdr-backend.md "Launch-argv replay") - so detection against
# firstmate's own record is the only cover, and these cases pin it.
#
# Both halves run with real processes and no harness, so CI enforces them
# everywhere:
#   (a) the verdict matrix, driven directly through the library's public
#       functions: healthy, argv loss, cwd drift, the severe primary-checkout
#       case, and both axes diverging at once.
#   (b) the unknown cases that must NEVER raise an alarm: an unreadable
#       endpoint, a task record written before this detector existed, and a pane
#       sitting at a shell prompt after its agent exited.
#   (c) the launch-env isolation regression: a launch wrapped in
#       `/usr/bin/env -i ... /bin/sh -c '<launch>'` must not report the
#       WRAPPER's own -i and -c as flags the harness lost.
#   (d) end-to-end through fm-crew-state.sh over a real process tree, proving
#       the severe finding reaches the supervisor's line and that a healthy
#       worker adds nothing to it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-launch-drift-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch-drift)

PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/pool/task-worktree"
ELSEWHERE="$TMP_ROOT/elsewhere"
mkdir -p "$PROJECT/src" "$WORKTREE" "$ELSEWHERE"

LAUNCH="FM_HOME=/h claude --dangerously-skip-permissions --model opus --add-dir /x"
WRAPPED="/usr/bin/env -i HOME=/h /bin/sh -c 'FM_HOME=/h claude --dangerously-skip-permissions'"

# verdict_field <n> <recorded> <worktree> <project> <live-cwd> <live-argv>
verdict_field() {
  local n=$1
  shift
  fm_launch_drift_verdict "$@" | cut -f"$n"
}

# --- (a) the verdict matrix ------------------------------------------------

[ "$(verdict_field 1 "$LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --dangerously-skip-permissions --model opus --add-dir /x")" = ok ] \
  || fail "a healthy worker in its own worktree with intact flags must read ok"
pass "launch drift: matching worktree and intact flags read ok"

[ "$(verdict_field 2 "$LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus --add-dir /x")" = argv-loss ] \
  || fail "a worker missing a launched flag must read argv-loss"
assert_contains \
  "$(fm_launch_drift_verdict "$LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus --add-dir /x")" \
  "--dangerously-skip-permissions" \
  "argv-loss must name the flag that went missing"
pass "launch drift: a dropped flag reads argv-loss and names the flag"

[ "$(verdict_field 2 "$LAUNCH" "$WORKTREE" "$PROJECT" "$ELSEWHERE" "claude --dangerously-skip-permissions --model opus --add-dir /x")" = cwd-drift ] \
  || fail "a worker outside both its worktree and the project must read cwd-drift"
pass "launch drift: a worker in an unrelated directory reads cwd-drift"

# The severe case. This is the whole reason the detector exists: edits made here
# land in the checkout firstmate itself operates from.
SEVERE=$(fm_launch_drift_verdict "$LAUNCH" "$WORKTREE" "$PROJECT" "$PROJECT/src" "claude --dangerously-skip-permissions --model opus --add-dir /x")
[ "$(printf '%s' "$SEVERE" | cut -f1)" = severe ] \
  || fail "a worker inside the project's primary checkout must read severe, got: $SEVERE"
[ "$(printf '%s' "$SEVERE" | cut -f2)" = primary-checkout ] \
  || fail "the severe case must carry the primary-checkout code, got: $SEVERE"
pass "launch drift: a worker in the primary checkout reads severe/primary-checkout"

# Worst axis wins, and the weaker finding is still reported: a supervisor must
# never be told only about the flags while the worker stands in the checkout.
BOTH=$(fm_launch_drift_verdict "$LAUNCH" "$WORKTREE" "$PROJECT" "$PROJECT/src" "claude --model opus")
[ "$(printf '%s' "$BOTH" | cut -f1)" = severe ] \
  || fail "both axes diverging must keep the severe severity, got: $BOTH"
assert_contains "$BOTH" "primary-checkout+argv-loss" "both axes diverging must report both codes"
pass "launch drift: both axes diverging keep severe and report both findings"

# --- (b) the unknown cases that must not raise an alarm --------------------

[ "$(verdict_field 1 "$LAUNCH" "$WORKTREE" "$PROJECT" "" "")" = unknown ] \
  || fail "an endpoint that could not be read must be unknown, never drift"
[ "$(verdict_field 1 "" "" "" "" "")" = unknown ] \
  || fail "a task record from before this detector existed must be unknown, never drift"
# An unverifiable axis outranks a verified-good one, so a record with no
# launch_argv= reads unknown even while its cwd checks out. Both are silent to
# the caller; what must never happen is either one reading as drift.
[ "$(verdict_field 1 "" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --whatever")" = unknown ] \
  || fail "a record with no launch_argv= must be unknown, never drift"
assert_contains \
  "$(fm_launch_drift_verdict "" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --whatever")" \
  "argv-unreadable" \
  "an unknown verdict must name which axis could not be verified"
pass "launch drift: unreadable endpoints and pre-detector records never alarm"

# A pane back at its shell prompt is a different condition entirely, owned by
# fm-crew-state.sh's own state read. Reporting it as lost flags would bury it.
SHELL_VERDICT=$(verdict_field 1 "$LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "-zsh")
case "$SHELL_VERDICT" in
  ok|unknown) ;;
  *) fail "a pane at a shell prompt must not be reported as drift, got: $SHELL_VERDICT" ;;
esac
assert_contains \
  "$(fm_launch_drift_verdict "$LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "-zsh")" \
  "not running claude" \
  "an exited agent must be described as such, not as lost flags"
pass "launch drift: a pane back at its shell prompt is not reported as lost flags"

# --- (c) the launch-env isolation regression -------------------------------

WRAPPED_VERDICT=$(verdict_field 1 "$WRAPPED" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --dangerously-skip-permissions")
[ "$WRAPPED_VERDICT" = ok ] \
  || fail "a launch-env-isolated launch must not report the wrapper's own -i/-c as lost harness flags, got: $WRAPPED_VERDICT"
assert_not_contains \
  "$(fm_launch_drift_flags "$WRAPPED")" "-i" \
  "wrapper flags must not be collected as harness flags"
assert_contains \
  "$(fm_launch_drift_flags "$WRAPPED")" "--dangerously-skip-permissions" \
  "the harness's own flags must still be collected from inside the wrapper"
pass "launch drift: the launch-env isolation wrapper's own flags are not attributed to the harness"

# --- (d) end to end through fm-crew-state.sh -------------------------------

# A real process tree: a shell parent standing in for the pane, with a real
# flag-carrying child standing in for the agent. The fake tmux reports that
# shell as the pane pid, so fm_backend_tmux_pane_argv's descendant walk runs
# against a genuine process table rather than a canned string.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# Only the three reads the detector and the readability probe make.
for arg in "$@"; do
  case "$arg" in
    '#{pane_current_path}') printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
    '#{pane_pid}') printf '%s\n' "${FM_FAKE_PANE_PID:-}"; exit 0 ;;
    '#{pane_id}') printf '%%0\n'; exit 0 ;;
  esac
done
exit 0
SH
chmod +x "$FAKEBIN/tmux"

PATH="$FAKEBIN:$PATH"
export PATH

STATE_DIR="$TMP_ROOT/state"
mkdir -p "$STATE_DIR"

# `exec -a` renames the process so the table really carries the launched flags,
# rather than a shebang script whose interpreter is what ps would report. The
# subshell keeps the outer bash alive as the pane pid with the agent as its
# child, which is the shape the descendant walk expects.
FAKE_AGENT_ARGV='fmfakeagent --dangerously-skip-permissions --model opus'
start_fake_agent() {  # <argv-string>
  # The wrapper shell's stderr is discarded: when stop_fake_agent kills the
  # stand-in agent, that shell reports its terminated child, and the notice
  # would land in the suite's own output looking like a failure.
  bash -c "( exec -a \"\$1\" sleep 300 )" _ "$1" 2>/dev/null &
  FAKE_PANE_PID=$!
  local waited=0
  while [ "$waited" -lt 40 ]; do
    pgrep -P "$FAKE_PANE_PID" >/dev/null 2>&1 && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}
stop_fake_agent() {
  [ -n "${FAKE_PANE_PID:-}" ] || return 0
  pkill -P "$FAKE_PANE_PID" 2>/dev/null || true
  kill "$FAKE_PANE_PID" 2>/dev/null || true
  # Reap it here: an unwaited killed job makes bash print a "Terminated" notice
  # into the suite's own output at exit, which reads like a failure in CI logs.
  wait "$FAKE_PANE_PID" 2>/dev/null || true
  FAKE_PANE_PID=''
}
trap 'stop_fake_agent; fm_test_cleanup' EXIT

start_fake_agent "$FAKE_AGENT_ARGV" || fail "the stand-in agent process never appeared"

# Prove the reader actually sees the flags before any verdict is trusted:
# without this the healthy case below could pass merely because the argv was
# unreadable and the axis went quiet.
. "$ROOT/bin/fm-backend.sh"
READ_ARGV=$(fm_backend_agent_descendant_argv "$FAKE_PANE_PID") \
  || fail "the descendant walk could not read the stand-in agent's command line"
assert_contains "$READ_ARGV" "--dangerously-skip-permissions" \
  "the descendant walk must read the agent's own launched flags"
assert_contains "$READ_ARGV" "fmfakeagent" \
  "the descendant walk must read the agent, not its wrapper shell"
pass "launch drift: the process-table reader sees the agent's real command line"

export FM_FAKE_PANE_PID="$FAKE_PANE_PID"

# kind=scout keeps the no-mistakes run lookup out of this suite: the run-step
# source has its own coverage in tests/fm-crew-state.test.sh, and this suite is
# about the annotation the line carries, not the state it reports.
write_task_meta() {  # <id> [launch_argv]
  local id=$1 launch=${2:-}
  fm_write_meta "$STATE_DIR/$id.meta" \
    "window=%0" \
    "endpoint_task_id=$id" \
    "worktree=$WORKTREE" \
    "project=$PROJECT" \
    "harness=claude" \
    "kind=scout" \
    "backend=tmux"
  [ -z "$launch" ] || printf 'launch_argv=%s\n' "$launch" >> "$STATE_DIR/$id.meta"
}

crew_state() {  # <id>
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE_DIR" "$CREW_STATE" "$1" 2>&1
}

# Healthy: the worker is in its worktree with its flags. The supervisor's line
# must stay clean - a detector that annotates healthy workers is noise.
write_task_meta healthy "fmfakeagent --dangerously-skip-permissions --model opus"
FM_FAKE_PANE_PATH="$WORKTREE"
export FM_FAKE_PANE_PATH
HEALTHY_LINE=$(crew_state healthy)
assert_not_contains "$HEALTHY_LINE" "launch drift" \
  "a healthy worker must not be annotated with launch drift"
pass "launch drift: fm-crew-state.sh leaves a healthy worker's line unannotated"

# Severe: the same worker, now standing in the primary checkout.
FM_FAKE_PANE_PATH="$PROJECT/src"
export FM_FAKE_PANE_PATH
SEVERE_LINE=$(crew_state healthy)
assert_contains "$SEVERE_LINE" "LAUNCH DRIFT (severe, primary-checkout)" \
  "a worker in the primary checkout must be surfaced on the supervisor's line"
assert_contains "$SEVERE_LINE" "state: " \
  "the drift annotation must accompany the state, not replace it"
pass "launch drift: fm-crew-state.sh surfaces the primary-checkout case on the state line"

# The production symptom itself: the worker came back, in the right place, but
# without the flags it was launched with. Restarting the stand-in agent under a
# reduced argv reproduces exactly that.
stop_fake_agent
start_fake_agent 'fmfakeagent --model opus' || fail "the reduced stand-in agent never appeared"
export FM_FAKE_PANE_PID="$FAKE_PANE_PID"
FM_FAKE_PANE_PATH="$WORKTREE"
export FM_FAKE_PANE_PATH
ARGV_LOSS_LINE=$(crew_state healthy)
assert_contains "$ARGV_LOSS_LINE" "launch drift (argv-loss)" \
  "a worker restored without its launched flags must be surfaced"
assert_contains "$ARGV_LOSS_LINE" "--dangerously-skip-permissions" \
  "the argv-loss annotation must name the flag the restored worker lost"
pass "launch drift: fm-crew-state.sh surfaces a worker restored without its launched flags"

# A task record written before this detector existed must stay silent on the
# argv axis while the cwd axis still works.
write_task_meta legacy
FM_FAKE_PANE_PATH="$WORKTREE"
export FM_FAKE_PANE_PATH
LEGACY_LINE=$(crew_state legacy)
assert_not_contains "$LEGACY_LINE" "launch drift" \
  "a pre-detector task record must not be annotated"
FM_FAKE_PANE_PATH="$PROJECT/src"
export FM_FAKE_PANE_PATH
LEGACY_SEVERE=$(crew_state legacy)
assert_contains "$LEGACY_SEVERE" "primary-checkout" \
  "a pre-detector record must still get the cwd axis, which needs no launch_argv="
pass "launch drift: a pre-detector task record keeps the cwd axis and never false-alarms on argv"


