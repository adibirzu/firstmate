#!/usr/bin/env bash
# shellcheck shell=bash
# fm-capacity-lib.sh - spawn admission through the machine-capacity verdict
# owned by llm-router-axi.
#
# This library is a thin adapter, not a measurement or policy owner.
# `llm-router-axi capacity` measures the live machine gauges (agents, load per
# core, free memory percent, memory pressure, swap in use, and the
# one-suite-at-a-time slot) and compares them against the thresholds in the
# router policy at ~/.config/llm-router-axi/policy.json.
# The router README and policy schema own the gauge definitions and thresholds;
# docs/configuration.md points at them rather than restating the contract.
#
# WHY THE GUARD STILL EXISTS HERE
# A saturated machine is not a throughput problem, it is a "the operator cannot
# use his own computer" problem, so every spawn is admitted against the router's
# verdict before any task lock, backend, worktree, or metadata mutation.
# The guard only declines; it never kills, signals, stops, reaps, or
# deprioritizes anything, because restoring headroom by stopping live work
# would destroy unlanded work.
#
# FM_CAPACITY_NO_GUARD=1 disables the check for a caller that deliberately wants
# to bypass it; the ordinary path always asks the router.
#
# Functions:
#   fm_capacity_guard <config> <label>
#       Return 0 when the router admits another agent, 1 otherwise. <config> is
#       accepted for call-site compatibility and no longer read; <label> names
#       the refused work in the diagnostic.
#   fm_capacity_router_bin
#       Print the resolved llm-router-axi executable, empty when absent.

# Source resolution only; loading this file has no other side effect.
_FM_CAPACITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-router-lib.sh
. "$_FM_CAPACITY_LIB_DIR/fm-router-lib.sh"

fm_capacity_router_bin() {
  fm_router_axi_bin
}

fm_capacity_guard() {  # <config> <label>
  local label=${2:-work}
  [ -z "${FM_CAPACITY_NO_GUARD:-}" ] || return 0

  local router
  router=$(fm_capacity_router_bin)
  if [ -z "$router" ]; then
    echo "error: llm-router-axi is not installed, so machine capacity cannot be checked before spawning $label." >&2
    echo "  Install it with: $(fm_router_axi_install_hint)" >&2
    echo "  This check declines new work rather than risk saturating the machine; nothing already running is affected." >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is not installed, so the llm-router-axi capacity verdict cannot be read; declining $label." >&2
    return 1
  fi

  local json ok
  if ! json=$("$router" capacity --json 2>/dev/null); then
    echo "error: llm-router-axi could not measure this machine; declining $label rather than spawning blind." >&2
    return 1
  fi
  ok=$(printf '%s' "$json" | jq -r '.ok // false' 2>/dev/null)
  [ "$ok" = true ] && return 0

  echo "machine capacity declines $label:" >&2
  printf '%s' "$json" | jq -r '.reasons[]? | "  - " + .' >&2
  echo "  Nothing already running is affected. Raise the router policy thresholds" >&2
  echo "  (~/.config/llm-router-axi/policy.json) or wait for headroom to return." >&2
  return 1
}
