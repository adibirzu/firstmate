#!/usr/bin/env bash
# fm-router-lib.sh - single owner of firstmate's usage-axi / llm-router-axi
# tool resolution.
#
# Firstmate's accepted P3 shim-first posture is: prefer the two axi tools when
# they are installed, and keep the in-repo dispatch, capacity, and telemetry
# path when they are absent. This file resolves those executables plus the
# operator-facing install hint so every caller agrees on the names, the env
# overrides, and the "tool absent" contract.
#
# Env overrides (operator escape hatch and test seam):
#   FM_USAGE_AXI       usage-axi executable       (default: usage-axi)
#   FM_LLM_ROUTER_AXI  llm-router-axi executable  (default: llm-router-axi)
#
# Functions:
#   fm_usage_axi_bin          print the resolved executable, empty when absent
#   fm_usage_axi_have         return 0 when usage-axi resolves
#   fm_router_axi_bin         print the resolved executable, empty when absent
#   fm_router_axi_have        return 0 when llm-router-axi resolves
#   fm_router_axi_install_hint  print the documented install command
#
# Resolution is PATH-only, plus an absolute path passed through the override.
# Firstmate never vendors a private copy of either tool: install both with
# `npm install -g usage-axi llm-router-axi`, or run one off with
# `npx -y usage-axi` / `npx -y llm-router-axi`. A caller that finds the tool
# absent must keep its in-repo fallback rather than failing closed.

fm_router_lib_resolve() {  # <name-or-path> -> resolved executable, or empty
  local name=${1:-} path
  [ -n "$name" ] || return 0
  if path=$(command -v "$name" 2>/dev/null) && [ -n "$path" ]; then
    printf '%s\n' "$path"
  fi
}

fm_usage_axi_bin() {
  fm_router_lib_resolve "${FM_USAGE_AXI:-usage-axi}"
}

fm_usage_axi_have() {
  [ -n "$(fm_usage_axi_bin)" ]
}

fm_router_axi_bin() {
  fm_router_lib_resolve "${FM_LLM_ROUTER_AXI:-llm-router-axi}"
}

fm_router_axi_have() {
  [ -n "$(fm_router_axi_bin)" ]
}

fm_router_axi_install_hint() {
  printf '%s\n' 'npm install -g usage-axi llm-router-axi   # or: npx -y usage-axi / npx -y llm-router-axi'
}
