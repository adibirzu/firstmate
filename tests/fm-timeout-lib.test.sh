#!/usr/bin/env bash
# Behavior tests for fm-timeout-lib.sh's bash-fallback foreground timeout.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-timeout-lib.sh"

# fm_run_timed_foreground must terminate the actual command process at the
# requested bound, not merely return rc=124 while the real process (a
# grandchild of the wrapper it signals) keeps running. This is the contract
# every fm_run_timed_foreground caller relies on - e.g. fm-fleet-pulse.sh's
# --best-effort publish step, which counts on the collector actually dying at
# its own --timeout instead of surviving until the much larger outer bound.
test_bash_foreground_timeout_kills_the_actual_command() {
  command -v pgrep >/dev/null 2>&1 || { echo "skip: pgrep not found"; return 0; }
  local nonce rc t0 t1 elapsed waited
  nonce=$(( (($$ * 7919) + RANDOM) % 900000 + 100000 ))

  t0=$(date +%s)
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed_foreground 2 sleep "$nonce"
  rc=$?
  t1=$(date +%s)
  elapsed=$(( t1 - t0 ))

  [ "$rc" -eq 124 ] || fail "bash-fallback foreground timeout must report rc=124 on expiry, got $rc"
  [ "$elapsed" -le 5 ] || fail "bash-fallback foreground timeout must return near the requested bound, took ${elapsed}s"

  waited=0
  while [ "$waited" -lt 30 ]; do
    pgrep -f "sleep $nonce" >/dev/null 2>&1 || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if pgrep -f "sleep $nonce" >/dev/null 2>&1; then
    kill -KILL "$(pgrep -f "sleep $nonce")" 2>/dev/null || true
    fail "bash-fallback foreground timeout must actually terminate the command, not just its wrapper subshell"
  fi
  pass "bash-fallback foreground timeout kills the real command process, not just its wrapper subshell"
}

test_bash_foreground_timeout_kills_the_actual_command

# Companion to the case above: the wrapped command is not always the leaf
# process itself. The real production shape (fm-fleet-pulse.sh's collector
# step, fm-fleet-herdr-collect.sh) is a script that forks its own subprocess
# rather than exec'ing straight into it. Signaling only the wrapped command's
# own top-level pid never reaches that forked grandchild, which inherits the
# command substitution's stdout pipe and is left running, orphaned, once its
# parent script dies.
test_bash_foreground_timeout_kills_the_wrapped_commands_own_children() {
  command -v pgrep >/dev/null 2>&1 || { echo "skip: pgrep not found"; return 0; }
  local nonce rc t0 t1 elapsed waited wrapper
  nonce=$(( (($$ * 7919) + RANDOM) % 900000 + 100000 ))
  wrapper=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-lib-test-wrapper.XXXXXX") || fail "mktemp failed"
  cat > "$wrapper" <<SH
#!/usr/bin/env bash
sleep $nonce &
wait
SH
  chmod +x "$wrapper"

  t0=$(date +%s)
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed_foreground 2 "$wrapper"
  rc=$?
  t1=$(date +%s)
  elapsed=$(( t1 - t0 ))
  rm -f "$wrapper"

  [ "$rc" -eq 124 ] || fail "bash-fallback foreground timeout must report rc=124 on expiry, got $rc"
  [ "$elapsed" -le 5 ] || fail "bash-fallback foreground timeout must return near the requested bound, took ${elapsed}s"

  waited=0
  while [ "$waited" -lt 30 ]; do
    pgrep -f "sleep $nonce" >/dev/null 2>&1 || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if pgrep -f "sleep $nonce" >/dev/null 2>&1; then
    kill -KILL "$(pgrep -f "sleep $nonce")" 2>/dev/null || true
    fail "bash-fallback foreground timeout must terminate the wrapped command's own forked children, not just its top-level pid"
  fi
  pass "bash-fallback foreground timeout kills the wrapped command's own forked children"
}

test_bash_foreground_timeout_kills_the_wrapped_commands_own_children

# Every real fm_run_timed_foreground caller invokes it through command
# substitution (e.g. fm-fleet-pulse.sh's pulse_run_step:
# SNAPSHOT=$(pulse_run_step ... fm_run_timed_foreground "$step_timeout" ...)).
# On the common healthy path - the wrapped command finishes well inside the
# bound - that substitution must return promptly, not stall until the full
# requested bound. Regression: the watchdog's internal `sleep "$seconds"` is
# not its subshell's last statement, so bash forks it rather than exec'ing
# into it; cancelling the watchdog with a plain `kill "$watchdog_pid"` then
# only reaches the subshell wrapper, leaving that sleep orphaned. Because it
# inherited the write end of the command substitution's pipe, bash cannot see
# EOF - and so cannot return - until the orphaned sleep itself exits at the
# full bound.
test_bash_foreground_timeout_returns_promptly_on_the_healthy_path() {
  local runner
  if command -v timeout >/dev/null 2>&1; then
    runner=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    runner=gtimeout
  else
    echo "skip: no real timeout/gtimeout to bound this test"
    return 0
  fi

  local t0 t1 elapsed out rc
  t0=$(date +%s)
  # shellcheck disable=SC2016  # single quotes are deliberate: expansion is deferred to the child bash -c shell.
  out=$("$runner" 20 bash -c '
    set -u
    . "$1"
    out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed_foreground 60 sleep 0.3)
    printf "%s\n" "$?"
  ' _ "$ROOT/bin/fm-timeout-lib.sh")
  rc=$?
  t1=$(date +%s)
  elapsed=$(( t1 - t0 ))

  [ "$rc" -ne 124 ] || fail "the outer 20s bound fired: the command substitution stalled instead of returning promptly on the healthy path"
  [ "$rc" -eq 0 ] || fail "unexpected outer failure (rc=$rc) running the fm_run_timed_foreground healthy-path repro"
  [ "$out" = 0 ] || fail "fm_run_timed_foreground must report the wrapped command's own rc (0) on the healthy path, got '$out'"
  [ "$elapsed" -le 5 ] || fail "bash-fallback foreground timeout inside \$(...) must return promptly when the wrapped command finishes quickly, took ${elapsed}s"
  pass "bash-fallback foreground timeout inside \$(...) returns promptly on the healthy path, not stalled to the full bound"
}

test_bash_foreground_timeout_returns_promptly_on_the_healthy_path
