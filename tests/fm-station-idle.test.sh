#!/usr/bin/env bash
# Tests for fm-station-idle.sh, the per-station idle-window gate.
#
# The gate exists so a herdr/firstmate update only ever runs on a station whose
# tasks are finished: herdr's update restarts the host's whole server and stops
# every pane there. These cases prove the probe stays silent while ANY home on
# the host still has in-flight work, a working or blocked herdr agent, or a live
# recorded endpoint, and that it prints its one line only once every condition
# has cleared and the station has been idle long enough.
#
# Every external read is a PATH stub, so no case touches a real station, a real
# herdr server, or a real firstmate home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-station-idle.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-station-idle)

STUB="$TMP_ROOT/bin"
mkdir -p "$STUB"

HERDR_WORKING='{"result":{"agents":[{"agent_status":"working"}]}}'
HERDR_BLOCKED='{"result":{"agents":[{"agent_status":"blocked"}]}}'
HERDR_MIXED_IDLE='{"result":{"agents":[{"agent_status":"idle"},{"agent_status":"done"}]}}'
CREW_IDLE='state: done · source: none · no current-state source available'
CREW_WORKING='state: working · source: pane · harness busy (busy)'

write_stub() {  # <name> <body>
  local name=$1
  mkdir -p "$STUB"
  cat > "$STUB/$name"
  chmod 0755 "$STUB/$name"
}

write_stub herdr <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_HERDR_JSON:-}" ]; then
  printf '%s\n' "$FM_TEST_HERDR_JSON"
else
  printf '{"result":{"agents":[]}}\n'
fi
exit "${FM_TEST_HERDR_RC:-0}"
SH

write_stub tasks-axi <<'SH'
#!/usr/bin/env bash
printf 'count: %s\n' "${FM_TEST_INFLIGHT:-0}"
exit "${FM_TEST_TASKS_RC:-0}"
SH

write_stub crew-state <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_CREW_STATE:-state: done · source: none · x}"
exit "${FM_TEST_CREW_RC:-0}"
SH

# A dispatching ssh stub: it reads the remote command out of the argv and
# answers from the matching fixture variable, so a remote station behaves
# exactly as the shapes under test need.
write_stub ssh <<'SH'
#!/usr/bin/env bash
seen=0 host= cmd=
for a in "$@"; do
  if [ "$seen" = 1 ]; then
    if [ -z "$host" ]; then host=$a; else cmd=$a; fi
    continue
  fi
  [ "$a" = "--" ] && seen=1
done
[ -z "${FM_TEST_SSH_LOG:-}" ] || printf '%s\t%s\n' "$host" "$cmd" >> "$FM_TEST_SSH_LOG"
if [ "${FM_TEST_SSH_RC:-0}" != 0 ]; then exit "${FM_TEST_SSH_RC}"; fi
case "$cmd" in
  *'agent list'*)
    if [ -n "${FM_TEST_SSH_HERDR:-}" ]; then printf '%s\n' "$FM_TEST_SSH_HERDR"; else printf '{"result":{"agents":[]}}\n'; fi ;;
  *'list --state in_flight'*) printf 'count: %s\n' "${FM_TEST_SSH_INFLIGHT:-0}" ;;
  *'ls -1 '*) printf '%s\n' "${FM_TEST_SSH_LS:-}" ;;
  *fm-crew-state.sh*) printf '%s\n' "${FM_TEST_SSH_CREW:-state: done · source: none · x}" ;;
  *) exit 1 ;;
esac
SH

make_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

write_registry() {  # <home> <line...>
  local home=$1
  shift
  : > "$home/data/secondmates.md"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/data/secondmates.md"
  done
}

REMOTE_RECORD='- infra-remote - overflow firstmate work (host: adi2-ts; root: /home/adi/firstmate; home: /home/adi/.firstmate-infra; scope: firstmate repo work; projects: ; added 2026-09-13)'
LOCAL_RECORD='- fm-infra - local fleet infrastructure (home: /home/other/.firstmate-infra; scope: firstmate repo; projects: ; added 2026-08-02)'

# run_probe <home> <station> <out> [extra NAME=VALUE...]
run_probe() {
  local home=$1 station=$2 out=$3
  shift 3
  local status=0
  env FM_HOME="$home" FM_STATION_CREW_STATE="$STUB/crew-state" \
    FM_STATION_SSH="$STUB/ssh" FM_STATION_HERDR="$STUB/herdr" \
    FM_STATION_TASKS_AXI="$STUB/tasks-axi" FM_STATION_IDLE_WINDOW=0 \
    "$@" "$CHECK" "$station" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "probe exit ($station)"
}

# --- the idle report --------------------------------------------------------

test_idle_station_reports_its_one_line() {
  local home out
  home=$(make_home idle)
  out="$home/out.txt"
  run_probe "$home" local "$out"
  [ "$(cat "$out")" = 'station-idle: local' ] || fail "an idle station did not print its one line: $(cat "$out")"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the report must be exactly one line"
  pass "an idle station prints exactly one station-idle line"
}

test_a_working_or_blocked_pane_keeps_the_station_silent() {
  local home out
  home=$(make_home herdr)
  out="$home/out.txt"

  run_probe "$home" local "$out" "FM_TEST_HERDR_JSON=$HERDR_WORKING"
  [ ! -s "$out" ] || fail "a working herdr agent did not keep the station silent: $(cat "$out")"

  run_probe "$home" local "$out" "FM_TEST_HERDR_JSON=$HERDR_BLOCKED"
  [ ! -s "$out" ] || fail "a blocked herdr agent did not keep the station silent: $(cat "$out")"

  # Idle and done agents are not work; the station is idle.
  run_probe "$home" local "$out" "FM_TEST_HERDR_JSON=$HERDR_MIXED_IDLE"
  [ "$(cat "$out")" = 'station-idle: local' ] || fail "an idle/done herdr state was read as busy: $(cat "$out")"
  pass "a working or blocked herdr agent keeps the station silent"
}

test_in_flight_work_keeps_the_station_silent() {
  local home out
  home=$(make_home inflight)
  out="$home/out.txt"
  run_probe "$home" local "$out" FM_TEST_INFLIGHT=3
  [ ! -s "$out" ] || fail "an in-flight task did not keep the station silent: $(cat "$out")"
  pass "an in-flight task keeps the station silent"
}

test_a_live_recorded_endpoint_keeps_the_station_silent() {
  local home out
  home=$(make_home endpoint)
  out="$home/out.txt"
  printf 'worktree=/tmp/w\nkind=ship\n' > "$home/state/t1.meta"

  run_probe "$home" local "$out" "FM_TEST_CREW_STATE=$CREW_WORKING"
  [ ! -s "$out" ] || fail "a live recorded endpoint did not keep the station silent: $(cat "$out")"

  run_probe "$home" local "$out" "FM_TEST_CREW_STATE=$CREW_IDLE"
  [ "$(cat "$out")" = 'station-idle: local' ] || fail "an idle recorded endpoint was read as busy: $(cat "$out")"
  pass "a live recorded endpoint keeps the station silent"
}

test_an_unanswered_read_is_never_read_as_idle() {
  local home out
  home=$(make_home unanswered)
  out="$home/out.txt"
  # A herdr that fails to answer, an in-flight read that fails, and an endpoint
  # read that fails must each keep the station silent rather than prove it idle.
  run_probe "$home" local "$out" FM_TEST_HERDR_RC=1
  [ ! -s "$out" ] || fail "an unanswered herdr read was read as idle: $(cat "$out")"

  run_probe "$home" local "$out" FM_TEST_TASKS_RC=1
  [ ! -s "$out" ] || fail "an unanswered in-flight read was read as idle: $(cat "$out")"

  printf 'worktree=/tmp/w\nkind=ship\n' > "$home/state/t2.meta"
  run_probe "$home" local "$out" FM_TEST_CREW_RC=1
  [ ! -s "$out" ] || fail "an unanswered endpoint read was read as idle: $(cat "$out")"
  pass "a read that did not answer is never read as idle"
}

# --- remote stations --------------------------------------------------------

test_remote_station_resolves_its_host_and_ignores_other_homes() {
  local home out log
  home=$(make_home remote)
  out="$home/out.txt"
  log="$home/ssh.log"
  printf 'worktree=/tmp/w\nkind=ship\n' > "$home/state/local-task.meta"
  write_registry "$home" "$REMOTE_RECORD" "$LOCAL_RECORD"

  # The station is adi2; the record names the host alias adi2-ts, and only that
  # host's home may be read. The local record is another station's.
  run_probe "$home" adi2 "$out" "FM_TEST_SSH_LOG=$log"
  [ "$(cat "$out")" = 'station-idle: adi2' ] || fail "a remote idle station did not report: $(cat "$out")"
  assert_contains "$(cat "$log")" 'adi2-ts' "the probe did not read through the station's recorded host alias"
  assert_not_contains "$(cat "$log")" '/home/other/.firstmate-infra' "the probe read a home belonging to another station"
  pass "a remote station resolves its host route and ignores other homes"
}

test_a_remote_working_pane_keeps_the_station_silent() {
  local home out
  home=$(make_home remote-busy)
  out="$home/out.txt"
  write_registry "$home" "$REMOTE_RECORD"
  run_probe "$home" adi2 "$out" "FM_TEST_SSH_HERDR=$HERDR_WORKING"
  [ ! -s "$out" ] || fail "a remote working pane did not keep the station silent: $(cat "$out")"
  pass "a remote working pane keeps the station silent"
}

test_a_remote_station_with_no_home_is_probed_host_wide() {
  local home out log
  home=$(make_home remote-nohome)
  out="$home/out.txt"
  log="$home/ssh.log"
  # adi3 has no registered home yet; only herdr is asked, and it is idle.
  run_probe "$home" adi3 "$out" "FM_TEST_SSH_LOG=$log" FM_TEST_SSH_LS=
  [ "$(cat "$out")" = 'station-idle: adi3' ] || fail "a home-less idle station did not report: $(cat "$out")"
  assert_contains "$(cat "$log")" 'adi3' "the probe did not ask the station host itself"
  assert_not_contains "$(cat "$log")" 'list --state in_flight' "a home-less station must not read a backlog"
  pass "a remote station with no registered home is probed host-wide"
}

# --- the idle window and no-nag ---------------------------------------------

test_the_idle_window_delays_the_report_and_reports_once() {
  local home out
  home=$(make_home window)
  out="$home/out.txt"

  # First idle observation starts the window; it is not yet news.
  run_probe "$home" local "$out" FM_STATION_IDLE_WINDOW=300 FM_STATION_NOW=1000
  [ ! -s "$out" ] || fail "the station reported before the idle window elapsed: $(cat "$out")"

  # Still inside the window.
  run_probe "$home" local "$out" FM_STATION_IDLE_WINDOW=300 FM_STATION_NOW=1200
  [ ! -s "$out" ] || fail "the station reported before the idle window elapsed: $(cat "$out")"

  # The window has elapsed: one line, once.
  run_probe "$home" local "$out" FM_STATION_IDLE_WINDOW=300 FM_STATION_NOW=1300
  [ "$(cat "$out")" = 'station-idle: local' ] || fail "the station did not report after the idle window: $(cat "$out")"

  run_probe "$home" local "$out" FM_STATION_IDLE_WINDOW=300 FM_STATION_NOW=5000
  [ ! -s "$out" ] || fail "the same idle window was reported twice: $(cat "$out")"
  pass "the idle window delays the one-time report"
}

test_busy_then_idle_again_reports_a_new_window() {
  local home out
  home=$(make_home flapping)
  out="$home/out.txt"

  run_probe "$home" local "$out" FM_STATION_IDLE_WINDOW=300 FM_STATION_NOW=1000
  [ ! -s "$out" ] || fail "the station reported before the idle window elapsed: $(cat "$out")"

  # A task arrives: the pending window is discarded, still silent.
  run_probe "$home" local "$out" FM_STATION_IDLE_WINDOW=300 FM_STATION_NOW=1200 FM_TEST_INFLIGHT=1
  [ ! -s "$out" ] || fail "a busy station spoke: $(cat "$out")"

  # Idle again, but the new window has only just started.
  run_probe "$home" local "$out" FM_STATION_IDLE_WINDOW=300 FM_STATION_NOW=2000
  [ ! -s "$out" ] || fail "the station reported before the new idle window elapsed: $(cat "$out")"

  run_probe "$home" local "$out" FM_STATION_IDLE_WINDOW=300 FM_STATION_NOW=2300
  [ "$(cat "$out")" = 'station-idle: local' ] || fail "the station did not report after the new idle window: $(cat "$out")"
  pass "a busy gap resets the idle window"
}

# --- arming through the watcher contract ------------------------------------

test_arm_registers_the_check_and_disarm_removes_it() {
  local home out status
  home=$(make_home arm)
  out="$home/out.txt"

  status=0
  env FM_HOME="$home" FM_STATION_CREW_STATE="$STUB/crew-state" FM_STATION_SSH="$STUB/ssh" \
    FM_STATION_HERDR="$STUB/herdr" FM_STATION_TASKS_AXI="$STUB/tasks-axi" \
    "$CHECK" arm adi1 >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/station-idle-adi1.check.sh" "arm did not write the check shim"
  assert_present "$home/state/station-idle-adi1.check-trust" "arm did not register the check's bytes"
  [ "$(stat -c %a "$home/state/station-idle-adi1.check.sh" 2>/dev/null || stat -f %Lp "$home/state/station-idle-adi1.check.sh")" = 700 ] \
    || fail "the check shim is not mode 700"
  assert_grep 'fm-custom-check-v1' "$home/state/station-idle-adi1.check-trust" "the trust binding has the wrong schema"

  # The shim is the executable check: running it produces the station's line.
  status=0
  env FM_HOME="$home" FM_STATION_CREW_STATE="$STUB/crew-state" FM_STATION_SSH="$STUB/ssh" \
    FM_STATION_HERDR="$STUB/herdr" FM_STATION_TASKS_AXI="$STUB/tasks-axi" FM_STATION_IDLE_WINDOW=0 \
    "$home/state/station-idle-adi1.check.sh" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "shim run exit"
  [ "$(cat "$out")" = 'station-idle: adi1' ] || fail "the armed shim did not probe its station: $(cat "$out")"

  env FM_HOME="$home" "$CHECK" disarm adi1 >/dev/null || fail "disarm failed"
  assert_absent "$home/state/station-idle-adi1.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/station-idle-adi1.check-trust" "disarm left the trust binding behind"
  assert_absent "$home/state/.station-idle-adi1" "disarm left the idle record behind"
  pass "arm registers a trusted check and disarm removes every trace"
}

test_armed_check_wakes_the_watcher_with_the_idle_line() {
  local home out err status
  home=$(make_home wake)
  out="$home/out.txt"
  err="$home/err.txt"
  env FM_HOME="$home" "$CHECK" arm adi1 >/dev/null || fail "could not arm the station idle check"

  status=0
  env FM_HOME="$home" FM_STATION_CREW_STATE="$STUB/crew-state" FM_STATION_SSH="$STUB/ssh" \
    FM_STATION_HERDR="$STUB/herdr" FM_STATION_TASKS_AXI="$STUB/tasks-axi" FM_STATION_IDLE_WINDOW=0 \
    FM_CHECK_TIMEOUT=30 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 10 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" 'check:' "the armed check did not reach the watcher as a check wake"
  assert_contains "$(cat "$out")" 'station-idle: adi1' "the wake did not carry the station-idle line"
  pass "the armed check reaches the watcher as an ordinary check wake"
}

# --- refusal ----------------------------------------------------------------

test_invalid_use_refuses() {
  local home status
  home=$(make_home refuse)
  status=0
  env FM_HOME="$home" "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "missing station exit"
  status=0
  env FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "arm without station exit"
  status=0
  env FM_HOME="$home" "$CHECK" 'bad/name' >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "invalid station exit"
  status=0
  env FM_HOME="$home" "$CHECK" --help >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "help exit"
  pass "invalid use refuses instead of guessing"
}

test_idle_station_reports_its_one_line
test_a_working_or_blocked_pane_keeps_the_station_silent
test_in_flight_work_keeps_the_station_silent
test_a_live_recorded_endpoint_keeps_the_station_silent
test_an_unanswered_read_is_never_read_as_idle
test_remote_station_resolves_its_host_and_ignores_other_homes
test_a_remote_working_pane_keeps_the_station_silent
test_a_remote_station_with_no_home_is_probed_host_wide
test_the_idle_window_delays_the_report_and_reports_once
test_busy_then_idle_again_reports_a_new_window
test_arm_registers_the_check_and_disarm_removes_it
test_armed_check_wakes_the_watcher_with_the_idle_line
test_invalid_use_refuses
