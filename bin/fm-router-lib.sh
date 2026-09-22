#!/usr/bin/env bash
# fm-router-lib.sh - single owner of firstmate's usage-axi / llm-router-axi
# tool resolution.
#
# The two axi tools own the dispatch selector, the in-run step-down chain, the
# subscription-exhaustion vocabulary of the depletion classifier, and the
# machine-capacity gauges. This file resolves
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
#   fm_router_captain_intent  print a brief's `## Captain's intent` body,
#                             nothing when the brief or section is missing
#   fm_router_route_task_arg  print `--task <tempfile>` carrying the brief's
#                             captain intent, or nothing when there is none
#
# Resolution is PATH-only, plus an absolute path passed through the override.
# Firstmate never vendors a private copy of either tool. Both are unpublished on
# npm, so install each from its GitHub main clone (fm_router_axi_install_hint
# owns the exact commands). A missing tool is a blocker, not a reason to hand
# dispatch: the capacity guard declines and the selector refuses rather than
# running unguarded.
#
# The captain-intent helpers feed llm-router-axi's `route --task` shadow hook,
# which records the Jev-derived descriptor next to the supplied one for
# dispatch-vs-Jev agreement evidence (docs/configuration.md "Jev shadow mode").
# The flag must carry the captain's own intent only - `## Captain's intent` in
# a generator brief (bin/fm-brief.sh line 392) - never `## Firstmate spec` or
# any later section, and never secrets or .env values. `route` itself treats
# --task as read-only: the routing decision is always computed from the
# supplied descriptor and is byte-identical whether or not the flag is passed.
# The temp file is mode-0600 and lives under ${TMPDIR:-/tmp}, so nothing about
# the task text reaches argv or a log.

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

fm_router_captain_intent() {  # <brief-file> -> the `## Captain's intent` body only
  local brief=$1 line in_section=0
  [ -f "$brief" ] || return 0
  [ -L "$brief" ] && return 0  # a symlinked brief is never read for routing text
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "## Captain's intent")
        in_section=1
        continue
        ;;
      '#'*)
        if [ "$in_section" -eq 1 ]; then
          break
        fi
        ;;
    esac
    if [ "$in_section" -eq 1 ]; then
      printf '%s\n' "$line"
    fi
  done < "$brief"
}

fm_router_route_task_arg() {  # <brief-file> -> `--task <tempfile>` or nothing
  local brief=${1:-} content tmp
  [ -n "$brief" ] || return 0
  content=$(fm_router_captain_intent "$brief") || return 0
  [ -n "$content" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-router-task.XXXXXX") || return 0
  chmod 600 "$tmp" || { rm -f "$tmp"; return 0; }
  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 0; }
  printf -- '--task %s\n' "$tmp"
}
