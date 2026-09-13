#!/usr/bin/env bash
# Report what the machine-capacity spawn guard measures right now, and what it
# would decide.
# Usage: fm-capacity.sh [report]   print every signal with its measured and
#                                  wanted value, plus the verdict; always exit 0
#        fm-capacity.sh check      same report, but exit 1 when there is no
#                                  headroom, so a script can branch on it
#        fm-capacity.sh -h         print this header
#
# This is a read-only inspection of live machine state. It starts nothing, stops
# nothing, and signals nothing; bin/fm-capacity-lib.sh's header owns the signal
# set, the reason there is more than one, the unreadable-signal policy, and the
# config/spawn-capacity format. docs/configuration.md "Machine capacity
# (config/spawn-capacity)" owns the operator-facing settings contract.
#
# When usage-axi is installed, its live `machine` measurement is printed
# alongside the legacy verdict as the router's preferred capacity source; when
# it is absent the report above is the whole answer. Resolution is owned by
# bin/fm-router-lib.sh.
#
# Settings are read from the effective firstmate home, resolved the same way
# every other home-local config is: FM_CONFIG_OVERRIDE, else FM_HOME/config,
# else the tracked code root's config/.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"

MODE=report
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ''|report) MODE=report ;;
  check) MODE=check ;;
  *) echo "error: unknown command '$1' (expected report or check)" >&2; exit 2 ;;
esac

rc=0
fm_capacity_evaluate "$CONFIG" || rc=1

printf 'machine capacity: %s\n' "$FM_CAPACITY_SUMMARY"
fm_capacity_render_rows '  '
if [ "$rc" -ne 0 ]; then
  printf '%s\n' '  A spawn attempted now would be declined. Nothing already running is affected.'
  printf '  Raise the limits or set mode = off in %s to proceed anyway.\n' \
    "${FM_CAPACITY_CONFIG_PATH:-$CONFIG/$FM_CAPACITY_CONFIG_FILE}"
fi

# usage-axi machine is the router's preferred capacity reading. Resolution
# lives in bin/fm-router-lib.sh; the tool stays optional so a host without it
# keeps the legacy verdict unchanged.
# shellcheck source=bin/fm-router-lib.sh
. "$SCRIPT_DIR/fm-router-lib.sh"
if fm_usage_axi_have; then
  usage_axi_machine_bin=$(fm_usage_axi_bin)
  printf '\nusage-axi machine (%s):\n' "$usage_axi_machine_bin"
  usage_axi_machine_out=$("$usage_axi_machine_bin" machine 2>/dev/null || true)
  if [ -n "$usage_axi_machine_out" ]; then
    printf '%s\n' "$usage_axi_machine_out" | sed 's/^/  /'
  else
    printf '%s\n' '  usage-axi machine returned no reading'
  fi
fi

[ "$MODE" = check ] || exit 0
exit "$rc"
