#!/usr/bin/env bash
# Behavior tests for the base-freshness proof every feature branch creation
# must run (bin/fm-base-check.sh).
#
# The pass case proves a current checkout proceeds. A checkout with no origin
# likewise proceeds (there is nothing to prove against). A stale checkout
# refuses with the printed remedy, a diverged checkout refuses, and a
# non-checkout or a checkout with an unfetchable origin refuses as unprovable.

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-base-check.sh"
TMP=$(fm_test_tmproot fm-base-check)

make_repo() {
  local case=$1 repo origin publisher worktree
  repo="$TMP/$case/repo"
  origin="$TMP/$case/origin.git"
  publisher="$TMP/$case/publisher"
  mkdir -p "$TMP/$case"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm base
  git clone -q --bare "$repo" "$origin"
  git -C "$repo" remote add origin "file://$origin"
  git -C "$repo" fetch -q origin "main:refs/remotes/origin/main"
  printf '%s\n' "$repo|$origin|$publisher"
}

make_worktree() {
  local repo=$1 worktree
  worktree="$TMP/$(basename "$(dirname "$repo")")/wt"
  mkdir -p "$(dirname "$worktree")"
  git -C "$repo" worktree add --quiet --detach "$worktree" HEAD
  git -C "$repo" fetch -q origin "main:refs/remotes/origin/main"
  printf '%s\n' "$worktree"
}

advance_origin() {
  local origin=$1 publisher=$2 commit
  git clone -q "file://$origin" "$publisher"
  printf 'advanced\n' > "$publisher/new.txt"
  git -C "$publisher" add new.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance
  commit=$(git -C "$publisher" rev-parse HEAD)
  git -C "$publisher" push -q origin main
  printf '%s\n' "$commit"
}

test_current_base_proceeds() {
  local rec repo worktree out
  rec=$(make_repo current)
  repo=${rec%%|*}
  IFS='|' read -r repo _ _ <<< "$rec"
  worktree=$(make_worktree "$repo")
  out=$("$CHECK" "$worktree" 2>&1) || fail "a current checkout was refused"$'\n'"$out"
  assert_contains "$out" "base check: current" "current checkout did not report current"
  pass "a checkout at its origin tip proves current and proceeds"
}

test_stale_base_refuses_with_remedy() {
  local rec repo origin publisher worktree out rc
  rec=$(make_repo stale)
  IFS='|' read -r repo origin publisher <<< "$rec"
  worktree=$(make_worktree "$repo")
  advance_origin "$origin" "$publisher" >/dev/null
  rc=0
  out=$("$CHECK" "$worktree" 2>&1) || rc=$?
  expect_code 1 "$rc" "a stale checkout did not refuse the branch proof"
  assert_contains "$out" "STALE" "stale refusal did not name the stale base"
  assert_contains "$out" "commits behind" "stale refusal did not name the backlog"
  assert_contains "$out" "remedy" "stale refusal did not print the remedy"
  pass "a checkout behind its origin tip refuses with the remedy"
}

test_origin_less_checkout_proceeds() {
  local repo=$TMP/originless/repo out
  mkdir -p "$repo"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm base
  out=$("$CHECK" "$repo" 2>&1) || fail "an origin-less checkout was refused"$'\n'"$out"
  assert_contains "$out" "no origin configured" "origin-less checkout did not say so"
  pass "a checkout without an origin has nothing to prove and proceeds"
}

test_diverged_base_refuses() {
  local repo=$TMP/diverge/repo origin=$TMP/diverge/origin.git publisher=$TMP/diverge/publisher out rc
  mkdir -p "$TMP/diverge"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm base
  git clone -q --bare "$repo" "$origin"
  git -C "$repo" remote add origin "file://$origin"
  git -C "$repo" push -q origin main
  # Local-only commit that origin never sees creates a divergence.
  printf 'local\n' > "$repo/local.txt"
  git -C "$repo" add local.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local
  # Advance origin independently.
  git clone -q "file://$origin" "$publisher"
  printf 'upstream\n' > "$publisher/up.txt"
  git -C "$publisher" add up.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm upstream
  git -C "$publisher" push -q origin main
  rc=0
  out=$("$CHECK" "$repo" 2>&1) || rc=$?
  expect_code 1 "$rc" "a diverged checkout did not refuse the branch proof"
  assert_contains "$out" "DIVERGED" "divergence refusal did not say so"
  assert_contains "$out" "reconcile" "divergence refusal did not name reconciliation"
  pass "a diverged base refuses rather than cutting a branch from it"
}

test_not_a_git_checkout_refuses() {
  local repo=$TMP/notgit/repo out rc
  mkdir -p "$repo"
  rc=0
  out=$("$CHECK" "$repo" 2>&1) || rc=$?
  expect_code 2 "$rc" "a non-checkout directory did not refuse as unprovable"
  assert_contains "$out" "not a Git work tree" "non-checkout refusal did not say so"
  pass "a directory that is not a Git checkout refuses the branch proof"
}

test_unfetchable_origin_refuses() {
  local rec repo origin publisher worktree out rc
  rec=$(make_repo unfetchable)
  IFS='|' read -r repo origin publisher <<< "$rec"
  worktree=$(make_worktree "$repo")
  git -C "$worktree" remote set-url origin "file://$TMP/definitely-missing.git"
  rc=0
  out=$("$CHECK" "$worktree" 2>&1) || rc=$?
  expect_code 2 "$rc" "an unfetchable origin did not refuse as unprovable"
  assert_contains "$out" "could not fetch" "unfetchable refusal did not say so"
  pass "an unfetchable origin refuses the branch proof"
}

test_missing_argument_usage() {
  local out rc
  rc=0
  out=$("$CHECK" 2>&1) || rc=$?
  expect_code 2 "$rc" "missing directory argument did not produce a usage error"
  assert_contains "$out" "missing directory" "missing-argument refusal did not say so"
  pass "missing arguments produce a usage error"
}

test_current_base_proceeds
test_stale_base_refuses_with_remedy
test_origin_less_checkout_proceeds
test_diverged_base_refuses
test_not_a_git_checkout_refuses
test_unfetchable_origin_refuses
test_missing_argument_usage