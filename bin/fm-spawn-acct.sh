#!/usr/bin/env bash
# fm-spawn-acct.sh — multi-account wrapper around fm-spawn.sh (Phase 4 add-on).
#
# Adds a per-spawn --account axis WITHOUT modifying fm-spawn.sh: it composes an
# account-isolated launch command (fm_account_compose_launch) and hands it to
# fm-spawn's raw-launch escape hatch. Isolation rides in the command string, so
# it survives the Herdr/tmux pane boundary; no secret is placed on argv.
#
# Scope: config-dir accounts (claude/codex/pi/cline). api-key accounts
# (grok/cursor) are refused here (a key would land on argv) — use
# fm-account-exec.sh for a direct, non-supervised isolated launch instead.
#
# Usage:
#   fm-spawn-acct.sh <task-id> <project-dir> --account <name> [--model M] [--effort E] [passthrough flags...]
#
# Testable: set FM_SPAWN_BIN to a stub to capture the composed launch command.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"; export FM_HOME
# shellcheck source=bin/fm-account-env.sh disable=SC1091
. "$SCRIPT_DIR/fm-account-env.sh"

ACCOUNT=""; MODEL=""; EFFORT=""; POS=(); PASS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --account)   ACCOUNT=${2:-}; shift 2 ;;
    --account=*) ACCOUNT=${1#--account=}; shift ;;
    --model)     MODEL=${2:-}; shift 2 ;;
    --model=*)   MODEL=${1#--model=}; shift ;;
    --effort)    EFFORT=${2:-}; shift 2 ;;
    --effort=*)  EFFORT=${1#--effort=}; shift ;;
    *) if [ "${#POS[@]}" -lt 2 ]; then POS+=("$1"); else PASS+=("$1"); fi; shift ;;
  esac
done

[ -n "$ACCOUNT" ] || { echo "usage: fm-spawn-acct.sh <task-id> <project-dir> --account <name> [--model M] [--effort E] [flags...]" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "error: task-id (and usually project-dir) required" >&2; exit 1; }

LAUNCH=$(fm_account_compose_launch "$ACCOUNT" "$MODEL" "$EFFORT") || exit $?

FM_SPAWN_BIN="${FM_SPAWN_BIN:-$SCRIPT_DIR/fm-spawn.sh}"
# fm-spawn signature: <task-id> <project-dir> [<harness>|<launch-command>] [flags...]
exec "$FM_SPAWN_BIN" "${POS[@]}" "$LAUNCH" ${PASS[@]+"${PASS[@]}"}
