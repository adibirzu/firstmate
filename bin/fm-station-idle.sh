#!/usr/bin/env bash
# fm-station-idle.sh - read-only per-station idle-window probe and its watcher
# check.
#
# Usage:
#   fm-station-idle.sh <station>          probe one station (same as `check`)
#   fm-station-idle.sh check <station>    probe one station; the shim's own verb
#   fm-station-idle.sh arm <station>      write and register the watcher check
#   fm-station-idle.sh disarm <station>   remove the watcher check
#   fm-station-idle.sh --help             print this help
#
# Why this exists: a herdr update restarts a station's whole server and stops
# every pane on that host, so it is only safe while that station has no work
# running. "Update a station only when its tasks are finished, never mid-run" is
# a captain rule, and this probe encodes it so nobody has to remember to check.
#
# A station is one SSH host (or the local host). Its update-safe window is
# proven from durable records, for every Firstmate home on that station:
#
#   1. `tasks-axi list --state in_flight` is empty (no dispatched task);
#   2. herdr reports no agent in `working` or `blocked` state in any session on
#      that host, host-wide, because a herdr update stops every pane there;
#   3. every task endpoint the home records is not live (`bin/fm-crew-state.sh`
#      is not `working`, `parked`, or `blocked`), which catches a pane still
#      running after its backlog item closed.
#
# Homes are resolved from data/secondmates.md: a remote station matches its
# `host:` routes, while the local station matches the local routes plus this
# home. A remote route whose host is `<station>` or `<station>-<suffix>` belongs
# to that station, so a tailnet alias like `adi2-ts` is reached by `adi2`.
#
# The probe is silent unless the whole station is provably idle, and then it
# prints exactly one line: `station-idle: <station>`. It never performs an
# update itself: the update stays a wake-time decision, exactly as
# process-event-sources requires for a disruptive action. It is read-only over
# the network; its only write is its own dedupe record under this home's state/.
#
# The line is news once, not on every poll. The station must also have been idle
# continuously for FM_STATION_IDLE_WINDOW seconds (default 300) before the line
# is printed, so a brief gap between tasks is not mistaken for a real window;
# the probe records the first idle observation and clears it the moment the
# station is busy again. Once reported, the line stays silent until the station
# goes busy and idle once more.
#
# `arm <station>` writes state/station-idle-<station>.check.sh through
# bin/fm-check-register.sh, so the watcher turns the line into a `check:` wake;
# `disarm <station>` removes it. Arm each station once, for example:
#
#   FM_HOME=<primary-home> bin/fm-station-idle.sh arm adi1
#   FM_HOME=<primary-home> bin/fm-station-idle.sh arm adi2
#   FM_HOME=<primary-home> bin/fm-station-idle.sh arm adi3
#
# Environment knobs (all overridable for tests):
#   FM_STATION_TIMEOUT          per-read bound in seconds (8, valid 1..60)
#   FM_STATION_BUDGET           whole-probe bound in seconds, cut to fit
#                               FM_CHECK_TIMEOUT (20, valid 1..120)
#   FM_STATION_ENDPOINT_LIMIT   most endpoint records proven per home (20)
#   FM_STATION_IDLE_WINDOW      continuous idle seconds before reporting (300, 0 disables)
#   FM_STATION_LOCAL_NAMES      station names that mean the local host ("local mini")
#   FM_STATION_SSH              ssh executable (ssh)
#   FM_STATION_HERDR            herdr executable (herdr)
#   FM_STATION_TASKS_AXI        tasks-axi executable (tasks-axi)
#   FM_STATION_CREW_STATE       fm-crew-state.sh path (this checkout)
#   FM_STATION_JQ               jq executable (jq)
#   FM_STATION_NOW              epoch override for the idle window (tests only)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"

SSH_BIN=${FM_STATION_SSH:-ssh}
HERDR=${FM_STATION_HERDR:-herdr}
TASKS_AXI=${FM_STATION_TASKS_AXI:-tasks-axi}
CREW_STATE=${FM_STATION_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}
JQ=${FM_STATION_JQ:-jq}
LOCAL_NAMES=${FM_STATION_LOCAL_NAMES:-local mini}
IDLE_WINDOW=${FM_STATION_IDLE_WINDOW:-300}
ENDPOINT_LIMIT=${FM_STATION_ENDPOINT_LIMIT:-20}
CHECK_ID_PREFIX='station-idle'

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-check-shim-lib.sh
. "$SCRIPT_DIR/fm-check-shim-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  sed -n '2,65p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-station-idle: %s\n' "$1" >&2
  usage >&2
  exit 2
}

TIMEOUT=${FM_STATION_TIMEOUT:-8}
case "$TIMEOUT" in ''|*[!0-9]*|0) die_usage 'FM_STATION_TIMEOUT must be a whole number from 1 to 60' ;; esac
[ "$TIMEOUT" -le 60 ] || die_usage 'FM_STATION_TIMEOUT must be a whole number from 1 to 60'

BUDGET=${FM_STATION_BUDGET:-20}
case "$BUDGET" in ''|*[!0-9]*|0) die_usage 'FM_STATION_BUDGET must be a whole number from 1 to 120' ;; esac
[ "$BUDGET" -le 120 ] || die_usage 'FM_STATION_BUDGET must be a whole number from 1 to 120'

case "$ENDPOINT_LIMIT" in ''|*[!0-9]*|0) die_usage 'FM_STATION_ENDPOINT_LIMIT must be a positive whole number' ;; esac
case "$IDLE_WINDOW" in ''|*[!0-9]*) die_usage 'FM_STATION_IDLE_WINDOW must be a whole number of seconds (0 disables it)' ;; esac

# The watcher's per-check bound, read from this check's own environment. The
# watcher runs the check as a direct child, so an operator who raised it is seen
# here too, and when it is unset both sides resolve the same default.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
# Leave room for one whole probe plus the kill grace the timeout runner uses, so
# a sweep that respects the budget is never killed by the watcher with nothing
# printed.
BUDGET_MAX=$((CHECK_TIMEOUT - TIMEOUT - 2))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
[ "$BUDGET" -le "$BUDGET_MAX" ] || BUDGET=$BUDGET_MAX

real_epoch() { date +%s; }

record_epoch_now() {
  case "${FM_STATION_NOW:-}" in
    ''|*[!0-9]*) real_epoch ;;
    *) printf '%s\n' "$FM_STATION_NOW" ;;
  esac
}

deadline_passed() {
  [ "$(real_epoch)" -ge "$DEADLINE" ]
}

# --- target model -----------------------------------------------------------

STATION_KIND=
STATION_HOST=
T_KIND=()
T_HOST=()
T_HOME=()
T_ROOT=()
T_ID=()

add_target() {  # <kind> <host> <home> <root> <id>
  T_KIND+=("$1")
  T_HOST+=("$2")
  T_HOME+=("$3")
  T_ROOT+=("$4")
  T_ID+=("$5")
}

station_matches_host() {  # <station> <host>
  case "$2" in
    "$1"|"$1"-*) return 0 ;;
  esac
  return 1
}

# A route reaches this probe from data/secondmates.md. Validate the exact values
# before any is used as an argv or a remote path, so a malformed registry entry
# can never steer the probe at an unintended host or path.
secondmate_target_paths_safe() {
  case "$SECONDMATE_REGISTRY_HOME" in /*) ;; *) return 1 ;; esac
  case "$SECONDMATE_REGISTRY_HOME" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
  case "/$SECONDMATE_REGISTRY_HOME/" in */../*|*/./*) return 1 ;; esac
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] && return 0
  case "$SECONDMATE_REGISTRY_HOST" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$SECONDMATE_REGISTRY_ROOT" in /*) ;; *) return 1 ;; esac
  case "$SECONDMATE_REGISTRY_ROOT" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
  case "/$SECONDMATE_REGISTRY_ROOT/" in */../*|*/./*) return 1 ;; esac
  return 0
}

# Resolve every home on <station>. The local host always includes this home;
# a remote host may have no registered home at all (for example a station that
# is not yet onboarded), and is still probed host-wide through herdr.
resolve_station() {  # <station>
  local station=$1 line
  T_KIND=(); T_HOST=(); T_HOME=(); T_ROOT=(); T_ID=()
  STATION_KIND=remote
  STATION_HOST=
  case " $LOCAL_NAMES " in
    *" $station "*)
      STATION_KIND=local
      add_target local '' "$FM_HOME" "$FM_ROOT" 'this-home'
      ;;
  esac
  if [ -f "$REG" ] && [ ! -L "$REG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '- '*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" || continue
      if [ "$STATION_KIND" = local ]; then
        [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
        secondmate_target_paths_safe || continue
        add_target local '' "$SECONDMATE_REGISTRY_HOME" "$FM_ROOT" "$SECONDMATE_REGISTRY_ID"
      else
        [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
        station_matches_host "$station" "$SECONDMATE_REGISTRY_HOST" || continue
        secondmate_target_paths_safe || continue
        [ -n "$STATION_HOST" ] || STATION_HOST=$SECONDMATE_REGISTRY_HOST
        add_target remote "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_HOME" \
          "$SECONDMATE_REGISTRY_ROOT" "$SECONDMATE_REGISTRY_ID"
      fi
    done < "$REG"
  fi
  if [ "$STATION_KIND" = remote ] && [ -z "$STATION_HOST" ]; then
    STATION_HOST=$station
  fi
  return 0
}

# --- reads ------------------------------------------------------------------

# Quote one validated value for the remote POSIX shell. SSH joins its argv with
# spaces and lets the remote shell re-split it, so a remote command is passed as
# one already-quoted string rather than as separate arguments.
rq() { printf '%q' "$1"; }

# A fixed, bounded, non-forwarding SSH read. The host alias and any remote path
# reach this from the validated registry or the validated station name, so the
# command is never built from untrusted text.
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

# 0 when herdr on the station has no working or blocked agent, 1 otherwise
# (including any failure to answer, which is never read as idle).
station_herdr_idle() {  # <kind> <host>
  local kind=$1 host=${2:-} out rc statuses
  if [ "$kind" = local ]; then
    out=$(fm_run_timed "$TIMEOUT" "$HERDR" agent list 2>/dev/null)
  else
    out=$(ssh_read "$host" "$(printf '%s agent list' "$(rq "$HERDR")")" 2>/dev/null)
  fi
  rc=$?
  [ "$rc" -eq 0 ] && [ -n "$out" ] || return 1
  command -v "$JQ" >/dev/null 2>&1 || return 1
  printf '%s' "$out" | "$JQ" -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 1
  statuses=$(printf '%s' "$out" | "$JQ" -r '.result.agents[].agent_status // empty' 2>/dev/null) || return 1
  if printf '%s\n' "$statuses" | grep -Eq '^(working|blocked)$'; then
    return 1
  fi
  return 0
}

# 0 when the home has no in-flight task, 1 otherwise.
home_in_flight_empty() {  # <kind> <host> <home>
  local kind=$1 host=$2 home=$3 out rc count
  if [ "$kind" = local ]; then
    out=$(cd "$home" 2>/dev/null && fm_run_timed "$TIMEOUT" "$TASKS_AXI" list --state in_flight 2>/dev/null)
  else
    out=$(ssh_read "$host" \
      "$(printf 'cd %s && exec %s list --state in_flight' "$(rq "$home")" "$(rq "$TASKS_AXI")")" 2>/dev/null)
  fi
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  count=$(printf '%s\n' "$out" | sed -n 's/^count: *//p' | head -1)
  case "$count" in
    0) return 0 ;;
  esac
  return 1
}

# The task ids the home records, one per line.
home_meta_ids() {  # <kind> <host> <home>
  local kind=$1 host=$2 home=$3 out rc
  if [ "$kind" = local ]; then
    out=$(ls -1 "$home/state" 2>/dev/null)
  else
    out=$(ssh_read "$host" "$(printf 'ls -1 %s' "$(rq "$home/state")")" 2>/dev/null)
  fi
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out" | sed -n 's/\.meta$//p' | grep -vE '^\.' || true
}

# 0 when no recorded endpoint in the home is live, 1 otherwise.
home_endpoints_idle() {  # <kind> <host> <home> <root>
  local kind=$1 host=$2 home=$3 root=$4
  local ids id line state n=0
  ids=$(home_meta_ids "$kind" "$host" "$home") || return 1
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    # More recorded endpoints than the probe will read is not proof of idle.
    [ "$n" -le "$ENDPOINT_LIMIT" ] || return 1
    deadline_passed && return 1
    if [ "$kind" = local ]; then
      line=$(FM_HOME="$home" fm_run_timed "$TIMEOUT" "$CREW_STATE" "$id" 2>/dev/null) || return 1
    else
      line=$(ssh_read "$host" \
        "$(printf 'env %s %s %s' "$(rq "FM_HOME=$home")" "$(rq "$root/bin/fm-crew-state.sh")" "$(rq "$id")")" 2>/dev/null) || return 1
    fi
    state=$(printf '%s\n' "$line" | sed -n 's/^state: *\([a-z-]*\).*/\1/p' | head -1)
    case "$state" in
      working|parked|blocked) return 1 ;;
      '') return 1 ;;
    esac
  done <<EOF
$ids
EOF
  return 0
}

# --- idle window record -----------------------------------------------------

record_path() { printf '%s/.station-idle-%s\n' "$STATE" "$1"; }

record_read() {  # <file> -> prints "since" then "reported", one per line
  local file=$1 first=1 line since=0 reported=0
  [ -f "$file" ] || { printf '0\n0\n'; return 0; }
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = 'fm-station-idle-v1' ] || { printf '0\n0\n'; return 0; }
      continue
    fi
    case "$line" in
      since=*)
        line=${line#since=}
        case "$line" in ''|*[!0-9]*) since=0 ;; *) since=$line ;; esac
        ;;
      reported=*) [ "${line#reported=}" = 1 ] && reported=1 || reported=0 ;;
    esac
  done < "$file"
  printf '%s\n%s\n' "$since" "$reported"
}

record_write() {  # <file> <since> <reported>
  local file=$1 since=$2 reported=$3 tmp
  tmp=$(umask 077; mktemp "$file.XXXXXX" 2>/dev/null) || return 1
  {
    printf '%s\n' 'fm-station-idle-v1'
    printf 'since=%s\n' "$since"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  return 0
}

clear_record() {  # <station>
  rm -f -- "$(record_path "$1")"
}

report_or_clear() {  # <station> <idle:0|1>
  local station=$1 idle=$2 file since reported now
  file=$(record_path "$station")
  if [ "$idle" -eq 0 ]; then
    clear_record "$station"
    return 0
  fi
  { read -r since; read -r reported; } < <(record_read "$file")
  if [ "$reported" = 1 ]; then
    return 0
  fi
  now=$(record_epoch_now)
  if [ "$since" -eq 0 ]; then
    since=$now
    record_write "$file" "$since" 0 || true
  fi
  if [ "$IDLE_WINDOW" -le 0 ] || [ $((now - since)) -ge "$IDLE_WINDOW" ]; then
    printf 'station-idle: %s\n' "$station"
    record_write "$file" "$since" 1 || true
  fi
  return 0
}

# --- actions ----------------------------------------------------------------

DEADLINE=0

action_check() {  # <station>
  local station=$1 i
  resolve_station "$station"
  DEADLINE=$(($(real_epoch) + BUDGET))
  if ! station_herdr_idle "$STATION_KIND" "$STATION_HOST"; then
    report_or_clear "$station" 0
    return 0
  fi
  i=0
  while [ "$i" -lt "${#T_HOME[@]}" ]; do
    if deadline_passed \
      || ! home_in_flight_empty "${T_KIND[i]}" "${T_HOST[i]}" "${T_HOME[i]}" \
      || ! home_endpoints_idle "${T_KIND[i]}" "${T_HOST[i]}" "${T_HOME[i]}" "${T_ROOT[i]}"; then
      report_or_clear "$station" 0
      return 0
    fi
    i=$((i + 1))
  done
  report_or_clear "$station" 1
}

shim_content() {  # <home> <station>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-station-idle.sh - per-station idle-window poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-station-idle.sh") check $(printf '%q' "$2")"
}

action_arm() {  # <station>
  local station=$1 home want
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-station-idle: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home" "$station")
  fm_check_shim_install "$SCRIPT_DIR" "$STATE" "$CHECK_ID_PREFIX-$station" "$want"
}

action_disarm() {  # <station>
  local station=$1 id
  id="$CHECK_ID_PREFIX-$station"
  fm_check_shim_remove "$STATE" "$id"
  clear_record "$station"
  printf 'disarmed: state/%s.check.sh\n' "$id"
  return 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') die_usage 'a station is required' ;;
  check|arm|disarm)
    ACTION=$1
    STATION=${2:-}
    [ -n "$STATION" ] || die_usage "$ACTION requires a station"
    case "$STATION" in
      ''|.*|-*|*[!A-Za-z0-9._-]*) die_usage "station must be letters, digits, dot, underscore, or dash: $STATION" ;;
    esac
    ;;
  *)
    ACTION=check
    STATION=$1
    case "$STATION" in
      ''|.*|-*|*[!A-Za-z0-9._-]*) die_usage "station must be letters, digits, dot, underscore, or dash: $STATION" ;;
    esac
    ;;
esac

case "$ACTION" in
  check) action_check "$STATION" ;;
  arm) action_arm "$STATION" ;;
  disarm) action_disarm "$STATION" ;;
esac
