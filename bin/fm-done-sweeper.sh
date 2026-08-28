#!/usr/bin/env bash
# fm-done-sweeper.sh - auto-tear down Done homes exceeding keepDone limit.
#
# Heartbeat job that identifies finished tasks whose work has landed or PR is
# merged/closed, keeping only the most recent keepDone entries (default: 5).
# Removes pooled worktrees and frees pool slots for new tasks.
#
# Usage:
#   fm-done-sweeper.sh [--keep <N>] [--dry-run]
#
# Exit codes:
#   0  Sweep completed successfully (or nothing to sweep).
#   1  Fatal error or dependency missing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
CONFIG="$FM_HOME/config"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

KEEP_DONE=5
if [ -f "$CONFIG/keepDone" ]; then
  configured_keep=$(tr -d '[:space:]' < "$CONFIG/keepDone")
  case "$configured_keep" in
    ''|*[!0-9]*) ;;
    *) KEEP_DONE=$configured_keep ;;
  esac
fi
KEEP_DONE="${FM_KEEP_DONE:-$KEEP_DONE}"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)
      KEEP_DONE="${2:-5}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help|help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *)
      case "$1" in
        ''|*[!0-9]*)
          echo "error: unrecognized argument: $1" >&2
          exit 1
          ;;
        *)
          KEEP_DONE="$1"
          shift
          ;;
      esac
      ;;
  esac
done

case "$KEEP_DONE" in
  ''|*[!0-9]*) KEEP_DONE=5 ;;
esac

[ -d "$STATE" ] || exit 0

pr_state_of() {  # <meta-file> <pr-url>
  local meta=$1 pr=$2 state
  if [ -n "${FM_TEST_GH_STATE:-}" ]; then
    printf '%s\n' "$FM_TEST_GH_STATE"
    return 0
  fi
  [ -n "$pr" ] || return 1
  if command -v gh >/dev/null 2>&1; then
    state=$(gh pr view "$pr" --json state -q .state 2>/dev/null || true)
    if [ -n "$state" ]; then
      printf '%s\n' "$state"
      return 0
    fi
  fi
  return 1
}

# Collect finished tasks: state done + PR merged/closed (or scout with report).
candidates=()
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  task=$(basename "$meta")
  task="${task%.meta}"

  # Skip secondmates: secondmate retirement follows a different lifecycle.
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" != "secondmate" ] || continue

  status_file="$STATE/$task.status"
  [ -f "$status_file" ] || continue

  last=$(last_status_line "$status_file")
  verb=$(status_line_verb "$last")
  case "$verb" in
    done|[Dd]one) ;;
    *) continue ;;
  esac

  pr=$(fm_meta_get "$meta" pr)
  is_eligible=0
  if [ -n "$pr" ]; then
    pr_state=$(pr_state_of "$meta" "$pr" || true)
    case "$pr_state" in
      MERGED|merged|CLOSED|closed) is_eligible=1 ;;
      *) is_eligible=0 ;;
    esac
  elif [ "$kind" = "scout" ]; then
    if [ -f "$FM_HOME/data/$task/report.md" ]; then
      is_eligible=1
    fi
  fi

  [ "$is_eligible" = 1 ] || continue

  # Get timestamp (mtime of status file) for sorting.
  mtime=$(stat -f %m "$status_file" 2>/dev/null || stat -c %Y "$status_file" 2>/dev/null || date +%s)
  candidates+=("$mtime $task")
done

total=${#candidates[@]}
if [ "$total" -le "$KEEP_DONE" ]; then
  exit 0
fi

# Sort oldest first by timestamp.
sorted=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  sorted+=("$line")
done < <(printf '%s\n' "${candidates[@]}" | sort -n)

excess=$((total - KEEP_DONE))
for ((i=0; i<excess; i++)); do
  entry="${sorted[$i]}"
  victim="${entry#* }"
  if [ "$DRY_RUN" = 1 ]; then
    echo "done-sweeper: [dry-run] would tear down $victim (PR merged/closed, keepDone: $KEEP_DONE)"
  else
    echo "done-sweeper: auto-tearing down $victim (PR merged/closed, keepDone: $KEEP_DONE)"
    if "$SCRIPT_DIR/fm-teardown.sh" "$victim" 2>&1; then
      echo "done-sweeper: auto-torn down $victim (PR merged/closed, keepDone: $KEEP_DONE)"
    else
      echo "done-sweeper: warning: teardown failed for $victim" >&2
    fi
  fi
done

exit 0
