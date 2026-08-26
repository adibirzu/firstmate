#!/usr/bin/env bash
# fm-captain-hold-batcher.sh - daily Lavish digest of hold-kind:captain items.
#
# Scans the fleet backlog for all items held for the captain (hold-kind: captain),
# groups them by project, and builds an interactive Lavish digest with
# Accept/Reject/Defer options per item. Arms the digest with lavish-axi and
# binds it to the keyed-answer intake (fm-captain-hold.sh).
#
# Usage:
#   fm-captain-hold-batcher.sh [build] [--force] [--daily]
#   fm-captain-hold-batcher.sh path
#   fm-captain-hold-batcher.sh status
#
# Options:
#   --force  Re-generate digest even if already run today.
#   --daily  Only run if today's digest has not been run yet.
#
# Exit codes:
#   0  Digest built and armed, or skipped because already run today.
#   1  Fatal error or missing dependencies.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
DATA="$FM_HOME/data"
BACKLOG="$DATA/backlog.md"
LAVISH_DIR="$FM_HOME/.lavish"
DIGEST_HTML="$LAVISH_DIR/captain-hold-digest.html"
MARKER="$STATE/.last-captain-hold-digest"

command_path() {
  printf '%s\n' "$DIGEST_HTML"
}

command_status() {
  local today last="never"
  today=$(date +%Y-%m-%d)
  if [ -f "$MARKER" ]; then
    last=$(tr -d '[:space:]' < "$MARKER")
  fi
  printf 'today: %s\nlast_run: %s\n' "$today" "$last"
  if [ "$last" = "$today" ]; then
    printf 'status: ran-today\n'
  else
    printf 'status: pending\n'
  fi
}

command_build() {
  local force=0 daily=0 today
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --daily) daily=1; shift ;;
      build) shift ;;
      *) echo "error: unrecognized argument: $1" >&2; exit 1 ;;
    esac
  done

  today=$(date +%Y-%m-%d)
  if [ "$daily" = 1 ] && [ "$force" = 0 ] && [ -f "$MARKER" ]; then
    if [ "$(tr -d '[:space:]' < "$MARKER")" = "$today" ]; then
      printf 'captain-hold-batcher: digest already generated for %s\n' "$today"
      return 0
    fi
  fi

  if [ ! -f "$BACKLOG" ]; then
    printf 'captain-hold-batcher: backlog not found at %s\n' "$BACKLOG" >&2
    return 0
  fi

  mkdir -p "$LAVISH_DIR" "$STATE"

  node "$SCRIPT_DIR/fm-captain-hold-batcher.mjs" --backlog "$BACKLOG" --output "$DIGEST_HTML"

  command -v lavish-axi >/dev/null 2>&1 || {
    printf 'captain-hold-batcher: lavish-axi is not installed\n' >&2
    return 1
  }
  if [ ! -x "$SCRIPT_DIR/fm-procevent-lavish.sh" ] || [ ! -x "$SCRIPT_DIR/fm-captain-hold.sh" ]; then
    printf 'captain-hold-batcher: required Lavish helpers are unavailable\n' >&2
    return 1
  fi
  if ! lavish-axi "$DIGEST_HTML"; then
    printf 'captain-hold-batcher: cannot establish the Lavish session\n' >&2
    return 1
  fi

  local sid
  if ! sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$DIGEST_HTML"); then
    printf 'captain-hold-batcher: cannot derive the Lavish source id\n' >&2
    return 1
  fi
  if ! "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" --any-origin >/dev/null; then
    printf 'captain-hold-batcher: cannot bind keyed-answer intake\n' >&2
    return 1
  fi
  if ! "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$DIGEST_HTML" >/dev/null; then
    printf 'captain-hold-batcher: cannot arm the Lavish digest\n' >&2
    return 1
  fi

  printf '%s\n' "$today" > "$MARKER"
  printf 'captain-hold-batcher: built digest at %s\n' "$DIGEST_HTML"
  printf 'captain-hold-batcher: armed as %s\n' "$sid"
}

case "${1:-build}" in
  path) command_path ;;
  status) command_status ;;
  build) shift || true; command_build "$@" ;;
  --force|--daily) command_build "$@" ;;
  -h|--help|help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *)
    echo "error: unknown command: $1" >&2
    exit 1
    ;;
esac
