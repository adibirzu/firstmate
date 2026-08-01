#!/usr/bin/env bash
# Read one crewmate endpoint's pane statusline and print its best-effort quota
# signal. Read-only diagnosis: it captures, parses, and prints, and never sends
# a key, kills an endpoint, or decides a handoff.
#
# Usage: fm-statusline-quota.sh <target> [lines=40] [--verdict]
#   <target> is anything fm-peek.sh accepts: a task id, a legacy fm-<id> label,
#   or an explicit backend target.
#   --verdict prints only the status token (ok|low|unknown|exhausted).
#
# Output without --verdict is the key=value line from fm_statusline_quota_parse,
# e.g. `status=low source=codex weekly_pct=3 context_pct=40`.
# An unresolvable target fails like fm-peek.sh; a pane that resolves but cannot
# be captured or parsed prints status=unknown. This path never reports
# exhaustion it did not read, and a context reading never counts as one.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-statusline-quota-lib.sh
. "$SCRIPT_DIR/fm-statusline-quota-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

RAW_TARGET=
LINES=40
VERDICT_ONLY=0
for a in "$@"; do
  case "$a" in
    --verdict) VERDICT_ONLY=1 ;;
    -h|--help) usage ;;
    --*) echo "error: unknown option $a" >&2; usage ;;
    *)
      if [ -z "$RAW_TARGET" ]; then
        RAW_TARGET=$a
      else
        case "$a" in
          ''|*[!0-9]*) echo "error: lines must be a positive integer, got '$a'" >&2; exit 1 ;;
        esac
        LINES=$a
      fi
      ;;
  esac
done
[ -n "$RAW_TARGET" ] || usage

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")
BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

CAPTURED=$(fm_backend_capture "$BACKEND" "$T" "$LINES" "$EXPECTED_LABEL" 2>/dev/null) || CAPTURED=

if [ "$VERDICT_ONLY" = 1 ]; then
  fm_statusline_quota_verdict "$CAPTURED"
else
  fm_statusline_quota_parse "$CAPTURED"
fi
