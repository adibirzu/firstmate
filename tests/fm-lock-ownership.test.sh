#!/usr/bin/env bash
# tests/fm-lock-ownership.test.sh - session-exclusive fleet-lock ownership.
#
# Each case invokes bin/fm-lock.sh rather than its sourced implementation.
# The fake process table models a live Claude session and a reparented shared
# worker pool, while real sleepers make the holder-liveness checks meaningful.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-ownership)
PIDS=

reap() {
  local pid
  for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}
trap reap EXIT

spawn_live_pid() {
  sleep 300 >/dev/null 2>&1 &
  LIVE_PID=$!
  PIDS="$PIDS $LIVE_PID"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_ps() {  # <fakebin> <mode> <session-pid> <sibling-pid> <spare-pid> <host-pid>
  cat > "$1/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\${FM_LOCK_TEST_MODE}:\$pid:\$field" in
  *:$3:comm=|*:$4:comm=) printf '%s\n' claude ;;
  *:$3:args=|*:$4:args=) printf '%s\n' 'claude --dangerously-skip-permissions' ;;
  *:$3:ppid=|*:$4:ppid=) printf '%s\n' 1 ;;
  pool:$5:comm=) printf '%s\n' 'claude bg-spare' ;;
  pool:$5:args=) printf '%s\n' 'claude bg-spare --bg-spare /tmp/cc/spare.sock' ;;
  pool:$5:ppid=) printf '%s\n' $6 ;;
  pool:$6:comm=) printf '%s\n' 'claude bg-pty-host' ;;
  pool:$6:args=) printf '%s\n' 'claude bg-pty-host --bg-pty-host /tmp/cc/pty.sock' ;;
  pool:$6:ppid=) printf '%s\n' 1 ;;
  direct:*:comm=) printf '%s\n' bash ;;
  direct:*:args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  direct:*:ppid=) printf '%s\n' $3 ;;
  pool:*:comm=) printf '%s\n' bash ;;
  pool:*:args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  pool:*:ppid=) printf '%s\n' $5 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$1/ps"
}

run_lock() {  # <home> <fakebin> <mode> <session-id> <claude-pid>
  FM_LOCK_TEST_MODE=$3 CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=$4 CLAUDE_PID=$5 \
    FM_HOME=$1 FM_STATE_OVERRIDE="$1/state" PATH="$2:$PATH" \
    bash "$ROOT/bin/fm-lock.sh" 2>&1
}

test_new_lock_excludes_a_pool_sibling_and_readmits_its_owner() {
  local home fakebin session sibling spare host out
  home=$(make_home new-lock)
  fakebin=$(fm_fakebin "$home/bin")
  spawn_live_pid; session=$LIVE_PID
  spawn_live_pid; sibling=$LIVE_PID
  spawn_live_pid; spare=$LIVE_PID
  spawn_live_pid; host=$LIVE_PID
  write_ps "$fakebin" ignored "$session" "$sibling" "$spare" "$host"

  out=$(run_lock "$home" "$fakebin" direct owner-session "$session") \
    || fail "new lock acquisition failed: $out"
  [ "$(tr -d '[:space:]' < "$home/state/.lock")" = "$session" ] \
    || fail "new lock did not record the session pid"
  [ "$(cat "$home/state/.lock.session")" = "$(printf 'format=1\nkind=claude\npid=%s\nsession=owner-session' "$session")" ] \
    || fail "new lock did not write its complete session binding"

  out=$(run_lock "$home" "$fakebin" pool owner-session "$session") \
    || fail "owner was refused after its call moved to the reparented pool: $out"
  case "$out" in *"lock acquired: harness pid $session"*) ;; *) fail "owner re-entry did not report its original lock: $out" ;; esac

  out=$(run_lock "$home" "$fakebin" pool sibling-session "$sibling") \
    && fail "a sibling session acquired the owner's new-format lock: $out"
  case "$out" in *"another live firstmate session holds the lock (pid $session)"*) ;; *) fail "sibling refusal was not explicit: $out" ;; esac
  pass "fm-lock: a new session binding readmits its owner and rejects a sibling in the same pool"
}

test_legacy_pool_lock_is_logged_when_temporarily_accepted() {
  local home fakebin session sibling spare host out log
  home=$(make_home legacy-lock)
  fakebin=$(fm_fakebin "$home/bin")
  spawn_live_pid; session=$LIVE_PID
  spawn_live_pid; sibling=$LIVE_PID
  spawn_live_pid; spare=$LIVE_PID
  spawn_live_pid; host=$LIVE_PID
  write_ps "$fakebin" ignored "$session" "$sibling" "$spare" "$host"
  printf '%s\n' "$host" > "$home/state/.lock"

  out=$(run_lock "$home" "$fakebin" pool owner-session "$session") \
    || fail "a live legacy pool lock was not temporarily accepted: $out"
  log=$(cat "$home/state/.lock.legacy.log" 2>/dev/null || true)
  case "$log" in *"legacy session lock accepted: home="*" pid=$host"*) ;; *) fail "legacy acceptance was not logged with home and pid: $log" ;; esac
  [ ! -e "$home/state/.lock.session" ] || fail "legacy acceptance rewrote a lock without a new acquisition"
  pass "fm-lock: legacy shared-pool ownership is accepted only visibly during migration"
}

test_unidentifiable_claude_session_cannot_use_legacy_compatibility() {
  local home fakebin session sibling spare host out
  home=$(make_home unidentifiable)
  fakebin=$(fm_fakebin "$home/bin")
  spawn_live_pid; session=$LIVE_PID
  spawn_live_pid; sibling=$LIVE_PID
  spawn_live_pid; spare=$LIVE_PID
  spawn_live_pid; host=$LIVE_PID
  write_ps "$fakebin" ignored "$session" "$sibling" "$spare" "$host"
  printf '%s\n' "$host" > "$home/state/.lock"

  out=$(FM_LOCK_TEST_MODE=pool CLAUDECODE=1 CLAUDE_PID=$session FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" bash "$ROOT/bin/fm-lock.sh" 2>&1) \
    && fail "an unidentifiable session fell through to legacy compatibility: $out"
  case "$out" in *"cannot establish this session's lock identity"*) ;; *) fail "identity refusal was not explicit: $out" ;; esac
  [ "$(tr -d '[:space:]' < "$home/state/.lock")" = "$host" ] \
    || fail "the unidentifiable session changed the legacy lock"
  [ ! -e "$home/state/.lock.session" ] || fail "the unidentifiable session wrote a new-format binding"
  pass "fm-lock: an unidentifiable new Claude acquisition refuses without legacy fallback"
}

test_new_lock_excludes_a_pool_sibling_and_readmits_its_owner
test_legacy_pool_lock_is_logged_when_temporarily_accepted
test_unidentifiable_claude_session_cannot_use_legacy_compatibility
