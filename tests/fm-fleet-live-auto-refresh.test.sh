#!/usr/bin/env bash
# Behavioral tests for the automatic fleet-view refresh wiring.
#
# The live fleet view (bin/fm-fleet-live.sh) refreshes itself, best-effort and
# non-disruptively, from two existing boundaries: the supervision heartbeat in
# bin/fm-watch.sh and the successful task-completion path in bin/fm-teardown.sh
# (covered beside its own fixture in tests/fm-teardown.test.sh). This file proves
# the heartbeat trigger and the primitive's automatic `refresh --best-effort`
# form:
#   - the heartbeat actually invokes the refresh entry point;
#   - a heartbeat with no recorded view tab makes no Herdr call;
#   - the primitive no-ops silently when no tab is recorded or Herdr is absent;
#   - the primitive refreshes an already-recorded tab silently and bounded.
# Everything here runs hermetically with a fake Herdr recorder, so it needs no
# real Herdr and never touches a live session. The real-binary pin stays in
# tests/fm-fleet-live-herdr-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LIVE="$ROOT/bin/fm-fleet-live.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-live-auto-refresh)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A minimal fake Herdr for the refresh path only: every invocation is recorded,
# `pane get` answers the expected pane, and `pane run` records the renderer
# command it was asked to run. Any other verb is a hard error so an unexpected
# call cannot pass silently.
write_fake_herdr() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FAKE_HERDR_CALLS:?}"
case "${1:-} ${2:-}" in
  "pane get")
    [ "${3:-}" = "${FAKE_HERDR_PANE:-}" ] || exit 1
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3"
    ;;
  "pane run")
    printf '%s\n' "${4:-}" >> "${FAKE_HERDR_RUNS:?}"
    printf '{}\n'
    ;;
  *) echo "fake herdr: unexpected command: $*" >&2; exit 91 ;;
esac
SH
  chmod +x "$1/herdr"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

write_record() {  # <home> <session> <pane>
  printf 'session=%s\nworkspace=ws1\ntab=tab1\npane=%s\n' "$2" "$3" > "$1/state/fleet-view.herdr"
}

# --- primitive: refresh --best-effort no-op and success ---------------------

test_best_effort_no_record_is_a_silent_noop() {
  local home fakebin calls out status=0
  home=$(make_home no-record); fakebin="$home/fakebin"; mkdir -p "$fakebin"
  write_fake_herdr "$fakebin"
  calls="$home/calls.log"; : > "$calls"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_CALLS="$calls" \
    "$LIVE" refresh --best-effort 2>&1) || status=$?
  expect_code 0 "$status" "best-effort refresh with no record must exit 0"
  [ -z "$out" ] || fail "best-effort refresh with no record printed output: $out"
  [ ! -s "$calls" ] || fail "best-effort refresh with no record still called Herdr: $(cat "$calls")"
  pass "refresh --best-effort is a silent no-op with no recorded tab"
}

test_best_effort_herdr_missing_is_a_silent_noop() {
  local home calls out status=0 path_without_herdr
  home=$(make_home herdr-missing)
  write_record "$home" fm-lab-missing pane1
  path_without_herdr=$(fm_test_base_path_sans "$PATH" herdr)
  out=$(PATH="$path_without_herdr" FM_HOME="$home" "$LIVE" refresh --best-effort 2>&1) || status=$?
  expect_code 0 "$status" "best-effort refresh without herdr must exit 0"
  [ -z "$out" ] || fail "best-effort refresh without herdr printed output: $out"
  pass "refresh --best-effort is a silent no-op when Herdr is unavailable"
}

test_best_effort_refreshes_a_recorded_tab() {
  local home fakebin calls runs out status=0
  home=$(make_home refresh-ok); fakebin="$home/fakebin"; mkdir -p "$fakebin"
  write_fake_herdr "$fakebin"
  write_record "$home" fm-lab-refresh pane7
  calls="$home/calls.log"; runs="$home/runs.log"; : > "$calls"; : > "$runs"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_HERDR_CALLS="$calls" \
    FAKE_HERDR_RUNS="$runs" FAKE_HERDR_PANE=pane7 \
    "$LIVE" refresh --best-effort 2>&1) || status=$?
  expect_code 0 "$status" "best-effort refresh of a recorded tab must exit 0"
  [ -z "$out" ] || fail "best-effort refresh of a recorded tab printed output: $out"
  grep -q "fm-fleet-view.sh" "$runs" || fail "best-effort refresh did not run the renderer in the recorded pane"
  grep -q -- "--session fm-lab-refresh" "$calls" || fail "best-effort refresh did not target the recorded session: $(cat "$calls")"
  pass "refresh --best-effort refreshes only the recorded tab, silently"
}

test_best_effort_refuses_non_refresh_verbs() {
  local status=0 out
  out=$("$LIVE" open --best-effort 2>&1) || status=$?
  expect_code 2 "$status" "open --best-effort must be refused"
  case "$out" in *"only for refresh"*) : ;; *) fail "best-effort misuse should say why: $out" ;; esac
  pass "refresh --best-effort is confined to the refresh verb"
}

# --- heartbeat trigger ------------------------------------------------------

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

test_heartbeat_invokes_the_automatic_refresh() {
  local dir state fakebin out stub log pid i pulse_stub pulse_log
  dir=$(make_case heartbeat-refresh); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; log="$dir/refresh-calls.log"; pulse_log="$dir/pulse-calls.log"
  stub="$dir/fleet-live-stub.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FLEET_LIVE_STUB_LOG:?}"
exit 0
SH
  chmod +x "$stub"
  pulse_stub="$dir/fleet-pulse-stub.sh"
  cat > "$pulse_stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FLEET_PULSE_STUB_LOG:?}"
exit 0
SH
  chmod +x "$pulse_stub"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    FM_FLEET_LIVE_BIN="$stub" FM_FLEET_LIVE_STUB_LOG="$log" \
    FM_FLEET_PULSE_BIN="$pulse_stub" FM_FLEET_PULSE_STUB_LOG="$pulse_log" "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ -s "$log" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
  [ -s "$log" ] || fail "the supervision heartbeat never invoked the fleet-view refresh: $(cat "$out" 2>/dev/null)"
  grep -Fx "refresh --best-effort" "$log" >/dev/null \
    || fail "the heartbeat did not call the refresh entry point as 'refresh --best-effort': $(cat "$log")"
  pass "the supervision heartbeat invokes the best-effort fleet-view refresh"
}

test_heartbeat_republishes_the_pulse_page() {
  local dir state fakebin out pid i pulse_stub pulse_log
  dir=$(make_case heartbeat-pulse); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; pulse_log="$dir/pulse-calls.log"
  pulse_stub="$dir/fleet-pulse-stub.sh"
  cat > "$pulse_stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FLEET_PULSE_STUB_LOG:?}"
exit 0
SH
  chmod +x "$pulse_stub"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    FM_FLEET_PULSE_BIN="$pulse_stub" FM_FLEET_PULSE_STUB_LOG="$pulse_log" "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ -s "$pulse_log" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
  [ -s "$pulse_log" ] || fail "the supervision heartbeat never invoked the Pulse republish: $(cat "$out" 2>/dev/null)"
  grep -Fx "publish --best-effort" "$pulse_log" >/dev/null \
    || fail "the heartbeat did not call the publish entry point as 'publish --best-effort': $(cat "$pulse_log")"
  pass "the supervision heartbeat republishes the Pulse fleet page best-effort"
}

test_heartbeat_without_a_record_makes_no_herdr_call() {
  local dir state fakebin out pid i pulse_stub
  dir=$(make_case heartbeat-no-record); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  write_fake_herdr "$fakebin"
  pulse_stub="$dir/fleet-pulse-stub.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$pulse_stub"
  chmod +x "$pulse_stub"
  : > "$dir/calls.log"; : > "$dir/runs.log"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    FAKE_HERDR_CALLS="$dir/calls.log" FAKE_HERDR_PANE=pane1 FAKE_HERDR_RUNS="$dir/runs.log" \
    FM_FLEET_PULSE_BIN="$pulse_stub" "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ -e "$state/.last-heartbeat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
  [ -e "$state/.last-heartbeat" ] || fail "the watcher never completed a heartbeat cycle: $(cat "$out" 2>/dev/null)"
  [ ! -s "$dir/calls.log" ] \
    || fail "a heartbeat with no recorded view tab still reached Herdr: $(cat "$dir/calls.log")"
  pass "a heartbeat with no recorded view tab reaches no Herdr and is a clean no-op"
}

test_best_effort_no_record_is_a_silent_noop
test_best_effort_herdr_missing_is_a_silent_noop
test_best_effort_refreshes_a_recorded_tab
test_best_effort_refuses_non_refresh_verbs
test_heartbeat_invokes_the_automatic_refresh
test_heartbeat_republishes_the_pulse_page
test_heartbeat_without_a_record_makes_no_herdr_call
