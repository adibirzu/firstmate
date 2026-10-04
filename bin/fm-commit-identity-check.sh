#!/usr/bin/env bash
# fm-commit-identity-check.sh - refuse a push when branch commits use the wrong identity.
#
# The expected author and committer identity is the operator's global Git
# identity (`git config --global user.name` and `user.email`).
# Every commit in the pull-request range (the merge-base with origin/main, or
# local main when that tracking ref is absent, through HEAD) must use that exact
# name and email for both its author and committer.
#
# Usage:
#   fm-commit-identity-check.sh [--base REF]
#
# --base is a test and maintainer override for repositories whose pull-request
# base is not available as origin/main or main.

set -u

BASE_REF=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || {
        printf 'fm-commit-identity-check.sh: --base requires a ref.\n' >&2
        exit 2
      }
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#*=}
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'fm-commit-identity-check.sh: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'fm-commit-identity-check.sh: not inside a Git worktree; refusing push.\n' >&2
  exit 1
fi

EXPECTED_NAME=$(git config --global --get user.name 2>/dev/null || true)
EXPECTED_EMAIL=$(git config --global --get user.email 2>/dev/null || true)
if [ -z "$EXPECTED_NAME" ] || [ -z "$EXPECTED_EMAIL" ]; then
  printf 'fm-commit-identity-check.sh: global Git user.name and user.email must both be configured; refusing push.\n' >&2
  exit 1
fi

if [ -z "$BASE_REF" ]; then
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    BASE_REF=origin/main
  elif git rev-parse --verify -q main >/dev/null 2>&1; then
    BASE_REF=main
  else
    printf 'fm-commit-identity-check.sh: cannot resolve pull-request base origin/main or main; refusing push.\n' >&2
    exit 1
  fi
fi

if ! git rev-parse --verify -q "$BASE_REF^{commit}" >/dev/null 2>&1; then
  printf 'fm-commit-identity-check.sh: base ref %s is not a commit; refusing push.\n' "$BASE_REF" >&2
  exit 1
fi
if ! git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
  printf 'fm-commit-identity-check.sh: HEAD is not a commit; refusing push.\n' >&2
  exit 1
fi

MERGE_BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null || true)
if [ -z "$MERGE_BASE" ]; then
  printf 'fm-commit-identity-check.sh: cannot find a merge-base between %s and HEAD; refusing push.\n' "$BASE_REF" >&2
  exit 1
fi

RECORDS=$(mktemp "${TMPDIR:-/tmp}/fm-commit-identity.XXXXXX") || exit 1
cleanup() {
  rm -f "$RECORDS"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if ! git log --reverse --format='%H%x09%an%x09%ae%x09%cn%x09%ce' "$MERGE_BASE..HEAD" > "$RECORDS"; then
  printf 'fm-commit-identity-check.sh: cannot read commits in %s..HEAD; refusing push.\n' "$MERGE_BASE" >&2
  exit 1
fi

COUNT=0
OFFENDING=0
TAB=$(printf '\t')
while IFS="$TAB" read -r sha author_name author_email committer_name committer_email; do
  [ -n "$sha" ] || continue
  COUNT=$((COUNT + 1))
  commit_bad=0
  if [ "$author_name" != "$EXPECTED_NAME" ] || [ "$author_email" != "$EXPECTED_EMAIL" ]; then
    printf 'error: commit %s author is %s <%s>; expected %s <%s>.\n' \
      "$sha" "$author_name" "$author_email" "$EXPECTED_NAME" "$EXPECTED_EMAIL" >&2
    commit_bad=1
  fi
  if [ "$committer_name" != "$EXPECTED_NAME" ] || [ "$committer_email" != "$EXPECTED_EMAIL" ]; then
    printf 'error: commit %s committer is %s <%s>; expected %s <%s>.\n' \
      "$sha" "$committer_name" "$committer_email" "$EXPECTED_NAME" "$EXPECTED_EMAIL" >&2
    commit_bad=1
  fi
  [ "$commit_bad" -eq 0 ] || OFFENDING=$((OFFENDING + 1))
done < "$RECORDS"

if [ "$OFFENDING" -ne 0 ]; then
  printf 'fm-commit-identity-check.sh: %s offending commit(s) in %s..HEAD; refusing push.\n' \
    "$OFFENDING" "$MERGE_BASE" >&2
  exit 1
fi

printf 'fm-commit-identity-check.sh: verified %s commit(s) as %s <%s>.\n' \
  "$COUNT" "$EXPECTED_NAME" "$EXPECTED_EMAIL"
