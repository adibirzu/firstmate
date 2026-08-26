#!/usr/bin/env bash
# Behavior tests for the idle signal heartbeat line in bin/fm-watch.sh.
#
# Guarantees under test:
#   - fleet_idle_signal counts:
#     * X secondmates idle (healthy)
#     * Y ships active (working/busy)
#     * Z awaiting your word (needs-decision, hold-kind: captain, paused)
#     * W blocked
#   - format is exactly:
#     "Fleet: X secondmates idle (healthy), Y ships active, Z awaiting your word, W blocked."
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-idle-signal)
fm_git_identity

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

# Extract fleet_idle_signal from bin/fm-watch.sh to test it cleanly.
eval "$(sed -n '/^fleet_idle_signal() {/,/^}/p' "$ROOT/bin/fm-watch.sh")"

# --- Test 1: Empty fleet ---
{
  dir="$TMP_ROOT/test-empty"
  mkdir -p "$dir/state" "$dir/data"
  STATE="$dir/state"
  FM_HOME="$dir"

  out=$(fleet_idle_signal)
  expected="Fleet: 0 secondmates idle (healthy), 0 ships active, 0 awaiting your word, 0 blocked."
  [ "$out" = "$expected" ] || fail "empty fleet expected '$expected', got '$out'"
  pass "idle-signal: empty fleet reports 0 across all categories"
}

# --- Test 2: Mixed fleet state ---
{
  dir="$TMP_ROOT/test-mixed"
  mkdir -p "$dir/state" "$dir/data"
  STATE="$dir/state"
  FM_HOME="$dir"

  # 2 healthy secondmates
  printf 'kind=secondmate\nhome=%s/sm1\n' "$dir" > "$STATE/sm1.meta"
  printf 'kind=secondmate\nhome=%s/sm2\n' "$dir" > "$STATE/sm2.meta"
  # 1 dead secondmate (should not count as healthy)
  printf 'kind=secondmate\nhome=%s/sm3\n' "$dir" > "$STATE/sm3.meta"
  touch "$STATE/sm3.dead"

  # 3 ships active (working)
  printf 'kind=ship\n' > "$STATE/ship1.meta"
  printf 'working: running tests\n' > "$STATE/ship1.status"
  printf 'kind=ship\n' > "$STATE/ship2.meta"
  printf 'busy: compiling\n' > "$STATE/ship2.status"
  printf 'kind=ship\n' > "$STATE/ship3.meta"
  printf 'working: implementing\n' > "$STATE/ship3.status"

  # 1 ship blocked
  printf 'kind=ship\n' > "$STATE/ship4.meta"
  printf 'blocked: missing auth\n' > "$STATE/ship4.status"

  # 2 awaiting word in state + backlog items
  printf 'kind=ship\n' > "$STATE/ship5.meta"
  printf 'needs-decision: approve approach A or B\n' > "$STATE/ship5.status"
  printf 'kind=ship\n' > "$STATE/ship6.meta"
  printf 'paused: waiting for upstream\n' > "$STATE/ship6.status"

  out=$(fleet_idle_signal)
  expected="Fleet: 2 secondmates idle (healthy), 3 ships active, 2 awaiting your word, 1 blocked."
  [ "$out" = "$expected" ] || fail "mixed fleet expected '$expected', got '$out'"
  pass "idle-signal: accurately counts secondmates, active ships, awaiting word, and blocked"
}

printf 'All fm-watch-idle-signal tests passed.\n'
