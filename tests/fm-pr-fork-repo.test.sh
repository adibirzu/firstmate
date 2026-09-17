#!/usr/bin/env bash
# Fork-correct PR reads: a fork checkout's PR read must target the fork, never
# the upstream parent. Exercises the rendered gh calls of firstmate's PR
# surfaces and the shared origin-remote derivation, rather than asserting
# source bytes.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-fork-repo)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
FORK_SLUG=adibirzu/firstmate
PARENT_SLUG=kunchenguid/firstmate
FORK_HEAD=1111111111111111111111111111111111111111
PARENT_HEAD=2222222222222222222222222222222222222222

# Build a home, a worktree directory, a no-op guard, and a fake gh. The fake gh
# models the reported default-repo trap: a read that passes no explicit --repo
# is answered from the parent repository, while an explicit --repo is answered
# from that repository. So a surface that omits --repo observes parent data.
make_case() {  # <name>
  local name=$1 dir fakebin root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$fakebin" "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
repo=""
want_repo=0
for a in "$@"; do
  if [ "$want_repo" = 1 ]; then repo=$a; want_repo=0; continue; fi
  case "$a" in
    --repo) want_repo=1 ;;
    --repo=*) repo=${a#--repo=} ;;
  esac
done
# No explicit --repo models gh resolving against its own default repository,
# which for a fork checkout under the reported bug is the parent.
[ -n "$repo" ] || repo=$FM_TEST_PARENT_SLUG
case " $* " in
  *" headRefOid "*)
    if [ "$repo" = "$FM_TEST_FORK_SLUG" ]; then printf '%s\n' "$FM_TEST_FORK_HEAD"
    else printf '%s\n' "$FM_TEST_PARENT_HEAD"; fi
    ;;
  *" state "*)
    if [ "$repo" = "$FM_TEST_FORK_SLUG" ]; then printf '%s\n' "${FM_TEST_FORK_STATE:-OPEN}"
    else printf '%s\n' "${FM_TEST_PARENT_STATE:-OPEN}"; fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

write_task_meta() {  # <dir> [id]
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=direct-PR"
}

run_check_entry() {  # <dir> <args...>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_FORK_SLUG="$FORK_SLUG" FM_TEST_PARENT_SLUG="$PARENT_SLUG" \
    FM_TEST_FORK_HEAD="$FORK_HEAD" FM_TEST_PARENT_HEAD="$PARENT_HEAD" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

test_origin_remote_derivation() {
  local repo
  repo="$TMP_ROOT/origin-remote"
  fm_git_init_commit "$repo"
  git -C "$repo" remote add origin "https://github.com/$FORK_SLUG.git"
  [ "$(fm_pr_github_repo_from_checkout "$repo")" = "$FORK_SLUG" ] \
    || fail "an https fork origin remote did not resolve to the fork"
  git -C "$repo" remote set-url origin "git@github.com:$PARENT_SLUG.git"
  [ "$(fm_pr_github_repo_from_checkout "$repo")" = "$PARENT_SLUG" ] \
    || fail "an ssh parent origin remote did not resolve to the parent"
  git -C "$repo" remote set-url origin "https://github.com/$FORK_SLUG"
  [ "$(fm_pr_github_repo_from_checkout "$repo")" = "$FORK_SLUG" ] \
    || fail "a remote without a .git suffix did not resolve to the fork"
  [ "$(fm_pr_github_repo_slug "ssh://git@github.com/$FORK_SLUG.git")" = "$FORK_SLUG" ] \
    || fail "an ssh:// fork remote did not resolve to the fork"
  [ "$(fm_pr_github_repo_slug "https://github.com/$FORK_SLUG/pull/42")" = "$FORK_SLUG" ] \
    || fail "a canonical fork PR URL did not resolve to the fork"
  ! fm_pr_github_repo_slug "https://github.com.evil/evil/firstmate" >/dev/null \
    || fail "a spoofed github.com host resolved a GitHub slug"
  ! fm_pr_github_repo_slug "https://gitlab.com/$FORK_SLUG" >/dev/null \
    || fail "a non-GitHub host resolved a GitHub slug"
  git -C "$repo" remote set-url origin "file:///tmp/not-github.git"
  ! fm_pr_github_repo_from_checkout "$repo" \
    || fail "a non-GitHub origin remote resolved a GitHub slug"
  pass "fork and parent origin remotes resolve to an explicit owner/repository"
}

test_pr_check_read_pins_the_fork() {
  local dir
  dir=$(make_case pr-check-fork)
  write_task_meta "$dir"
  run_check_entry "$dir" task-a "https://github.com/$FORK_SLUG/pull/42" \
    > "$dir/stdout" 2> "$dir/stderr" || fail "fork PR check failed: $(cat "$dir/stderr")"
  grep -qxF "pr_head=$FORK_HEAD" "$dir/home/state/task-a.meta" \
    || fail "PR head read resolved to the parent repository, not the fork: $(cat "$dir/home/state/task-a.meta")"
  assert_grep "--repo $FORK_SLUG" "$dir/gh.log" "PR check gh read did not pass an explicit fork --repo"
  assert_no_grep "$PARENT_SLUG" "$dir/gh.log" "PR check gh read referenced the parent repository"
  pass "fm-pr-check.sh records the fork's PR head through an explicit --repo"
}

test_poll_read_pins_the_fork() {
  local dir out
  dir=$(make_case poll-fork)
  out=$(FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_FORK_SLUG="$FORK_SLUG" FM_TEST_PARENT_SLUG="$PARENT_SLUG" \
    FM_TEST_FORK_STATE=MERGED FM_TEST_PARENT_STATE=OPEN \
    PATH="$dir/fakebin:$BASE_PATH" \
    bash "$POLL" --validated github "https://github.com/$FORK_SLUG/pull/42" \
      github.com "$FORK_SLUG" 42)
  [ "$out" = merged ] || fail "static poll resolved the parent repository instead of the fork: '$out'"
  assert_grep "--repo $FORK_SLUG" "$dir/gh.log" "static poll gh read did not pass an explicit fork --repo"
  assert_no_grep "$PARENT_SLUG" "$dir/gh.log" "static poll gh read referenced the parent repository"
  pass "fm-pr-poll.sh reads the fork through an explicit --repo"
}

test_origin_remote_derivation
test_pr_check_read_pins_the_fork
test_poll_read_pins_the_fork
