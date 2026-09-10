#!/usr/bin/env bash
# Behavior tests for the launch-drift detector: bin/fm-launch-drift-lib.sh's
# verdict policy, and its surfacing through bin/fm-crew-state.sh.
#
# What this protects: a restored worker can come back without the flags it was
# launched with, or in a different working directory, and the severe case is one
# restored into the project's PRIMARY CHECKOUT instead of its task worktree. No
# supported backend replays a launch command - Herdr persists none at all from
# 0.8.0 (docs/herdr-backend.md "Launch-argv replay") - so detection against
# firstmate's own record is the only cover, and these cases pin it. Herdr alone
# covers the argv axis through its atomic argv array. Tmux reports argv unknown
# because it has no atomic boundary-preserving argv source. The cwd axis covers
# tmux and Herdr through passive reads; zellij, cmux, and Orca remain unknown so
# a state read never types into a live pane.
#
# Both halves run without a harness, so CI enforces them everywhere:
#   (a) the verdict matrix, driven directly through the library's public
#       functions: healthy, argv loss, cwd drift, the severe primary-checkout
#       case, and both axes diverging at once.
#   (b) the unknown cases that must NEVER raise an alarm: an unreadable
#       endpoint, an unreadable argv axis in a task record written before this
#       detector existed, and a pane sitting at a shell prompt after its agent
#       exited. A verified cwd finding remains actionable for a legacy record.
#   (c) the launch-env isolation regression: a launch wrapped in
#       `/usr/bin/env -i ... /bin/sh -c '<launch>'` must not report the
#       WRAPPER's own -i and -c as flags the harness lost.
#   (d) end-to-end through fm-crew-state.sh, proving the severe finding reaches
#       the supervisor's line and that a healthy worker adds nothing to it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-launch-drift-lib.sh"
# shellcheck source=bin/fm-launch-drift-identity-lib.sh
. "$ROOT/bin/fm-launch-drift-identity-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch-drift)

PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/pool/task-worktree"
ELSEWHERE="$TMP_ROOT/elsewhere"
mkdir -p "$PROJECT/src" "$WORKTREE" "$ELSEWHERE"

LAUNCH="FM_HOME=/h claude --dangerously-skip-permissions --model opus --add-dir /x"
WRAPPED="/usr/bin/env -i HOME=/h /bin/sh -c 'FM_HOME=/h claude --dangerously-skip-permissions'"

# verdict_field <n> <harness> <recorded> <worktree> <project> <live-cwd> <live-argv>
verdict_field() {
  local n=$1 harness=$2
  shift 2
  fm_launch_drift_verdict "$1" "$harness" "${@:2}" | cut -f"$n"
}

argv_fields() {
  local field out=''
  for field in "$@"; do
    if [ -n "$out" ]; then out+=$'\037'; fi
    out+=$field
  done
  printf '%s' "$out"
}

# --- (a) the verdict matrix ------------------------------------------------

[ "$(verdict_field 1 claude "$LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --dangerously-skip-permissions --model opus --add-dir /x")" = ok ] \
  || fail "a healthy worker in its own worktree with intact flags must read ok"
pass "launch drift: matching worktree and intact flags read ok"

[ "$(verdict_field 2 claude "$LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus --add-dir /x")" = argv-loss ] \
  || fail "a worker missing a launched flag must read argv-loss"
assert_contains \
  "$(fm_launch_drift_verdict "$LAUNCH" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus --add-dir /x")" \
  "--dangerously-skip-permissions" \
  "argv-loss must name the flag that went missing"
pass "launch drift: a dropped flag reads argv-loss and names the flag"

MODEL_VALUE_LAUNCH="claude --model opus"
MODEL_VALUE_CHANGED=$(fm_launch_drift_verdict "$MODEL_VALUE_LAUNCH" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model sonnet")
[ "$(printf '%s' "$MODEL_VALUE_CHANGED" | cut -f2)" = argv-loss ] \
  || fail "a changed --model operand must read argv-loss, got: $MODEL_VALUE_CHANGED"
assert_contains "$MODEL_VALUE_CHANGED" "opus" "a changed option operand must name the recorded value"
assert_contains "$MODEL_VALUE_CHANGED" "sonnet" "a changed option operand must name the live value"

MODEL_VALUE_MISSING=$(fm_launch_drift_verdict "$MODEL_VALUE_LAUNCH" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model")
[ "$(printf '%s' "$MODEL_VALUE_MISSING" | cut -f2)" = argv-loss ] \
  || fail "a missing --model operand must read argv-loss, got: $MODEL_VALUE_MISSING"
assert_contains "$MODEL_VALUE_MISSING" "<missing>" "a missing option operand must be identified as missing"

MODEL_EQUALS_CHANGED=$(fm_launch_drift_verdict "claude --model=opus" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model sonnet")
[ "$(printf '%s' "$MODEL_EQUALS_CHANGED" | cut -f2)" = argv-loss ] \
  || fail "--opt=value must detect a changed operand, got: $MODEL_EQUALS_CHANGED"
[ "$(verdict_field 1 claude "claude --model=opus" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus")" = ok ] \
  || fail "--opt=value and --opt value must compare as equal when their operands match"
pass "launch drift: option operands detect changed and missing values"

# The literal $( is the fixture under test, not an expansion.
# shellcheck disable=SC2016
AGY_BRIEF_LAUNCH='agy -i "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
AGY_BRIEF_OK=$(fm_launch_drift_verdict "$AGY_BRIEF_LAUNCH" agy "$WORKTREE" "$PROJECT" "$WORKTREE" \
  "$(argv_fields agy -i encoded-launch-brief)")
[ "$(printf '%s' "$AGY_BRIEF_OK" | cut -f1)" = ok ] \
  || fail "a non-empty agy -i encoded brief must read ok, got: $AGY_BRIEF_OK"
AGY_BRIEF_MISSING=$(fm_launch_drift_verdict "$AGY_BRIEF_LAUNCH" agy "$WORKTREE" "$PROJECT" "$WORKTREE" \
  "$(argv_fields agy -i)")
[ "$(printf '%s' "$AGY_BRIEF_MISSING" | cut -f2)" = argv-loss ] \
  || fail "a missing agy -i encoded brief must read argv-loss, got: $AGY_BRIEF_MISSING"
AGY_BRIEF_EMPTY=$(fm_launch_drift_verdict "$AGY_BRIEF_LAUNCH" agy "$WORKTREE" "$PROJECT" "$WORKTREE" \
  "$(argv_fields agy -i '')")
[ "$(printf '%s' "$AGY_BRIEF_EMPTY" | cut -f2)" = argv-loss ] \
  || fail "an empty agy -i encoded brief must read argv-loss, got: $AGY_BRIEF_EMPTY"
pass "launch drift: encoded briefs require a non-empty option operand"

CODEX_NOTIFY='notify=["bash","-c","touch __TURNEND__"]'
CODEX_RECORD='codex -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]"'
CODEX_LIVE=$(argv_fields codex -c "$CODEX_NOTIFY")
[ "$(verdict_field 1 codex "$CODEX_RECORD" "$WORKTREE" "$PROJECT" "$WORKTREE" "$CODEX_LIVE")" = ok ] \
  || fail "an intact Codex -c operand with spaces and escaped quotes must read ok"
CODEX_CHANGED=$(fm_launch_drift_verdict "$CODEX_RECORD" codex "$WORKTREE" "$PROJECT" "$WORKTREE" \
  "$(argv_fields codex -c 'notify=["bash","-c","changed __TURNEND__"]')")
[ "$(printf '%s' "$CODEX_CHANGED" | cut -f2)" = argv-loss ] \
  || fail "a changed Codex -c operand with spaces must read argv-loss, got: $CODEX_CHANGED"
assert_contains "$CODEX_CHANGED" "$CODEX_NOTIFY" \
  "a changed Codex operand must name the recorded value"
assert_contains "$CODEX_CHANGED" "changed __TURNEND__" \
  "a changed Codex operand must name the live value"
CODEX_EQUALS_RECORD='codex --config="notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]"'
[ "$(verdict_field 1 codex "$CODEX_EQUALS_RECORD" "$WORKTREE" "$PROJECT" "$WORKTREE" \
  "$(argv_fields codex "--config=$CODEX_NOTIFY")")" = ok ] \
  || fail "an intact --opt=value operand with spaces must read ok"
pass "launch drift: encoded argv preserves spaced and quoted Codex operands"

[ "$(verdict_field 2 claude "$LAUNCH" "$WORKTREE" "$PROJECT" "$ELSEWHERE" "claude --dangerously-skip-permissions --model opus --add-dir /x")" = cwd-drift ] \
  || fail "a worker outside both its worktree and the project must read cwd-drift"
pass "launch drift: a worker in an unrelated directory reads cwd-drift"

# The severe case. This is the whole reason the detector exists: edits made here
# land in the checkout firstmate itself operates from.
SEVERE=$(fm_launch_drift_verdict "$LAUNCH" claude "$WORKTREE" "$PROJECT" "$PROJECT/src" "claude --dangerously-skip-permissions --model opus --add-dir /x")
[ "$(printf '%s' "$SEVERE" | cut -f1)" = severe ] \
  || fail "a worker inside the project's primary checkout must read severe, got: $SEVERE"
[ "$(printf '%s' "$SEVERE" | cut -f2)" = primary-checkout ] \
  || fail "the severe case must carry the primary-checkout code, got: $SEVERE"
pass "launch drift: a worker in the primary checkout reads severe/primary-checkout"

# Worst axis wins, and the weaker finding is still reported: a supervisor must
# never be told only about the flags while the worker stands in the checkout.
BOTH=$(fm_launch_drift_verdict "$LAUNCH" claude "$WORKTREE" "$PROJECT" "$PROJECT/src" "claude --model opus")
[ "$(printf '%s' "$BOTH" | cut -f1)" = severe ] \
  || fail "both axes diverging must keep the severe severity, got: $BOTH"
assert_contains "$BOTH" "primary-checkout+argv-loss" "both axes diverging must report both codes"
pass "launch drift: both axes diverging keep severe and report both findings"

# --- (b) the unknown cases that must not raise an alarm --------------------

[ "$(verdict_field 1 claude "$LAUNCH" "$WORKTREE" "$PROJECT" "" "")" = unknown ] \
  || fail "an endpoint that could not be read must be unknown, never drift"
[ "$(verdict_field 1 "" "" "" "" "" "")" = unknown ] \
  || fail "an unreadable pre-detector endpoint must be unknown, never drift"
# A pre-detector record leaves only its argv axis unknown. A verified-good cwd
# keeps the verdict silent, while a verified cwd divergence remains actionable.
[ "$(verdict_field 1 claude "" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --whatever")" = unknown ] \
  || fail "a pre-detector record with a healthy cwd must keep its argv axis unknown"
assert_contains \
  "$(fm_launch_drift_verdict "" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --whatever")" \
  "argv-unreadable" \
  "an unknown verdict must name which axis could not be verified"
pass "launch drift: unreadable endpoints and an unverified argv axis never alarm"

# A pane back at its shell prompt is a different condition entirely, owned by
# fm-crew-state.sh's own state read. Reporting it as lost flags would bury it.
SHELL_VERDICT=$(verdict_field 1 claude "$LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "")
case "$SHELL_VERDICT" in
  ok|unknown) ;;
  *) fail "a pane at a shell prompt must not be reported as drift, got: $SHELL_VERDICT" ;;
esac
assert_contains \
  "$(fm_launch_drift_verdict "$LAUNCH" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "")" \
  "argv-unreadable" \
  "an unreadable argv axis must stay silent"
pass "launch drift: a pane back at its shell prompt is not reported as lost flags"

# --- (c) the launch-env isolation regression -------------------------------

WRAPPED_VERDICT=$(verdict_field 1 claude "$WRAPPED" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --dangerously-skip-permissions")
[ "$WRAPPED_VERDICT" = ok ] \
  || fail "a launch-env-isolated launch must not report the wrapper's own -i/-c as lost harness flags, got: $WRAPPED_VERDICT"
assert_not_contains \
  "$(fm_launch_drift_flags "$WRAPPED" claude)" "-i" \
  "wrapper flags must not be collected as harness flags"
assert_contains \
  "$(fm_launch_drift_flags "$WRAPPED" claude)" "--dangerously-skip-permissions" \
  "the harness's own flags must still be collected from inside the wrapper"
pass "launch drift: the launch-env isolation wrapper's own flags are not attributed to the harness"

# Env options and relaunch shell prefixes must not become a false harness token.
ENV_UNSET_LAUNCH="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI claude --dangerously-skip-permissions --model opus"
[ "$(verdict_field 2 claude "$ENV_UNSET_LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus")" = argv-loss ] \
  || fail "an env -u wrapper must compare the real harness flags, not its removed variable names"
assert_contains \
  "$(fm_launch_drift_verdict "$ENV_UNSET_LAUNCH" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus")" \
  "--dangerously-skip-permissions" \
  "an env -u wrapper must name the real harness flag that went missing"

RELAUNCH="unset TRACEPARENT; claude --dangerously-skip-permissions --model opus"
[ "$(verdict_field 2 claude "$RELAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus")" = argv-loss ] \
  || fail "an unset relaunch prefix must compare the real harness flags, not TRACEPARENT"
assert_contains \
  "$(fm_launch_drift_verdict "$RELAUNCH" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus")" \
  "--dangerously-skip-permissions" \
  "an unset relaunch prefix must name the real harness flag that went missing"
pass "launch drift: env and relaunch prefixes preserve the true harness boundary"

QUOTED_HOME_LAUNCH="FM_HOME='/tmp/Second Mate' claude --dangerously-skip-permissions --model opus"
[ "$(verdict_field 2 claude "$QUOTED_HOME_LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus")" = argv-loss ] \
  || fail "a quoted assignment must preserve the true harness after a spaced value"
assert_contains \
  "$(fm_launch_drift_verdict "$QUOTED_HOME_LAUNCH" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "claude --model opus")" \
  "--dangerously-skip-permissions" \
  "a quoted assignment must preserve the flag that the true harness lost"
pass "launch drift: quoted assignment values preserve the true harness boundary"

PI_LAUNCH="pi --thinking high"
herdr_live_argv() {  # <harness>
  local harness=$1 argv_json
  argv_json=$(
    if [ -n "${FM_TEST_FG_EXACT_ARGV:-}" ]; then
      fm_launch_drift_live_tokens "$FM_TEST_FG_EXACT_ARGV"
    else
      fm_launch_drift_live_tokens "$FM_TEST_FG_ARGS"
    fi | jq -R . | jq -s .
  ) || return 1
  FM_TEST_HERDR_RESPONSE=$(jq -nc --arg name "$FM_TEST_FG_COMM" --argjson argv "$argv_json" \
    '{result:{process_info:{foreground_processes:[{name:$name,argv:$argv}]}}}') || return 1
  export FM_TEST_HERDR_RESPONSE
  (
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source herdr
    fm_backend_herdr_target_observe() { FM_BACKEND_HERDR_SESSION=default; FM_BACKEND_HERDR_PANE=w1:p2; }
    fm_backend_herdr_cli() { printf '%s\n' "$FM_TEST_HERDR_RESPONSE"; }
    fm_backend_pane_argv herdr default:w1:p2 "$harness"
  )
}

FM_TEST_FG_COMM=pip FM_TEST_FG_ARGS='pip --thinking high' FM_TEST_FG_ARGV0=pip
export FM_TEST_FG_COMM FM_TEST_FG_ARGS FM_TEST_FG_ARGV0
if herdr_live_argv pi >/dev/null; then
  fail "a strict executable-name prefix must not be treated as the recorded harness"
fi
FM_TEST_FG_COMM=/opt/local/bin/pi FM_TEST_FG_ARGS='/opt/local/bin/pi --thinking high' FM_TEST_FG_ARGV0=/opt/local/bin/pi
PI_ARGV=$(herdr_live_argv pi) || fail "a path-qualified executable must match the recorded harness by its final component"
[ "$(verdict_field 1 pi "$PI_LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "$PI_ARGV")" = ok ] \
  || fail "a path-qualified executable must stay comparable after adapter identity selection"
pass "launch drift: foreground identity requires an executable token boundary"

FM_TEST_FG_COMM=codex FM_TEST_FG_ARGV0=codex
FM_TEST_FG_ARGS="codex -c $CODEX_NOTIFY"
FM_TEST_FG_EXACT_ARGV=$(argv_fields codex -c "$CODEX_NOTIFY")
CODEX_ADAPTER_ARGV=$(herdr_live_argv codex) || fail "the Herdr adapter must return a field-preserving Codex argv"
[ "$(verdict_field 1 codex "$CODEX_RECORD" "$WORKTREE" "$PROJECT" "$WORKTREE" "$CODEX_ADAPTER_ARGV")" = ok ] \
  || fail "a field-preserving Herdr Codex argv must read ok"
unset FM_TEST_FG_EXACT_ARGV
pass "launch drift: Herdr argv fields preserve the Codex notify operand"

FM_TEST_FG_COMM=claude FM_TEST_FG_ARGS='claude --model opus' FM_TEST_FG_ARGV0=claude
HERDR_MODEL_OK=$(herdr_live_argv claude) || fail "the Herdr adapter must return an intact model argv"
[ "$(verdict_field 1 claude 'claude --model opus' "$WORKTREE" "$PROJECT" "$WORKTREE" "$HERDR_MODEL_OK")" = ok ] \
  || fail "an intact Herdr model argv must read ok"
FM_TEST_FG_ARGS='claude --model sonnet'
HERDR_MODEL_CHANGED=$(herdr_live_argv claude) || fail "the Herdr adapter must return a changed model argv"
HERDR_MODEL_DRIFT=$(fm_launch_drift_verdict 'claude --model opus' claude "$WORKTREE" "$PROJECT" "$WORKTREE" "$HERDR_MODEL_CHANGED")
[ "$(printf '%s' "$HERDR_MODEL_DRIFT" | cut -f2)" = argv-loss ] \
  || fail "a changed Herdr model operand must read argv-loss, got: $HERDR_MODEL_DRIFT"
pass "launch drift: Herdr argv detects changed option operands"

CURSOR_LAUNCH="cursor-agent --trust --yolo"
FM_TEST_FG_COMM=node FM_TEST_FG_ARGS='node /opt/cursor/cursor-agent --trust --yolo' FM_TEST_FG_ARGV0=node
CURSOR_ARGV=$(herdr_live_argv cursor-agent) || fail "a node-bundled Cursor worker must identify through the Herdr adapter"
[ "$(verdict_field 1 cursor-agent "$CURSOR_LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "$CURSOR_ARGV")" = ok ] \
  || fail "a node-bundled Cursor worker with intact flags must read ok"
FM_TEST_FG_ARGS='node /opt/cursor/cursor-agent --trust'
CURSOR_ARGV_LOSS=$(herdr_live_argv cursor-agent) || fail "a node-bundled Cursor worker must remain identifiable after a flag loss"
CURSOR_LOSS=$(fm_launch_drift_verdict "$CURSOR_LAUNCH" cursor-agent "$WORKTREE" "$PROJECT" "$WORKTREE" "$CURSOR_ARGV_LOSS")
[ "$(printf '%s' "$CURSOR_LOSS" | cut -f2)" = argv-loss ] \
  || fail "a node-bundled harness missing --yolo must read argv-loss, got: $CURSOR_LOSS"
assert_contains "$CURSOR_LOSS" "--yolo" \
  "a node-bundled harness argv-loss must name the dropped flag"
pass "launch drift: node-bundled harnesses retain argv-loss detection"

CURSOR_ALIAS_LAUNCH="/opt/cursor/agent --trust --yolo"
CURSOR_ALIAS_LOSS=$(fm_launch_drift_verdict "$CURSOR_ALIAS_LAUNCH" cursor "$WORKTREE" "$PROJECT" "$WORKTREE" "$CURSOR_ARGV_LOSS")
[ "$(printf '%s' "$CURSOR_ALIAS_LOSS" | cut -f2)" = argv-loss ] \
  || fail "a verified legacy Cursor alias missing --yolo must read argv-loss, got: $CURSOR_ALIAS_LOSS"
assert_contains "$CURSOR_ALIAS_LOSS" "--yolo" \
  "a verified legacy Cursor alias argv-loss must name the dropped flag"
pass "launch drift: the recorded Cursor alias retains argv-loss detection"

CLAUDE_NODE_LAUNCH="claude --dangerously-skip-permissions"
FM_TEST_FG_COMM=node FM_TEST_FG_ARGS='node /x/@anthropic-ai/claude-code/cli.js --dangerously-skip-permissions' FM_TEST_FG_ARGV0=node
CLAUDE_NODE_ARGV=$(herdr_live_argv claude) || fail "an interpreter-launched Claude worker must identify through the Herdr adapter"
[ "$(verdict_field 1 claude "$CLAUDE_NODE_LAUNCH" "$WORKTREE" "$PROJECT" "$WORKTREE" "$CLAUDE_NODE_ARGV")" = ok ] \
  || fail "an interpreter-launched Claude worker with intact flags must read ok"
FM_TEST_FG_ARGS='node /x/@anthropic-ai/claude-code/cli.js'
CLAUDE_NODE_ARGV_LOSS=$(herdr_live_argv claude) || fail "an interpreter-launched Claude worker must remain identifiable after a flag loss"
CLAUDE_NODE_LOSS=$(fm_launch_drift_verdict "$CLAUDE_NODE_LAUNCH" claude "$WORKTREE" "$PROJECT" "$WORKTREE" "$CLAUDE_NODE_ARGV_LOSS")
[ "$(printf '%s' "$CLAUDE_NODE_LOSS" | cut -f2)" = argv-loss ] \
  || fail "an interpreter-launched Claude worker missing its flag must read argv-loss, got: $CLAUDE_NODE_LOSS"
assert_contains "$CLAUDE_NODE_LOSS" "--dangerously-skip-permissions" \
  "an interpreter-launched Claude argv-loss must name the dropped flag"
pass "launch drift: interpreter-launched Claude workers retain argv-loss detection"

for drift_case in \
  'codex|codex|codex|codex --full-auto|--full-auto' \
  'opencode|opencode|opencode|opencode --agent build|--agent' \
  'pi-signed|pi-signed|pi-signed|pi-signed --thinking high|--thinking' \
  'grok|grok|grok|grok --fast|--fast' \
  'kimi|kimi|kimi|kimi --yolo|--yolo' \
  'cline|/opt/cline/bin/cline|/opt/cline/bin/cline|cline --yolo|--yolo' \
  'omp|omp|omp|omp --yolo|--yolo' \
  'agy|agy|agy|agy --dangerously-skip-permissions|--dangerously-skip-permissions' \
  'muse|muse-bin-1.0|muse-bin-1.0|muse-bin-1.0 --yolo|--yolo' \
  'copilot|copilot|copilot|copilot --yolo|--yolo' \
  'rovo|rovo|rovo|rovo --yolo|--yolo'; do
  IFS='|' read -r CASE_HARNESS CASE_COMM CASE_ARGV0 CASE_RECORD CASE_FLAG <<EOF
$drift_case
EOF
  FM_TEST_FG_COMM=$CASE_COMM FM_TEST_FG_ARGS="${CASE_RECORD/$CASE_FLAG/}" FM_TEST_FG_ARGV0=$CASE_ARGV0
  CASE_LIVE=$(herdr_live_argv "$CASE_HARNESS") \
    || fail "$CASE_HARNESS must remain identifiable after a launch flag is lost"
  CASE_LOSS=$(fm_launch_drift_verdict "$CASE_RECORD" "$CASE_HARNESS" "$WORKTREE" "$PROJECT" "$WORKTREE" "$CASE_LIVE")
  [ "$(printf '%s' "$CASE_LOSS" | cut -f2)" = argv-loss ] \
    || fail "$CASE_HARNESS missing $CASE_FLAG must read argv-loss, got: $CASE_LOSS"
  assert_contains "$CASE_LOSS" "$CASE_FLAG" \
    "$CASE_HARNESS argv-loss must name the dropped flag"
done

FM_TEST_FG_COMM=node FM_TEST_FG_ARGS='node /opt/gemini/gemini' FM_TEST_FG_ARGV0=node
GEMINI_LIVE=$(herdr_live_argv gemini) || fail "gemini must identify through its interpreter command"
GEMINI_LOSS=$(fm_launch_drift_verdict 'gemini --yolo' gemini "$WORKTREE" "$PROJECT" "$WORKTREE" "$GEMINI_LIVE")
[ "$(printf '%s' "$GEMINI_LOSS" | cut -f2)" = argv-loss ] \
  || fail "gemini missing --yolo must read argv-loss, got: $GEMINI_LOSS"

FM_TEST_FG_COMM=node FM_TEST_FG_ARGS='node /opt/node_modules/cline/bin/.cline' FM_TEST_FG_ARGV0=node
CLINE_LIVE=$(herdr_live_argv cline) || fail "cline must identify through its executed script"
CLINE_LOSS=$(fm_launch_drift_verdict 'cline --yolo' cline "$WORKTREE" "$PROJECT" "$WORKTREE" "$CLINE_LIVE")
[ "$(printf '%s' "$CLINE_LOSS" | cut -f2)" = argv-loss ] \
  || fail "cline missing --yolo must read argv-loss, got: $CLINE_LOSS"
pass "launch drift: every supported harness retains argv-loss detection"

(
  . "$ROOT/bin/fm-session-lock-lib.sh"
  ! fm_harness_process_matches agy 'agy --dangerously-skip-permissions'
  ! fm_harness_process_matches node 'node /opt/cursor/cursor-agent --trust'
) || fail "launch-drift identity must not broaden session-lock holder identity"
fm_launch_drift_process_matches cursor-agent node 'node /opt/cursor/cursor-agent --trust' node \
  || fail "launch-drift identity must retain detector-only Cursor script evidence"
pass "launch drift: Cursor detector evidence leaves session-lock identity unchanged"

# State reads must use only passive cwd readers and leave active adapter probes
# reserved for fm-spawn.sh before a harness starts.
(
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  _FM_BACKEND_TMUX_SOURCED=1
  _FM_BACKEND_HERDR_SOURCED=1
  _FM_BACKEND_ZELLIJ_SOURCED=1
  _FM_BACKEND_CMUX_SOURCED=1
  _FM_BACKEND_ORCA_SOURCED=1
  # tmux has two passive readers, and supervision must use the BOUND one:
  # fm_backend_tmux_current_path is the cheap direct read fm-spawn.sh polls
  # while waiting for a pane it just created, and it inherits tmux's
  # active-pane fallback for an absent target. Only the bound reader proves
  # the value belongs to the recorded pane, which is what keeps a torn-down
  # task from being annotated with a severe primary-checkout landing.
  fm_backend_tmux_current_path() { printf '/unbound/tmux\n'; }
  fm_backend_tmux_bound_current_path() { printf '/passive/tmux\n'; }
  fm_backend_herdr_current_path() { printf '/passive/herdr\n'; }
  fm_backend_zellij_current_path() { return 23; }
  fm_backend_cmux_current_path() { return 24; }
  [ "$(fm_backend_current_path tmux sess:win)" = /passive/tmux ] \
    || fail "the tmux dispatcher must use its BOUND passive cwd reader, not the unbound spawn poll"
  [ "$(fm_backend_current_path herdr default:w1:p2)" = /passive/herdr ] \
    || fail "the Herdr dispatcher must retain its passive cwd reader"
  fm_backend_current_path zellij firstmate:7 fm-task >/dev/null
  [ "$?" -eq 1 ] || fail "the zellij dispatcher must not invoke its active cwd probe"
  fm_backend_current_path cmux workspace:surface fm-task >/dev/null
  [ "$?" -eq 1 ] || fail "the cmux dispatcher must not invoke its active cwd probe"
  fm_backend_current_path orca terminal-1 >/dev/null
  [ "$?" -eq 1 ] || fail "the Orca dispatcher must report its unavailable cwd axis as unknown"
) || fail "the passive cwd dispatcher contract failed"
pass "launch drift: supervision dispatches only passive cwd readers"

# --- (d) end to end through fm-crew-state.sh -------------------------------

# A controlled tmux process view supplies the foreground worker command line.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# Only the reads the detector and the readability probe make.
for arg in "$@"; do
  case "$arg" in
    '#{pane_current_path}') printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
    '#{pane_tty}') printf '%s\n' "${FM_FAKE_ACTIVE_TTY:-/dev/pts/fm-launch-drift}"; exit 0 ;;
    '#{pane_id}') printf '%%0\n'; exit 0 ;;
  esac
done
if [ "${1:-}" = list-panes ] && [ "${2:-}" = -a ]; then
  [ "${FM_FAKE_TMUX_TARGET_LIVE:-1}" = 1 ] \
    && printf 'firstmate\tfm-healthy\t@1\t%%0\t1\t%s\t/dev/pts/fm-launch-drift\n' "${FM_FAKE_SNAPSHOT_PATH:-}"
  exit 0
fi
exit 0
SH
chmod +x "$FAKEBIN/tmux"

REAL_PS=$(command -v ps)
export REAL_PS
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *' -t pts/fm-launch-drift '*) printf '4242 4242 4242 claude\n' ;;
  *' -p 4242 '*) printf '%s\n' "${FAKE_AGENT_ARGV:-}" ;;
  *) exec "$REAL_PS" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/ps"

PATH="$FAKEBIN:$PATH"
export PATH

STATE_DIR="$TMP_ROOT/state"
mkdir -p "$STATE_DIR"

FAKE_AGENT_ARGV='claude --dangerously-skip-permissions --model opus'
FM_FAKE_TMUX_TARGET_LIVE=1
FM_FAKE_SNAPSHOT_PATH="$WORKTREE"
FM_FAKE_PANE_PATH="$WORKTREE"
export FAKE_AGENT_ARGV FM_FAKE_TMUX_TARGET_LIVE FM_FAKE_SNAPSHOT_PATH FM_FAKE_PANE_PATH
trap 'fm_test_cleanup' EXIT

. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
if fm_backend_pane_argv tmux '%0' claude >/dev/null; then
  fail "tmux must leave the argv axis unreadable"
fi
pass "launch drift: tmux reports its argv axis as unknown"

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
write_task_meta healthy "claude --dangerously-skip-permissions --model opus"
FM_FAKE_PANE_PATH="$WORKTREE"
FM_FAKE_SNAPSHOT_PATH="$WORKTREE"
export FM_FAKE_PANE_PATH FM_FAKE_SNAPSHOT_PATH
HEALTHY_LINE=$(crew_state healthy)
assert_not_contains "$HEALTHY_LINE" "launch drift" \
  "a healthy worker must not be annotated with launch drift"
pass "launch drift: fm-crew-state.sh leaves a healthy worker's line unannotated"

FM_FAKE_SNAPSHOT_PATH="$WORKTREE"
FM_FAKE_PANE_PATH="$PROJECT/src"
export FM_FAKE_SNAPSHOT_PATH FM_FAKE_PANE_PATH
RACE_LINE=$(crew_state healthy)
assert_not_contains "$RACE_LINE" "primary-checkout" \
  "a target snapshot must not be replaced by a later active-pane cwd read"
assert_not_contains "$RACE_LINE" "launch drift" \
  "a target snapshot must keep a healthy worker silent during pane teardown"
pass "launch drift: tmux reads stay bound to the target snapshot"

# Severe: the same worker, now standing in the primary checkout.
FM_FAKE_PANE_PATH="$PROJECT/src"
FM_FAKE_SNAPSHOT_PATH="$PROJECT/src"
export FM_FAKE_PANE_PATH FM_FAKE_SNAPSHOT_PATH
SEVERE_LINE=$(crew_state healthy)
assert_contains "$SEVERE_LINE" "LAUNCH DRIFT (severe, primary-checkout)" \
  "a worker in the primary checkout must be surfaced on the supervisor's line"
assert_contains "$SEVERE_LINE" "state: " \
  "the drift annotation must accompany the state, not replace it"
pass "launch drift: fm-crew-state.sh surfaces the primary-checkout case on the state line"

FM_FAKE_TMUX_TARGET_LIVE=0
FM_FAKE_PANE_PATH="$PROJECT/src"
FM_FAKE_SNAPSHOT_PATH="$PROJECT/src"
export FM_FAKE_TMUX_TARGET_LIVE FM_FAKE_PANE_PATH FM_FAKE_SNAPSHOT_PATH
MISSING_LINE=$(crew_state healthy)
assert_not_contains "$MISSING_LINE" "primary-checkout" \
  "a torn-down tmux target must not read the active pane as a primary-checkout worker"
assert_not_contains "$MISSING_LINE" "launch drift" \
  "a torn-down tmux target must keep both unreadable axes silent"
FM_FAKE_TMUX_TARGET_LIVE=1
export FM_FAKE_TMUX_TARGET_LIVE
pass "launch drift: a torn-down tmux target stays silent"

# A restored tmux worker can lose flags, but its argv axis is deliberately
# unreadable while its verified cwd stays in the task worktree.
FAKE_AGENT_ARGV='claude --model opus'
export FAKE_AGENT_ARGV
FM_FAKE_PANE_PATH="$WORKTREE"
FM_FAKE_SNAPSHOT_PATH="$WORKTREE"
export FM_FAKE_PANE_PATH FM_FAKE_SNAPSHOT_PATH
ARGV_LOSS_LINE=$(crew_state healthy)
assert_not_contains "$ARGV_LOSS_LINE" "launch drift" \
  "a tmux worker with unreadable argv must not be annotated for lost flags"
pass "launch drift: tmux lost flags leave the argv axis unknown"

# A task record written before this detector existed has a silent argv axis.
# Its independently verified cwd axis remains actionable.
write_task_meta legacy
FM_FAKE_PANE_PATH="$WORKTREE"
FM_FAKE_SNAPSHOT_PATH="$WORKTREE"
export FM_FAKE_PANE_PATH FM_FAKE_SNAPSHOT_PATH
LEGACY_LINE=$(crew_state legacy)
assert_not_contains "$LEGACY_LINE" "launch drift" \
  "a pre-detector record with a healthy cwd must stay unannotated"
FM_FAKE_PANE_PATH="$PROJECT/src"
FM_FAKE_SNAPSHOT_PATH="$PROJECT/src"
export FM_FAKE_PANE_PATH FM_FAKE_SNAPSHOT_PATH
LEGACY_SEVERE=$(crew_state legacy)
assert_contains "$LEGACY_SEVERE" "primary-checkout" \
  "a pre-detector record must report a verified primary-checkout cwd landing"
pass "launch drift: legacy records keep a silent argv axis and severe cwd alarms"
