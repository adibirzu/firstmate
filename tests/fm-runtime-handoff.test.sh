#!/usr/bin/env bash
# Tests for bin/fm-runtime-handoff.sh and fm-spawn.sh --reuse-worktree.
#
# Guarantees under test (behavior through the public scripts, not source bytes):
#   - successful handoff preserves commits and uncommitted changes in the
#     recorded worktree and does not call treehouse get/return
#   - state/<id>.meta harness= (and model/effort when supplied) update while
#     non-owned keys such as pr= are preserved
#   - handoff refuses when the worktree cannot be reconciled
#   - handoff refuses when the endpoint is still alive / ownership is ambiguous
#   - handoff refuses an unverified target harness
#   - statusline quota parse: unparseable => unknown, never exhausted
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HANDOFF="$ROOT/bin/fm-runtime-handoff.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
# shellcheck source=bin/fm-statusline-quota-lib.sh
. "$ROOT/bin/fm-statusline-quota-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-runtime-handoff)
fm_git_identity

# --- helpers ----------------------------------------------------------------

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# Record every invocation for assertions.
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  *"#{pane_current_command}"*)
    printf '%s\n' "${FM_FAKE_PANE_CMD:-bash}"
    exit 0
    ;;
  *"list-windows"*)
    # Both create_task and agent_state inventory use window_name lines.
    # Present = print the bare window name; absent = empty.
    if [ "${FM_FAKE_WINDOW_PRESENT:-0}" = 1 ] || [ -n "${FM_FAKE_EXISTING_WINDOW:-}" ]; then
      printf '%s\n' "${FM_FAKE_EXISTING_WINDOW:-${FM_FAKE_WINDOW_NAME:-fm-task}}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message)
    case "$*" in
      *'#S'*) printf '%s\n' "${FM_FAKE_SESSION:-firstmate}" ;;
      *'#{pane_id}'*) printf '%%1\n' ;;
      *'#{pane_current_path}'*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
      *'#{pane_current_command}'*) printf '%s\n' "${FM_FAKE_PANE_CMD:-bash}" ;;
      *) printf '%s\n' "${FM_FAKE_SESSION:-firstmate}" ;;
    esac
    exit 0
    ;;
  has-session|new-session|kill-window|set-window-option|send-keys) exit 0 ;;
  new-window)
    # -P -F '#{window_id}'
    printf '@9\n'
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  # treehouse must NOT be called for a successful reuse/handoff.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
printf '%s\n' "${HOME:-}" >> "${FM_FAKE_TREEHOUSE_HOMELOG:-/dev/null}"
case "${1:-}" in
  get)
    printf '%s\n' "${FM_FAKE_TREEHOUSE_WT:-}"
    exit 0
    ;;
  return) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"

  # fm-send is invoked for exit; stub it.
  cat > "$fakebin/fm-send-stub" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_SEND_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/fm-send-stub"

  printf '%s\n' "$fakebin"
}

# setup_case <name> <id>: home + project + worktree with a commit and dirty file.
# Sets CASE_DIR, CASE_HOME, CASE_PROJ, CASE_WT and exports FM_HOME + fake env
# in the CALLING shell (must not be run under command substitution).
setup_case() {
  local name=$1 id=$2 fakebin
  CASE_DIR="$TMP_ROOT/$name"
  CASE_HOME="$CASE_DIR/home"
  CASE_PROJ="$CASE_DIR/project"
  CASE_WT="$CASE_DIR/wt"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/data/$id" "$CASE_HOME/config" "$CASE_HOME/projects"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "fm/$id"
  # Extra landed commit on the task branch + uncommitted change.
  printf 'commit-body\n' > "$CASE_WT/feature.txt"
  git -C "$CASE_WT" add feature.txt
  git -C "$CASE_WT" commit -qm 'task work'
  printf 'uncommitted\n' > "$CASE_WT/dirty.txt"
  printf '# brief for %s\n' "$id" > "$CASE_HOME/data/$id/brief.md"
  fakebin=$(make_fakebin "$CASE_DIR")
  export FM_HOME="$CASE_HOME"
  export FM_FAKE_PANE_PATH="$CASE_WT"
  export FM_FAKE_TREEHOUSE_WT="$CASE_WT"
  export FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  export FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log"
  export FM_FAKE_SEND_LOG="$CASE_DIR/send.log"
  export FM_FAKE_SESSION=firstmate
  export FM_FAKE_WINDOW_NAME="fm-$id"
  export FM_FAKE_WINDOW_PRESENT=0
  export FM_FAKE_PANE_CMD=bash
  export FM_FAKE_EXISTING_WINDOW=
  export PATH="$fakebin:$PATH"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-test-$id" \
    "model=default" \
    "effort=default" \
    "pr=https://example.test/pr/1" \
    "pr_head=abc123"
}

# --- statusline quota parser ------------------------------------------------

{
  v=$(fm_statusline_quota_verdict 'garbage not a statusline')
  [ "$v" = unknown ] || fail "unparseable statusline must be unknown, got $v"
  pass "unparseable statusline => unknown (never exhausted)"
}

{
  v=$(fm_statusline_quota_verdict 'Context 100% left · weekly 21% left')
  [ "$v" = ok ] || fail "healthy codex statusline should be ok, got $v"
  pass "codex healthy statusline => ok"
}

{
  v=$(fm_statusline_quota_verdict 'Context 5% left · weekly 3% left')
  [ "$v" = low ] || fail "low codex statusline should be low, got $v"
  pass "codex low statusline => low"
}

{
  v=$(fm_statusline_quota_verdict 'weekly 0% left')
  [ "$v" = exhausted ] || fail "zero weekly should be exhausted, got $v"
  pass "codex zero weekly => exhausted"
}

{
  v=$(fm_statusline_quota_verdict '5HR 3% ↻2150 WK 5% ↻SAT@0100 SUB')
  [ "$v" = low ] || fail "claude low statusline should be low, got $v"
  pass "claude low statusline => low"
}

{
  v=$(fm_statusline_quota_verdict '5HR 0% WK 40%')
  [ "$v" = exhausted ] || fail "claude zero 5HR should be exhausted, got $v"
  pass "claude zero 5hr => exhausted"
}

# --- refusal: unverified harness -------------------------------------------

{
  setup_case refuse-unverified task-u1
  set +e
  out=$("$HANDOFF" task-u1 --harness not-a-real-harness --skip-exit 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unverified harness should refuse"
  assert_contains "$out" "not a verified adapter" "unverified harness message"
  [ -f "$CASE_WT/dirty.txt" ] || fail "refusal must not touch worktree"
  pass "refuses unverified target harness"
}

# --- refusal: missing worktree ---------------------------------------------

{
  setup_case refuse-missing-wt task-m1
  rm -rf "$CASE_WT"
  set +e
  out=$("$HANDOFF" task-m1 --harness claude --skip-exit 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing worktree should refuse"
  assert_contains "$out" "does not exist" "missing worktree message"
  pass "refuses when recorded worktree is missing"
}

# --- refusal: primary checkout as worktree ---------------------------------

{
  setup_case refuse-primary task-p1
  fm_write_meta "$CASE_HOME/state/task-p1.meta" \
    "window=firstmate:fm-task-p1" \
    "endpoint_task_id=task-p1" \
    "worktree=$CASE_PROJ" \
    "project=$CASE_PROJ" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  set +e
  out=$("$HANDOFF" task-p1 --harness claude --skip-exit 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "primary worktree should refuse"
  assert_contains "$out" "primary checkout" "primary checkout message"
  pass "refuses when worktree is the project primary"
}

# --- refusal: live endpoint without successful exit ------------------------

{
  setup_case refuse-alive task-a1
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=codex
  set +e
  out=$("$SPAWN" task-a1 --reuse-worktree --harness claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "alive endpoint should refuse reuse-worktree"
  assert_contains "$out" "still alive" "alive endpoint message"
  pass "refuses --reuse-worktree while endpoint is alive"
}

# --- refusal: ambiguous endpoint ownership ---------------------------------

{
  setup_case refuse-ambiguous task-q1
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=something-unknown
  set +e
  out=$("$SPAWN" task-q1 --reuse-worktree --harness claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ambiguous endpoint should refuse"
  assert_contains "$out" "cannot reconcile" "ambiguous ownership message"
  pass "refuses when endpoint ownership cannot be reconciled"
}

# --- success: reuse-worktree preserves commits, dirt, meta keys ------------

{
  setup_case success-reuse task-s1
  export FM_FAKE_WINDOW_PRESENT=0
  export FM_FAKE_PANE_CMD=bash
  : > "$FM_FAKE_TREEHOUSE_LOG"
  head_before=$(git -C "$CASE_WT" rev-parse HEAD)
  dirty_before=$(cat "$CASE_WT/dirty.txt")
  branch_before=$(git -C "$CASE_WT" rev-parse --abbrev-ref HEAD)

  set +e
  out=$(FM_SPAWN_SETTLE_POLLS=2 "$SPAWN" task-s1 --reuse-worktree --harness claude --model sonnet --effort high 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "reuse-worktree should succeed: $out"

  head_after=$(git -C "$CASE_WT" rev-parse HEAD)
  dirty_after=$(cat "$CASE_WT/dirty.txt")
  branch_after=$(git -C "$CASE_WT" rev-parse --abbrev-ref HEAD)
  [ "$head_before" = "$head_after" ] || fail "HEAD must be preserved"
  [ "$dirty_before" = "$dirty_after" ] || fail "uncommitted changes must be preserved"
  [ "$branch_before" = "$branch_after" ] || fail "branch must be preserved"

  meta=$(cat "$CASE_HOME/state/task-s1.meta")
  assert_contains "$meta" "harness=claude" "meta harness updated"
  assert_contains "$meta" "model=sonnet" "meta model updated"
  assert_contains "$meta" "effort=high" "meta effort updated"
  assert_contains "$meta" "pr=https://example.test/pr/1" "pr= preserved"
  assert_contains "$meta" "pr_head=abc123" "pr_head= preserved"
  assert_contains "$meta" "worktree=$CASE_WT" "worktree preserved"
  assert_contains "$meta" "mode=no-mistakes" "mode preserved"

  if [ -s "$FM_FAKE_TREEHOUSE_LOG" ]; then
    fail "treehouse must not be invoked on reuse-worktree; log=$(cat "$FM_FAKE_TREEHOUSE_LOG")"
  fi
  assert_contains "$out" "spawned task-s1 harness=claude" "spawn success line"
  pass "successful reuse preserves commits, dirt, and non-owned meta"
}

# --- success: handoff end-to-end with skip-exit (dead endpoint) -------------

{
  setup_case success-handoff task-h1
  export FM_FAKE_WINDOW_PRESENT=0
  export FM_FAKE_PANE_CMD=bash
  : > "$FM_FAKE_TREEHOUSE_LOG"
  head_before=$(git -C "$CASE_WT" rev-parse HEAD)
  printf 'uncommitted\n' > "$CASE_WT/dirty.txt"

  set +e
  out=$(
    FM_SPAWN_SETTLE_POLLS=2 \
    "$HANDOFF" task-h1 --harness claude --skip-exit \
      --progress-note "Codex quota exhausted mid-pipeline; 1 commit + dirty fix remain." \
      --model opus 2>&1
  )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "handoff should succeed: $out"
  assert_contains "$out" "handed-off task-h1" "handoff success line"
  assert_contains "$out" "to harness=claude" "handoff target harness"

  [ "$(git -C "$CASE_WT" rev-parse HEAD)" = "$head_before" ] || fail "handoff must preserve HEAD"
  [ -f "$CASE_WT/dirty.txt" ] || fail "handoff must preserve dirty file"
  meta=$(cat "$CASE_HOME/state/task-h1.meta")
  assert_contains "$meta" "harness=claude" "handoff meta harness"
  assert_contains "$meta" "pr=https://example.test/pr/1" "handoff preserves pr="
  [ -f "$CASE_HOME/data/task-h1/brief.md" ] || fail "original brief must remain"
  [ -f "$CASE_HOME/state/task-h1.handoff-prompt" ] || fail "handoff prompt should be written"
  prompt=$(cat "$CASE_HOME/state/task-h1.handoff-prompt")
  assert_contains "$prompt" "Codex quota exhausted" "progress note in handoff prompt"
  assert_contains "$prompt" "no-mistakes axi status" "pipeline re-attach instruction"
  assert_contains "$prompt" "brief for task-h1" "original brief content embedded"
  if [ -s "$FM_FAKE_TREEHOUSE_LOG" ]; then
    fail "handoff must not call treehouse; log=$(cat "$FM_FAKE_TREEHOUSE_LOG")"
  fi
  pass "successful handoff preserves work, updates meta, reuses brief"
}

# --- refusal: missing original brief ---------------------------------------

{
  setup_case refuse-brief task-b1
  rm -f "$CASE_HOME/data/task-b1/brief.md"
  set +e
  out=$("$HANDOFF" task-b1 --harness claude --skip-exit 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing brief should refuse"
  assert_contains "$out" "original brief missing" "missing brief message"
  pass "refuses when original brief is missing"
}

printf 'All fm-runtime-handoff tests passed.\n'
