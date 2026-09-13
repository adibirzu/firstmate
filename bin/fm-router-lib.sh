#!/usr/bin/env bash
# fm-router-lib.sh - single owner of firstmate's usage-axi / llm-router-axi
# tool resolution.
#
# The two axi tools own the dispatch selector, the in-run step-down chain, the
# depletion classifier, and the machine-capacity gauges. This file resolves
# those executables plus the operator-facing install hint so every caller agrees
# on the names, the env overrides, and the "tool absent" contract.
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
# Firstmate never vendors a private copy of either tool. Both are unpublished on
# npm, so install each from its GitHub main clone (fm_router_axi_install_hint
# owns the exact commands). A missing tool is a blocker, not a reason to hand
# dispatch: the capacity guard declines and the selector refuses rather than
# running unguarded.

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
  printf '%s\n' 'git clone https://github.com/adibirzu/llm-router-axi && cd llm-router-axi && npm ci && npm run build && npm install -g --prefix ~/.local .   # repeat for https://github.com/adibirzu/usage-axi; neither is on npm yet'
}
