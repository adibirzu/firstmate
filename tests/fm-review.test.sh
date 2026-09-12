#!/usr/bin/env bash
# tests/fm-review.test.sh - unit tests for the deterministic-first code review
# wrapper (bin/fm-review.sh). Fakes `ocr` and `gh` so no LLM/network call and
# no real `ocr` install are required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# A curated PATH that resolves every real tool (bash, jq, git, gh, ...) except
# `ocr`, so the "missing required tool" case does not depend on this host
# happening to lack ocr, and does not accidentally hide jq/git/bash too.
NO_OCR_PATH=$(fm_test_base_path_sans "$PATH" ocr)

# fake_ocr writes a fake `ocr` into FAKEBIN whose `delegate preview` reports
# $1 insertions, $2 deletions, and $3 (space-separated, single-quoted) reviewable
# file paths; its `delegate rule` echoes back the files it was given as one rule
# group; its `review` exits 0 with a canned success verdict unless
# OCR_FAKE_REVIEW_EXIT is set to a nonzero code, in which case it prints a
# failure line on stderr and exits with that code. Every invocation appends its
# argv to $TMP_ROOT/ocr.log for assertions.
fake_ocr() {
  local insertions=$1 deletions=$2 files=$3
  cat > "$FAKEBIN/ocr" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$TMP_ROOT/ocr.log"
case "\${1:-}" in
  delegate)
    case "\${2:-}" in
      preview)
        files_json=\$(printf '%s\n' $files | jq -R . | jq -s '[.[] | select(length > 0)]')
        jq -n --argjson files "\$files_json" --arg ins "$insertions" --arg del "$deletions" \\
          '{schema_version:"1", mode:"range", total_files: (\$files | length), reviewable_count: (\$files | length), total_insertions: (\$ins | tonumber), total_deletions: (\$del | tonumber), reviewable_files: [\$files[] | {path: ., status: "modified", insertions: 1, deletions: 0}], excluded_files: []}'
        ;;
      rule)
        shift 2
        rule_files=()
        while [[ \$# -gt 0 ]]; do
          case "\$1" in
            --format|--repo) shift 2 ;;
            *) rule_files+=("\$1"); shift ;;
          esac
        done
        printf '%s\n' "\${rule_files[@]}" | jq -R . | jq -s '{schema_version:"1", groups: [{group_id:1, source:"system", pattern:"default", files: ., rule:"fake rule text"}]}'
        ;;
    esac
    ;;
  review)
    if [[ -n "\${OCR_FAKE_REVIEW_EXIT:-}" && "\${OCR_FAKE_REVIEW_EXIT}" != "0" ]]; then
      echo "fake ocr review: simulated provider failure" >&2
      exit "\${OCR_FAKE_REVIEW_EXIT}"
    fi
    echo '{"status":"passed","summary":{"files_reviewed":1,"comments":0,"total_tokens":42}}'
    ;;
esac
EOF
  chmod +x "$FAKEBIN/ocr"
}

fake_gh_pr_view() {
  local base_ref=$1
  cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
set -u
if [[ "\${1:-}" == pr && "\${2:-}" == view ]]; then
  echo "$base_ref"
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
}

run_review() {
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-review.sh" "$@"
}

# --- usage / missing-tool guards --------------------------------------------

OUT=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-review.sh" --help 2>&1)
assert_contains "$OUT" "Usage:" "help output must show Usage:"
assert_contains "$OUT" "worktree" "help output must mention worktree mode"
assert_contains "$OUT" "pr <PR_URL>" "help output must mention pr mode"
pass "fm-review.sh --help prints usage for both modes"

OUT=$(PATH="$NO_OCR_PATH" "$ROOT/bin/fm-review.sh" worktree --from a --to b 2>&1) && fail "must fail with ocr missing from PATH"
assert_contains "$OUT" "required tool 'ocr'" "must name the missing required tool"
pass "fm-review.sh refuses to run when a required tool is missing from PATH"

OUT=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-review.sh" bogus-mode 2>&1) && fail "must reject an unknown mode"
assert_contains "$OUT" "unknown mode" "must name the rejected mode"
pass "fm-review.sh rejects a mode that is neither worktree nor pr"

# --- Stage 1 only, no escalation ---------------------------------------------

fake_ocr 50 5 "'src/a.py' 'src/b.py'"
OUT=$(run_review worktree --dir "$TMP_ROOT" --from base --to head)
assert_contains "$OUT" "Stage 1: Deterministic Review" "verdict must show the Stage 1 heading"
assert_contains "$OUT" "+50 / -5 (55 lines)" "verdict must report the changeset size"
assert_contains "$OUT" "No escalation" "a small changeset must not escalate"
grep -Eq '^review ' "$TMP_ROOT/ocr.log" && fail "ocr review must never be called when Stage 1 does not escalate"
pass "a small changeset with no risk files stays on Stage 1 only, and never calls ocr review"

# --- size-threshold escalation (delegate mode, the default) -----------------

fake_ocr 2000 0 "'big.py'"
OUT=$(run_review worktree --dir "$TMP_ROOT" --from base --to head); CODE=$?
[ "$CODE" = 2 ] || fail "size-threshold escalation in delegate mode must exit 2, got $CODE"
assert_contains "$OUT" "Stage 2: Escalated" "verdict must show the Stage 2 heading"
assert_contains "$OUT" "exceeds threshold" "escalation reason must name the threshold"
assert_contains "$OUT" "No LLM call made" "delegate mode must state no LLM call was made"
pass "a changeset over the size threshold escalates to Stage 2 delegate mode and exits 2"

OUT=$(FM_REVIEW_SIZE_THRESHOLD=5000 run_review worktree --dir "$TMP_ROOT" --from base --to head)
assert_contains "$OUT" "No escalation" "a raised threshold must suppress escalation"
pass "FM_REVIEW_SIZE_THRESHOLD overrides the default 1000-line threshold"

OUT=$(run_review worktree --dir "$TMP_ROOT" --from base --to head --stage1-only); CODE=$?
[ "$CODE" = 0 ] || fail "--stage1-only must never escalate, got exit $CODE"
assert_contains "$OUT" "No escalation" "--stage1-only must suppress escalation"
pass "--stage1-only suppresses escalation even over the size threshold"

# --- risk-pattern escalation via config/code-review --------------------------

mkdir -p "$TMP_ROOT/config"
cat > "$TMP_ROOT/config/code-review" <<'JSON'
{"riskPatterns": ["auth/*.py"]}
JSON
fake_ocr 10 0 "'auth/login.py'"
OUT=$(run_review worktree --dir "$TMP_ROOT" --from base --to head); CODE=$?
[ "$CODE" = 2 ] || fail "risk-pattern match must escalate and exit 2, got $CODE"
assert_contains "$OUT" "high-risk file(s) matched: auth/login.py" "escalation reason must name the matched file"
pass "config/code-review riskPatterns force Stage 2 even under the size threshold"
rm -f "$TMP_ROOT/config/code-review"

# --- linter integration -------------------------------------------------------

mkdir -p "$TMP_ROOT/bin"
LINT_ARGS_LOG="$TMP_ROOT/lint-args.log"
cat > "$TMP_ROOT/bin/fm-lint.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$LINT_ARGS_LOG"
echo "fake-lint: 1 problem found"
exit 1
SH
chmod +x "$TMP_ROOT/bin/fm-lint.sh"

# Two reviewable files: one in fm-lint.sh's canonical set (bin/*.sh), one not.
# The linter must run scoped to exactly the canonical one, never bare (a bare
# call would let fm-lint.sh's own merge-base auto-detection diverge from the
# range fm-review.sh was asked to review).
fake_ocr 10 0 "'bin/x.sh' 'src/other.py'"
OUT=$(run_review worktree --dir "$TMP_ROOT" --from base --to head); CODE=$?
[ "$CODE" = 2 ] || fail "linter findings must escalate to Stage 2 (delegate default), got $CODE"
assert_contains "$OUT" "linter reported findings" "escalation reason must name the linter"
assert_contains "$OUT" "fake-lint: 1 problem found" "verdict must include the linter's own output"
LINT_ARGS=$(cat "$LINT_ARGS_LOG")
[ "$LINT_ARGS" = "bin/x.sh" ] || fail "fm-lint.sh must be invoked with exactly the OCR-selected canonical file(s), got: $LINT_ARGS"
pass "a repo-configured linter's findings escalate to Stage 2 and are printed in the verdict, scoped to the OCR-selected canonical files"

OUT=$(run_review worktree --dir "$TMP_ROOT" --from base --to head --stage1-only); CODE=$?
[ "$CODE" = 1 ] || fail "--stage1-only with real lint findings must still exit 1, got $CODE"
pass "--stage1-only still reports lint findings via exit 1 without escalating to Stage 2"

: > "$LINT_ARGS_LOG"
fake_ocr 10 0 "'src/only.py'"
OUT=$(run_review worktree --dir "$TMP_ROOT" --from base --to head); CODE=$?
[ "$CODE" = 0 ] || fail "no canonical lint target must not escalate, got exit $CODE"
assert_contains "$OUT" "none configured for this repo" "fm-lint.sh must not run when no reviewable file is in its canonical set"
[ -s "$LINT_ARGS_LOG" ] && fail "fm-lint.sh must not be invoked at all when no reviewable file is in its canonical set"
pass "fm-lint.sh is skipped (never invoked bare) when no reviewable file falls in its canonical lint set"
rm -f "$TMP_ROOT/bin/fm-lint.sh" "$LINT_ARGS_LOG"

# --- stage2Mode: litellm -------------------------------------------------------

mkdir -p "$TMP_ROOT/config"
cat > "$TMP_ROOT/config/code-review" <<'JSON'
{"sizeThreshold": 1, "stage2Mode": "litellm", "stage2Provider": "litellm", "stage2Model": "test-model"}
JSON
fake_ocr 100 0 "'y.py'"
OUT=$(OCR_FAKE_REVIEW_EXIT=0 run_review worktree --dir "$TMP_ROOT" --from base --to head); CODE=$?
[ "$CODE" = 0 ] || fail "a successful litellm Stage 2 pass must exit 0, got $CODE"
# The single-quoted needle is a literal backtick-quoted string, not command
# substitution.
# shellcheck disable=SC2016
assert_contains "$OUT" 'Mode: `litellm`' "verdict must name the litellm stage2 mode"
grep -Eq -- '^review .*--provider litellm --model test-model' "$TMP_ROOT/ocr.log" \
  || fail "ocr review must be called with the configured provider/model"
pass "stage2Mode=litellm calls ocr review with the configured provider/model, scoped to the OCR-selected diff"

OUT=$(OCR_FAKE_REVIEW_EXIT=1 run_review worktree --dir "$TMP_ROOT" --from base --to head 2>&1); CODE=$?
[ "$CODE" = 1 ] || fail "a failed litellm call must exit 1, got $CODE"
assert_contains "$OUT" "Stage 2 (litellm) failed" "a failed litellm call must be reported clearly"
pass "a failed litellm Stage 2 call is reported and exits 1, never silently treated as a pass"
rm -f "$TMP_ROOT/config/code-review"

# --- JSON format --------------------------------------------------------------

fake_ocr 10 0 "'z.py'"
OUT=$(run_review worktree --dir "$TMP_ROOT" --from base --to head --format json)
echo "$OUT" | jq -e '.stage1.total_changed_lines == 10' >/dev/null || fail "json verdict missing/wrong total_changed_lines: $OUT"
echo "$OUT" | jq -e '.escalated == false' >/dev/null || fail "json verdict should report escalated=false: $OUT"
pass "--format json produces a parseable verdict with the expected stage1/escalated fields"

# --- pr mode resolves the base ref via gh -------------------------------------

fake_gh_pr_view "release-branch"
fake_ocr 10 0 "'p.py'"
: > "$TMP_ROOT/ocr.log"
run_review pr https://github.com/example/repo/pull/1 --dir "$TMP_ROOT" >/dev/null
grep -Fq -- "--from release-branch --to HEAD" "$TMP_ROOT/ocr.log" \
  || fail "pr mode must resolve --from from gh pr view's baseRefName"
pass "pr mode resolves --from from gh pr view's baseRefName"

OUT=$(PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-review.sh" pr 2>&1) && fail "pr mode without a URL must fail"
assert_contains "$OUT" "requires a PR URL" "pr mode must name the missing URL argument"
pass "pr mode refuses to run without a PR URL argument"

echo "# fm-review.test.sh: all assertions passed"
