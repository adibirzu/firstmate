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
