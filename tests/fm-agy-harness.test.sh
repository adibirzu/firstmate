#!/usr/bin/env bash
# Behavioral adapter checks for Antigravity CLI.
set -u
# shellcheck source=tests/fixtures.sh
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
    case "$FM_AGY_MODE" in
      clear) if [ "$n" -gt 1 ]; then printf '%s\n' '? for shortcuts Gemini 3.6 Flash · high'; else printf '%s\n' 'Do you trust the contents of this project?' '> Yes, I trust this folder'; fi ;;
      clear-123-busy) if [ "$n" -gt 1 ]; then printf '%s\n' "$FM_AGY_123_BUSY"; else printf '%s\n' "$FM_AGY_123_DIALOG"; fi ;;
      clear-123-idle) if [ "$n" -gt 1 ]; then printf '%s\n' "$FM_AGY_123_IDLE"; else printf '%s\n' "$FM_AGY_123_DIALOG"; fi ;;
      *) printf '%s\n' "${FM_AGY_123_DIALOG:-Do you trust the contents of this project?}";;
    esac ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_test_spawn_home "$dir/home" agy
  fm_git_worktree "$dir/project" "$dir/wt" "agy-$name"
  fm_test_spawn_brief "$dir/home" "agy-$name"
  printf '0\n' > "$dir/count"; : > "$dir/keys"; : > "$dir/launch"
  printf '%s|%s|%s|%s\n' "$dir" "$fakebin" "$mode" "agy-$name"
}
# Recorded agy 1.2.3 pane shapes (live scratch-pane captures, model
# gemini-3.8-flash-high). The 1.1.9 footers never render there, so each fixture
# below deliberately carries no 1.1.9 anchor: the gate must clear on the new
# signals alone, which keeps this regression from going quietly vacuous.
agy_123_busy_capture() {
  printf '%s\n' '⠋ Running command...' '● Bash(echo working: >> state/x.status) (ctrl+o to expand)' '└ Tip: press ctrl+o to expand tool output' '' '╭──────────────────╮' '│ >                │' '╰──────────────────╯'
}
agy_123_idle_capture() {
  printf '%s\n' 'gemini-3.8-flash-high' '' '╭──────────────────╮' '│ >                │' '╰──────────────────╯'
}
agy_trust_dialog_capture() {
  printf '%s\n' 'Accessing workspace:' '' '/tmp/fm-agy-fresh.TO2lcN' '' 'Do you trust the contents of this project?' '' 'Antigravity CLI requires permission to read, edit, and execute files here.' '' '> Yes, I trust this folder' '  No, exit' '' '  Navigate · enter Confirm'
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
test_agy_trust_gate_clears_on_123_mid_turn() {
  local rec dir fakebin mode id out rc busy dialog
  busy=$(agy_123_busy_capture); dialog=$(agy_trust_dialog_capture)
  if printf '%s\n' "$busy" | grep -Eq 'esc to cancel|\? for shortcuts'; then fail "1.2.3 busy fixture must not carry a 1.1.9 anchor"; fi
  rec=$(make_agy_spawn_case 123-busy clear-123-busy); IFS='|' read -r dir fakebin mode id <<<"$rec"
  out=$(FM_AGY_MODE="$mode" FM_AGY_CAPTURE_COUNT="$dir/count" FM_AGY_KEYS="$dir/keys" FM_AGY_LAUNCH="$dir/launch" FM_AGY_123_BUSY="$busy" FM_AGY_123_DIALOG="$dialog" FM_AGY_TRUST_POLLS=4 FM_AGY_POLL_INTERVAL=0 fm_test_run_spawn "$dir/home" "$dir/wt" "$fakebin" "$id" "$dir/project" agy --model gemini-3.8-flash-high --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "agy spawn should recognize the 1.2.3 mid-turn pane: $out"
  [ "$(wc -l < "$dir/keys")" -eq 1 ] || fail "agy trust must send Enter once"
  rm -rf "$dir"
  pass "fm-spawn: agy clears trust on the 1.2.3 Running command pane"
}
test_agy_trust_gate_clears_on_123_idle() {
  local rec dir fakebin mode id out rc idle dialog
  idle=$(agy_123_idle_capture); dialog=$(agy_trust_dialog_capture)
  if printf '%s\n' "$idle" | grep -Eq 'esc to cancel|\? for shortcuts'; then fail "1.2.3 idle fixture must not carry a 1.1.9 anchor"; fi
  rec=$(make_agy_spawn_case 123-idle clear-123-idle); IFS='|' read -r dir fakebin mode id <<<"$rec"
  out=$(FM_AGY_MODE="$mode" FM_AGY_CAPTURE_COUNT="$dir/count" FM_AGY_KEYS="$dir/keys" FM_AGY_LAUNCH="$dir/launch" FM_AGY_123_IDLE="$idle" FM_AGY_123_DIALOG="$dialog" FM_AGY_TRUST_POLLS=4 FM_AGY_POLL_INTERVAL=0 fm_test_run_spawn "$dir/home" "$dir/wt" "$fakebin" "$id" "$dir/project" agy --model gemini-3.8-flash-high --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "agy spawn should recognize the 1.2.3 idle composer pane: $out"
  [ "$(wc -l < "$dir/keys")" -eq 1 ] || fail "agy trust must send Enter once"
  rm -rf "$dir"
  pass "fm-spawn: agy clears trust on the 1.2.3 bare-composer pane"
}
test_agy_trust_gate_fails_bounded() {
  local rec dir fakebin mode id out rc dialog
  dialog=$(agy_trust_dialog_capture)
  rec=$(make_agy_spawn_case blocked blocked); IFS='|' read -r dir fakebin mode id <<<"$rec"
  out=$(FM_AGY_MODE="$mode" FM_AGY_CAPTURE_COUNT="$dir/count" FM_AGY_KEYS="$dir/keys" FM_AGY_LAUNCH="$dir/launch" FM_AGY_123_DIALOG="$dialog" FM_AGY_TRUST_POLLS=2 FM_AGY_POLL_INTERVAL=0 fm_test_run_spawn "$dir/home" "$dir/wt" "$fakebin" "$id" "$dir/project" agy --model gemini-3.8-flash-high --mode no-mistakes --yolo off); rc=$?
  expect_code 1 "$rc" "agy spawn must fail when the trust dialog persists"
  assert_contains "$out" 'did not clear the project-trust gate' "agy trust failure was not explicit"
  [ "$(wc -l < "$dir/keys")" -eq 1 ] || fail "persistent dialog must still send Enter once"
  rm -rf "$dir"
  pass "fm-spawn: agy fails a bounded trust dialog without matching it as ready"
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
test_agy_trust_gate_clears_on_123_mid_turn
test_agy_trust_gate_clears_on_123_idle
test_agy_trust_gate_fails_bounded
test_agy_secondmate_refusal
echo "ALL PASS: fm-agy-harness"
