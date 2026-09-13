#!/usr/bin/env bash
# fm-install-router-axi-tools.sh - install CI's pinned, verified builds of the
# two unpublished router tools: llm-router-axi and usage-axi.
#
# Both tools own firstmate's machine-capacity admission (bin/fm-capacity-lib.sh
# adapts llm-router-axi), and neither is published on npm yet, so every behavior
# lane that can spawn an agent must build and install them from a pinned GitHub
# commit. This is the single owner of that pinned install recipe; the CI jobs
# and bin/fm-test-run.sh's local lane preflight both call it rather than
# restating the git clone / npm ci / npm run build / npm install sequence.
#
# Cache-friendly and idempotent: a destination that already carries the exact
# pinned version of a tool skips that tool's build, so an actions/cache restore
# keyed on the pins (--print-cache-key) turns a repeat lane into a no-op.
#
# Usage:
#   fm-install-router-axi-tools.sh <destination-prefix>
#       Build and `npm install -g --prefix <destination-prefix> .` each tool.
#       The executables land at <destination-prefix>/bin, so callers put that
#       directory on PATH. Prints both tools' --version lines.
#   fm-install-router-axi-tools.sh --print-cache-key
#       Print the stable cache key derived from the two pinned commits.
#   fm-install-router-axi-tools.sh -h|--help
#       Print this header.
#
# Pins (verified 2026-09-13: SHA builds report the version named beside it; run
# `git ls-remote <repo> HEAD` and bump both the SHA and the version together):
#   llm-router-axi  bf42cff713ce8501301663a8377f4d6bca7c3881 -> 0.1.0
#                   (P5 merged; `capacity --for suite` gates a suite start)
#   usage-axi       b140738e6bf074f280aca46dc48a3339e8ef1f6d -> 0.1.1
set -eu

FM_ROUTER_AXI_LLM_REPO=https://github.com/adibirzu/llm-router-axi
FM_ROUTER_AXI_LLM_SHA=bf42cff713ce8501301663a8377f4d6bca7c3881
FM_ROUTER_AXI_LLM_VERSION=0.1.0
FM_ROUTER_AXI_USAGE_REPO=https://github.com/adibirzu/usage-axi
FM_ROUTER_AXI_USAGE_SHA=b140738e6bf074f280aca46dc48a3339e8ef1f6d
FM_ROUTER_AXI_USAGE_VERSION=0.1.1

die() {
  printf 'fm-install-router-axi-tools.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

print_cache_key() {
  printf 'llm-router-axi-%s-usage-axi-%s\n' \
    "${FM_ROUTER_AXI_LLM_SHA:0:12}" "${FM_ROUTER_AXI_USAGE_SHA:0:12}"
}

# Build and install one tool unless <prefix>/bin/<name> already reports the
# exact pinned version. <name> <repo> <sha> <version>.
install_tool() {
  local name=$1 repo=$2 sha=$3 version=$4
  local installed="${DESTINATION}/bin/${name}"

  if [ -x "$installed" ]; then
    local have
    have=$("$installed" --version 2>/dev/null | head -n 1 | tr -d '[:space:]') || have=
    if [ "$have" = "$version" ]; then
      printf 'fm-install-router-axi-tools.sh: %s %s already installed, skipping build\n' "$name" "$version" >&2
      return 0
    fi
  fi

  command -v git >/dev/null 2>&1 || die "git is required to build $name"
  command -v npm >/dev/null 2>&1 || die "npm is required to build $name"

  local tmp
  tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-router-axi-${name}.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  mkdir -p "$DESTINATION"

  printf 'fm-install-router-axi-tools.sh: building %s %s from %s@%s\n' \
    "$name" "$version" "$repo" "$sha" >&2
  git init -q "$tmp/src" || die "git init failed for $name"
  git -C "$tmp/src" remote add origin "$repo" || die "git remote add failed for $name"
  git -C "$tmp/src" fetch -q --depth 1 origin "$sha" \
    || die "git fetch failed for $name@$sha"
  git -C "$tmp/src" checkout -q FETCH_HEAD || die "git checkout failed for $name@$sha"

  local actual_sha
  actual_sha=$(git -C "$tmp/src" rev-parse HEAD)
  [ "$actual_sha" = "$sha" ] \
    || die "checked out $name at $actual_sha, expected pinned $sha"

  ( cd "$tmp/src" && npm ci ) || die "npm ci failed for $name"
  ( cd "$tmp/src" && npm run build ) || die "npm run build failed for $name"

  # Pack the built tree and install the tarball, never the source directory:
  # `npm install -g` on a local directory creates a symlink back to that
  # directory, so a restored actions/cache prefix would dangle once the build
  # temp dir is gone. The tarball copies a self-contained package instead.
  mkdir -p "$tmp/pack"
  local pack_out
  if ! pack_out=$( cd "$tmp/src" && npm pack --silent --pack-destination "$tmp/pack" ); then
    die "npm pack failed for $name"
  fi
  local tarball
  tarball="$tmp/pack/$(printf '%s\n' "$pack_out" | tail -n 1)"
  [ -f "$tarball" ] || die "npm pack did not produce a tarball for $name"
  npm install -g --prefix "$DESTINATION" "$tarball" \
    || die "npm install -g --prefix $DESTINATION failed for $name"

  [ -x "$installed" ] || die "$name did not produce $installed"

  local got
  got=$("$installed" --version 2>/dev/null | head -n 1 | tr -d '[:space:]') || got=
  [ "$got" = "$version" ] \
    || die "installed $name reports version '${got:-<empty>}', expected exact pin $version"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "${1:-}" = "--print-cache-key" ]; then
  print_cache_key
  exit 0
fi

DESTINATION=${1:?usage: fm-install-router-axi-tools.sh <destination-prefix>}
mkdir -p "$DESTINATION"
DESTINATION=$(cd "$DESTINATION" && pwd) \
  || die "could not resolve destination directory to an absolute path"

install_tool llm-router-axi "$FM_ROUTER_AXI_LLM_REPO" \
  "$FM_ROUTER_AXI_LLM_SHA" "$FM_ROUTER_AXI_LLM_VERSION"
install_tool usage-axi "$FM_ROUTER_AXI_USAGE_REPO" \
  "$FM_ROUTER_AXI_USAGE_SHA" "$FM_ROUTER_AXI_USAGE_VERSION"

printf '%s\n' "$("$DESTINATION/bin/llm-router-axi" --version)"
printf '%s\n' "$("$DESTINATION/bin/usage-axi" --version)"
