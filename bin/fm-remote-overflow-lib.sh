#!/usr/bin/env bash
# fm-remote-overflow-lib.sh - route a refused local spawn to a remote secondmate home.
#
# Sourced, never executed. When the machine-capacity guard declines a fresh
# ship or scout spawn, this library offers the work to a registered remote
# secondmate home whose host has headroom, through the existing remote
# secondmate handoff (bin/fm-backlog-handoff.sh), rather than queueing locally.
# docs/remote-secondmates.md owns why an individual worker is never placed
# remotely: the handoff moves the queued backlog item into the remote home's
# own backlog, and that home's mate dispatches it under its own capacity guard.
#
# Placement contract (owned here, not restated elsewhere):
#   - Only fresh ship/scout spawns are eligible. Secondmate spawns are
#     persistent mates, not overflowable work; reuse-worktree relaunches own
#     an existing local task and must never be stolen away.
#   - Only a Queued, unheld, unblocked local backlog item moves. In-flight
#     work stays where its worker is.
#   - Remote candidates are the remote records in data/secondmates.md, probed
#     in alphabetical id order; the first whose host reports headroom wins.
#     Alphabetical is the documented tie-break: it is deterministic, needs no
#     cross-host load comparison, and is trivially testable.
#   - A probe that times out or errors means "no headroom there", never a
#     crash and never permission to assume headroom. The Mac's own thresholds
#     are never loosened to force a local launch instead.
#   - When no remote home has headroom, the caller falls back to today's
#     refusal exactly: nothing moves, nothing is dropped.
#
# Probing runs `fm-capacity.sh check` on the remote host through bin/fm-on.sh,
# which is read-only there. Each probe is hard-bounded by fm_run_timed
# (bin/fm-timeout-lib.sh) with tightened SSH dead-peer knobs, so a vanished
# host fails in seconds instead of hanging the spawn.
#
# On success the caller prints `routed <id> remote=<mate> host=<alias>` to
# stdout, which is where the requester learns which machine the task landed
# on. No local task metadata exists at refusal time (the guard runs before any
# mutation), so there is deliberately no meta write here; the durable record
# is the item now owned by the remote home's backlog.
#
# Environment:
#   FM_OVERFLOW=0|off|no   disable overflow; the guard refusal stands as-is.
#   FM_OVERFLOW_NO_REMOTE=1  disable overflow (recursion/test guard).
#   FM_OVERFLOW_PROBE_SECONDS  per-remote probe bound in seconds (default 90).
#   FM_OVERFLOW_FM_ON      fm-on.sh implementation (default bin/fm-on.sh);
#                          a test seam in the fm-station-idle.sh tradition.
#   FM_OVERFLOW_HANDOFF    fm-backlog-handoff.sh implementation
#                          (default bin/fm-backlog-handoff.sh); same tradition.
#
# Functions:
#   fm_overflow_enabled
#       Return 0 unless overflow is disabled by environment.
#   fm_overflow_remote_ids
#       Print one remote secondmate id per line, alphabetical, from $DATA.
#   fm_overflow_probe <id>
#       Return 0 when that remote home's host reports capacity headroom.
#   fm_overflow_pick
#       Print `<id> <host>` for the first remote home with headroom, or
#       return 1 when no remote home qualifies.
#   fm_overflow_try <id>
#       Move Queued item <id> to the picked remote home. On success print
#       `routed <id> remote=<mate> host=<alias>` to stdout and return 0;
#       otherwise return 1 having moved nothing the handoff did not own.
set -u

_FM_OVERFLOW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$_FM_OVERFLOW_LIB_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_OVERFLOW_LIB_DIR/fm-timeout-lib.sh"

fm_overflow_enabled() {
  case "${FM_OVERFLOW:-}" in 0|off|no|OFF|NO) return 1 ;; esac
  [ -z "${FM_OVERFLOW_NO_REMOTE:-}" ] || return 1
  return 0
}

fm_overflow_fm_on() {
  if [ -n "${FM_OVERFLOW_FM_ON:-}" ]; then
    printf '%s\n' "$FM_OVERFLOW_FM_ON"
  else
    printf '%s\n' "$_FM_OVERFLOW_LIB_DIR/fm-on.sh"
  fi
}

fm_overflow_handoff() {
  if [ -n "${FM_OVERFLOW_HANDOFF:-}" ]; then
    printf '%s\n' "$FM_OVERFLOW_HANDOFF"
  else
    printf '%s\n' "$_FM_OVERFLOW_LIB_DIR/fm-backlog-handoff.sh"
  fi
}

fm_overflow_probe_seconds() {
  case "${FM_OVERFLOW_PROBE_SECONDS:-}" in
    ''|*[!0-9]*) printf '90\n' ;;
    0) printf '90\n' ;;
    *) printf '%s\n' "$FM_OVERFLOW_PROBE_SECONDS" ;;
  esac
}

fm_overflow_remote_ids() {  # reads $DATA/secondmates.md
  local reg="${DATA:-}/secondmates.md" line
  [ -f "$reg" ] && [ ! -L "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" 2>/dev/null || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
    [ -n "$SECONDMATE_REGISTRY_ID" ] || continue
    printf '%s\n' "$SECONDMATE_REGISTRY_ID"
  done < "$reg" | LC_ALL=C sort -u
}

fm_overflow_probe() {  # <secondmate-id>
  local id=$1 fm_on seconds rc=0
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  fm_on=$(fm_overflow_fm_on)
  seconds=$(fm_overflow_probe_seconds)
  [ -x "$fm_on" ] || [ -f "$fm_on" ] || return 1
  # Tight dead-peer knobs bound a vanished host; a slow-but-alive host still
  # completes under the outer hard bound. Any failure is "no headroom there".
  if FM_SSH_ALIVE_INTERVAL=5 FM_SSH_ALIVE_COUNT_MAX=3 \
    fm_run_timed "$seconds" "$fm_on" "$id" fm-capacity.sh check \
    >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ]
}

fm_overflow_pick() {  # prints "<id> <host>"
  local id host
  fm_overflow_enabled || return 1
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    fm_overflow_probe "$id" || continue
    host=$(secondmate_registry_field "${DATA:-}/secondmates.md" "$id" host 2>/dev/null || true)
    [ -n "$host" ] || continue
    printf '%s %s\n' "$id" "$host"
    return 0
  done < <(fm_overflow_remote_ids)
  return 1
}

fm_overflow_try() {  # <task-id>
  local id=$1 pick mate host handoff handoff_out rc
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  pick=$(fm_overflow_pick) || return 1
  mate=${pick%% *}
  host=${pick#* }
  [ -n "$mate" ] && [ -n "$host" ] || return 1
  handoff=$(fm_overflow_handoff)
  handoff_out=$("$handoff" "$mate" "$id" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$handoff_out" | sed 's/^/overflow handoff: /' >&2 || true
    return 1
  fi
  echo "routed $id remote=$mate host=$host"
  return 0
}
