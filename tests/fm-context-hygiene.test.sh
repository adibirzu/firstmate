#!/usr/bin/env bash
# tests/fm-context-hygiene.test.sh - context-hygiene policy and watcher wiring.
#
# Covers bin/fm-context-hygiene-lib.sh and the watcher functions that consume it
# (context_hygiene_tick, heartbeat_interval, coalesce_signal_rows,
# secondmate_healthy_idle): the per-harness compact/clear command table, the
# config knobs (context-hygiene off switch, idle seconds, wake-coalesce,
# heartbeat-idle), the durable compact marker and idle window, adaptive
# heartbeat reset on an in-flight task, signal-row dedupe, and the healthy-idle
# secondmate suppression. Backend delivery is stubbed at the backend boundary so
# no real pane, harness, or tmux is required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-context-hygiene)
STATE_DIR="$TMP/state"
CONFIG_DIR="$TMP/config"
DATA_DIR="$TMP/data"
mkdir -p "$STATE_DIR" "$CONFIG_DIR" "$DATA_DIR"

export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
export FM_CONFIG_OVERRIDE="$CONFIG_DIR"
export FM_DATA_OVERRIDE="$DATA_DIR"
# Keep harness detection hermetic; a case that needs another harness resets it.
export FM_CONTEXT_HYGIENE_HARNESS=claude
# Production modules are independently linted canonical roots.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

# --- stubs -------------------------------------------------------------------
SENT="$TMP/sent"
COMPOSER_STATE=empty
BUSY_STATE=idle
TARGET_EXISTS=0
SEND_VERDICT=empty
INBOX_UNHANDLED=1

fm_backend_target_exists() { return "$TARGET_EXISTS"; }
fm_backend_busy_state() { printf '%s\n' "$BUSY_STATE"; }
fm_backend_composer_state() { printf '%s\n' "$COMPOSER_STATE"; }
fm_backend_send_text_submit() {  # <backend> <target> <text> ...
  printf '%s\n' "$3" >> "$SENT"
  printf '%s\n' "$SEND_VERDICT"
}
fm_backend_target_of_meta() { printf 'firstmate:0\n'; }
fm_backend_of_meta() { printf 'tmux\n'; }
fm_task_inbox_oldest_unhandled() { return "$INBOX_UNHANDLED"; }
discover_supervisor_target() { printf 'firstmate:0\n'; }
discover_supervisor_backend() { printf 'tmux\n'; }
wake() { printf 'WAKE %s\n' "$1" >> "$SENT"; return 0; }

reset_case() {
  rm -rf "$STATE_DIR" "$CONFIG_DIR" "$DATA_DIR"
  mkdir -p "$STATE_DIR" "$CONFIG_DIR" "$DATA_DIR"
  : > "$SENT"
  COMPOSER_STATE=empty
  BUSY_STATE=idle
  TARGET_EXISTS=0
  SEND_VERDICT=empty
  INBOX_UNHANDLED=1
  _context_hygiene_harness=""
  export FM_CONTEXT_HYGIENE_HARNESS=claude
  # Read as globals by the sourced watcher functions, so export them.
  export STATE="$STATE_DIR"
  export CONFIG="$CONFIG_DIR"
  export DATA="$DATA_DIR"
}

# --- command table -----------------------------------------------------------

test_command_table() {
  reset_case
  local out
  out=$(fm_context_hygiene_command claude compact); [ "$out" = "/compact" ] || fail "claude compact: $out"
  out=$(fm_context_hygiene_command claude clear); [ "$out" = "/clear" ] || fail "claude clear: $out"
  out=$(fm_context_hygiene_command pi compact); [ "$out" = "/compact" ] || fail "pi compact: $out"
  out=$(fm_context_hygiene_command pi clear); [ "$out" = "/new" ] || fail "pi clear: $out"
  out=$(fm_context_hygiene_command pi-signed clear); [ "$out" = "/new" ] || fail "pi-signed clear: $out"
  out=$(fm_context_hygiene_command codex compact); [ -z "$out" ] || fail "codex must have no verified compact command: $out"
  out=$(fm_context_hygiene_command codex clear); [ -z "$out" ] || fail "codex must have no verified clear command: $out"
  out=$(fm_context_hygiene_command opencode clear); [ -z "$out" ] || fail "opencode must have no verified clear command: $out"
  out=$(fm_context_hygiene_command grok clear); [ -z "$out" ] || fail "grok must have no verified clear command: $out"
  out=$(fm_context_hygiene_compact_command claude "Focus on task A")
  [ "$out" = "/compact Focus on task A" ] || fail "claude compact must carry the focus line: $out"
  out=$(fm_context_hygiene_compact_command pi "Focus on task A")
  [ "$out" = "/compact" ] || fail "pi compact must not receive an unverified focus argument: $out"
  out=$(fm_context_hygiene_compact_command codex "Focus on task A")
  [ -z "$out" ] || fail "codex must have no verified compact command: $out"
  pass "the per-harness command table lists only verified compact/clear commands"
}

# --- config knobs ------------------------------------------------------------

test_off_switch_and_seconds() {
  reset_case
  fm_context_hygiene_disabled "$CONFIG" && fail "absent config/context-hygiene must leave the feature on"
  printf 'off\n' > "$CONFIG/context-hygiene"
  fm_context_hygiene_disabled "$CONFIG" || fail "literal off must disable the feature"
  printf 'OFF\n' > "$CONFIG/context-hygiene"
  fm_context_hygiene_disabled "$CONFIG" || fail "off must be case-insensitive"
  printf 'on\n' > "$CONFIG/context-hygiene"
  fm_context_hygiene_disabled "$CONFIG" && fail "a non-off value must leave the feature on"

  # Seconds: default when absent, and never zero on a malformed value.
  [ "$(fm_context_hygiene_seconds "$CONFIG" context-hygiene-idle-seconds 900)" = 900 ] || fail "absent idle seconds must use the default"
  printf '45\n' > "$CONFIG/context-hygiene-idle-seconds"
  [ "$(fm_context_hygiene_seconds "$CONFIG" context-hygiene-idle-seconds 900)" = 45 ] || fail "a valid idle seconds value was ignored"
  printf '0\n' > "$CONFIG/context-hygiene-idle-seconds"
  [ "$(fm_context_hygiene_seconds "$CONFIG" context-hygiene-idle-seconds 900)" = 900 ] || fail "a zero idle window must fall back to the default"
  printf '00\n' > "$CONFIG/context-hygiene-idle-seconds"
  [ "$(fm_context_hygiene_seconds "$CONFIG" context-hygiene-idle-seconds 900)" = 900 ] || fail "a leading-zero zero must fall back to the default"
  printf '08\n' > "$CONFIG/context-hygiene-idle-seconds"
  [ "$(fm_context_hygiene_seconds "$CONFIG" context-hygiene-idle-seconds 900)" = 900 ] || fail "an octal-looking value must fall back to the default"
  printf 'soon\n' > "$CONFIG/context-hygiene-idle-seconds"
  [ "$(fm_context_hygiene_seconds "$CONFIG" context-hygiene-idle-seconds 900)" = 900 ] || fail "a malformed idle value must fall back to the default"
  pass "config/context-hygiene is off only for the literal off and malformed seconds fall back"
}

test_watcher_cadence_wiring() {
  reset_case
  printf '1234\n' > "$CONFIG/heartbeat-idle-seconds"
  printf '17\n' > "$CONFIG/wake-coalesce-seconds"
  local out
  out=$(FM_HOME="$TMP/home" FM_CONFIG_OVERRIDE="$CONFIG" FM_STATE_OVERRIDE="$STATE_DIR" \
    bash -c '. "$1"; printf "%s|%s\n" "$HEARTBEAT_MAX" "$SIGNAL_GRACE"' _ "$ROOT/bin/fm-watch.sh")
  [ "$out" = "1234|17" ] || fail "watcher did not wire config/heartbeat-idle-seconds and config/wake-coalesce-seconds (got $out)"
  pass "the watcher reads heartbeat-idle-seconds and wake-coalesce-seconds from config"
}

# --- marker, focus, in-flight ------------------------------------------------

test_marker_focus_and_in_flight() {
  reset_case
  printf 'kind=ship\n' > "$STATE_DIR/task.meta"
  printf 'kind=secondmate\n' > "$STATE_DIR/mate.meta"
  [ "$(fm_context_hygiene_in_flight_count "$STATE_DIR")" = 1 ] \
    || fail "a secondmate record must not count as work in flight"
  printf 'kind=scout\n' > "$STATE_DIR/other.meta"
  [ "$(fm_context_hygiene_in_flight_count "$STATE_DIR")" = 2 ] \
    || fail "ship and scout records must both count as work in flight"

  printf '## In flight\n- task [no-mistakes] - the open one\n## Queued\n- later\n' > "$DATA_DIR/backlog.md"
  local focus
  focus=$(fm_context_hygiene_focus_line "$DATA_DIR" "$STATE_DIR")
  case "$focus" in
    *"the open one"*) ;;
    *) fail "focus line did not summarize the in-flight backlog title: $focus" ;;
  esac
  case "$focus" in
    *"later"*) fail "focus line leaked a queued title: $focus" ;;
  esac

  fm_context_hygiene_mark_compact "$STATE_DIR" "Focus on task A"
  [ -f "$STATE_DIR/.context-compact-pending" ] || fail "mark_compact did not write the durable marker"
  [ "$(cat "$STATE_DIR/.context-compact-pending")" = "Focus on task A" ] || fail "marker lost its focus line"
  fm_context_hygiene_clear_marker "$STATE_DIR"
  [ ! -e "$STATE_DIR/.context-compact-pending" ] || fail "clear_marker did not remove the marker"

  # A secondmate-only fleet with no backlog heading falls back to an idle line.
  rm -f "$DATA_DIR/backlog.md" "$STATE_DIR/task.meta" "$STATE_DIR/other.meta"
  focus=$(fm_context_hygiene_focus_line "$DATA_DIR" "$STATE_DIR")
  case "$focus" in
    *idle*) ;;
    *) fail "an idle fleet focus line must say so: $focus" ;;
  esac
  pass "the compact marker is durable and the focus line summarizes remaining open work"
}

# --- idle window -------------------------------------------------------------

test_idle_ready_window() {
  reset_case
  [ "$(fm_context_hygiene_pending_replies "$STATE_DIR")" = 0 ] || fail "no pending-replies dir must read as zero"
  fm_context_hygiene_idle_ready "$STATE_DIR" 900 && fail "the first idle observation must start the window, not report ready"
  [ -f "$STATE_DIR/.context-hygiene-idle-since" ] || fail "the idle window was not started"

  printf '%s\n' "$(( $(date +%s) - 901 ))" > "$STATE_DIR/.context-hygiene-idle-since"
  fm_context_hygiene_idle_ready "$STATE_DIR" 900 || fail "an elapsed idle window with a quiet fleet must report ready"

  printf 'kind=ship\n' > "$STATE_DIR/task.meta"
  fm_context_hygiene_idle_ready "$STATE_DIR" 900 && fail "an in-flight task must block the idle window"
  [ ! -e "$STATE_DIR/.context-hygiene-idle-since" ] || fail "an in-flight task must reset the idle window"
  rm -f "$STATE_DIR/task.meta"

  mkdir -p "$STATE_DIR/pending-replies"
  printf 'phase=awaiting_report\n' > "$STATE_DIR/pending-replies/corr-1"
  printf '%s\n' "$(( $(date +%s) - 901 ))" > "$STATE_DIR/.context-hygiene-idle-since"
  fm_context_hygiene_idle_ready "$STATE_DIR" 900 && fail "a pending captain reply must block the idle window"

  rm -rf "$STATE_DIR/pending-replies"
  printf '1\tsignal\tk\tsignal: x\n' > "$STATE_DIR/.wake-queue"
  printf '%s\n' "$(( $(date +%s) - 901 ))" > "$STATE_DIR/.context-hygiene-idle-since"
  fm_context_hygiene_idle_ready "$STATE_DIR" 900 && fail "a non-empty wake queue must block the idle window"
  pass "idle readiness requires zero in-flight tasks, an empty queue, no pending reply, and a full window"
}

# --- watcher tick delivery ---------------------------------------------------

test_tick_compact_at_boundary() {
  reset_case
  TARGET_EXISTS=0
  fm_context_hygiene_mark_compact "$STATE_DIR" "Focus on the remaining open work"
  context_hygiene_tick
  [ "$(cat "$SENT" 2>/dev/null)" = "/compact Focus on the remaining open work" ] \
    || fail "an idle pane with a pending marker must receive /compact with its focus (sent: $(cat "$SENT" 2>/dev/null))"
  [ ! -e "$STATE_DIR/.context-compact-pending" ] || fail "a confirmed compact must clear the marker"

  # Refused delivery keeps the marker for the next cycle.
  : > "$SENT"
  COMPOSER_STATE=pending
  fm_context_hygiene_mark_compact "$STATE_DIR" "Focus again"
  context_hygiene_tick
  [ -s "$SENT" ] && fail "a pane with pending composer input must not be typed into"
  [ -f "$STATE_DIR/.context-compact-pending" ] || fail "a refused compact must keep the durable marker"
  COMPOSER_STATE=empty

  # A composer that is not affirmatively empty (unknown/unreadable) is refused.
  COMPOSER_STATE=unknown
  context_hygiene_tick
  [ -s "$SENT" ] && fail "an unproven composer must not be typed into"
  [ -f "$STATE_DIR/.context-compact-pending" ] || fail "an unproven-composer refusal must keep the marker"
  COMPOSER_STATE=empty

  # A busy pane also defers.
  BUSY_STATE=busy
  context_hygiene_tick
  [ -s "$SENT" ] && fail "a busy pane must not be typed into"
  [ -f "$STATE_DIR/.context-compact-pending" ] || fail "a busy-pane refusal must keep the marker"
  BUSY_STATE=idle

  # An unknown busy verdict beside a proven-empty composer is still deliverable:
  # the composer proof is the load-bearing guard.
  BUSY_STATE=unknown
  : > "$SENT"
  context_hygiene_tick
  [ "$(cat "$SENT" 2>/dev/null)" = "/compact Focus again" ] \
    || fail "an unknown busy verdict with an empty composer must still deliver (sent: $(cat "$SENT" 2>/dev/null))"
  [ ! -e "$STATE_DIR/.context-compact-pending" ] || fail "a delivered compact must clear the marker"
  BUSY_STATE=idle
  fm_context_hygiene_mark_compact "$STATE_DIR" "Focus again"

  # A harness with no verified compact command drops the marker rather than
  # retrying forever.
  : > "$SENT"
  export FM_CONTEXT_HYGIENE_HARNESS=codex
  _context_hygiene_harness=""
  context_hygiene_tick
  [ -s "$SENT" ] && fail "codex must not be sent a guessed compact command"
  [ ! -e "$STATE_DIR/.context-compact-pending" ] || fail "an unsupported harness must drop the compact marker"

  # An unproven harness must not pin a marker forever and starve idle clear.
  : > "$SENT"
  export FM_CONTEXT_HYGIENE_HARNESS=unknown
  _context_hygiene_harness=""
  fm_context_hygiene_mark_compact "$STATE_DIR" "Focus again"
  context_hygiene_tick
  [ ! -e "$STATE_DIR/.context-compact-pending" ] || fail "an unproven harness pinned the compact marker"
  export FM_CONTEXT_HYGIENE_HARNESS=claude
  _context_hygiene_harness=""
  printf '%s\n' "$(( $(date +%s) - 901 ))" > "$STATE_DIR/.context-hygiene-idle-since"
  context_hygiene_tick
  [ "$(cat "$SENT" 2>/dev/null)" = "/clear" ] \
    || fail "a dropped marker must not starve the idle clear (sent: $(cat "$SENT" 2>/dev/null))"
  pass "the watcher delivers compact at a boundary only into an idle pane, and keeps a refused marker"
}

test_tick_clear_on_idle() {
  reset_case
  export FM_CONTEXT_HYGIENE_HARNESS=claude
  _context_hygiene_harness=""
  # Not yet idle: the first tick starts the window, sends nothing.
  context_hygiene_tick
  [ -s "$SENT" ] && fail "an idle clear must not fire before the window elapses"
  printf '%s\n' "$(( $(date +%s) - 901 ))" > "$STATE_DIR/.context-hygiene-idle-since"
  context_hygiene_tick
  [ "$(cat "$SENT" 2>/dev/null)" = "/clear" ] || fail "an elapsed idle window must send /clear (sent: $(cat "$SENT" 2>/dev/null))"
  local reset_now
  reset_now=$(cat "$STATE_DIR/.context-hygiene-idle-since")
  [ "$(( $(date +%s) - reset_now ))" -lt 60 ] || fail "a delivered clear must restart the idle window"

  # The off switch disables both compact and clear.
  reset_case
  printf 'off\n' > "$CONFIG/context-hygiene"
  fm_context_hygiene_mark_compact "$STATE_DIR" "Focus"
  printf '%s\n' "$(( $(date +%s) - 901 ))" > "$STATE_DIR/.context-hygiene-idle-since"
  context_hygiene_tick
  [ -s "$SENT" ] && fail "config/context-hygiene=off must disable delivery"
  [ -f "$STATE_DIR/.context-compact-pending" ] || fail "the off switch must not consume the marker"
  pass "the watcher clears an idle home and config/context-hygiene=off disables delivery"
}

test_afk_pauses_delivery() {
  reset_case
  export FM_CONTEXT_HYGIENE_HARNESS=claude
  _context_hygiene_harness=""
  : > "$STATE_DIR/.afk"
  fm_context_hygiene_mark_compact "$STATE_DIR" "Focus while away"
  printf '%s\n' "$(( $(date +%s) - 901 ))" > "$STATE_DIR/.context-hygiene-idle-since"
  context_hygiene_tick
  [ -s "$SENT" ] && fail "away mode's daemon owns the pane, so delivery must pause: $(cat "$SENT")"
  [ -f "$STATE_DIR/.context-compact-pending" ] || fail "a paused away-mode compact must keep its marker"
  rm -f "$STATE_DIR/.afk"
  pass "context-hygiene delivery pauses while away mode owns the home's pane"
}

test_reset_idle_failure_does_not_respam() {
  reset_case
  printf '111\n' > "$STATE_DIR/.context-hygiene-idle-since"
  local stamp_before stamp_after
  stamp_before=$(cat "$STATE_DIR/.context-hygiene-idle-since")
  # Force the rewrite to fail; the stamp must be removed so the next poll starts
  # a fresh window instead of re-reading the stale stamp and re-clearing.
  # shellcheck disable=SC2329 # Shadowed for this case only; the sourced lib calls it.
  date() { return 1; }
  fm_context_hygiene_reset_idle "$STATE_DIR"
  unset -f date 2>/dev/null || true
  [ ! -e "$STATE_DIR/.context-hygiene-idle-since" ] \
    || fail "a failed idle reset must drop the stamp (still $stamp_before)"
  stamp_after=$(cat "$STATE_DIR/.context-hygiene-idle-since" 2>/dev/null || true)
  [ -z "$stamp_after" ] || fail "stale idle stamp survived: $stamp_after"
  pass "a failed idle-reset drops the stamp rather than re-clearing every poll"
}

# --- adaptive heartbeat ------------------------------------------------------

test_heartbeat_interval() {
  reset_case
  HEARTBEAT=600
  HEARTBEAT_MAX=3600
  export HEARTBEAT HEARTBEAT_MAX
  printf '0\n' > "$STATE_DIR/.heartbeat-streak"
  [ "$(heartbeat_interval)" = 600 ] || fail "a fresh idle fleet must heartbeat on the base cadence"
  printf '1\n' > "$STATE_DIR/.heartbeat-streak"
  [ "$(heartbeat_interval)" = 1200 ] || fail "the idle cadence must double per streak"
  printf '4\n' > "$STATE_DIR/.heartbeat-streak"
  [ "$(heartbeat_interval)" = 3600 ] || fail "the idle cadence must cap at HEARTBEAT_MAX (got $(heartbeat_interval))"
  printf '99\n' > "$STATE_DIR/.heartbeat-streak"
  [ "$(heartbeat_interval)" = 3600 ] || fail "an over-large streak must still cap"

  # A newly spawned task resets the backoff to the base cadence at once.
  printf 'kind=ship\n' > "$STATE_DIR/task.meta"
  printf '6\n' > "$STATE_DIR/.heartbeat-streak"
  [ "$(heartbeat_interval)" = 600 ] || fail "an in-flight task must hold the base heartbeat cadence"
  [ "$(cat "$STATE_DIR/.heartbeat-streak")" = 0 ] || fail "an in-flight task must reset the backoff streak"
  pass "the heartbeat doubles while idle, caps at the configured idle seconds, and resets on a spawned task"
}

# --- signal coalescing -------------------------------------------------------

test_coalesce_signal_rows() {
  reset_case
  local out count
  out=$(printf 'sf1\t1\tstate/a.status\nsf2\t2\tstate/b.status\nsf1\t3\tstate/a.status\n' | coalesce_signal_rows)
  count=$(printf '%s\n' "$out" | grep -c .)
  [ "$count" = 2 ] || fail "coalescing must collapse a file re-seen by the re-scan (got $count rows)"
  printf '%s\n' "$out" | grep -F 'sf1	3	state/a.status' >/dev/null \
    || fail "coalescing must keep the LAST signature for a repeated file"
  printf '%s\n' "$out" | grep -F 'sf2	2	state/b.status' >/dev/null \
    || fail "coalescing dropped an unrelated file's row"
  pass "a signal file seen by both scans is enqueued once with its last signature"
}

# --- healthy-idle secondmate ------------------------------------------------

test_secondmate_healthy_idle() {
  reset_case
  local meta="$STATE_DIR/mate.meta"
  printf 'kind=secondmate\n' > "$meta"
  INBOX_UNHANDLED=1
  COMPOSER_STATE=empty
  secondmate_healthy_idle mate "$meta" || fail "an empty steering inbox at an empty prompt must be healthy idle"
  INBOX_UNHANDLED=0
  secondmate_healthy_idle mate "$meta" && fail "an unhandled steering record must not read as healthy idle"
  INBOX_UNHANDLED=1
  COMPOSER_STATE=pending
  secondmate_healthy_idle mate "$meta" && fail "an unconfirmed composer must not read as healthy idle"
  COMPOSER_STATE=unknown
  secondmate_healthy_idle mate "$meta" && fail "an unreadable composer must not read as healthy idle"
  COMPOSER_STATE=empty
  # The inbox half must be positively proven too: an unreadable or non-directory
  # inbox is not "empty".
  : > "$STATE_DIR/mate.inbox"
  secondmate_healthy_idle mate "$meta" && fail "a non-directory steering inbox must not read as empty"
  rm -f "$STATE_DIR/mate.inbox"
  mkdir -p "$STATE_DIR/mate.inbox"
  chmod 000 "$STATE_DIR/mate.inbox"
  if [ ! -r "$STATE_DIR/mate.inbox" ]; then
    secondmate_healthy_idle mate "$meta" && fail "an unreadable steering inbox must not read as empty"
  fi
  chmod 700 "$STATE_DIR/mate.inbox"
  rm -rf "$STATE_DIR/mate.inbox"
  pass "a healthy-idle mate needs both an empty steering inbox and a proven-empty prompt"
}

# The stall tick consumes secondmate_healthy_idle: an idle mate with an empty
# steering inbox and a frozen foreign queue is healthy idle and must not alert,
# while an unproven-idle pane on the same queue still escalates.
test_stall_tick_suppresses_healthy_idle() {
  reset_case
  local mate_home="$TMP/mate" meta="$STATE_DIR/mate.meta" now epoch
  mkdir -p "$mate_home/state"
  printf 'mate\n' > "$mate_home/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$mate_home" > "$meta"
  now=$(date +%s)
  epoch=$(( now - 100 ))
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$epoch" > "$mate_home/state/.wake-queue"
  printf '%s %s-7\n' "$(( now - 2 ))" "$epoch" > "$STATE_DIR/.secondmate-wake-progress-mate"
  SECONDMATE_WAKE_STALL_SECS=1
  export SECONDMATE_WAKE_STALL_SECS
  INBOX_UNHANDLED=1
  COMPOSER_STATE=empty
  secondmate_in_active_turn() { return 1; }

  secondmate_wake_stall_tick
  [ ! -s "$SENT" ] || fail "a healthy-idle mate with an empty steering inbox was escalated as stalled: $(cat "$SENT")"
  [ ! -s "$STATE_DIR/.wake-queue" ] || fail "a healthy-idle mate produced a durable stall notification"

  COMPOSER_STATE=pending
  secondmate_wake_stall_tick
  grep -F 'WAKE check: secondmate wake-loop stalled' "$SENT" >/dev/null \
    || fail "an unproven-idle pane with a frozen queue must still escalate: $(cat "$SENT")"
  pass "the stall tick suppresses a healthy-idle mate and still escalates an unproven-idle one"
}

test_command_table
test_off_switch_and_seconds
test_watcher_cadence_wiring
test_marker_focus_and_in_flight
test_idle_ready_window
test_tick_compact_at_boundary
test_tick_clear_on_idle
test_afk_pauses_delivery
test_reset_idle_failure_does_not_respam
test_heartbeat_interval
test_coalesce_signal_rows
test_secondmate_healthy_idle
test_stall_tick_suppresses_healthy_idle

echo "# fm-context-hygiene.test.sh: all assertions passed"
