#!/usr/bin/env bash
# fm-fleet-herdr-collect.sh - read-only per-host Herdr session/agent collector.
#
# Lists every Herdr session and its agents/panes on the local Mac and on every
# registered remote host, then matches each one against firstmate's own task
# records. Anything that cannot be matched to a tracked task is labeled
# "unmanaged" rather than omitted: the whole point is to show sessions and
# agents firstmate did not dispatch or no longer tracks.
#
# READ-ONLY HARD CONSTRAINT: this collector only lists and reads. It invokes
# exactly three Herdr subcommands - `session list`, `agent list`, and
# `pane list` - plus `fm-on.sh` to run its own `--local-only` form on a remote
# home. It never attaches to, sends input to, closes, stops, deletes, starts,
# focuses, renames, or otherwise mutates another session's panes or agents; a
# session this collector does not own is firstmate's to observe only, never to
# touch. Do not add a mutating Herdr call here: future editors must route any
# lifecycle action through bin/fm-control.sh, never through this file.
#
# Output contract: `--json` prints one object with schema `fm-fleet-herdr.v1`:
#   {schema, generated, host, hosts[]} where each host record carries
#   {host, ok, source, sessions[]} or {host, ok:false, error}. A session
#   carries {name, running, agents[], plain_panes[]}. An agent carries
#   {agent, status, cwd, pane_id, tab_id, workspace_id, title,
#    matched_task_id, matched_home, managed}. A plain pane (no detected agent)
#   carries {cwd, pane_id, tab_id, title, managed:false, matched_task_id:null}.
#   managed is true exactly when matched_task_id is non-null.
#
# Matching is by worktree path: an agent/pane whose cwd equals or sits under a
# worktree recorded in a task meta's `worktree=` line matches that task, longest
# worktree wins. Local matching reads this home's state/*.meta plus the state
# dirs of local secondmate records (same Mac, same Herdr server). Remote
# matching runs on the remote side, against that home's own metas, through the
# fixed fm-on.sh remote-command mechanism; the parent only merges.
#
# The collector never fails hard: an unreachable host, a missing herdr binary,
# or a timed-out read becomes an ok:false host record with a reason, so one
# dark station cannot hide the rest of the fleet. Exit non-zero means a usage
# error only.
#
# Usage:
#   fm-fleet-herdr-collect.sh --json [--local-only] [--timeout <seconds>]
#   fm-fleet-herdr-collect.sh --help
#
# Environment:
#   FM_HOME                    operational home (match source for local mode)
#   FM_FLEET_HERDR_TIMEOUT     per-remote-host bound in seconds (default 30)
#   FM_FLEET_HERDR_CALL_TIMEOUT
#                              per-Herdr-call bound in seconds (default 10)
#   FM_HERDR_BIN_OVERRIDE      herdr binary override (tests point at a fake)
#   FM_FLEET_HERDR_ON_BIN      remote-command override (tests point at a fake;
#                              default is this checkout's bin/fm-on.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
HERDR_BIN="${FM_HERDR_BIN_OVERRIDE:-herdr}"
ON_BIN="${FM_FLEET_HERDR_ON_BIN:-$SCRIPT_DIR/fm-on.sh}"
TIMEOUT=${FM_FLEET_HERDR_TIMEOUT:-30}
CALL_TIMEOUT=${FM_FLEET_HERDR_CALL_TIMEOUT:-10}
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=30 ;; esac
case "$CALL_TIMEOUT" in ''|*[!0-9]*|0) CALL_TIMEOUT=10 ;; esac

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-herdr-collect.sh --json [--local-only] [--timeout <seconds>]

Read-only collector: list every Herdr session/agent/pane on this host
(--local-only) or on this host plus every registered remote host, match each
against firstmate task records, and print one fm-fleet-herdr.v1 JSON object.
Unmatched sessions render as unmanaged, never omitted. Only `session list`,
`agent list`, and `pane list` are ever invoked; nothing is attached to,
signalled, or closed.
EOF
}

LOCAL_ONLY=0
JSON_OUT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) JSON_OUT=1; shift ;;
    --local-only) LOCAL_ONLY=1; shift ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "fm-fleet-herdr-collect: --timeout requires a value" >&2; exit 2; }
      TIMEOUT=$2
      case "$TIMEOUT" in ''|*[!0-9]*|0) echo "fm-fleet-herdr-collect: invalid --timeout '$2'" >&2; exit 2 ;; esac
      shift 2
      ;;
    *) echo "fm-fleet-herdr-collect: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ "$JSON_OUT" -eq 1 ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-herdr-collect: jq not found" >&2; exit 2; }

NOW=$(date -u +%s)

# (Herdr invocations below set HERDR_SESSION plus an explicit trailing
# --session flag inline, mirroring bin/fm-fleet-live.sh's transport contract.)

# fm_meta_map_json: emit the worktree-to-task match map as JSON from every
# readable local match source: this home's state/*.meta plus the state dir of
# each local secondmate record (same Mac, same Herdr server, different owner).
# Symlinks are skipped so a planted link can never redirect the match read.
fm_meta_map_json() {
  local tmpmap state_dir meta id worktree harness model home_label line
  tmpmap=$(mktemp "$STATE/.fm-herdr-map.XXXXXX" 2>/dev/null || mktemp /tmp/.fm-herdr-map.XXXXXX) || { printf '[]\n'; return 0; }
  : > "$tmpmap" || { rm -f -- "$tmpmap"; printf '[]\n'; return 0; }
  {
    printf 'LOCAL\t%s\t%s\n' "$STATE" "main"
    if [ -f "$REG" ] && [ ! -L "$REG" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '- '*) ;; *) continue ;; esac
        secondmate_registry_parse_line "$line" 2>/dev/null || continue
        [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
        [ -n "$SECONDMATE_REGISTRY_HOME" ] || continue
        printf 'LOCAL\t%s/state\t%s\n' "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_ID"
      done < "$REG"
    fi
  } | sort -u | while IFS="$(printf '\t')" read -r _kind state_dir home_label; do
    [ -n "${state_dir:-}" ] || continue
    [ -d "$state_dir" ] || continue
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      id=$(basename "$meta" .meta)
      case "$id" in ''|.*) continue ;; esac
      worktree=$(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2- | tail -1)
      [ -n "${worktree:-}" ] || continue
      case "$worktree" in /*) ;; *) continue ;; esac
      harness=$(grep '^harness=' "$meta" 2>/dev/null | cut -d= -f2- | tail -1)
      model=$(grep '^model=' "$meta" 2>/dev/null | cut -d= -f2- | tail -1)
      printf '%s\t%s\t%s\t%s\t%s\n' "$worktree" "$id" "${harness:-unknown}" "${model:-unknown}" "$home_label"
    done
  done >> "$tmpmap" 2>/dev/null
  jq -R -s '
    [ split("\n")[]
      | select(test("\t"))
      | split("\t")
      | select(length >= 5)
      | {worktree: .[0], task_id: .[1], harness: .[2], model: .[3], home: .[4]} ]
  ' "$tmpmap" 2>/dev/null || printf '[]\n'
  rm -f -- "$tmpmap"
}

# fm_collect_local_json <match-map-json>: enumerate running Herdr sessions and
# their agents/panes on this host, matched against the given map. Prints one
# host record. Only session/agent/pane list verbs are invoked.
fm_collect_local_json() {  # <match-map-json>
  local map_json=$1 sessions agents panes name
  if ! command -v "$HERDR_BIN" >/dev/null 2>&1; then
    jq -n --arg host "local" '{host:$host,ok:false,source:"local",error:"herdr not installed",sessions:[]}'
    return 0
  fi
  sessions=$(fm_run_timed "$CALL_TIMEOUT" env HERDR_SESSION=default "$HERDR_BIN" session list --json 2>/dev/null) || sessions=''
  if [ -z "$sessions" ] || ! printf '%s' "$sessions" | jq -e '.sessions' >/dev/null 2>&1; then
    jq -n --arg host "local" '{host:$host,ok:false,source:"local",error:"herdr session list failed",sessions:[]}'
    return 0
  fi
  printf '%s' "$sessions" | jq -c '.sessions[] | select(.running == true) | .name' 2>/dev/null | while read -r name; do
    name=$(printf '%s' "$name" | jq -r '.' 2>/dev/null)
    [ -n "${name:-}" ] || continue
    case "$name" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    agents=$(fm_run_timed "$CALL_TIMEOUT" env HERDR_SESSION="$name" "$HERDR_BIN" agent list --session "$name" 2>/dev/null) || agents=''
    panes=$(fm_run_timed "$CALL_TIMEOUT" env HERDR_SESSION="$name" "$HERDR_BIN" pane list --session "$name" 2>/dev/null) || panes=''
    jq -n \
      --arg name "$name" \
      --argjson map "$map_json" \
      --arg agents "${agents:-null}" \
      --arg panes "${panes:-null}" \
      '
      def matchof($cwd):
        ( [ $map[]
            | .worktree as $wt
            | select($cwd == $wt or ($cwd | startswith($wt + "/")))
          ] | if length == 0 then null else (max_by(.worktree | length)) end );
      (try ($agents | fromjson | .result.agents // []) catch []) as $alist
      | (try ($panes | fromjson | .result.panes // []) catch []) as $plist
      | ([$alist[] | .pane_id] | map(select(. != null))) as $agent_panes
      | { name: $name, running: true,
          agents: [ $alist[]
            | (.foreground_cwd // .cwd // "") as $cwd
            | (matchof($cwd)) as $m
            | { agent: (.agent // "unknown"),
                status: (.agent_status // "unknown"),
                cwd: $cwd,
                pane_id: (.pane_id // "-"),
                tab_id: (.tab_id // "-"),
                workspace_id: (.workspace_id // "-"),
                title: (.terminal_title_stripped // .terminal_title // "-"),
                matched_task_id: ($m.task_id // null),
                matched_home: ($m.home // null),
                matched_harness: ($m.harness // null),
                managed: ($m != null) } ],
          plain_panes: [ $plist[]
            | select(.pane_id as $p | ($agent_panes | index($p)) == null)
            | { cwd: (.foreground_cwd // .cwd // ""),
                pane_id: (.pane_id // "-"),
                tab_id: (.tab_id // "-"),
                title: (.terminal_title_stripped // .terminal_title // "-"),
                managed: false,
                matched_task_id: null } ] }
      '
  done | jq -s --arg host "local" '{host:$host,ok:true,source:"local",error:null,sessions:.}'
}

# fm_collect_remote_json <id> <host>: run the local-only collector on one
# remote home through fm-on.sh, bounded, and merge its host record. A second,
# parallel data-collection path is deliberately not invented here: the remote
# side runs this same file, so the schema and read-only contract are single.
fm_collect_remote_json() {  # <id> <host>
  local id=$1 host=$2 out rc session_json
  out=$(fm_run_timed "$TIMEOUT" "$ON_BIN" "$id" fm-fleet-herdr-collect.sh --json --local-only 2>/dev/null) || out=''
  rc=$?
  if [ "$rc" -eq 124 ] || [ -z "$out" ]; then
    jq -n --arg host "$host" --arg id "$id" \
      '{host:$host,ok:false,source:("remote-secondmate:" + $id),error:"remote collection timed out or unreachable",sessions:[]}'
    return 0
  fi
  session_json=$(printf '%s' "$out" | jq -c '.hosts[0] // empty' 2>/dev/null) || session_json=''
  if [ -z "$session_json" ]; then
    jq -n --arg host "$host" --arg id "$id" \
      '{host:$host,ok:false,source:("remote-secondmate:" + $id),error:"remote collector returned no parseable host record",sessions:[]}'
    return 0
  fi
  printf '%s' "$session_json" | jq -c --arg host "$host" --arg id "$id" \
    '.host = $host | .source = ("remote-secondmate:" + $id)'
}

MAP_JSON=$(fm_meta_map_json)
LOCAL_RECORD=$(fm_collect_local_json "$MAP_JSON")

if [ "$LOCAL_ONLY" -eq 1 ]; then
  jq -n --argjson now "$NOW" --argjson local "$LOCAL_RECORD" \
    '{schema:"fm-fleet-herdr.v1",generated:$now,host:"local",hosts:[$local]}'
  exit 0
fi

HOSTS_FILE=$(mktemp "${TMPDIR:-/tmp}/.fm-herdr-hosts.XXXXXX") || exit 2
printf '%s\n' "$LOCAL_RECORD" | jq -c '.' 2>/dev/null >> "$HOSTS_FILE"
seen_hosts=" local "
if [ -f "$REG" ] && [ ! -L "$REG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" 2>/dev/null || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
    host=$SECONDMATE_REGISTRY_HOST
    id=$SECONDMATE_REGISTRY_ID
    [ -n "${host:-}" ] && [ -n "${id:-}" ] || continue
    case "$seen_hosts" in *" $host "*) continue ;; esac
    seen_hosts="$seen_hosts$host "
    fm_collect_remote_json "$id" "$host" >> "$HOSTS_FILE" 2>/dev/null || true
  done < "$REG"
fi

jq -n --argjson now "$NOW" --slurpfile hosts "$HOSTS_FILE" \
  '{schema:"fm-fleet-herdr.v1",generated:$now,host:"local",hosts:$hosts}'
rc=$?
rm -f -- "$HOSTS_FILE"
exit $rc
