#!/usr/bin/env bash
# Shared contract for bin/fm-remote-dev-session.sh.
#
# docs/remote-dev-sessions.md owns the operator-facing contract. This library
# owns the parts a portable test can drive without a live station: backend
# selection, the durable continuity record (schema fm-remote-dev-session.v1),
# reference derivation from a task record, attach-command rendering, and the
# pre-launch convergence/equivalence verdict.
#
# Every function here is read-only over the station, the project clone, and the
# durable records; the command header owns the mutating verbs.
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
set -u

FM_RDS_SCHEMA='fm-remote-dev-session.v1'
# The verified backends a remote development session may use. herdr is the
# default and the only one a remote second mate uses (docs/remote-secondmates.md);
# tmux is reachable only by an explicit flag or config value, never silently.
FM_RDS_BACKENDS='herdr tmux'
FM_RDS_DIRNAME='remote-dev-sessions'
# Every field the continuity record persists. The command writes exactly these;
# the reader rejects anything else, so a corrupt or hand-edited record is
# reported rather than half-trusted.
FM_RDS_KEYS='schema station local host backend session workspace window tab pane task_id project branch worktree spawn_gen return_channel attach_command updated'

fm_rds_backend_known() {  # <backend>
  case " $FM_RDS_BACKENDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# The configured default backend. An absent or empty config file means herdr; a
# value that is not a known backend is reported to the caller, never silently
# replaced, so a typo cannot quietly change a station's session provider.
fm_rds_config_backend() {  # <config-file>
  local file=$1 value
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    printf 'herdr\n'
    return 0
  fi
  value=$(tr -d ' \t\r\n' < "$file" 2>/dev/null || true)
  case "$value" in
    '') printf 'herdr\n' ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# Resolve the session backend. An explicit flag wins; otherwise the configured
# value; otherwise herdr. An unknown value is an invalid-use error (exit 2) so a
# mistyped backend refuses instead of selecting one.
fm_rds_resolve_backend() {  # <explicit|''> <config-file>
  local explicit=${1:-} config=$2 resolved
  if [ -n "$explicit" ]; then
    fm_rds_backend_known "$explicit" \
      || { printf 'unknown backend: %s (known: %s)\n' "$explicit" "$FM_RDS_BACKENDS" >&2; return 2; }
    printf '%s\n' "$explicit"
    return 0
  fi
  resolved=$(fm_rds_config_backend "$config")
  fm_rds_backend_known "$resolved" \
    || { printf 'unknown backend in config: %s (known: %s)\n' "$resolved" "$FM_RDS_BACKENDS" >&2; return 2; }
  printf '%s\n' "$resolved"
}

# The dedicated named session remote work shares. The remote-secondmate doctor
# owns the same value for the herdr server it provisions; docs/remote-dev-sessions.md
# is the cross-reference.
fm_rds_default_session() { printf 'fm-remote\n'; }

fm_rds_record_dir() {  # <state-dir>
  printf '%s/%s\n' "$1" "$FM_RDS_DIRNAME"
}

fm_rds_record_path() {  # <state-dir> <station>
  printf '%s/%s/%s.session\n' "$1" "$FM_RDS_DIRNAME" "$2"
}

# Atomically write the record from canonical key=value lines. The only accepted
# keys are FM_RDS_KEYS, and a record must carry the schema line.
fm_rds_record_write() {  # <path> <key=value>...
  local path=$1
  shift
  local dir tmp kv key seen='' have_schema=0
  dir=$(dirname "$path")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$path.XXXXXX" 2>/dev/null) || return 1
  for kv in "$@"; do
    case "$kv" in
      *$'\r'*|*$'\n'*) rm -f -- "$tmp"; return 1 ;;
    esac
    key=${kv%%=*}
    case " $FM_RDS_KEYS " in
      *" $key "*) ;;
      *) rm -f -- "$tmp"; return 1 ;;
    esac
    case "$seen" in
      *$'\n'"$key"$'\n'*) rm -f -- "$tmp"; return 1 ;;
    esac
    seen+=$'\n'"$key"$'\n'
    [ "$key" != schema ] || have_schema=1
  done
  [ "$have_schema" -eq 1 ] || { rm -f -- "$tmp"; return 1; }
  {
    for kv in "$@"; do
      printf '%s\n' "$kv"
    done
  } > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

# Read and validate a record. Prints canonical key=value lines on stdout and
# returns non-zero for an absent, malformed, duplicate-key, or wrong-schema
# record. The schema line must appear first.
fm_rds_record_read() {  # <path>
  local path=$1 line key value required seen='' first=1
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || return 1
    case " $FM_RDS_KEYS " in
      *" $key "*) ;;
      *) return 1 ;;
    esac
    case "$seen" in
      *$'\n'"$key"$'\n'*) return 1 ;;
    esac
    seen+=$'\n'"$key"$'\n'
    if [ "$first" -eq 1 ]; then
      [ "$key" = schema ] && [ "$value" = "$FM_RDS_SCHEMA" ] || return 1
      first=0
    fi
    printf '%s=%s\n' "$key" "$value"
  done < "$path"
  [ "$first" -eq 0 ] || return 1
  for required in $FM_RDS_KEYS; do
    case "$seen" in
      *$'\n'"$required"$'\n'*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

fm_rds_record_get() {  # <path> <key>
  local path=$1 want=$2 line key
  while IFS= read -r line; do
    key=${line%%=*}
    [ "$key" = "$want" ] || continue
    printf '%s\n' "${line#*=}"
    return 0
  done <<EOF
$(fm_rds_record_read "$path" 2>/dev/null || true)
EOF
  return 1
}

# The exact command a person runs to attach to (or reconnect to) the session.
# Rendering is the single owner of that command shape; docs/remote-dev-sessions.md
# quotes it rather than restating it.
fm_rds_attach_command() {  # <backend> <local:0|1> <host> <session>
  local backend=$1 local1=$2 host=$3 session=$4
  case "$backend" in
    herdr)
      if [ "$local1" = 1 ]; then
        printf 'herdr --session %q' "$session"
      else
        printf 'herdr --remote %q --session %q' "$host" "$session"
      fi
      ;;
    tmux)
      if [ "$local1" = 1 ]; then
        printf 'tmux attach -t %q' "$session"
      else
        printf 'ssh -t %q tmux attach -t %q' "$host" "$session"
      fi
      ;;
    *) return 2 ;;
  esac
}

fm_rds_meta_value() {  # <meta-file> <key>
  local meta=$1 key=$2 line
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < "$meta"
  return 1
}

# Derive the continuity reference fields from a task record. The task record
# remains the endpoint authority (bin/fm-spawn.sh owns it); this is a cached
# projection for reconnect, refreshed on every open/recover.
fm_rds_refs_from_meta() {  # <meta-file> <backend> <project-name>
  local meta=$1 backend=$2 project=${3:-}
  local id task_id worktree spawn_gen meta_project
  local workspace='' window='' tab='' pane='' branch=''
  id=$(basename "$meta" .meta)
  task_id=$(fm_rds_meta_value "$meta" endpoint_task_id || true)
  [ -n "$task_id" ] || task_id=$id
  worktree=$(fm_rds_meta_value "$meta" worktree || true)
  spawn_gen=$(fm_rds_meta_value "$meta" spawn_gen || true)
  meta_project=$(fm_rds_meta_value "$meta" project || true)
  case "$backend" in
    herdr)
      workspace=$(fm_rds_meta_value "$meta" herdr_workspace_id || true)
      tab=$(fm_rds_meta_value "$meta" herdr_tab_id || true)
      pane=$(fm_rds_meta_value "$meta" herdr_pane_id || true)
      ;;
  esac
  window=$(fm_rds_meta_value "$meta" window || true)
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    branch=$("${FM_RDS_GIT:-git}" -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [ "$branch" != HEAD ] || branch=
  fi
  [ -n "$project" ] || project=${meta_project##*/}
  printf 'task_id=%s\n' "$task_id"
  printf 'project=%s\n' "$project"
  printf 'branch=%s\n' "$branch"
  printf 'worktree=%s\n' "$worktree"
  printf 'spawn_gen=%s\n' "$spawn_gen"
  printf 'workspace=%s\n' "$workspace"
  printf 'window=%s\n' "$window"
  printf 'tab=%s\n' "$tab"
  printf 'pane=%s\n' "$pane"
}

# --- pre-launch convergence and equivalence ---------------------------------
#
# Before a development session launches, the default branch is fetched and the
# intended branch is checked against it so duplicate or stale work refuses
# instead of starting a second run of the same change. Both helpers are
# read-only over the working tree: the fetch moves remote-tracking refs only,
# and every equivalence probe is a query.

fm_rds_git() {  # <repo> <args...>
  "${FM_RDS_GIT:-git}" -C "$1" "${@:2}"
}

# 0 when the fetch converged the default branch, non-zero with a diagnostic
# otherwise. Never checks out, resets, or stashes.
fm_rds_converge() {  # <repo> <remote> <default-branch>
  local repo=$1 remote=$2 branch=$3 out rc
  [ -n "$repo" ] && [ -d "$repo" ] || { printf 'converge: repo is not a directory: %s\n' "${repo:-<empty>}" >&2; return 2; }
  fm_rds_git "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || { printf 'converge: not a git clone: %s\n' "$repo" >&2; return 2; }
  out=$(fm_rds_git "$repo" fetch --quiet --no-tags --prune -- "$remote" "$branch" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'converge: fetch %s %s failed: %s\n' "$remote" "$branch" "${out:-unknown error}" >&2
    return 1
  fi
  return 0
}

# Resolve the ref a branch name refers to in <repo>, preferring a local branch,
# then the named remote, then origin. Prints the ref name or nothing.
fm_rds_resolve_branch_ref() {  # <repo> <remote> <branch>
  local repo=$1 remote=$2 branch=$3 ref
  local refs=("refs/heads/$branch")
  [ -n "$remote" ] && refs+=("refs/remotes/$remote/$branch")
  refs+=("refs/remotes/origin/$branch")
  for ref in "${refs[@]}"; do
    if fm_rds_git "$repo" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

# The pre-launch verdict for an intended branch.
#
#   fm_rds_equivalence <repo> <default-ref> <intended-branch> <recorded-branch> <pr-state>
#
# Prints one `verdict=...` line and returns:
#   0  ok       the work may start
#   3  duplicate an existing branch or pull request already covers this work
#   4  stale     the recorded branch is behind the default branch or already landed
#   2  invalid   the probe itself could not run
#
# <pr-state> is open|merged|closed|none|unknown. An unknown state is reported but
# never refuses the launch, because an unreadable forge probe is not evidence of
# duplicate work.
fm_rds_equivalence() {  # <repo> <default-ref> <intended-branch> <recorded-branch> <pr-state>
  local repo=$1 default_ref=$2 intended=$3 recorded=$4 pr_state=${5:-unknown}
  local ref behind cherry ahead
  case "$pr_state" in
    open|merged)
      printf 'verdict=duplicate reason=pr-%s\n' "$pr_state"
      return 3
      ;;
  esac
  fm_rds_git "$repo" rev-parse --verify --quiet "$default_ref" >/dev/null 2>&1 \
    || { printf 'verdict=invalid reason=default-ref-unresolved ref=%s\n' "$default_ref"; return 2; }
  if ! ref=$(fm_rds_resolve_branch_ref "$repo" '' "$intended"); then
    printf 'verdict=ok\n'
    return 0
  fi
  if [ -z "$recorded" ] || [ "$intended" != "$recorded" ]; then
    printf 'verdict=duplicate reason=branch-exists branch=%s\n' "$intended"
    return 3
  fi
  # The branch is this task's own work: a resume. Refuse only when it is stale.
  # A branch sitting exactly on the default tip carries no work yet and is a
  # fresh start, not a stale copy.
  if [ "$(fm_rds_git "$repo" rev-parse "$ref" 2>/dev/null || true)" = \
       "$(fm_rds_git "$repo" rev-parse "$default_ref" 2>/dev/null || true)" ]; then
    printf 'verdict=ok\n'
    return 0
  fi
  if fm_rds_git "$repo" merge-base --is-ancestor "$ref" "$default_ref" >/dev/null 2>&1; then
    printf 'verdict=stale reason=branch-already-in-default branch=%s\n' "$intended"
    return 4
  fi
  cherry=$(fm_rds_git "$repo" cherry "$default_ref" "$ref" 2>/dev/null || true)
  if [ -n "$cherry" ]; then
    if ! printf '%s\n' "$cherry" | grep -q '^+'; then
      printf 'verdict=stale reason=patch-already-in-default branch=%s\n' "$intended"
      return 4
    fi
  fi
  behind=$(fm_rds_git "$repo" rev-list --count "$ref..$default_ref" 2>/dev/null || true)
  case "$behind" in
    ''|*[!0-9]*) behind=0 ;;
  esac
  if [ "$behind" -gt 0 ]; then
    printf 'verdict=stale reason=base-behind-default branch=%s behind=%s\n' "$intended" "$behind"
    return 4
  fi
  printf 'verdict=ok\n'
  return 0
}
