#!/usr/bin/env bash

if ! declare -F fm_harness_path_name >/dev/null 2>&1; then
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$(dirname -- "${BASH_SOURCE[0]}")/fm-session-lock-lib.sh"
fi
if ! declare -F fm_gemini_args_are_gemini >/dev/null 2>&1; then
  # shellcheck source=bin/fm-gemini-lib.sh
  . "$(dirname -- "${BASH_SOURCE[0]}")/fm-gemini-lib.sh"
fi

fm_launch_drift_interpreter_script_matches() {  # <harness> <args>
  local harness=$1 args=$2 argv0 rest token name
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  case "${argv0##*/}" in
    node|node-*|node[0-9]*|MainThread|python|python[0-9]*|python[0-9].[0-9]*) ;;
    *) return 1 ;;
  esac
  rest=${args#"$argv0"}
  while [ -n "$rest" ]; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in -*) continue ;; esac
    case "$harness:$token" in
      claude:*/@anthropic-ai/claude-code/*) return 0 ;;
    esac
    if name=$(fm_harness_path_name "$token"); then
      [ "$name" = "$harness" ] && return 0
    fi
    return 1
  done
  return 1
}

fm_launch_drift_process_matches() {  # <harness> <comm> <args> [argv0]
  local harness=$1 comm=$2 args=$3 argv0=${4:-} name base
  case "$harness" in
    cursor|cursor-agent)
      fm_cursor_drift_process_matches "$comm" "$args" "$argv0"
      return
      ;;
    gemini)
      fm_gemini_args_are_gemini "$args"
      return
      ;;
    claude)
      if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
        [ "$name" = claude ] && return 0
      fi
      fm_launch_drift_interpreter_script_matches claude "$args"
      return
      ;;
    muse)
      for name in "$comm" "$argv0"; do
        base=${name##*/}
        case "$base" in muse|muse-bin-*) return 0 ;; esac
      done
      return 1
      ;;
    agy|copilot|rovo)
      for name in "$comm" "$argv0"; do
        [ "${name##*/}" = "$harness" ] && return 0
      done
      return 1
      ;;
  esac
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    [ "$name" = "$harness" ] && return 0
  fi
  fm_launch_drift_interpreter_script_matches "$harness" "$args" && return 0
  return 1
}
