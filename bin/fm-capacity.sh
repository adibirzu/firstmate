#!/usr/bin/env bash
# Report what the machine-capacity spawn guard measures right now, and what it
# would decide.
# Usage: fm-capacity.sh [report]   print the live gauges and verdict; always exit 0
#        fm-capacity.sh check      same reading, but exit 1 when there is no
#                                  headroom, so a script can branch on it
#        fm-capacity.sh -h         print this header
#
# This is a read-only inspection of live machine state. It starts nothing, stops
# nothing, and signals nothing. The measurement and the thresholds both live in
# llm-router-axi (`capacity` and the policy at ~/.config/llm-router-axi/policy.json);
# bin/fm-capacity-lib.sh owns spawn admission, and docs/configuration.md points
# at the tools rather than restating the gauge contract.
#
# When usage-axi is installed, its `machine` reading is printed alongside the
# router verdict as the raw capacity measurement. Tool resolution is owned by
# bin/fm-router-lib.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-router-lib.sh
. "$SCRIPT_DIR/fm-router-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

MODE=report
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ''|report) MODE=report ;;
  check) MODE=check ;;
  *) echo "error: unknown command '$1' (expected report or check)" >&2; exit 2 ;;
esac

router=$(fm_router_axi_bin)
if [ -z "$router" ]; then
  echo "error: llm-router-axi is not installed, so machine capacity cannot be read." >&2
  echo "  Install it with: $(fm_router_axi_install_hint)" >&2
  exit 1
fi

rc=0
if [ "$MODE" = check ]; then
  "$router" capacity check || rc=$?
else
  "$router" capacity || rc=$?
fi

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
