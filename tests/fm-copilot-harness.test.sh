#!/usr/bin/env bash
# Behavioral adapter checks for GitHub Copilot CLI.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
. "$ROOT/bin/fm-tmux-lib.sh"
. "$ROOT/tests/composer-fence.sh"
classify() { fm_composer_classify_content "$@"; }
test_copilot_env_marker_detects_harness() {
  local out
  out=$(COPILOT_CLI=1 "$HARNESS")
  [ "$out" = copilot ] || fail "expected copilot from COPILOT_CLI=1, got '$out'"
  pass "fm-harness: Copilot marker selects copilot"
}
test_copilot_busy_and_composer_states() {
  printf '%s' ' ◎ Working esc interrupt GPT-5.6 Terra' | fm_busy_lines_match copilot || fail "copilot busy footer did not classify busy"
  if printf '%s' '❯' | fm_busy_lines_match copilot; then fail "copilot idle composer read busy"; fi
  [ "$(classify 1 '❯')" = empty ] || fail "bordered copilot glyph must be empty"
  [ "$(classify 0 '❯')" = empty ] || fail "bare copilot glyph must be empty"
  [ "$(classify 1 'Fix the parser')" = pending ] || fail "copilot input must be pending"
  fm_test_composer_reads_empty "$(printf '%s\n' '❯ ')" "copilot bare composer row"
  pass "copilot busy and composer captures classify correctly"
}
test_copilot_env_marker_detects_harness
test_copilot_busy_and_composer_states
echo "ALL PASS: fm-copilot-harness"
