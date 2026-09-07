#!/usr/bin/env bash
# Behavioral adapter checks for Antigravity CLI.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
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
make_agy_spawn_case() {
  local name=$1 mode=$2 dir fakebin
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-spawn.XXXXXX")
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake" agy)
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0;; esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate ;;
  has-session|new-session|new-window|kill-window|set-window-option|list-windows) ;;
  send-keys) if [ "${!#}" = Enter ]; then [ "$(cat "$FM_AGY_CAPTURE_COUNT")" = 0 ] || printf '%s\n' Enter >> "$FM_AGY_KEYS"; else printf '%s\n' "$*" >> "$FM_AGY_LAUNCH"; fi ;;
  capture-pane)
    n=$(cat "$FM_AGY_CAPTURE_COUNT"); n=$((n + 1)); printf '%s\n' "$n" > "$FM_AGY_CAPTURE_COUNT"
    if [ "$FM_AGY_MODE" = clear ] && [ "$n" -gt 1 ]; then printf '%s\n' '? for shortcuts Gemini 3.6 Flash · high'; else printf '%s\n' 'Do you trust the contents of this project?' '> Yes, I trust this folder'; fi ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_test_spawn_home "$dir/home" agy
  fm_git_worktree "$dir/project" "$dir/wt" "agy-$name"
  fm_test_spawn_brief "$dir/home" "agy-$name"
  printf '0\n' > "$dir/count"; : > "$dir/keys"; : > "$dir/launch"
  printf '%s|%s|%s|%s\n' "$dir" "$fakebin" "$mode" "agy-$name"
}
test_agy_launch_and_trust_gate() {
  local rec dir fakebin mode id out rc
  rec=$(make_agy_spawn_case clear clear); IFS='|' read -r dir fakebin mode id <<<"$rec"
  out=$(FM_AGY_MODE="$mode" FM_AGY_CAPTURE_COUNT="$dir/count" FM_AGY_KEYS="$dir/keys" FM_AGY_LAUNCH="$dir/launch" FM_AGY_TRUST_POLLS=3 FM_AGY_POLL_INTERVAL=0 fm_test_run_spawn "$dir/home" "$dir/wt" "$fakebin" "$id" "$dir/project" agy --model gemini-3.6-flash --effort xhigh --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "agy spawn should clear project trust: $out"
  [ "$(wc -l < "$dir/keys")" -eq 1 ] || fail "agy trust must send Enter once"
  assert_contains "$(cat "$dir/launch")" '--effort high' "agy xhigh launch must clamp to high"
  rm -rf "$dir"
  pass "fm-spawn: agy launches with supported effort and clears trust once"
}
test_agy_secondmate_refusal() {
  local rec dir fakebin mode id out rc sm
  rec=$(make_agy_spawn_case secondmate clear); IFS='|' read -r dir fakebin mode id <<<"$rec"
  sm="$dir/secondmate-home"; mkdir -p "$sm/bin" "$sm/data"; printf '# Firstmate\n' > "$sm/AGENTS.md"; printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  out=$(FM_AGY_MODE="$mode" FM_AGY_CAPTURE_COUNT="$dir/count" FM_AGY_KEYS="$dir/keys" FM_AGY_LAUNCH="$dir/launch" fm_test_run_spawn "$dir/home" "$dir/wt" "$fakebin" "$id" "$sm" agy --secondmate); rc=$?
  expect_code 1 "$rc" "agy secondmate spawn must be refused"
  assert_contains "$out" 'cannot run a secondmate' "agy secondmate refusal was not explicit"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused agy secondmate wrote task metadata"
  rm -rf "$dir"
  pass "fm-spawn: agy refuses unsupported secondmate lifecycle"
}
test_agy_env_marker_takes_precedence
test_agy_busy_and_composer_states
test_agy_launch_and_trust_gate
test_agy_secondmate_refusal
echo "ALL PASS: fm-agy-harness"
