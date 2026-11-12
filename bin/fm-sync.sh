#!/usr/bin/env bash
# fm-sync.sh - convenience terminal entrypoint for FirstMate task synchronization.
#
# Usage:
#   fm-sync [--direct] [--dry-run] [--project <slug>] [--initiative <id>]
#           [--limit <n>] [--request-id <id>] [--json] [--] [<message>...]
#   fm-sync --help
#
# Behavior:
#   1. Inspects the target FirstMate home ($FM_HOME, defaulting to this script's
#      repository root) via `bin/fm-inbox.sh ready`.
#   2. When a live FirstMate primary holds the home lock with a healthy wake
#      consumer (`can_receive: true`) and neither `--direct` nor `--dry-run` was
#      passed, enqueues an idempotent inbox note via
#      `bin/fm-inbox.sh note --request-id <uuid> --json -- "<message>"` so the
#      live session wakes immediately and handles synchronization (plus any
#      requested `adi0` task dispatches in `<message>`).
#   3. When no live FirstMate session is currently receiving wakes (or when
#      `--direct` / `--dry-run` is passed), runs `bin/fm-task-sync.sh` directly
#      (`--apply` by default, `--dry-run` when requested) and prints the
#      standalone outcome digest immediately.
set -euo pipefail

for _extra in "$HOME/.toolbox/bin" "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$_extra:"*) ;;
    *) [ -d "$_extra" ] && PATH="$PATH:$_extra" ;;
  esac
done
unset _extra
export PATH

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  LINK_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"
  LINK_TARGET="$(readlink "$SOURCE_PATH")"
  case "$LINK_TARGET" in
    /*) SOURCE_PATH="$LINK_TARGET" ;;
    *) SOURCE_PATH="$LINK_DIR/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"
TRACKED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FM_HOME="${FM_HOME:-$TRACKED_ROOT}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SOURCE_PATH"
}

die() {
  printf 'fm-sync: %s\n' "$*" >&2
  exit 2
}

DIRECT=0
DRY_RUN=0
JSON_OUT=0
PROJECT_FILTER=""
INITIATIVE_FILTER=""
LIMIT=""
REQUEST_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --direct)
      DIRECT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    --project)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--project requires a non-empty slug"
      PROJECT_FILTER=$2
      shift 2
      ;;
    --project=*)
      PROJECT_FILTER=${1#--project=}
      [ -n "$PROJECT_FILTER" ] || die "--project requires a non-empty slug"
      shift
      ;;
    --initiative)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--initiative requires a non-empty id"
      INITIATIVE_FILTER=$2
      shift 2
      ;;
    --initiative=*)
      INITIATIVE_FILTER=${1#--initiative=}
      [ -n "$INITIATIVE_FILTER" ] || die "--initiative requires a non-empty id"
      shift
      ;;
    --limit)
      [ "$#" -ge 2 ] || die "--limit requires a non-negative integer"
      case "$2" in
        ''|*[!0-9]*) die "--limit must be a non-negative integer (got '$2')" ;;
      esac
      LIMIT=$2
      shift 2
      ;;
    --limit=*)
      LIMIT=${1#--limit=}
      case "$LIMIT" in
        ''|*[!0-9]*) die "--limit must be a non-negative integer (got '$LIMIT')" ;;
      esac
      shift
      ;;
    --request-id)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--request-id requires a non-empty id"
      REQUEST_ID=$2
      shift 2
      ;;
    --request-id=*)
      REQUEST_ID=${1#--request-id=}
      [ -n "$REQUEST_ID" ] || die "--request-id requires a non-empty id"
      shift
      ;;
    --)
      shift
      break
      ;;
    --*)
      die "unknown option: $1 (pass --help for usage)"
      ;;
    *)
      break
      ;;
  esac
done

MESSAGE="$*"
if [ -z "${MESSAGE//[[:space:]]/}" ]; then
  if [ -n "$PROJECT_FILTER" ]; then
    MESSAGE="sync ${PROJECT_FILTER} development tasks"
  else
    MESSAGE="sync all development tasks"
  fi
fi

SCOPE_TAGS=""
if [ -n "$PROJECT_FILTER" ]; then
  SCOPE_TAGS="${SCOPE_TAGS} --project ${PROJECT_FILTER}"
fi
if [ -n "$INITIATIVE_FILTER" ]; then
  SCOPE_TAGS="${SCOPE_TAGS} --initiative ${INITIATIVE_FILTER}"
fi
if [ -n "$LIMIT" ]; then
  SCOPE_TAGS="${SCOPE_TAGS} --limit ${LIMIT}"
fi
if [ -n "$SCOPE_TAGS" ]; then
  MESSAGE="${MESSAGE} (${SCOPE_TAGS# })"
fi

INBOX_BIN="${FM_SYNC_INBOX_BIN:-}"
if [ -z "$INBOX_BIN" ]; then
  if [ -x "$SCRIPT_DIR/fm-inbox.sh" ]; then
    INBOX_BIN="$SCRIPT_DIR/fm-inbox.sh"
  else
    INBOX_BIN="$FM_HOME/bin/fm-inbox.sh"
  fi
fi

TASK_SYNC_BIN="${FM_SYNC_TASK_SYNC_BIN:-}"
if [ -z "$TASK_SYNC_BIN" ]; then
  if [ -x "$SCRIPT_DIR/fm-task-sync.sh" ]; then
    TASK_SYNC_BIN="$SCRIPT_DIR/fm-task-sync.sh"
  elif [ -x "$FM_HOME/bin/fm-task-sync.sh" ]; then
    TASK_SYNC_BIN="$FM_HOME/bin/fm-task-sync.sh"
  else
    die "could not locate bin/fm-task-sync.sh"
  fi
fi

CAN_RECEIVE="false"
if [ "$DIRECT" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ -x "$INBOX_BIN" ]; then
  ready_json=$(FM_HOME="$FM_HOME" bash "$INBOX_BIN" ready 2>/dev/null || true)
  if [ -n "$ready_json" ]; then
    CAN_RECEIVE=$(python3 -c '
import json, sys
try:
    doc = json.loads(sys.argv[1])
    print("true" if doc.get("can_receive") is True else "false")
except Exception:
    print("false")
' "$ready_json")
  fi
fi

if [ "$CAN_RECEIVE" = "true" ] && [ "$DIRECT" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "$REQUEST_ID" ]; then
    REQUEST_ID=$(python3 -c 'import uuid; print("fm-sync-" + uuid.uuid4().hex)')
  fi
  note_out=$(FM_HOME="$FM_HOME" bash "$INBOX_BIN" note --request-id "$REQUEST_ID" --json -- "$MESSAGE")
  if [ "$JSON_OUT" -eq 1 ]; then
    printf '%s\n' "$note_out"
  else
    note_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$note_out")
    printf 'Queued sync request for live FirstMate (%s): %s\n' "$note_id" "$MESSAGE"
  fi
  exit 0
fi

sync_args=()
if [ "$DRY_RUN" -eq 1 ]; then
  sync_args+=(--dry-run)
else
  sync_args+=(--apply)
fi
if [ -n "$PROJECT_FILTER" ]; then
  sync_args+=(--project "$PROJECT_FILTER")
fi
if [ -n "$INITIATIVE_FILTER" ]; then
  sync_args+=(--initiative "$INITIATIVE_FILTER")
fi
if [ -n "$LIMIT" ]; then
  sync_args+=(--limit "$LIMIT")
fi
if [ "$JSON_OUT" -eq 1 ]; then
  sync_args+=(--json)
fi

exec env FM_HOME="$FM_HOME" bash "$TASK_SYNC_BIN" "${sync_args[@]}"
