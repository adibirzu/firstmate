#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

DIRECT_PR_VALID='## Code Review (Stage 1)

# Code Review Verdict

**Stage 1: Deterministic Review (zero LLM tokens)**

- Files reviewable: 2 / 2
- Changes: +50 / -5 (55 lines)
- Linter: ran, 0 finding(s)
- LLM tokens: 0

No escalation: Stage 1 alone gates this change.

## Independent Second-Level Review

Reviewer: crewmate delegate review (host-agent lane)
Report: data/fm-ci-review-attestation-check/report.md'

run_attestation() {
  printf '%s' "$1" | "$ROOT/bin/fm-direct-pr-attestation.sh" 2>&1
}

test_direct_pr_valid_attestation_passes() {
  local output rc
  rc=0
  output=$(run_attestation "$DIRECT_PR_VALID") || rc=$?
  expect_code 0 "$rc" "validator rejected a valid two-stage attestation body"
  pass "direct-PR validator accepts a valid Stage 1 verdict plus named second-level review"
}

test_direct_pr_empty_body_fails() {
  local output rc
  rc=0
  output=$(run_attestation "") || rc=$?
  [ "$rc" -ne 0 ] || fail "validator accepted an empty PR body"
  assert_contains "$output" "empty" \
    "empty-body failure did not explain the body is empty"
  pass "direct-PR validator rejects an empty PR body"
}

test_direct_pr_placeholder_reviewer_fails() {
  local body output rc
  body='## Code Review (Stage 1)

# Code Review Verdict

**Stage 1: Deterministic Review (zero LLM tokens)**

- Files reviewable: 2 / 2
- Changes: +50 / -5 (55 lines)

## Independent Second-Level Review

Reviewer: TBD
Report: data/fm-ci-review-attestation-check/report.md'
  rc=0
  output=$(run_attestation "$body") || rc=$?
  [ "$rc" -ne 0 ] || fail "validator accepted a placeholder second-level reviewer"
  assert_contains "$output" "Reviewer" \
    "placeholder-reviewer failure did not name the Reviewer field"
  pass "direct-PR validator rejects a placeholder second-level reviewer"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_direct_pr_valid_attestation_passes
test_direct_pr_empty_body_fails
test_direct_pr_placeholder_reviewer_fails
