#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_idle() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

write_fixture() {  # <home>
  local home=$1 fixture_gen
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  # A working ship task proves it through its own semantic busy-state record
  # (bin/fm-busy-lib.sh), which is what the snapshot's current-state read
  # consults; rendered pane text is no longer a state source.
  fixture_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-task busy --gen "$fixture_gen" \
    --source claude-hook --event user-prompt-submit
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    "window=firstmate:fm-secondmate-task" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks|length == 0)
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.orphan_in_flight | length) == 0
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| local | main | " "empty fleet view should still render the local station"
  assert_contains "$view" "No queued backlog records found." "empty fleet view should use explicit absence markers"
  assert_contains "$view" "| - | - | - | - | - | - | - | - | - |" \
    "empty fleet view should render an explicit placeholder child row"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,scout-task,secondmate-task,ship-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
test_hold_buckets_are_total_and_text_blind() {
  local home fakebin out
  home=$(make_home hold-buckets)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] working-held - Held while working (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z

## Queued
- [ ] blocked-hold - Blocked call blocked-by: upstream-work (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] dated-hold - Dated call (repo: sample) (kind: captain) (hold: revisit later) (hold-kind: captain) (hold-until: 2026-12-01)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] aged-hold - Aged call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-06-01T00:00:00Z
- [ ] live-hold - Live call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] opposite-word - Opposite wording (repo: sample) (kind: captain) (hold: non-deferred release choice) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] marker-prose - Marker prose (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
  SUPERSEDED - kept only to prove prose never classifies.
- [ ] upstream-work - Land the upstream change (repo: sample) (kind: ship)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data"     FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.structured and .hold_kind == "captain")]
    | length == 7
      and all(.hold_bucket as $bucket
              | ["live", "blocked", "dated", "aged"] | index($bucket) != null)
  ' >/dev/null || fail "every captain hold must land in exactly one structured bucket: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "blocked-hold")][0].hold_bucket == "blocked")
      and ([.backlog.records[] | select(.id == "dated-hold")][0].hold_bucket == "dated")
      and ([.backlog.records[] | select(.id == "aged-hold")][0].hold_bucket == "aged")
      and ([.backlog.records[] | select(.id == "live-hold")][0].hold_bucket == "live")
  ' >/dev/null || fail "structured fields did not drive the bucket assignment: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "opposite-word")][0]) as $opposite
    | ([.backlog.records[] | select(.id == "marker-prose")][0]) as $prose
    | $opposite.hold_bucket == "live" and $opposite.captain_actionable == true
      and $prose.hold_bucket == "live" and $prose.captain_actionable == true
  ' >/dev/null || fail "hold reason or body prose must never reclassify a live decision: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "working-held")][0])
    | .hold_bucket == "live" and .captain_actionable == true
  ' >/dev/null || fail "a captain hold on a working task must still be bucketed: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "upstream-work")][0].hold_bucket) == null
  ' >/dev/null || fail "a row that is not a captain hold must carry no bucket: $out"
  pass "captain-hold buckets are total, mutually exclusive, and never decided by prose"
}

test_main_inventory_orphan_and_unstructured_disclosure() {
  local home fakebin out
  home=$(make_home main-inventory)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
free-form current note
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
another free-form queued note
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: visible\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight == ["orphan-ship"])
      and ([.tasks[].id] == ["visible-ship"])
  ' >/dev/null || fail "main_inventory did not disclose orphan/unstructured: $out"
  # Counterfactual: add meta for the orphan and strip free-form current lines.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: orphan now live\n' > "$home/state/orphan-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
      and (.main_inventory.orphan_in_flight | length) == 0
      and (([.tasks[].id] | sort) == ["orphan-ship", "visible-ship"])
  ' >/dev/null || fail "main_inventory stayed invalid after meta + structured cleanup: $out"
  pass "main_inventory discloses orphan/unstructured and clears when inventory is consistent"
}

test_normalized_roles_and_plural_blocker_readiness() {
  local home fakebin out
  home=$(make_home normalized-records)
  mkdir -p "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] worker - Real worker (repo: alpha) (kind: ship)
- [ ] orphan - Ordinary missing worker (repo: alpha) (kind: ship)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/worker.meta" \
    "window=firstmate:fm-worker" "worktree=$home/projects/worker" "project=alpha" \
    "harness=codex" "kind=ship" "mode=ship"
  printf 'working: preparing canary\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.orphan_in_flight == ["orphan"]
      and (.backlog.records[] | select(.id == "program")
        | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "observation")
        | .current_role == "held" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "orphan")
        | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "captain-run")
        | .blocked_by == "review"
          and .blocked_by_ids == ["worker", "review"]
          and .unresolved_blocker_ids == ["worker", "review"]
          and .captain_actionable == false)
  ' >/dev/null || fail "normalized role or plural blocker fields were wrong: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/worker.meta" "$home/state/worker.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == ["review"]
      and .captain_actionable == false
  ' >/dev/null || fail "one completed blocker did not leave exactly one unresolved id: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == []
      and .captain_actionable == true
  ' >/dev/null || fail "completed blockers did not make the captain hold actionable: $out"

  sed 's/blocked-by: review/blocked-by: missing/' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by_ids == ["worker", "missing"]
      and .unresolved_blocker_ids == ["missing"]
      and .captain_actionable == false
  ' >/dev/null || fail "a missing blocker was incorrectly treated as resolved: $out"
  pass "backlog normalization preserves strict roles and resolves every blocker compatibly"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out hint_gen
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    "window=firstmate:fm-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-decision
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    "window=firstmate:fm-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-blocked
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    "window=firstmate:fm-stale-decision-ship-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-decision)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-decision busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    "window=firstmate:fm-stale-blocked-ship-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-blocked)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-blocked busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma
- [ ] sample-decision-route - Choose sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: captain route choice pending) (hold-kind: captain)
- [ ] dated-route - Deferred sample route (repo: sample) (kind: ship) (hold: captain sent this to later) (hold-kind: captain) (hold-until: 2026-09-01)
- [ ] captain-gated-work - Captain-gated ship work (repo: sample) (kind: ship) (hold: captain go pending) (hold-kind: captain)
- [ ] parked-prose - Parked captain call (repo: sample) (kind: ship) (hold: DEFERRED by captain) (hold-kind: captain)

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    "window=firstmate:fm-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" bold-task
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" \
    FM_SNAPSHOT_NOW=2026-07-14T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "sample-decision-route")
    | .title == "Choose sample route"
      and .repo == "sample"
      and .kind == "captain"
      and .hold_reason == "captain route choice pending"
      and .hold_kind == "captain"
      and .captain_actionable == true
  ' >/dev/null || fail "tasks-axi captain-hold metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "dated-route")
    | .title == "Deferred sample route"
      and .hold_until == "2026-09-01"
      and .captain_actionable == false
      and .hold_bucket == "dated"
  ' >/dev/null || fail "a dated captain hold did not defer or strip its hold-until from the title"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-gated-work")
    | .kind == "ship" and .captain_actionable == true and .hold_bucket == "live"
  ' >/dev/null || fail "captain actionability must not depend on the row kind"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parked-prose")
    | .captain_actionable == true and .hold_bucket == "live"
  ' >/dev/null || fail "hold prose must never classify a captain hold"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| local | alpha | bold-task | done | - | - | - | - | - |" \
    "view should render the bold in-flight child row from the snapshot"
  assert_contains "$view" "| blocked-reason | Blocked Reason | beta | ship | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | gamma | ship | - | https://github.com/kunchenguid/firstmate/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | delta | ship | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_undated_captain_hold_phrasing_and_aging() {
  local home fakebin out
  home=$(make_home undated-aging)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] parked-hold - Parked style call (repo: sample) (kind: ship) (hold: parked) (hold-kind: captain)
- [ ] awaiting-go - Awaiting go call (repo: sample) (kind: ship) (hold: awaiting captain go) (hold-kind: captain)
- [ ] no-dispatch - No dispatch call (repo: sample) (kind: ship) (hold: do not dispatch) (hold-kind: captain)
- [ ] no-auto - No auto-dispatch call (repo: sample) (kind: ship) (hold: do not auto-dispatch) (hold-kind: captain)
- [ ] not-urgent - Not urgent call (repo: sample) (kind: ship) (hold: not urgent) (hold-kind: captain)
- [ ] deprior - Deprioritized call (repo: sample) (kind: ship) (hold: de-prioritized) (hold-kind: captain)
- [ ] queued-opp - Queued opportunity call (repo: sample) (kind: ship) (hold: queued opportunity) (hold-kind: captain)
- [ ] gated-hold - Captain-gated phrasing (repo: sample) (kind: ship) (hold: captain-gated) (hold-kind: captain)
- [ ] aged-call - Aged genuine call (repo: sample) (kind: captain) (since 2026-07-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-01T00:00:00Z
- [ ] recent-call - Recent genuine call (repo: sample) (kind: captain) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] legacy-old-hold - Legacy unstamped hold (repo: sample) (kind: ship) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Historical notes remain ordinary task content.
  Captain hold set: 2026-07-24T00:00:00Z
- [ ] boundary-call - Almost aged genuine call (repo: sample) (kind: captain) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-11T00:01:00Z
- [ ] live-gated - Live captain-gated work (repo: sample) (kind: ship) (hold: captain go pending) (hold-kind: captain)
- [ ] unparked-call - Newly unparked decision (repo: sample) (kind: captain) (hold: unparked; choose a sample route) (hold-kind: captain)
- [ ] contextual-call - Context is not a deferral (repo: sample) (kind: captain) (hold: choose whether to pursue this queued opportunity) (hold-kind: captain)
  This is not urgent context, but the captain decision is current.
- [ ] contextual-not-urgent - Leading context is not a deferral (repo: sample) (kind: captain) (hold: not urgent but choose the route now) (hold-kind: captain)
- [ ] contextual-comma - Comma context is not a deferral (repo: sample) (kind: captain) (hold: not urgent, choose the launch route now) (hold-kind: captain)
- [ ] metadata-context - Metadata-like context is not a deferral (repo: sample) (kind: captain) (hold: not urgent, priority: decide P1 or P2) (hold-kind: captain)
- [ ] contextual-opportunity - Leading opportunity is not a deferral (repo: sample) (kind: captain) (hold: queued opportunity: choose whether to proceed) (hold-kind: captain)
- [ ] contextual-gated - Leading gate is not a deferral (repo: sample) (kind: captain) (hold: captain-gated decision needs current approval) (hold-kind: captain)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "parked-hold" or .id == "awaiting-go" or .id == "no-dispatch"
        or .id == "no-auto" or .id == "not-urgent" or .id == "deprior" or .id == "queued-opp"
        or .id == "gated-hold")]
     | all(.captain_actionable == true and .hold_bucket == "live"))
  ' >/dev/null || fail "parked-style wording must never classify a fresh undated hold: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "aged-call")
    | .captain_actionable == false
      and .hold_bucket == "aged"
      and .hold_age_days == 24
  ' >/dev/null || fail "an undated captain hold older than the default 14-day threshold must age: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "recent-call")][0]) as $recent
    | ([.backlog.records[] | select(.id == "legacy-old-hold")][0]) as $legacy
    | $recent.captain_actionable == true
      and $recent.hold_bucket == "live"
      and $recent.hold_age_days == 5
      and $legacy.captain_actionable == false
      and $legacy.hold_set == null
      and $legacy.hold_bucket == "aged"
      and $legacy.hold_age_days == 54
  ' >/dev/null || fail "recent stamped and legacy unstamped hold ages are wrong: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "boundary-call")
    | .hold_set == "2026-07-11T00:01:00Z"
      and .hold_age_days == 13 and .hold_bucket == "live"
  ' >/dev/null || fail "a hold one minute short of 14 days must not age early: $out"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.id == "live-gated" or .id == "unparked-call" or .id == "contextual-call"
        or .id == "contextual-not-urgent" or .id == "contextual-comma" or .id == "metadata-context"
        or .id == "contextual-opportunity" or .id == "contextual-gated")]
    | length == 8
      and all(.captain_actionable == true and .hold_bucket == "live")
      and (map(select(.id == "contextual-comma" and .hold_reason == "not urgent, choose the launch route now")) | length == 1)
      and (map(select(.id == "metadata-context" and .hold_reason == "not urgent, priority: decide P1 or P2")) | length == 1)
  ' >/dev/null || fail "contextual parked-style wording must not hide current decisions: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=30 "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "aged-call")
    | .hold_bucket == "live" and .hold_age_days == 24
  ' >/dev/null || fail "raising the age threshold must leave a 24-day hold unaged: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=5 "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "recent-call")
    | .hold_bucket == "aged" and .hold_age_days == 5
  ' >/dev/null || fail "lowering the age threshold to 5 must age a 5-day hold: $out"
  pass "undated captain holds age after a configurable threshold, decided only from structured fields"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "Generated: " "view must carry an observation timestamp"
  assert_contains "$view" "Schema: fm-fleet-snapshot.v1" "view must name the snapshot schema"
  assert_contains "$view" "| local | main | " "view must render the local home as a station"
  assert_contains "$view" "| local | secondmate-task | unknown (secondmate metadata is not registered) | present/alive |" \
    "a local secondmate without a registered ledger must still render as a station"
  assert_contains "$view" "| local | alpha | ship-task | working | - | - | - | https://github.com/kunchenguid/firstmate/pull/9 | - |" \
    "view must render child rows with state, model, PR and explicit - fallbacks"
  assert_contains "$view" "| local | alpha | cmux-task | unknown | - | - | - | - | - |" \
    "a child with no PR must render explicit - links, never a blank"
  assert_contains "$view" "| queued-task | Queued Task | alpha | ship | ship-task | - |" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | alpha | ship | - | https://github.com/kunchenguid/firstmate/pull/7 |" \
    "view should render done backlog row"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  pass "fleet view renders stations, child agents, links, and explicit fallbacks"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    "window=firstmate:fm-dead-secondmate" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| local | dead-secondmate | unknown (secondmate metadata is not registered) | present/dead |" \
    "view should distinguish a present secondmate endpoint from a dead agent"
  assert_contains "$view" "| - | - | - | - | - | - | - | - | - |" \
    "an empty fleet must render an explicit placeholder child row, never a blank table"
  pass "fleet view renders secondmate endpoint liveness and explicit empty state"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (fm-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/masked-decision.meta" \
    "window=firstmate:fm-masked-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_secondmate_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-secondmate)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/active-secondmate.meta" \
    "window=firstmate:fm-active-secondmate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-secondmate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-secondmate")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live secondmate endpoint must not clear an unrelated keyed decision: $out"
  pass "a live secondmate endpoint preserves unrelated open decisions"
}

# An open decision clears ONLY on an explicit resolution referencing its key, never
# on an unrelated terminal line.
test_open_decision_transfers_to_captain_hold() {
  local home fakebin out
  home=$(make_home captain-held-transfer)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/transferred-decision.meta" \
    "window=firstmate:fm-transferred-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=sample"
  printf 'needs-decision [key=route]: choose a sample route\n' > "$home/state/transferred-decision.status"
  printf 'captain-held [key=route]: tracked by transferred-decision-route\n' >> "$home/state/transferred-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "transferred-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "captain-held transfer must close only the duplicate status copy: $out"
  pass "durable captain-held transfer closes the duplicate live status decision"
}

test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/resolved-decision.meta" \
    "window=firstmate:fm-resolved-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: captain chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED scout report must never be read as a pending decision. A scout that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the captain - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the crew lifecycle; report prose never opens or reopens a decision.
test_completed_scout_report_is_pointer_not_pending() {
  local home fakebin out
  home=$(make_home completed-scout)
  mkdir -p "$home/projects/scout-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/scout-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" lavish-103
  # Stale needs-decision, then the scout finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a captain decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.scout_report_present == true
  ' >/dev/null || fail "a completed scout report must be a pointer, not a pending decision: $out"
  pass "a completed scout's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a scout still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided scout.
test_parked_scout_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-scout)
  mkdir -p "$home/projects/scout-wt2"
  fm_write_meta "$home/state/parked-scout.meta" \
    "window=firstmate:fm-parked-scout" \
    "worktree=$home/projects/scout-wt2" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" parked-scout
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-scout.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-scout")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a scout still parked at a decision must stay pending: $out"
  pass "a scout still parked at a decision stays pending (terminal clear does not over-fire)"
}

# Home-summary validity treats persistent secondmates as registered homes, not
# in-flight children. They have no backlog rows, so they must not produce
# unowned_current or terminal_in_flight. Ordinary crew/ship metas still do.
test_home_summary_excludes_secondmate_from_child_inventory() {
  local home fakebin out
  home=$(make_home summary-secondmate-only)
  mkdir -p "$home/secondmate-home" "$home/projects/unowned" "$home/projects/terminal"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'working: watching delegated scope\n' > "$home/state/mate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .schema == "fm-secondmate-home-summary.v1"
      and .valid == true
      and .reason == null
      and .invalidity == {kind:null,ids:[]}
      and (.invalidity.kind != "unowned_current")
      and (.invalidity.kind != "terminal_in_flight")
  ' >/dev/null || fail "secondmate-only home with a clean backlog must be VALID: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] mate - Registered secondmate home (repo: alpha) (kind: secondmate) (since 2026-07-11)

## Queued

## Done
EOF
  printf 'done: delegated scope complete\n' > "$home/state/mate.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == true
      and .reason == null
      and .invalidity == {kind:null,ids:[]}
      and (.invalidity.kind != "terminal_in_flight")
  ' >/dev/null || fail "terminal secondmate with a matching in-flight row must not produce terminal_in_flight: $out"

  fm_write_meta "$home/state/unowned-ship.meta" \
    "window=firstmate:fm-unowned-ship" \
    "worktree=$home/projects/unowned" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_idle "$home/state" unowned-ship
  printf 'needs-decision [key=unowned-ship]: choose a route\n' > "$home/state/unowned-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == false
      and .invalidity == {kind:"unowned_current",ids:["unowned-ship"]}
      and (.reason | contains("unowned-ship=parked"))
      and (.reason | contains("mate=") | not)
  ' >/dev/null || fail "ordinary unowned ship must still produce unowned_current without listing the secondmate: $out"

  rm -f "$home/state/unowned-ship.meta" "$home/state/unowned-ship.status"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] terminal-ship - Done child still in flight (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fm_write_meta "$home/state/terminal-ship.meta" \
    "window=firstmate:fm-terminal-ship" \
    "worktree=$home/projects/terminal" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_idle "$home/state" terminal-ship
  printf 'done: complete\n' > "$home/state/terminal-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == false
      and .invalidity == {kind:"terminal_in_flight",ids:["terminal-ship"]}
      and (.reason | contains("terminal-ship=done"))
      and (.reason | contains("mate=") | not)
  ' >/dev/null || fail "ordinary terminal in-flight ship must still produce terminal_in_flight without listing the secondmate: $out"
  pass "home-summary excludes kind=secondmate from unowned_current and terminal_in_flight"
}

write_remote_ledger_summary() {  # <home> <generated-epoch>
  local dest=$1
  mkdir -p "$dest/state"
  jq -n --arg home "$dest" --argjson epoch "$2" '{
    schema:"fm-secondmate-home-summary.v1",
    hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:"2026-09-01T22:00:00Z",generated_epoch:$epoch,home:$home,
    valid:true,reason:null,invalidity:{kind:null,ids:[]},state:"no_active_work",
    active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],
    counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[]
  }' > "$dest/state/home-summary.json"
}

# make_remote_ssh <dir>: a fake SSH transport that answers per host so one run
# can exercise every cross-home read outcome:
#   host-slow             - a live but slow home that consumes the per-home budget
#   host-fail             - a live read that produces nothing
#   host-bad              - a ledger that is not a valid summary
#   host-ok               - a healthy ledger at $FM_TEST_HEALTHY_LEDGER
#   host-probe-fetch-fail - probe answers alive immediately while the ledger
#                           fetch itself wedges past the per-home timeout, so
#                           fetch_one and probe_one race exactly as they do
#                           against a real busy-but-alive host
#   host-badreason        - a shape-valid ledger whose .reason is not a string
#                           at $FM_TEST_BADREASON_LEDGER
make_remote_ssh() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
case "${1:-}" in
  host-slow) sleep 30; exit 1 ;;
  host-fail) exit 1 ;;
  host-bad) printf 'this is not a valid summary\n'; exit 0 ;;
  host-ok) cat "${FM_TEST_HEALTHY_LEDGER:?}"; exit 0 ;;
  host-orphan) cat "${FM_TEST_ORPHAN_LEDGER:?}"; exit 0 ;;
  host-stuck) cat "${FM_TEST_STUCK_LEDGER:?}"; exit 0 ;;
  host-raw) cat "${FM_TEST_RAW_LEDGER:?}"; exit 0 ;;
  host-probe)
    # fm-on.sh ships the remote command as one trailing base64 argv blob
    # (fm-remote-entrypoint.sh <proto> <root> <home> <argv>); decode only that
    # blob, never the whole argv, so surrounding plaintext cannot corrupt it.
    last=""; for arg in "$@"; do last=$arg; done
    if printf '%s' "$last" | base64 -d 2>/dev/null | grep -q "fm-remote-secondmate-control"; then
      printf 'alive\n'; exit 0
    fi
    cat "${FM_TEST_HEALTHY_LEDGER:?}"; exit 0 ;;
  host-probe-fetch-fail)
    last=""; for arg in "$@"; do last=$arg; done
    if printf '%s' "$last" | base64 -d 2>/dev/null | grep -q "fm-remote-secondmate-control"; then
      printf 'alive\n'; exit 0
    fi
    sleep 30; exit 1 ;;
  host-badreason) cat "${FM_TEST_BADREASON_LEDGER:?}"; exit 0 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

# write_remote_ledger_invalid_summary <dest> <kind> <reason> <state> <epoch>:
# an invalid but shape-valid ledger with one readable child, so the view must
# render the specific reason beside the data instead of dropping the row.
write_remote_ledger_invalid_summary() {  # <dest> <kind> <reason> <state> <epoch>
  local dest=$1
  mkdir -p "$dest/state"
  jq -n --arg home "$dest" --arg kind "$2" --arg reason "$3" --arg state "$4" --argjson epoch "$5" '{
    schema:"fm-secondmate-home-summary.v1",
    hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:"2026-09-22T12:00:00Z",generated_epoch:$epoch,home:$home,
    valid:false,reason:$reason,invalidity:{kind:$kind,ids:["remote-ship"]},state:$state,
    active_children:[{id:"remote-ship",kind:"ship",state:"working",repo:"alpha",source:"run-step",doing:"fixing",
      usage:{harness:"pi",model:"m"}}],
    decisions_open:[],holds:[],queued:[],landed:[],
    endpoints:[{id:"remote-ship",state:"working",source:"run-step",endpoint:{exists:true,agent_alive:"alive"}}],
    counts:{active_children:1,decisions_open:0,holds:0,queued:0,landed:0,endpoints:1},omitted:[]
  }' > "$dest/state/home-summary.json"
}

# write_remote_ledger_malformed_reason <dest> <epoch>: an otherwise shape-valid
# invalid ledger whose .reason is a number instead of a string, simulating a
# malformed remote producer rather than the empty/missing cases above.
write_remote_ledger_malformed_reason() {  # <dest> <epoch>
  local dest=$1
  mkdir -p "$dest/state"
  jq -n --arg home "$dest" --argjson epoch "$2" '{
    schema:"fm-secondmate-home-summary.v1",
    hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:"2026-09-22T12:00:00Z",generated_epoch:$epoch,home:$home,
    valid:false,reason:123,invalidity:{kind:"orphan_in_flight",ids:["remote-ship"]},state:"unknown",
    active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],
    counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[]
  }' > "$dest/state/home-summary.json"
}

# register_remote_secondmate <home> <id> <host> <remote-home>: record a remote
# home in the registry and its local metadata.
register_remote_secondmate() {  # <home> <id> <host> <remote-home>
  local home=$1 id=$2 host=$3 remote=$4
  mkdir -p "$remote/state"
  printf -- '- %s - fixture (host: %s; root: /remote/root; home: %s; scope: fixture; projects: sample; added 2026-09-01)\n' \
    "$id" "$host" "$remote" >> "$home/data/secondmates.md"
  fm_write_meta "$home/state/$id.meta" \
    "kind=secondmate" "mode=secondmate" "harness=pi" \
    "remote_host=$host" "remote_root=/remote/root" "home=$remote"
}

# remote_ledger_cache_path <home> <id> <host> <remote-home>: the exact cache path
# fm-fleet-snapshot.sh computes for one remote route.
remote_ledger_cache_path() {  # <home> <id> <host> <remote-home>
  local home=$1 id=$2 host=$3 remote=$4 key
  key=$(printf '%s\n%s\n%s\n' "$id" "$host" "$remote" | shasum -a 256 | awk '{print $1}')
  printf '%s/state/secondmate-summary-cache/%s.json\n' "$home" "$key"
}

test_view_reports_timed_out_secondmate_home_distinctly() {
  local home fb slow_home ok_home view
  home=$(make_home view-timeout)
  slow_home="$TMP_ROOT/view-timeout-slow"
  ok_home="$TMP_ROOT/view-timeout-ok"
  write_remote_ledger_summary "$ok_home" 1000
  register_remote_secondmate "$home" ledger-slow host-slow "$slow_home"
  register_remote_secondmate "$home" ledger-ok host-ok "$ok_home"
  fb=$(make_remote_ssh "$home")
  view=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_TEST_HEALTHY_LEDGER="$ok_home/state/home-summary.json" \
    FM_SNAPSHOT_SECONDMATE_TIMEOUT=2 "$VIEW")
  assert_contains "$view" "| host-slow | ledger-slow | timeout (" \
    "a timed-out remote home must render timeout, not unknown: $view"
  assert_contains "$view" "no valid cached copy" \
    "a timeout must name the missing cached copy: $view"
  assert_contains "$view" "| host-ok | ledger-ok | no_active_work |" \
    "a healthy remote home must be unaffected by another home's timeout: $view"
  assert_not_contains "$view" "| host-ok | ledger-ok | timeout" \
    "one home's timeout must never be attributed to another home: $view"
  pass "fleet view distinguishes a timed-out remote home from unknown"
}

test_view_reports_stale_cached_remote_home() {
  local home stale_home fb cache view
  home=$(make_home view-stale)
  stale_home="$TMP_ROOT/view-stale-home"
  register_remote_secondmate "$home" ledger-stale host-fail "$stale_home"
  write_remote_ledger_summary "$stale_home" 1000
  cache=$(remote_ledger_cache_path "$home" ledger-stale host-fail "$stale_home")
  mkdir -p "$(dirname "$cache")"
  chmod 700 "$(dirname "$cache")"
  cp "$stale_home/state/home-summary.json" "$cache"
  chmod 600 "$cache"
  fb=$(make_remote_ssh "$home")
  view=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_TEST_HEALTHY_LEDGER="$stale_home/state/home-summary.json" "$VIEW")
  assert_contains "$view" "| host-fail | ledger-stale | no_active_work |" \
    "a failed live read with a valid cached copy must render the cached state: $view"
  assert_contains "$view" "remote-ledger-cache/stale" \
    "a days-old cached read must disclose its source and its staleness, never render as current: $view"
  assert_contains "$view" "| host-fail | ledger-stale | no_active_work |" \
    "a stale cached home must never render blank: $view"
  pass "fleet view renders a stale cached remote home from its cached ledger"
}

test_view_reports_invalid_remote_ledger_loudly() {
  local home bad_home fb view
  home=$(make_home view-invalid)
  bad_home="$TMP_ROOT/view-invalid-home"
  register_remote_secondmate "$home" ledger-bad host-bad "$bad_home"
  fb=$(make_remote_ssh "$home")
  view=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_TEST_HEALTHY_LEDGER="$bad_home/state/home-summary.json" "$VIEW")
  assert_contains "$view" "| host-bad | ledger-bad | unknown (" \
    "an invalid ledger with no cache must render an explicit unknown, not blank: $view"
  assert_contains "$view" "missing, unreadable, or invalid" \
    "an invalid ledger must name the invalidity: $view"
  assert_not_contains "$view" "| host-bad | ledger-bad | timeout" \
    "an invalid ledger is not a timeout: $view"
  assert_not_contains "$view" "| host-bad | ledger-bad | - |" \
    "an invalid ledger must never render as an absent row: $view"
  pass "fleet view reports an invalid remote ledger with an explicit reason"
}

test_view_renders_invalid_remote_homes_nonfatally() {
  local home fb view snap now
  home=$(make_home view-invalid-kind)
  now=$(date +%s)
  write_remote_ledger_invalid_summary "$TMP_ROOT/view-orphan-home" \
    orphan_in_flight "in-flight backlog item has no child metadata: remote-ship" unknown "$now"
  write_remote_ledger_invalid_summary "$TMP_ROOT/view-stuck-home" \
    child_current_unavailable "child current state unavailable: remote-ship" unknown "$now"
  write_remote_ledger_invalid_summary "$TMP_ROOT/view-raw-home" \
    unstructured_current "unstructured current backlog row" active_child_work "$now"
  register_remote_secondmate "$home" ledger-orphan host-orphan "$TMP_ROOT/view-orphan-home"
  register_remote_secondmate "$home" ledger-stuck host-stuck "$TMP_ROOT/view-stuck-home"
  register_remote_secondmate "$home" ledger-raw host-raw "$TMP_ROOT/view-raw-home"
  fb=$(make_remote_ssh "$home")
  view=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_TEST_ORPHAN_LEDGER="$TMP_ROOT/view-orphan-home/state/home-summary.json" \
    FM_TEST_STUCK_LEDGER="$TMP_ROOT/view-stuck-home/state/home-summary.json" \
    FM_TEST_RAW_LEDGER="$TMP_ROOT/view-raw-home/state/home-summary.json" "$VIEW")
  assert_contains "$view" "structured home state invalid: in-flight backlog item has no child metadata: remote-ship" \
    "an orphan in-flight home must name its specific reason: $view"
  assert_contains "$view" "structured home state invalid: child current state unavailable: remote-ship" \
    "a child-unavailable home must name its specific reason: $view"
  assert_contains "$view" "structured home state invalid: unstructured current backlog row" \
    "an unstructured-row home must name its specific reason: $view"
  assert_contains "$view" "| host-orphan | alpha | remote-ship | working |" \
    "an invalid home must still render every readable child: $view"
  assert_contains "$view" "| host-stuck | alpha | remote-ship | working |" \
    "a child-unavailable home must still render every readable child: $view"
  assert_contains "$view" "| host-raw | alpha | remote-ship | working |" \
    "an unstructured-row home must still render every readable child: $view"
  snap=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_TEST_ORPHAN_LEDGER="$TMP_ROOT/view-orphan-home/state/home-summary.json" \
    FM_TEST_STUCK_LEDGER="$TMP_ROOT/view-stuck-home/state/home-summary.json" \
    FM_TEST_RAW_LEDGER="$TMP_ROOT/view-raw-home/state/home-summary.json" "$SNAPSHOT" --json)
  printf '%s' "$snap" | jq -e '
    ([.secondmate_current.records[]
      | select(.id == "ledger-orphan" or .id == "ledger-stuck" or .id == "ledger-raw")
      | select(.provenance.trust == "partial-structured"
        and (.active_children | length) == 1
        and (.current.reason | contains("structured home state invalid: ")))] | length) == 3
  ' >/dev/null || fail "every invalid home must stay partial-structured with its child and specific reason: $snap"
  pass "fleet view renders every invalidity kind non-fatally with its specific reason"
}

test_view_reports_per_home_timeout_distinctly() {
  local home fb view
  home=$(make_home view-host-timeout)
  write_remote_ledger_summary "$TMP_ROOT/view-host-timeout-ok" "$(date +%s)"
  register_remote_secondmate "$home" ledger-slow-home host-slow "$TMP_ROOT/view-host-timeout-slow"
  register_remote_secondmate "$home" ledger-fast host-ok "$TMP_ROOT/view-host-timeout-ok"
  fb=$(make_remote_ssh "$home")
  view=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_TEST_HEALTHY_LEDGER="$TMP_ROOT/view-host-timeout-ok/state/home-summary.json" \
    FM_SNAPSHOT_SECONDMATE_HOST_TIMEOUT=2 FM_SNAPSHOT_SECONDMATE_TIMEOUT=60 "$VIEW")
  assert_contains "$view" "| host-slow | ledger-slow-home | timeout (" \
    "a home wedged past its own allowance must render timeout, not unknown: $view"
  assert_contains "$view" "timed out after 2s" \
    "a per-home timeout must name its own allowance: $view"
  assert_contains "$view" "| host-ok | ledger-fast | no_active_work |" \
    "a healthy home must be unaffected by another home's per-home timeout: $view"
  pass "fleet view reports a per-home timeout distinctly from the collection backstop"
}

test_view_marks_stale_remote_ledger() {
  local home fb view
  home=$(make_home view-stale-fresh)
  write_remote_ledger_summary "$TMP_ROOT/view-stale-fresh-home" 1000
  register_remote_secondmate "$home" ledger-old host-ok "$TMP_ROOT/view-stale-fresh-home"
  fb=$(make_remote_ssh "$home")
  view=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_TEST_HEALTHY_LEDGER="$TMP_ROOT/view-stale-fresh-home/state/home-summary.json" "$VIEW")
  assert_contains "$view" "| host-ok | ledger-old | no_active_work |" \
    "a stale but valid ledger must still render its state: $view"
  assert_contains "$view" "remote-ledger/stale " \
    "a days-old ledger must never render as fresh: $view"
  assert_not_contains "$view" "remote-ledger/fresh " \
    "a days-old ledger must not claim freshness: $view"
  pass "fleet view marks a stale remote ledger stale instead of fresh"
}

test_view_prefers_live_probe_endpoint() {
  local home fb view
  home=$(make_home view-probe)
  write_remote_ledger_summary "$TMP_ROOT/view-probe-home" "$(date +%s)"
  register_remote_secondmate "$home" ledger-probe host-probe "$TMP_ROOT/view-probe-home"
  register_remote_secondmate "$home" ledger-noprobe host-ok "$TMP_ROOT/view-probe-home"
  fb=$(make_remote_ssh "$home")
  view=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_TEST_HEALTHY_LEDGER="$TMP_ROOT/view-probe-home/state/home-summary.json" "$VIEW")
  assert_contains "$view" "| host-probe | ledger-probe | no_active_work | present/alive |" \
    "a reachable home must show its live probed endpoint, not unknown: $view"
  assert_contains "$view" "| host-ok | ledger-noprobe | no_active_work | unknown/unknown |" \
    "without probe evidence the endpoint must stay honestly unknown: $view"
  pass "fleet view prefers the live mate-endpoint probe over unknown"
}

test_view_prefers_probe_over_timed_out_fetch() {
  local home fb view row
  home=$(make_home view-probe-race)
  register_remote_secondmate "$home" ledger-probe-race host-probe-fetch-fail "$TMP_ROOT/view-probe-race-home"
  fb=$(make_remote_ssh "$home")
  view=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_SNAPSHOT_SECONDMATE_HOST_TIMEOUT=2 FM_SNAPSHOT_SECONDMATE_TIMEOUT=60 "$VIEW")
  row=$(printf '%s\n' "$view" | grep '| host-probe-fetch-fail |')
  [ -n "$row" ] || fail "host-probe-fetch-fail must render its own row: $view"
  assert_contains "$row" "| timeout (" \
    "a home whose ledger fetch times out must still render timeout, not unknown: $row"
  assert_contains "$row" "timed out after 2s" \
    "the timeout reason must still name its own allowance: $row"
  assert_contains "$row" "| present/alive |" \
    "a probe that answers alive while the fetch times out must win over unknown, not be dropped: $row"
  pass "fleet view keeps the live probe result when its own home's ledger fetch times out"
}

test_snapshot_degrades_nonfatally_on_malformed_reason_type() {
  local home fb ok_home bad_home snap rc
  home=$(make_home snapshot-badreason)
  ok_home="$TMP_ROOT/snapshot-badreason-ok"
  bad_home="$TMP_ROOT/snapshot-badreason-bad"
  write_remote_ledger_summary "$ok_home" "$(date +%s)"
  write_remote_ledger_malformed_reason "$bad_home" "$(date +%s)"
  register_remote_secondmate "$home" ledger-ok host-ok "$ok_home"
  register_remote_secondmate "$home" ledger-badreason host-badreason "$bad_home"
  fb=$(make_remote_ssh "$home")
  snap=$(PATH="$fb:$PATH" FM_HOME="$home" \
    FM_SSH_BIN="$fb/fake-ssh" \
    FM_TEST_HEALTHY_LEDGER="$ok_home/state/home-summary.json" \
    FM_TEST_BADREASON_LEDGER="$bad_home/state/home-summary.json" \
    "$SNAPSHOT" --json)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a remote ledger with a non-string .reason must not crash the whole snapshot: rc=$rc out=$snap"
  printf '%s' "$snap" | jq -e '
    (.secondmate_current.records[] | select(.id == "ledger-ok") | .current.state) == "no_active_work"
  ' >/dev/null || fail "a malformed sibling ledger must never take down an unrelated healthy home: $snap"
  printf '%s' "$snap" | jq -e '
    (.secondmate_current.records[] | select(.id == "ledger-badreason") | .current.reason
      | contains("missing, unreadable, or invalid"))
  ' >/dev/null || fail "a non-string .reason must degrade to the generic invalid-ledger reason, not crash: $snap"
  pass "snapshot degrades a malformed remote reason type non-fatally instead of crashing"
}

test_view_reads_release_manifest_seam() {
  local home alt view
  home=$(make_home view-manifest)
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "## Release Manifest" "view must always render the manifest seam"
  assert_contains "$view" "(not present)" "an absent manifest must be stated explicitly, never blank"
  jq -n '{schema:"release-manifest.v1",generated:"2026-09-14T00:00:00Z",stations:[{id:"a"}]}' \
    > "$home/data/fleet-release-manifest.json"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "Schema: release-manifest.v1" "a present manifest must disclose its own schema"
  assert_contains "$view" "Generated: 2026-09-14T00:00:00Z" "a present manifest must disclose its stamp"
  assert_contains "$view" "Top-level entries: 3" "a present manifest must be consumed generically"
  alt="$home/data/other-manifest.json"
  jq -n '{schema:"other.v1",generated:"2025-01-01T00:00:00Z"}' > "$alt"
  view=$(FM_HOME="$home" "$VIEW" --release-manifest "$alt")
  assert_contains "$view" "Schema: other.v1" "the --release-manifest override must select the named file"
  assert_not_contains "$view" "Schema: release-manifest.v1" "the override must not read the default path"
  pass "view consumes an optional release manifest through a documented, schema-agnostic seam"
}

test_empty_fleet_json
test_fixture_snapshot_json
test_home_summary_excludes_secondmate_from_child_inventory
test_undated_captain_hold_phrasing_and_aging
test_hold_buckets_are_total_and_text_blind
test_main_inventory_orphan_and_unstructured_disclosure
test_normalized_roles_and_plural_blocker_readiness
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_secondmate_open_decision_survives_live_endpoint
test_open_decision_transfers_to_captain_hold
test_open_decision_clears_on_keyed_resolution
test_completed_scout_report_is_pointer_not_pending
test_parked_scout_decision_stays_pending
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_view_renders_snapshot
test_view_renders_dead_secondmate_agent_status
test_view_reports_timed_out_secondmate_home_distinctly
test_view_reports_stale_cached_remote_home
test_view_reports_invalid_remote_ledger_loudly
test_view_renders_invalid_remote_homes_nonfatally
test_view_reports_per_home_timeout_distinctly
test_view_marks_stale_remote_ledger
test_view_prefers_live_probe_endpoint
test_view_prefers_probe_over_timed_out_fetch
test_snapshot_degrades_nonfatally_on_malformed_reason_type
test_view_reads_release_manifest_seam
