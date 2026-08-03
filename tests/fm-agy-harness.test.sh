#!/usr/bin/env bash
# Behavior tests for the verified agy (Antigravity CLI) adapter.
#
# agy is the first verified harness whose composer is NOT a corner-drawn box: it
# renders a bare `>` between two full-width U+2500 rules. Under the shared safety
# rule a bare shell prompt glyph outside a composer container is a DEAD SHELL, so
# without rule-delimited detection every healthy idle agy worker would read as
# dead. These tests pin that detection, and equally pin that the safety rule still
# holds for a genuinely bare `>` with no rules around it.
#
# They also pin the adapter's other verified contracts: env-marker detection,
# tmux agent-process liveness, and the unverified-busy-source gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMUX_LIB="$ROOT/bin/fm-tmux-lib.sh"
BUSY_LIB="$ROOT/bin/fm-busy-lib.sh"
BACKEND_LIB="$ROOT/bin/fm-backend.sh"
HARNESS="$ROOT/bin/fm-harness.sh"

# shellcheck source=/dev/null
. "$TMUX_LIB"
# shellcheck source=/dev/null
. "$BUSY_LIB"
# shellcheck source=/dev/null
. "$BACKEND_LIB"

TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

cleanup_agy_harness() { rm -rf "$TMP_ROOT"; }
trap cleanup_agy_harness EXIT

# A fake tmux serving a fixture pane plus a cursor row, mirroring the shape the
# composer reader consumes (styled with -e, plain without).
make_fake_tmux() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    start= end= prev=
    for a in "$@"; do
      case "$prev" in
        -S) start=$a ;;
        -E) end=$a ;;
      esac
      prev=$a
    done
    if [ "$start" = "${FM_FAKE_CY:-0}" ] && [ "$end" = "${FM_FAKE_CY:-0}" ]; then
      sed -n "$(( ${FM_FAKE_CY:-0} + 1 ))p" "$FM_FAKE_PANE" 2>/dev/null
    else
      cat "$FM_FAKE_PANE" 2>/dev/null
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# A 60-wide U+2500 run, the shape agy draws above and below its composer row.
agy_rule() { printf '────────────────────────────────────────────────────────────\n'; }

# --- composer: rule-delimited detection -------------------------------------

test_agy_idle_composer_reads_empty() {
  local dir fb pane out
  dir="$TMP_ROOT/agy-idle"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  pane="$dir/pane.txt"
  {
    printf 'some earlier agent output\n'
    agy_rule
    printf '>\n'
    agy_rule
    printf '? for shortcuts\n'
  } > "$pane"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=2 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] \
    || fail "agy's rule-delimited empty composer must read empty, got '$out'"
  pass "fm_tmux_composer_state: agy's rule-delimited '>' reads empty, not a dead shell"
}

test_agy_composer_with_text_reads_pending() {
  local dir fb pane out
  dir="$TMP_ROOT/agy-pending"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  pane="$dir/pane.txt"
  {
    agy_rule
    printf '> /no-mistakes\n'
    agy_rule
    printf '? for shortcuts\n'
  } > "$pane"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] \
    || fail "unsubmitted text in agy's composer must read pending, got '$out'"
  pass "fm_tmux_composer_state: unsubmitted agy composer text reads pending"
}

test_bare_shell_glyph_without_rules_stays_unknown() {
  local dir fb pane out
  dir="$TMP_ROOT/agy-bare"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  pane="$dir/pane.txt"
  # The exact same glyph with NO rules around it is a dead shell prompt. The
  # rule-delimited path must not weaken that safety rule.
  printf 'agent exited\n>\n' > "$pane"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "a bare '>' with no delimiting rules must stay unknown, got '$out'"
  pass "fm_tmux_composer_state: a bare '>' without rules is still a dead shell"
}

test_partial_rule_structure_is_not_a_composer() {
  local dir fb pane out
  dir="$TMP_ROOT/agy-partial"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  pane="$dir/pane.txt"
  # Only one rule, and a mismatched-width pair, must both be refused: the proof
  # requires two non-empty, equal-width, pure-rule rows.
  {
    agy_rule
    printf '>\n'
    printf 'not a rule\n'
  } > "$pane"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "a single delimiting rule must not prove a composer, got '$out'"

  {
    agy_rule
    printf '>\n'
    printf '──────────\n'
  } > "$pane"
  out=$(PATH="$fb:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "mismatched rule widths must not prove a composer, got '$out'"
  pass "fm_tmux_find_rule_composer: partial or mismatched rule structure is refused"
}

# --- harness detection -------------------------------------------------------

test_antigravity_env_marker_detects_agy() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = agy ] \
    || fail "ANTIGRAVITY_AGENT=1 must detect agy, got '$out'"
  pass "fm-harness.sh: ANTIGRAVITY_AGENT=1 detects agy"
}

test_agy_marker_does_not_displace_verified_markers() {
  local out
  # agy's marker is deliberately checked last, so it can never change a
  # previously verified adapter's detection outcome.
  out=$(env -u PI_CODING_AGENT -u GROK_AGENT \
    CLAUDECODE=1 ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = claude ] \
    || fail "an existing claude marker must still win over agy's, got '$out'"
  pass "fm-harness.sh: agy's marker does not displace a verified marker"
}

# --- tmux agent-process liveness --------------------------------------------

test_tmux_classifies_agy_process_alive() {
  local dir fb out
  dir="$TMP_ROOT/agy-live"; mkdir -p "$dir"
  fb="$dir/fakebin"; mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf 'fm-agy-task\n'; exit 0 ;;
  display-message) printf '%s\n' "${FM_FAKE_COMM:-agy}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  out=$(PATH="$fb:$PATH" FM_FAKE_COMM=agy fm_backend_agent_state tmux "s:fm-agy-task")
  [ "$out" = alive ] \
    || fail "a pane running agy must classify alive, got '$out'"
  out=$(PATH="$fb:$PATH" FM_FAKE_COMM=zsh fm_backend_agent_state tmux "s:fm-agy-task")
  [ "$out" = dead ] \
    || fail "a shell pane must still classify dead, got '$out'"
  pass "fm_backend_tmux_agent_state: agy is alive, a shell is still dead"
}

# --- busy-state gate ---------------------------------------------------------

test_agy_busy_state_is_gated_unverified() {
  local dir out
  dir="$TMP_ROOT/agy-busy"; mkdir -p "$dir/state"
  fm_busy_agy_verified \
    && fail "agy's busy gate must stay closed until a semantic source is verified"
  out=$(fm_busy_classify tmux "s:w" agy some-task "$dir/state")
  [ "$out" = "unknown agy-unverified" ] \
    || fail "agy must classify unknown agy-unverified, got '$out'"
  pass "fm_busy_classify: agy reports unknown agy-unverified, never idle"
}

test_agy_trusts_no_busy_sources_while_gated() {
  local out
  out=$(fm_busy_sources_for_harness agy)
  [ -z "$out" ] \
    || fail "a gated agy must trust no busy sources, got '$out'"
  fm_busy_source_trusted agy agy-ls \
    && fail "agy-ls must not be trusted while the gate is closed"
  pass "fm_busy_sources_for_harness: a gated agy trusts no source"
}

test_agy_idle_composer_reads_empty
test_agy_composer_with_text_reads_pending
test_bare_shell_glyph_without_rules_stays_unknown
test_partial_rule_structure_is_not_a_composer
test_antigravity_env_marker_detects_agy
test_agy_marker_does_not_displace_verified_markers
test_tmux_classifies_agy_process_alive
test_agy_busy_state_is_gated_unverified
test_agy_trusts_no_busy_sources_while_gated
