# shellcheck shell=bash
# fm-context-hygiene-lib.sh - context-hygiene policy for a home's own agent.
#
# A home's primary or secondmate agent is long-lived: every supervision wake is
# another full-context turn, so an agent that never compacts or clears
# accumulates a very large context and spends most of its budget on it. This
# library is the single owner of the policy that lets such an agent compact at
# a task boundary and clear while idle, plus the config knobs that gate it:
#
#   config/context-hygiene               literal "off" disables the feature
#   config/context-hygiene-idle-seconds  continuous idle seconds before a clear
#   config/wake-coalesce-seconds         signal-coalescing window (watcher)
#   config/heartbeat-idle-seconds        idle-fleet heartbeat backoff cap (watcher)
#
# Only the DELIVERY of a compact/clear command is a side effect, and the caller
# owns it because it needs the source home's backend primitives. This library
# owns the decisions: whether the feature is on, how long idle must last, which
# command a harness understands, when the home counts as idle, and the durable
# compact-pending marker the watcher drains after a task boundary.
#
# The per-harness command table is deliberately conservative: a command is
# listed only where a firstmate verification record proves it, so an unproven
# harness is sent nothing rather than guessing at a context-reset command.
#
# Usage: . bin/fm-context-hygiene-lib.sh

FM_CONTEXT_HYGIENE_FILE="context-hygiene"
FM_CONTEXT_HYGIENE_IDLE_DEFAULT=900
# shellcheck disable=SC2034 # Consumed by bin/fm-watch.sh's cadence wiring.
FM_WAKE_COALESCE_DEFAULT=20
# shellcheck disable=SC2034 # Consumed by bin/fm-watch.sh's heartbeat wiring.
FM_HEARTBEAT_IDLE_DEFAULT=3600

FM_CONTEXT_COMPACT_MARKER=".context-compact-pending"
FM_CONTEXT_IDLE_SINCE=".context-hygiene-idle-since"

# fm_context_hygiene_setting <config-dir> <file>
# Print the first non-empty, non-comment line of a config file with surrounding
# whitespace trimmed, or nothing when the file is absent/empty/unreadable. The
# same per-script first-line convention bin/fm-inbox.sh and bin/fm-harness.sh use.
fm_context_hygiene_setting() {
  local dir=$1 name=$2 path line
  path="$dir/$name"
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    printf '%s' "$line"
    return 0
  done < "$path"
  return 0
}

# fm_context_hygiene_disabled <config-dir>
# 0 only for the exact literal `off`, case-insensitive. An absent or unreadable
# file leaves the feature on, matching the documented "absent means on"
# contract; callers treat a non-zero result as enabled.
fm_context_hygiene_disabled() {
  local value
  value=$(fm_context_hygiene_setting "$1" "$FM_CONTEXT_HYGIENE_FILE")
  case "$value" in
    off|OFF|Off|oFf|ofF|OFf|oFF|OfF) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_context_hygiene_seconds <config-dir> <file> <default>
# Print a positive base-10 integer from the named config file, or the default
# when the file is absent, empty, or malformed. Leading-zero forms (00, 08) are
# rejected too: an 08 would later trip an octal arithmetic error, and 00 is not a
# usable timer. A malformed value never becomes a zero-second timer.
fm_context_hygiene_seconds() {
  local dir=$1 name=$2 default=$3 value
  value=$(fm_context_hygiene_setting "$dir" "$name")
  case "$value" in
    ''|*[!0-9]*|0*) printf '%s\n' "$default" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# fm_context_hygiene_harness
# The home's own harness: an explicit FM_CONTEXT_HYGIENE_HARNESS test/override
# seam, else bin/fm-harness.sh's detection. That detection is env-marker first
# (CLAUDECODE, PI_CODING_AGENT, GROK_AGENT, ...), which every watcher process
# inherits from the harness that launched it even when it is reparented, so the
# two harnesses with verified context commands (Claude and Pi) are identifiable
# from the watcher; markerless harnesses fall back to process ancestry.
fm_context_hygiene_harness() {
  local script_dir=$1 harness
  if [ -n "${FM_CONTEXT_HYGIENE_HARNESS:-}" ]; then
    printf '%s\n' "$FM_CONTEXT_HYGIENE_HARNESS"
    return 0
  fi
  harness=$("$script_dir/fm-harness.sh" 2>/dev/null || printf unknown)
  [ -n "$harness" ] || harness=unknown
  printf '%s\n' "$harness"
}

# fm_context_hygiene_command <harness> <compact|clear>
# Print the harness's context command, or nothing when that harness has no
# verified command for the operation. Claude and Pi are listed because
# docs/verification/supervision.md records their behavior; every other harness
# currently has no proven context-reset command and is sent nothing.
#   Claude 2.1.222: /clear reports source=clear, /compact reports source=compact
#   Pi 0.82.0:      /new reports session_start reason new, /compact reports
#                   session_compact (both re-injected fresh hook output)
fm_context_hygiene_command() {
  local harness=$1 op=$2
  case "$harness:$op" in
    claude:compact) printf '/compact\n' ;;
    claude:clear) printf '/clear\n' ;;
    pi:compact|pi-signed:compact) printf '/compact\n' ;;
    pi:clear|pi-signed:clear) printf '/new\n' ;;
    *) return 0 ;;
  esac
}

# fm_context_hygiene_compact_command <harness> <focus-line>
# The compact command to deliver, with the marker's one-line focus appended
# where the harness accepts it. Claude's /compact takes free-text instructions;
# Pi's does not have a verified focus argument, so it gets the bare command.
fm_context_hygiene_compact_command() {
  local harness=$1 focus=$2 base
  base=$(fm_context_hygiene_command "$harness" compact)
  [ -n "$base" ] || return 0
  if [ "$harness" = claude ] && [ -n "$focus" ]; then
    printf '%s %s\n' "$base" "$focus"
  else
    printf '%s\n' "$base"
  fi
}

# fm_context_hygiene_marker_path <state>
fm_context_hygiene_marker_path() { printf '%s/%s' "$1" "$FM_CONTEXT_COMPACT_MARKER"; }

# fm_context_hygiene_mark_compact <state> <focus-line>
# Durably record that this home should compact at its next idle boundary. The
# marker survives a watcher restart and is removed only after a confirmed
# delivery, so a boundary reached while the agent is mid-turn is not lost.
fm_context_hygiene_mark_compact() {
  local state=$1 focus=$2 marker tmp
  [ -n "$state" ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  marker=$(fm_context_hygiene_marker_path "$state")
  focus=$(printf '%s' "$focus" | tr '\n\r' '  ')
  tmp=$(umask 077; mktemp "$state/.context-compact.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$focus" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$marker"
}

# fm_context_hygiene_clear_marker <state>
fm_context_hygiene_clear_marker() {
  local marker
  marker=$(fm_context_hygiene_marker_path "$1")
  rm -f -- "$marker"
}

# fm_context_hygiene_focus_line <data-dir> [<state-dir>]
# A one-line summary of the home's remaining open work for /compact's focus
# argument. Prefers the backlog's in-flight title lines; falls back to a plain
# count of live task records when the backlog has no In-flight heading yet.
fm_context_hygiene_focus_line() {
  local data=$1 state=${2:-} collected='' inf=0 line count=0
  if [ -n "$state" ]; then
    count=$(fm_context_hygiene_in_flight_count "$state")
  fi
  if [ -f "$data/backlog.md" ] && [ ! -L "$data/backlog.md" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '## In flight'*) inf=1; continue ;;
        '## '*) [ "$inf" -eq 1 ] && break; continue ;;
      esac
      [ "$inf" -eq 1 ] || continue
      case "$line" in
        [-*][[:space:]]*)
          line=${line//$'\t'/ }
          collected="${collected}${collected:+; }$line"
          ;;
      esac
    done < "$data/backlog.md"
  fi
  if [ -n "$collected" ]; then
    printf 'Focus on the remaining open work for this home: %s\n' "$collected"
  elif [ "$count" -gt 0 ]; then
    printf 'Focus on the %s remaining in-flight task(s) for this home.\n' "$count"
  else
    printf 'Focus on the remaining open work for this home; the fleet is currently idle.\n'
  fi
}

# fm_context_hygiene_in_flight_count <state>
# Count live task records that are not persistent secondmates. A secondmate
# record names a long-lived home, not work in flight, so it never blocks the
# idle-clear condition.
fm_context_hygiene_in_flight_count() {
  local state=$1 meta kind count=0
  [ -d "$state" ] || { printf '0\n'; return 0; }
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | head -n1)
    [ "$kind" = secondmate ] && continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# fm_context_hygiene_pending_replies <state>
# Count unresolved secondmate pending-reply records. A resolved record is
# removed by bin/fm-pending-reply-lib.sh, so any regular record file present
# means this home still owes or awaits a reply.
fm_context_hygiene_pending_replies() {
  local state=$1 dir count=0 f
  dir="$state/pending-replies"
  [ -d "$dir" ] && [ ! -L "$dir" ] || { printf '0\n'; return 0; }
  for f in "$dir"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "${f##*/}" in .*) continue ;; esac
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# fm_context_hygiene_wake_queue_empty <state>
# 0 when the durable wake queue has no actionable rows (absent or empty). A
# non-empty queue means a wake is still owed a handling turn, so the home is
# not idle even when this watcher cycle has nothing to present.
fm_context_hygiene_wake_queue_empty() {
  local queue="$1/.wake-queue"
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  [ -s "$queue" ] && return 1
  return 0
}

# fm_context_hygiene_idle_ready <state> <idle-seconds>
# 0 when this home has been fully idle for at least <idle-seconds>: zero
# in-flight tasks, an empty wake queue, and no pending captain reply. Tracks the
# continuous window in state/.context-hygiene-idle-since, resetting it the
# moment any condition fails, so the timer measures uninterrupted idleness
# rather than elapsed wall clock.
fm_context_hygiene_idle_ready() {
  local state=$1 idle=$2 since now
  case "$idle" in ''|*[!0-9]*|0) idle=$FM_CONTEXT_HYGIENE_IDLE_DEFAULT ;; esac
  if [ "$(fm_context_hygiene_in_flight_count "$state")" -ne 0 ] \
    || [ "$(fm_context_hygiene_pending_replies "$state")" -ne 0 ] \
    || ! fm_context_hygiene_wake_queue_empty "$state"; then
    rm -f -- "$state/$FM_CONTEXT_IDLE_SINCE"
    return 1
  fi
  since=$(cat "$state/$FM_CONTEXT_IDLE_SINCE" 2>/dev/null || true)
  case "$since" in ''|*[!0-9]*) since= ;; esac
  if [ -z "$since" ]; then
    date +%s > "$state/$FM_CONTEXT_IDLE_SINCE" 2>/dev/null || true
    return 1
  fi
  now=$(date +%s)
  [ $((now - since)) -ge "$idle" ]
}

# fm_context_hygiene_reset_idle <state>
# Restart the continuous-idle window, called after a delivered clear so the next
# clear waits a full window rather than firing on the following poll. If the
# stamp cannot be rewritten, remove it so the next poll starts a fresh window
# instead of re-reading the stale stamp and re-clearing every cycle.
fm_context_hygiene_reset_idle() {
  if ! date +%s > "$1/$FM_CONTEXT_IDLE_SINCE" 2>/dev/null; then
    rm -f -- "$1/$FM_CONTEXT_IDLE_SINCE" 2>/dev/null || true
  fi
}
