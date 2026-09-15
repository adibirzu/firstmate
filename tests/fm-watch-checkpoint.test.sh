#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_rearm_resurface_is_absorbed_and_holds_budget() {
  local home out err status start end elapsed
  home=$(make_home rearm-absorbed)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'x\n' > "$home/state/demo.meta"
  append_wake "$home/state" check drain-test 'synthetic durable wake' \
    || fail "could not seed durable wake"
  status=0
  start=$(date +%s)
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 3 >"$out" 2>"$err" || status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 124 "$status" "rearm-absorbed checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 3s" "absorbed checkpoint line missing"
  if grep -F 'rearm-resurface' "$out" >/dev/null; then
    fail "internal rearm wake leaked into checkpoint output: $(cat "$out")"
  fi
  assert_contains "$(cat "$err")" "absorbed" "absorbed rearm note missing from stderr"
  [ "$elapsed" -ge 2 ] || fail "checkpoint exited after ${elapsed}s instead of holding the 3s budget"
  grep -F 'drain-test' "$home/state/.wake-queue" >/dev/null \
    || fail "durable wake was consumed instead of preserved for drain"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived absorbed checkpoint"
  pass "checkpoint absorbs internal rearm-resurface, holds the full budget, and preserves the queue for drain"
}

test_chained_checkpoint_without_new_work_holds_budget() {
  local home out err status start end elapsed
  home=$(make_home chained-quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'x\n' > "$home/state/demo.meta"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 2 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "first chained checkpoint exit"
  status=0
  start=$(date +%s)
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 2 >"$out" 2>"$err" || status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 124 "$status" "second chained checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 2s" "chained checkpoint line missing"
  if grep -F 'rearm-resurface' "$out" >/dev/null; then
    fail "internal rearm wake leaked into chained checkpoint output: $(cat "$out")"
  fi
  [ "$elapsed" -ge 1 ] || fail "chained checkpoint exited after ${elapsed}s instead of holding the 2s budget"
  pass "a chained checkpoint with no new work holds the full budget instead of exiting on the recovery echo"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_rearm_resurface_is_absorbed_and_holds_budget
test_chained_checkpoint_without_new_work_holds_budget
