#!/usr/bin/env bash
# Behavior tests for fm-graphify.sh: outside-repo indexes, on-demand freshness,
# token-budgeted query, and fallback-to-source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GRAPHIFY="$ROOT/bin/fm-graphify.sh"
TMP_ROOT=$(fm_test_tmproot fm-graphify-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

write_graphify_shim() {
  local fakebin=$1
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
set -eu
log=${GRAPHIFY_LOG:-/dev/null}
{
  printf 'argv'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "$log"

cmd=${1:-}
shift || true
case "$cmd" in
  extract)
    path=
    out=
    while [ $# -gt 0 ]; do
      case "$1" in
        --out|--output)
          out=$2
          shift 2
          ;;
        --no-cluster|--code-only)
          shift
          ;;
        --*)
          shift
          ;;
        *)
          [ -z "$path" ] && path=$1
          shift
          ;;
      esac
    done
    [ -n "$out" ] || exit 3
    mkdir -p "$out/graphify-out"
    printf '{"nodes":[]}\n' > "$out/graphify-out/graph.json"
    if [ "${GRAPHIFY_WRITE_IN_PROJECT:-}" = 1 ] && [ -n "$path" ]; then
      mkdir -p "$path/graphify-out"
      printf '{"nodes":[]}\n' > "$path/graphify-out/graph.json"
    fi
    if [ "${GRAPHIFY_MUTATE_TREE:-}" = 1 ] && [ -n "$path" ]; then
      printf 'changed during extract\n' >> "$path/README.md"
    fi
    exit 0
    ;;
  query)
    question=$1
    budget=
    graph=
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --budget)
          budget=$2
          shift 2
          ;;
        --graph)
          graph=$2
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf 'QUERY question=%s budget=%s graph=%s\n' "$question" "$budget" "$graph"
    exit 0
    ;;
  update)
    printf 'unexpected update\n' >&2
    exit 4
    ;;
  *)
    exit 5
    ;;
esac
SH
  chmod +x "$fakebin/graphify"
}

run_g() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" GRAPHIFY_LOG="${GRAPHIFY_LOG:-}" \
    GRAPHIFY_WRITE_IN_PROJECT="${GRAPHIFY_WRITE_IN_PROJECT:-}" \
    GRAPHIFY_MUTATE_TREE="${GRAPHIFY_MUTATE_TREE:-}" "$GRAPHIFY" "$@"
}

extract_count() {
  [ -f "$1" ] || { printf '0'; return; }
  grep -c $'^argv\textract\t' "$1" || true
}

query_count() {
  [ -f "$1" ] || { printf '0'; return; }
  grep -c $'^argv\tquery\t' "$1" || true
}

test_help_works() {
  local out
  out=$("$GRAPHIFY" --help 2>&1) || fail "--help must work"
  assert_contains "$out" "query" "help names query"
  assert_contains "$out" "build" "help names build"
  assert_contains "$out" "--budget" "help names --budget"
  pass "help works"
}

test_refuses_usage_errors() {
  local home fakebin rc
  home="$TMP_ROOT/usage-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/usage-bin")
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  set +e
  run_g "$home" "$fakebin" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "bare call"
  set +e
  run_g "$home" "$fakebin" query >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "query without repo"
  set +e
  run_g "$home" "$fakebin" query "$home" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "query without question"
  set +e
  run_g "$home" "$fakebin" query "$home" "q" --budget 0 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "budget 0"
  set +e
  run_g "$home" "$fakebin" query "$home" "q" --budget no >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "non-numeric budget"
  pass "usage errors exit 1"
}

test_missing_graphify_falls_back() {
  local home repo fakebin out rc
  home="$TMP_ROOT/missing-home"
  repo="$TMP_ROOT/missing-repo"
  fakebin=$(fm_fakebin "$TMP_ROOT/missing-bin")
  mkdir -p "$home"
  fm_git_init_commit "$repo"
  set +e
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$GRAPHIFY" query "$repo" "where is readme" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "missing graphify"
  assert_contains "$out" "GRAPHIFY_FALLBACK=source" "missing graphify prints fallback"
  pass "missing graphify falls back to source"
}

test_non_git_falls_back() {
  local home dir fakebin out rc
  home="$TMP_ROOT/nongit-home"
  dir="$TMP_ROOT/nongit-dir"
  fakebin=$(fm_fakebin "$TMP_ROOT/nongit-bin")
  write_graphify_shim "$fakebin"
  mkdir -p "$home" "$dir"
  set +e
  out=$(run_g "$home" "$fakebin" query "$dir" "where is readme" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "non-git path"
  assert_contains "$out" "GRAPHIFY_FALLBACK=source" "non-git prints fallback"
  pass "a non-git path falls back to source"
}

test_query_builds_outside_repo_and_forwards_budget() {
  local home repo fakebin log out
  home="$TMP_ROOT/out-home"
  repo="$TMP_ROOT/out-repo"
  fakebin=$(fm_fakebin "$TMP_ROOT/out-bin")
  log="$TMP_ROOT/out.log"
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  fm_git_init_commit "$repo"
  GRAPHIFY_LOG=$log out=$(run_g "$home" "$fakebin" query "$repo" "who owns spawn" --budget 1500) \
    || fail "query failed: $out"
  assert_contains "$out" "QUERY question=who owns spawn budget=1500" "query forwards the question and budget"
  assert_contains "$out" "graph=" "query points at a graph.json"
  assert_absent "$repo/graphify-out" "query must not write graphify-out inside the project"
  [ "$(extract_count "$log")" = 1 ] || fail "first query should extract once, got $(extract_count "$log")"
  [ "$(query_count "$log")" = 1 ] || fail "first query should query once, got $(query_count "$log")"
  assert_no_grep $'\tupdate\t' "$log" "helper must not invoke graphify update"
  find "$home/data/graphify" -name graph.json | grep -q . \
    || fail "index graph.json must live under the firstmate home"
  pass "query builds outside the repo and forwards --budget"
}

test_second_query_reuses_fresh_index() {
  local home repo fakebin log
  home="$TMP_ROOT/cache-home"
  repo="$TMP_ROOT/cache-repo"
  fakebin=$(fm_fakebin "$TMP_ROOT/cache-bin")
  log="$TMP_ROOT/cache.log"
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  fm_git_init_commit "$repo"
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "first" >/dev/null \
    || fail "first cache query failed"
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "second" >/dev/null \
    || fail "second cache query failed"
  [ "$(extract_count "$log")" = 1 ] || fail "fresh index must not rebuild; extracts=$(extract_count "$log")"
  [ "$(query_count "$log")" = 2 ] || fail "both queries should run; queries=$(query_count "$log")"
  pass "a matching stamp reuses the index"
}

test_dirty_tree_rebuilds() {
  local home repo fakebin log
  home="$TMP_ROOT/dirty-home"
  repo="$TMP_ROOT/dirty-repo"
  fakebin=$(fm_fakebin "$TMP_ROOT/dirty-bin")
  log="$TMP_ROOT/dirty.log"
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  fm_git_init_commit "$repo"
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "before dirty" >/dev/null \
    || fail "pre-dirty query failed"
  printf '\ndirty\n' >> "$repo/README.md"
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "after dirty" >/dev/null \
    || fail "post-dirty query failed"
  [ "$(extract_count "$log")" = 2 ] || fail "dirty tree should rebuild; extracts=$(extract_count "$log")"
  pass "a dirty tree rebuilds before query"
}

test_head_change_rebuilds() {
  local home repo fakebin log
  home="$TMP_ROOT/head-home"
  repo="$TMP_ROOT/head-repo"
  fakebin=$(fm_fakebin "$TMP_ROOT/head-bin")
  log="$TMP_ROOT/head.log"
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  fm_git_init_commit "$repo"
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "before commit" >/dev/null \
    || fail "pre-commit query failed"
  printf 'more\n' > "$repo/extra.md"
  git -C "$repo" add extra.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm extra
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "after commit" >/dev/null \
    || fail "post-commit query failed"
  [ "$(extract_count "$log")" = 2 ] || fail "HEAD change should rebuild; extracts=$(extract_count "$log")"
  pass "a new HEAD rebuilds before query"
}

test_mid_extract_change_rebuilds_next_query() {
  local home repo fakebin log
  home="$TMP_ROOT/race-home"
  repo="$TMP_ROOT/race-repo"
  fakebin=$(fm_fakebin "$TMP_ROOT/race-bin")
  log="$TMP_ROOT/race.log"
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  fm_git_init_commit "$repo"
  GRAPHIFY_MUTATE_TREE=1 GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "during change" >/dev/null \
    || fail "mid-extract-change query failed"
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "after change" >/dev/null \
    || fail "post-change query failed"
  [ "$(extract_count "$log")" = 2 ] \
    || fail "a tree change during extract must rebuild on the next query; extracts=$(extract_count "$log")"
  pass "a tree change during extract rebuilds on the next query"
}

test_missing_graph_json_rebuilds() {
  local home repo fakebin log
  home="$TMP_ROOT/nograph-home"
  repo="$TMP_ROOT/nograph-repo"
  fakebin=$(fm_fakebin "$TMP_ROOT/nograph-bin")
  log="$TMP_ROOT/nograph.log"
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  fm_git_init_commit "$repo"
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "before delete" >/dev/null \
    || fail "pre-delete query failed"
  find "$home/data/graphify" -name graph.json -delete
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$repo" "after delete" >/dev/null \
    || fail "a deleted graph.json must rebuild instead of falling back"
  [ "$(extract_count "$log")" = 2 ] \
    || fail "a deleted graph.json should rebuild; extracts=$(extract_count "$log")"
  find "$home/data/graphify" -name graph.json | grep -q . \
    || fail "the rebuild must restore graph.json"
  pass "a deleted graph.json self-heals with a rebuild"
}

test_distinct_repos_get_distinct_indexes() {
  local home one two fakebin log
  home="$TMP_ROOT/distinct-home"
  one="$TMP_ROOT/projects/alpha"
  two="$TMP_ROOT/other/alpha"
  fakebin=$(fm_fakebin "$TMP_ROOT/distinct-bin")
  log="$TMP_ROOT/distinct.log"
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  fm_git_init_commit "$one"
  fm_git_init_commit "$two"
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$one" "one" >/dev/null \
    || fail "first repo query failed"
  GRAPHIFY_LOG=$log run_g "$home" "$fakebin" query "$two" "two" >/dev/null \
    || fail "second repo query failed"
  [ "$(extract_count "$log")" = 2 ] || fail "two repos should each extract once; extracts=$(extract_count "$log")"
  [ "$(find "$home/data/graphify" -name graph.json | wc -l | tr -d ' ')" = 2 ] \
    || fail "two repos must not share one index directory"
  pass "same-basename repos keep separate indexes"
}

test_in_project_write_falls_back() {
  local home repo fakebin out rc
  home="$TMP_ROOT/inproj-home"
  repo="$TMP_ROOT/inproj-repo"
  fakebin=$(fm_fakebin "$TMP_ROOT/inproj-bin")
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  fm_git_init_commit "$repo"
  set +e
  out=$(GRAPHIFY_WRITE_IN_PROJECT=1 run_g "$home" "$fakebin" query "$repo" "leak" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "in-project write"
  assert_contains "$out" "GRAPHIFY_FALLBACK=source" "in-project write prints fallback"
  pass "an in-project extract write is refused"
}

test_default_budget_is_2000() {
  local home repo fakebin out
  home="$TMP_ROOT/budget-home"
  repo="$TMP_ROOT/budget-repo"
  fakebin=$(fm_fakebin "$TMP_ROOT/budget-bin")
  write_graphify_shim "$fakebin"
  mkdir -p "$home"
  fm_git_init_commit "$repo"
  out=$(run_g "$home" "$fakebin" query "$repo" "default budget") \
    || fail "default-budget query failed"
  assert_contains "$out" "budget=2000" "default query budget is 2000"
  pass "query defaults to a 2000-token budget"
}

test_help_works
test_refuses_usage_errors
test_missing_graphify_falls_back
test_non_git_falls_back
test_query_builds_outside_repo_and_forwards_budget
test_second_query_reuses_fresh_index
test_dirty_tree_rebuilds
test_head_change_rebuilds
test_mid_extract_change_rebuilds_next_query
test_missing_graph_json_rebuilds
test_distinct_repos_get_distinct_indexes
test_in_project_write_falls_back
test_default_budget_is_2000
echo "ALL PASS: fm-graphify"
