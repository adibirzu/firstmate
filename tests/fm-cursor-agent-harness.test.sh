#!/usr/bin/env bash
# Behavior tests for the verified cursor-agent crewmate adapter (Cursor CLI 2026.07).
#
# Every literal here is an EMPIRICAL capture from live `cursor-agent --force` panes
# driven through tmux (see docs/verification/cursor-agent-adapter.md):
#   - busy footer:      "⠠⠛ Working ... ctrl+c to stop"   (interrupt = Ctrl-C mid-turn)
#   - idle composer:    "→ Plan, search, build anything" (first) / "→ Add a follow-up"
#   - glyph:            → (U+2192); a verified AGENT glyph in the shared classifier
#                       and bare-row promotion set (fm-composer-lib.sh)
#   - exit:             /quit ;  autonomy: --force (status bar "Run Everything")
#   - launch:           cursor-agent --force [--model M] "<brief>"  (seeds+auto-runs after trust)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"   # brings fm-composer-lib.sh + busy defaults/matcher

classify() { fm_composer_classify_content "$@"; }

# cursor's idle placeholders carry the → glyph in-line, so the idle-RE matches the
# full glyph-prefixed content; → is additionally a verified agent glyph so a bare
# → row (placeholder ghost-stripped away) still reads empty, never dead-shell.
CURSOR_IDLE_RE='^→ (Plan, search, build anything|Add a follow-up)$'

# --- launch template (mechanics half) ---------------------------------------

test_cursor_launch_template_is_pinned() {
  local line="    cursor-agent) printf '%s' 'cursor-agent --force __MODELFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  grep -Fqx -- "$line" "$SPAWN" \
    || fail "fm-spawn: verified cursor-agent launch template missing/changed"
  pass "fm-spawn: cursor-agent launch template is the verified --force argv-seed line"
}

test_existing_launch_templates_untouched() {
  grep -Fq "claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "claude launch template changed"
  grep -Fq "cline -i --tui --auto-approve true __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "cline launch template changed"
  pass "fm-spawn: pre-existing adapters' launch templates are untouched"
}

test_cursor_is_a_known_bare_adapter_name() {
  grep -Fq "|cline|cursor-agent)" "$SPAWN" \
    || fail "fm-spawn: cursor-agent not added to a known-harness allowlist"
  pass "fm-spawn: cursor-agent is recognized as a known bare adapter name"
}

test_cursor_model_flag() {
  # cursor-agent takes --model; effort is a model bracket param, so NO effort flag.
  grep -Fq "|kimi|cline|cursor-agent)" "$SPAWN" \
    || fail "fm-spawn: cursor-agent not in the --model allowlist"
  pass "fm-spawn: cursor-agent gets --model (effort is a model bracket param, no flag)"
}

# --- detection --------------------------------------------------------------

test_cursor_detection_wired() {
  grep -Fq '*cursor*) echo cursor-agent; return ;;' "$HARNESS" \
    || fail "fm-harness: cursor-agent ancestry case missing"
  pass "fm-harness: cursor-agent is detected by process ancestry"
}

# --- busy signature ---------------------------------------------------------

test_cursor_busy_default_defined() {
  [ -n "${FM_TMUX_CURSOR_AGENT_BUSY_REGEX_DEFAULT:-}" ] \
    || fail "FM_TMUX_CURSOR_AGENT_BUSY_REGEX_DEFAULT is not defined"
  pass "fm-tmux-lib: FM_TMUX_CURSOR_AGENT_BUSY_REGEX_DEFAULT is defined"
}

test_cursor_busy_line_matches() {
  printf '%s' '  → Add a follow-up                    ctrl+c to stop' | fm_busy_lines_match cursor-agent \
    || fail "cursor busy footer 'ctrl+c to stop' did not classify busy"
  pass "fm_busy_lines_match: cursor 'ctrl+c to stop' footer reads busy"
}

test_cursor_idle_line_not_busy() {
  if printf '%s' '  → Plan, search, build anything' | fm_busy_lines_match cursor-agent; then
    fail "cursor idle composer must not read busy"
  fi
  pass "fm_busy_lines_match: cursor idle composer does not read busy"
}

test_cursor_does_not_borrow_signatures() {
  # cursor must not borrow pi's 'Working...' or claude's 'esc to interrupt'.
  if printf '%s' 'esc to interrupt' | fm_busy_lines_match cursor-agent; then
    fail "cursor busy regex borrowed 'esc to interrupt'"
  fi
  pass "fm_busy_lines_match: cursor uses only its own verified footer"
}

# --- composer idle classification (via idle-RE, glyph classifier untouched) --

test_cursor_idle_placeholders_read_empty() {
  local p out
  for p in '→ Plan, search, build anything' '→ Add a follow-up'; do
    out=$(classify 0 "$p" "$CURSOR_IDLE_RE" insensitive)
    [ "$out" = empty ] \
      || fail "cursor idle placeholder '$p' must read empty (given idle-RE), got '$out'"
  done
  pass "fm_composer_classify_content: cursor idle placeholders read empty"
}

test_cursor_real_input_reads_pending() {
  local out
  out=$(classify 0 "→ refactor the auth module" "$CURSOR_IDLE_RE" insensitive)
  [ "$out" != empty ] \
    || fail "real cursor composer input must not read empty, got '$out'"
  pass "fm_composer_classify_content: real cursor input does not read empty"
}

# --- shared idle default + glyph promotion cover cursor ---------------------

test_shared_idle_default_covers_cursor() {
  local p b bad=0 up
  for p in '→ Plan, search, build anything' '→ Add a follow-up'; do
    printf '%s' "$p" | grep -qE "$FM_COMPOSER_IDLE_RE_DEFAULT" \
      || fail "shared FM_COMPOSER_IDLE_RE_DEFAULT does not match cursor placeholder '$p'"
  done
  for b in herdr cmux orca; do
    up=$(printf '%s' "$b" | tr '[:lower:]' '[:upper:]')
    grep -Eq "FM_BACKEND_${up}_IDLE_RE=.*FM_COMPOSER_IDLE_RE_DEFAULT" \
      "$ROOT/bin/backends/$b.sh" || { echo "  backend $b IDLE_RE does not use the shared default"; bad=1; }
  done
  [ "$bad" -eq 0 ] || fail "one or more backend IDLE_RE defaults do not use the shared idle default"
  pass "shared idle default covers cursor placeholders and backs herdr/cmux/orca"
}

test_cursor_glyph_is_promoted_and_safe() {
  local out
  printf '%s' '→ Plan, search, build anything' | grep -qE "$FM_COMPOSER_BARE_PROMPT_RE_DEFAULT" \
    || fail "bare-row promotion default does not match a → composer row"
  out=$(classify 0 '→')
  [ "$out" = empty ] || fail "a bare → agent glyph must read empty, got '$out'"
  out=$(classify 0 '>')
  [ "$out" = unknown ] || fail "a bare > shell glyph must stay unknown (dead shell), got '$out'"
  pass "→ is a promoted agent glyph; dead-shell glyphs still never read empty"
}

test_cursor_trust_gate_wired() {
  grep -Fq '.workspace-trusted' "$SPAWN" \
    || fail "fm-spawn: workspace-trust marker pre-seed missing"
  grep -Fq 'Workspace Trust Required' "$SPAWN" \
    || fail "fm-spawn: trust-dialog readiness gate missing"
  pass "fm-spawn: cursor workspace-trust pre-seed + readiness gate are wired"
}

# --- run --------------------------------------------------------------------
test_cursor_launch_template_is_pinned
test_existing_launch_templates_untouched
test_cursor_is_a_known_bare_adapter_name
test_cursor_model_flag
test_cursor_detection_wired
test_cursor_busy_default_defined
test_cursor_busy_line_matches
test_cursor_idle_line_not_busy
test_cursor_does_not_borrow_signatures
test_cursor_idle_placeholders_read_empty
test_cursor_real_input_reads_pending
test_shared_idle_default_covers_cursor
test_cursor_glyph_is_promoted_and_safe
test_cursor_trust_gate_wired
echo "ALL PASS: fm-cursor-agent-harness"
