#!/usr/bin/env bash
# fm-base-check.sh - prove a checkout's base is current before a new feature branch is created.
#
# The working contract is that every development station and project clone
# proves, at branch-creation time, that its working base is not stale relative
# to its origin's default branch. A branch cut from a stale base is silently
# behind the moment it exists, and the whole point of cutting from the default
# is to inherit everything upstream has. This check fetches origin, compares
# HEAD against the origin default branch, and reports three report-only
# verdicts; it never writes a ref, never moves HEAD, and never discards work.
#
# Usage:
#   fm-base-check.sh <directory>
#
# Exit status (the branch step acts on it, so it is the contract, not the text):
#   0   base is current: HEAD is at or contains origin's default tip, or the
#       checkout has no origin configured and there is nothing to prove against
#   1   base is stale or diverged from origin's default branch; do not branch
#       until it is current, following the printed remedy
#   2   usage error or the base cannot be proven (unfetchable origin, no
#       resolvable default branch); do not branch
#
# A stale base refuses rather than proceeding with a warning: the check
# cannot prove what the contract requires, so the branch step must not happen.
# Fast-forwardable and diverged bases both refuse, because a divergence means
# the local and upstream defaults have moved apart and resetting would discard
# unlanded work. The remedy is printed but never executed: the operator (or
# worker) chooses how to reconcile.

set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  '')
    printf 'fm-base-check.sh: missing directory argument (see --help).\n' >&2
    exit 2
    ;;
  --*)
    printf 'fm-base-check.sh: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

DIR=$1
[ -d "$DIR" ] || {
  printf 'fm-base-check.sh: not a directory: %s\n' "$DIR" >&2
  exit 2
}
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'fm-base-check.sh: not a Git work tree: %s\n' "$DIR" >&2
  exit 2
}

if ! git -C "$DIR" config --get-regexp '^remote\.origin\.' >/dev/null 2>&1; then
  printf 'base check: no origin configured, nothing to prove against\n'
  exit 0
fi

git -C "$DIR" fetch --quiet origin || {
  printf 'fm-base-check.sh: could not fetch origin; cannot prove the base is current.\n' >&2
  exit 2
}

if ! git -C "$DIR" remote set-head origin --auto >/dev/null 2>&1; then
  printf 'fm-base-check.sh: could not resolve origin'"'"'s default branch; cannot prove the base is current.\n' >&2
  exit 2
fi

default=$(git -C "$DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -z "$default" ]; then
  for candidate in main master trunk; do
    if git -C "$DIR" show-ref --verify --quiet "refs/remotes/origin/$candidate" 2>/dev/null; then
      default="origin/$candidate"
      break
    fi
  done
  [ -n "$default" ] || {
    printf 'fm-base-check.sh: origin has no resolvable default branch; cannot prove the base is current.\n' >&2
    exit 2
  }
fi

head_sha=$(git -C "$DIR" rev-parse HEAD) || {
  printf 'fm-base-check.sh: could not resolve HEAD.\n' >&2
  exit 2
}
tip_sha=$(git -C "$DIR" rev-parse --verify --quiet "$default^{commit}") || {
  printf 'fm-base-check.sh: origin default branch %s has no commit to compare against.\n' "$default" >&2
  exit 2
}

if [ "$head_sha" = "$tip_sha" ]; then
  printf 'base check: current (HEAD is %s)\n' "$default"
  exit 0
fi

merge_base=$(git -C "$DIR" merge-base "$head_sha" "$tip_sha") || {
  printf 'fm-base-check.sh: no merge base between HEAD and %s; bases diverged.\n' "$default" >&2
  exit 1
}

if [ "$merge_base" = "$tip_sha" ]; then
  printf 'base check: current (HEAD contains %s; it is at or ahead of the origin tip)\n' "$default"
  exit 0
fi

behind=$(git -C "$DIR" rev-list --count "$head_sha".."$tip_sha" 2>/dev/null || echo 0)
if [ "$merge_base" = "$head_sha" ]; then
  printf 'base check: STALE - HEAD is %s commits behind %s; do not branch until it is current\n' "$behind" "$default"
  printf 'remedy: git -C %s merge --ff-only %s   (or pull --ff-only), then re-run this check\n' "$DIR" "$default"
  exit 1
fi

printf 'base check: DIVERGED - HEAD and %s have moved apart; reconcile before branching\n' "$default"
exit 1