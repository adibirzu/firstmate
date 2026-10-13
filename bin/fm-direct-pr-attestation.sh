#!/usr/bin/env bash
# fm-direct-pr-attestation.sh - validate a direct-PR two-stage review attestation.
#
# A direct-PR body passes the `Require no-mistakes` compliance check without a
# no-mistakes pipeline attestation when it carries a valid two-stage review
# attestation (docs/code-review.md owns the exact format): a pasted Stage 1
# verdict from bin/fm-review.sh under `## Code Review (Stage 1)`, plus a named
# independent second-level review under `## Independent Second-Level Review`
# (or the equivalent `## Code Review (Stage 2)` heading) with non-placeholder
# `Reviewer:` and `Report:` fields.
#
# Usage:
#   fm-direct-pr-attestation.sh [FILE]   validate FILE, or stdin when omitted
#   fm-direct-pr-attestation.sh --help   print this usage
#
# Exit 0 when the attestation is present and well-formed, 1 otherwise.
# The failure reason goes to stderr; nothing is printed on success.

set -u

usage() {
  sed -n '2,17{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

BODY=""
if [[ $# -gt 1 ]]; then
  echo "usage: fm-direct-pr-attestation.sh [FILE]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  [[ -f "$1" ]] || {
    echo "fm-direct-pr-attestation.sh: file not found: $1" >&2
    exit 2
  }
  BODY="$(cat "$1")"
else
  BODY="$(cat)"
fi

fail() {
  echo "fm-direct-pr-attestation.sh: $1" >&2
  exit 1
}

[[ -n "${BODY//[[:space:]]/}" ]] || fail "PR body is empty."

grep -qF '## Code Review (Stage 1)' <<<"$BODY" \
  || fail "missing '## Code Review (Stage 1)' heading."

stage1_ok=0
if grep -q 'Stage 1' <<<"$BODY" &&
  grep -qE 'Deterministic Review|Code Review Verdict' <<<"$BODY" &&
  grep -qE 'Files reviewable|Changes:' <<<"$BODY"; then
  stage1_ok=1
fi
[[ "$stage1_ok" -eq 1 ]] \
  || fail "Stage 1 verdict text from bin/fm-review.sh is missing or incomplete."

if grep -qF '## Independent Second-Level Review' <<<"$BODY"; then
  second_heading="## Independent Second-Level Review"
elif grep -qF '## Code Review (Stage 2)' <<<"$BODY"; then
  second_heading="## Code Review (Stage 2)"
else
  fail "missing '## Independent Second-Level Review' heading."
fi

reviewer_line="$(grep -m1 -E '^[[:space:]]*>?[[:space:]]*Reviewer:' <<<"$BODY" || true)"
[[ -n "$reviewer_line" ]] \
  || fail "second-level review must name its lane in a 'Reviewer:' field under '$second_heading'."
reviewer_value="$(sed -E 's/^[^:]*Reviewer:[[:space:]]*//' <<<"$reviewer_line" | sed -E 's/[*_`]+//g' | xargs)"
[[ -n "$reviewer_value" ]] || fail "'Reviewer:' field is empty."
reviewer_lower="$(tr '[:upper:]' '[:lower:]' <<<"$reviewer_value")"
case "$reviewer_lower" in
  todo|tbd|tba|n/a|na|none|placeholder|example|xxx|\<*\>*)
    fail "'Reviewer:' field is a placeholder ('$reviewer_value')."
    ;;
esac
[[ "${#reviewer_value}" -ge 2 ]] || fail "'Reviewer:' field is too short to name a lane."

report_line="$(grep -m1 -E '^[[:space:]]*>?[[:space:]]*Report:' <<<"$BODY" || true)"
[[ -n "$report_line" ]] \
  || fail "second-level review must give its location in a 'Report:' field under '$second_heading'."
report_value="$(sed -E 's/^[^:]*Report:[[:space:]]*//' <<<"$report_line" | sed -E 's/[*_`]+//g' | xargs)"
[[ -n "$report_value" ]] || fail "'Report:' field is empty."
report_lower="$(tr '[:upper:]' '[:lower:]' <<<"$report_value")"
case "$report_lower" in
  todo|tbd|tba|n/a|na|none|placeholder|example|xxx|\<*\>*)
    fail "'Report:' field is a placeholder ('$report_value')."
    ;;
esac
if ! grep -qE '/|\.|://' <<<"$report_value"; then
  fail "'Report:' field must be a path or URL ('$report_value')."
fi

exit 0
