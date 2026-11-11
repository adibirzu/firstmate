#!/usr/bin/env bash
# shellcheck shell=bash
# fm-capacity-lib.sh - spawn admission through the machine-capacity verdict
# owned by llm-router-axi.
#
# This library is a thin adapter, not a measurement or policy owner.
# `llm-router-axi capacity` measures the live machine gauges (agents, load per
# core, free memory percent, memory pressure, swap in use, the
# one-suite-at-a-time slot, and local llama.cpp parallel slots) and compares
# them against the thresholds in the router policy at
# ~/.config/llm-router-axi/policy.json.
# The router README and policy schema own the gauge definitions and thresholds;
# docs/configuration.md points at them rather than restating the contract.
#
# Spawn admission asks the bare `capacity` purpose, so the one-suite-at-a-time
# slot is context here and never refuses a spawn: the rule serializes suite
# STARTS, not agent launches. The purpose-scoped `capacity --for suite` verdict
# is enforced by bin/fm-test-run.sh before it starts a full suite.
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

# True when the spawn model (or harness/model selector) needs a local llama.cpp
# parallel slot on adi1 (qwen38fn / LiteLLM local qwen / auto-code/free).
fm_capacity_needs_llama() {  # <model-or-empty>
  local model=${1:-}
  case "$model" in
    ''|-) return 1 ;;
  esac
  case "$model" in
    *qwen38fn*|*qwen3.8*|*qwen3\.8*|litellm/qwen*|litellm/auto-code*|litellm/auto-free*|*/qwen3.8*|auto-code|auto-free)
      return 0
      ;;
  esac
  return 1
}

fm_capacity_guard() {  # <config> <label> [<model>]
  local label=${2:-work}
  local model=${3:-}
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

  local purpose=spawn
  if fm_capacity_needs_llama "$model"; then
    purpose=local-llm
  fi

  local json ok
  if ! json=$("$router" capacity --for "$purpose" --json 2>/dev/null); then
    echo "error: llm-router-axi could not measure this machine; declining $label rather than spawning blind." >&2
    return 1
  fi
  ok=$(printf '%s' "$json" | jq -r '.ok // false' 2>/dev/null)
  [ "$ok" = true ] && return 0

  echo "machine capacity declines $label:" >&2
  printf '%s' "$json" | jq -r '.reasons[]? | "  - " + .' >&2
  if [ "$purpose" = local-llm ]; then
    echo "  Local llama.cpp is at --parallel capacity (both slots busy)." >&2
    echo "  Wait for a free slot, or spawn on a non-local model (claude/codex/grok)." >&2
  else
    echo "  Nothing already running is affected. Raise the router policy thresholds" >&2
    echo "  (~/.config/llm-router-axi/policy.json) or wait for headroom to return." >&2
  fi
  return 1
}
