#!/usr/bin/env bash
# fm-spawn.sh --relaunch: the recorded endpoint's IDENTITY, not just its handle.
#
# A relaunch ADOPTS the endpoint the task already runs in rather than creating a
# new one, so it skips the creation path that is the only assigner of the
# backend-specific endpoint ids (herdr_session / herdr_workspace_id /
# herdr_tab_id / herdr_pane_id, and the zellij and cmux equivalents).
# Those ids are also keys this spawn REWRITES, so a relaunch that does not read
# them back from the record cannot republish them - which is what
# bin/fm-teardown.sh later matches the task against to close the endpoint down.
#
# This suite pins the refusal half hermetically, through the executable
# interface: a herdr record that cannot name its own endpoint must be refused
# while the task is still whole, naming the exact keys that are missing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-relaunch-endpoint)

# A `herdr` stub covering exactly the calls this path makes: the version/status
# probe bin/fm-spawn.sh's backend validation runs, and the `pane get` + `agent
# get` pair the endpoint-state check reads. The recorded pane exists and has no
# agent registered - `agent get` answers agent_not_found, the real herdr answer
# for such a pane, which the adapter maps to the agent-free state a relaunch
# requires.
make_herdr_stub() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.1","channel":"stable","protocol":14},"server":{"running":true}}\n' ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "${3:-}" ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# new_herdr_case <name> <id> <extra-meta-line>... -> echoes the case dir.
# The record always carries the window= handle (so the adoption path is the one
# taken); the caller decides which endpoint-identity keys accompany it.
new_herdr_case() {
  local name=$1 id=$2 dir
  shift 2
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/home/config"
  fm_git_worktree "$dir/proj" "$dir/wt" "fm/$id"
  printf 'brief\n' > "$dir/home/data/$id/brief.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=default:w1:p2" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=herdr" \
    "$@"
  make_herdr_stub "$dir" >/dev/null
  printf '%s\n' "$dir"
}

run_relaunch() {  # <case-dir> <id>
  local dir=$1 id=$2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" --relaunch --harness claude 2>&1
}

test_incomplete_herdr_endpoint_identity_is_refused() {
  local dir out rc before
  dir=$(new_herdr_case incomplete he1 "herdr_session=default" "herdr_workspace_id=w1")
  before=$(cat "$dir/home/state/he1.meta")
  out=$(run_relaunch "$dir" he1); rc=$?
  expect_code 1 "$rc" "a herdr record missing endpoint ids should refuse the relaunch"
  assert_contains "$out" "herdr endpoint identity" \
    "the refusal should name the endpoint identity a relaunch must adopt"
  assert_contains "$out" "herdr_tab_id" "the refusal should name the missing tab id"
  assert_contains "$out" "herdr_pane_id" "the refusal should name the missing pane id"
  case "$out" in
    *"unbound variable"*)
      fail "the relaunch aborted on an unbound endpoint variable instead of refusing on the record" ;;
  esac
  [ "$before" = "$(cat "$dir/home/state/he1.meta")" ] \
    || fail "a refused relaunch must leave the record byte-identical"
  pass "fm-spawn --relaunch: a herdr record that cannot name its own endpoint is refused, record untouched"
}

test_complete_herdr_endpoint_identity_passes_the_adoption_gate() {
  local dir out
  dir=$(new_herdr_case complete he2 \
    "herdr_session=default" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2")
  out=$(run_relaunch "$dir" he2) || true
  # This stub cannot carry a launch through to a running agent, so the spawn
  # still fails further along. What is pinned here is that a COMPLETE record
  # clears the adoption gate rather than being refused for missing identity or
  # aborting on an unbound endpoint variable - the two failures a relaunch that
  # never reads those keys back produces.
  case "$out" in
    *"herdr endpoint identity"*)
      fail "a complete herdr record was refused for missing endpoint identity: $out" ;;
    *"unbound variable"*)
      fail "a complete herdr record aborted on an unbound endpoint variable: $out" ;;
  esac
  pass "fm-spawn --relaunch: a complete herdr record clears the endpoint-adoption gate"
}

test_incomplete_herdr_endpoint_identity_is_refused
test_complete_herdr_endpoint_identity_passes_the_adoption_gate
echo "ALL PASS: fm-spawn-relaunch-endpoint"
