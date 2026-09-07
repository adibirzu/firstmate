#!/usr/bin/env bash
# Behavioral adapter checks for GitHub Copilot CLI.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
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
make_copilot_spawn_case() {
  local name=$1 mode=$2 dir fakebin
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-copilot-spawn.XXXXXX")
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake" copilot)
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0;; esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate ;;
  has-session|new-session|new-window|kill-window|set-window-option|list-windows) ;;
  send-keys) [ "${!#}" != Enter ] || [ "$(cat "$FM_COPILOT_CAPTURE_COUNT")" = 0 ] || printf '%s\n' Enter >> "$FM_COPILOT_KEYS" ;;
  capture-pane)
    n=$(cat "$FM_COPILOT_CAPTURE_COUNT"); n=$((n + 1)); printf '%s\n' "$n" > "$FM_COPILOT_CAPTURE_COUNT"
    if [ "$FM_COPILOT_MODE" = clear ] && [ "$n" -gt 1 ]; then printf '%s\n' ' ◎ Working esc interrupt GPT-5.6 Terra'; else printf '%s\n' 'Confirm folder trust' '/opt/pool/crew/wt-01' '❯ 1. Yes'; fi ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_test_spawn_home "$dir/home" copilot
  fm_git_worktree "$dir/project" "$dir/wt" "copilot-$name"
  fm_test_spawn_brief "$dir/home" "copilot-$name"
  mkdir -p "$dir/home/user-home/.copilot"
  printf '%s\n' sentinel > "$dir/home/user-home/.copilot/config.json"
  printf '0\n' > "$dir/count"; : > "$dir/keys"
  printf '%s|%s|%s|%s\n' "$dir" "$fakebin" "$mode" "copilot-$name"
}
test_copilot_trust_gate_spawn_behavior() {
  local rec dir fakebin mode id out rc
  rec=$(make_copilot_spawn_case clear clear); IFS='|' read -r dir fakebin mode id <<<"$rec"
  out=$(FM_COPILOT_MODE="$mode" FM_COPILOT_CAPTURE_COUNT="$dir/count" FM_COPILOT_KEYS="$dir/keys" FM_COPILOT_TRUST_POLLS=3 FM_COPILOT_POLL_INTERVAL=0 FM_FAKE_LAUNCH_LOG="$dir/launch" fm_test_run_spawn "$dir/home" "$dir/wt" "$fakebin" "$id" "$dir/project" copilot --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "copilot spawn should clear folder trust: $out"
  [ "$(wc -l < "$dir/keys")" -eq 1 ] || fail "folder trust must send Enter once"
  [ "$(cat "$dir/home/user-home/.copilot/config.json")" = sentinel ] || fail "spawn mutated Copilot config"
  rm -rf "$dir"
  pass "fm-spawn: copilot accepts trust once without config mutation"
}
test_copilot_trust_gate_fails_bounded() {
  local rec dir fakebin mode id out rc
  rec=$(make_copilot_spawn_case blocked blocked); IFS='|' read -r dir fakebin mode id <<<"$rec"
  out=$(FM_COPILOT_MODE="$mode" FM_COPILOT_CAPTURE_COUNT="$dir/count" FM_COPILOT_KEYS="$dir/keys" FM_COPILOT_TRUST_POLLS=2 FM_COPILOT_POLL_INTERVAL=0 fm_test_run_spawn "$dir/home" "$dir/wt" "$fakebin" "$id" "$dir/project" copilot --mode no-mistakes --yolo off); rc=$?
  expect_code 1 "$rc" "copilot spawn must fail when trust dialog persists"
  assert_contains "$out" 'did not clear the folder-trust gate' "copilot trust failure was not explicit"
  [ "$(wc -l < "$dir/keys")" -eq 1 ] || fail "persistent dialog must still send Enter once"
  [ "$(cat "$dir/home/user-home/.copilot/config.json")" = sentinel ] || fail "failed spawn mutated Copilot config"
  rm -rf "$dir"
  pass "fm-spawn: copilot fails bounded trust dialog without config mutation"
}
test_copilot_env_marker_detects_harness
test_copilot_busy_and_composer_states
test_copilot_trust_gate_spawn_behavior
test_copilot_trust_gate_fails_bounded
echo "ALL PASS: fm-copilot-harness"
