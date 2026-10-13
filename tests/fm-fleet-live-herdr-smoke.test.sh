#!/usr/bin/env bash
# Real-Herdr smoke test for the fleet live-view surface (bin/fm-fleet-live.sh).
#
# Proves against the REAL Herdr binary, in a private named non-default lab
# session, that the surface creates its labeled fleet-view tab, that the pane
# actually runs the renderer and is readable, and that close and teardown leave
# the default session untouched. The unit behavior is covered hermetically in
# tests/fm-fleet-live.test.sh; this file pins the real-binary integration.
#
# Every lifecycle call goes through bin/fm-herdr-lab.sh, which records the
# running default session as a tripwire and refuses any call that would touch
# it. Skips cleanly when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

LAB="$ROOT/bin/fm-herdr-lab.sh"
LIVE="$ROOT/bin/fm-fleet-live.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-live-herdr.XXXXXX")
export FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SESSION=$("$LAB" name fm-fleet-live-smoke) || fail "could not generate a lab session name"
[ "$SESSION" != "default" ] || fail "lab session must never be default"
case "$SESSION" in fm-lab-*) : ;; *) fail "lab session name is not in the lab namespace: $SESSION" ;; esac

cleanup() {
  "$LAB" teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

"$LAB" provision "$SESSION" || fail "could not provision isolated Herdr lab session $SESSION"
pass "real herdr: provisioned an isolated non-default lab session"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"

out=$(FM_HOME="$HOME_DIR" "$LIVE" open --session "$SESSION" 2>&1) || fail "open failed: $out"
case "$out" in "opened fleet view tab "*) : ;; *) fail "open did not report a created tab: $out" ;; esac
RECORD="$HOME_DIR/state/fleet-view.herdr"
[ -f "$RECORD" ] || fail "open did not record the fleet-view tab"
PANE=$(awk -F= '$1 == "pane" { print $2 }' "$RECORD")
TAB=$(awk -F= '$1 == "tab" { print $2 }' "$RECORD")
[ -n "$PANE" ] && [ -n "$TAB" ] || fail "record is missing tab/pane ids"

tab_json=$("$LAB" run "$SESSION" tab list 2>/dev/null) || fail "could not list tabs"
printf '%s' "$tab_json" | jq -e --arg tab "$TAB" '(.result.tabs // [])[] | select(.tab_id == $tab) | .tab_id == $tab' >/dev/null \
  || fail "the created tab does not exist in the lab session: $tab_json"
pass "real herdr: the labeled fleet-view tab exists in the lab session"

# The renderer runs asynchronously in the pane; poll its output a bounded time.
seen=0
i=0
while [ "$i" -lt 60 ]; do
  pane_out=$("$LAB" run "$SESSION" pane read "$PANE" --lines 200 2>/dev/null || true)
  case "$pane_out" in *"# Fleet View"*) seen=1; break ;; esac
  sleep 0.5
  i=$((i + 1))
done
[ "$seen" -eq 1 ] || fail "the fleet view did not become readable in the pane within the settle window"
printf '%s' "$pane_out" | grep -q "Generated: " || fail "the rendered view is missing its observation timestamp"
pass "real herdr: the pane runs the renderer and its fleet view is readable"

out=$(FM_HOME="$HOME_DIR" "$LIVE" close --session "$SESSION" 2>&1) || fail "close failed: $out"
[ ! -f "$RECORD" ] || fail "close did not clear the record"
remaining=$("$LAB" run "$SESSION" tab list 2>/dev/null \
  | jq -r --arg tab "$TAB" '(.result.tabs // [])[] | select(.tab_id == $tab) | .tab_id') || true
[ -z "$remaining" ] || fail "close left the fleet-view tab behind"
pass "real herdr: close removes only the recorded fleet-view tab"

"$LAB" teardown "$SESSION" || fail "guarded teardown failed"
pass "real herdr: guarded teardown removed the lab session with the default session unchanged"
