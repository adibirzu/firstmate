#!/usr/bin/env bash
# tests/fm-watch-bounded-waits.test.sh - one hung call inside the poll loop must
# cost only its own bound, never the watcher's liveness beacon.
#
# Field evidence: bin/fm-watch.sh wedged three times in a day, alive in state S
# with .last-watcher-beat 7-18 minutes stale, until the stuck pid was killed by
# hand. One wedge was a child bin/fm-crew-state.sh that never returned; the
# others had no child at all, which is the shape of an in-process wait (a lock
# held by a live but hung process, polled with sleep 0.1 forever). These cases
# pin the bounds that keep the loop beating:
#   T1 a hung fm-crew-state.sh read degrades to the surfacing verdict ("none")
#      after FM_CREW_STATE_TIMEOUT and the hung reader is reaped;
#   T2 fm_lock_acquire_wait honours the unexported FM_LOCK_WAIT_MAX_SECONDS cap
#      behind a live foreign holder, and stays uncapped when the cap is unset;
#   T3 a real watcher whose wake-queue lock is held by a live foreign process
#      keeps its beacon fresh and keeps polling instead of spinning on the lock.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-bounded-waits)

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# run_guarded <secs> <outfile> <cmd...>: run the command, give up on it after
# <secs>, and report 99 for a call that had to be abandoned so a regression
# fails this suite instead of hanging it.
run_guarded() {
  local secs=$1 out=$2 pid i=0 limit
  shift 2
  "$@" > "$out" 2>&1 &
  pid=$!
  limit=$(( secs * 10 ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$limit" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 99
    fi
    sleep 0.1
    i=$(( i + 1 ))
  done
  wait "$pid"
}

# T1: a hung crew-state read is bounded and reaped.
test_hung_crew_state_read_is_bounded() {
  local dir stub pidfile hung_pid rc
  dir="$TMP_ROOT/crew-state"
  mkdir -p "$dir"
  stub="$dir/crew-state-stub"
  pidfile="$dir/stub.pid"
  cat > "$stub" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$pidfile"
sleep 60
SH
  chmod +x "$stub"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  run_guarded 12 "$dir/out" env FM_CREW_STATE_BIN="$stub" FM_CREW_STATE_TIMEOUT=1 \
    bash -c '. "$1/fm-classify-lib.sh"; crew_absorb_class t1' _ "$ROOT/bin"
  rc=$?
  [ "$rc" -ne 99 ] || fail "T1: a hung fm-crew-state.sh read was never bounded (crew_absorb_class blocked)"
  [ "$rc" -eq 0 ] || fail "T1: crew_absorb_class failed after a timed-out read (rc=$rc)"
  [ "$(cat "$dir/out")" = none ] \
    || fail "T1: a timed-out read must degrade to the surfacing verdict 'none', got: $(cat "$dir/out")"
  [ -s "$pidfile" ] || fail "T1: the stub reader never ran (vacuous case)"
  hung_pid=$(cat "$pidfile")
  sleep 0.5
  ! kill -0 "$hung_pid" 2>/dev/null \
    || fail "T1: the timed-out reader (pid $hung_pid) outlived its bound"
  pass "T1 hung crew-state read: bounded, degraded to 'none', reaped"
}

# hold_lock <lockdir> <pidfile>: a live process that owns <lockdir> and never
# releases it, standing in for a hung helper that holds a shared queue lock.
hold_lock() {
  local lockdir=$1 pidfile=$2 i=0
  bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1; printf "%s\n" "$$" > "$3"; exec sleep 30' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$lockdir" "$pidfile" &
  while [ ! -s "$pidfile" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$(( i + 1 ))
  done
  [ -s "$pidfile" ] || fail "could not start a live foreign lock holder"
}

# T2: the in-process lock wait honours its cap.
test_lock_wait_cap() {
  local dir lock holder rc started elapsed
  dir="$TMP_ROOT/lock-cap"
  mkdir -p "$dir/state"
  lock="$dir/state/.cap.lock"
  hold_lock "$lock" "$dir/holder.pid"
  holder=$(cat "$dir/holder.pid")
  started=$(date +%s)
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  run_guarded 15 "$dir/capped.out" env FM_STATE_OVERRIDE="$dir/state" \
    bash -c '. "$1"; FM_LOCK_WAIT_MAX_SECONDS=1; fm_lock_acquire_wait "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$lock"
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -ne 99 ] || fail "T2: fm_lock_acquire_wait ignored FM_LOCK_WAIT_MAX_SECONDS behind a live holder"
  [ "$rc" -eq 1 ] || fail "T2: a capped wait that timed out must return 1, got $rc"
  [ "$elapsed" -lt 8 ] || fail "T2: the capped wait took ${elapsed}s for a 1s cap"
  kill -0 "$holder" 2>/dev/null || fail "T2: the cap must not disturb the live holder"
  # Uncapped (the default for every mutation-critical caller) still waits: it
  # must not give up inside a short window while the holder lives.
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  run_guarded 3 "$dir/uncapped.out" env FM_STATE_OVERRIDE="$dir/state" \
    bash -c '. "$1"; fm_lock_acquire_wait "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$lock"
  rc=$?
  [ "$rc" -eq 99 ] || fail "T2: an uncapped wait behind a live holder returned early (rc=$rc)"
  kill -TERM "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "T2 lock wait: capped wait gives up at its bound, uncapped wait is unchanged"
}

# T3: a watcher behind a held wake-queue lock keeps beating.
# A non-empty queue makes every poll take the wake-queue lock. With a live
# foreign holder that never lets go, an unbounded wait strands the loop inside
# the first poll and the beacon ages without limit.
test_watcher_beats_behind_held_queue_lock() {
  local dir state watcher m now age max_age=0 i
  dir="$TMP_ROOT/held-queue-lock"
  state="$dir/state"
  mkdir -p "$state"
  FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=999999 FM_GUARD_GRACE=9 FM_WATCHER_BEAT_SUBCADENCE=1 \
    FM_WATCHER_LOCK_WAIT_MAX=1 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  watcher=$!
  i=0
  while [ ! -e "$state/.last-watcher-beat" ] && [ "$i" -lt 400 ]; do
    sleep 0.1
    i=$(( i + 1 ))
  done
  [ -e "$state/.last-watcher-beat" ] || fail "T3: the watcher never wrote a beacon"
  # Seed after startup: arming itself takes the queue lock, and this case is
  # about a poll that meets a lock held for good.
  append_wake "$state" check "stub:held" "check: stub held row" \
    || fail "T3: could not seed the wake queue"
  hold_lock "$state/.wake-queue.lock" "$dir/holder.pid"
  i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$watcher" 2>/dev/null || fail "T3: the watcher exited behind a held queue lock"
    m=$(file_mtime "$state/.last-watcher-beat")
    now=$(date +%s)
    age=$(( now - m ))
    [ "$age" -le "$max_age" ] || max_age=$age
    sleep 0.2
    i=$(( i + 1 ))
  done
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  kill -TERM "$(cat "$dir/holder.pid")" 2>/dev/null || true
  [ "$max_age" -lt 6 ] \
    || fail "T3: the beacon aged ${max_age}s behind a held wake-queue lock (grace 9s): the loop is stuck waiting on the lock"
  pass "T3 held wake-queue lock: watcher kept polling, beacon stayed fresh (max age ${max_age}s)"
}

test_hung_crew_state_read_is_bounded
test_lock_wait_cap
test_watcher_beats_behind_held_queue_lock

exit 0
