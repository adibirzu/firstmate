#!/usr/bin/env bash
# Behavioral adapter checks for Antigravity CLI.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
. "$ROOT/bin/fm-tmux-lib.sh"
classify() { fm_composer_classify_content "$@"; }
test_agy_env_marker_takes_precedence() {
  local out
  out=$(ANTIGRAVITY_AGENT=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = agy ] || fail "expected agy when both markers set, got '$out'"
  out=$(ANTIGRAVITY_AGENT='' CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "expected claude when only CLAUDECODE set, got '$out'"
  pass "fm-harness: Antigravity marker takes precedence over Claude"
}
test_agy_busy_and_composer_states() {
  printf '%s' 'esc to cancel Gemini 3.6 Flash · low' | fm_busy_lines_match agy || fail "agy busy footer did not classify busy"
  if printf '%s' '? for shortcuts Gemini 3.6 Flash · low' | fm_busy_lines_match agy; then fail "agy idle bar read busy"; fi
  [ "$(classify 1 '>')" = empty ] || fail "bordered agy composer must be empty"
  [ "$(classify 0 '>')" = unknown ] || fail "bare agy glyph must remain unknown"
  [ "$(classify 1 'Fix the parser')" = pending ] || fail "agy input must be pending"
  pass "agy busy and composer captures classify correctly"
}
test_agy_env_marker_takes_precedence
test_agy_busy_and_composer_states
echo "ALL PASS: fm-agy-harness"
