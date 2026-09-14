#!/usr/bin/env bash
# Fail closed when a crewmate's shell is not the exact disposable worktree it
# was launched in.
#
# bin/fm-brief.sh emits a {WORKTREE} placeholder in the ship/scout isolation
# assertion and bin/fm-spawn.sh substitutes it with the leased worktree path, so
# this check is the worker's first command. It succeeds only when the physical
# shell cwd AND the git top-level both resolve to that exact worktree and the
# location is a genuine, linked task worktree - never a firstmate home (main or
# secondmate, carrying .fm-secondmate-home/.fm-secondmate-parent) and never a
# primary checkout. A worker misdirected into a home or the primary checkout
# must stop before branching or editing, which is the failure this catches.
#
# Exit status: 0 in the assigned worktree; 1 on any mismatch (fail closed); 2 on
# a usage error or an assigned path that is not a git worktree root.
#
# Usage: fm-worker-isolation-check.sh <assigned-worktree>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() {
  echo "usage: fm-worker-isolation-check.sh <assigned-worktree>" >&2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -eq 1 ] || { usage; exit 2; }

ASSIGNED=$1

physical_path() {
  local path=$1
  ( CDPATH='' cd -- "$path" 2>/dev/null && pwd -P ) || printf '%s\n' "$path"
}

# Return 0 when <dir> is a firstmate operational home: a secondmate home
# (.fm-secondmate-home) or a home bound to a parent (.fm-secondmate-parent).
# fm_root_is_secondmate_home already refuses a symlinked marker, so mirror that
# for the parent marker rather than following a planted symlink.
is_firstmate_home() {
  local dir=$1 marker
  fm_root_is_secondmate_home "$dir" && return 0
  marker="$dir/.fm-secondmate-parent"
  [ -f "$marker" ] && [ ! -L "$marker" ] && return 0
  return 1
}

# Return 0 when <dir> is a plain checkout - its own git dir is the repository's
# common git dir - rather than a linked task worktree. The primary checkout of a
# repository is exactly this shape.
is_primary_checkout() {
  local dir=$1 git_dir common_dir
  git_dir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || return 1
  [ "$(physical_path "$git_dir")" = "$(physical_path "$common_dir")" ]
}

# Echo a short reason <dir> cannot be a crewmate's assigned worktree, or nothing
# when it has no disqualifying shape. The explicit firstmate-home and
# primary-checkout cases are fail-closed even when a path somehow equals the
# assigned one; a plain mismatch is caught by the path comparisons below.
location_flaw() {
  local dir=$1
  if is_firstmate_home "$dir"; then
    printf 'a firstmate home\n'
    return 0
  fi
  if is_primary_checkout "$dir"; then
    printf 'a primary checkout, not a linked task worktree\n'
    return 0
  fi
  return 0
}

[ -n "$ASSIGNED" ] || { echo "error: assigned worktree path is empty" >&2; exit 2; }
[ -d "$ASSIGNED" ] || { echo "error: assigned worktree does not exist: $ASSIGNED" >&2; exit 2; }
EXPECTED=$(physical_path "$ASSIGNED")

EXPECTED_TOP=$(git -C "$EXPECTED" rev-parse --show-toplevel 2>/dev/null) || EXPECTED_TOP=
if [ -z "$EXPECTED_TOP" ] || [ "$(physical_path "$EXPECTED_TOP")" != "$EXPECTED" ]; then
  echo "error: assigned path is not a git worktree root: $ASSIGNED" >&2
  exit 2
fi

CWD=$(pwd -P)
TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || TOP=
[ -z "$TOP" ] || TOP=$(physical_path "$TOP")
flaw=

fail() {
  echo "error: not in the assigned worktree: $1" >&2
  echo "  assigned worktree: $EXPECTED" >&2
  echo "  shell cwd:         $CWD" >&2
  echo "  git top-level:     ${TOP:-<none>}" >&2
  echo "stop before branching or editing; report blocked and wait for firstmate." >&2
  exit 1
}

if [ "$CWD" != "$EXPECTED" ]; then
  flaw=$(location_flaw "$CWD")
  if [ -n "$flaw" ]; then
    fail "shell cwd '$CWD' is $flaw"
  fi
  fail "shell cwd is not the assigned worktree"
fi

if [ -z "$TOP" ]; then
  fail "shell cwd is not inside any git worktree"
fi
if [ "$TOP" != "$EXPECTED" ]; then
  flaw=$(location_flaw "$TOP")
  if [ -n "$flaw" ]; then
    fail "git top-level '$TOP' is $flaw"
  fi
  fail "git top-level is not the assigned worktree"
fi

flaw=$(location_flaw "$EXPECTED")
if [ -n "$flaw" ]; then
  fail "the assigned path is $flaw"
fi

printf 'ok: shell is in the assigned worktree %s\n' "$EXPECTED"
