#!/usr/bin/env bash
# tests/fm-cursor-submit-confirm.test.sh - regression: a Cursor pane held on a
# pre-composer gate screen must never confirm a submit, and the spawn must
# wait for a proven-ready composer before typing the seeded brief.
#
# cursor-agent 2026.09.02-c22c1a3 boots through pre-composer gates (the
# "Workspace Trust Required" dialog, the "Command Execution" sandbox intro)
# that hold the pane on a non-composer screen. The bare launch used to type
# the seeded brief 0.3s after the launch Enter with no readiness wait, so the
# submit-confirmation read unknown forever (spawn: "did not start a confirmed
# first turn"; steer: "delivery unconfirmed; verdict=unknown"), and a quit
# modal exited the agent outright (later sends: send-failed). The spawn now
# pre-seeds .workspace-trusted and waits for a ready composer, answering each
# dialog once with the launch-consistent choice, before submitting.
#
# Every assertion drives behavior through an executable or public interface:
# real fm-spawn.sh against the spawn-world fake tmux, the real backend submit
# cores against fake CLIs, and the real lib matchers against the same fixture
# screens - never source bytes.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-submit-confirm)

# --- fixture screens (vendor text, shared by every section) ------------------

SCREENS="$TMP_ROOT/screens"
mkdir -p "$SCREENS"

# The blocking trust dialog, documented in
# docs/verification/cursor-agent-adapter.md.
cat > "$SCREENS/trust.txt" <<'EOF'
  ╭───────────────────────────────────────────────╮
  │  ⚠ Workspace Trust Required                     │
  │  Cursor Agent can execute code and access files │
  │  Do you trust the contents of this directory?   │
  │    /tmp/some-worktree                            │
  │  ▶ [a] Trust this workspace                      │
  │    [q] Quit                                      │
  ╰───────────────────────────────────────────────╯
EOF

# The 2026.09 sandbox intro (verified in the installed bundle: title
# "Command Execution", keys a/m/u/q, quit exits 0).
cat > "$SCREENS/sandbox.txt" <<'EOF'
  ╭──────────────────────────────────────────────────────────╮
  │  Command Execution                                         │
  │  Cursor can execute commands safely in a sandbox.          │
  │  Choose how commands should be executed:                   │
  │  ▶ [a] Auto - Commands run in sandbox automatically        │
  │    [m] Manual - All commands require approval              │
  │    [u] Run Everything - All commands run unsandboxed       │
  │    [q] Quit                                                │
  ╰──────────────────────────────────────────────────────────╯
EOF

# An idle cursor composer (plain capture): the verified `→` placeholder row.
cat > "$SCREENS/ready.txt" <<'EOF'
  previous turn output

  → Add a follow-up
  Auto                                            Run Everything
  /tmp/some-worktree
EOF

# A mid-turn cursor pane: the verified busy footer beside the composer row.
cat > "$SCREENS/busy.txt" <<'EOF'
  ⠠⠛ Working
  → Add a follow-up                                ctrl+c to stop
  Auto · 10.4%                                     Run Everything
EOF

# The unauthenticated startup screen (captured live from 2026.09.02-c22c1a3):
# no composer shape at all.
cat > "$SCREENS/login.txt" <<'EOF'
adi@adi2:/tmp/cursor-probe-wt$ cursor-agent --trust --yolo --workspace /tmp/cursor-probe-wt
Tip: You can start the Cursor CLI with `agent` (same as `cursor-agent`).

                                               Cursor Agent
                                               v2026.09.02-c22c1a3
                                               Press any key to log in...
EOF

# --- shared-owner agreement fence -------------------------------------------
# The spawn gate duplicates two vendor literals whose owners live in
# bin/fm-composer-lib.sh (the cursor placeholder alternation and the busy
# token). These assertions run the OWNERS against the same fixture screens
# the spawn tests below feed the gate, so either copy drifting apart fails
# here without any test reading implementation source.

test_lib_owners_agree_with_gate_fixtures() {
  local esc row screen caps verdict
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  # The busy footer is the delivery-busy signal for cursor on every backend.
  fm_busy_lines_match cursor < "$SCREENS/busy.txt" \
    || fail "the shared busy matcher must recognize the mid-turn cursor footer"
  # Non-vacuousness: the gate screens are genuinely different signals, so an
  # owner that matched everything would not pass this fence.
  ! fm_busy_lines_match cursor < "$SCREENS/ready.txt" \
    || fail "an idle composer must not match the cursor busy signal"
  ! fm_busy_lines_match cursor < "$SCREENS/trust.txt" \
    || fail "the trust dialog must not match the cursor busy signal"
  ! fm_busy_lines_match cursor < "$SCREENS/login.txt" \
    || fail "the login screen must not match the cursor busy signal"
  # The idle composer shape the gate waits for is genuinely empty under the
  # shared classifier: the real 2026.08.11 idle row (dim glyph and
  # placeholder, reverse-video cell under the terminal cursor) exercises the
  # ghost-strip, bare-row promotion, and placeholder-owner path end to end.
  # Without this, the gate's ready text would have no classifying owner.
  esc=$(printf '\033')
  row="${esc}[48;2;21;21;21m ${esc}[2m→ ${esc}[0;7m${esc}[48;2;21;21;21mP"
  row="${row}${esc}[0;2m${esc}[48;2;21;21;21mlan, search, build anything${esc}[0m"
  screen=$'transcript\n\n'"$row"
  caps=$'styled=1\ncursor=0\nidentity=1\nrows=20'
  verdict=$(fm_composer_classify_screen "$caps" "$screen")
  [ "$verdict" = empty ] \
    || fail "the shared classifier must read the idle cursor composer as empty, got '$verdict'"
  pass "shared owners agree with the gate fixtures: busy footer is busy, gate screens are not"
}

# --- tmux submit regression --------------------------------------------------
# Faithful reproduction of the observed steer/spawn verdict: a pane held on
# the trust dialog reports unknown (never empty) through the real tmux
# submit core.

make_tmux_submit_fakebin() {  # <dir> <screen> -> echoes fakebin
  local dir=$1 screen=$2 fakebin="$1/fakebin" sent="$1/sent.log"
  mkdir -p "$fakebin"
  : > "$sent"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
SCREEN="$screen"
SENT="$sent"
case "\${1:-}" in
  display-message)
    for a in "\$@"; do
      case "\$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    exit 0 ;;
  capture-pane) cat "\$SCREEN"; exit 0 ;;
  send-keys)
    shift
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        -t) shift 2 ;;
        -l) printf 'literal:%s\n' "\$2" >> "\$SENT"; shift 2 ;;
        *) printf 'key:%s\n' "\$1" >> "\$SENT"; shift ;;
      esac
    done
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s' "$fakebin"
}

# --- tmux submit regression --------------------------------------------------
# Faithful reproduction of the observed verdicts: a pane held on a
# pre-composer gate screen never confirms through the real tmux submit core.
# A blocking dialog reads pending-unproven (the core retries Enter into the
# dialog itself - the hazard the spawn gate removes), while a screen with no
# composer shape at all (login/boot, the observed unknown) reads unknown.

test_tmux_submit_against_gate_screen_never_confirms() {
  local screen_name expected dir fakebin verdict composer_state
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  for screen_name in trust login; do
    case "$screen_name" in
      trust) expected=pending-unproven ;;
      login) expected=unknown ;;
    esac
    dir="$TMP_ROOT/tmux-$screen_name"
    mkdir -p "$dir"
    fakebin=$(make_tmux_submit_fakebin "$dir" "$SCREENS/$screen_name.txt")
    # Pre-check: the gate screen really has no confirmable composer.
    composer_state=$(PATH="$fakebin:$PATH" fm_tmux_composer_state "win" 2>/dev/null)
    [ "$composer_state" = "$expected" ] \
      || fail "pre-check: $screen_name must read $expected, got '$composer_state'"
    # The submit types once and retries Enter only, then reports the screen.
    verdict=$(PATH="$fakebin:$PATH" fm_tmux_submit_core "win" ":" 2 0.01 0.01 2>/dev/null)
    [ "$verdict" = "$expected" ] \
      || fail "a tmux submit into a $screen_name-held pane must report $expected (never empty), got '$verdict'"
    # Non-vacuousness: the verdict came from a real attempt, not a vacuous
    # no-send. The text went out once (never retyped) and Enter was retried.
    grep -Fq 'literal::' "$dir/sent.log" \
      || fail "the $screen_name submit must type the text exactly once"
    [ "$(grep -c '^key:Enter$' "$dir/sent.log")" -ge 1 ] \
      || fail "the $screen_name submit must attempt Enter before reporting $expected"
    [ "$(grep -c '^literal:' "$dir/sent.log")" -eq 1 ] \
      || fail "a swallowed Enter must never cause a retype"
  done
  pass "tmux submit into a gate-held cursor pane never confirms (dialog: pending-unproven, login: unknown)"
}

# --- Herdr submit regression --------------------------------------------------
# Same reproduction through the real Herdr submit core against a canned CLI:
# cursor's always-blocked native state plus a gate-held composer reads
# unknown (never empty).

make_herdr_submit_fakebin() {  # <dir> <screen> -> echoes fakebin
  local dir=$1 screen=$2 fakebin="$1/fakebin" log="$1/herdr.log"
  mkdir -p "$fakebin"
  : > "$log"
  cat > "$fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
SCREEN="$screen"
LOG="$log"
case "\${1:-}" in
  status) printf '{"server":{"running":true}}\n'; exit 0 ;;
  agent) printf '{"result":{"agent":{"agent":"cursor","agent_status":"blocked"}}}\n'; exit 0 ;;
  pane)
    case "\${2:-}" in
      send-text|send-keys) printf '%s\n' "\$*" >> "\$LOG"; exit 0 ;;
      read) cat "\$SCREEN"; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  printf '%s' "$fakebin"
}

# --- Herdr submit regression --------------------------------------------------
# Same reproduction through the real Herdr submit core against a canned CLI:
# cursor's always-blocked native state routes it into the composer branch,
# where a gate-held screen never confirms (dialog: pending-unproven, login:
# unknown).

test_herdr_submit_against_gate_screen_never_confirms() {
  local screen_name expected dir fakebin verdict composer_state
  command -v jq >/dev/null 2>&1 || { pass "skip: jq not found (required by the herdr adapter)"; return 0; }
  for screen_name in trust login; do
    case "$screen_name" in
      trust) expected=pending-unproven ;;
      login) expected=unknown ;;
    esac
    dir="$TMP_ROOT/herdr-$screen_name"
    mkdir -p "$dir" "$dir/home"
    fakebin=$(make_herdr_submit_fakebin "$dir" "$SCREENS/$screen_name.txt")
    verdict=$(FM_HOME="$dir/home" PATH="$fakebin:$PATH" bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_composer_state "labses:pane1" >/dev/null 2>&1
      fm_backend_herdr_send_text_submit "labses:pane1" ":" 2 0.01 0.01
    ' "$ROOT" 2>/dev/null | tail -1)
    [ "$verdict" = "$expected" ] \
      || fail "a herdr submit into a $screen_name-held pane must report $expected (never empty), got '$verdict'"
    # Non-vacuousness: the literal send and an Enter really went out, and the
    # native agent read saw cursor's always-blocked state (the masking
    # condition that routes cursor into the composer branch on Herdr).
    grep -Fq 'send-text' "$dir/herdr.log" \
      || fail "the herdr $screen_name submit must send the text"
    grep -Fq 'send-keys' "$dir/herdr.log" \
      || fail "the herdr $screen_name submit must attempt Enter"
    composer_state=$(FM_HOME="$dir/home" PATH="$fakebin:$PATH" bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_composer_state "labses:pane1"
    ' "$ROOT" 2>/dev/null)
    [ "$composer_state" = "$expected" ] \
      || fail "pre-check: the $screen_name screen must read $expected on herdr, got '$composer_state'"
  done
  pass "herdr submit into a gate-held cursor pane never confirms after a real send attempt"
}

# --- spawn gate end to end ----------------------------------------------------
# Full fm-spawn.sh runs with a scripted pane screen: dialogs are answered
# once with the launch-consistent choice, anything else fails loudly before
# the brief is typed.

make_cursor_gate_case() {  # <name> -> echoes <case_dir|home|proj|wt|fakebin|launch>
  local name=$1 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin="$case_dir/fake"
  mkdir -p "$fakebin"
  fm_test_fake_tmux_spawn "$fakebin"
  # The cursor catalog probe runs through `timeout <secs> <cmd>`; the fake
  # must execute the command (dropping the duration) rather than exit 0, or
  # the catalog reads empty and every --model is refused.
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  printf '%b\n' "Available models\ncursor-grok-4.5-high - Grok 4.5 High"
fi
exit 0
SH
  chmod +x "$fakebin/cursor-agent"
  fm_fake_treehouse "$fakebin"
  fm_test_spawn_home "$home" cursor
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name"
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$launchlog"
}

run_cursor_gate_spawn() {  # <rec> <id> — caller sets FM_FAKE_TMUX_SCREEN_DIR + poll env
  local rec=$1 id=$2 home proj wt fakebin launchlog
  IFS='|' read -r _ home proj wt fakebin launchlog <<EOF
$rec
EOF
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --mode no-mistakes --yolo off --model cursor-grok-4.5-high --effort high
}

write_screens() {  # <screen-dir> <names...> — copies named screens as 1, 2, ...
  local screen_dir=$1 n=0
  shift
  mkdir -p "$screen_dir"
  rm -f "$screen_dir/.count"
  for name in "$@"; do
    n=$((n + 1))
    cp "$SCREENS/$name.txt" "$screen_dir/$n"
  done
}

spawn_user_home() {  # <home> — the throwaway HOME fm_test_run_spawn uses
  printf '%s' "$1/user-home"
}

test_gate_answers_trust_once_then_submits() {
  local rec id out status home wt launchlog user_home slug marker
  id=gate-trust-z1
  rec=$(make_cursor_gate_case "$id")
  IFS='|' read -r _ home _ wt _ launchlog <<EOF
$rec
EOF
  write_screens "$TMP_ROOT/$id-screens" trust ready
  out=$(FM_FAKE_TMUX_SCREEN_DIR="$TMP_ROOT/$id-screens" \
    FM_CURSOR_READY_POLLS=10 FM_CURSOR_POLL_INTERVAL=0.01 \
    run_cursor_gate_spawn "$rec" "$id")
  status=$?
  expect_code 0 "$status" "spawn past an answered trust dialog should succeed, got: $out"
  assert_contains "$out" "spawned $id harness=cursor" "spawn did not report cursor"
  # The dialog answer is exactly one bare `a`, never re-sent into the composer.
  [ "$(grep -c -x 'a' "$launchlog")" -eq 1 ] \
    || fail "the trust dialog must be answered with exactly one 'a', log: $(cat "$launchlog")"
  [ "$(grep -c -x 'u' "$launchlog" || true)" -eq 0 ] \
    || fail "no sandbox-intro answer may be sent when only trust was shown"
  assert_contains "$(cat "$launchlog")" "FIRSTMATE_OP: v1 launch-brief" \
    "the seeded brief must be submitted after the gate clears"
  # The pre-seed marker covers the task worktree before launch.
  user_home=$(spawn_user_home "$home")
  slug=$(printf '%s' "${wt#/}" | tr '/' '-')
  marker="$user_home/.cursor/projects/$slug/.workspace-trusted"
  [ -f "$marker" ] || fail "the trust marker must be pre-seeded at $marker"
  assert_grep "\"workspacePath\":\"$wt\"" "$marker" \
    "the pre-seeded marker must claim the task worktree"
  pass "spawn answers a residual trust dialog once, pre-seeds trust, then submits the brief"
}

test_gate_answers_sandbox_intro_once_then_submits() {
  local rec id out status launchlog
  id=gate-sandbox-z2
  rec=$(make_cursor_gate_case "$id")
  IFS='|' read -r _ _ _ _ _ launchlog <<EOF
$rec
EOF
  write_screens "$TMP_ROOT/$id-screens" sandbox ready
  out=$(FM_FAKE_TMUX_SCREEN_DIR="$TMP_ROOT/$id-screens" \
    FM_CURSOR_READY_POLLS=10 FM_CURSOR_POLL_INTERVAL=0.01 \
    run_cursor_gate_spawn "$rec" "$id")
  status=$?
  expect_code 0 "$status" "spawn past an answered sandbox intro should succeed, got: $out"
  assert_contains "$out" "spawned $id harness=cursor" "spawn did not report cursor"
  # `u` is Run Everything, the launch-consistent choice beside --yolo.
  [ "$(grep -c -x 'u' "$launchlog")" -eq 1 ] \
    || fail "the sandbox intro must be answered with exactly one 'u', log: $(cat "$launchlog")"
  [ "$(grep -c -x 'a' "$launchlog" || true)" -eq 0 ] \
    || fail "no trust answer may be sent when only the intro was shown"
  assert_contains "$(cat "$launchlog")" "FIRSTMATE_OP: v1 launch-brief" \
    "the seeded brief must be submitted after the gate clears"
  pass "spawn answers the sandbox intro once with the Run-Everything choice, then submits"
}

test_gate_fails_loud_on_login_screen_without_typing() {
  local rec id out status home wt launchlog user_home slug marker
  id=gate-login-z3
  rec=$(make_cursor_gate_case "$id")
  IFS='|' read -r _ home _ wt _ launchlog <<EOF
$rec
EOF
  write_screens "$TMP_ROOT/$id-screens" login
  out=$(FM_FAKE_TMUX_SCREEN_DIR="$TMP_ROOT/$id-screens" \
    FM_CURSOR_READY_POLLS=4 FM_CURSOR_POLL_INTERVAL=0.01 \
    run_cursor_gate_spawn "$rec" "$id")
  status=$?
  expect_code 1 "$status" "spawn held on a login screen must fail instead of typing into it"
  assert_contains "$out" "did not reach a ready composer" \
    "the failure must name the unreadiness instead of the submit verdict"
  assert_contains "$out" "trust answered: 0, sandbox-intro answered: 0" \
    "the failure must report the spent answers"
  assert_not_contains "$(cat "$launchlog")" "FIRSTMATE_OP: v1 launch-brief" \
    "the seeded brief must never be typed into a login screen"
  [ "$(grep -c -x 'a' "$launchlog" || true)" -eq 0 ] \
    || fail "no dialog answer may be sent when no dialog was shown"
  assert_grep "failed: cursor did not reach a ready composer" "$home/state/$id.status" \
    "the failure must append a supervisor-actionable task status"
  # Even on the fail path the pre-seed ran before launch.
  user_home=$(spawn_user_home "$home")
  slug=$(printf '%s' "${wt#/}" | tr '/' '-')
  marker="$user_home/.cursor/projects/$slug/.workspace-trusted"
  [ -f "$marker" ] || fail "the trust pre-seed must run even when the gate later fails"
  pass "spawn fails loudly on a login screen and never types the brief into it"
}

test_preseed_keeps_an_already_claimed_workspace() {
  local rec id out status home wt user_home slug marker before
  id=gate-claimed-z4
  rec=$(make_cursor_gate_case "$id")
  IFS='|' read -r _ home _ wt _ _ <<EOF
$rec
EOF
  # An operator marker under another slug already claims this worktree: the
  # pre-seed must not add a second claimant for the transcript binding.
  # Pretty-printed like cursor's own marker, one key per line.
  user_home=$(spawn_user_home "$home")
  mkdir -p "$user_home/.cursor/projects/operator-slug"
  {
    printf '{\n'
    printf '  "trustedAt": "2026-01-01T00:00:00.000Z",\n'
    printf '  "workspacePath": "%s",\n' "$wt"
    printf '  "trustMethod": "manual"\n'
    printf '}\n'
  } > "$user_home/.cursor/projects/operator-slug/.workspace-trusted"
  before=$(cat "$user_home/.cursor/projects/operator-slug/.workspace-trusted")
  write_screens "$TMP_ROOT/$id-screens" ready
  out=$(FM_FAKE_TMUX_SCREEN_DIR="$TMP_ROOT/$id-screens" \
    FM_CURSOR_READY_POLLS=10 FM_CURSOR_POLL_INTERVAL=0.01 \
    run_cursor_gate_spawn "$rec" "$id")
  status=$?
  expect_code 0 "$status" "spawn with a claimed workspace should succeed, got: $out"
  [ "$(cat "$user_home/.cursor/projects/operator-slug/.workspace-trusted")" = "$before" ] \
    || fail "an existing workspace claim must stay byte-identical"
  slug=$(printf '%s' "${wt#/}" | tr '/' '-')
  marker="$user_home/.cursor/projects/$slug/.workspace-trusted"
  [ ! -e "$marker" ] \
    || fail "no second marker may be seeded while the workspace is claimed"
  pass "pre-seed never adds a second claimant for an already-claimed workspace"
}

# --- real-backend no-orphan confirmation --------------------------------------
# The fake-CLI regressions above cannot leak by construction. These two prove
# the same verdicts against real backends and assert the cleanup: no leaked
# panes, workers, or locks.
#
# The tmux case runs always when tmux is installed, on a private socket no
# fleet server can share (TMUX_TMPDIR), with the pane blocked in `cat` so the
# typed text is echoed (delivery proof) but never executed. The Herdr case
# needs a live server and is opt-in like the rest of the live-harness family.

test_real_tmux_submit_unknown_and_cleanup() {
  local dir verdict windows waited=0 echoed=0 wid
  command -v tmux >/dev/null 2>&1 \
    || { pass "skip: tmux not installed (real-backend cleanup has nothing to drive)"; return 0; }
  dir="$TMP_ROOT/real-tmux"
  mkdir -p "$dir/sock"
  (
    unset TMUX
    export TMUX_TMPDIR="$dir/sock"
    tmux kill-server 2>/dev/null || true
    trap 'tmux kill-server 2>/dev/null || true' EXIT
    tmux -f /dev/null new-session -d -s fmcur -x 120 -y 40 cat >/dev/null \
      || fail "could not start the isolated tmux server"
    # Target the stable window id, never the name: a name-based target that
    # no longer resolves is answered from another window, which is exactly
    # the send-failed shape this test must not trip over itself.
    wid=$(tmux display-message -p -t fmcur '#{window_id}' 2>/dev/null) \
      || fail "could not read the isolated window id"
    # `cat` echoes stdin without executing it: wait until it owns the pane.
    waited=0
    while [ "$(tmux display-message -p -t "$wid" '#{pane_current_command}' 2>/dev/null)" != cat ]; do
      waited=$((waited + 1))
      [ "$waited" -lt 40 ] || fail "the isolated pane never started cat"
      sleep 0.25
    done
    # shellcheck source=bin/fm-tmux-lib.sh
    . "$ROOT/bin/fm-tmux-lib.sh"
    verdict=$(fm_tmux_submit_core "$wid" ":" 2 0.05 0.05 2>/dev/null)
    [ "$verdict" = unknown ] \
      || fail "a real tmux submit into a composer-less pane must report unknown, got '$verdict'"
    # The typed text reached the pane (cat echoed it) and was never a composer.
    waited=0
    while ! tmux capture-pane -p -t "$wid" -S -10 2>/dev/null | grep -Fq ':'; do
      waited=$((waited + 1))
      [ "$waited" -lt 16 ] || fail "the submitted text must be visible in the pane (delivery proof)"
      sleep 0.25
    done
    # No strays in our own server before teardown.
    windows=$(tmux list-windows -t fmcur 2>/dev/null | wc -l)
    [ "$windows" -eq 1 ] \
      || fail "the isolated server must hold exactly the test window, got '$windows'"
    tmux kill-server 2>/dev/null || fail "could not stop the isolated tmux server"
    trap - EXIT
    ! tmux ls 2>/dev/null | grep -q . \
      || fail "no tmux server may survive the test on the private socket"
  ) || exit 1
  pass "real tmux submit into a composer-less pane reports unknown with no surviving server"
}

test_real_herdr_lab_submit_unknown_and_cleanup() {
  local lab session ws_json pane target verdict screen waited=0
  # shellcheck source=tests/lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
  # Same opt-in gate shape as the live-harness family: a real Herdr server
  # with credentials is required, so this never runs unasked in CI.
  if [ "${FM_HERDR_CURSOR_SUBMIT_LIVE:-0}" != 1 ]; then
    pass "skip: set FM_HERDR_CURSOR_SUBMIT_LIVE=1 to run the real-Herdr cleanup case"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || { pass "skip: jq not found"; return 0; }
  lab="$ROOT/bin/fm-herdr-lab.sh"
  [ -x "$lab" ] || fail "the Herdr lab helper is not executable at $lab"
  # shellcheck source=tests/herdr-test-safety.sh
  . "$ROOT/tests/herdr-test-safety.sh"
  herdr_forget_inherited_pane
  session=$("$lab" name fm-cursor-submit-live)
  lab_cleanup() {
    "$lab" teardown "$session" || fail "the Herdr lab teardown must verify the default session intact"
  }
  trap lab_cleanup EXIT
  "$lab" provision "$session" || fail "could not provision the isolated Herdr lab"
  ws_json=$("$lab" run "$session" workspace create --cwd "$ROOT" --label fm-cursubmit --no-focus) \
    || fail "could not create the isolated lab workspace"
  pane=$(printf '%s' "$ws_json" | jq -er '.result.root_pane.pane_id') \
    || fail "workspace create did not return a pane id"
  target="$session:$pane"
  # Hold the pane on gate-like text without executing anything submitted:
  # `cat` echoes the typed line and keeps running.
  "$lab" run "$session" pane run "$pane" "cat" >/dev/null \
    || fail "could not start cat in the isolated lab pane"
  # shellcheck source=/dev/null
  . "$ROOT/bin/backends/herdr.sh"
  verdict=$(FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    fm_backend_herdr_send_text_submit "$target" ":" 1 0.05 0.05 2>/dev/null)
  [ "$verdict" = unknown ] \
    || fail "a real herdr submit into a composer-less pane must report unknown, got '$verdict'"
  waited=0
  while :; do
    screen=$("$lab" run "$session" pane read "$pane" --source recent --lines 200 2>/dev/null || true)
    if printf '%s' "$screen" | grep -Fq ':'; then break; fi
    waited=$((waited + 1))
    [ "$waited" -lt 20 ] || fail "the submitted text must be visible in the lab pane (delivery proof)"
    sleep 0.25
  done
  trap - EXIT
  lab_cleanup
  pass "real herdr submit into a composer-less pane reports unknown with lab teardown intact"
}

test_lib_owners_agree_with_gate_fixtures
test_tmux_submit_against_gate_screen_never_confirms
test_herdr_submit_against_gate_screen_never_confirms
test_gate_answers_trust_once_then_submits
test_gate_answers_sandbox_intro_once_then_submits
test_gate_fails_loud_on_login_screen_without_typing
test_preseed_keeps_an_already_claimed_workspace
test_real_tmux_submit_unknown_and_cleanup
test_real_herdr_lab_submit_unknown_and_cleanup
