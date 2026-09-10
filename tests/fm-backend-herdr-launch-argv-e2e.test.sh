#!/usr/bin/env bash
# Isolated real-Herdr E2E guard on the launch-replay facts the launch-drift
# detector rests on.
#
# HISTORY, and why this file inverted: Herdr once persisted a `launch_argv` for
# a pane created through `agent start <name> --cwd <dir> --workspace <id>`, and
# an earlier version of this test proved that record survived a real server
# restart. Protocol 20 removes both halves - the pane-creating signature and the
# persisted field - so a worker's flags can no longer be replayed by any
# supported backend. This file now pins the CURRENT truth instead, because that
# absence is exactly the assumption bin/fm-launch-drift-lib.sh is built on:
#
#   1. the pane-creating `agent start --cwd/--workspace` signature is gone;
#   2. no persisted launch-command field exists anywhere in the protocol schema;
#   3. a pane's persisted cwd FOLLOWS the live shell and survives a restart,
#      which is the one axis Herdr does restore.
#
# If a future Herdr reintroduces a persisted launch command, case 2 fails loudly
# naming the version rather than leaving the detector's rationale silently
# stale - at which point the cheaper replay path is worth revisiting.
#
# This costs no model tokens: every assertion reads the protocol schema and the
# persisted session snapshot, so no agent is ever launched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

PROTOCOL=$(herdr api schema 2>/dev/null | awk '/^protocol:/ {print $2}')
case "$PROTOCOL" in
  ''|*[!0-9]*) fail "could not read the Herdr protocol number" ;;
esac
# Below protocol 20 the removed surface may still exist, and the pre-0.8
# behaviour is a different contract this file no longer describes.
[ "$PROTOCOL" -ge 20 ] || { echo "skip: Herdr protocol $PROTOCOL predates the launch-argv removal"; exit 0; }

HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-launch-argv) || fail "could not generate a lab session name"
LAB_CWD=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-launch-argv.XXXXXX")
PROJECT_DIR="$LAB_CWD/project"
WORKTREE_DIR="$LAB_CWD/worktree"
mkdir -p "$PROJECT_DIR" "$WORKTREE_DIR"
STATE_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/sessions/$HERDR_LAB_SESSION/session.json"

cleanup() {
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
  rm -rf "$LAB_CWD"
}
trap cleanup EXIT

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# Read through the lab helper, never a bare herdr call: the helper is the only
# path that guarantees an explicit --session scope.
session_running() {
  lab session list --json 2>/dev/null \
    | jq -r --arg s "$HERDR_LAB_SESSION" '[.sessions[]|select(.name==$s)|.running]|first // "absent"'
}

# Once the lab server is down the helper can no longer reach that session at all,
# so a stopped server reads as either "false" or an unreachable "absent". Both
# mean not running; only a live "true" means the server is still up.
wait_for_session_stopped() {  # <seconds>
  local waited=0
  while [ "$waited" -lt "$1" ]; do
    [ "$(session_running)" = true ] || return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

wait_for_session_running() {  # <seconds>
  local waited=0
  while [ "$waited" -lt "$1" ]; do
    [ "$(session_running)" = true ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

recorded_cwds() {
  jq -r '[.workspaces[].tabs[].panes[].cwd] | join(",")' "$STATE_JSON" 2>/dev/null
}

# --- 1. the pane-creating signature is gone --------------------------------

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
  || fail "could not provision the isolated lab session"

WS=$(lab workspace create --cwd "$PROJECT_DIR" --label argvlab --no-focus 2>/dev/null \
  | jq -r '.result.workspace.id // .result.workspace.workspace_id // empty')
[ -n "$WS" ] || fail "lab workspace was not created"

if lab agent start argvold --cwd "$PROJECT_DIR" --workspace "$WS" --no-focus -- true >/dev/null 2>&1; then
  fail "$HERDR_VERSION accepted the pane-creating agent-start signature; the launch-argv removal this suite documents no longer holds"
fi
pass "herdr launch-argv: the pane-creating agent-start signature is absent on $HERDR_VERSION"

# --- 2. no persisted launch command exists in the protocol -----------------

SCHEMA=$(herdr api schema --json 2>/dev/null) || fail "could not read the Herdr JSON schema"

# agent.start attaches to an existing pane: it takes no cwd and no workspace.
START_REQUIRED=$(printf '%s' "$SCHEMA" | jq -r '.schemas.request."$defs".AgentStartParams.required | join(",")' 2>/dev/null)
[ "$START_REQUIRED" = "name,kind,pane_id" ] \
  || fail "agent.start's required parameters changed: expected name,kind,pane_id, got '$START_REQUIRED'"

snapshot_keys=$(printf '%s' "$SCHEMA" | jq -r '.schemas.success_response."$defs".SessionSnapshot.properties | keys | join(",")' 2>/dev/null)
pane_keys=$(printf '%s' "$SCHEMA" | jq -r '.schemas.success_response."$defs".PaneInfo.properties | keys | join(",")' 2>/dev/null)
agent_keys=$(printf '%s' "$SCHEMA" | jq -r '.schemas.success_response."$defs".AgentInfo.properties | keys | join(",")' 2>/dev/null)
agent_session_keys=$(printf '%s' "$SCHEMA" | jq -r '.schemas.success_response."$defs".AgentSessionInfo.properties | keys | join(",")' 2>/dev/null)

[ "$snapshot_keys" = "agents,focused_pane_id,focused_tab_id,focused_workspace_id,layouts,panes,protocol,tabs,version,workspaces" ] \
  || fail "$HERDR_VERSION changed the persisted session snapshot shape ($snapshot_keys); a replay field may have returned - revisit docs/herdr-backend.md 'Launch-argv replay'"
[ "$pane_keys" = "agent,agent_session,agent_status,cwd,display_agent,focused,foreground_cwd,label,pane_id,revision,scroll,state_labels,tab_id,terminal_id,terminal_title,terminal_title_stripped,title,tokens,workspace_id" ] \
  || fail "$HERDR_VERSION changed the persisted pane record shape ($pane_keys); a replay field may have returned - revisit docs/herdr-backend.md 'Launch-argv replay'"
[ "$agent_keys" = "agent,agent_session,agent_status,cwd,display_agent,focused,foreground_cwd,interactive_ready,launch_pending,name,pane_id,revision,screen_detection_skipped,state_change_seq,state_labels,tab_id,terminal_id,terminal_title,terminal_title_stripped,title,tokens,workspace_id" ] \
  || fail "$HERDR_VERSION changed the persisted agent record shape ($agent_keys); a replay field may have returned - revisit docs/herdr-backend.md 'Launch-argv replay'"
[ "$agent_session_keys" = "agent,kind,source,value" ] \
  || fail "$HERDR_VERSION changed the persisted agent-session shape ($agent_session_keys); a replay field may have returned - revisit docs/herdr-backend.md 'Launch-argv replay'"
pass "herdr launch-argv: protocol $PROTOCOL persists no launch command, only a live process read and a start response"

# --- 3. the persisted cwd follows the live shell and survives a restart ----

TAB=$(lab tab create --workspace "$WS" --cwd "$PROJECT_DIR" --label argvcwd --no-focus 2>/dev/null)
PANE=$(printf '%s' "$TAB" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE" ] || fail "lab task tab did not return a pane id"

lab pane run "$PANE" "cd $WORKTREE_DIR" >/dev/null 2>&1 \
  || fail "the lab pane did not accept the directory change"
sleep "${FM_HERDR_ARGV_SETTLE:-8}"

case ",$(recorded_cwds)," in
  *",$WORKTREE_DIR,"*) ;;
  *) fail "the persisted pane cwd did not follow the live shell: got '$(recorded_cwds)'" ;;
esac
pass "herdr launch-argv: a pane's persisted cwd follows the live shell"

# A real stop and a real start, not a reload: the second provision is a fresh
# server process that has only the persisted snapshot to work from.
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
  || fail "guarded lab stop failed"
wait_for_session_stopped "${FM_HERDR_ARGV_STOP_TIMEOUT:-30}" \
  || fail "the lab server did not actually stop; this would not be a real restart"

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
  || fail "could not restart the lab session server"
wait_for_session_running "${FM_HERDR_ARGV_START_TIMEOUT:-30}" \
  || fail "the lab server did not come back up after the restart"
sleep "${FM_HERDR_ARGV_RESTART_SETTLE:-10}"

case ",$(recorded_cwds)," in
  *",$WORKTREE_DIR,"*) ;;
  *) fail "the pane cwd did not survive a real server restart: got '$(recorded_cwds)'" ;;
esac
pass "herdr launch-argv: the followed cwd survives a real server restart"
