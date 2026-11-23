#!/usr/bin/env bash
# scripts/orca-worktree-archive.sh - Orca worktree archive cleanup for firstmate.
# Removes only regenerable __pycache__ and .ruff_cache directories. Never
# descends into .git, data/, state/, config/ or projects/ and never removes
# regular source files. Makes no network calls.
set -euo pipefail

top=$(git rev-parse --show-toplevel)

find "$top" \
  \( -path "$top/.git" -o -path "$top/data" -o -path "$top/state" \
     -o -path "$top/config" -o -path "$top/projects" \) -prune -o \
  -type d \( -name __pycache__ -o -name .ruff_cache \) -prune \
  -exec rm -r -- {} +

printf 'orca-worktree-archive: cleaned local caches\n'
