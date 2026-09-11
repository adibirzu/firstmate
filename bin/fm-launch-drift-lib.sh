#!/usr/bin/env bash
# bin/fm-launch-drift-lib.sh - single owner of the launch-drift contract.
#
# Why this exists: a restored worker can come back without the flags it was
# launched with, or in the wrong working directory. Both have been observed in
# production, and the severe case is a worker restored into the project's
# PRIMARY CHECKOUT instead of its isolated task worktree, where its edits land
# in the checkout firstmate itself operates from.
#
# No supported runtime backend can prevent this on its own. Herdr persists a
# pane's live cwd but records no launch command at all from 0.8.0 onward
# (docs/herdr-backend.md "Launch-argv replay"), and tmux, zellij, and cmux
# persist neither across a server restart. Herdr alone exposes an atomic,
# boundary-preserving live argv read, so only it covers the argv axis. tmux
# reports argv unknown because it lacks such a read. Tmux and Herdr expose the
# passive live-cwd reads used by supervision; zellij, cmux, and Orca report
# unknown on that axis rather than having supervision type into a live pane.
# Detection at supervision time is therefore the available cover, which is what
# this file owns.
#
# The comparison is between what the spawn RECORDED (state/<id>.meta's
# launch_argv= and worktree=, published by bin/fm-spawn.sh) and what the
# endpoint is LIVE running now (read by the caller through its backend). This
# file performs no I/O: it takes both sides as arguments and returns a verdict,
# so the policy is testable without a backend, a harness, or a live agent.
#
# Verdict line, tab-separated, always printed, always exit 0:
#
#   <severity>\t<code>\t<detail>
#
# severity is one of:
#   ok      - the endpoint matches its record on both axes.
#   unknown - an axis could not be read. An unreadable cwd never alarms, and an
#             unreadable argv, a pre-detector record, or a pane not running the
#             harness never alarms on the argv axis. A verified cwd divergence
#             can still report warn or severe without a launch record.
#   warn    - a real divergence that is not the severe case.
#   severe  - the worker is live in the project's primary checkout.
#
# Severity ordering is severe > warn > unknown > ok: the worst axis wins, so a
# primary-checkout finding is never masked by a healthy argv.

# fm_launch_drift_shell_tokens: print the shell words in <launch-command>, with
# shell quoting and backslash escapes removed. The command is recorded data, not
# shell input, so this deliberately does not evaluate substitutions or other
# shell syntax.
fm_launch_drift_shell_tokens() {  # <launch-command>
  local command=$1 token='' quote='' char next token_started=0 i
  for ((i = 0; i < ${#command}; i++)); do
    char=${command:i:1}
    if [ -n "$quote" ]; then
      if [ "$quote" = "'" ]; then
        if [ "$char" = "'" ]; then quote=''; else token+=$char; fi
      elif [ "$char" = '"' ]; then
        quote=''
      elif [ "$char" = "\\" ]; then
        i=$((i + 1))
        next=${command:i:1}
        token+=$next
      else
        token+=$char
      fi
      token_started=1
      continue
    fi
    case "$char" in
      [[:space:]])
        if [ "$token_started" = 1 ]; then
          printf '%s\n' "$token"
          token=''
          token_started=0
        fi
        ;;
      "'"|'"') quote=$char; token_started=1 ;;
      \\)
        i=$((i + 1))
        next=${command:i:1}
        token+=$next
        token_started=1
        ;;
      *) token+=$char; token_started=1 ;;
    esac
  done
  [ "$token_started" = 0 ] || printf '%s\n' "$token"
}

# fm_launch_drift_parsed_tokens: print tab-separated harness and flag tokens
# from <launch-command> after locating its recorded <harness>.
#
# The launch can have an env wrapper, an isolation shell, or the relaunch's
# `unset TRACEPARENT;` prefix. Env options that take a separate operand are
# consumed before harness selection, and an unset prefix is skipped through its
# command separator.
fm_launch_drift_parsed_tokens() {  # <launch-command> <harness>
  local launch=$1 harness=$2 token base harness_seen=0 skip_option_arg=0 skip_to_separator=0 shell_wrapper=0 shell_command=0
  while IFS= read -r token; do
    if [ "$shell_command" = 1 ]; then
      fm_launch_drift_parsed_tokens "$token" "$harness"
      return 0
    fi
    if [ "$harness_seen" = 1 ]; then
      printf 'flag\t%s\n' "$token"
      continue
    fi
    if [ "$skip_to_separator" = 1 ]; then
      case "$token" in *';') skip_to_separator=0 ;; esac
      continue
    fi
    if [ "$skip_option_arg" = 1 ]; then
      skip_option_arg=0
      continue
    fi
    if [ "$shell_wrapper" = 1 ]; then
      [ "$token" = -c ] && shell_command=1
      continue
    fi
    case "$token" in
      -u|--unset|-C|--chdir|-S|--split-string)
        skip_option_arg=1
        continue
        ;;
      -*|*=*) continue ;;
    esac
    base=${token##*/}
    case "$base" in
      env|exec) continue ;;
      sh|bash|zsh)
        shell_wrapper=1
        continue
        ;;
      unset)
        skip_to_separator=1
        continue
        ;;
    esac
    case "$harness:$base" in
      cursor:cursor-agent|cursor:agent|cursor-agent:cursor-agent|muse:muse-bin-*|"$harness:$harness") ;;
      *) continue ;;
    esac
    harness_seen=1
    printf 'harness\t%s\n' "$harness"
  done < <(fm_launch_drift_shell_tokens "$launch")
}

# fm_launch_drift_flags: print the HARNESS's own flag tokens from a recorded
# launch command, one per line. Wrapper flags never reach the harness process,
# so they are excluded. Tokens are deduplicated so a flag repeated in the
# wrapper is not required twice.
fm_launch_drift_flags() {  # <launch-command> <harness>
  local kind token seen=$'\n'
  while IFS=$'\t' read -r kind token; do
    [ "$kind" = flag ] || continue
    case "$token" in
      -*=*) token=${token%%=*} ;;
      -*) ;;
      *) continue ;;
    esac
    case "$seen" in
      *$'\n'"$token"$'\n'*) continue ;;
    esac
    seen="$seen$token"$'\n'
    printf '%s\n' "$token"
  done < <(fm_launch_drift_parsed_tokens "$1" "$2")
}

fm_launch_drift_option_has_no_operand() {  # <option>
  case "$1" in
    --dangerously-skip-permissions|--dangerously-bypass-approvals-and-sandbox|--always-approve|--trust|--yolo|-y|--auto|--full-auto|--allow-all|--no-ask-user|--tui) return 0 ;;
  esac
  return 1
}

fm_launch_drift_option_value_mode() {  # <harness> <option> <recorded-operand>
  case "$3" in
    \$\(*) ;;
    *) printf 'compare\n'; return 0 ;;
  esac
  case "$1:$2" in
    agy:-i)
      # agy's -i expansion is a non-reproducible encoded launch brief.
      printf 'exists\n'
      ;;
    opencode:--prompt)
      # opencode's --prompt expansion is a non-reproducible encoded launch brief.
      printf 'exists\n'
      ;;
    copilot:-i)
      # copilot's -i expansion is a non-reproducible encoded launch brief.
      printf 'exists\n'
      ;;
    *) printf 'compare\n' ;;
  esac
}

fm_launch_drift_option_values() {  # <launch-command> <harness>
  local kind token option value next mode i
  local -a tokens=()
  while IFS=$'\t' read -r kind token; do
    [ "$kind" = flag ] && tokens[${#tokens[@]}]=$token
  done < <(fm_launch_drift_parsed_tokens "$1" "$2")
  for ((i = 0; i < ${#tokens[@]}; i++)); do
    token=${tokens[i]}
    case "$token" in
      -*=*)
        option=${token%%=*}
        value=${token#*=}
        mode=$(fm_launch_drift_option_value_mode "$2" "$option" "$value")
        printf '%s\t%s\t%s\n' "$option" "$value" "$mode"
        ;;
      -*)
        fm_launch_drift_option_has_no_operand "$token" && continue
        [ "$((i + 1))" -lt "${#tokens[@]}" ] || continue
        next=${tokens[i + 1]}
        case "$next" in -*) continue ;; esac
        mode=$(fm_launch_drift_option_value_mode "$2" "$token" "$next")
        printf '%s\t%s\t%s\n' "$token" "$next" "$mode"
        i=$((i + 1))
        ;;
    esac
  done
}

fm_launch_drift_live_tokens() {  # <live-argv>
  local live=$1 token
  if [[ "$live" == *$'\037'* ]]; then
    while :; do
      token=${live%%$'\037'*}
      printf '%s\n' "$token"
      [ "$token" = "$live" ] && break
      live=${live#*$'\037'}
    done
    return 0
  fi
  fm_launch_drift_shell_tokens "$live"
}

fm_launch_drift_live_option_values() {  # <live-argv>
  local token option value next i
  local -a tokens=()
  while IFS= read -r token; do
    tokens[${#tokens[@]}]=$token
  done < <(fm_launch_drift_live_tokens "$1")
  for ((i = 0; i < ${#tokens[@]}; i++)); do
    token=${tokens[i]}
    case "$token" in
      -*=*)
        option=${token%%=*}
        value=${token#*=}
        printf '%s\t%s\n' "$option" "$value"
        ;;
      -*)
        [ "$((i + 1))" -lt "${#tokens[@]}" ] || continue
        next=${tokens[i + 1]}
        case "$next" in -*) continue ;; esac
        printf '%s\t%s\n' "$token" "$next"
        i=$((i + 1))
        ;;
    esac
  done
}

fm_launch_drift_live_has_flag() {  # <live-argv> <option>
  local token
  while IFS= read -r token; do
    case "$token" in "$2"|"$2="*) return 0 ;; esac
  done < <(fm_launch_drift_live_tokens "$1")
  return 1
}

fm_launch_drift_recorded_has_harness() {  # <launch-command> <harness>
  local kind token
  while IFS=$'\t' read -r kind token; do
    [ "$kind" = harness ] && return 0
  done < <(fm_launch_drift_parsed_tokens "$1" "$2")
  return 1
}

# fm_launch_drift_path_within: return 0 when <path> is <root> or sits under it.
# Both sides are compared after symlink resolution when the path still exists,
# so /tmp vs /private/tmp on macOS cannot manufacture a false divergence.
fm_launch_drift_path_within() {  # <path> <root>
  local path=$1 root=$2 rp rr
  [ -n "$path" ] && [ -n "$root" ] || return 1
  rp=$(cd "$path" 2>/dev/null && pwd -P) || rp=$path
  rr=$(cd "$root" 2>/dev/null && pwd -P) || rr=$root
  [ "$rp" = "$rr" ] || [ "${rp#"$rr"/}" != "$rp" ]
}

# fm_launch_drift_verdict: the whole policy. See the header for the output shape.
#
# An absent launch record, an empty live_argv, or a live argv that does not
# carry the harness is deliberately `unknown` on the argv axis rather than
# `argv-loss`. A pane sitting at a shell prompt after the agent exited is a
# different condition, already owned by bin/fm-crew-state.sh's own state read,
# and reporting it as lost flags would bury the real signal under noise. A
# verified cwd divergence remains independently actionable without launch_argv.
fm_launch_drift_verdict() {  # <recorded-argv> <harness> <worktree> <project> <live-cwd> <live-argv>
  local recorded=$1 harness=$2 worktree=$3 project=$4 live_cwd=$5 live_argv=$6
  local cwd_sev=unknown cwd_code=cwd-unreadable cwd_detail
  local argv_sev=unknown argv_code=argv-unreadable argv_detail
  local flag missing='' option expected_value mode live_values live_value

  if [ -z "$live_cwd" ]; then
    cwd_detail="endpoint working directory could not be read"
  elif [ -z "$worktree" ]; then
    cwd_detail="task record has no worktree to compare against"
  elif fm_launch_drift_path_within "$live_cwd" "$worktree"; then
    cwd_sev=ok cwd_code=cwd-ok cwd_detail="in its worktree"
  elif [ -n "$project" ] && fm_launch_drift_path_within "$live_cwd" "$project"; then
    cwd_sev=severe cwd_code=primary-checkout
    cwd_detail="running in the project's primary checkout $live_cwd, not its worktree $worktree"
  else
    cwd_sev=warn cwd_code=cwd-drift
    cwd_detail="running in $live_cwd, not its worktree $worktree"
  fi

  if [ -z "$recorded" ]; then
    argv_detail="task record has no launch command to compare against"
  elif [ -z "$live_argv" ]; then
    argv_detail="endpoint command line could not be read"
  elif [ -z "$harness" ]; then
    argv_detail="task record names no harness to compare against"
  elif ! fm_launch_drift_recorded_has_harness "$recorded" "$harness"; then
    argv_detail="recorded launch command does not name $harness"
  else
    argv_sev=ok argv_code=argv-ok argv_detail="launched flags intact"
    while IFS= read -r flag; do
      [ -n "$flag" ] || continue
      fm_launch_drift_live_has_flag "$live_argv" "$flag" && continue
      missing=$flag
      break
    done <<FLAGS
$(fm_launch_drift_flags "$recorded" "$harness")
FLAGS
    if [ -n "$missing" ]; then
      argv_sev=warn argv_code=argv-loss
      argv_detail="$harness restarted without $missing"
    else
      live_values=$(fm_launch_drift_live_option_values "$live_argv")
      while IFS=$'\t' read -r option expected_value mode; do
        [ -n "$option" ] || continue
        if [ "$mode" = exists ]; then
          live_value=$(printf '%s\n' "$live_values" \
            | awk -F '\t' -v option="$option" '$1 == option && length($2) { print $2; exit }')
          [ -n "$live_value" ] && continue
          argv_sev=warn argv_code=argv-loss
          argv_detail="$harness restarted without a non-empty $option operand"
          break
        fi
        if printf '%s\n' "$live_values" | grep -Fqx -- "$(printf '%s\t%s' "$option" "$expected_value")"; then
          continue
        fi
        live_value=$(printf '%s\n' "$live_values" | awk -F '\t' -v option="$option" '$1 == option { print $2; exit }')
        argv_sev=warn argv_code=argv-loss
        argv_detail="$harness restarted with $option ${live_value:-<missing>}; expected $expected_value"
        break
      done <<VALUES
$(fm_launch_drift_option_values "$recorded" "$harness")
VALUES
    fi
  fi

  fm_launch_drift_combine "$cwd_sev" "$cwd_code" "$cwd_detail" "$argv_sev" "$argv_code" "$argv_detail"
}

# fm_launch_drift_combine: worst-axis-wins reduction. Kept separate from the
# comparison above so the ordering rule has exactly one implementation.
fm_launch_drift_combine() {  # <cwd-sev> <cwd-code> <cwd-detail> <argv-sev> <argv-code> <argv-detail>
  local cwd_sev=$1 cwd_code=$2 cwd_detail=$3 argv_sev=$4 argv_code=$5 argv_detail=$6
  local rank_cwd rank_argv
  rank_cwd=$(fm_launch_drift_rank "$cwd_sev")
  rank_argv=$(fm_launch_drift_rank "$argv_sev")
  # Both axes divergent: report both, worst severity, so a supervisor is never
  # told about the flags while silently standing in the wrong checkout.
  if [ "$rank_cwd" -ge 2 ] && [ "$rank_argv" -ge 2 ]; then
    printf '%s\t%s\t%s\n' \
      "$(fm_launch_drift_worst "$cwd_sev" "$argv_sev")" \
      "$cwd_code+$argv_code" \
      "$cwd_detail; $argv_detail"
    return 0
  fi
  if [ "$rank_cwd" -ge "$rank_argv" ]; then
    printf '%s\t%s\t%s\n' "$cwd_sev" "$cwd_code" "$cwd_detail"
  else
    printf '%s\t%s\t%s\n' "$argv_sev" "$argv_code" "$argv_detail"
  fi
}

fm_launch_drift_rank() {  # <severity>
  case "$1" in
    severe) printf '3\n' ;;
    warn) printf '2\n' ;;
    unknown) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

fm_launch_drift_worst() {  # <severity> <severity>
  local a b
  a=$(fm_launch_drift_rank "$1")
  b=$(fm_launch_drift_rank "$2")
  if [ "$a" -ge "$b" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}
