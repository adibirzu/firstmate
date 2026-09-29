#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Two signals decide ownership, either one sufficient: the recorded pid
# is a member of this process's contiguous harness ancestry, or the trusted
# Claude session id below matches the id recorded beside a live lock. Neither
# signal ever fails open: no id, no sidecar, an untrusted id, or a different
# recorded id leaves the ancestry verdict exactly as it was.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_SESSION_LOCK_LIB_DIR

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
#
# cline is here but NOT in FM_HARNESS_RE, and the split is deliberate. cline
# runs as a bundled Node script, so its reported command name is a bare `node`
# that no name regex can own, while `ps -o comm=` carries its install path
# (.../node_modules/cline/bin/.cline) - the same shape cursor-agent has. The
# path rule below matches an exact `cline` path COMPONENT rather than a
# substring, so an unrelated node process still matches nothing and stays
# unattributed rather than being claimed as an agent. Without this entry the
# tmux liveness classifier reads a live cline pane as `ambiguous`, and every
# lifecycle verb that must prove an agent is running refuses it.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi cline omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
FM_HARNESS_ANCESTRY_CACHE_READY=0
FM_HARNESS_ANCESTRY_CACHE_FOUND=0
FM_HARNESS_ANCESTRY_PIDS=
FM_HARNESS_ANCESTRY_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_cache() {
  local pid=$$ comm args extending=0 printed=0
  if [ "$FM_HARNESS_ANCESTRY_CACHE_READY" -eq 1 ]; then
    [ "$FM_HARNESS_ANCESTRY_CACHE_FOUND" -eq 1 ]
    return
  fi
  FM_HARNESS_ANCESTRY_CACHE_READY=1
  FM_HARNESS_ANCESTRY_CACHE_FOUND=0
  FM_HARNESS_ANCESTRY_PIDS=
  FM_HARNESS_ANCESTRY_IS_CLAUDE=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      FM_HARNESS_ANCESTRY_PIDS="${FM_HARNESS_ANCESTRY_PIDS}${FM_HARNESS_ANCESTRY_PIDS:+$'\n'}$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 0 ] || FM_HARNESS_ANCESTRY_IS_CLAUDE=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ] || return 1
  FM_HARNESS_ANCESTRY_CACHE_FOUND=1
}

fm_harness_ancestry_pids() {
  fm_harness_ancestry_cache || return 1
  printf '%s\n' "$FM_HARNESS_ANCESTRY_PIDS"
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pid outermost=''
  fm_harness_ancestry_cache || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$FM_HARNESS_ANCESTRY_PIDS
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current Claude run.
#
# Trust gate: CLAUDE_PID must be a Claude-shaped member of this process's
# contiguous harness ancestry. An id merely retained in a helper environment
# fails that membership and is ignored: a hand-started Pi or codex primary under
# a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and CLAUDE_PID,
# and must never own a lock with them. Ids are read from the environment only,
# never from ps argv, where prompts and briefs are visible.
#
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print the Claude session id this process may own with, or return 1. $1 is the
# ancestry list an earlier walk already produced, so a caller that walked once
# need not walk again.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$id"
    return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# True when the lock in state dir $1 was recorded by this same Claude session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_session_id "$pids" >/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is ANY harness ancestor of the current process, or the lock
# was recorded by this same trusted Claude session and its recorded pid is still
# a live harness. Membership is the honest ancestry test, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the outermost pid
# when the hook fires inside the session's own nested worker chain, and an inner
# pid when a harness-named daemon parents the session. The same-session path
# requires the recorded pid alive so that a dead one is reclaimed through
# bin/fm-lock.sh's ordinary stale-owner path, which refreshes line 1, rather than
# silently owned with a dead anchor. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry under another (or no) session id, or
# an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_ancestry_cache || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$FM_HARNESS_ANCESTRY_PIDS
EOF
  fm_session_lock_same_session "$state" "$pids" || return 1
  fm_harness_pid_alive "$lock_pid"
}

# True when state dir $1 records a live verified harness outside this process's
# contiguous harness ancestry that was not recorded by this same trusted Claude
# session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
# Malformed, missing, dead, and ancestry-uncertain locks are not foreign-owner
# evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids pid
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 1
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" && return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#
# held: the recorded pid is a live verified harness.
# stale: the recorded pid is gone.
# unknown: the file or pid cannot be classified without guessing, including a
# live process that is not a verified harness. Existence of a lock file, a
# session record, or a pane is never treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  lock="$state/.lock"
  if [ ! -e "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  case "$pid" in
    ''|*[!0-9]*)
      FM_LOCK_INSPECT_STATE=unknown
      return 0
      ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if ps -o comm= -p "$pid" >/dev/null 2>&1; then
    FM_LOCK_INSPECT_STATE=unknown
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=stale
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}

# True when this run's verified harness is Claude.
#
# A Claude worker pool can be reparented away from the session it serves, so
# its ancestry is not by itself a session identity. Every other currently
# verified harness has one contiguous harness pid and retains the established
# ancestry contract above.
fm_harness_ancestry_is_claude() {
  fm_harness_ancestry_cache || return 1
  [ "$FM_HARNESS_ANCESTRY_IS_CLAUDE" -eq 1 ]
}

# Set the identity a NEW session lock must record.
#
# Claude Code supplies a stable session id, and normally the served session pid
# in CLAUDE_PID. Require the session id, and require a live verified-harness pid,
# before a new Claude lock may be written. When CLAUDE_PID is unset - the
# homebrew Claude Code build exports CLAUDECODE and CLAUDE_CODE_SESSION_ID into
# hook and tool shells but not CLAUDE_PID - fall back to the live claude ancestry
# pid, the contiguous-run pid state/.lock records for this session anyway. The
# session id, not the pid, is what distinguishes one Claude session from a
# reparented worker-pool sibling, so this fallback keeps a sibling from claiming
# the lock. Other supported harnesses expose their session through their one
# verified ancestry pid, which remains their stable lock identity.
FM_SESSION_LOCK_OWNER_KIND=
FM_SESSION_LOCK_OWNER_PID=
FM_SESSION_LOCK_OWNER_SESSION=
fm_session_lock_prepare_acquisition_identity() {
  local ancestry_pid session_id session_pid
  FM_SESSION_LOCK_OWNER_KIND=
  FM_SESSION_LOCK_OWNER_PID=
  FM_SESSION_LOCK_OWNER_SESSION=
  ancestry_pid=$(fm_harness_ancestry_pid) || return 1
  if fm_harness_ancestry_is_claude; then
    [ "${CLAUDECODE:-}" = 1 ] || return 1
    session_id=${CLAUDE_CODE_SESSION_ID:-}
    session_pid=${CLAUDE_PID:-}
    case "$session_id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ -n "$session_pid" ] || session_pid=$ancestry_pid
    case "$session_pid" in ''|*[!0-9]*) return 1 ;; esac
    fm_harness_pid_alive "$session_pid" || return 1
    FM_SESSION_LOCK_OWNER_KIND=claude
    FM_SESSION_LOCK_OWNER_PID=$session_pid
    FM_SESSION_LOCK_OWNER_SESSION=$session_id
    return 0
  fi
  FM_SESSION_LOCK_OWNER_KIND=ancestry
  FM_SESSION_LOCK_OWNER_PID=$ancestry_pid
  FM_SESSION_LOCK_OWNER_SESSION=$ancestry_pid
}

# Print the adjacent new-format binding path for state dir $1.
# state/.lock remains a bare pid for its existing readers.
fm_session_lock_record_path() {  # <state-dir>
  printf '%s/.lock.session\n' "$1"
}

# Read one exact new-format lock binding into FM_SESSION_LOCK_RECORD_*.
# A missing binding is legacy. A malformed binding is never legacy, because a
# failed or tampered new-format record must not regain the compatibility path.
FM_SESSION_LOCK_RECORD_KIND=
FM_SESSION_LOCK_RECORD_PID=
FM_SESSION_LOCK_RECORD_SESSION=
fm_session_lock_read_record_file() {  # <record-path>
  local path=$1 first second third fourth extra
  FM_SESSION_LOCK_RECORD_KIND=
  FM_SESSION_LOCK_RECORD_PID=
  FM_SESSION_LOCK_RECORD_SESSION=
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  {
    IFS= read -r first
    IFS= read -r second
    IFS= read -r third
    IFS= read -r fourth
    IFS= read -r extra || true
  } < "$path" || return 1
  [ "$first" = 'format=1' ] || return 1
  case "$second" in kind=claude|kind=ancestry) ;; *) return 1 ;; esac
  case "$third" in pid=*) FM_SESSION_LOCK_RECORD_PID=${third#pid=} ;; *) return 1 ;; esac
  case "$fourth" in session=*) FM_SESSION_LOCK_RECORD_SESSION=${fourth#session=} ;; *) return 1 ;; esac
  [ -z "$extra" ] || return 1
  case "$FM_SESSION_LOCK_RECORD_PID" in ''|*[!0-9]*) return 1 ;; esac
  case "$FM_SESSION_LOCK_RECORD_SESSION" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  FM_SESSION_LOCK_RECORD_KIND=${second#kind=}
}

fm_session_lock_read_record() {  # <state-dir>
  fm_session_lock_read_record_file "$(fm_session_lock_record_path "$1")"
}

# Print state dir $1's validated binding in its on-disk format.
fm_session_lock_print_record() {  # <state-dir>
  fm_session_lock_read_record "$1" || return 1
  printf 'format=1\nkind=%s\npid=%s\nsession=%s\n' \
    "$FM_SESSION_LOCK_RECORD_KIND" "$FM_SESSION_LOCK_RECORD_PID" "$FM_SESSION_LOCK_RECORD_SESSION"
}

# True when record file $2 is exactly state dir $1's validated lock binding.
fm_session_lock_record_matches_file() {  # <state-dir> <record-path>
  local state=$1 record=$2 kind pid session
  fm_session_lock_read_record "$state" || return 1
  kind=$FM_SESSION_LOCK_RECORD_KIND
  pid=$FM_SESSION_LOCK_RECORD_PID
  session=$FM_SESSION_LOCK_RECORD_SESSION
  fm_session_lock_read_record_file "$record" || return 1
  [ "$FM_SESSION_LOCK_RECORD_KIND" = "$kind" ] \
    && [ "$FM_SESSION_LOCK_RECORD_PID" = "$pid" ] \
    && [ "$FM_SESSION_LOCK_RECORD_SESSION" = "$session" ]
}

fm_session_lock_record_matches() {  # <state-dir> <kind> <pid> <session>
  local state=$1 kind=$2 pid=$3 session=$4
  fm_session_lock_read_record "$state" || return 1
  [ "$FM_SESSION_LOCK_RECORD_KIND" = "$kind" ] \
    && [ "$FM_SESSION_LOCK_RECORD_PID" = "$pid" ] \
    && [ "$FM_SESSION_LOCK_RECORD_SESSION" = "$session" ]
}

fm_session_lock_print_binding() {  # <kind> <pid> <session>
  local kind=$1 pid=$2 session=$3
  case "$kind" in claude|ancestry) ;; *) return 1 ;; esac
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$session" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf 'format=1\nkind=%s\npid=%s\nsession=%s\n' "$kind" "$pid" "$session"
}

# Write the complete new lock format under fm-lock.sh's acquisition claim.
# The record publishes first, so readers fail closed while the raw pid moves;
# it is removed again if the raw lock cannot be replaced. A new acquisition
# therefore never leaves only a pid-only lock behind.
fm_session_lock_write_new_format() {  # <state-dir>
  local state=$1 path lock tmp_record tmp_lock previous=
  [ -n "$FM_SESSION_LOCK_OWNER_KIND" ] || return 1
  [ -n "$FM_SESSION_LOCK_OWNER_PID" ] || return 1
  [ -n "$FM_SESSION_LOCK_OWNER_SESSION" ] || return 1
  path=$(fm_session_lock_record_path "$state")
  lock="$state/.lock"
  tmp_record=$(mktemp "$state/.lock.session.XXXXXX" 2>/dev/null) || return 1
  tmp_lock=$(mktemp "$state/.lock.new.XXXXXX" 2>/dev/null) || {
    command rm -f -- "$tmp_record" 2>/dev/null
    return 1
  }
  if ! {
    printf 'format=1\nkind=%s\npid=%s\nsession=%s\n' \
      "$FM_SESSION_LOCK_OWNER_KIND" "$FM_SESSION_LOCK_OWNER_PID" "$FM_SESSION_LOCK_OWNER_SESSION" > "$tmp_record"
    printf '%s\n' "$FM_SESSION_LOCK_OWNER_PID" > "$tmp_lock"
  }; then
    command rm -f -- "$tmp_record" "$tmp_lock" 2>/dev/null
    return 1
  fi
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    previous=$(mktemp "$state/.lock.session.previous.XXXXXX" 2>/dev/null) || {
      command rm -f -- "$tmp_record" "$tmp_lock" 2>/dev/null
      return 1
    }
    if ! cp "$path" "$previous" 2>/dev/null; then
      command rm -f -- "$tmp_record" "$tmp_lock" "$previous" 2>/dev/null
      return 1
    fi
  fi
  if ! mv -f "$tmp_record" "$path" 2>/dev/null; then
    command rm -f -- "$tmp_record" "$tmp_lock" "$previous" 2>/dev/null
    return 1
  fi
  if ! mv -f "$tmp_lock" "$lock" 2>/dev/null; then
    if [ -n "$previous" ]; then
      mv -f "$previous" "$path" 2>/dev/null || true
    else
      command rm -f -- "$path" 2>/dev/null
    fi
    command rm -f -- "$tmp_lock" "$previous" 2>/dev/null
    return 1
  fi
  command rm -f -- "$previous" 2>/dev/null || true
}

# Record every temporary legacy acceptance durably. Logging failure rejects the
# acceptance rather than silently extending the migration exception.
fm_session_lock_log_legacy_acceptance() {  # <state-dir> <pid>
  local state=$1 pid=$2 home
  home=$(cd "$state/.." 2>/dev/null && pwd -P) || home=$state
  printf 'legacy session lock accepted: home=%s pid=%s\n' "$home" "$pid" \
    >> "$state/.lock.legacy.log" 2>/dev/null
}

# True only when state dir $1's existing PID-only lock is temporarily accepted
# for the current session. Follow-up task fm-remove-legacy-lock-compat removes
# this compatibility path once all live homes have turned over to new-format
# locks. It exists solely to avoid wedging a live home whose old lock names the
# shared Claude pool daemon during migration.
fm_session_lock_owned_by_legacy_compatibility() {  # <state-dir>
  local state=$1 lock_pid path ancestry_pid
  fm_session_lock_prepare_acquisition_identity || return 1
  path=$(fm_session_lock_record_path "$state")
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  ancestry_pid=$(fm_harness_ancestry_pid) || return 1
  if [ "$lock_pid" != "$FM_SESSION_LOCK_OWNER_PID" ] && [ "$lock_pid" != "$ancestry_pid" ]; then
    return 1
  fi
  fm_harness_pid_alive "$lock_pid" || return 1
  fm_session_lock_log_legacy_acceptance "$state" "$lock_pid"
}

# True when the current session owns state dir $1's lock. New-format records
# prove ownership with the identity published when the lock was taken: a claude
# session id that survives worker-pool reparenting, or the ancestry session pid
# every other harness carries. A PID-only record reaches only the temporary,
# logged migration path above and can never be used to create a new lock.
#
# One published field can be stale on a lock this session still owns: Claude
# Code regenerates CLAUDE_CODE_SESSION_ID on /clear while the same harness
# process keeps running and keeps the lock. In that case every earlier identity
# check still holds - the recorded holder is this session's own live harness
# pid, its kind matches, and that pid equals this session's own pid - so only
# the session-id comparison is exempted, and only for a claude-kind binding.
# Every other kind carries its session identity in its pid, so a session
# mismatch there is a same-pid successor and still fails closed; so does a lock
# recorded to a different live pid, and so does an unreadable session identity.
fm_session_lock_owned_by_current_session() {  # <state-dir>
  local state=$1 lock_pid
  if fm_session_lock_read_record "$state"; then
    fm_session_lock_prepare_acquisition_identity || return 1
    lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
    [ "$lock_pid" = "$FM_SESSION_LOCK_RECORD_PID" ] || return 1
    fm_harness_pid_alive "$lock_pid" || return 1
    [ "$FM_SESSION_LOCK_OWNER_KIND" = "$FM_SESSION_LOCK_RECORD_KIND" ] || return 1
    [ "$FM_SESSION_LOCK_OWNER_PID" = "$FM_SESSION_LOCK_RECORD_PID" ] || return 1
    [ "$FM_SESSION_LOCK_OWNER_SESSION" = "$FM_SESSION_LOCK_RECORD_SESSION" ] && return 0
    [ "$FM_SESSION_LOCK_RECORD_KIND" = claude ]
    return
  fi
  fm_session_lock_owned_by_legacy_compatibility "$state"
}
