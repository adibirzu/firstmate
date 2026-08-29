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

  # Re-evaluate capacity before each attempt: each spawn takes resources.
  if ! fm_capacity_evaluate "$CONFIG"; then
    break
  fi

  inflight_file="$cmd_file.inflight"
  if ! mv "$cmd_file" "$inflight_file"; then
    continue
  fi

  args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < "$inflight_file"

  [ "${#args[@]}" -gt 0 ] || { rm -f "$inflight_file"; continue; }
  task=${args[1]:-unknown}
  echo "capacity-retry: retrying spawn for $task" >&2
  if ! "${args[@]}"; then
    echo "capacity-retry: retry for $task exited non-zero" >&2
    if [ ! -e "$STATE/$task.meta" ] && [ ! -L "$STATE/$task.meta" ]; then
      mv "$inflight_file" "$cmd_file" 2>/dev/null || true
    else
      rm -f "$inflight_file"
    fi
  else
    rm -f "$inflight_file"
    echo "capacity-retry: successfully spawned $task" >&2
  fi
done

exit 0
