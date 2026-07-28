#!/usr/bin/env bash
# Contract and synthetic event replay for the PR body compliance workflow.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

extract_signature_script() {
  awk '
    /^        run: \|$/ { capture=1; next }
    capture && /^          / { sub(/^          /, ""); print; next }
    capture { exit }
  ' "$WORKFLOW"
}

# Blank GH_TOKEN/GH_REPO explicitly: this replay judges the payload snapshot
# alone, and an ambient token in the caller's environment must not turn it into
# a live API read against a synthetic PR number.
signature_result() {
  local body=$1 script
  script=$(extract_signature_script)
  GH_TOKEN='' GH_REPO='' PR_NUMBER=418 PR_AUTHOR=synthetic-fork-contributor PR_BODY="$body" \
    bash -c "$script" >/dev/null 2>&1
}

# A stub `gh` standing in for the live-body read: it either prints the body the
# PR carries now, or exits non-zero to simulate an unreachable API.
make_gh_stub() {
  local dir=$1 mode=$2 live=${3:-}
  mkdir -p "$dir"
  printf '%s' "$live" >"$dir/live-body.txt"
  if [ "$mode" = unreachable ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/gh"
  else
    printf '#!/usr/bin/env bash\ncat %s/live-body.txt\n' "$dir" >"$dir/gh"
  fi
  chmod +x "$dir/gh"
}

signature_result_live() {
  local payload=$1 mode=$2 live=${3:-} dir script
  dir=$(fm_test_tmproot fm-nm-signature)
  make_gh_stub "$dir" "$mode" "$live"
  script=$(extract_signature_script)
  PATH="$dir:$PATH" GH_TOKEN=synthetic-token GH_REPO=kunchenguid/firstmate \
    PR_NUMBER=418 PR_AUTHOR=synthetic-fork-contributor PR_BODY="$payload" \
    bash -c "$script" >/dev/null 2>&1
}

render_group() {
  local action=$1 run_id=$2
  case "$action" in
    opened|edited) printf 'no-mistakes-required-418-%s\n' "$run_id" ;;
    synchronize|reopened) printf 'no-mistakes-required-418-head-change\n' ;;
  esac
}

render_run_name() {
  local action=$1 run_number=$2 run_id=$3
  printf 'PR #418 body compliance - %s - event %s (run %s)\n' "$action" "$run_number" "$run_id"
}

test_signature_sequence_at_fixed_head() {
  signature_result "Synthetic body\n$MARKER" || fail "signed opened event must succeed"
  if signature_result 'Synthetic unsigned edit'; then
    fail "unsigned edited event must fail"
  fi
  signature_result "Synthetic signed edit\n$MARKER" || fail "signed edited event must succeed"
  pass "fixed-head signed opened, unsigned edited, signed edited yields 0/1/0"
}

# Regression: no-mistakes pushes commits before it writes the '## Pipeline'
# section, so a head-change run that starts late replays a body snapshot taken
# before the signature existed. Head changes and body events sit in different
# concurrency groups, so that stale verdict is never superseded and a PR whose
# body is signed stays red. The verdict must follow the body the PR carries now.
test_live_body_outranks_the_payload_snapshot() {
  signature_result_live 'Unsigned snapshot from an earlier head change' signed "Signed later\n$MARKER" || \
    fail "a signed live body must clear a stale unsigned payload snapshot"
  if signature_result_live "Stale signed snapshot\n$MARKER" signed 'The signature is gone from the body'; then
    fail "an unsigned live body must fail even when the payload snapshot was signed"
  fi
  pass "the body the PR carries now decides, not the event payload snapshot"
}

test_unreachable_api_falls_back_to_the_snapshot() {
  signature_result_live "Signed snapshot\n$MARKER" unreachable || \
    fail "an unreachable API must fall back to the payload snapshot"
  if signature_result_live 'Unsigned snapshot' unreachable; then
    fail "an unreachable API must not pass an unsigned PR"
  fi
  pass "an unreachable API falls back to the snapshot and still refuses unsigned bodies"
}

test_live_body_read_contract() {
  assert_grep '  pull-requests: read' "$WORKFLOW" "workflow cannot read the live PR body"
  assert_grep 'GH_TOKEN: ${{ github.token }}' "$WORKFLOW" "live body read must use the job's own token"
  assert_grep 'repos/${GH_REPO}/pulls/${PR_NUMBER}' "$WORKFLOW" \
    "live body must be read from the PR the event names"
  pass "live body is read read-only from the event's own PR with the job token"
}

test_event_identity_contract() {
  local opened edited_one edited_two synchronize reopened
  opened=$(render_group opened 9001)
  edited_one=$(render_group edited 9002)
  edited_two=$(render_group edited 9003)
  synchronize=$(render_group synchronize 9004)
  reopened=$(render_group reopened 9005)
  [ "$opened" != "$edited_one" ] && [ "$opened" != "$edited_two" ] && [ "$edited_one" != "$edited_two" ] || \
    fail "body events must have distinct immutable groups"
  [ "$synchronize" = "$reopened" ] || fail "synchronize and reopened must share head-change"
  case "$opened $edited_one $edited_two" in *head-change*) fail "body event reused head-change" ;; esac

  assert_grep "group: no-mistakes-required-\${{ github.event.pull_request.number }}-\${{ (github.event.action == 'opened' || github.event.action == 'edited') && github.run_id || 'head-change' }}" "$WORKFLOW" \
    "workflow does not implement immutable body-event groups"
  assert_grep 'cancel-in-progress: true' "$WORKFLOW" "workflow lost cancellation for coalesced head changes"
  pass "body event groups are distinct while head changes remain coalesced"
}

test_run_names_are_ordered_and_unique() {
  local first second
  first=$(render_run_name edited 73 9002)
  second=$(render_run_name edited 74 9003)
  [ "$first" = 'PR #418 body compliance - edited - event 73 (run 9002)' ] || fail "first synthetic run name is incomplete"
  [ "$second" = 'PR #418 body compliance - edited - event 74 (run 9003)' ] || fail "second synthetic run name is incomplete"
  [ "$first" != "$second" ] || fail "distinct events must have unique run names"
  assert_grep 'run-name: "PR #${{ github.event.pull_request.number }} body compliance - ${{ github.event.action }} - event ${{ github.run_number }} (run ${{ github.run_id }})"' "$WORKFLOW" \
    "workflow run name does not expose PR, action, monotonic run number, and immutable run ID"
  pass "run names expose monotonic numbers and immutable IDs"
}

test_security_and_signature_contract_is_preserved() {
  assert_grep '  pull_request:' "$WORKFLOW" "workflow must use pull_request"
  assert_no_grep 'pull_request_target' "$WORKFLOW" "workflow must not use pull_request_target"
  assert_grep '  contents: read' "$WORKFLOW" "contents permission must remain read-only"
  assert_no_grep 'contents: write' "$WORKFLOW" "workflow must not gain contents write permission"
  assert_no_grep 'secrets.' "$WORKFLOW" "workflow must not read secrets"
  assert_no_grep 'actions/checkout' "$WORKFLOW" "workflow must not check out fork code"
  assert_grep 'name: PR must be raised via no-mistakes' "$WORKFLOW" "stable required check name changed"
  assert_grep "$MARKER" "$WORKFLOW" "signature marker changed"
  assert_grep "github.event.pull_request.user.login != 'github-actions[bot]'" "$WORKFLOW" "github-actions bot exemption changed"
  assert_grep "github.event.pull_request.user.login != 'dependabot[bot]'" "$WORKFLOW" "dependabot bot exemption changed"
  assert_no_grep 'release-please[bot]' "$WORKFLOW" "Firstmate must not exempt release-please"
  pass "fork, permission, check-name, marker, and bot-exemption contracts are preserved"
}

test_signature_sequence_at_fixed_head
test_live_body_outranks_the_payload_snapshot
test_unreachable_api_falls_back_to_the_snapshot
test_live_body_read_contract
test_event_identity_contract
test_run_names_are_ordered_and_unique
test_security_and_signature_contract_is_preserved
