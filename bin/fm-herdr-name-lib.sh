#!/usr/bin/env bash
# fm-herdr-name-lib.sh - the single owner of the Herdr session DISPLAY NAME.
#
# Every herdr task tab firstmate creates is labelled with a configurable
# prefix followed by the project and the task:
#   <prefix>-<project>-<task-id>
# where the prefix defaults to `adix` (the captain's own words).
# A host segment is inserted after the prefix ONLY when this home has an
# explicit host token configured, so most tabs stay short:
#   adix-firstmate-herdr-session-naming      (no host configured)
#   adix-adi1-firstmate-herdr-session-naming (config/herdr-session-host=adi1)
#   adix-lifeos-adi1                          (the lifeos-adi1 secondmate itself)
#
# This label is a DISPLAY name only. Task identity, endpoint resolution,
# supervision, teardown, and recovery keep using the recorded
# state/<id>.meta endpoint - never this string. bin/backends/herdr.sh's
# presentation journal, workspace labels, and the `fm-<id>` legacy tab label
# all remain as they were; only a freshly created task tab takes the display
# name, and existing live sessions are never renamed or restarted. The legacy
# `fm-<id>` form survives solely as the create_task husk-replacement alias.
#
# Segments:
#   prefix  - fm_herdr_name_prefix: local config/herdr-session-prefix, else
#             `adix`. Whitespace is stripped and the value is sanitized.
#   host    - fm_herdr_name_host_optional: FM_HERDR_HOST, else local
#             config/herdr-session-host, else EMPTY. An absent host is omitted
#             from the label, so a plain home never carries a host segment.
#             config/herdr-session-host is LOCAL and deliberately NOT inherited:
#             which machine a home runs on is a property of that machine.
#   project - the registered project name (the project clone's directory name),
#             `firstmate` for a firstmate-repo task, or the secondmate id for a
#             secondmate agent.
#   task-id - the task id, with a single leading `fm-` stripped so the common
#             firstmate task id does not repeat that prefix.
#
# A segment equal to the segment immediately before it is dropped, so a
# secondmate agent (project == task id) renders `adix-<id>` rather than
# `adix-<id>-<id>`.
#
# No side effects on source. set -u / set -e safe.

FM_HERDR_NAME_PREFIX_CONFIG="herdr-session-prefix"
FM_HERDR_NAME_HOST_CONFIG="herdr-session-host"
FM_HERDR_NAME_DEFAULT_PREFIX="adix"
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

# fm_herdr_name_read_config <config-dir> <filename>: the whitespace-stripped
# content of one regular, non-symlink config file, or empty.
fm_herdr_name_read_config() {  # <config-dir> <filename>
  local config_dir=${1:-} filename=${2:-} file
  [ -n "$config_dir" ] || return 0
  file="$config_dir/$filename"
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    tr -d '[:space:]' < "$file" 2>/dev/null
  fi
}

# fm_herdr_name_prefix [<config-dir>]: the label prefix. config/herdr-session-prefix
# wins when set; an absent or empty value falls back to `adix`.
fm_herdr_name_prefix() {  # [<config-dir>]
  local config_dir=${1:-} value
  value=$(fm_herdr_name_sanitize "$(fm_herdr_name_read_config "$config_dir" "$FM_HERDR_NAME_PREFIX_CONFIG")")
  [ -n "$value" ] || value=$FM_HERDR_NAME_DEFAULT_PREFIX
  printf '%s' "$value"
}

# fm_herdr_name_host_optional [<config-dir>]: the explicit host token, or empty
# when this home is not configured with one. Never falls back to the machine
# hostname: an unconfigured home renders a plain `<prefix>-<project>-<task>`.
fm_herdr_name_host_optional() {  # [<config-dir>]
  local config_dir=${1:-} value=
  if [ -n "${FM_HERDR_HOST:-}" ]; then
    value=$(fm_herdr_name_sanitize "$FM_HERDR_HOST")
  else
    value=$(fm_herdr_name_sanitize "$(fm_herdr_name_read_config "$config_dir" "$FM_HERDR_NAME_HOST_CONFIG")")
  fi
  printf '%s' "$value"
}

# fm_herdr_name_task_segment <task-id>: the task label segment. A single
# leading `fm-` is stripped so `fm-herdr-session-naming` renders as
# `herdr-session-naming` and the composed label stays readable.
fm_herdr_name_task_segment() {  # <task-id>
  local id=${1:-}
  printf '%s' "${id#fm-}"
}

# fm_herdr_name_label <prefix> <host> <project> <task-id>: compose the display
# label. Each segment is sanitized; an empty host is omitted; a segment equal
# to the one before it is dropped.
fm_herdr_name_label() {  # <prefix> <host> <project> <task-id>
  local prefix host project task seg out='' prev=''
  prefix=$(fm_herdr_name_sanitize "${1:-}")
  host=$(fm_herdr_name_sanitize "${2:-}")
  project=$(fm_herdr_name_sanitize "${3:-}")
  task=$(fm_herdr_name_sanitize "$(fm_herdr_name_task_segment "${4:-}")")
  [ -n "$prefix" ] || prefix=$FM_HERDR_NAME_DEFAULT_PREFIX
  for seg in "$prefix" "$host" "$project" "$task"; do
    [ -n "$seg" ] || continue
    [ "$seg" = "$prev" ] && continue
    if [ -z "$out" ]; then out=$seg; else out="$out-$seg"; fi
    prev=$seg
  done
  printf '%s' "$out"
}

# fm_herdr_name_label_for <config-dir> <kind> <task-id> <project-dir>: the
# one-call composer bin/fm-spawn.sh uses. <kind> is the spawn kind (`secondmate`
# or anything else); <project-dir> is the resolved project directory for a
# crewmate/scout and is ignored for a secondmate, whose project is its own id.
fm_herdr_name_label_for() {  # <config-dir> <kind> <task-id> <project-dir>
  local config_dir=${1:-} kind=${2:-} id=${3:-} project_dir=${4:-} project prefix host
  if [ "$kind" = secondmate ]; then
    project=$id
  else
    project=$(basename "$project_dir" 2>/dev/null)
  fi
  prefix=$(fm_herdr_name_prefix "$config_dir")
  host=$(fm_herdr_name_host_optional "$config_dir")
  fm_herdr_name_label "$prefix" "$host" "$project" "$id"
}

# fm_herdr_name_seed_host_config <home> <token>: write the sanitized token into
# <home>/config/herdr-session-host ONLY when that file does not already exist, so
# a deliberate operator override is never clobbered. The remote-secondmate
# launch uses this to give that home its registry host segment for its own tab
# and every crewmate or scout it later spawns. Best-effort: a naming seed never
# fails a caller and returns 0 even when nothing is written.
fm_herdr_name_seed_host_config() {  # <home> <token>
  local home=${1:-} token config_dir host_file tmp
  token=$(fm_herdr_name_sanitize "${2:-}")
  [ -n "$home" ] && [ -n "$token" ] || return 0
  config_dir="$home/config"
  host_file="$config_dir/$FM_HERDR_NAME_HOST_CONFIG"
  [ -L "$config_dir" ] && return 0
  if [ -e "$host_file" ] || [ -L "$host_file" ]; then
    return 0
  fi
  [ -d "$config_dir" ] || return 0
  tmp="$host_file.tmp.$$"
  if printf '%s\n' "$token" > "$tmp" 2>/dev/null && mv -f "$tmp" "$host_file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}
