#!/usr/bin/env bash
# Behavior tests for agy (Antigravity CLI) as a firstmate PRIMARY and SECONDMATE
# harness (docs/turnend-guard.md, docs/supervision-protocols/agy.md,
# docs/verification/agy.md).
#
# Hermetic over temp dirs with real processes and NO agy installed, so CI
# enforces them everywhere. The payloads are the shapes recorded live on agy
# 1.4.7 in docs/verification/agy.md; nothing here replaces a live run.
#   PARK         - bin/fm-turnend-guard-agy.sh, the Stop-hook park: its
#                  continuation sources, its untouched stops, its double loop
#                  bound, its park window, its bounded repair nag, and its
#                  supersession contract.
#   SESSION      - bin/fm-sessionstart-agy.sh, which injects the digest.
#   PRETOOL      - the --agy renderings of the arm and cd seatbelts.
#   REGISTRATION - the tracked .agents/hooks.json resolves to real adapters.
#   WIRING       - the protocol renderer, the supervision model, and the
#                  secondmate-home trust pre-registration.
#
# The park runs as a child of a fake harness (a real executable named agy)
# whose pid holds the fixture home's session lock, so the real agy ancestry path
# in bin/fm-session-lock-lib.sh is exercised rather than stubbed.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-primary)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
# A real executable whose own canonical basename is agy: a symlink to bash would
# resolve to bash on Linux and the ancestry classifier would rightly reject it.
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || fail "a C compiler is required to build the fake agy process"
cat > "$TMP_ROOT/fake-agy.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int status;
  pid_t child;
  if (argc != 3 || strcmp(argv[1], "-c") != 0) return 64;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    execl("/bin/bash", "bash", "-c", argv[2], (char *)0);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 72;
}
C
"$CC_BIN" -o "$FAKEBIN/agy" "$TMP_ROOT/fake-agy.c" \
  || fail "could not build the fake agy process"
FAKE_AGY="$FAKEBIN/agy"

install_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs"
  for f in fm-turnend-guard-agy.sh fm-turnend-guard.sh fm-sessionstart-agy.sh \
           fm-sessionstart-run.sh fm-sessionstart-nudge.sh fm-arm-pretool-check.sh \
           fm-cd-pretool-check.sh fm-hook-host-lib.sh fm-agy-trust.sh \
           fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh fm-path-lib.sh \
           fm-session-lock-lib.sh fm-cursor-lib.sh fm-operational-input.sh \
           fm-supervision-instructions.sh fm-harness.sh fm-lock.sh \
           fm-gate-refuse-lib.sh fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh \
           fm-supervision-engine-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir"/bin/*.sh
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# An arm fixture standing in for bin/fm-watch-arm.sh. Real process, real output.
write_arm_fixture() {  # <dir> <kind>
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win needs a look\n'
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    switchable)
      # Slow until state/arm-fast appears, so a second invocation can be made
      # fast WITHOUT rewriting a script the first one is still executing.
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
if [ -e "$FM_HOME/state/arm-fast" ]; then
  printf 'stale: fixture-win fast\n'
  exit 0
fi
sleep 30
printf 'stale: fixture-win late\n'
exit 0
SH
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# The park's child body: claim the home lock as this fake harness process, then
# run the adapter as its child, so the real agy ancestry path decides lock
# ownership on every platform. Keep the fake harness process alive: Linux
# changes the process identity when an exec reaches the adapter's shebang.
PARK_CHILD='
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  "$FM_HOME/bin/fm-turnend-guard-agy.sh"
'

agy_stop_payload() {  # <exec-num> <reason> <fully-idle>
  printf '{"artifactDirectoryPath":"/x","conversationId":"conv-agy","error":"","executionNum":%s,"fullyIdle":%s,"lastUserInput":"hi","modelName":"gemini-3.8-flash-low","terminationReason":"%s","transcriptPath":"/x/t.jsonl","workspacePaths":["/w"]}' "$1" "$3" "$2"
}

# Run the park as a child of the fake agy harness that holds the home lock.
# Tunables arrive as T_* variables so each test names only what it changes.
run_park() {  # <dir>
  local dir=$1 payload
  payload=$(agy_stop_payload "${T_EXEC:-0}" "${T_REASON:-NO_TOOL_CALL}" "${T_IDLE:-true}")
  printf '%s' "$payload" | env FM_HOME="$dir" FM_AGY_PARK_POLL=1 \
    ${T_CEILING:+FM_AGY_TURNEND_LOOP_CEILING=$T_CEILING} \
    ${T_PARK_SECONDS:+FM_AGY_PARK_SECONDS=$T_PARK_SECONDS} \
    "$FAKE_AGY" -c "$PARK_CHILD" 2>/dev/null
}

decision_of() {  # <json>
  printf '%s' "$1" | jq -r '.decision // empty' 2>/dev/null
}

reason_of() {  # <json>
  printf '%s' "$1" | jq -r '.reason // empty' 2>/dev/null
}

kind_of_continuation() {  # <json> -> the operational kind
  local body
  body=$(reason_of "$1")
  [ -n "$body" ] || return 1
  printf '%s' "$body" | "$ROOT/bin/fm-operational-input.sh" kind
}

expect_allow() {  # <json> <message>
  [ "$1" = '{}' ] || fail "$2, got: $1"
}

# --- PARK --------------------------------------------------------------------

test_park_allows_the_stop_when_nothing_in_flight() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-idle")
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir")
  expect_allow "$out" "the park must let the loop stop with nothing in flight"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed with nothing to supervise"
  pass "agy park: the stop is allowed with {} when no supervision is needed"
}

test_park_delivers_actionable_wake_as_continuation() {
  local dir out body
  dir=$(make_primary_dir "$TMP_ROOT/park-wake")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir")
  [ -e "$dir/state/arm-ran" ] || fail "the park did not run the arm"
  [ "$(decision_of "$out")" = continue ] || fail "a wake must block the stop with a continue decision, got: $out"
  [ "$(kind_of_continuation "$out")" = watcher ] \
    || fail "an actionable close must arrive as a watcher-kind continuation, got: $out"
  body=$(reason_of "$out")
  case "$body" in *'stale: fixture-win needs a look'*) ;; *) fail "the wake reason was not carried into the continuation: $body" ;; esac
  case "$body" in *'fm-wake-drain.sh'*) ;; *) fail "the continuation must tell the session to drain first: $body" ;; esac
  pass "agy park: an actionable close is delivered as one watcher-kind continuation"
}

test_park_always_exits_zero() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/park-exit")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  run_park "$dir" >/dev/null; status=$?
  expect_code 0 "$status" "the agy adapter's only channel is its stdout object, so it must exit 0"
  pass "agy park: always exits 0, even when supervision is genuinely down"
}

test_park_leaves_non_turn_end_stops_alone() {
  local dir out reason idle
  dir=$(make_primary_dir "$TMP_ROOT/park-untouched")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  for reason in USER_CANCELED ERROR MAX_INVOCATIONS MAX_FORCED_INVOCATIONS TERMINAL_CUSTOM_HOOK; do
    out=$(T_REASON=$reason run_park "$dir")
    expect_allow "$out" "a $reason stop must be handed back untouched"
  done
  idle=$(T_IDLE=false run_park "$dir")
  expect_allow "$idle" "a stop with background work still running is not yet a turn end"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed on a stop that is not a turn end"
  pass "agy park: a cancel, an error, a limit, and a not-idle stop are never argued with"
}

test_park_repair_nag_is_bounded() {
  local dir out i
  dir=$(make_primary_dir "$TMP_ROOT/park-nag")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  for i in 1 2 3; do
    out=$(run_park "$dir")
    [ "$(decision_of "$out")" = continue ] || fail "nag $i should block the stop, got: $out"
    [ "$(kind_of_continuation "$out")" = turn-end-guard ] \
      || fail "nag $i should be a turn-end-guard continuation, got: $out"
  done
  out=$(run_park "$dir")
  expect_allow "$out" "the repair nag must stop after its budget"
  pass "agy park: the repair nag is bounded and then goes quiet"
}

test_park_repair_nag_requires_a_persisted_budget() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-nag-write-failure")
  : > "$dir/state/task1.meta"
  mkdir "$dir/state/.turnend-agy-blocks"
  write_arm_fixture "$dir" failed
  out=$(run_park "$dir")
  expect_allow "$out" "a repair nag without a persisted budget increment must fail open"
  pass "agy park: a repair nag is emitted only after its budget persists"
}

test_park_nag_budget_resets_after_a_real_wake() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-nag-reset")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" failed
  run_park "$dir" >/dev/null
  run_park "$dir" >/dev/null
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir")
  [ "$(kind_of_continuation "$out")" = watcher ] || fail "expected a real wake, got: $out"
  write_arm_fixture "$dir" failed
  out=$(run_park "$dir")
  [ "$(kind_of_continuation "$out")" = turn-end-guard ] \
    || fail "a productive wake must reset the nag budget, got: $out"
  pass "agy park: a delivered wake resets the bounded repair budget"
}

test_park_loop_ceiling_warns_once_then_goes_quiet() {
  local dir out body
  dir=$(make_primary_dir "$TMP_ROOT/park-ceiling")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  out=$(T_EXEC=5 T_CEILING=5 run_park "$dir")
  body=$(reason_of "$out")
  case "$body" in *'CEILING REACHED'*) ;; *) fail "at the ceiling the session must be told once, got: $out" ;; esac
  [ ! -e "$dir/state/arm-ran" ] || fail "the park must not arm at the loop ceiling"
  out=$(T_EXEC=6 T_CEILING=5 run_park "$dir")
  expect_allow "$out" "above the ceiling the adapter must let the loop stop"
  pass "agy park: the executionNum ceiling warns exactly once, then stops the loop"
}

test_default_ceiling_bites_before_agys_own_chain_limit() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-default-ceiling")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  # agy ends a forced-continuation chain after executionNum 10 (measured live,
  # docs/verification/agy.md), so the default must warn at a lower number.
  out=$(T_EXEC=8 run_park "$dir")
  case "$(reason_of "$out")" in *'CEILING REACHED'*) ;; *) fail "the default ceiling must be reached by executionNum 8, got: $out" ;; esac
  out=$(T_EXEC=7 run_park "$dir")
  case "$(reason_of "$out")" in *'stale: fixture-win needs a look'*) ;; *) fail "executionNum 7 is still an ordinary wake, got: $out" ;; esac
  pass "agy park: the default ceiling sits below agy's own ten-continuation chain limit"
}

test_park_window_ends_in_a_bounded_checkpoint() {
  local dir out body
  dir=$(make_primary_dir "$TMP_ROOT/park-window")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" switchable
  out=$(T_PARK_SECONDS=2 run_park "$dir")
  [ "$(decision_of "$out")" = continue ] || fail "an elapsed park window must hand back a checkpoint, got: $out"
  [ "$(kind_of_continuation "$out")" = watcher ] || fail "the checkpoint must be a watcher-kind continuation, got: $out"
  body=$(reason_of "$out")
  case "$body" in *'checkpoint'*'fm-wake-drain.sh'*) ;; *) fail "the checkpoint must tell the session to drain and end its turn: $body" ;; esac
  case "$body" in *'stale: fixture-win'*) fail "a checkpoint must not pretend a wake arrived: $body" ;; esac
  pass "agy park: an elapsed park window ends in a bounded checkpoint continuation inside the hook timeout"
}

test_park_stands_down_when_superseded() {
  local dir first_out first_pid marker waited=0
  dir=$(make_primary_dir "$TMP_ROOT/park-supersede")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" switchable
  marker="$dir/state/first-park-out"
  ( run_park "$dir" > "$marker" 2>/dev/null ) &
  first_pid=$!
  while [ ! -s "$dir/state/.agy-park-owner" ] || [ ! -e "$dir/state/arm-ran" ]; do
    sleep 0.2
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || fail "the first park never claimed ownership"
  done
  : > "$dir/state/arm-fast"
  run_park "$dir" >/dev/null 2>&1
  wait "$first_pid" 2>/dev/null || true
  first_out=$(cat "$marker" 2>/dev/null || true)
  case "$first_out" in ''|'{}') ;; *) fail "the older park delivered after the newer stop claimed the baton: $first_out" ;; esac
  pass "agy park: an older park stands down after a newer stop claim"
}

test_park_inert_when_afk() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-afk")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  out=$(run_park "$dir")
  expect_allow "$out" "away mode owns supervision; the park must not wake the primary"
  [ ! -e "$dir/state/arm-ran" ] || fail "the park armed while the away daemon owns the watcher"
  pass "agy park: inert while away mode is active"
}

test_park_inert_without_session_lock() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-no-lock")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  # No harness process holds the home lock for this invocation, so it is not the
  # owning session and must neither arm nor wake.
  out=$(agy_stop_payload 0 NO_TOOL_CALL true | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard-agy.sh" 2>/dev/null)
  expect_allow "$out" "a session that does not hold the home lock must not arm or wake"
  [ ! -e "$dir/state/arm-ran" ] || fail "a read-only session armed the watcher"
  pass "agy park: inert without session-lock ownership"
}

test_park_inert_in_child_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/park-base")
  child="$TMP_ROOT/park-child"
  fm_git_worktree "$base" "$child" fm/agy-park-child
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  install_scripts "$child"
  : > "$child/state/task1.meta"
  write_arm_fixture "$child" actionable
  out=$(run_park "$child")
  expect_allow "$out" "a crewmate worktree must stay outside primary scope"
  pass "agy park: inert inside a child crewmate worktree"
}

test_park_ignores_malformed_payload() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/park-malformed")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  out=$(printf 'not json at all' | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard-agy.sh" 2>/dev/null)
  expect_allow "$out" "a malformed payload must fail open"
  out=$(printf '{"executionNum":"three","terminationReason":"NO_TOOL_CALL"}' | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard-agy.sh" 2>/dev/null)
  expect_allow "$out" "a non-numeric executionNum must fail open"
  out=$(printf '' | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard-agy.sh" 2>/dev/null)
  expect_allow "$out" "an empty payload must fail open"
  [ ! -e "$dir/state/arm-ran" ] || fail "a malformed payload armed the watcher"
  pass "agy park: malformed payloads fail open without arming"
}

# --- SESSION -----------------------------------------------------------------

install_digest_fixture() {  # <dir>
  cat > "$1/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/state/digest-args"
printf 'FIRSTMATE DIGEST "quoted" line\nsecond line\n'
SH
  chmod +x "$1/bin/fm-session-start.sh"
}

test_sessionstart_injects_the_digest_as_a_system_message() {
  local dir out ctx
  dir=$(make_primary_dir "$TMP_ROOT/session-start")
  install_digest_fixture "$dir"
  out=$(printf '%s' '{"conversationId":"conv-agy","modelName":"m","workspacePaths":["/w"]}' \
    | FM_HOME="$dir" "$FAKE_AGY" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$FM_HOME/bin/fm-sessionstart-agy.sh" --source startup
    ' 2>/dev/null)
  ctx=$(printf '%s' "$out" | jq -r '.injectSteps[0].systemMessage.systemMessage // empty' 2>/dev/null)
  case "$ctx" in *'FIRSTMATE DIGEST "quoted" line'*) ;; *) fail "the digest must reach model context verbatim, got: $out" ;; esac
  case "$ctx" in *'second line'*) ;; *) fail "the digest was truncated at the first line: $ctx" ;; esac
  grep -q -- '--source startup' "$dir/state/digest-args" \
    || fail "the adapter must supply --source itself; agy's payload has no source field"
  pass "fm-sessionstart-agy: SessionStart injects the digest as a systemMessage step"
}

test_sessionstart_is_a_no_op_in_a_child_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/session-base")
  child="$TMP_ROOT/session-child"
  fm_git_worktree "$base" "$child" fm/agy-session-child
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  install_scripts "$child"
  install_digest_fixture "$child"
  out=$(printf '{"conversationId":"c"}' | FM_HOME="$child" bash "$child/bin/fm-sessionstart-agy.sh" --source startup 2>/dev/null)
  expect_allow "$out" "a child worktree must never take the helm"
  [ ! -e "$child/state/digest-args" ] || fail "a child worktree ran the session-start digest"
  pass "fm-sessionstart-agy: {} and no digest inside a child worktree"
}

# --- PRETOOL -----------------------------------------------------------------

agy_tool_payload() {  # <command>
  jq -cn --arg c "$1" '{toolCall:{name:"run_command",args:{CommandLine:$c,WaitMsBeforeAsync:5000}},stepIdx:3,conversationId:"conv-agy"}'
}

test_arm_seatbelt_renders_agy_deny_and_allows_the_rest() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/pretool-arm")
  out=$(agy_tool_payload 'bin/fm-watch-arm.sh &' | bash "$dir/bin/fm-arm-pretool-check.sh" --agy 2>/dev/null); status=$?
  expect_code 0 "$status" "agy reads the returned object, so the deny path exits 0"
  [ "$(decision_of "$out")" = deny ] || fail "expected an agy deny object on stdout, got: $out"
  printf '%s' "$out" | jq -e '.reason | type == "string" and length > 0' >/dev/null 2>&1 \
    || fail "agy's deny object must carry a reason, got: $out"
  out=$(agy_tool_payload 'ls -la' | bash "$dir/bin/fm-arm-pretool-check.sh" --agy 2>&1); status=$?
  expect_code 0 "$status" "an ordinary command must be allowed"
  [ -z "$out" ] || fail "an allowed command produced output: $out"
  pass "fm-arm-pretool-check: --agy reads toolCall.args.CommandLine and denies in agy's shape"
}

test_cd_seatbelt_renders_agy_deny() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/pretool-cd")
  out=$(agy_tool_payload 'cd projects/example' | FM_HOME="$dir" bash "$dir/bin/fm-cd-pretool-check.sh" --agy 2>/dev/null); status=$?
  expect_code 0 "$status" "agy reads the returned object, so the deny path exits 0"
  [ "$(decision_of "$out")" = deny ] || fail "expected an agy deny object from the cd guard, got: $out"
  out=$(agy_tool_payload 'ls projects' | FM_HOME="$dir" bash "$dir/bin/fm-cd-pretool-check.sh" --agy 2>&1)
  [ -z "$out" ] || fail "an allowed command produced output: $out"
  pass "fm-cd-pretool-check: --agy denies a persistent cwd change in agy's shape"
}

# --- REGISTRATION ------------------------------------------------------------

test_tracked_registration_resolves_to_the_adapters() {
  local reg=$ROOT/.agents/hooks.json cmd script
  [ -f "$reg" ] || fail "the tracked agy hook registration is missing"
  jq -e 'type == "object" and length > 0' "$reg" >/dev/null 2>&1 || fail ".agents/hooks.json is not a named-hook object"
  # agy's complete event vocabulary (agy plugin validate, 1.4.7).
  jq -e '[.[] | keys[]] | all(. as $e | ["SessionStart","PreInvocation","PostInvocation","Stop","PreToolUse","PostToolUse","enabled"] | index($e))' "$reg" >/dev/null 2>&1 \
    || fail "the registration names an event agy would ignore"
  for event in SessionStart Stop PreToolUse; do
    jq -e --arg e "$event" '[.[] | .[$e] // empty] | length > 0' "$reg" >/dev/null 2>&1 \
      || fail "the registration lacks a $event hook"
  done
  # Handlers are flat for SessionStart and Stop and grouped (matcher + hooks)
  # for PreToolUse; every command runs with .agents/ as its cwd.
  jq -r '.[] | ((.SessionStart[]?, .Stop[]?) | .command), (.PreToolUse[]? | .hooks[].command)' "$reg" | while IFS= read -r cmd; do
    script=${cmd%% *}
    [ -x "$ROOT/.agents/$script" ] || fail "registered command '$cmd' does not resolve to an executable from .agents/"
  done
  jq -e '[.[] | .Stop[]? | .timeout] | all(. >= 3600)' "$reg" >/dev/null 2>&1 \
    || fail "the Stop hook's timeout must exceed the park window or agy kills the park and the stop proceeds"
  jq -e '[.[] | .PreToolUse[]? | .matcher] | all(. == "run_command")' "$reg" >/dev/null 2>&1 \
    || fail "the seatbelts must match agy's run_command tool"
  pass "the tracked .agents/hooks.json resolves every registered event to a real adapter"
}

# --- WIRING ------------------------------------------------------------------

test_protocol_block_renders_for_agy() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/wiring-protocol")
  out=$(bash "$dir/bin/fm-supervision-instructions.sh" --harness agy)
  case "$out" in *'primary harness: agy'*) ;; *) fail "the block must name agy, got: $out" ;; esac
  case "$out" in *'Mode: agy'*'Stop-hook-owned park'*) ;; *) fail "the agy protocol snippet did not render: $out" ;; esac
  case "$out" in *'Ordinary wake: the Stop-hook park'*) ;; *) fail "the ordinary-wake line must name the Stop-hook park: $out" ;; esac
  case "$out" in *'Mode: Unknown harness fallback'*) fail "agy must no longer fall to the unknown-harness fallback" ;; esac
  out=$(bash "$dir/bin/fm-supervision-instructions.sh" --harness agy --repair-line)
  case "$out" in *'fm-turnend-guard-agy.sh'*) ;; *) fail "the repair line must name the agy park: $out" ;; esac
  pass "fm-supervision-instructions: agy renders its own protocol and repair line"
}

test_supervision_model_is_between_turns_for_agy() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/wiring-model")
  out=$(FM_HOME="$dir" "$FAKE_AGY" -c '. "$FM_HOME/bin/fm-wake-lib.sh"; fm_supervision_model' 2>/dev/null)
  [ "$out" = autoarm ] || fail "an agy park arms between turns like Cursor's, so its model is autoarm, got: $out"
  pass "fm_supervision_model: agy is classified as the between-turns autoarm model"
}

make_secondmate_home() {  # <dir> <id>
  local dir=$1 id=$2
  mkdir -p "$dir/bin" "$dir/data"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  printf '%s' "$id" > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

test_agy_trust_pre_registers_a_seeded_secondmate_home() {
  local home dir out store
  home="$TMP_ROOT/trust-home"
  mkdir -p "$home"
  dir=$(make_secondmate_home "$TMP_ROOT/trust-sm" sm-one)
  out=$(HOME="$home" bash "$ROOT/bin/fm-agy-trust.sh" --secondmate-home "$dir" sm-one 2>&1) \
    || fail "a seeded secondmate home must be accepted: $out"
  store=$home/.gemini/antigravity-cli/settings.json
  jq -e --arg d "$(cd "$dir" && pwd -P)" '.trustedWorkspaces | index($d) != null' "$store" >/dev/null 2>&1 \
    || fail "the home was not recorded in agy's trust store: $(cat "$store" 2>/dev/null)"
  pass "fm-agy-trust.sh: --secondmate-home records a seeded home"
}

test_agy_trust_refuses_an_unseeded_secondmate_home() {
  local home dir out
  home="$TMP_ROOT/trust-refuse-home"
  mkdir -p "$home"
  dir=$(make_secondmate_home "$TMP_ROOT/trust-wrong-id" sm-one)
  out=$(HOME="$home" bash "$ROOT/bin/fm-agy-trust.sh" --secondmate-home "$dir" sm-two 2>&1) \
    && fail "a home marked for another secondmate must be refused"
  assert_contains "$out" "marked for secondmate" "the wrong-id refusal lacked its reason"
  mkdir -p "$TMP_ROOT/trust-plain"
  out=$(HOME="$home" bash "$ROOT/bin/fm-agy-trust.sh" --secondmate-home "$TMP_ROOT/trust-plain" sm-one 2>&1) \
    && fail "a plain directory must be refused"
  assert_contains "$out" "no .fm-secondmate-home marker" "the plain-directory refusal lacked its reason"
  dir=$(make_secondmate_home "$TMP_ROOT/trust-link" sm-one)
  rm "$dir/.fm-secondmate-home"
  printf 'sm-one' > "$TMP_ROOT/trust-link-target"
  ln -s "$TMP_ROOT/trust-link-target" "$dir/.fm-secondmate-home"
  out=$(HOME="$home" bash "$ROOT/bin/fm-agy-trust.sh" --secondmate-home "$dir" sm-one 2>&1) \
    && fail "a symlinked marker must be refused"
  assert_contains "$out" "symlink" "the symlink refusal lacked its reason"
  [ ! -e "$home/.gemini/antigravity-cli/settings.json" ] || fail "a refusal still wrote the trust store"
  pass "fm-agy-trust.sh: --secondmate-home refuses a wrong id, a plain directory, and a symlinked marker"
}

test_park_allows_the_stop_when_nothing_in_flight
test_park_delivers_actionable_wake_as_continuation
test_park_always_exits_zero
test_park_leaves_non_turn_end_stops_alone
test_park_repair_nag_is_bounded
test_park_repair_nag_requires_a_persisted_budget
test_park_nag_budget_resets_after_a_real_wake
test_park_loop_ceiling_warns_once_then_goes_quiet
test_default_ceiling_bites_before_agys_own_chain_limit
test_park_window_ends_in_a_bounded_checkpoint
test_park_stands_down_when_superseded
test_park_inert_when_afk
test_park_inert_without_session_lock
test_park_inert_in_child_worktree
test_park_ignores_malformed_payload
test_sessionstart_injects_the_digest_as_a_system_message
test_sessionstart_is_a_no_op_in_a_child_worktree
test_arm_seatbelt_renders_agy_deny_and_allows_the_rest
test_cd_seatbelt_renders_agy_deny
test_tracked_registration_resolves_to_the_adapters
test_protocol_block_renders_for_agy
test_supervision_model_is_between_turns_for_agy
test_agy_trust_pre_registers_a_seeded_secondmate_home
test_agy_trust_refuses_an_unseeded_secondmate_home
