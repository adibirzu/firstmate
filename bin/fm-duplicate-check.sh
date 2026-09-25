#!/usr/bin/env bash
# fm-duplicate-check.sh - detect duplicate or superseded work before dispatch.
#
# Before firstmate starts a new worker, it must know whether the intended
# feature branch or its topic is already covered by an existing open PR or by
# an existing branch, so it does not start a second worker on already-covered
# ground. This check answers that against the checkout's own origin (for
# branch existence) and, when that origin is GitHub, against the forge's open
# PR list via gh-axi.
#
# Usage:
#   fm-duplicate-check.sh <directory> <branch> [words...]
#
# <branch> is the intended feature branch (for example fm/<task-id>). Each
# <word> is a description token; distinctive tokens (length >= 4, after
# stopword filtering) are matched against the titles and head branches of open
# PRs on the GitHub origin.
#
# Exit status (the dispatch gate acts on it, so it is the contract, not text):
#   0   no duplicate or superseded work detected; dispatch may proceed
#   1   duplicate detected: an open PR already covers the intended branch or a
#       description token, or the intended branch already exists on origin;
#       do not dispatch
#   2   environment refusal: the origin is GitHub but gh or gh-axi is missing
#       or unauthenticated, or an open-PR query failed; do not dispatch
#       because the duplicate question could not be answered
#
# A GitHub-origin refusal is a stop-and-report result: firstmate may only
# proceed past it by re-running with --duplicate-ok (its own judgment call
# against the printed evidence) or by fixing the queried environment. A
# non-GitHub origin still runs the branch-existence check, so a local-only
# project is never silently skipped.

set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
esac

DUPLICATE_OK=0
POS=()
for a in "$@"; do
  case "$a" in
    --duplicate-ok) DUPLICATE_OK=1 ;;
    --*) printf 'fm-duplicate-check.sh: unknown argument: %s\n' "$a" >&2; exit 2 ;;
    *) POS+=("$a") ;;
  esac
done

[ "${#POS[@]}" -ge 2 ] || {
  printf 'fm-duplicate-check.sh: usage: %s <directory> <branch> [words...]\n' "$0" >&2
  exit 2
}
DIR=${POS[0]}
BRANCH=${POS[1]}
WORDS=("${POS[@]:2}")

[ -d "$DIR" ] || {
  printf 'fm-duplicate-check.sh: not a directory: %s\n' "$DIR" >&2
  exit 2
}
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'fm-duplicate-check.sh: not a Git work tree: %s\n' "$DIR" >&2
  exit 2
}

# Superseded branch: the intended branch already exists on this checkout's own
# origin, whether or not a PR was opened from it.
if git -C "$DIR" ls-remote --heads --exit-code origin "$BRANCH" >/dev/null 2>&1; then
  if [ "$DUPLICATE_OK" -eq 1 ]; then
    printf 'duplicate check: branch %s already exists on origin, but --duplicate-ok overrides it; dispatch may proceed\n' "$BRANCH"
    exit 0
  fi
  printf 'duplicate check: REFUSED - branch %s already exists on origin (superseded work)\n' "$BRANCH"
  printf 'evidence: git ls-remote --heads origin %s matched\n' "$BRANCH"
  printf 'override: pass --duplicate-ok to dispatch anyway\n'
  exit 1
fi

# GitHub origin: query open PRs through gh-axi so a fork checkout is never
# resolved against a CLI default repository.
slug=$(fm_pr_github_repo_from_checkout "$DIR" 2>/dev/null) || slug=
if [ -n "$slug" ]; then
  if ! command -v gh-axi >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1; then
    printf 'fm-duplicate-check.sh: %s has a GitHub origin but gh-axi/gh is missing; cannot answer the duplicate question.\n' "$DIR" >&2
    exit 2
  fi
  if ! gh auth status >/dev/null 2>&1; then
    printf 'fm-duplicate-check.sh: cannot answer the duplicate question for %s: GitHub is not authenticated.\n' "$DIR" >&2
    exit 2
  fi
fi

# Exact head-branch match against open PRs is the strongest duplicate signal:
# a second worker pushing to the same branch would land in an open PR that
# already exists. Token matches extend that to a same-topic PR on a different
# branch.
matching=0
if [ -n "$slug" ]; then
  head_matches=$(gh-axi pr list --repo "$slug" --state open --head "$BRANCH" 2>/dev/null) || {
    printf 'fm-duplicate-check.sh: open-PR query failed for %s; cannot answer the duplicate question.\n' "$DIR" >&2
    exit 2
  }
  if printf '%s\n' "$head_matches" | grep -q '^count: [1-9]'; then
    matching=1
    printf 'duplicate check: REFUSED - open PR already exists with head branch %s\n' "$BRANCH"
    printf '%s\n' "$head_matches" | grep '^{' || true
  fi

  tokens=()
  for w in "$BRANCH" "${WORDS[@]}"; do
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      case " ${tokens[*]:-} " in *" $t "*) continue ;; esac
      tokens+=("$t")
    done < <(printf '%s\n' "$w" | tr -cs '[:alnum:]' '\n' | tr '[:upper:]' '[:lower:]')
  done

  pr_rows=$(gh-axi pr list --repo "$slug" --state open 2>/dev/null) || {
    printf 'fm-duplicate-check.sh: open-PR listing failed for %s; cannot answer the duplicate question.\n' "$DIR" >&2
    exit 2
  }
  while IFS= read -r row; do
    num=$(printf '%s\n' "$row" | sed -n 's/^ *\([0-9][0-9]*\),"\(.*\)",.*$/\1/p')
    title=$(printf '%s\n' "$row" | sed -n 's/^ *[0-9][0-9]*,"\([^"]*\)",.*$/\1/p')
    [ -n "$num" ] || continue
    tl=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
    for t in "${tokens[@]:-}"; do
      [ "${#t}" -ge 4 ] || continue
      case " $tl " in *" $t "*) : ;; *) continue ;; esac
      matching=1
      printf 'duplicate check: REFUSED - open PR #%s covers token "%s": %s\n' "$num" "$t" "$title"
      break
    done
  done <<EOF
$pr_rows
EOF

  if [ "$matching" -eq 1 ]; then
    if [ "$DUPLICATE_OK" -eq 1 ]; then
      printf 'duplicate check: open PR overlap found, but --duplicate-ok overrides it; dispatch may proceed\n'
      exit 0
    fi
    printf 'duplicate check: do not dispatch a second worker on already-covered ground\n'
    printf 'override: pass --duplicate-ok to dispatch anyway\n'
    exit 1
  fi
fi

printf 'duplicate check: clear - no open PR or existing branch covers %s\n' "$BRANCH"
exit 0