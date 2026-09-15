#!/usr/bin/env bash
# tests/fm-watch-beacon.test.sh - the watcher liveness beacon cannot be starved
# by slow per-home probes, while a genuinely wedged watcher still reads stale.
#
# With a large registered fleet one poll cycle's inline per-home work - remote
# secondmate busy observations over SSH and the slow per-task check sweep - can
# outlast the guard's stale grace. The beacon used to be touched only at the top
# of the cycle, so the guard reported a watcher that was alive and still
# delivering as stale. bin/fm-watch.sh now re-beats the beacon at cycle stage
# boundaries once it has aged past FM_WATCHER_BEAT_SUBCADENCE, and each remote
# per-home read is bounded by FM_PENDING_REPLY_OBSERVE_TIMEOUT, so the gap
# between touches is bounded by one bounded probe instead of the whole cycle. A
# watcher wedged inside a single stage reaches no further boundary and still
# crosses the grace: only the false-stale-while-alive case changes.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pending-reply-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-beacon)

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# max_beat_age <state> <alive-pid> <secs> -> prints the largest observed
# .last-watcher-beat age while sampling every 0.2s. Returns 1 if <alive-pid>
# dies mid-sample: a watcher that exited on its own would otherwise "pass" by
# leaving a frozen beacon behind.
max_beat_age() {
  local state=$1 pid=$2 secs=$3
  local beat="$state/.last-watcher-beat"
  local samples=$(( secs * 5 )) i=0 m now age max_age=0
  while [ "$i" -lt "$samples" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    m=$(file_mtime "$beat")
    if [ -n "$m" ]; then
      now=$(date +%s)
      age=$(( now - m ))
      [ "$age" -le "$max_age" ] || max_age=$age
    fi
    sleep 0.2
    i=$(( i + 1 ))
  done
  printf '%s\n' "$max_age"
}

# T1: a slow per-home sweep must keep the beacon inside the grace.
# Three registered custom checks (the local, deterministic stand-in for the
# per-home station/PR-poll probes the sweep actually runs) each sleep past the
# margin between two touches. FM_CHECK_TIMEOUT exceeds the sleep so a check
# completes and prints nothing, so a live watcher that keeps cycling proves the
# sweep ran to completion without being starved.
test_slow_probe_sweep_keeps_beacon_fresh() {
  local dir state fakebin watcher max_age c waited
  dir="$TMP_ROOT/slow-sweep"
  state="$dir/state" fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin" "$dir/done"
  for c in stationA stationB stationC; do
    printf '#!/usr/bin/env bash\nsleep 4\ntouch "%s/done/%s"\n' "$dir" "$c" > "$state/$c.check.sh"
    chmod 700 "$state/$c.check.sh"
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" "$c" >/dev/null \
      || fail "T1: could not register the slow per-home probe $c"
  done
  # grace 9s, in-cycle beat sub-cadence 1s. One top-of-cycle touch alone ages
  # the beacon ~12s across this sweep (3 x 4s), past the 9s grace; beats between
  # checks must cap it near 4s.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=20 \
    FM_GUARD_GRACE=9 FM_WATCHER_BEAT_SUBCADENCE=1 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  watcher=$!
  max_age=$(max_beat_age "$state" "$watcher" 14) \
    || fail "T1: the watcher exited during the slow per-home sweep"
  [ "$max_age" -lt 9 ] \
    || fail "T1: beacon aged ${max_age}s during a slow per-home sweep (grace 9s): an alive, delivering watcher would read stale"
  # Freshness is measured; give the sweep its remaining time to prove the whole
  # fleet of probes still ran rather than being starved.
  waited=0
  while [ "$waited" -lt 50 ]; do
    [ -e "$dir/done/stationA" ] && [ -e "$dir/done/stationB" ] && [ -e "$dir/done/stationC" ] && break
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  for c in stationA stationB stationC; do
    [ -e "$dir/done/$c" ] || fail "T1: the slow sweep never completed probe $c"
  done
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  pass "T1 slow per-home sweep: beacon stayed inside grace, all probes completed, poll kept cycling"
}

# T2: a hung remote per-home read costs only its per-probe bound.
# A remote secondmate's busy observation is an SSH round trip run inline in the
# poll loop. A fake SSH that never answers stands in for a hung remote home,
# local and deterministic with no real host. The observation must be cut to the
# per-probe timeout, degrade to the no-evidence unknown (never a false completed
# turn), the hung read must be reaped, and the pending expectation preserved.
test_hung_remote_probe_is_bounded() {
  local parent state corr marker hung_pid elapsed started
  parent="$TMP_ROOT/hung-remote"
  state="$parent/state"
  mkdir -p "$state" "$parent/data"
  cat > "$parent/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $parent/mate; scope: iOS work; projects: alpha; added 2026-09-14)
EOF
  fm_write_meta "$state/ios.meta" \
    "window=remote:ios" "kind=secondmate" "mode=secondmate" \
    "harness=codex" "remote_host=remote-mac" "remote_root=$ROOT" "home=$parent/mate"
  corr=$(FM_PENDING_REPLY_GRACE_SECS=100000 \
    fm_pending_reply_create "$parent" "$state" ios 'answer the fleet audit') \
    || fail "T2: could not create the pending-reply record"
  FM_PENDING_REPLY_GRACE_SECS=100000 \
    fm_pending_reply_mark_delivered "$state" "$corr" \
    || fail "T2: could not mark the request delivered"
  marker="$parent/ssh-marker"
  cat > "$parent/hang-ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$marker"
sleep 20
SH
  chmod +x "$parent/hang-ssh"
  started=$(date +%s)
  FM_HOME="$parent" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    FM_SSH_BIN="$parent/hang-ssh" FM_PENDING_REPLY_OBSERVE_TIMEOUT=3 \
    bash -c '. "$1/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2"' _ "$ROOT/bin" "$state" \
    || fail "T2: a hung remote per-home read must not fail the supervision tick"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] \
    || fail "T2: the hung remote per-home read was not bounded (tick took ${elapsed}s)"
  [ -e "$marker" ] || fail "T2: the remote observe never reached the transport (vacuous probe path)"
  hung_pid=$(cat "$marker")
  sleep 1
  ! kill -0 "$hung_pid" 2>/dev/null \
    || fail "T2: the timed-out remote read (pid $hung_pid) outlived its per-probe bound"
  local rec="$state/pending-replies/$corr"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "T2: a timed-out observation changed the pending-reply phase"
  [ -z "$(fm_pending_reply_get "$rec" request_turn_completed_epoch)" ] \
    || fail "T2: a timed-out observation was falsely recorded as a completed turn"
  pass "T2 hung remote home: bounded to its per-probe timeout, degraded to unknown, reaped, expectation preserved"
}

# T3: a watcher wedged inside one stage still reads stale.
# A fake pane capture that never returns blocks the poll loop mid-stage, so no
# further boundary beat fires and the beacon ages past the grace even though the
# process is alive: the stale verdict keeps its meaning.
test_wedged_watcher_still_reads_stale() {
  local dir state fakebin watcher
  dir="$TMP_ROOT/wedged-capture"
  state="$dir/state" fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  fm_write_meta "$state/t1.meta" "window=fm-wedge:t1" "kind=ship"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane) sleep 40; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
    FM_GUARD_GRACE=9 FM_WATCHER_BEAT_SUBCADENCE=1 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  watcher=$!
  sleep 12
  kill -0 "$watcher" 2>/dev/null || fail "T3: the watcher exited instead of staying wedged in the hung capture"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-supervision-lib.sh"
  fm_supervision_status "$state" 9
  [ "$FM_SUP_NEEDED" = true ] || fail "T3: the wedged home stopped needing supervision mid-test"
  [ "$FM_SUP_WATCHER_FRESH" = false ] \
    || fail "T3: a watcher wedged inside one stage kept a fresh beacon (${FM_SUP_BEACON_DESC}): the stale verdict lost its meaning"
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  pass "T3 genuinely wedged watcher: still reports stale past grace"
}

test_slow_probe_sweep_keeps_beacon_fresh
test_hung_remote_probe_is_bounded
test_wedged_watcher_still_reads_stale

exit 0
