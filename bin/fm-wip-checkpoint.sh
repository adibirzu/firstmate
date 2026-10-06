#!/usr/bin/env bash
# Snapshot a task's work in progress, including uncommitted changes and the
# worker's handoff file, as one commit under refs/tags/wip/<task-id>, so another
# agent can continue the task on another harness, model or host.
#
# Usage:
#   fm-wip-checkpoint.sh <task-id> [--push] [--remote <name>]
#
# What this does (mechanism only; firstmate or the worker decides WHEN):
#   1. Reads worktree= from state/<id>.meta.
#   2. Builds a tree from the worktree as it is now - committed work, staged and
#      unstaged changes, and untracked files that .gitignore does not exclude -
#      through a private temporary index. The worktree's own index, HEAD, branch
#      and files are never touched.
#   3. Adds data/<id>/handoff.md, when present and non-empty, at the tree path
#      .fm-handoff.md.
#   4. Commits that tree with the current HEAD as its only parent and points the
#      lightweight tag wip/<id> at it (replacing an earlier checkpoint).
#   5. With --push, force-pushes that tag to the remote (default: origin).
#      Tags are not branches: they open no PR and are not built by
#      branch-filtered deployments.
#
# Prints: checkpoint <id> <commit> parent=<head> handoff=<yes|no> pushed=<remote|no>
#
# Restoring on any host (documented in docs/handoff-checkpoints.md):
#   git fetch --force <remote> "refs/tags/wip/<id>:refs/tags/wip/<id>"
#   git switch -c <branch> "wip/<id>^"
#   git restore --source="wip/<id>" --worktree -- .
#   then read and remove .fm-handoff.md
#
# Hard refusals: missing FM_HOME, missing meta or worktree=, a worktree that is
# not a git work tree, an unborn HEAD, an invalid task id.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

usage() {
  cat >&2 <<'EOF'
usage: fm-wip-checkpoint.sh <task-id> [--push] [--remote <name>]
  --push           force-push refs/tags/wip/<task-id> to the remote
  --remote <name>  remote for --push (default: origin)
EOF
}

ID=
PUSH=0
REMOTE=origin
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1 ;;
    --remote) [ $# -ge 2 ] || { usage; exit 2; }; REMOTE=$2; shift ;;
    --remote=*) REMOTE=${1#--remote=} ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
    *) [ -z "$ID" ] || { echo "error: unexpected argument: $1" >&2; usage; exit 2; }; ID=$1 ;;
  esac
  shift
done

[ -n "$ID" ] || { usage; exit 2; }
case "$ID" in
  *[!A-Za-z0-9._-]*|.*|-*) echo "error: invalid task id: $ID" >&2; exit 2 ;;
esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-wip-checkpoint refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for $ID at $META" >&2; exit 1; }
WT=$(sed -n 's/^worktree=//p' "$META" | tail -n 1)
[ -n "$WT" ] || { echo "error: meta for $ID is missing worktree=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for $ID does not exist: $WT" >&2; exit 1; }
[ "$(git -C "$WT" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] ||
  { echo "error: worktree for $ID is not a git work tree: $WT" >&2; exit 1; }
HEAD_SHA=$(git -C "$WT" rev-parse --verify -q HEAD) ||
  { echo "error: worktree for $ID has no commit yet; nothing to checkpoint" >&2; exit 1; }

HANDOFF_FILE="$DATA/$ID/handoff.md"
TMP_INDEX=$(mktemp "${TMPDIR:-/tmp}/fm-wip-index.XXXXXX")
trap 'rm -f "$TMP_INDEX"' EXIT

# Start from HEAD's tree, then add the worktree on top: a private index means a
# half-staged worktree index is neither read for content nor modified.
GIT_INDEX_FILE="$TMP_INDEX" git -C "$WT" read-tree "$HEAD_SHA"
GIT_INDEX_FILE="$TMP_INDEX" git -C "$WT" add -A -- .

HAS_HANDOFF=no
if [ -s "$HANDOFF_FILE" ]; then
  blob=$(git -C "$WT" hash-object -w -- "$HANDOFF_FILE")
  GIT_INDEX_FILE="$TMP_INDEX" git -C "$WT" update-index --add --cacheinfo "100644,$blob,.fm-handoff.md"
  HAS_HANDOFF=yes
fi

TREE=$(GIT_INDEX_FILE="$TMP_INDEX" git -C "$WT" write-tree)
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT=$(printf 'wip(%s): checkpoint %s\n\nWork in progress snapshot made by fm-wip-checkpoint.sh. Not for merge.\nParent is the task branch head; .fm-handoff.md is the worker handoff file.\n' "$ID" "$STAMP" |
  git -C "$WT" commit-tree "$TREE" -p "$HEAD_SHA")
git -C "$WT" update-ref "refs/tags/wip/$ID" "$COMMIT"

PUSHED=no
if [ "$PUSH" = 1 ]; then
  git -C "$WT" push --quiet --force "$REMOTE" "refs/tags/wip/$ID:refs/tags/wip/$ID"
  PUSHED=$REMOTE
fi

printf 'checkpoint %s %s parent=%s handoff=%s pushed=%s\n' "$ID" "$COMMIT" "$HEAD_SHA" "$HAS_HANDOFF" "$PUSHED"
