#!/usr/bin/env bash
# fm-session-continuity.sh - bounded, read-only recovery index for a new
# Firstmate conversation that cannot yet own this home's fleet lock.
#
# Usage: fm-session-continuity.sh
#
# This command never claims or changes the fleet lock, drains wakes, contacts a
# backend, or writes state.  It projects only durable local task records so a
# replacement session can find every prior task's brief, worktree, endpoint,
# and most recent status EVENT before the normal startup digest's bulk output.
# The status value is deliberately labelled historical: fm-crew-state.sh owns
# current-state reconciliation once a verified lock-owning session is running.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

meta_value() { # <path> <key>
  awk -v key="$2" '
    index($0, key "=") == 1 { value = substr($0, length(key) + 2) }
    END { print value }
  ' "$1" 2>/dev/null
}

last_status_event() { # <path>
  awk 'NF { event = $0 } END { print event }' "$1" 2>/dev/null | cut -c1-240
}

printf 'SESSION CONTINUITY - DURABLE LOCAL RECOVERY INDEX\n'
printf '%s\n' 'This is read-only evidence, not a fleet-lock takeover or current-state reconciliation.'

if [ ! -d "$STATE" ]; then
  printf 'No state directory exists at %s.\n' "$STATE"
  exit 0
fi

count=0
skipped=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  id=${meta##*/}
  id=${id%.meta}
  count=$((count + 1))
  kind=$(meta_value "$meta" kind)
  project=$(meta_value "$meta" project)
  harness=$(meta_value "$meta" harness)
  backend=$(meta_value "$meta" backend)
  endpoint=$(meta_value "$meta" endpoint_task_id)
  worktree=$(meta_value "$meta" worktree)
  pr=$(meta_value "$meta" pr)
  [ -n "$kind" ] || kind=ship
  [ -n "$backend" ] || backend=tmux
  [ -n "$endpoint" ] || endpoint='<not recorded>'
  [ -n "$project" ] || project='<not recorded>'
  [ -n "$harness" ] || harness='<not recorded>'
  [ -n "$worktree" ] || worktree='<not recorded>'

  printf '\n- task: %s\n' "$id"
  printf '  kind: %s; project: %s; harness: %s\n' "$kind" "$project" "$harness"
  printf '  endpoint: %s/%s; worktree: %s\n' "$backend" "$endpoint" "$worktree"
  [ -n "$pr" ] && printf '  recorded PR: %s\n' "$pr"
  [ -f "$DATA/$id/brief.md" ] && printf '  brief: %s\n' "$DATA/$id/brief.md"
  [ -f "$DATA/$id/report.md" ] && printf '  report: %s\n' "$DATA/$id/report.md"
  event=$(last_status_event "$STATE/$id.status")
  [ -n "$event" ] && printf '  latest status EVENT (not current state): %s\n' "$event"
done

if [ "$count" -eq 0 ]; then
  printf 'No durable task metadata is recorded.\n'
else
  printf '\nRecorded task metadata: %s.\n' "$count"
fi
[ "$skipped" -eq 0 ] || printf 'Skipped %s unsafe or unreadable metadata record(s).\n' "$skipped"
