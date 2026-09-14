#!/usr/bin/env bash
# fm-herdr-name-lib.sh - the single owner of the Herdr session DISPLAY NAME.
#
# Every herdr task tab firstmate creates is labelled
#   fm-<host>-<project>-<task-id>
# so the captain can tell at a glance, on any connected machine, which host and
# project a task belongs to (AGENTS.md task fm-herdr-session-naming). Examples:
#   fm-mini-firstmate-herdr-session-naming   (a firstmate-repo task on the Mac)
#   fm-adi1-lifeos-adi1                      (the lifeos-adi1 secondmate itself)
#   fm-adi2-ts-usage-axi-add-quota-window    (a crewmate of a remote secondmate)
#
# This label is a DISPLAY name only. Task identity, endpoint resolution,
# supervision, teardown, and recovery keep using the recorded
# state/<id>.meta endpoint - never this string. bin/backends/herdr.sh's
# presentation journal, workspace labels, and the `fm-<id>` legacy tab label
# all remain as they were; only a freshly created task tab takes the new name,
# and existing live sessions are never renamed or restarted.
#
# The label is composed from three sanitized segments:
#   host    - fm_herdr_name_host: FM_HERDR_HOST, else config/herdr-session-host,
#             else the machine's short hostname. The per-host override is LOCAL
#             and deliberately NOT inherited by secondmate homes, because the
#             host token is a property of the machine each home runs on.
#   project - the registered project name (the project clone's directory name),
#             `firstmate` for a firstmate-repo task, or the secondmate id for a
#             secondmate agent.
#   task-id - the task id, with a single leading `fm-` stripped so the common
#             firstmate task id does not double the `fm-` prefix.
#
# A segment equal to the segment immediately before it is dropped, so a
# secondmate agent (project == task id) renders `fm-<host>-<id>` rather than
# `fm-<host>-<id>-<id>`.
#
# No side effects on source. set -u / set -e safe.

FM_HERDR_NAME_HOST_CONFIG="herdr-session-host"
FM_HERDR_NAME_SEGMENT_MAX=48

# fm_herdr_name_sanitize <text>: fold arbitrary text into a label-safe token.
# Every character outside [A-Za-z0-9._-] becomes `-`, runs of `-` collapse, and
# leading/trailing `-`/`.` are trimmed. Case is preserved so a project such as
# `TMS` stays legible. Capped at FM_HERDR_NAME_SEGMENT_MAX characters.
fm_herdr_name_sanitize() {  # <text>
  local text=${1:-} out
  out=$(printf '%s' "$text" | tr -c 'A-Za-z0-9._-' '-' 2>/dev/null) || out=
  out=${out:0:$FM_HERDR_NAME_SEGMENT_MAX}
  # Trim leading/trailing separator runs, then collapse internal runs so a
  # long run of unsafe characters does not leave an ugly `----` in the label.
  out=$(printf '%s' "$out" | sed -e 's/^[-.]*//' -e 's/[-.]*$//' -e 's/--*/-/g' 2>/dev/null) || out=
  printf '%s' "$out"
}

# fm_herdr_name_host [<config-dir>]: resolve the host token for a label.
# Precedence: an explicit FM_HERDR_HOST (used by the remote-secondmate launch
# path and by tests), then local config/herdr-session-host, then the machine's
# own short hostname. Never empty: an unreadable host falls back to `local`.
fm_herdr_name_host() {  # [<config-dir>]
  local config_dir=${1:-} file value=
  if [ -n "${FM_HERDR_HOST:-}" ]; then
    value=$(fm_herdr_name_sanitize "$FM_HERDR_HOST")
  else
    if [ -n "$config_dir" ]; then
      file="$config_dir/$FM_HERDR_NAME_HOST_CONFIG"
      if [ -f "$file" ] && [ ! -L "$file" ]; then
        value=$(fm_herdr_name_sanitize "$(tr -d '[:space:]' < "$file" 2>/dev/null)")
      fi
    fi
    if [ -z "$value" ]; then
      value=$(fm_herdr_name_sanitize "$(hostname -s 2>/dev/null || hostname 2>/dev/null)")
    fi
  fi
  [ -n "$value" ] || value=local
  printf '%s' "$value"
}

# fm_herdr_name_task_segment <task-id>: the task label segment. A single
# leading `fm-` is stripped so `fm-herdr-session-naming` renders as
# `herdr-session-naming` and the composed label does not repeat the prefix.
fm_herdr_name_task_segment() {  # <task-id>
  local id=${1:-}
  printf '%s' "${id#fm-}"
}

# fm_herdr_name_label <host> <project> <task-id>: compose the display label.
# Each segment is sanitized; a segment equal to the one before it is dropped.
fm_herdr_name_label() {  # <host> <project> <task-id>
  local host project task seg out=fm prev=
  host=$(fm_herdr_name_sanitize "${1:-}")
  project=$(fm_herdr_name_sanitize "${2:-}")
  task=$(fm_herdr_name_sanitize "$(fm_herdr_name_task_segment "${3:-}")")
  for seg in "$host" "$project" "$task"; do
    [ -n "$seg" ] || continue
    [ "$seg" = "$prev" ] && continue
    out="$out-$seg"
    prev=$seg
  done
  printf '%s' "$out"
}

# fm_herdr_name_label_for <config-dir> <kind> <task-id> <project-dir>: the
# one-call composer bin/fm-spawn.sh uses. <kind> is the spawn kind (`secondmate`
# or anything else); <project-dir> is the resolved project directory for a
# crewmate/scout and is ignored for a secondmate, whose project is its own id.
fm_herdr_name_label_for() {  # <config-dir> <kind> <task-id> <project-dir>
  local config_dir=${1:-} kind=${2:-} id=${3:-} project_dir=${4:-} project host
  if [ "$kind" = secondmate ]; then
    project=$id
  else
    project=$(basename "$project_dir" 2>/dev/null)
  fi
  host=$(fm_herdr_name_host "$config_dir")
  fm_herdr_name_label "$host" "$project" "$id"
}
