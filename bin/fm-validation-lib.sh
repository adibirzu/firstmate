#!/usr/bin/env bash
# shellcheck shell=bash
# fm-validation-lib.sh - feature vs PRD-finish validation contract.
#
# One owner of validation=<feature|prd-finish> on ship Delivery contract lines.
# Callers: bin/fm-dod-lib.sh, bin/fm-brief.sh, bin/fm-spawn.sh.

fm_validation_normalize() {  # <phase-or-empty>
  case "${1:-}" in
    ''|feature) printf '%s\n' feature ;;
    prd-finish|prd_finish|finish) printf '%s\n' prd-finish ;;
    *) return 1 ;;
  esac
}

fm_validation_contract_token() {  # <phase>
  local phase
  phase=$(fm_validation_normalize "$1") || return 1
  printf 'validation=%s' "$phase"
}

fm_validation_prd_review_profiles() {
  cat <<'EOF'
claude:opus:high
codex:gpt-5.5:xhigh
grok:grok-4.6:xhigh
agy:gemini-3.1-pro:high
cursor:cursor-grok-4.6-high:high
EOF
}

fm_validation_dod_addendum() {  # <phase>
  local phase
  phase=$(fm_validation_normalize "$1") || return 1
  case "$phase" in
    feature)
      cat <<'EOF'

# Validation phase: feature
Delivery contract: validation=feature
While this feature is in progress, run only tests that cover the newly developed work:
- Firstmate-repo tasks: `bin/fm-test-run.sh --changed` (never `--all` / `--lane` / `--family` for ordinary feature work).
- Other projects: run only the tests that exercise files you changed, or the project's documented targeted/changed test entry point. Do not run the full suite as routine feature validation.
Stage 1 (`bin/fm-review.sh worktree`) remains required before delivery; do not force a high-thinking Stage 2 review for ordinary feature work.
EOF
      ;;
    prd-finish)
      cat <<'EOF'

# Validation phase: prd-finish
Delivery contract: validation=prd-finish
This task closes a PRD (or equivalent finish gate). Before reporting done:
1. Run the full test suite for the project (Firstmate: `bin/fm-test-run.sh --all` after `llm-router-axi capacity --for suite` admits it; other projects: the project's full CI/test suite).
2. Run `bin/fm-review.sh worktree` Stage 1, then complete a high-thinking Stage 2 host review even when Stage 1 does not escalate.
3. Prefer a REVIEW-lane high-thinking profile for that review: Claude Opus (high), Codex/Sol gpt-5.5 (xhigh), Grok 4.6 (xhigh), Gemini Pro (high), or Cursor grok-4.6-high — firstmate may spawn the reviewer; do not skim the finish review on a cheap fast model.
Append evidence of the full-suite result and the high-thinking review verdict before `done:`.
EOF
      ;;
  esac
}
