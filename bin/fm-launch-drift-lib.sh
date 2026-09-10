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
# persist neither across a server restart. Detection at supervision time is
# therefore the only cover, which is what this file owns.
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
#   unknown - a side could not be read. NEVER an alarm: an unreadable endpoint,
#             a pre-detector task record, or a pane that is not running the
#             harness at all must not be reported as drift.
#   warn    - a real divergence that is not the severe case.
#   severe  - the worker is live in the project's primary checkout.
#
# Severity ordering is severe > warn > unknown > ok: the worst axis wins, so a
# primary-checkout finding is never masked by a healthy argv.

# fm_launch_drift_unquote: strip one layer of leading and trailing shell quotes
# from a token.
#
# The recorded launch is a shell command LINE, so the launch-env isolation
# wrapper's `/bin/sh -c '<launch>'` leaves its quote characters attached to the
# first and last tokens inside it - `'FM_HOME=/h` and `--some-flag'`. Comparing
# those against a live process argv, where no quotes survive, would report every
# isolated launch as having lost its last flag.
fm_launch_drift_unquote() {  # <token>
  local token=$1
  token=${token#[\'\"]}
  token=${token%[\'\"]}
  printf '%s\n' "$token"
}

# fm_launch_drift_flags: print the HARNESS's own flag tokens from a recorded
# launch command, one per line. Whitespace splitting is deliberate and
# sufficient: a flag the harness was launched with appears as its own token in
# the live process argv.
#
# Only tokens AFTER the harness executable count. The launch string may be
# wrapped by the launch-env isolation prefix
# (`/usr/bin/env -i HOME=... /bin/sh -c '<real launch>'`), and that wrapper's
# own flags - `-i`, `-c` - never reach the harness process. Requiring them
# would report every isolated launch as having lost its flags. Tokens are
# deduplicated so a flag repeated in the wrapper is not required twice.
fm_launch_drift_flags() {  # <launch-command>
  local token base seen=$'\n' harness_seen=0
  for token in $1; do
    token=$(fm_launch_drift_unquote "$token")
    if [ "$harness_seen" = 0 ]; then
      case "$token" in
        -*|*=*) continue ;;
      esac
      base=${token##*/}
      case "$base" in
        env|sh|bash|zsh|unset|exec) continue ;;
      esac
      harness_seen=1
      continue
    fi
    case "$token" in
      -*) ;;
      *) continue ;;
    esac
    case "$seen" in
      *$'\n'"$token"$'\n'*) continue ;;
    esac
    seen="$seen$token"$'\n'
    printf '%s\n' "$token"
  done
}

# fm_launch_drift_harness_token: print the harness executable token a recorded
# launch is expected to produce in a live argv. It is the first token that is
# neither a flag nor an env assignment nor a shell the wrapper interposes, which
# is what `/usr/bin/env -i A=1 /bin/sh -c 'FM_HOME=x claude --flag'` reduces to.
fm_launch_drift_harness_token() {  # <launch-command>
  local token base
  for token in $1; do
    token=$(fm_launch_drift_unquote "$token")
    case "$token" in
      -*|*=*) continue ;;
    esac
    base=${token##*/}
    case "$base" in
      env|sh|bash|zsh|unset|exec) continue ;;
    esac
    printf '%s\n' "$base"
    return 0
  done
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
# An empty live_argv, or a live argv that does not carry the harness at all,
# is deliberately `unknown` on the argv axis rather than `argv-loss`: a pane
# sitting at a shell prompt after the agent exited is a different condition,
# already owned by bin/fm-crew-state.sh's own state read, and reporting it as
# lost flags would bury the real signal under noise.
fm_launch_drift_verdict() {  # <recorded-argv> <worktree> <project> <live-cwd> <live-argv>
  local recorded=$1 worktree=$2 project=$3 live_cwd=$4 live_argv=$5
  local cwd_sev=unknown cwd_code=cwd-unreadable cwd_detail
  local argv_sev=unknown argv_code=argv-unreadable argv_detail
  local harness flag missing=

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
  elif ! harness=$(fm_launch_drift_harness_token "$recorded"); then
    argv_detail="recorded launch command names no harness executable"
  elif [ "${live_argv#*"$harness"}" = "$live_argv" ]; then
    argv_detail="endpoint is not running $harness"
  else
    argv_sev=ok argv_code=argv-ok argv_detail="launched flags intact"
    while IFS= read -r flag; do
      [ -n "$flag" ] || continue
      case " $live_argv " in
        *" $flag "*|*" $flag="*) continue ;;
      esac
      missing=$flag
      break
    done <<FLAGS
$(fm_launch_drift_flags "$recorded")
FLAGS
    if [ -n "$missing" ]; then
      argv_sev=warn argv_code=argv-loss
      argv_detail="$harness restarted without $missing"
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
