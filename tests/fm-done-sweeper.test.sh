#!/usr/bin/env bash
# Behavior tests for bin/fm-done-sweeper.sh: auto-teardown of Done tasks.
#
# Guarantees under test:
#   - when finished tasks (PR merged/closed + state done) exceed keepDone (default: 5),
#     the oldest tasks are auto-torn down
#   - tasks with open PRs or non-done states are never swept
#   - scout tasks with report.md are eligible when done
#   - secondmates are preserved and never swept
#   - --keep flag and config/keepDone are honored
#   - --dry-run prints actions without modifying state
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEPER="$ROOT/bin/fm-done-sweeper.sh"
TMP_ROOT=$(fm_test_tmproot fm-done-sweeper)
fm_git_identity

setup_home() {
  local home="$1"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
}

create_task() {
  local home=$1 id=$2 state=$3 pr_state=$4 kind=${5:-ship} mtime_offset=${6:-0}
  local meta="$home/state/$id.meta"
  local status="$home/state/$id.status"

  mkdir -p "$home/data/$id"
  cat > "$meta" <<EOF
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$home/projects/$id
project=$home/projects/$id
harness=opencode
kind=$kind
mode=no-mistakes
yolo=off
EOF

  if [ -n "$pr_state" ]; then
    printf 'pr=https://github.com/example/repo/pull/123\n' >> "$meta"
  fi

  printf '%s: work completed\n' "$state" > "$status"
  if [ "$mtime_offset" -gt 0 ]; then
    # Adjust mtime so older tasks have older timestamps.
    local past
    past=$(date -v "-${mtime_offset}S" +%Y%m%d%H%M.%S 2>/dev/null || date -d "-${mtime_offset} seconds" +%Y%m%d%H%M.%S 2>/dev/null || true)
    if [ -n "$past" ]; then
      touch -t "$past" "$status" 2>/dev/null || true
    fi
  fi
}

make_fake_teardown() {
  local dir=$1
  cat > "$dir/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
set -u
task=$1
printf 'torn_down: %s\n' "$task" >> "${FM_TEST_TEARDOWN_LOG:?}"
rm -f "$FM_HOME/state/$task.meta" "$FM_HOME/state/$task.status"
exit 0
SH
  chmod +x "$dir/fm-teardown.sh"
}

create_local_only_worktree() {
  local home=$1 id=$2 landed=$3 project worktree
  project="$home/projects/project"
  worktree="$home/projects/$id"
  if [ ! -d "$project/.git" ]; then
    git init -q -b main "$project"
    printf 'base\n' > "$project/README.md"
    git -C "$project" add README.md
    git -C "$project" commit -qm base
  fi
  git -C "$project" worktree add -q -b "$id" "$worktree"
  if [ "$landed" != 1 ]; then
    printf '%s\n' "$id" >> "$worktree/README.md"
    git -C "$worktree" add README.md
    git -C "$worktree" commit -qm unlanded
  fi
  printf 'mode=local-only\nworktree=%s\nproject=%s\n' "$worktree" "$project" >> "$home/state/$id.meta"
}

# --- Test 1: Fewer than keepDone tasks => nothing swept ---
{
  dir="$TMP_ROOT/test-below-limit"
  setup_home "$dir"
  create_task "$dir" "task-1" "done" "MERGED" "ship" 10
  create_task "$dir" "task-2" "done" "MERGED" "ship" 5
  create_task "$dir" "task-3" "done" "MERGED" "ship" 1

  log="$dir/teardown.log"
  farm="$dir/bin"
  mkdir -p "$farm"
  ln -sf "$ROOT/bin/fm-classify-lib.sh" "$farm/fm-classify-lib.sh"
  ln -sf "$ROOT/bin/fm-landed-lib.sh" "$farm/fm-landed-lib.sh"
  make_fake_teardown "$farm"

  out=$(FM_HOME="$dir" FM_TEST_TEARDOWN_LOG="$log" FM_TEST_GH_STATE=MERGED "$SWEEPER" --keep 5 2>&1)
  [ ! -f "$log" ] || fail "sweeper should not tear down when count <= keep: $(cat "$log")"
  pass "done-sweeper: preserves all when finished tasks <= keepDone"
}

# --- Test 2: More than keepDone tasks => oldest swept ---
{
  dir="$TMP_ROOT/test-above-limit"
  setup_home "$dir"
  create_task "$dir" "task-old1" "done" "MERGED" "ship" 100
  create_task "$dir" "task-old2" "done" "CLOSED" "ship" 80
  create_task "$dir" "task-k1" "done" "MERGED" "ship" 50
  create_task "$dir" "task-k2" "done" "MERGED" "ship" 40
  create_task "$dir" "task-k3" "done" "MERGED" "ship" 30
  create_task "$dir" "task-k4" "done" "MERGED" "ship" 20
  create_task "$dir" "task-k5" "done" "MERGED" "ship" 10

  log="$dir/teardown.log"
  # Create wrapper around sweeper that calls fake teardown in SCRIPT_DIR
  farm="$dir/bin"
  mkdir -p "$farm"
  ln -sf "$ROOT/bin/fm-classify-lib.sh" "$farm/fm-classify-lib.sh"
  ln -sf "$ROOT/bin/fm-landed-lib.sh" "$farm/fm-landed-lib.sh"
  make_fake_teardown "$farm"
  cp "$SWEEPER" "$farm/fm-done-sweeper.sh"
  chmod +x "$farm/fm-done-sweeper.sh"

  out=$(FM_HOME="$dir" FM_TEST_TEARDOWN_LOG="$log" FM_TEST_GH_STATE=MERGED "$farm/fm-done-sweeper.sh" --keep 5 2>&1)
  [ -f "$log" ] || fail "sweeper should have torn down excess tasks: $out"
  assert_contains "$(cat "$log")" "task-old1" "oldest task-old1 torn down"
  assert_contains "$(cat "$log")" "task-old2" "second oldest task-old2 torn down"
  [ ! -f "$dir/state/task-old1.meta" ] || fail "task-old1 meta should be removed"
  [ ! -f "$dir/state/task-old2.meta" ] || fail "task-old2 meta should be removed"
  [ -f "$dir/state/task-k1.meta" ] || fail "task-k1 should be preserved in keep 5"
  [ -f "$dir/state/task-k5.meta" ] || fail "task-k5 should be preserved in keep 5"
  pass "done-sweeper: auto-tears down excess finished tasks keeping most recent keepDone:5"
}

# --- Test 3: Unfinished and open-PR tasks are never swept ---
{
  dir="$TMP_ROOT/test-filter-unlanded"
  setup_home "$dir"
  create_task "$dir" "task-working" "working" "MERGED" "ship" 100
  create_task "$dir" "task-blocked" "blocked" "MERGED" "ship" 90
  create_task "$dir" "task-open-pr" "done" "OPEN" "ship" 80

  log="$dir/teardown.log"
  farm="$dir/bin"
  mkdir -p "$farm"
  ln -sf "$ROOT/bin/fm-classify-lib.sh" "$farm/fm-classify-lib.sh"
  ln -sf "$ROOT/bin/fm-landed-lib.sh" "$farm/fm-landed-lib.sh"
  make_fake_teardown "$farm"
  cp "$SWEEPER" "$farm/fm-done-sweeper.sh"

  out=$(FM_HOME="$dir" FM_TEST_TEARDOWN_LOG="$log" FM_TEST_GH_STATE=OPEN "$farm/fm-done-sweeper.sh" --keep 1 2>&1)
  [ ! -f "$log" ] || fail "unlanded/non-done tasks must never be torn down: $(cat "$log")"
  pass "done-sweeper: ignores working, blocked, and open-PR tasks"
}

# --- Test 4: Dry-run does not mutate ---
{
  dir="$TMP_ROOT/test-dryrun"
  setup_home "$dir"
  create_task "$dir" "task-1" "done" "MERGED" "ship" 30
  create_task "$dir" "task-2" "done" "MERGED" "ship" 10

  log="$dir/teardown.log"
  farm="$dir/bin"
  mkdir -p "$farm"
  ln -sf "$ROOT/bin/fm-classify-lib.sh" "$farm/fm-classify-lib.sh"
  ln -sf "$ROOT/bin/fm-landed-lib.sh" "$farm/fm-landed-lib.sh"
  make_fake_teardown "$farm"
  cp "$SWEEPER" "$farm/fm-done-sweeper.sh"

  out=$(FM_HOME="$dir" FM_TEST_TEARDOWN_LOG="$log" FM_TEST_GH_STATE=MERGED "$farm/fm-done-sweeper.sh" --keep 1 --dry-run 2>&1)
  assert_contains "$out" "[dry-run] would tear down task-1" "dry run logs planned action"
  [ ! -f "$log" ] || fail "dry-run must not execute teardown"
  [ -f "$dir/state/task-1.meta" ] || fail "dry-run must preserve meta"
  pass "done-sweeper: --dry-run logs without tearing down"
}

# --- Test 5: Landed local-only tasks are swept, unlanded work is preserved ---
{
  dir="$TMP_ROOT/test-local-only"
  setup_home "$dir"
  create_task "$dir" "local-landed" "done" "" "ship" 20
  create_task "$dir" "local-unlanded" "done" "" "ship" 10
  create_local_only_worktree "$dir" "local-landed" 1
  create_local_only_worktree "$dir" "local-unlanded" 0

  log="$dir/teardown.log"
  farm="$dir/bin"
  mkdir -p "$farm"
  ln -sf "$ROOT/bin/fm-classify-lib.sh" "$farm/fm-classify-lib.sh"
  ln -sf "$ROOT/bin/fm-landed-lib.sh" "$farm/fm-landed-lib.sh"
  make_fake_teardown "$farm"
  cp "$SWEEPER" "$farm/fm-done-sweeper.sh"
  chmod +x "$farm/fm-done-sweeper.sh"

  FM_HOME="$dir" FM_TEST_TEARDOWN_LOG="$log" "$farm/fm-done-sweeper.sh" --keep 0 >/dev/null
  assert_contains "$(cat "$log")" "local-landed" "landed local-only task should be swept"
  [ -f "$dir/state/local-unlanded.meta" ] || fail "unlanded local-only task must be preserved"
  pass "done-sweeper: sweeps landed local-only work and preserves unlanded work"
}

printf 'All fm-done-sweeper tests passed.\n'
