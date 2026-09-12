#!/usr/bin/env bash
# fm-review.sh - deterministic-first code review wrapper.
#
# Two-stage review built on Alibaba's Open Code Review (`ocr`, the AACR-bench
# tool at https://github.com/alibaba/open-code-review):
#
#   Stage 1 (always, zero LLM tokens): `ocr delegate preview` selects the
#   reviewable file set and reports changeset size; the target repo's own
#   configured linter runs against that same diff (bin/fm-lint.sh, invoked
#   with exactly the OCR-selected files that fall in its canonical set -
#   bin/*.sh, bin/backends/*.sh, tests/*.sh - when the target repo is
#   firstmate itself, otherwise a `package.json` "lint" script when one
#   exists - nothing else is auto-detected).
#
#   Stage 2 (only when Stage 1 flags a reason): a high-risk file matched a
#   configured pattern, the linter reported findings, or the changeset
#   exceeds the configured size threshold. Two stage-2 modes:
#     - "delegate" (default): no LLM call at all. `ocr delegate rule` prints
#       the deterministic rule text for the OCR-selected files so the
#       calling agent's own harness reviews them directly - this is the
#       cheaper path whenever a metered LLM call isn't already unavoidable.
#     - "litellm": `ocr review` runs a real LLM pass through the LiteLLM
#       gateway (see LIFEOS/DOCUMENTATION/Services/Gb10Fleet.md), only on
#       the same OCR-selected diff.
#
# Usage:
#   fm-review.sh worktree [--dir PATH] [--from REF] [--to REF]
#   fm-review.sh pr <PR_URL>
#   fm-review.sh (worktree|pr ...) [--format json|markdown] [--output FILE] [--stage1-only]
#
# Config (repo-root config/code-review, JSON; all keys optional):
#   {
#     "sizeThreshold": 1000,          // total changed lines before Stage 2 escalates
#     "riskPatterns": ["auth/**"],    // glob patterns (matched with bash extglob) that force Stage 2
#     "stage2Mode": "delegate",       // "delegate" (no LLM) or "litellm" (real LLM call)
#     "stage2Provider": "litellm",    // passed to `ocr review --provider`  (litellm mode only)
#     "stage2Model": "auto-code"      // passed to `ocr review --model`     (litellm mode only)
#   }
#
# Env overrides (take precedence over config/code-review, for quick local testing):
#   FM_REVIEW_SIZE_THRESHOLD, FM_REVIEW_STAGE1_ONLY, FM_REVIEW_STAGE2_MODE
#
# Exit codes:
#   0  Stage 1 clean, no escalation
#   1  Stage 1 found lint findings, or a required tool is missing/failed
#   2  Escalated to Stage 2 in "delegate" mode - a host-agent review is still owed
# Stage 2 "litellm" escalation exits 0 once the LLM pass completes (its own
# findings are reported in the verdict body, not via exit code).
#
# Requires: ocr, jq. `gh` (via gh-axi) only for `pr` mode.

set -euo pipefail

# --- Argument parsing ---

MODE=""
DIR="."
FROM=""
TO="HEAD"
PR_URL=""
FORMAT="markdown"
OUTPUT=""
STAGE1_ONLY="${FM_REVIEW_STAGE1_ONLY:-}"

usage() {
  cat <<'EOF'
Usage:
  fm-review.sh worktree [--dir PATH] [--from REF] [--to REF] [options]
  fm-review.sh pr <PR_URL> [options]

Options:
  --format json|markdown   output format (default: markdown)
  --output FILE            write the verdict to FILE instead of stdout
  --stage1-only            never escalate to Stage 2, regardless of config/thresholds
  -h, --help               print this usage
EOF
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

MODE="$1"; shift
case "$MODE" in
  worktree)
    ;;
  pr)
    if [[ $# -eq 0 || "$1" == -* ]]; then
      echo "error: 'pr' mode requires a PR URL as its first argument" >&2
      exit 1
    fi
    PR_URL="$1"; shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "error: unknown mode '$MODE' (expected 'worktree' or 'pr')" >&2
    exit 1
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --stage1-only) STAGE1_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unrecognized argument '$1'" >&2; exit 1 ;;
  esac
done

for tool in ocr jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

# --- Resolve mode into DIR / FROM / TO ---

if [[ "$MODE" == "pr" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: 'pr' mode requires 'gh' on PATH" >&2
    exit 1
  fi
  BASE_REF="$(gh pr view "$PR_URL" --json baseRefName -q .baseRefName 2>/dev/null)" || {
    echo "error: could not resolve base ref for $PR_URL via gh" >&2
    exit 1
  }
  FROM="$BASE_REF"
  TO="HEAD"
fi

if [[ -z "$FROM" ]]; then
  FROM="$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null || git -C "$DIR" merge-base HEAD main 2>/dev/null || echo main)"
fi

# --- Load config/code-review (repo-root JSON, all keys optional) ---

CONFIG_FILE="$DIR/config/code-review"
SIZE_THRESHOLD="${FM_REVIEW_SIZE_THRESHOLD:-}"
STAGE2_MODE="${FM_REVIEW_STAGE2_MODE:-}"
STAGE2_PROVIDER=""
STAGE2_MODEL=""
RISK_PATTERNS=()

if [[ -f "$CONFIG_FILE" ]]; then
  [[ -n "$SIZE_THRESHOLD" ]] || SIZE_THRESHOLD="$(jq -r '.sizeThreshold // empty' "$CONFIG_FILE")"
  [[ -n "$STAGE2_MODE" ]] || STAGE2_MODE="$(jq -r '.stage2Mode // empty' "$CONFIG_FILE")"
  STAGE2_PROVIDER="$(jq -r '.stage2Provider // empty' "$CONFIG_FILE")"
  STAGE2_MODEL="$(jq -r '.stage2Model // empty' "$CONFIG_FILE")"
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] && RISK_PATTERNS+=("$pattern")
  done < <(jq -r '.riskPatterns[]? // empty' "$CONFIG_FILE")
fi

SIZE_THRESHOLD="${SIZE_THRESHOLD:-1000}"
STAGE2_MODE="${STAGE2_MODE:-delegate}"

# --- Stage 1: deterministic review (zero LLM tokens) ---

stage1_json="$(ocr delegate preview --repo "$DIR" --from "$FROM" --to "$TO" --format json)"

total_insertions="$(echo "$stage1_json" | jq -r '.total_insertions // 0')"
total_deletions="$(echo "$stage1_json" | jq -r '.total_deletions // 0')"
total_changed=$(( total_insertions + total_deletions ))
mapfile -t reviewable_files < <(echo "$stage1_json" | jq -r '.reviewable_files[]?.path // empty')

# Repo's own configured linter, run only against the reviewable diff.
# fm-lint.sh's own canonical set (a direct *.sh child of bin/, bin/backends/,
# or tests/); explicit-path mode requires at least one match, otherwise
# no-arg mode would fall back to its own unrelated file-set auto-detection.
review_lint_target() {  # <path>
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}
lint_targets=()
for f in "${reviewable_files[@]}"; do
  review_lint_target "$f" && lint_targets+=("$f")
done

lint_ran=false
lint_findings=0
lint_output=""
if [[ -x "$DIR/bin/fm-lint.sh" ]]; then
  if [[ ${#lint_targets[@]} -gt 0 ]]; then
    lint_ran=true
    if ! lint_output="$("$DIR/bin/fm-lint.sh" "${lint_targets[@]}" 2>&1)"; then
      lint_findings=1
    fi
  fi
elif [[ -f "$DIR/package.json" ]] && jq -e '.scripts.lint' "$DIR/package.json" >/dev/null 2>&1; then
  lint_ran=true
  if ! lint_output="$(cd "$DIR" && npm run lint --silent 2>&1)"; then
    lint_findings=1
  fi
fi

# High-risk file match against configured glob patterns.
matched_risk_files=()
if [[ ${#RISK_PATTERNS[@]} -gt 0 ]]; then
  shopt -s extglob nullglob globstar 2>/dev/null || true
  for f in "${reviewable_files[@]}"; do
    for pattern in "${RISK_PATTERNS[@]}"; do
      # Intentional glob match (pattern is a glob, not a literal string).
      # shellcheck disable=SC2053
      if [[ "$f" == $pattern ]]; then
        matched_risk_files+=("$f")
        break
      fi
    done
  done
fi

escalate=false
escalate_reason=""
if [[ "$STAGE1_ONLY" != "true" ]]; then
  if [[ $total_changed -gt $SIZE_THRESHOLD ]]; then
    escalate=true
    escalate_reason="changeset ($total_changed lines) exceeds threshold ($SIZE_THRESHOLD)"
  elif [[ ${#matched_risk_files[@]} -gt 0 ]]; then
    escalate=true
    escalate_reason="high-risk file(s) matched: ${matched_risk_files[*]}"
  elif [[ $lint_findings -gt 0 ]]; then
    escalate=true
    escalate_reason="linter reported findings"
  fi
fi

# --- Stage 2 (only when escalated) ---

stage2_ran=false
stage2_mode_used=""
stage2_output=""
stage2_exit=0

if [[ "$escalate" == "true" ]]; then
  stage2_ran=true
  stage2_mode_used="$STAGE2_MODE"
  if [[ "$STAGE2_MODE" == "litellm" ]]; then
    ocr_args=(review --repo "$DIR" --from "$FROM" --to "$TO" --format json)
    [[ -n "$STAGE2_PROVIDER" ]] && ocr_args+=(--provider "$STAGE2_PROVIDER")
    [[ -n "$STAGE2_MODEL" ]] && ocr_args+=(--model "$STAGE2_MODEL")
    if stage2_output="$(ocr "${ocr_args[@]}" 2>&1)"; then
      stage2_exit=0
    else
      stage2_exit=1
    fi
  else
    # delegate mode: print the deterministic rule text for the selected
    # files; no LLM call. The calling agent applies these rules itself.
    if [[ ${#reviewable_files[@]} -gt 0 ]]; then
      stage2_output="$(ocr delegate rule --repo "$DIR" "${reviewable_files[@]}" --format json 2>&1)" || stage2_exit=1
    else
      stage2_output='{"groups": []}'
    fi
  fi
fi

# --- Render verdict ---

if [[ "$FORMAT" == "json" ]]; then
  result="$(jq -n \
    --argjson stage1 "$stage1_json" \
    --arg escalate "$escalate" \
    --arg reason "$escalate_reason" \
    --arg lint_ran "$lint_ran" \
    --arg lint_findings "$lint_findings" \
    --arg lint_output "$lint_output" \
    --arg stage2_ran "$stage2_ran" \
    --arg stage2_mode "$stage2_mode_used" \
    --arg stage2_output "$stage2_output" \
    --arg stage2_failed "$( [[ $stage2_exit -ne 0 ]] && echo true || echo false )" \
    '{
      stage1: {
        preview: $stage1,
        total_changed_lines: ($stage1.total_insertions + $stage1.total_deletions),
        lint: { ran: ($lint_ran == "true"), findings: ($lint_findings | tonumber), output: $lint_output }
      },
      escalated: ($escalate == "true"),
      escalation_reason: $reason,
      stage2: {
        ran: ($stage2_ran == "true"),
        mode: $stage2_mode,
        failed: ($stage2_failed == "true"),
        output: $stage2_output
      }
    }')"
else
  result="# Code Review Verdict

**Stage 1: Deterministic Review (zero LLM tokens)**

- Files reviewable: ${#reviewable_files[@]} / $(echo "$stage1_json" | jq -r '.total_files // 0')
- Changes: +${total_insertions} / -${total_deletions} ($total_changed lines)
- Linter: $([[ "$lint_ran" == "true" ]] && echo "ran, $lint_findings finding(s)" || echo "none configured for this repo")
- LLM tokens: 0
"
  if [[ "$lint_ran" == "true" && $lint_findings -gt 0 ]]; then
    result+="
\`\`\`
$lint_output
\`\`\`
"
  fi
  if [[ "$escalate" == "true" ]]; then
    result+="
**Stage 2: Escalated** (${escalate_reason})

Mode: \`$stage2_mode_used\`
"
    if [[ "$stage2_mode_used" == "litellm" ]]; then
      result+="$(echo "$stage2_output" | jq -r '.summary // "LLM review completed; see JSON output for findings."' 2>/dev/null || echo "$stage2_output")"
    else
      result+="No LLM call made. The host agent must review the selected files against the rules below before this PR is ready.

$(echo "$stage2_output" | jq -r '.groups[]? | "### " + (.files | join(", ")) + "\n\n" + .rule' 2>/dev/null || echo "$stage2_output")"
    fi
  else
    result+="
No escalation: Stage 1 alone gates this change."
  fi
fi

if [[ -n "$OUTPUT" ]]; then
  echo "$result" > "$OUTPUT"
  echo "Verdict written to $OUTPUT" >&2
else
  echo "$result"
fi

if [[ $stage2_exit -ne 0 ]]; then
  echo "error: Stage 2 ($stage2_mode_used) failed; see output above" >&2
  exit 1
fi
if [[ $lint_findings -gt 0 && "$escalate" != "true" ]]; then
  exit 1
fi
if [[ "$escalate" == "true" && "$stage2_mode_used" == "delegate" ]]; then
  exit 2
fi
exit 0
