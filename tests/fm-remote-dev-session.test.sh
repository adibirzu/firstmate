#!/usr/bin/env bash
# Tests for bin/fm-remote-dev-session.sh, the guarded remote development session
# continuity command.
#
# The command establishes or reattaches one registered station's development
# session, records the continuity references, and refuses duplicate or stale
# work before launch. It must never launch a raw process: a dead endpoint is
# relaunched only through the ordinary task/second mate record paths, and an
# unreadable readiness or liveness state refuses rather than guessing.
#
# Every external boundary is a PATH stub or a real local git fixture, so no case
# touches a real station, a real session, or a real firstmate home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CMD="$ROOT/bin/fm-remote-dev-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-dev-session)
STUB="$TMP_ROOT/bin"
mkdir -p "$STUB"

# --- stubs ------------------------------------------------------------------

write_stub() {  # <name> <body>
  local name=$1
  mkdir -p "$STUB"
  cat > "$STUB/$name"
  chmod 0755 "$STUB/$name"
}

# The fm-on route stub: reads the remote command from argv and answers the
# doctor probe from the fixture environment.
write_stub fm-on <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_FMON_LOG:-/dev/null}"
if [ -n "${FM_TEST_DOCTOR_OUT:-}" ]; then printf '%s\n' "$FM_TEST_DOCTOR_OUT"; fi
exit "${FM_TEST_DOCTOR_RC:-0}"
SH

write_stub crew-state <<'SH'
#!/usr/bin/env bash
[ -n "${FM_TEST_CREW_STATE:-}" ] || exit 1
printf '%s\n' "$FM_TEST_CREW_STATE"
exit "${FM_TEST_CREW_RC:-0}"
SH

# The ssh stub answers the tmux readiness probe; every other argv succeeds.
write_stub ssh <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${*}" >> "${FM_TEST_SSH_LOG:-/dev/null}"
case "${*}" in
  *'-V'*) printf 'tmux 3.5a\n' ;;
esac
exit "${FM_TEST_SSH_RC:-0}"
SH

write_stub fm-spawn <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_SPAWN_LOG:-/dev/null}"
exit "${FM_TEST_SPAWN_RC:-0}"
SH

write_stub fm-control <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_CONTROL_LOG:-/dev/null}"
exit "${FM_TEST_CONTROL_RC:-0}"
SH

make_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

write_registry() {  # <home> <line...>
  local home=$1
  shift
  : > "$home/data/secondmates.md"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/data/secondmates.md"
  done
}

REMOTE_RECORD='- infra-remote - overflow firstmate work (host: adi2-ts; root: /home/adi/firstmate; home: /home/adi/.firstmate-infra; scope: firstmate repo work; projects: alpha; added 2026-09-13)'

# run_cmd <home> <out> <args...> [NAME=VALUE...]
# The NAME=VALUE pairs go before the command as environment assignments.
run_cmd() {
  local home=$1 out=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      *=*) envs+=("$1"); shift ;;
      *) break ;;
    esac
  done
  local status=0
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_RDS_FM_ON="$STUB/fm-on" FM_RDS_CREW_STATE="$STUB/crew-state" \
    FM_RDS_SPAWN="$STUB/fm-spawn" FM_RDS_CONTROL="$STUB/fm-control" \
    FM_RDS_HERDR="$STUB/herdr" FM_RDS_TMUX="$STUB/tmux" FM_RDS_SSH="$STUB/ssh" \
    "${envs[@]}" "$CMD" "$@" >"$out" 2>&1 || status=$?
  printf '%s\n' "$status"
}

# make_repo <home> <name>: a real repo with an origin bare, on branch main.
make_repo() {  # <home> <name>
  local home=$1 name=$2
  local repo="$home/projects/$name"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -m main 2>/dev/null || true
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" fetch --quiet origin main
  printf '%s\n' "$repo"
}

use_branch() {  # <repo> <branch>
  git -C "$1" checkout -q -b "$2" 2>/dev/null || git -C "$1" checkout -q "$2"
  printf 'work\n' > "$1/branch-work.txt"
  git -C "$1" add branch-work.txt
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm "$2 work"
}

write_meta() {  # <home> <id> <backend> <repo> [extra...]
  local home=$1 id=$2 backend=$3 repo=$4
  shift 4
  local lines=(
    "window=fm-remote:wK:p2"
    "endpoint_task_id=$id"
    "worktree=$repo"
    "project=alpha"
    "kind=ship"
    "spawn_gen=s123.456"
    "backend=$backend"
  )
  if [ "$backend" = herdr ]; then
    lines+=("herdr_session=fm-remote" "herdr_workspace_id=wK" "herdr_tab_id=wK:t2" "herdr_pane_id=wK:p2")
  fi
  local line
  for line in "$@"; do lines+=("$line"); done
  : > "$home/state/$id.meta"
  for line in "${lines[@]}"; do printf '%s\n' "$line" >> "$home/state/$id.meta"; done
}

# --- reference record -------------------------------------------------------

test_herdr_open_attaches_live_task_and_records_references() {
  local home repo status out rec
  home=$(make_home herdr-live)
  repo=$(make_repo "$home" alpha)
  use_branch "$repo" fm/t1
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    FM_TEST_FMON_LOG="$home/fmon.log" \
    open adi2 --task t1 --project alpha)
  expect_code 0 "$status" "herdr open exit"
  assert_grep 'fm-remote-doctor.sh' "$home/fmon.log" "the herdr readiness gate did not run the remote doctor"
  rec="$home/state/remote-dev-sessions/adi2.session"
  assert_present "$rec" "open did not write the continuity record"
  assert_grep 'backend=herdr' "$rec" "record lost the backend"
  assert_grep 'session=fm-remote' "$rec" "record lost the session"
  assert_grep 'host=adi2-ts' "$rec" "record lost the host"
  assert_grep 'workspace=wK' "$rec" "record lost the herdr workspace"
  assert_grep 'tab=wK:t2' "$rec" "record lost the herdr tab"
  assert_grep 'pane=wK:p2' "$rec" "record lost the herdr pane"
  assert_grep 'task_id=t1' "$rec" "record lost the task id"
  assert_grep 'branch=fm/t1' "$rec" "record lost the branch"
  assert_grep 'spawn_gen=s123.456' "$rec" "record lost the spawn generation"
  assert_grep "return_channel=$home/state/t1.status" "$rec" \
    "record lost the return channel"
  assert_contains "$(cat "$out")" "attach: herdr --remote adi2-ts --session fm-remote" \
    "the attach command was not printed"
  assert_contains "$(cat "$out")" 'action=attached' "a live endpoint was not attached"
  pass "herdr open attaches a live task and records every continuity reference"
}

test_dead_task_endpoint_relaunches_through_the_control_plane() {
  local home repo status out control spawn
  home=$(make_home herdr-dead)
  repo=$(make_repo "$home" alpha)
  use_branch "$repo" fm/t1
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"
  control="$home/control.log"
  spawn="$home/spawn.log"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: done · source: none · x' \
    FM_TEST_CONTROL_LOG="$control" FM_TEST_SPAWN_LOG="$spawn" \
    open adi2 --task t1 --project alpha)
  expect_code 0 "$status" "relaunch exit"
  assert_contains "$(cat "$out")" 'action=launched' "a dead endpoint was not relaunched"
  assert_contains "$(cat "$control")" 't1 relaunch' "the control plane was not the relaunch path"
  assert_absent "$spawn" "a task relaunch must not go through fm-spawn"
  pass "a dead task endpoint relaunches through the control plane, never a raw process"
}

test_dead_secondmate_endpoint_relaunches_through_fm_spawn() {
  local home status out control spawn meta
  home=$(make_home mate-dead)
  write_registry "$home" "$REMOTE_RECORD"
  meta="$home/state/infra-remote.meta"
  {
    printf 'window=fm-remote:wK:p2\n'
    printf 'endpoint_task_id=infra-remote\n'
    printf 'worktree=/home/adi/.firstmate-infra\n'
    printf 'project=infra-remote\n'
    printf 'kind=secondmate\n'
    printf 'spawn_gen=s999\n'
    printf 'backend=herdr\n'
    printf 'herdr_workspace_id=wK\nherdr_tab_id=wK:t2\nherdr_pane_id=wK:p2\n'
  } > "$meta"
  out="$home/out.txt"
  control="$home/control.log"
  spawn="$home/spawn.log"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: done · source: none · x' \
    FM_TEST_CONTROL_LOG="$control" FM_TEST_SPAWN_LOG="$spawn" \
    open adi2 --secondmate infra-remote)
  expect_code 0 "$status" "secondmate relaunch exit"
  assert_contains "$(cat "$out")" 'action=launched' "a dead second mate was not relaunched"
  assert_contains "$(cat "$spawn")" 'infra-remote --secondmate' "the second mate did not relaunch through fm-spawn"
  assert_absent "$control" "a second mate relaunch must not go through fm-control"
  pass "a dead second mate endpoint relaunches through fm-spawn --secondmate"
}

test_a_readiness_gap_refuses_with_the_doctor_text() {
  local home repo status out rec
  home=$(make_home gap)
  repo=$(make_repo "$home" alpha)
  use_branch "$repo" fm/t1
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"

  status=$(run_cmd "$home" "$out" \
    FM_TEST_DOCTOR_RC=1 \
    FM_TEST_DOCTOR_OUT='check herdr-server=fixable: no fm-remote server
action: herdr-server: rerun with --fix' \
    FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha)
  expect_code 5 "$status" "a red doctor must refuse"
  assert_contains "$(cat "$out")" 'check herdr-server=fixable' "the doctor gap text was not surfaced"
  assert_contains "$(cat "$out")" 'action: herdr-server' "the doctor action line was not surfaced"
  assert_absent "$home/state/remote-dev-sessions/adi2.session" "a refused open must not write a record"
  pass "a readiness gap refuses and prints the doctor's own gap text"
}

test_repair_rechecks_read_only_and_never_trusts_the_repair() {
  local home repo status out fmon
  home=$(make_home repair)
  repo=$(make_repo "$home" alpha)
  use_branch "$repo" fm/t1
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"
  fmon="$home/fmon.log"

  # The doctor stays red after the repair, so the second read-only check refuses.
  status=$(run_cmd "$home" "$out" \
    FM_TEST_DOCTOR_RC=1 FM_TEST_FMON_LOG="$fmon" \
    FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha --repair)
  expect_code 5 "$status" "a failed repair must still refuse"
  assert_grep 'fm-remote-doctor.sh --fix' "$fmon" "the repair was not attempted"
  assert_absent "$home/state/remote-dev-sessions/adi2.session" "a refused repair must not write a record"
  pass "repair runs then re-checks read-only, and a failed repair still refuses"
}

test_tmux_backend_is_explicit_and_renders_an_equivalent_attach() {
  local home repo status out rec
  home=$(make_home tmux)
  repo=$(make_repo "$home" alpha)
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 tmux "$repo"
  out="$home/out.txt"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha --backend tmux)
  expect_code 0 "$status" "tmux open exit"
  rec="$home/state/remote-dev-sessions/adi2.session"
  assert_grep 'backend=tmux' "$rec" "record lost the tmux backend"
  assert_grep 'window=fm-remote:wK:p2' "$rec" "record lost the tmux window"
  assert_contains "$(cat "$out")" "attach: ssh -t adi2-ts tmux attach -t fm-remote" \
    "the tmux attach command was not rendered"
  pass "the tmux fallback is explicit and renders an equivalent attach command"
}

test_tmux_config_fallback_never_replaces_a_failed_herdr() {
  local home repo status out rec
  home=$(make_home tmux-config)
  repo=$(make_repo "$home" alpha)
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 tmux "$repo"
  printf 'tmux\n' > "$home/config/remote-dev-backend"
  out="$home/out.txt"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha)
  expect_code 0 "$status" "configured tmux open exit"
  rec="$home/state/remote-dev-sessions/adi2.session"
  assert_grep 'backend=tmux' "$rec" "the configured tmux backend was not selected"

  # An explicit herdr that fails readiness must refuse, not fall back to tmux.
  status=$(run_cmd "$home" "$out" FM_TEST_DOCTOR_RC=1 \
    FM_TEST_DOCTOR_OUT='check herdr=human: herdr CLI missing' \
    FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha --backend herdr)
  expect_code 5 "$status" "a failed herdr must not silently fall back to tmux"
  pass "tmux is reachable only by explicit selection and never silently replaces a failed herdr"
}

test_unknown_backend_refuses() {
  local home status out
  home=$(make_home backend-bad)
  write_registry "$home" "$REMOTE_RECORD"
  out="$home/out.txt"
  status=$(run_cmd "$home" "$out" open adi2 --task t1 --backend screen)
  expect_code 2 "$status" "an unknown backend must be invalid use"
  assert_contains "$(cat "$out")" 'unknown backend' "the unknown backend was not named"
  pass "an unknown backend refuses"
}

test_unknown_liveness_refuses_to_relaunch() {
  local home repo status out control
  home=$(make_home unknown-live)
  repo=$(make_repo "$home" alpha)
  use_branch "$repo" fm/t1
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"
  control="$home/control.log"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_RC=1 \
    FM_TEST_CONTROL_LOG="$control" \
    open adi2 --task t1 --project alpha)
  expect_code 1 "$status" "an unknown liveness must refuse"
  assert_absent "$control" "an unknown liveness must never relaunch"
  assert_contains "$(cat "$out")" 'unknown' "the unknown liveness was not reported"
  pass "an unreadable liveness refuses instead of relaunching"
}

test_idle_remote_secondmate_attaches_without_relaunch() {
  local home status out control spawn meta
  home=$(make_home mate-idle)
  write_registry "$home" "$REMOTE_RECORD"
  meta="$home/state/infra-remote.meta"
  {
    printf 'window=fm-remote:wK:p2\n'
    printf 'endpoint_task_id=infra-remote\n'
    printf 'worktree=/home/adi/.firstmate-infra\n'
    printf 'project=infra-remote\n'
    printf 'kind=secondmate\n'
    printf 'spawn_gen=s999\n'
    printf 'backend=herdr\n'
    printf 'herdr_workspace_id=wK\nherdr_tab_id=wK:t2\nherdr_pane_id=wK:p2\n'
  } > "$meta"
  out="$home/out.txt"
  control="$home/control.log"
  spawn="$home/spawn.log"

  status=$(run_cmd "$home" "$out" \
    FM_TEST_CREW_STATE='state: unknown · source: remote-endpoint · alive on adi2-ts (an idle secondmate is healthy)' \
    FM_TEST_CONTROL_LOG="$control" FM_TEST_SPAWN_LOG="$spawn" \
    open adi2 --secondmate infra-remote)
  expect_code 0 "$status" "idle secondmate attach exit"
  assert_contains "$(cat "$out")" 'action=attached' "a healthy idle second mate was not attached"
  assert_absent "$spawn" "a healthy idle second mate must never relaunch through fm-spawn"
  assert_absent "$control" "a healthy idle second mate must never relaunch through fm-control"
  pass "a confirmed-alive idle remote secondmate attaches instead of relaunching"
}

test_check_runs_the_gates_without_launching_or_recording() {
  local home repo status out control spawn
  home=$(make_home check)
  repo=$(make_repo "$home" alpha)
  use_branch "$repo" fm/t1
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"
  control="$home/control.log"
  spawn="$home/spawn.log"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: done · source: none · x' \
    FM_TEST_CONTROL_LOG="$control" FM_TEST_SPAWN_LOG="$spawn" \
    check adi2 --task t1 --project alpha)
  expect_code 0 "$status" "check exit"
  assert_contains "$(cat "$out")" 'check=ok' "check did not report its verdict"
  assert_absent "$control" "check must not launch"
  assert_absent "$spawn" "check must not spawn"
  assert_absent "$home/state/remote-dev-sessions/adi2.session" "check must not write a record"
  pass "check runs the gates without launching or recording"
}

test_tmux_readiness_gap_refuses() {
  local home repo status out
  home=$(make_home tmux-gap)
  repo=$(make_repo "$home" alpha)
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 tmux "$repo"
  out="$home/out.txt"

  status=$(run_cmd "$home" "$out" FM_TEST_SSH_RC=1 \
    FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha --backend tmux)
  expect_code 5 "$status" "an unavailable remote tmux must refuse"
  assert_contains "$(cat "$out")" 'tmux is not available' "the tmux gap was not named"
  assert_absent "$home/state/remote-dev-sessions/adi2.session" "a tmux readiness gap must not write a record"
  pass "an unavailable remote tmux refuses instead of silently using herdr"
}

# --- pre-launch equivalence -------------------------------------------------

test_a_duplicate_branch_refuses() {
  local home repo status out
  home=$(make_home dup)
  repo=$(make_repo "$home" alpha)
  git -C "$repo" branch fm/work
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"

  # The task's own branch is main; an intended branch that already exists under
  # another name is duplicate work.
  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha --branch fm/work)
  expect_code 3 "$status" "an existing branch must refuse as duplicate"
  assert_absent "$home/state/remote-dev-sessions/adi2.session" "a duplicate refusal must not write a record"
  pass "an existing branch refuses as duplicate work"
}

test_a_stale_base_refuses() {
  local home repo status out
  home=$(make_home stale)
  repo=$(make_repo "$home" alpha)
  git -C "$repo" checkout -q -b fm/work
  printf 'work\n' > "$repo/work.txt"
  git -C "$repo" add work.txt
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm work
  git -C "$repo" checkout -q main
  printf 'more\n' > "$repo/main2.txt"
  git -C "$repo" add main2.txt
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm main2
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -q fm/work
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha)
  expect_code 4 "$status" "a branch behind the default must refuse as stale"
  pass "a branch behind the default refuses as stale work"
}

test_a_branch_already_landed_refuses() {
  local home repo status out
  home=$(make_home landed)
  repo=$(make_repo "$home" alpha)
  git -C "$repo" checkout -q -b fm/work
  printf 'work\n' > "$repo/work.txt"
  git -C "$repo" add work.txt
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm work
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --ff-only fm/work
  printf 'later\n' > "$repo/later.txt"
  git -C "$repo" add later.txt
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm later
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -q fm/work
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha)
  expect_code 4 "$status" "a branch already in the default must refuse as stale"
  pass "a branch already contained in the default refuses as stale work"
}

# --- recover, status, attach, list ------------------------------------------

test_recover_is_idempotent_and_inherits_the_recorded_target() {
  local home repo status out sha2
  home=$(make_home recover)
  repo=$(make_repo "$home" alpha)
  use_branch "$repo" fm/t1
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"

  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha)
  expect_code 0 "$status" "first open exit"
  status=$(run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    recover adi2)
  expect_code 0 "$status" "recover exit"
  assert_contains "$(cat "$out")" 'action=attached' "recover did not attach"
  assert_present "$home/state/remote-dev-sessions/adi2.session" "recover removed the record"
  sha2=$(sed -n 's/^updated=//p' "$home/state/remote-dev-sessions/adi2.session")
  [ -n "$sha2" ] || fail "recover left the record without an updated stamp"
  pass "recover is idempotent and inherits the recorded target"
}

test_status_and_attach_read_the_record() {
  local home repo status out rec
  home=$(make_home read)
  repo=$(make_repo "$home" alpha)
  use_branch "$repo" fm/t1
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"

  run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha >/dev/null

  status=$(run_cmd "$home" "$out" status adi2)
  expect_code 0 "$status" "status exit"
  assert_contains "$(cat "$out")" 'task_id=t1' "status did not print the record"

  status=$(run_cmd "$home" "$out" attach adi2)
  expect_code 0 "$status" "attach exit"
  assert_contains "$(cat "$out")" 'herdr --remote adi2-ts --session fm-remote' "attach did not print the command"

  # A malformed record refuses instead of half-trusting it.
  rec="$home/state/remote-dev-sessions/adi2.session"
  printf 'not-a-record\n' >> "$rec"
  status=$(run_cmd "$home" "$out" status adi2)
  expect_code 1 "$status" "a malformed record must refuse"
  pass "status and attach read the durable record and a malformed record refuses"
}

test_list_reports_records() {
  local home repo status out
  home=$(make_home list)
  repo=$(make_repo "$home" alpha)
  use_branch "$repo" fm/t1
  write_registry "$home" "$REMOTE_RECORD"
  write_meta "$home" t1 herdr "$repo"
  out="$home/out.txt"

  run_cmd "$home" "$out" FM_TEST_CREW_STATE='state: working · source: pane · busy' \
    open adi2 --task t1 --project alpha >/dev/null

  status=$(run_cmd "$home" "$out" list)
  expect_code 0 "$status" "list exit"
  assert_contains "$(cat "$out")" 'station=adi2' "list did not report the record"

  status=$(run_cmd "$home" "$out" list --json)
  expect_code 0 "$status" "list --json exit"
  assert_contains "$(cat "$out")" '"schema":"fm-remote-dev-session-list.v1"' "list --json lost its schema"
  printf '%s\n' "$(cat "$out")" | jq -e '.records | length == 1' >/dev/null 2>&1 \
    || fail "list --json did not carry the record as JSON"
  pass "list reports durable records as text and JSON"
}

# --- invalid use ------------------------------------------------------------

test_invalid_use_refuses() {
  local home status out
  home=$(make_home invalid)
  write_registry "$home" "$REMOTE_RECORD"
  out="$home/out.txt"

  status=$(run_cmd "$home" "$out")
  expect_code 2 "$status" "no action exit"

  status=$(run_cmd "$home" "$out" open adi2)
  expect_code 2 "$status" "open without a target exit"

  status=$(run_cmd "$home" "$out" frobnicate adi2)
  expect_code 2 "$status" "unknown action exit"

  status=$(run_cmd "$home" "$out" open 'bad/name' --task t1)
  expect_code 2 "$status" "bad station exit"

  status=$(run_cmd "$home" "$out" status adi2 --task t1)
  expect_code 2 "$status" "status with a target exit"

  status=$(run_cmd "$home" "$out" open adi2 --task t1 --backend 'bad/name')
  expect_code 2 "$status" "bad backend exit"

  status=$(run_cmd "$home" "$out" --help)
  expect_code 0 "$status" "help exit"
  pass "invalid use refuses with exit 2 and help succeeds"
}

test_a_task_without_a_record_refuses() {
  local home status out
  home=$(make_home no-record)
  write_registry "$home" "$REMOTE_RECORD"
  out="$home/out.txt"
  status=$(run_cmd "$home" "$out" open adi2 --task ghost)
  expect_code 1 "$status" "a task with no record must refuse"
  assert_contains "$(cat "$out")" 'no task record' "the missing record was not named"
  pass "a task with no record refuses rather than inventing one"
}

test_herdr_open_attaches_live_task_and_records_references
test_dead_task_endpoint_relaunches_through_the_control_plane
test_dead_secondmate_endpoint_relaunches_through_fm_spawn
test_a_readiness_gap_refuses_with_the_doctor_text
test_repair_rechecks_read_only_and_never_trusts_the_repair
test_tmux_backend_is_explicit_and_renders_an_equivalent_attach
test_tmux_config_fallback_never_replaces_a_failed_herdr
test_tmux_readiness_gap_refuses
test_unknown_backend_refuses
test_unknown_liveness_refuses_to_relaunch
test_idle_remote_secondmate_attaches_without_relaunch
test_check_runs_the_gates_without_launching_or_recording
test_a_duplicate_branch_refuses
test_a_stale_base_refuses
test_a_branch_already_landed_refuses
test_recover_is_idempotent_and_inherits_the_recorded_target
test_status_and_attach_read_the_record
test_list_reports_records
test_invalid_use_refuses
test_a_task_without_a_record_refuses
