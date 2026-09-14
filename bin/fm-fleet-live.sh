#!/usr/bin/env bash
# fm-fleet-live.sh - surface the fleet view as a live Herdr tab.
#
# This command does not render fleet state itself. It ensures one dedicated
# Herdr tab exists in a named Herdr session and runs bin/fm-fleet-view.sh in
# that tab's pane, so the rendered view (which already covers the local home and
# every local or remote secondmate home plus their child agents) is visible in
# the current Herdr session. It never parses state, never computes a summary,
# and never arms a watcher, poll, or background loop; refresh is an explicit,
# idempotent re-run driven by the caller (the supervision heartbeat or the
# operator), matching the held fleet-view decision to regenerate on work already
# happening rather than adding a daemon.
#
# Session targeting is always explicit. The real captain fleet runs in Herdr's
# `default` session, so `default` is the fallback target; a `--session` flag,
# FM_FLEET_VIEW_SESSION, or local gitignored config/fleet-view-session selects
# another. tests/fm-fleet-live-herdr-smoke.test.sh drives a named non-default
# lab session, never the default one.
#
# Usage:
#   fm-fleet-live.sh open    [--session <name>] [--label <text>]
#   fm-fleet-live.sh refresh [--session <name>]
#   fm-fleet-live.sh close   [--session <name>]
#   fm-fleet-live.sh status  [--session <name>]
#   fm-fleet-live.sh --help
#
# `open` is idempotent: a live recorded tab is refreshed in place, and a stale
# record is replaced. If the record belongs to a different session than the one
# `open` was given, `open` best-effort closes only that exact recorded tab, in
# the session that recorded it, before creating the new one. `close` closes
# only the exact recorded tab (never a workspace) and clears the record.
# `status` reports the recorded tab and whether it still exists. Every verb
# touches only its own recorded tab, in the session that recorded it, and none
# calls a server-global or session-lifecycle Herdr operation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/fleet-view.herdr"

# shellcheck source=bin/fm-herdr-name-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-herdr-name-lib.sh"

fm_fleet_live_error() { echo "fm-fleet-live: $*" >&2; }

usage() {
  cat <<'EOF'
usage: fm-fleet-live.sh open    [--session <name>] [--label <text>]
       fm-fleet-live.sh refresh [--session <name>]
       fm-fleet-live.sh close   [--session <name>]
       fm-fleet-live.sh status  [--session <name>]

Surface the fleet view as a Herdr tab in a named session (default: "default").
open is idempotent (refreshes a live recorded tab, or best-effort closes a
record's old tab in its own session before opening in a new one); close closes
only the exact recorded tab; status reports the recorded tab. Every verb
touches only its own recorded tab, in the session that recorded it, and none
calls a server-global or session-lifecycle Herdr operation.
EOF
}

# fm_fleet_live_session <explicit>: resolve the named Herdr session.
fm_fleet_live_session() {  # [<explicit>]
  local explicit=${1:-} configured=
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
  if [ -n "${FM_FLEET_VIEW_SESSION:-}" ]; then printf '%s' "$FM_FLEET_VIEW_SESSION"; return 0; fi
  if [ -f "$CONFIG/fleet-view-session" ] && [ ! -L "$CONFIG/fleet-view-session" ]; then
    configured=$(tr -d '[:space:]' < "$CONFIG/fleet-view-session" 2>/dev/null || true)
  fi
  [ -n "$configured" ] || configured=default
  printf '%s' "$configured"
}

fm_fleet_live_label() {
  printf '%s-fleet-view' "$(fm_herdr_name_prefix "$CONFIG")"
}

fm_fleet_live_validate_session() {  # <name>
  case "$1" in
    ''|[!A-Za-z0-9_]*|*[!A-Za-z0-9._-]*)
      fm_fleet_live_error "invalid Herdr session name: '$1'"
      return 1
      ;;
  esac
  return 0
}

# fm_fleet_live_herdr: run herdr against the given session with an explicit
# trailing --session flag, matching the adapter's transport contract.
fm_fleet_live_herdr() {  # <session> <args...>
  local session=$1
  shift
  HERDR_SESSION="$session" herdr "$@" --session "$session"
}

fm_fleet_live_field() {  # <file> <key>
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  awk -F= -v k="$key" '$1 == k { sub("^" k "=", ""); print; exit }' "$file" 2>/dev/null
}

fm_fleet_live_write_record() {  # <session> <workspace> <tab> <pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 tmp
  mkdir -p "$STATE" || return 1
  tmp="$RECORD.$$"
  (
    umask 077
    {
      printf 'session=%s\n' "$session"
      printf 'workspace=%s\n' "$workspace"
      printf 'tab=%s\n' "$tab"
      printf 'pane=%s\n' "$pane"
    } > "$tmp"
  ) || return 1
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

fm_fleet_live_pane_exists() {  # <session> <pane>
  local session=$1 pane=$2 id
  [ -n "$pane" ] || return 1
  id=$(fm_fleet_live_herdr "$session" pane get "$pane" 2>/dev/null \
    | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  [ "$id" = "$pane" ]
}

fm_fleet_live_workspace_for_label() {  # <session> <label>
  local session=$1 label=$2 list ids
  list=$(fm_fleet_live_herdr "$session" workspace list 2>/dev/null) || return 1
  ids=$(printf '%s' "$list" | jq -r --arg label "$label" \
    '(.result.workspaces // [])[] | select(.label == $label) | .workspace_id' 2>/dev/null) || return 1
  [ -n "$ids" ] || return 0
  printf '%s\n' "$ids"
}

fm_fleet_live_tab_for_label() {  # <session> <workspace> <label>
  local session=$1 workspace=$2 label=$3 list ids
  list=$(fm_fleet_live_herdr "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  ids=$(printf '%s' "$list" | jq -r --arg label "$label" \
    '(.result.tabs // [])[] | select(.label == $label) | .tab_id' 2>/dev/null) || return 1
  [ -n "$ids" ] || return 0
  printf '%s\n' "$ids"
}

fm_fleet_live_count() {  # <newline-list>
  printf '%s\n' "${1:-}" | grep -c '[^[:space:]]' || true
}

fm_fleet_live_render_command() {
  printf 'FM_HOME=%s %s' "$(printf '%q' "$FM_HOME")" "$(printf '%q' "$SCRIPT_DIR/fm-fleet-view.sh")"
}

fm_fleet_live_run_renderer() {  # <session> <pane>
  local session=$1 pane=$2 cmd
  cmd=$(fm_fleet_live_render_command)
  fm_fleet_live_herdr "$session" pane run "$pane" "$cmd" >/dev/null 2>&1
}

fm_fleet_live_open() {  # <session> <label>
  local session=$1 label=$2 workspace tab pane ids count out seeded
  if [ -f "$RECORD" ]; then
    local rs rt rp
    rs=$(fm_fleet_live_field "$RECORD" session)
    rt=$(fm_fleet_live_field "$RECORD" tab)
    rp=$(fm_fleet_live_field "$RECORD" pane)
    if [ "$rs" = "$session" ] && fm_fleet_live_pane_exists "$session" "$rp"; then
      fm_fleet_live_run_renderer "$session" "$rp" || {
        fm_fleet_live_error "could not refresh the existing fleet-view tab ($rp)"
        return 1
      }
      printf 'refreshed fleet view tab %s (%s) in session %s\n' "$rt" "$rp" "$session"
      return 0
    fi
    if [ -n "$rs" ] && [ "$rs" != "$session" ] && [ -n "$rt" ]; then
      # The record is bound to a different session. Best-effort close only that
      # exact recorded tab, in the session that recorded it, before discarding
      # the record; never touch any other tab in that session.
      fm_fleet_live_herdr "$rs" tab close "$rt" >/dev/null 2>&1 || true
    fi
    rm -f -- "$RECORD"
  fi

  ids=$(fm_fleet_live_workspace_for_label "$session" "$label") || {
    fm_fleet_live_error "could not list workspaces in session $session"
    return 1
  }
  count=$(fm_fleet_live_count "$ids")
  case "$count" in
    0)
      out=$(fm_fleet_live_herdr "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null) || {
        fm_fleet_live_error "could not create the fleet-view workspace in session $session"
        return 1
      }
      workspace=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
      seeded=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
      ;;
    1) workspace=$(printf '%s\n' "$ids" | head -1) ;;
    *) fm_fleet_live_error "$count workspaces in session $session are labeled '$label'; refusing to guess which one is the view"; return 1 ;;
  esac
  [ -n "$workspace" ] || { fm_fleet_live_error "could not resolve the fleet-view workspace in session $session"; return 1; }

  ids=$(fm_fleet_live_tab_for_label "$session" "$workspace" "$label") || {
    fm_fleet_live_error "could not list tabs in workspace $workspace"
    return 1
  }
  count=$(fm_fleet_live_count "$ids")
  tab=
  pane=
  case "$count" in
    0) ;;
    1)
      tab=$(printf '%s\n' "$ids" | head -1)
      pane=$(fm_fleet_live_herdr "$session" pane list --workspace "$workspace" 2>/dev/null \
        | jq -r --arg tab "$tab" '(.result.panes // [])[] | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1)
      if [ -z "$pane" ]; then
        # A labeled tab with no pane is a husk (its pane died). Close only this
        # exact recorded-by-label tab and create a fresh one; never adopt a
        # pane-less tab.
        fm_fleet_live_herdr "$session" tab close "$tab" >/dev/null 2>&1 || true
        tab=
      fi
      ;;
    *) fm_fleet_live_error "$count tabs in workspace $workspace are labeled '$label'; refusing to guess which one is the view"; return 1 ;;
  esac
  if [ -z "$tab" ] || [ -z "$pane" ]; then
    out=$(fm_fleet_live_herdr "$session" tab create --workspace "$workspace" --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null) || {
      fm_fleet_live_error "could not create the fleet-view tab in session $session"
      return 1
    }
    tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    # Prune only the exact seeded tab returned by this call's own workspace
    # create, once our real tab exists; never infer a tab from its label.
    if [ -n "${seeded:-}" ] && [ "$seeded" != "$tab" ]; then
      fm_fleet_live_herdr "$session" tab close "$seeded" >/dev/null 2>&1 || true
    fi
  fi
  [ -n "$tab" ] && [ -n "$pane" ] || { fm_fleet_live_error "could not resolve the fleet-view tab/pane in session $session"; return 1; }

  fm_fleet_live_write_record "$session" "$workspace" "$tab" "$pane" || {
    fm_fleet_live_error "could not record the fleet-view tab"
    return 1
  }
  fm_fleet_live_run_renderer "$session" "$pane" || {
    fm_fleet_live_error "could not run the fleet view in tab $tab ($pane)"
    return 1
  }
  printf 'opened fleet view tab %s (%s) in session %s\n' "$tab" "$pane" "$session"
}

fm_fleet_live_record_session() { fm_fleet_live_field "$RECORD" session; }
fm_fleet_live_record_tab() { fm_fleet_live_field "$RECORD" tab; }
fm_fleet_live_record_pane() { fm_fleet_live_field "$RECORD" pane; }
fm_fleet_live_record_workspace() { fm_fleet_live_field "$RECORD" workspace; }

fm_fleet_live_refresh() {  # <session>
  local session=$1 pane
  [ -f "$RECORD" ] || { fm_fleet_live_error "no fleet-view tab recorded; run '$0 open' first"; return 1; }
  [ "$(fm_fleet_live_record_session)" = "$session" ] || {
    fm_fleet_live_error "the recorded fleet-view tab belongs to session $(fm_fleet_live_record_session), not $session"
    return 1
  }
  pane=$(fm_fleet_live_record_pane)
  fm_fleet_live_pane_exists "$session" "$pane" || {
    fm_fleet_live_error "the recorded fleet-view tab pane $pane no longer exists; run '$0 open' to recreate it"
    return 1
  }
  fm_fleet_live_run_renderer "$session" "$pane" || { fm_fleet_live_error "could not refresh the fleet view"; return 1; }
  printf 'refreshed fleet view tab %s (%s) in session %s\n' "$(fm_fleet_live_record_tab)" "$pane" "$session"
}

fm_fleet_live_close() {  # <session>
  local session=$1 tab pane
  [ -f "$RECORD" ] || { printf 'no fleet-view tab recorded in session %s\n' "$session"; return 0; }
  [ "$(fm_fleet_live_record_session)" = "$session" ] || {
    fm_fleet_live_error "the recorded fleet-view tab belongs to session $(fm_fleet_live_record_session), not $session"
    return 1
  }
  tab=$(fm_fleet_live_record_tab)
  pane=$(fm_fleet_live_record_pane)
  if ! fm_fleet_live_pane_exists "$session" "$pane"; then
    rm -f -- "$RECORD"
    printf 'fleet-view tab already gone in session %s\n' "$session"
    return 0
  fi
  fm_fleet_live_herdr "$session" tab close "$tab" >/dev/null 2>&1 || {
    fm_fleet_live_error "could not close fleet-view tab $tab in session $session"
    return 1
  }
  rm -f -- "$RECORD"
  printf 'closed fleet view tab %s in session %s\n' "$tab" "$session"
}

fm_fleet_live_status() {  # <session>
  local session=$1 tab pane workspace exists
  if [ ! -f "$RECORD" ]; then printf 'fleet-view: absent in session %s\n' "$session"; return 0; fi
  tab=$(fm_fleet_live_record_tab)
  pane=$(fm_fleet_live_record_pane)
  workspace=$(fm_fleet_live_record_workspace)
  [ "$(fm_fleet_live_record_session)" = "$session" ] || { printf 'fleet-view: recorded for session %s, not %s\n' "$(fm_fleet_live_record_session)" "$session"; return 0; }
  exists=absent
  fm_fleet_live_pane_exists "$session" "$pane" && exists=present
  printf 'fleet-view: %s session=%s workspace=%s tab=%s pane=%s\n' "$exists" "$session" "$workspace" "$tab" "$pane"
}

fm_fleet_live_main() {
  local command=${1:-} session_arg='' label_arg=''
  [ "$#" -ge 1 ] || { usage >&2; return 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) [ "$#" -ge 2 ] || { fm_fleet_live_error "--session requires a value"; return 2; }; session_arg=$2; shift 2 ;;
      --label) [ "$#" -ge 2 ] || { fm_fleet_live_error "--label requires a value"; return 2; }; label_arg=$2; shift 2 ;;
      *) fm_fleet_live_error "unknown argument: $1"; usage >&2; return 2 ;;
    esac
  done
  case "$command" in
    -h|--help|help) usage; return 0 ;;
    open|refresh|close|status) ;;
    *) usage >&2; return 2 ;;
  esac
  command -v herdr >/dev/null 2>&1 || { fm_fleet_live_error "herdr is not installed"; return 1; }
  command -v jq >/dev/null 2>&1 || { fm_fleet_live_error "jq is not installed"; return 1; }
  label=$label_arg
  [ -n "$label" ] || label=$(fm_fleet_live_label)
  session=$(fm_fleet_live_session "$session_arg")
  fm_fleet_live_validate_session "$session" || return 1
  case "$command" in
    open)    fm_fleet_live_open "$session" "$label" ;;
    refresh) fm_fleet_live_refresh "$session" ;;
    close)   fm_fleet_live_close "$session" ;;
    status)  fm_fleet_live_status "$session" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_fleet_live_main "$@"
fi
