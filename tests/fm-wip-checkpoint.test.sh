#!/usr/bin/env bash
# Tests for bin/fm-wip-checkpoint.sh.
#
# Guarantees under test (behavior through the public script):
#   - the checkpoint commit's parent is the task branch head, and its tree holds
#     committed work, staged and unstaged edits, new untracked files, deletions,
#     and the worker handoff file at .fm-handoff.md
#   - ignored files are not captured
#   - the worktree is left exactly as it was: same HEAD, branch, index and files
#   - a second checkpoint replaces wip/<id>
#   - --push publishes refs/tags/wip/<id> to the remote, and the documented
#     restore recipe reproduces the work in a fresh clone on another "host"
#   - no handoff file means handoff=no and no .fm-handoff.md in the tree
#   - refusals: unset FM_HOME, missing meta, missing worktree=, invalid id
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-wip-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-wip-checkpoint)
fm_git_identity

# setup_task <name> <id>: a home with state/<id>.meta pointing at a worktree on
# branch fm/<id>, one commit ahead of main, with a bare origin.
setup_task() {
  CASE_DIR="$TMP_ROOT/$1"
  CASE_HOME="$CASE_DIR/home"
  CASE_WT="$CASE_DIR/wt"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/data/$2"
  fm_git_worktree "$CASE_DIR/repo" "$CASE_WT" "fm/$2"
  printf 'kept\n' > "$CASE_WT/kept.txt"
  printf 'gone\n' > "$CASE_WT/gone.txt"
  printf 'ignored.log\n' > "$CASE_WT/.gitignore"
  git -C "$CASE_WT" add kept.txt gone.txt .gitignore
  git -C "$CASE_WT" commit -qm "task work"
  fm_write_meta "$CASE_HOME/state/$2.meta" "worktree=$CASE_WT" "harness=opencode"
}

worktree_fingerprint() {  # <wt> -> HEAD, branch, index tree and porcelain status
  printf '%s|%s|%s|%s' \
    "$(git -C "$1" rev-parse HEAD)" \
    "$(git -C "$1" rev-parse --abbrev-ref HEAD)" \
    "$(git -C "$1" write-tree)" \
    "$(git -C "$1" status --porcelain=v1 --untracked-files=all)"
}

# --- snapshot content and a worktree left untouched -------------------------
{
  setup_task snapshot t-snap
  printf 'staged edit\n' > "$CASE_WT/kept.txt"
  git -C "$CASE_WT" add kept.txt
  printf 'unstaged edit\n' >> "$CASE_WT/README.md"
  printf 'brand new\n' > "$CASE_WT/new.txt"
  rm "$CASE_WT/gone.txt"
  printf 'noise\n' > "$CASE_WT/ignored.log"
  printf '## Next\nRun the browser test.\n' > "$CASE_HOME/data/t-snap/handoff.md"
  head=$(git -C "$CASE_WT" rev-parse HEAD)
  before=$(worktree_fingerprint "$CASE_WT")

  out=$(FM_HOME="$CASE_HOME" "$CHECKPOINT" t-snap 2>&1) || fail "checkpoint should succeed: $out"
  assert_contains "$out" "checkpoint t-snap" "summary line names the task"
  assert_contains "$out" "parent=$head" "summary names the branch head as parent"
  assert_contains "$out" "handoff=yes" "summary reports the handoff file"
  assert_contains "$out" "pushed=no" "no push without --push"

  tag="refs/tags/wip/t-snap"
  [ "$(git -C "$CASE_WT" rev-parse "$tag^")" = "$head" ] || fail "checkpoint parent must be the branch head"
  [ "$(git -C "$CASE_WT" show "$tag:kept.txt")" = "staged edit" ] || fail "staged edit missing from checkpoint"
  assert_contains "$(git -C "$CASE_WT" show "$tag:README.md")" "unstaged edit" "unstaged edit missing from checkpoint"
  [ "$(git -C "$CASE_WT" show "$tag:new.txt")" = "brand new" ] || fail "untracked file missing from checkpoint"
  ! git -C "$CASE_WT" cat-file -e "$tag:gone.txt" 2>/dev/null || fail "deleted file must be absent from checkpoint"
  ! git -C "$CASE_WT" cat-file -e "$tag:ignored.log" 2>/dev/null || fail "ignored file must not be captured"
  assert_contains "$(git -C "$CASE_WT" show "$tag:.fm-handoff.md")" "Run the browser test." "handoff file missing from checkpoint"

  assert_equals "$before" "$(worktree_fingerprint "$CASE_WT")" "checkpoint must not change HEAD, branch, index or files"
  pass "checkpoint captures committed, staged, unstaged, new, deleted work and the handoff file, and leaves the worktree untouched"

  printf 'second\n' > "$CASE_WT/new.txt"
  first=$(git -C "$CASE_WT" rev-parse "$tag")
  FM_HOME="$CASE_HOME" "$CHECKPOINT" t-snap >/dev/null 2>&1 || fail "second checkpoint should succeed"
  assert_not_equals "$first" "$(git -C "$CASE_WT" rev-parse "$tag")" "a new checkpoint replaces wip/<id>"
  [ "$(git -C "$CASE_WT" show "$tag:new.txt")" = "second" ] || fail "replacement checkpoint holds the newer work"
  pass "a later checkpoint replaces the earlier one"
}

# --- push and restore on another host ---------------------------------------
{
  setup_task push t-push
  printf 'in progress\n' > "$CASE_WT/new.txt"
  rm "$CASE_WT/gone.txt"
  printf '## Next\nFinish new.txt.\n' > "$CASE_HOME/data/t-push/handoff.md"
  git -C "$CASE_WT" push -q origin fm/t-push

  out=$(FM_HOME="$CASE_HOME" "$CHECKPOINT" t-push --push 2>&1) || fail "checkpoint --push should succeed: $out"
  assert_contains "$out" "pushed=origin" "summary reports the push"
  origin_url=$(git -C "$CASE_WT" remote get-url origin)
  git ls-remote "$origin_url" refs/tags/wip/t-push | grep -q . || fail "wip tag must be on the remote"

  other="$CASE_DIR/other-host"
  git clone -q "$origin_url" "$other"
  git -C "$other" fetch -q --force origin "refs/tags/wip/t-push:refs/tags/wip/t-push"
  git -C "$other" switch -q -c fm/t-push "wip/t-push^"
  git -C "$other" restore --source="wip/t-push" --worktree -- .
  [ "$(cat "$other/new.txt")" = "in progress" ] || fail "restore must bring back the uncommitted new file"
  assert_absent "$other/gone.txt" "restore must bring back the deletion"
  assert_contains "$(cat "$other/.fm-handoff.md")" "Finish new.txt." "restore must bring back the handoff file"
  [ "$(git -C "$other" rev-parse HEAD)" = "$(git -C "$CASE_WT" rev-parse HEAD)" ] || fail "restored branch must sit on the original head"
  pass "--push publishes wip/<id> and the documented recipe restores the work elsewhere"
}

# --- no handoff file ---------------------------------------------------------
{
  setup_task nohandoff t-none
  out=$(FM_HOME="$CASE_HOME" "$CHECKPOINT" t-none 2>&1) || fail "checkpoint without handoff should succeed: $out"
  assert_contains "$out" "handoff=no" "summary reports no handoff file"
  ! git -C "$CASE_WT" cat-file -e "refs/tags/wip/t-none:.fm-handoff.md" 2>/dev/null || fail "no handoff file means no .fm-handoff.md"
  pass "a task without a handoff file is still checkpointed"
}

# --- refusals -----------------------------------------------------------------
{
  setup_task refuse t-ref
  set +e
  out=$(env -u FM_HOME "$CHECKPOINT" t-ref 2>&1); rc=$?
  expect_code 1 "$rc" "unset FM_HOME"
  assert_contains "$out" "FM_HOME is not set" "unset FM_HOME message"
  out=$(FM_HOME="$CASE_HOME" "$CHECKPOINT" t-missing 2>&1); rc=$?
  expect_code 1 "$rc" "missing meta"
  fm_write_meta "$CASE_HOME/state/t-nowt.meta" "harness=opencode"
  out=$(FM_HOME="$CASE_HOME" "$CHECKPOINT" t-nowt 2>&1); rc=$?
  expect_code 1 "$rc" "meta without worktree="
  assert_contains "$out" "missing worktree=" "missing worktree= message"
  out=$(FM_HOME="$CASE_HOME" "$CHECKPOINT" '../escape' 2>&1); rc=$?
  expect_code 2 "$rc" "invalid id"
  out=$(FM_HOME="$CASE_HOME" "$CHECKPOINT" t-ref --bogus 2>&1); rc=$?
  expect_code 2 "$rc" "unknown option"
  set -e
  assert_absent "$CASE_DIR/repo/.git/refs/tags/wip" "refusals must not create a tag"
  pass "refuses unset FM_HOME, missing meta, missing worktree=, invalid id and unknown options"
}
