#!/usr/bin/env bash
# Behavior tests for the verified GitHub Copilot CLI crewmate adapter (1.0.75).
#
# Every literal in this file is an EMPIRICAL capture from a live `copilot -i`
# pane driven through tmux (see docs/verification/copilot-adapter.md):
#   - busy footer:      " ◎ Working esc interrupt"  (optional " · <size>" infix;
#                        compound anchor 'Working.*esc interrupt' - bare
#                        "esc interrupt" collides with opencode's own anchor)
#   - idle composer:    bare "❯" glyph, NO placeholder text of any kind
#   - agent glyph:      ❯ (U+276F, already a verified empty-composer glyph)
#   - launch:           copilot --allow-all --no-ask-user [--model M]
#                        [--reasoning-effort E] -i "<brief>"
#   - interrupt:         single Ctrl-C mid-turn; exit: /exit (Esc is a no-op)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"   # brings fm-composer-lib.sh + busy defaults/matcher

classify() { fm_composer_classify_content "$@"; }

# --- launch template (mechanics half) ---------------------------------------

test_copilot_launch_template_is_pinned() {
  local line="    copilot) printf '%s' 'copilot --allow-all --no-ask-user __MODELFLAG____EFFORTFLAG__-i \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  grep -Fqx -- "$line" "$SPAWN" \
    || fail "fm-spawn: verified copilot launch template missing/changed"
  pass "fm-spawn: copilot launch template is the verified argv-seed line"
}

test_existing_launch_templates_untouched() {
  grep -Fq "claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "claude launch template changed"
  grep -Fq "cline -i --tui --auto-approve true __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "cline launch template changed"
  grep -Fq 'cursor-agent --force __MODELFLAG__' "$SPAWN" \
    || fail "cursor-agent launch template changed"
  pass "fm-spawn: pre-existing adapters' launch templates are untouched"
}

test_copilot_is_a_known_bare_adapter_name() {
  # copilot must be accepted as a bare adapter name, not routed to the raw-launch hatch.
  grep -Fq "|cline|cursor-agent|copilot)" "$SPAWN" \
    || fail "fm-spawn: copilot not added to a known-harness allowlist"
  pass "fm-spawn: copilot is recognized as a known bare adapter name"
}

test_copilot_model_and_effort_flags() {
  # copilot takes --model and maps effort to --reasoning-effort, accepting the
  # full shared low|medium|high|xhigh|max vocabulary (no tier omitted, unlike
  # cline/codex/grok).
  grep -Fq "|cline|cursor-agent|copilot)" "$SPAWN" \
    || fail "fm-spawn: copilot not in the --model allowlist"
  grep -Fq "low|medium|high|xhigh|max) printf -- '--reasoning-effort %s '" "$SPAWN" \
    || fail "fm-spawn: copilot effort->--reasoning-effort mapping missing"
  pass "fm-spawn: copilot gets --model and effort->--reasoning-effort (low|medium|high|xhigh|max)"
}

# --- detection --------------------------------------------------------------

test_copilot_detection_wired() {
  # copilot is a standalone compiled (Bun) binary whose /proc/<pid>/comm is
  # literally "MainThread" - never "copilot" or "node"/"python" - so detection
  # needs its own ancestry case (args-substring fallback) in addition to the
  # direct comm case and the verified COPILOT_CLI=1 env marker.
  grep -Fq '*copilot*) echo copilot; return ;;' "$HARNESS" \
    || fail "fm-harness: copilot direct ancestry case missing"
  grep -Fq 'MainThread)' "$HARNESS" \
    || fail "fm-harness: copilot MainThread ancestry fallback missing"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  grep -Fq '[ "${COPILOT_CLI:-}" = "1" ]' "$HARNESS" \
    || fail "fm-harness: copilot COPILOT_CLI=1 env marker missing"
  pass "fm-harness: copilot is detected by env marker and process ancestry (incl. MainThread fallback)"
}

# --- busy signature (knowledge half) ----------------------------------------

test_copilot_busy_default_defined() {
  [ -n "${FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT:-}" ] \
    || fail "FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT is not defined"
  pass "fm-tmux-lib: FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT is defined"
}

test_copilot_busy_line_matches() {
  # Real captured busy lines, with and without the tool-output-size infix.
  printf '%s' ' ◎ Working esc interrupt                                GPT-5.6 Terra' | fm_busy_lines_match copilot \
    || fail "copilot busy footer 'Working esc interrupt' did not classify busy"
  printf '%s' ' ◎ Working · 786 B esc interrupt                        GPT-5.6 Terra' | fm_busy_lines_match copilot \
    || fail "copilot busy footer with size infix did not classify busy"
  pass "fm_busy_lines_match: copilot 'Working.*esc interrupt' footer reads busy (with or without size infix)"
}

test_copilot_idle_line_not_busy() {
  if printf '%s' '❯' | fm_busy_lines_match copilot; then
    fail "copilot idle composer must not read busy"
  fi
  if printf '%s' ' / commands · ? help · tab next tab                    GPT-5.6 Terra' | fm_busy_lines_match copilot; then
    fail "copilot idle status bar must not read busy"
  fi
  pass "fm_busy_lines_match: copilot idle composer/status bar does not read busy"
}

test_copilot_does_not_borrow_signatures() {
  # G4: the copilot matcher must reject every foreign harness's literal token.
  # "esc interrupt" alone (no "Working") is opencode's own exact anchor - the
  # near-miss this compound regex exists to avoid.
  local foreign
  for foreign in 'esc to interrupt' 'esc interrupt' 'Working...' 'Ctrl+c:cancel' 'esc to cancel' 'ctrl+c to stop'; do
    if printf '%s' "$foreign" | fm_busy_lines_match copilot; then
      fail "copilot busy regex borrowed foreign token '$foreign'"
    fi
  done
  pass "fm_busy_lines_match: copilot uses only its own verified compound footer, no foreign borrow"
}

# --- composer idle classification -------------------------------------------

test_copilot_idle_placeholders_read_empty() {
  # copilot has NO idle placeholder text of any kind (verified: first-ready and
  # post-turn composer rows are byte-identical - just the bare ❯ glyph). Unlike
  # cline/cursor-agent there is no placeholder string to run through an idle-RE;
  # the bare agent glyph alone (already shared with claude) is what must read
  # empty, bordered or bare.
  local out
  out=$(classify 1 '❯')
  [ "$out" = empty ] || fail "bordered bare copilot composer glyph must read empty, got '$out'"
  out=$(classify 0 '❯')
  [ "$out" = empty ] || fail "unbordered bare copilot composer glyph must read empty, got '$out'"
  pass "fm_composer_classify_content: copilot's bare ❯ composer reads empty (no placeholder text exists)"
}

test_copilot_real_input_reads_pending() {
  local out
  out=$(classify 1 "fix the null-pointer in the parser")
  [ "$out" = pending ] \
    || fail "real copilot composer input must read pending, got '$out'"
  pass "fm_composer_classify_content: real copilot input still reads pending"
}

# --- shared fleet-wide defaults untouched (regression fence) ----------------

test_backend_idle_re_defaults_cover_copilot() {
  # copilot needed NO new placeholder in FM_COMPOSER_IDLE_RE_DEFAULT and NO
  # backend IDLE_RE override (verified; docs/verification/copilot-adapter.md
  # "Ready / idle composer" - there is no placeholder text to strip). This is
  # the PRD's coverage check adapted to that finding: prove the bare ❯ glyph
  # stays classified through the shared, untouched fleet-wide defaults rather
  # than needing a per-backend addition.
  printf '%s' '❯' | grep -qE "$FM_COMPOSER_BARE_PROMPT_RE_DEFAULT" \
    || fail "shared FM_COMPOSER_BARE_PROMPT_RE_DEFAULT does not match copilot's ❯ composer row"
  local b bad=0 up
  for b in herdr cmux orca; do
    up=$(printf '%s' "$b" | tr '[:lower:]' '[:upper:]')
    grep -Eq "FM_BACKEND_${up}_IDLE_RE=.*FM_COMPOSER_IDLE_RE_DEFAULT" \
      "$ROOT/bin/backends/$b.sh" || { echo "  backend $b IDLE_RE does not use the shared default"; bad=1; }
  done
  [ "$bad" -eq 0 ] || fail "one or more backend IDLE_RE defaults do not use the shared idle default"
  pass "copilot's bare-glyph composer is covered by the untouched shared fleet-wide defaults"
}

# --- run --------------------------------------------------------------------
test_copilot_launch_template_is_pinned
test_existing_launch_templates_untouched
test_copilot_is_a_known_bare_adapter_name
test_copilot_model_and_effort_flags
test_copilot_detection_wired
test_copilot_busy_default_defined
test_copilot_busy_line_matches
test_copilot_idle_line_not_busy
test_copilot_does_not_borrow_signatures
test_copilot_idle_placeholders_read_empty
test_copilot_real_input_reads_pending
test_backend_idle_re_defaults_cover_copilot
echo "ALL PASS: fm-copilot-harness"
