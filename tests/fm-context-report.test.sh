#!/usr/bin/env bash
# tests/fm-context-report.test.sh - bin/fm-context-report.sh behavior.
#
# Builds a synthetic Claude transcript tree and asserts the report groups turns
# by firstmate home, computes the tokens-in-context and >150k share from each
# assistant record's usage, respects the window, filters non-firstmate homes by
# default, and emits parseable JSON. No real transcript is read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-context-report.sh"
TMP=$(fm_test_tmproot fm-context-report-tests)
PROJECTS="$TMP/projects"

mk_jsonl() {  # <dir> <file> <cwd> <within-window 0|1> <tokens...>
  local dir=$1 file=$2 cwd=$3 within=$4
  shift 4
  mkdir -p "$dir"
  : > "$dir/$file"
  local ts now old tokens i=0
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  old=$(date -u -v-3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)
  : > "$dir/$file"
  for tokens in "$@"; do
    i=$((i + 1))
    if [ "$within" -eq 1 ]; then ts=$now; else ts=$old; fi
    printf '{"type":"assistant","cwd":"%s","timestamp":"%s","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
      "$cwd" "$ts" "$((tokens / 2))" "$((tokens - tokens / 2 - 10))" >> "$dir/$file"
  done
}

test_groups_and_threshold_share() {
  local out
  mk_jsonl "$PROJECTS/-home-firstmate" "a.jsonl" "/home/firstmate" 1 300000 100000
  mk_jsonl "$PROJECTS/-home-other-project" "b.jsonl" "/home/other-project" 1 400000

  out=$("$REPORT" --hours 24 --projects-dir "$PROJECTS")

  printf '%s\n' "$out" | grep -F "/home/firstmate" >/dev/null \
    || fail "report did not group a firstmate home: $out"
  printf '%s\n' "$out" | grep -F "/home/other-project" >/dev/null \
    && fail "report included a non-firstmate home without --all: $out"
  # Two turns, one at 300k (above) and one at ~100k (below) -> 50.0%.
  printf '%s\n' "$out" | grep -E '/home/firstmate +2 ' >/dev/null \
    || fail "report did not count both turns for the firstmate home: $out"
  # Only the >150k turn counts as above-threshold.
  printf '%s\n' "$out" | grep -F "50.0%" >/dev/null \
    || fail "report did not compute the >150k share: $out"
  pass "report groups by firstmate home and computes the above-threshold share"
}

test_window_and_all_and_json() {
  local out all
  mk_jsonl "$PROJECTS/-home-firstmate" "old.jsonl" "/home/firstmate" 0 999999
  out=$("$REPORT" --hours 24 --projects-dir "$PROJECTS")
  printf '%s\n' "$out" | grep -F "500000" >/dev/null \
    && fail "report counted a turn outside the window: $out"
  all=$("$REPORT" --hours 24 --projects-dir "$PROJECTS" --all)
  printf '%s\n' "$all" | grep -F "/home/other-project" >/dev/null \
    || fail "--all did not include a non-firstmate home: $all"
  local json
  json=$("$REPORT" --hours 24 --projects-dir "$PROJECTS" --all --json)
  printf '%s\n' "$json" | jq -e '.threshold == 150000 and (.homes | length) >= 2' >/dev/null \
    || fail "report --json was not parseable or wrong: $json"
  pass "the report respects the window, --all, and emits JSON"
}

test_missing_root_is_reported() {
  local out
  out=$("$REPORT" --projects-dir "$TMP/does-not-exist")
  printf '%s\n' "$out" | grep -F "no Claude transcript root" >/dev/null \
    || fail "a missing transcript root was not reported: $out"
  pass "a missing transcript root is reported rather than erroring"
}

test_bad_hours_refuses() {
  local rc=0 out value
  for value in 0 00 08 0x -1 abc; do
    rc=0
    out=$("$REPORT" --hours "$value" --projects-dir "$PROJECTS" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "a non-positive or malformed --hours ($value) must be refused (got rc=$rc: $out)"
  done
  pass "a non-positive or octal-looking --hours is refused"
}

test_groups_and_threshold_share
test_window_and_all_and_json
test_missing_root_is_reported
test_bad_hours_refuses

echo "# fm-context-report.test.sh: all assertions passed"
