#!/usr/bin/env bash
# tests/fm-status-span-fold-budget.test.sh - the status-span fold that builds the
# `;`-joined events string must stay bounded per pass, or a heavy fleet's status
# log feeds an ever-growing command-shaped join to every consumer of the record.
# That fold is the loop-built-whole-file string class that overflowed an 8 MiB
# stack on the 2026-10-07 Mac mini watcher (fm-watch-bash-segv): a ~19,400-command
# `;`-joined list parsed in one pass recursed the parser past the stack bound in
# xparse_dolparen. The budget bounds the events STRING alone; actionability (rc)
# and the needs-decision flag are still computed across the WHOLE span, so
# bounding the fold cannot bury an escalation in the un-folded tail.
#
# Regression contract:
#   - fail against the pre-fix code path: an unbounded fold returns the whole
#     dense log (len >> budget), which this suite refuses;
#   - pass after the fix: len and event count stay within the fold budget while
#     rc/needs-decision keep surfacing a decision buried deep in the log.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-span-fold-budget-tests)

# A status log dense with captain-relevant progress: 300 done: lines (enough to
# trip BOTH the 8192-char and 200-event budgets by a wide margin in the pre-fix
# code), plus a needs-decision buried beyond the budget, standing in for the
# incident's 180 KB / ~19,400-line watcher status log at a scale a test can roll
# in a couple of seconds. Pre-fix, the whole 300-line log is folded (~9 KB, 301
# fragments); post-fix only the 200-event head is folded and the buried decision
# still surfaces through whole-span actionability.
test_fold_stays_bounded_on_a_dense_captain_log() {
  local dir f i record rc nd events len chars_max ev_count _frag
  dir="$TMP_ROOT/dense"; mkdir -p "$dir"
  f="$dir/dense.status"
  for i in $(seq 1 300); do
    printf 'done: heavy batch %d shipped\n' "$i" >> "$f"
  done
  printf 'needs-decision [key=deep]: pick the deeper option\n' >> "$f"

  record=; nd=0
  status_span_first_actionable_record "$f" 0 record nd
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a needs-decision buried past the fold budget was not surfaced by actionability"
  [ "$nd" -eq 1 ] \
    || fail "the needs-decision flag was lost when the fold hit its budget"
  events=${record#*$'\t'}; events=${events#*$'\t'}
  chars_max=${FM_STATUS_SPAN_MAX_FOLD_CHARS:-8192}
  len=${#events}
  # The budget ceiling plus the truncation marker's overhead; still an order of
  # magnitude under the pre-fix fold of the whole log.
  [ "$len" -le $(( chars_max + 150 )) ] \
    || fail "the events fold grew to ${len} chars (budget ${chars_max}): the pre-fix unbounded fold"
  ev_count=0
  while IFS= read -r -d ';' _frag || [ -n "$_frag" ]; do
    [ -n "$_frag" ] && ev_count=$((ev_count + 1))
  done <<< "$events"
  [ "$ev_count" -le 205 ] \
    || fail "the events fold held ${ev_count} fragments (budget 200 + marker): the pre-fix unbounded fold"
  pass "a dense captain-relevant status log folds within budget and still surfaces a decision buried in its tail"
}

# The fold budget is env-tunable and ordinary small logs fold byte-for-byte as
# before, so the hard boundary never changes routine behavior.
test_budget_is_tunable_and_small_logs_are_untouched() {
  local dir f i record rc nd events
  dir="$TMP_ROOT/tunable"; mkdir -p "$dir"
  f="$dir/tunable.status"
  printf 'working: warmup\nneeds-decision [key=q]: pick now\nworking: tail\n' > "$f"
  record=; nd=0
  FM_STATUS_SPAN_MAX_FOLD_CHARS=4096 FM_STATUS_SPAN_MAX_FOLD_EVENTS=2 \
    status_span_first_actionable_record "$f" 0 record nd
  rc=$?
  [ "$rc" -eq 0 ] || fail "a single decision in a small log was not surfaced"
  [ "$nd" -eq 1 ] || fail "the needs-decision flag was lost on a small log"
  events=${record#*$'\t'}; events=${events#*$'\t'}
  [ "$events" = "needs-decision [key=q]: pick now" ] \
    || fail "a small log fold was not kept verbatim: '$events'"

  # A tight budget still surfaces the decision and stays bounded.
  : > "$f"
  for i in $(seq 1 100); do
    printf 'done: batch %d\n' "$i" >> "$f"
  done
  printf 'needs-decision [key=tight]: pick quickly\n' >> "$f"
  record=; nd=0
  FM_STATUS_SPAN_MAX_FOLD_CHARS=300 FM_STATUS_SPAN_MAX_FOLD_EVENTS=3 \
    status_span_first_actionable_record "$f" 0 record nd
  rc=$?
  [ "$rc" -eq 0 ] || fail "a decision past a tight budget was not surfaced"
  [ "$nd" -eq 1 ] || fail "the needs-decision flag was lost under a tight budget"
  events=${record#*$'\t'}; events=${events#*$'\t'}
  [ "${#events}" -le 300 ] || fail "a tight fold budget was exceeded: ${#events} chars"
  pass "the fold budget is env-tunable and small logs fold verbatim, while a decision past a tight budget still surfaces"
}

test_fold_stays_bounded_on_a_dense_captain_log
test_budget_is_tunable_and_small_logs_are_untouched