#!/usr/bin/env bash
# shellcheck disable=SC2016
# Both child shells below are single-quoted bash -c sources, so their $
# expansions are deliberate: they must expand in the child, not here.
# Write-confinement regression guard: a sandboxed suspect-suite run must never
# write outside its own case directory, even when the ambient environment
# exports a live home through FM_TEST_HOME or FM_TEST_USER_HOME.
#
# Matrix:
#   (a) sourcing tests/lib.sh clears ambient FM_TEST_HOME/FM_TEST_USER_HOME,
#       so no case can inherit a live home through the pr-merge helper's
#       `${FM_TEST_HOME:-$case_dir/home}` fallback.
#   (b) a verified GitHub merge run under that poisoned ambient home still
#       records pr= and its merge-report line in the case state while the
#       fake live home and its parent stay byte-identical and fixture-free.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-write-confinement)

# Build a fresh sandbox for one case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_confinement_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$case_dir/wt" "$fakebin"
  cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_confinement_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    cat "\$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    cat "\$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

test_lib_clears_test_home_overrides() {
  local rc
  set +e
  env FM_TEST_HOME=/nonexistent-live-home FM_TEST_USER_HOME=/nonexistent-live-user \
    bash -c '
      set -u
      [ -n "${FM_TEST_HOME:-}" ] || exit 3
      [ -n "${FM_TEST_USER_HOME:-}" ] || exit 3
      . "$1/tests/lib.sh"
      [ -z "${FM_TEST_HOME+set}" ] || exit 4
      [ -z "${FM_TEST_USER_HOME+set}" ] || exit 4
      [ -z "${FM_HOME+set}" ] || exit 5
    ' _ "$ROOT"
  rc=$?
  set -e
  [ "$rc" -ne 3 ] || fail "the child did not inherit the poisoned ambient home overrides"
  [ "$rc" -ne 4 ] || fail "lib.sh kept an ambient FM_TEST_HOME or FM_TEST_USER_HOME"
  [ "$rc" -ne 5 ] || fail "lib.sh kept an ambient FM_HOME"
  expect_code 0 "$rc" "sourcing lib.sh under a poisoned ambient home"
  pass "lib.sh clears ambient test-home overrides so cases start from no home"
}

test_merge_confined_despite_ambient_test_home() {
  local live parent case_dir manifest_before manifest_after rc markers
  live="$TMP_ROOT/live-home"
  parent="$TMP_ROOT/live-parent"
  mkdir -p "$live/state" "$live/data" "$parent/state"
  cp "$ROOT/.tasks.toml" "$live/.tasks.toml"
  printf '%s\n' '## In flight' > "$live/data/backlog.md"
  printf 'mate-live\n' > "$live/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
    "$parent" > "$live/.fm-secondmate-parent"
  printf 'working: live parent marker\n' > "$parent/state/mate-live.status"
  manifest_before="$TMP_ROOT/manifest-before"
  manifest_after="$TMP_ROOT/manifest-after"
  find "$live" "$parent" -type f | LC_ALL=C sort | xargs cksum > "$manifest_before"

  case_dir=$(make_confinement_case merge-stays-sandboxed)
  add_confinement_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  # The poisoned ambient home a live secondmate session exports, resolved
  # through the same `${FM_TEST_HOME:-$case_dir/home}` fallback the pr-merge
  # helper uses. Sourcing lib.sh first must clear it back to the case dir.
  set +e
  env FM_HOME="$live" FM_TEST_HOME="$live" FM_TEST_USER_HOME="$live/user" \
    bash -c '
      set -u
      . "$1/tests/lib.sh"
      FM_ROOT_OVERRIDE="$2" \
      FM_HOME="${FM_TEST_HOME:-$3/home}" \
      FM_STATE_OVERRIDE="$3/state" \
      FM_TEST_GH_AXI_LOG="$3/gh-axi.log" \
      FM_TEST_GH_LOG="$3/gh.log" \
      FM_TEST_GH_OUTCOME="$3/github-outcome" \
      FM_TEST_GH_RULES="$3/github-rules" \
      HOME="$3/user-home" \
      PATH="$3/fakebin:$PATH" \
        "$4" task-x1 https://github.com/example/repo/pull/9 \
          > "$3/stdout" 2> "$3/stderr"
    ' _ "$ROOT" "$ROOT" "$case_dir" "$PR_MERGE"
  rc=$?
  set -e
  expect_code 0 "$rc" "merge-stays-sandboxed: fm-pr-merge should succeed: $(cat "$case_dir/stderr")"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "merge-stays-sandboxed: pr= was not recorded in the case state"
  assert_grep 'merged-task-x1' "$case_dir/state/.wake-queue" \
    "merge-stays-sandboxed: the merge-report line did not land in the case state"

  find "$live" "$parent" -type f | LC_ALL=C sort | xargs cksum > "$manifest_after"
  diff "$manifest_before" "$manifest_after" >/dev/null \
    || fail "merge-stays-sandboxed: the live home changed under a sandboxed run: $(diff "$manifest_before" "$manifest_after")"
  markers=$(grep -rl 'example/repo' "$live" "$parent" 2>/dev/null || true)
  [ -z "$markers" ] || fail "merge-stays-sandboxed: fixture markers escaped into the live home: $markers"
  pass "a sandboxed merge run leaves the live home byte-identical and fixture-free"
}

test_lib_clears_test_home_overrides
test_merge_confined_despite_ambient_test_home
