#!/usr/bin/env bash
# tests/fm-cursor-startup-screen-live-e2e.test.sh - the live Cursor startup
# gate guard (live-harness-optin family).
#
# A cursor spawn is admitted by two vendor-controlled surfaces before any
# brief is typed: the account probe (`cursor-agent --list-models`, read by
# fm_cursor_auth_probe in bin/fm-cursor-lib.sh) and the rendered startup
# screen the readiness gate classifies (fm_cursor_gate_screen for the login,
# trust, and sandbox gates; the shared composer and busy owners for a ready
# pane). Both are vendor text that an auto-update can change silently, which
# is exactly how the fleet lost the Cursor lane for a week in 2026-09: the TUI
# opened on a login screen the gate had no name for, so every spawn spent its
# budget and reported only which dialogs it had not answered. Per
# .agents/skills/firstmate-coding-guidelines the byte fixtures in
# tests/fm-cursor-submit-confirm.test.sh are not enough on their own: this
# guard launches the INSTALLED cursor-agent in an isolated tmux server on a
# throwaway workspace and requires the real first screens to resolve to a
# named gate or a ready composer within the budget, failing by naming
# cursor-agent and `cursor-agent --version` and printing the screen it could
# not name.
#
# It also pins the two signals to each other: a login screen with a probe that
# did not refuse, or a ready composer with a probe that did, is drift in one
# of them and fails here rather than at the next spawn.
#
# No prompt is ever submitted, so no model tokens are spent and the gate is
# default-on wherever cursor-agent and tmux are installed (fm_live_gate):
# FM_CURSOR_STARTUP_LIVE=1 forces it (an absent cursor-agent then fails
# instead of skipping) and =0 disables it. A run that verified nothing fails
# rather than passing vacuously. Refresh docs/verification/runtime-backends.md
# ("Cursor Agent CLI" > "Startup gates and login") from this guard's output
# after any cursor-agent upgrade.
#
# Writes outside the lab: cursor records the throwaway workspace under
# ~/.cursor/projects/<slug>/ exactly as a task spawn would; the guard removes
# that entry when it created it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CURSOR_STARTUP_LIVE tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

CURSOR_BIN=$(fm_cursor_resolve_binary 2>/dev/null) || CURSOR_BIN=''
if [ -z "$CURSOR_BIN" ]; then
  case "${FM_CURSOR_STARTUP_LIVE:-}${FM_LIVE:-}" in
    *1*) printf 'not ok - FM_CURSOR_STARTUP_LIVE was requested but cursor-agent is not installed\n' >&2; exit 1 ;;
  esac
  printf 'skip: live: cursor-agent absent\n'
  exit 0
fi
VERSION=$("$CURSOR_BIN" --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION='version-unknown'

SOCKET="fm-cursor-startup-$$"
SESSION=cursorstart
WIN=cursor
LAB=''
WORKSPACE=''
PROJECTS_ROOT="${CURSOR_PROJECTS_ROOT_OVERRIDE:-$HOME/.cursor/projects}"
CREATED_SLUG_DIRS=()
CHECKED=0

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

# Every tmux call goes to the guard's private server, never the fleet's.
tm() { tmux -L "$SOCKET" "$@"; }

slug_of() {  # <abs-path>
  printf '%s' "${1#/}" | tr '/' '-'
}

cleanup() {
  tm kill-server 2>/dev/null || true
  # cursor writes its projects entry for the workspace while shutting down,
  # so the removal is retried briefly after the kill rather than racing it.
  # The entry is matched on the lab's unique suffix rather than a rebuilt
  # slug, because cursor's own slug rule (dots dropped, long paths hashed)
  # is not reproduced here.
  local dir i=0
  while [ "$i" -lt 6 ]; do
    for dir in "$PROJECTS_ROOT"/*fm-cursor-startup*"${LAB_SUFFIX:-no-such-lab}"*; do
      [ -d "$dir" ] && rm -rf -- "$dir"
    done
    i=$((i + 1))
    sleep 0.5
  done
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}
trap cleanup EXIT

# A short, fresh workspace path: cursor has never seen it, so the trust and
# sandbox gates can render if this build still shows them, and its slug stays
# under cursor's length cap so the created projects entry is predictable.
LAB=$(mktemp -d /tmp/fm-cursor-startup.XXXXXX) || fail "could not create the isolated lab"
LAB_SUFFIX=${LAB##*.}
mkdir -p "$LAB/ws"
git -C "$LAB/ws" init -q || fail "could not initialize the throwaway workspace"
git -C "$LAB/ws" -c user.name=guard -c user.email=guard@local commit -q --allow-empty -m init \
  || fail "could not seed the throwaway workspace"
WORKSPACE=$(cd "$LAB/ws" && pwd -P) || fail "could not resolve the throwaway workspace"
for candidate in "$LAB/ws" "$WORKSPACE"; do
  slug_dir="$PROJECTS_ROOT/$(slug_of "$candidate")"
  [ -e "$slug_dir" ] || CREATED_SLUG_DIRS+=("$slug_dir")
done

# --- signal 1: the account probe ---------------------------------------------
PROBE_RC=0
CATALOG=$(fm_cursor_auth_probe "$CURSOR_BIN") || PROBE_RC=$?
case "$PROBE_RC" in
  0) note "cursor-agent ($VERSION): account probe returned a catalog ($(printf '%s\n' "$CATALOG" | grep -c ' - ') model rows)" ;;
  1) note "cursor-agent ($VERSION): account probe refused with '$FM_CURSOR_AUTH_REQUIRED_RE_DEFAULT' (stored login dead)" ;;
  *) note "cursor-agent ($VERSION): account probe indeterminate (rc $PROBE_RC)" ;;
esac

# --- signal 2: the rendered startup screen ---------------------------------
tm new-session -d -s "$SESSION" -x 160 -y 45 -c "$WORKSPACE" \
  || fail "cursor-agent ($VERSION): could not start the isolated tmux server"
tm new-window -d -t "$SESSION:" -n "$WIN" -c "$WORKSPACE" -- \
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_INVOKED_AS \
  "$CURSOR_BIN" --trust --yolo --workspace "$WORKSPACE" \
  || fail "cursor-agent ($VERSION): could not launch in the isolated tmux server"

CAPS_CURSORLESS=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
classify_cursorless() {  # <styled-screen>
  local verdict
  verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$1")
  if [ "$verdict" = need-identity ]; then
    verdict=$(fm_composer_classify_screen "$CAPS_CURSORLESS" "$1" '' probe-absent)
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

budget=${FM_CURSOR_STARTUP_LIVE_POLLS:-45}
i=0
final=''
plain=''
seen_gates=''
trust_answered=0
sandbox_answered=0
while [ "$i" -lt "$budget" ]; do
  plain=$(tm capture-pane -p -t "$SESSION:$WIN" 2>/dev/null)
  styled=$(tm capture-pane -e -p -t "$SESSION:$WIN" 2>/dev/null | tail -n "$FM_COMPOSER_CAPTURE_LINES")
  gate=$(fm_cursor_gate_screen "$plain") || gate=''
  case "$gate" in
    login)
      final=login
      break
      ;;
    trust)
      case "$seen_gates" in *trust*) ;; *) seen_gates="$seen_gates trust" ;; esac
      if [ "$trust_answered" -eq 0 ]; then
        tm send-keys -t "$SESSION:$WIN" -l a
        trust_answered=1
      fi
      ;;
    sandbox)
      case "$seen_gates" in *sandbox*) ;; *) seen_gates="$seen_gates sandbox" ;; esac
      if [ "$sandbox_answered" -eq 0 ]; then
        tm send-keys -t "$SESSION:$WIN" -l u
        sandbox_answered=1
      fi
      ;;
    *)
      if printf '%s\n' "$plain" | fm_busy_lines_match cursor; then
        final=ready
        break
      fi
      if [ "$(classify_cursorless "$styled")" = empty ]; then
        final=ready
        break
      fi
      ;;
  esac
  i=$((i + 1))
  sleep 1
done

note "cursor-agent ($VERSION): gates seen before the final screen:${seen_gates:- none}"

if [ -z "$final" ]; then
  printf '# cursor-agent pane tail at failure:\n' >&2
  printf '%s\n' "$plain" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fail "cursor-agent ($VERSION): first screen matched no named gate and no ready composer within ${budget}s (trust answered: $trust_answered, sandbox-intro answered: $sandbox_answered); teach fm_cursor_gate_screen or the composer owners the new screen"
fi
CHECKED=$((CHECKED + 1))
pass "cursor-agent ($VERSION): real startup screen resolves to a named state: $final"

# --- the two signals must agree ----------------------------------------------
case "$final:$PROBE_RC" in
  login:1)
    CHECKED=$((CHECKED + 1))
    pass "cursor-agent ($VERSION): login screen and the account probe's refusal agree (stored login is dead; run 'cursor-agent login' to restore the lane)"
    ;;
  login:*)
    fail "cursor-agent ($VERSION): the TUI opened on its login screen but the account probe did not refuse (rc $PROBE_RC); one of the two signals has drifted"
    ;;
  ready:1)
    fail "cursor-agent ($VERSION): the account probe refused with '$FM_CURSOR_AUTH_REQUIRED_RE_DEFAULT' but the TUI reached a composer; the refusal text has drifted or no longer means logged out"
    ;;
  ready:*)
    CHECKED=$((CHECKED + 1))
    pass "cursor-agent ($VERSION): ready composer and a non-refusing account probe agree"
    ;;
esac

[ "$CHECKED" -gt 0 ] || fail "live cursor startup guard verified nothing; refusing a vacuous pass"
pass "live cursor startup guard verified $CHECKED live surface(s)"
