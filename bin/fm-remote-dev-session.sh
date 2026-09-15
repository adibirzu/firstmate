#!/usr/bin/env bash
# Establish or reattach one registered station's remote development session and
# persist its continuity references.
#
# Usage:
#   fm-remote-dev-session.sh open    <station> (--secondmate <id> | --task <id>) [options]
#   fm-remote-dev-session.sh recover <station> [options]
#   fm-remote-dev-session.sh attach  <station> [--exec]
#   fm-remote-dev-session.sh status  <station>
#   fm-remote-dev-session.sh list [--json]
#   fm-remote-dev-session.sh check   <station> (--secondmate <id> | --task <id>) [options]
#   fm-remote-dev-session.sh --help
#
# Options:
#   --secondmate <id>       target a registered second mate's own session
#   --task <id>             target an existing task record's session
#   --project <name>        project name for the record and equivalence gate
#   --backend <herdr|tmux>  explicit session backend (default: config then herdr)
#   --session <name>        named session (default: fm-remote)
#   --branch <name>         intended branch for the equivalence gate
#   --repo <path>           git clone the gate converges (default: the task worktree)
#   --repair                run the readiness repair, then re-check read-only
#   --print                 dry run: run read-only gates and print the plan only
#   --exec                  attach runs the attach command instead of printing it
#
# A remote development session is a Firstmate task or second mate running on a
# registered station over the existing SSH/fm-on route. This command never
# launches a raw process: `open` and `recover` reattach a live recorded endpoint
# or relaunch one through the ordinary record paths (`fm-spawn --secondmate` for
# a mate, `fm-control relaunch` for a task). It refuses duplicate or stale work
# before launch and never forces, stashes, or discards anything.
#
# Backend selection is explicit. herdr is the default and the only backend a
# remote second mate uses (docs/remote-secondmates.md). tmux is reachable only by
# `--backend tmux` or a local config/remote-dev-backend value, and a herdr
# failure is never silently retried on tmux. docs/remote-dev-sessions.md owns the
# full contract, the record schema, and the exact attach/reconnect commands.
#
# Exit status: 0 success; 1 operational failure; 2 invalid use; 3 duplicate work;
# 4 stale work; 5 readiness gap.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-remote-dev-session-lib.sh
. "$SCRIPT_DIR/fm-remote-dev-session-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

SSH_BIN=${FM_RDS_SSH:-ssh}
HERDR_BIN=${FM_RDS_HERDR:-herdr}
TMUX_BIN=${FM_RDS_TMUX:-tmux}
FM_ON=${FM_RDS_FM_ON:-$SCRIPT_DIR/fm-on.sh}
SPAWN=${FM_RDS_SPAWN:-$SCRIPT_DIR/fm-spawn.sh}
CONTROL=${FM_RDS_CONTROL:-$SCRIPT_DIR/fm-control.sh}
CREW_STATE=${FM_RDS_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}
GIT=${FM_RDS_GIT:-git}
TIMEOUT=${FM_RDS_TIMEOUT:-15}
LOCAL_NAMES=${FM_RDS_LOCAL_NAMES:-local mini}
JQ=${FM_RDS_JQ:-jq}
SESSION_DEFAULT=$(fm_rds_default_session)

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'fm-remote-dev-session: %s\n' "$1" >&2; exit 2; }
fail() { printf 'fm-remote-dev-session: %s\n' "$1" >&2; exit 1; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

ACTION=$1
shift

STATION=
TARGET_KIND=
TARGET_ID=
PROJECT=
BACKEND_FLAG=
SESSION_FLAG=
BRANCH=
REPO=
REPAIR=0
PRINT=0
EXEC=0
LIST_JSON=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --secondmate)
      [ "$#" -ge 2 ] || die "--secondmate requires an id"
      TARGET_KIND=secondmate; TARGET_ID=$2; shift 2 ;;
    --task)
      [ "$#" -ge 2 ] || die "--task requires an id"
      TARGET_KIND=task; TARGET_ID=$2; shift 2 ;;
    --project)
      [ "$#" -ge 2 ] || die "--project requires a name"
      PROJECT=$2; shift 2 ;;
    --backend)
      [ "$#" -ge 2 ] || die "--backend requires a value"
      BACKEND_FLAG=$2; shift 2 ;;
    --session)
      [ "$#" -ge 2 ] || die "--session requires a name"
      SESSION_FLAG=$2; shift 2 ;;
    --branch)
      [ "$#" -ge 2 ] || die "--branch requires a name"
      BRANCH=$2; shift 2 ;;
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires a path"
      REPO=$2; shift 2 ;;
    --repair) REPAIR=1; shift ;;
    --print) PRINT=1; shift ;;
    --exec) EXEC=1; shift ;;
    --json) LIST_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown option: $1" ;;
    *)
      [ -z "$STATION" ] || die "only one station may be named"
      STATION=$1; shift ;;
  esac
done

if [ -n "$TARGET_ID" ]; then
  case "$TARGET_ID" in
    *[!A-Za-z0-9._-]*) die "target id must be letters, digits, dot, underscore, or dash: $TARGET_ID" ;;
  esac
fi

case "$ACTION" in
  open|recover|check|attach|status)
    [ -n "$STATION" ] || die "'$ACTION' requires a station"
    case "$STATION" in ''|-*|*[!A-Za-z0-9._-]*) die "station must be letters, digits, dot, underscore, or dash: $STATION" ;; esac
    ;;
  list) ;;
  *) die "unknown action: $ACTION" ;;
esac

case "$ACTION" in
  attach|status|list)
    [ -z "$TARGET_ID" ] || die "'$ACTION' does not take a target"
    ;;
esac
if [ "$ACTION" = list ] && [ -n "$STATION" ]; then
  die "'list' does not take a station"
fi
if [ "$PRINT" -eq 1 ] && [ "$REPAIR" -eq 1 ]; then
  die "--print cannot be combined with --repair"
fi

# --- record listing (no station needed) -------------------------------------

if [ "$ACTION" = list ]; then
  DIR=$(fm_rds_record_dir "$STATE")
  if [ "$LIST_JSON" -eq 1 ]; then
    command -v "$JQ" >/dev/null 2>&1 || fail "jq is required for --json"
    if [ ! -d "$DIR" ]; then
      printf '{"schema":"fm-remote-dev-session-list.v1","records":[]}\n'
      exit 0
    fi
    records='[]'
    for f in "$DIR"/*.session; do
      [ -f "$f" ] || continue
      fm_rds_record_read "$f" >/dev/null 2>&1 || continue
      one=$(fm_rds_record_read "$f" | "$JQ" -Rn '[inputs | capture("^(?<k>[^=]*)=(?<v>.*)$") | {(.k): .v}] | add')
      records=$(printf '%s\n%s\n' "$records" "$one" | "$JQ" -s '.[0] + [.[1]]')
    done
    printf '%s' "$records" | "$JQ" -c '{schema:"fm-remote-dev-session-list.v1",records:.}'
    exit 0
  fi
  if [ ! -d "$DIR" ]; then
    printf 'remote-dev-session: no records under %s\n' "$DIR"
    exit 0
  fi
  for f in "$DIR"/*.session; do
    [ -f "$f" ] || continue
    fm_rds_record_read "$f" >/dev/null 2>&1 || { printf 'remote-dev-session: malformed record %s\n' "$f" >&2; continue; }
    printf 'station=%s backend=%s session=%s task=%s project=%s\n' \
      "$(fm_rds_record_get "$f" station)" \
      "$(fm_rds_record_get "$f" backend)" \
      "$(fm_rds_record_get "$f" session)" \
      "$(fm_rds_record_get "$f" task_id)" \
      "$(fm_rds_record_get "$f" project)"
  done
  exit 0
fi

# --- station resolution -----------------------------------------------------
#
# A station is one SSH host (or the local host). Remote routes come from
# data/secondmates.md exactly as bin/fm-station-idle.sh resolves them: the host
# is `<station>` or `<station>-<suffix>`. The first matching route supplies the
# SSH alias, remote home, code root, and route id.

STATION_LOCAL=0
STATION_HOST=
ROUTE_ID=
ROUTE_HOME=

resolve_station() {  # <station>
  local station=$1 line
  local matches=0
  STATION_LOCAL=0
  STATION_HOST=
  ROUTE_ID=
  ROUTE_HOME=
    case " $LOCAL_NAMES " in
    *" $station "*)
      STATION_LOCAL=1
      STATION_HOST=$station
      return 0
      ;;
  esac
  [ -f "$REG" ] && [ ! -L "$REG" ] || fail "no safe secondmate registry at $REG"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
    case "$SECONDMATE_REGISTRY_HOST" in
      "$station"|"$station"-*) ;;
      *) continue ;;
    esac
    matches=$((matches + 1))
    if [ "$matches" -eq 1 ]; then
      STATION_HOST=$SECONDMATE_REGISTRY_HOST
      ROUTE_ID=$SECONDMATE_REGISTRY_ID
      ROUTE_HOME=$SECONDMATE_REGISTRY_HOME
    fi
  done < "$REG"
  if [ "$matches" -eq 0 ]; then
    fail "no registered remote station for $station"
  fi
  return 0
}

# --- backend and session ----------------------------------------------------

RESOLVED_BACKEND=
RESOLVED_SESSION=
ATTACH_COMMAND=
RECOVERY_BACKEND=
RECOVERY_SESSION=

resolve_backend_and_session() {
  local rc=0
  if [ -n "$BACKEND_FLAG" ]; then
    RESOLVED_BACKEND=$(fm_rds_resolve_backend "$BACKEND_FLAG" "$CONFIG/remote-dev-backend") || rc=$?
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -eq 2 ] && exit 2
      fail "could not resolve the session backend"
    fi
  elif [ -n "$RECOVERY_BACKEND" ]; then
    RESOLVED_BACKEND=$RECOVERY_BACKEND
    fm_rds_backend_known "$RESOLVED_BACKEND" \
      || fail "continuity record has an unknown backend"
  else
    RESOLVED_BACKEND=$(fm_rds_resolve_backend '' "$CONFIG/remote-dev-backend") || rc=$?
    if [ "$rc" -ne 0 ]; then
      [ "$rc" -eq 2 ] && exit 2
      fail "could not resolve the session backend"
    fi
  fi
  RESOLVED_SESSION=${SESSION_FLAG:-${RECOVERY_SESSION:-$SESSION_DEFAULT}}
  case "$RESOLVED_SESSION" in ''|*[!A-Za-z0-9._-]*) die "session name must be letters, digits, dot, underscore, or dash: $RESOLVED_SESSION" ;; esac
  ATTACH_COMMAND=$(fm_rds_attach_command "$RESOLVED_BACKEND" "$STATION_LOCAL" "$STATION_HOST" "$RESOLVED_SESSION")
}

# --- continuity record ------------------------------------------------------

RECORD_PATH=

load_record_if_present() {
  RECORD_PATH=$(fm_rds_record_path "$STATE" "$STATION")
  if [ -f "$RECORD_PATH" ]; then
    fm_rds_record_read "$RECORD_PATH" >/dev/null 2>&1 \
      || fail "continuity record is malformed: $RECORD_PATH"
  fi
}

record_field() {  # <key>
  [ -n "$RECORD_PATH" ] || return 1
  [ -f "$RECORD_PATH" ] || return 1
  fm_rds_record_get "$RECORD_PATH" "$1"
}

write_record() {  # <task_id> <project> <branch> <worktree> <spawn_gen> <workspace> <window> <tab> <pane> <return_channel>
  local task_id=$1 project=$2 branch=$3 worktree=$4 spawn_gen=$5
  local workspace=$6 window=$7 tab=$8 pane=$9 return_channel=${10}
  [ "$PRINT" -eq 0 ] || return 0
  fm_rds_record_write "$RECORD_PATH" \
    "schema=$FM_RDS_SCHEMA" \
    "station=$STATION" \
    "local=$STATION_LOCAL" \
    "host=$STATION_HOST" \
    "backend=$RESOLVED_BACKEND" \
    "session=$RESOLVED_SESSION" \
    "workspace=$workspace" \
    "window=$window" \
    "tab=$tab" \
    "pane=$pane" \
    "task_id=$task_id" \
    "project=$project" \
    "branch=$branch" \
    "worktree=$worktree" \
    "spawn_gen=$spawn_gen" \
    "return_channel=$return_channel" \
    "attach_command=$ATTACH_COMMAND" \
    "updated=$(date +%s)" \
    || fail "could not write the continuity record at $RECORD_PATH"
}

# --- readiness --------------------------------------------------------------

doctor_output=

# A bounded, non-forwarding SSH probe, used only for the tmux readiness check.
ssh_read() {  # <host> <command-string>
  local host=$1 command=$2
  fm_run_timed "$TIMEOUT" "$SSH_BIN" \
    -o BatchMode=yes \
    -o ConnectTimeout="$TIMEOUT" \
    -o ForwardAgent=no \
    -o ClearAllForwardings=yes \
    -o 'SendEnv=-*' \
    -- "$host" "$command"
}

readiness_gate() {  # <local> <host> <route>
  local local1=$1 host=$2 route=$3 rc=0 out
  if [ "$RESOLVED_BACKEND" = tmux ]; then
    # The remote-secondmate doctor owns herdr readiness; tmux only proves its
    # own binary resolves, on either host.
    if [ "$local1" = 1 ]; then
      command -v "$TMUX_BIN" >/dev/null 2>&1 \
        || { printf 'readiness: tmux is not installed\n' >&2; return 5; }
    else
      out=$(ssh_read "$host" "$(printf '%s -V' "$TMUX_BIN")" 2>&1) || rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        printf 'readiness: tmux is not available on %s: %s\n' "$host" "${out:-ssh failed}" >&2
        doctor_output="readiness: tmux is not available on $host"
        return 5
      fi
    fi
    doctor_output="readiness: tmux ok on $host"
    return 0
  fi
  if [ "$local1" = 1 ]; then
    command -v "$HERDR_BIN" >/dev/null 2>&1 \
      || { printf 'readiness: herdr is not installed\n' >&2; return 5; }
    doctor_output='readiness: local herdr ok'
    return 0
  fi
  # The remote-secondmate doctor is the single owner of a remote host's herdr
  # readiness and of the named session server.
  out=$("$FM_ON" "$route" fm-remote-doctor.sh 2>&1) || rc=$?
  doctor_output=$out
  if [ "$rc" -ne 0 ]; then
    return 5
  fi
  return 0
}

readiness_repair() {  # <local> <route>
  local local1=$1 route=$2
  [ "$local1" = 0 ] || return 0
  "$FM_ON" "$route" fm-remote-doctor.sh --fix >/dev/null 2>&1 || true
}

print_gap_lines() {
  printf '%s\n' "$doctor_output" | awk '/^(check|action:|required) /' >&2
}

# --- endpoint liveness ------------------------------------------------------

# Returns 0 live, 1 not live, 2 unreadable. Reads this home's task record the
# same way bin/fm-station-idle.sh does, so a route to another host is read on
# that host rather than misread as dead.
endpoint_liveness() {  # <id>
  local id=$1 line state
  if [ ! -f "$STATE/$id.meta" ]; then
    return 1
  fi
  line=$(FM_HOME="$FM_HOME" fm_run_timed "$TIMEOUT" "$CREW_STATE" "$id" 2>/dev/null) || return 2
  state=$(printf '%s\n' "$line" | sed -n 's/^state: *\([a-z-]*\).*/\1/p' | head -1)
  case "$line" in
    *'source: remote-endpoint'*'remote endpoint alive on '*) return 0 ;;
  esac
  case "$state" in
    working|parked|blocked) return 0 ;;
    done|failed) return 1 ;;
    unknown)
      case "$line" in
        *'source: remote-endpoint'*'alive on '*) return 0 ;;
        *'source: remote-endpoint'*'remote endpoint dead on '*|*'source: remote-endpoint'*'remote endpoint missing on '*) return 1 ;;
        *) return 2 ;;
      esac
      ;;
    *) return 2 ;;
  esac
}

# --- pre-launch convergence and equivalence ---------------------------------

default_ref_of() {  # <repo>
  local repo=$1 head remote
  remote=$("$GIT" -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || true
  if [ -n "$remote" ]; then
    printf '%s\n' "$remote"
    return 0
  fi
  for head in origin/main origin/master main master; do
    if "$GIT" -C "$repo" rev-parse --verify --quiet "$head" >/dev/null 2>&1; then
      printf '%s\n' "$head"
      return 0
    fi
  done
  return 1
}

pr_state_of() {  # <id>
  # The forge probe is best-effort: an unreadable state is reported but never
  # refuses a launch, because it is not evidence of duplicate work.
  local id=$1 url probe
  [ -f "$STATE/$id.meta" ] || { printf 'none\n'; return 0; }
  url=$(fm_rds_meta_value "$STATE/$id.meta" pr || true)
  [ -n "$url" ] || { printf 'none\n'; return 0; }
  probe=${FM_RDS_PR_STATE:-}
  if [ -z "$probe" ]; then
    printf 'unknown\n'
    return 0
  fi
  "$probe" "$url" 2>/dev/null || printf 'unknown\n'
}

recorded_branch_of() {  # <id> <project>
  fm_rds_refs_from_meta "$STATE/$1.meta" "$RESOLVED_BACKEND" "$2" 2>/dev/null \
    | sed -n 's/^branch=//p'
}

prelaunch_gate() {  # <id> <project>
  local id=$1 project=$2 repo branch default_ref remote recorded state rc=0
  local meta="$STATE/$id.meta"
  repo=${REPO:-}
  if [ -z "$repo" ]; then
    repo=$(fm_rds_meta_value "$meta" worktree || true)
  fi
  [ -n "$repo" ] || repo="$PROJECTS/$project"
  recorded=$(recorded_branch_of "$id" "$project")
  branch=${BRANCH:-$recorded}
  if [ -z "$branch" ]; then
    printf 'fm-remote-dev-session: no intended branch resolved for %s; equivalence gate skipped\n' "$id" >&2
    return 0
  fi
  if [ ! -d "$repo" ]; then
    printf 'fm-remote-dev-session: no repo for %s at %s; equivalence gate skipped\n' "$id" "$repo" >&2
    return 0
  fi
  default_ref=$(default_ref_of "$repo") \
    || { printf 'fm-remote-dev-session: no default branch in %s; equivalence gate skipped\n' "$repo" >&2; return 0; }
  remote=${default_ref%%/*}
  [ "$remote" != "$default_ref" ] || remote=origin
  fm_rds_converge "$repo" "$remote" "${default_ref#*/}" \
    || { printf 'fm-remote-dev-session: default-branch convergence failed for %s; refusing\n' "$repo" >&2; return 1; }
  state=$(pr_state_of "$id")
  fm_rds_equivalence "$repo" "$default_ref" "$branch" "$recorded" "$state" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) return 3 ;;
    4) return 4 ;;
    *) return 1 ;;
  esac
}

# --- outcome ----------------------------------------------------------------

emit_outcome() {  # <action>
  printf 'remote-dev-session: backend=%s session=%s station=%s action=%s\n' \
    "$RESOLVED_BACKEND" "$RESOLVED_SESSION" "$STATION" "$1"
  printf 'attach: %s\n' "$ATTACH_COMMAND"
  [ -z "$RECORD_PATH" ] || printf 'record: %s\n' "$RECORD_PATH"
}

# --- verbs ------------------------------------------------------------------

resolve_station "$STATION"
if [ "$ACTION" = recover ] && [ -z "$TARGET_ID" ]; then
  load_record_if_present
  if [ -f "$RECORD_PATH" ]; then
    RECOVERY_BACKEND=$(record_field backend || true)
    RECOVERY_SESSION=$(record_field session || true)
  fi
fi
case "$ACTION" in
  status) ;;
  attach)
    [ -f "$(fm_rds_record_path "$STATE" "$STATION")" ] || resolve_backend_and_session
    ;;
  *) resolve_backend_and_session ;;
esac

case "$ACTION" in
  status)
    load_record_if_present
    if [ ! -f "$RECORD_PATH" ]; then
      printf 'remote-dev-session: none station=%s record=%s\n' "$STATION" "$RECORD_PATH"
      exit 0
    fi
    fm_rds_record_read "$RECORD_PATH" || fail "continuity record is malformed: $RECORD_PATH"
    exit 0
    ;;

  attach)
    load_record_if_present
    if [ -f "$RECORD_PATH" ]; then
      record_station=$(record_field station || true)
      record_local=$(record_field local || true)
      record_host=$(record_field host || true)
      RESOLVED_BACKEND=$(record_field backend || true)
      RESOLVED_SESSION=$(record_field session || true)
      recorded_attach_command=$(record_field attach_command || true)
      [ "$record_station" = "$STATION" ] \
        || fail "continuity record station does not match $STATION"
      [ "$record_local" = "$STATION_LOCAL" ] && [ "$record_host" = "$STATION_HOST" ] \
        || fail "continuity record route does not match station $STATION"
      fm_rds_backend_known "$RESOLVED_BACKEND" \
        || fail "continuity record has an unknown backend"
      case "$RESOLVED_SESSION" in
        ''|*[!A-Za-z0-9._-]*) fail "continuity record has an invalid session name" ;;
      esac
      ATTACH_COMMAND=$(fm_rds_attach_command "$RESOLVED_BACKEND" "$STATION_LOCAL" "$STATION_HOST" "$RESOLVED_SESSION") \
        || fail "continuity record has an invalid attach target"
      [ "$recorded_attach_command" = "$ATTACH_COMMAND" ] \
        || fail "continuity record attach command does not match its validated fields"
    fi
    [ -n "$ATTACH_COMMAND" ] || fail "no attach command could be resolved for station $STATION"
    if [ "$EXEC" -eq 1 ]; then
      exec bash -c "$ATTACH_COMMAND"
    fi
    printf '%s\n' "$ATTACH_COMMAND"
    exit 0
    ;;
esac

# `recover` without an explicit target inherits the recorded one, so a reconnect
# is a no-op for the operator.
load_record_if_present
if [ -z "$TARGET_ID" ] && [ "$ACTION" = recover ] && [ -f "$RECORD_PATH" ]; then
  recorded_id=$(record_field task_id || true)
  if [ -n "$recorded_id" ]; then
    if [ -f "$STATE/$recorded_id.meta" ] && [ "$(fm_rds_meta_value "$STATE/$recorded_id.meta" kind || true)" = secondmate ]; then
      TARGET_KIND=secondmate
    else
      TARGET_KIND=task
    fi
    TARGET_ID=$recorded_id
    [ -n "$PROJECT" ] || PROJECT=$(record_field project || true)
  fi
fi
[ -n "$TARGET_KIND" ] || die "'$ACTION' requires --secondmate <id> or --task <id>"

# Validate the target and its station placement.
if [ "$TARGET_KIND" = secondmate ]; then
  [ "$STATION_LOCAL" -eq 0 ] || fail "a second mate is not placed on the local station by this command"
  secondmate_registry_line_for_id "$REG" "$TARGET_ID" >/dev/null 2>&1 \
    || fail "no secondmate record for $TARGET_ID"
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || fail "$TARGET_ID is a local second mate; use fm-spawn directly"
  case "$SECONDMATE_REGISTRY_HOST" in
    "$STATION"|"$STATION"-*) ;;
    *) fail "$TARGET_ID is registered on ${SECONDMATE_REGISTRY_HOST}, not station $STATION" ;;
  esac
  [ "$RESOLVED_BACKEND" = herdr ] \
    || fail "remote second mates require the herdr backend"
  [ -n "$PROJECT" ] || PROJECT=$TARGET_ID
else
  [ -f "$STATE/$TARGET_ID.meta" ] || fail "no task record for $TARGET_ID at $STATE/$TARGET_ID.meta"
  [ -n "$PROJECT" ] || PROJECT=$(fm_rds_meta_value "$STATE/$TARGET_ID.meta" project 2>/dev/null || true)
  PROJECT=${PROJECT##*/}
fi

# Readiness gate: green, or refuse with the doctor's own gap text. --repair runs
# the doctor's repair once and re-checks read-only; a repair is never trusted on
# its own word.
rc=0
readiness_gate "$STATION_LOCAL" "$STATION_HOST" "${ROUTE_ID:-$STATION_HOST}" || rc=$?
if [ "$rc" -eq 5 ] && [ "$REPAIR" -eq 1 ]; then
  readiness_repair "$STATION_LOCAL" "${ROUTE_ID:-$STATION_HOST}"
  rc=0
  readiness_gate "$STATION_LOCAL" "$STATION_HOST" "${ROUTE_ID:-$STATION_HOST}" || rc=$?
fi
if [ "$rc" -eq 5 ]; then
  printf 'fm-remote-dev-session: station %s is not ready for a development session\n' "$STATION" >&2
  print_gap_lines
  exit 5
fi

# Pre-launch convergence and equivalence: refuse duplicate or stale work.
if [ "$TARGET_KIND" = task ]; then
  rc=0
  prelaunch_gate "$TARGET_ID" "$PROJECT" || rc=$?
  case "$rc" in
    0) ;;
    3) printf 'fm-remote-dev-session: duplicate work for %s; refusing to start a second run\n' "$TARGET_ID" >&2; exit 3 ;;
    4) printf 'fm-remote-dev-session: stale work for %s; the intended branch is behind or already landed\n' "$TARGET_ID" >&2; exit 4 ;;
    *) printf 'fm-remote-dev-session: the pre-launch gate could not complete; refusing\n' >&2; exit 1 ;;
  esac
fi

if [ "$ACTION" = check ]; then
  printf 'remote-dev-session: backend=%s session=%s station=%s check=ok\n' \
    "$RESOLVED_BACKEND" "$RESOLVED_SESSION" "$STATION"
  printf 'attach: %s\n' "$ATTACH_COMMAND"
  exit 0
fi

# Reattach a live endpoint or relaunch through the ordinary record path. Never a
# raw process.
meta="$STATE/$TARGET_ID.meta"
liveness=0
endpoint_liveness "$TARGET_ID" || liveness=$?
case "$liveness" in
  0)
    OUTCOME=attached
    ;;
  1)
    OUTCOME=launched
    if [ "$PRINT" -eq 0 ]; then
      if [ "$TARGET_KIND" = secondmate ]; then
        "$SPAWN" "$TARGET_ID" --secondmate >/dev/null 2>&1 \
          || fail "relaunching $TARGET_ID through fm-spawn failed"
      else
        "$CONTROL" "$TARGET_ID" relaunch >/dev/null 2>&1 \
          || fail "relaunching $TARGET_ID through fm-control failed"
      fi
    fi
    ;;
  *)
    fail "endpoint liveness for $TARGET_ID is unknown; refusing to relaunch on an unknown state"
    ;;
esac

ref_lines=$(fm_rds_refs_from_meta "$meta" "$RESOLVED_BACKEND" "$PROJECT")
task_id=$(printf '%s\n' "$ref_lines" | sed -n 's/^task_id=//p')
project=$(printf '%s\n' "$ref_lines" | sed -n 's/^project=//p')
branch=$(printf '%s\n' "$ref_lines" | sed -n 's/^branch=//p')
worktree=$(printf '%s\n' "$ref_lines" | sed -n 's/^worktree=//p')
spawn_gen=$(printf '%s\n' "$ref_lines" | sed -n 's/^spawn_gen=//p')
workspace=$(printf '%s\n' "$ref_lines" | sed -n 's/^workspace=//p')
window=$(printf '%s\n' "$ref_lines" | sed -n 's/^window=//p')
tab=$(printf '%s\n' "$ref_lines" | sed -n 's/^tab=//p')
pane=$(printf '%s\n' "$ref_lines" | sed -n 's/^pane=//p')

if [ "$TARGET_KIND" = secondmate ] && [ "$STATION_LOCAL" -eq 0 ]; then
  return_channel="$ROUTE_HOME/state/parent-replies.status"
else
  return_channel="$STATE/$TARGET_ID.status"
fi

write_record "$task_id" "$project" "$branch" "$worktree" "$spawn_gen" \
  "$workspace" "$window" "$tab" "$pane" "$return_channel"

emit_outcome "$OUTCOME"
if [ "$PRINT" -eq 1 ]; then
  printf 'remote-dev-session: dry run, no launch or record written\n'
fi
