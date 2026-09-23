#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks).
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four mechanisms terminate the whole process GROUP, not just the direct
# child, so a hung grandchild (a vendor CLI spawned by a wrapper script, a git
# fetch spawned by a sweep) cannot outlive the bound. GNU/BSD `timeout` does
# this by default because it does not run the command in the foreground process
# group; the perl fallback does it explicitly with setpgrp plus a negative pid,
# and the bash fallback uses monitor mode to give the bounded child its own
# process group before signaling its negative pid.
set -u

fm_timeout_mechanism() {
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

fm_run_bash_timeout() {
  local seconds=$1 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0
  shift
  command_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    "$@"
    command_rc=$?
    printf '%s\n' "$command_rc" > "$command_status"
    exit "$command_rc"
  ) &
  child_pid=$!
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_signal_process_tree() {  # <pid> <signal>: signal pid and its current descendants.
  # The foreground fallback below cannot isolate its wrapped command into its
  # own process group (staying in the caller's group is its whole contract),
  # so a group-wide kill is not available. Walk pgrep -P instead: the wrapped
  # command is frequently a script (e.g. fm-fleet-herdr-collect.sh) that forks
  # its own subprocess rather than exec'ing into it, and signaling only the
  # top-level pid leaves that grandchild running, orphaned.
  local pid=$1 sig=$2 children child
  if command -v pgrep >/dev/null 2>&1; then
    children=$(pgrep -P "$pid" 2>/dev/null || true)
  else
    children=
  fi
  kill -"$sig" "$pid" 2>/dev/null || true
  for child in $children; do
    case "$child" in ''|*[!0-9]*) continue ;; esac
    fm_signal_process_tree "$child" "$sig"
  done
}

fm_run_bash_timeout_foreground() {  # <seconds> <command...>
  local seconds=$1 deadline_status child_pid watchdog_pid command_rc monitor_was_on=0
  shift
  deadline_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-fg-deadline.XXXXXX" 2>/dev/null) || return 124
  # Run the command directly as the background job (no wrapping subshell), so
  # child_pid is the real command's pid: signaling it on expiry has to reach
  # the actual process, not a shell wrapper whose children survive its own
  # death untouched.
  "$@" &
  child_pid=$!
  # Give the watchdog its own process group (monitor mode, as fm_run_bash_timeout
  # does for its watchdog) so cancelling it on the healthy/early-finish path also
  # reaches its own `sleep` grandchild. `sleep "$seconds"` is not this subshell's
  # last statement, so bash forks it instead of exec'ing into it; a plain `kill
  # "$watchdog_pid"` only reaches the subshell wrapper and leaves that sleep
  # orphaned, holding the caller's `$(...)` pipe open until it finishes on its
  # own. The wrapped command above must NOT get the same isolation - staying in
  # the caller's process group is this function's whole contract, so an outer
  # fm_run_timed bound can still reach it.
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    fm_signal_process_tree "$child_pid" TERM
    sleep 0.2
    fm_signal_process_tree "$child_pid" KILL
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  rm -f "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_pid runner_rc command_rc
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # Run timeout asynchronously so its pid - also the process-group id created
  # by GNU/BSD timeout without --foreground - remains available for cleanup.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  "$runner" -k 1 "$seconds" bash -c '
    status_file=$1
    shift
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@" &
  runner_pid=$!
  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *) [ "$command_rc" -le 255 ] && return "$command_rc" ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$@" ;;
    perl)
      perl -MPOSIX=setsid -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setsid() or die "setsid failed: $!"; exec @ARGV; exit 127 } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
        "$seconds" "$@"
      ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}

# fm_run_timed_foreground <seconds> <command...>
#   Same contract as fm_run_timed (rc 124 means the bound fired), but never
#   isolates the command into a new process group/session. Use this instead
#   of fm_run_timed when already running inside an outer fm_run_timed bound:
#   nesting a second group-isolating bound would put the command in a
#   subtree the outer bound's group-wide kill cannot reach, orphaning it
#   instead of terminating it on the outer expiry. Because it stays in the
#   caller's group, an inner fm_run_timed_foreground command that outlives
#   its own bound is still reaped when the outer bound eventually fires.
fm_run_timed_foreground() {  # <seconds> <command...>
  local seconds=$1
  shift
  case "$(fm_timeout_mechanism)" in
    timeout) timeout -f -k 1 "$seconds" "$@" ;;
    gtimeout) gtimeout -f -k 1 "$seconds" "$@" ;;
    perl)
      perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { exec @ARGV; exit 127 } local $SIG{ALRM} = sub { kill "TERM", $pid; select undef, undef, undef, 0.2; kill "KILL", $pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
        "$seconds" "$@"
      ;;
    bash) fm_run_bash_timeout_foreground "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}
