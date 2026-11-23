#!/usr/bin/env bash
# scripts/orca-worktree-setup.sh - Orca worktree setup for firstmate.
# Adds local-only git excludes for scratch artifacts and checks the core
# runtime binaries. Never installs packages, never touches data/, state/,
# config/ or projects/, never modifies tracked files, makes no network calls.
set -euo pipefail

exclude_file=$(git rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$exclude_file")"
touch "$exclude_file"

for pattern in '__pycache__/' '*.pyc' '.ruff_cache/' 'firebase-debug.log'; do
  if ! grep -qxF -- "$pattern" "$exclude_file"; then
    printf '%s\n' "$pattern" >>"$exclude_file"
  fi
done

ok=""
missing=""
for tool in bash git jq python3; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok="$ok $tool"
  else
    missing="$missing $tool"
  fi
done

if [ -n "$missing" ]; then
  printf 'orca-worktree-setup: runtime ok:%s; missing:%s (install manually)\n' "${ok:- none}" "$missing"
else
  printf 'orca-worktree-setup: runtime ok:%s; excludes ready\n' "$ok"
fi
