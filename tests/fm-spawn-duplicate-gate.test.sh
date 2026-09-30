#!/usr/bin/env bash
# Behavior tests for fm-spawn's duplicate/superseded-work gate.
#
# A fresh ship whose fm/<id> branch already exists on origin is refused before
# any worker launches, leaving no task metadata behind; --duplicate-ok
# overrides that refusal for one concrete dispatch; a fresh ship with no such
# branch launches normally; and a scout with an existing branch still launches
# (investigating the work already under way is the scout's purpose, so the
# gate never applies to it).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-duplicate-gate)

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project origin pool publisher fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin"
}

# push_covered_branch <name> <id>: make origin already carry fm/<id>, the exact
# branch the brief tells this ship's worker to create.
push_covered_branch() {
  local name=$1 id=$2 case_dir publisher
  case_dir="$TMP_ROOT/$name"
  publisher="$case_dir/publisher"
  mkdir -p "$publisher"
  git clone --quiet "file://$case_dir/origin.git" "$publisher"
  git -C "$publisher" checkout --quiet -b "fm/$id"
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit --quiet --allow-empty -m "pre-existing work covering fm/$id"
  git -C "$publisher" push --quiet origin "fm/$id"
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    FM_FAKE_TREEHOUSE_WT="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

test_covered_branch_refuses_fresh_ship() {
  local rec id out status
  id='dup-gate-covered-r1'
  rec=$(make_case covered "$id")
  read_case_record "$rec"
  push_covered_branch covered "$id"

  out=$(run_spawn "$id" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship with a pre-existing fm/$id branch was dispatched"
  assert_contains "$out" "fm/$id" \
    "the refusal did not name the covered branch"
  assert_contains "$out" "refusing to dispatch a second worker on already-covered ground" \
    "the refusal did not explain the duplicate"
  assert_contains "$out" "--duplicate-ok" \
    "the refusal did not offer the concrete override"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused ship published task metadata"
  pass "a fresh ship with an already-existing fm/<id> branch on origin refuses before launch"
}

test_duplicate_ok_overrides_covered_branch() {
  local rec id out status
  id='dup-gate-override-r1'
  rec=$(make_case override "$id")
  read_case_record "$rec"
  push_covered_branch override "$id"

  out=$(run_spawn "$id" --mode direct-PR --yolo off --duplicate-ok)
  status=$?
  expect_code 0 "$status" "--duplicate-ok did not let the covered ship dispatch"$'\n'"$out"
  assert_contains "$out" "spawned $id" \
    "--duplicate-ok ship did not report success"
  pass "--duplicate-ok overrides the covered-branch refusal for one concrete dispatch"
}

test_clear_origin_launches_fresh_ship() {
  local rec id out status
  id='dup-gate-clear-r1'
  rec=$(make_case clear "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "a clear fresh ship was not dispatched"$'\n'"$out"
  assert_contains "$out" "spawned $id" "clear ship did not report success"
  assert_not_contains "$out" "already-covered ground" \
    "clear ship tripped the duplicate gate"
  pass "a fresh ship with no covering work launches normally"
}

test_scout_with_existing_branch_still_launches() {
  local rec id out status
  id='dup-gate-scout-r1'
  rec=$(make_case scout "$id")
  read_case_record "$rec"
  push_covered_branch scout "$id"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a scout investigating covered work was refused"$'\n'"$out"
  assert_contains "$out" "spawned $id" "scout did not report success"
  pass "a scout may launch even when an fm/<id> branch already exists on origin"
}

test_covered_branch_refuses_fresh_ship
test_duplicate_ok_overrides_covered_branch
test_clear_origin_launches_fresh_ship
test_scout_with_existing_branch_still_launches