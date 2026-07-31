#!/usr/bin/env bash
# Behavior tests for window_is_busy() native-busy staleness fallback
# (bin/fm-watch.sh).
#
# A backend's native "busy" signal that never flips (herdr has no cline
# integration, so its agent_status for a cline pane is a guess stuck at
# "working" forever) would make supervision wait forever and never reap a
# finished task. Past FM_BUSY_NATIVE_MAX_SECONDS (default 120) of continuous
# busy for the same window, window_is_busy stops trusting the native signal and
# falls through to the recorded harness's pane-tail signature. Under the
# threshold, behaviour is unchanged for claude/codex/pi/copilot, whose native
# signals are correct.
#
# Uses the repo's function-extraction + eval idiom (tests/fm-backend-herdr.test.sh:1226,
# tests/fm-copilot-harness.test.sh:176): window_is_busy is sed-extracted from
# fm-watch.sh and eval'd in a disposable `bash -c` subshell with its backend
# dependencies overridden by scripted stubs, against a temp STATE dir.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WINDOW_BUSY_SOURCE=$(sed -n '/^window_is_busy()/,/^window_kind()/p' "$WATCH" | sed '$d')

test_busy_under_threshold_trusts_native() {
  # Under FM_BUSY_NATIVE_MAX_SECONDS, a native "busy" must return 0 (busy)
  # exactly as before - the staleness fallback must not change hot-path
  # behaviour for backends whose native signals are correct.
  local tmpd out
  tmpd=$(fm_test_tmproot busy-under-threshold); mkdir -p "$tmpd"
  out=$(STATE="$tmpd" SRC="$WINDOW_BUSY_SOURCE" bash -c '
    eval "$SRC"
    fm_backend_busy_state() { printf busy; }
    window_backend() { printf herdr; }
    window_harness() { printf claude; }
    fm_busy_lines_match() { return 1; }
    FM_BUSY_NATIVE_MAX_SECONDS=120
    if window_is_busy win:0 "some idle tail"; then printf busy; else printf notbusy; fi
  ')
  [ "$out" = busy ] \
    || fail "under-threshold native busy must return busy (unchanged hot path), got '$out'"
  pass "window_is_busy: under-threshold native busy trusts the native signal"
}

test_stale_native_busy_falls_through_to_pane_regex() {
  # Past the threshold, a never-flipping native "busy" must stop being trusted
  # and fall through to the pane-regex classifier. This is the cline-on-herdr
  # escape hatch: the pane shows idle, so the regex says not-busy, and the
  # finished task is reaped instead of waiting forever.
  local tmpd out now
  tmpd=$(fm_test_tmproot busy-stale); mkdir -p "$tmpd"
  now=${EPOCHSECONDS:-$(date +%s)}
  echo $((now - 200)) > "$tmpd/.busy-since-win_0"
  out=$(STATE="$tmpd" SRC="$WINDOW_BUSY_SOURCE" bash -c '
    eval "$SRC"
    fm_backend_busy_state() { printf busy; }
    window_backend() { printf herdr; }
    window_harness() { printf cline; }
    fm_busy_lines_match() { return 1; }
    FM_BUSY_NATIVE_MAX_SECONDS=120
    if window_is_busy win:0 "idle pane tail"; then printf busy; else printf notbusy; fi
  ')
  [ "$out" = notbusy ] \
    || fail "stale native busy must fall through to the pane-regex classifier (cline turn-end), got '$out'"
  pass "window_is_busy: stale native busy beyond the threshold falls through to the pane-regex classifier"
}

test_stale_native_busy_confirms_busy_when_pane_still_working() {
  # Past the threshold, if the pane-regex classifier ALSO says busy, the window
  # is genuinely still working - the fallback must confirm busy, not invent idle.
  local tmpd out now
  tmpd=$(fm_test_tmproot busy-stale-working); mkdir -p "$tmpd"
  now=${EPOCHSECONDS:-$(date +%s)}
  echo $((now - 200)) > "$tmpd/.busy-since-win_0"
  out=$(STATE="$tmpd" SRC="$WINDOW_BUSY_SOURCE" bash -c '
    eval "$SRC"
    fm_backend_busy_state() { printf busy; }
    window_backend() { printf herdr; }
    window_harness() { printf cline; }
    fm_busy_lines_match() { return 0; }
    FM_BUSY_NATIVE_MAX_SECONDS=120
    if window_is_busy win:0 "Working... ctrl+c to stop"; then printf busy; else printf notbusy; fi
  ')
  [ "$out" = busy ] \
    || fail "stale native busy with a busy pane must confirm busy, got '$out'"
  pass "window_is_busy: stale native busy with a genuinely-busy pane confirms busy"
}

test_idle_resets_the_staleness_window() {
  # When the backend reports idle, the per-window busy-since state is cleared so
  # a later busy starts a fresh threshold window (no stale carryover).
  local tmpd out now
  tmpd=$(fm_test_tmproot busy-idle-reset); mkdir -p "$tmpd"
  now=${EPOCHSECONDS:-$(date +%s)}
  echo $((now - 200)) > "$tmpd/.busy-since-win_0"
  out=$(STATE="$tmpd" SRC="$WINDOW_BUSY_SOURCE" bash -c '
    eval "$SRC"
    fm_backend_busy_state() { printf idle; }
    window_backend() { printf herdr; }
    window_harness() { printf cline; }
    FM_BUSY_NATIVE_MAX_SECONDS=120
    if window_is_busy win:0 "idle"; then printf busy; else printf notbusy; fi
    [ -e "$STATE/.busy-since-win_0" ] && printf "state-leftover" || printf "state-cleared"
  ')
  case "$out" in
    notbusystate-cleared) ;;
    *) fail "idle must clear the busy-since state and report not-busy, got '$out'" ;;
  esac
  pass "window_is_busy: idle reports not-busy and clears the per-window staleness state"
}

test_unknown_backend_state_falls_through_and_clears() {
  # A non-busy/non-idle native value (unknown/error) falls through to the
  # pane-regex classifier (unchanged original behaviour) and clears any leftover
  # busy-since state so it cannot masquerade as stale later.
  local tmpd out now
  tmpd=$(fm_test_tmproot busy-unknown); mkdir -p "$tmpd"
  now=${EPOCHSECONDS:-$(date +%s)}
  echo $((now - 200)) > "$tmpd/.busy-since-win_0"
  out=$(STATE="$tmpd" SRC="$WINDOW_BUSY_SOURCE" bash -c '
    eval "$SRC"
    fm_backend_busy_state() { printf unknown; }
    window_backend() { printf herdr; }
    window_harness() { printf cline; }
    fm_busy_lines_match() { return 1; }
    FM_BUSY_NATIVE_MAX_SECONDS=120
    if window_is_busy win:0 "idle pane"; then printf busy; else printf notbusy; fi
    [ -e "$STATE/.busy-since-win_0" ] && printf "state-leftover" || printf "state-cleared"
  ')
  case "$out" in
    notbusystate-cleared) ;;
    *) fail "unknown native state must fall through to pane-regex and clear busy-since, got '$out'" ;;
  esac
  pass "window_is_busy: unknown native state falls through to pane-regex and clears the staleness state"
}

# --- run --------------------------------------------------------------------
test_busy_under_threshold_trusts_native
test_stale_native_busy_falls_through_to_pane_regex
test_stale_native_busy_confirms_busy_when_pane_still_working
test_idle_resets_the_staleness_window
test_unknown_backend_state_falls_through_and_clears
echo "ALL PASS: fm-watch-busy-staleness"
