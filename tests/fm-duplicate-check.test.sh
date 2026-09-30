#!/usr/bin/env bash
# Behavior tests for the duplicate/superseded-work detector every fresh ship
# dispatch must pass (bin/fm-duplicate-check.sh).
#
# A branch that already exists on origin is superseded work and refuses. A
# GitHub origin refuses when the open-PR question cannot be answered (gh
# missing, unauthenticated, or query failed), and refuses when an open PR
# covers the intended branch or a description token; --duplicate-ok overrides
# a found duplicate. A non-GitHub origin still runs the branch-existence check
# but has no open-PR question to answer.

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-duplicate-check.sh"
TMP=$(fm_test_tmproot fm-duplicate-check)

# make_origin <case> [branch-name]: build a local bare origin plus a checkout
# whose declared origin.url is a GitHub URL (so slug resolution has a
# repository to query) rewritten to the local bare via url.<base>.insteadOf
# (so branch existence and fetches stay on the test's own copy, never the
# network). Echoes "<checkout>|<bare>".
make_origin() {
  local name=$1 checkout bare branch=${2:-main}
  mkdir -p "$TMP/$name"
  checkout="$TMP/$name/checkout"
  bare="$TMP/$name/origin.git"
  git init -q -b main "$checkout"
  printf 'base\n' > "$checkout/file.txt"
  git -C "$checkout" add file.txt
  git -C "$checkout" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm base
  git clone -q --bare "$checkout" "$bare"
  git -C "$checkout" remote add origin "git@github.com:acme/$name.git"
  git -C "$checkout" config "url.file://$bare.insteadOf" "git@github.com:acme/$name.git"
  if [ "$branch" != main ]; then
    git -C "$checkout" push -q origin "main:$branch"
  fi
  printf '%s|%s\n' "$checkout" "$bare"
}

# path_without_forge <dir>: build a PATH that keeps the normal system tools
# (git, sed, ...) but excludes gh and gh-axi, so the missing-cli refusal path
# is exercised without breaking the script's own plumbing.
path_without_forge() {
  local dir=$1 tool
  mkdir -p "$dir"
  for tool in bash env git sh sed grep awk cut tr cat mkdir printf dirname basename sort comm readlink stat; do
    if t=$(command -v "$tool" 2>/dev/null); then
      ln -sf "$t" "$dir/$tool"
    fi
  done
  printf '%s\n' "$dir"
}

# fake_forge <fakebin> <head-count> [rows]: a gh-axi/gh pair that answers the
# duplicate detector's two PR queries deterministically. head-count is the
# `count:` the exact-head query prints; rows are the plain open-PR listing.
fake_forge() {
  local fakebin=$1 head_count=$2 rows=${3:-}
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  'auth status') exit "${FM_FAKE_GH_AUTH_RC:-0}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
set -u
if [ "\$1" = pr ] && [ "\$2" = list ]; then
  case "\$*" in
    *'--head'*)
      printf 'count: %s\npull_requests: []\n' "\${FM_FAKE_HEAD_COUNT:-$head_count}"
      exit "\${FM_FAKE_GH_AXI_RC:-0}"
      ;;
    *)
      printf 'count: %s\n' "\${FM_FAKE_LIST_COUNT:-0}"
      rows=\$(cat <<'ROWS'
$rows
ROWS
)
      [ -z "\$rows" ] || printf 'pull_requests:\n%s\n' "\$rows"
      exit "\${FM_FAKE_LIST_RC:-0}"
      ;;
  esac
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
}

run_check() {
  local dir=$1 branch=$2; shift 2
  PATH="$FAKEBIN_DIR:$PATH" "$CHECK" "$dir" "$branch" "$@" 2>&1
}

test_origin_less_and_local_origin_with_no_branch_clears() {
  local rec checkout bare fakebin out rc
  rec=$(make_origin clear)
  IFS='|' read -r checkout bare <<< "$rec"
  fakebin=$(fm_fakebin "$TMP/clear")
  fake_forge "$fakebin" 0
  rc=0
  out=$(PATH="$fakebin:$PATH" "$CHECK" "$checkout" fm/clear-task) || rc=$?
  expect_code 0 "$rc" "a fresh task on a GitHub origin with no open PR was refused"
  assert_contains "$out" "clear" "clear result did not say so"
  pass "a task with no existing branch or open PR on a GitHub origin clears"
}

test_existing_branch_refuses() {
  local rec checkout bare out rc
  rec=$(make_origin superseded fm/superseded-task)
  IFS='|' read -r checkout bare <<< "$rec"
  rc=0
  out=$("$CHECK" "$checkout" fm/superseded-task) || rc=$?
  expect_code 1 "$rc" "a branch that already exists on origin did not refuse"
  assert_contains "$out" "REFUSED" "superseded refusal did not say so"
  assert_contains "$out" "already exists on origin" "superseded refusal did not name the branch"
  assert_contains "$out" "--duplicate-ok" "superseded refusal did not show the override"
  pass "an already-existing branch on origin is superseded and refuses"
}

test_duplicate_ok_overrides_existing_branch() {
  local rec checkout bare out rc
  rec=$(make_origin override fm/override-task)
  IFS='|' read -r checkout bare <<< "$rec"
  rc=0
  out=$("$CHECK" "$checkout" fm/override-task --duplicate-ok) || rc=$?
  expect_code 0 "$rc" "--duplicate-ok did not override a found duplicate"
  assert_contains "$out" "overrides" "override did not say it overrode the duplicate"
  pass "--duplicate-ok dispatches anyway when a branch already exists on origin"
}

test_github_origin_with_missing_gh_refuses() {
  local rec checkout bare out rc bintmp
  rec=$(make_origin missing-gh)
  IFS='|' read -r checkout bare <<< "$rec"
  bintmp=$(path_without_forge "$TMP/missing-gh/bin")
  rc=0
  out=$(PATH="$bintmp" "$CHECK" "$checkout" fm/missing-gh-task 2>&1) || rc=$?
  expect_code 2 "$rc" "a GitHub origin with gh missing did not refuse as unanswerable"
  assert_contains "$out" "gh-axi/gh is missing" "missing-gh refusal did not say so"
  pass "a GitHub origin with gh/gh-axi missing refuses the duplicate question"
}

test_unauthenticated_github_refuses() {
  local rec checkout bare fakebin out rc
  rec=$(make_origin unauth)
  IFS='|' read -r checkout bare <<< "$rec"
  fakebin=$(fm_fakebin "$TMP/unauth")
  fake_forge "$fakebin" 0
  rc=0
  out=$(FM_FAKE_GH_AUTH_RC=1 PATH="$fakebin:$PATH" "$CHECK" "$checkout" fm/unauth-task 2>&1) || rc=$?
  expect_code 2 "$rc" "an unauthenticated GitHub origin did not refuse"
  assert_contains "$out" "not authenticated" "unauthenticated refusal did not say so"
  pass "an unauthenticated GitHub origin refuses the duplicate question"
}

test_open_pr_query_failure_refuses() {
  local rec checkout bare fakebin out rc
  rec=$(make_origin queryfail)
  IFS='|' read -r checkout bare <<< "$rec"
  fakebin=$(fm_fakebin "$TMP/queryfail")
  fake_forge "$fakebin" 0
  rc=0
  out=$(FM_FAKE_GH_AXI_RC=1 PATH="$fakebin:$PATH" "$CHECK" "$checkout" fm/queryfail-task 2>&1) || rc=$?
  expect_code 2 "$rc" "a failed open-PR query did not refuse as unanswerable"
  assert_contains "$out" "query failed" "query-failure refusal did not say so"
  pass "a failed open-PR query refuses the duplicate question"
}

test_open_pr_covering_branch_refuses() {
  local rec checkout bare fakebin out rc
  rec=$(make_origin covered)
  IFS='|' read -r checkout bare <<< "$rec"
  fakebin=$(fm_fakebin "$TMP/covered")
  fake_forge "$fakebin" 1
  rc=0
  out=$(FM_FAKE_HEAD_COUNT=1 PATH="$fakebin:$PATH" "$CHECK" "$checkout" fm/covered-task 2>&1) || rc=$?
  expect_code 1 "$rc" "an open PR already covering the branch did not refuse"
  assert_contains "$out" "REFUSED" "covered-branch refusal did not say so"
  assert_contains "$out" "head branch" "covered-branch refusal did not name the head"
  pass "an open PR already covering the intended branch refuses"
}

test_open_pr_title_token_refuses() {
  local rec checkout bare fakebin out rc rows
  rec=$(make_origin token)
  IFS='|' read -r checkout bare <<< "$rec"
  fakebin=$(fm_fakebin "$TMP/token")
  rows='  42,"fix(parser): handle escaped braces in nested blocks",open,alice,no,none'
  fake_forge "$fakebin" 0 "$rows"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$CHECK" "$checkout" fm/escaped-braces-task parser 2>&1) || rc=$?
  expect_code 1 "$rc" "an open PR whose title covers a description token did not refuse"
  assert_contains "$out" "REFUSED" "token refusal did not say so"
  assert_contains "$out" "covers token" "token refusal did not name the token"
  pass "an open PR whose title covers a description token refuses"
}

test_token_match_can_be_overridden() {
  local rec checkout bare fakebin out rc rows
  rec=$(make_origin token-override)
  IFS='|' read -r checkout bare <<< "$rec"
  fakebin=$(fm_fakebin "$TMP/token-override")
  rows='  43,"fix(parser): handle escaped braces",open,bob,no,none'
  fake_forge "$fakebin" 0 "$rows"
  rc=0
  out=$(FM_FAKE_LIST_COUNT=1 PATH="$fakebin:$PATH" "$CHECK" "$checkout" fm/token-override-task --duplicate-ok braces) || rc=$?
  expect_code 0 "$rc" "--duplicate-ok did not override a title-token duplicate"
  assert_contains "$out" "overrides" "title-token override did not say so"
  pass "--duplicate-ok dispatches anyway when a title-token duplicate exists"
}

test_listing_failure_refuses() {
  local rec checkout bare fakebin out rc
  rec=$(make_origin listfail)
  IFS='|' read -r checkout bare <<< "$rec"
  fakebin=$(fm_fakebin "$TMP/listfail")
  fake_forge "$fakebin" 0
  rc=0
  out=$(FM_FAKE_LIST_RC=1 PATH="$fakebin:$PATH" "$CHECK" "$checkout" fm/listfail-task 2>&1) || rc=$?
  expect_code 2 "$rc" "a failed open-PR listing did not refuse as unanswerable"
  assert_contains "$out" "listing failed" "listing-failure refusal did not say so"
  pass "a failed open-PR listing refuses the duplicate question"
}

test_not_a_git_checkout_usage() {
  local dir=$TMP/notgit out rc
  mkdir -p "$dir"
  rc=0
  out=$("$CHECK" "$dir" fm/x 2>&1) || rc=$?
  expect_code 2 "$rc" "a non-checkout directory did not produce a usage error"
  assert_contains "$out" "not a Git work tree" "non-checkout refusal did not say so"
  pass "a directory that is not a Git checkout produces a usage error"
}

test_missing_argument_usage() {
  local out rc
  rc=0
  out=$("$CHECK" 2>&1) || rc=$?
  expect_code 2 "$rc" "missing arguments did not produce a usage error"
  assert_contains "$out" "usage" "missing-argument refusal did not show usage"
  pass "missing arguments produce a usage error"
}

test_origin_less_and_local_origin_with_no_branch_clears
test_existing_branch_refuses
test_duplicate_ok_overrides_existing_branch
test_github_origin_with_missing_gh_refuses
test_unauthenticated_github_refuses
test_open_pr_query_failure_refuses
test_open_pr_covering_branch_refuses
test_open_pr_title_token_refuses
test_token_match_can_be_overridden
test_listing_failure_refuses
test_not_a_git_checkout_usage
test_missing_argument_usage