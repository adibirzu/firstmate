# shellcheck shell=bash
# Shared gha-runner-axi resolution + compatibility floor for firstmate.
# Usage: . bin/fm-gha-runner-axi-lib.sh
#
# gha-runner-axi reports whether the fleet's self-hosted GitHub Actions runners
# are online and whether CI_RUNS_ON actually routes jobs to them. firstmate reads
# it before relying on self-hosted CI (a no-mistakes push whose checks must run on
# a runner is worthless if that runner is offline).
#
# Resolution is PATH-only, plus an absolute path via the FM_GHA_RUNNER_AXI
# override. Firstmate never vendors a private copy: install it from its GitHub
# clone (fm_gha_runner_axi_install_hint owns the exact command). A missing or
# too-old tool is reported by the caller, never silently assumed present.
#
# This file is the single owner of FM_GHA_RUNNER_AXI_MIN, following the axi-family
# floor policy owned beside the floor constants in bin/fm-bootstrap.sh.

FM_GHA_RUNNER_AXI_MIN=0.1.0

fm_gha_runner_axi_bin() {  # -> resolved executable, or empty
  local name=${FM_GHA_RUNNER_AXI:-gha-runner-axi} path
  if path=$(command -v "$name" 2>/dev/null) && [ -n "$path" ]; then
    printf '%s\n' "$path"
  fi
}

fm_gha_runner_axi_have() {
  [ -n "$(fm_gha_runner_axi_bin)" ]
}

fm_gha_runner_axi_compatible() {
  local output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  fm_gha_runner_axi_have || return 1
  output=$("$(fm_gha_runner_axi_bin)" --version 2>/dev/null </dev/null) || return 1
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_GHA_RUNNER_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_gha_runner_axi_install_hint() {
  printf '%s\n' 'git clone https://github.com/adibirzu/gha-runner-axi && cd gha-runner-axi && npm ci && npm run build && npm install -g --prefix ~/.local .   # not on npm yet'
}
