#!/usr/bin/env bash
# fm-capacity-retry.sh - auto-retry spawns queued due to spawn-capacity limits.
#
# Heartbeat job that checks if machine capacity headroom has returned.
# If headroom is available, retries queued spawn commands in FIFO order.
#
# Usage:
#   fm-capacity-retry.sh
#
# Exit codes:
#   0  Retries completed or capacity still exceeded.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
CONFIG="$FM_HOME/config"
QUEUE_DIR="$STATE/capacity-queue"

[ -d "$QUEUE_DIR" ] || exit 0

# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"

shopt -s nullglob
cmd_files=("$QUEUE_DIR"/*.cmd)
shopt -u nullglob

[ "${#cmd_files[@]}" -gt 0 ] || exit 0

# Evaluate current machine capacity headroom.
if ! fm_capacity_evaluate "$CONFIG"; then
  exit 0
fi

for cmd_file in "${cmd_files[@]}"; do
  [ -f "$cmd_file" ] || continue

  args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < "$cmd_file"

  [ "${#args[@]}" -gt 0 ] || { rm -f "$cmd_file"; continue; }
  task=${args[1]:-unknown}

  # Re-evaluate capacity before each attempt: each spawn takes resources.
  if ! fm_capacity_evaluate "$CONFIG"; then
    break
  fi

  echo "capacity-retry: retrying spawn for $task" >&2
  rm -f "$cmd_file"
  if ! "${args[@]}"; then
    echo "capacity-retry: retry for $task exited non-zero" >&2
  else
    echo "capacity-retry: successfully spawned $task" >&2
  fi
done

exit 0
