#!/usr/bin/env bash
# agy (Antigravity CLI) `Stop` hook adapter for a firstmate PRIMARY session: the
# park model, ported from bin/fm-turnend-guard-cursor.sh.
#
# Registered in tracked .agents/hooks.json. agy runs a Stop hook synchronously
# and awaits it at the end of every execution loop, and a hook that prints
# {"decision":"continue","reason":...} blocks the stop and re-enters the loop
# with the reason injected as a system message (verified live, agy 1.4.7). One
# script therefore owns both halves of agy primary supervision:
#
#   PARK      while supervision is needed, foreground bin/fm-watch-arm.sh and
#             hold the stop open until the watcher closes with an actionable
#             wake, then return that wake as the continuation. No model tokens
#             are spent while parked. The next stop parks again, so the arm and
#             re-arm loop is hook-owned, never model-memory-owned.
#   BACKSTOP  when the park cannot establish supervision, return the shared
#             turn-end guard's repair instruction as a bounded continuation.
#
# Every path exits 0 and the only channel is one JSON object on stdout:
# {"decision":"continue","reason":...} to keep the loop going, {} to let agy
# stop. A hook that overruns its registered `timeout` is killed and the stop
# proceeds (verified live: a 40s hook under a 20s timeout never produced its
# continuation), so the park's own bound (FM_AGY_PARK_SECONDS) sits below the
# registered timeout and ends with a bounded checkpoint continuation instead.
#
# The stop payload carries conversationId, executionNum, terminationReason, and
# fullyIdle. Only a NO_TOOL_CALL stop on a fully idle loop is parked on; a user
# cancel, an error, and a limit stop hand control back untouched, and a stop with
# background work still running is not yet the end of the turn.
#
# LOOP BOUNDING. agy ends a forced-continuation chain after executionNum 10
# (eleven Stop calls, measured live with an always-continue hook), after which it
# stops calling the hook for that chain. FM_AGY_TURNEND_LOOP_CEILING bounds the
# payload's own executionNum from inside, deliberately BELOW that, so the session
# is told once, loudly, instead of supervision going quiet at agy's own limit.
# A genuine wake is productive work and does not consume the separate repair
# budget; only consecutive unproductive repair nags do. Queued wakes stay durable
# past the ceiling and the captain's next message starts a fresh chain.
#
# SUPERSESSION. Each invocation publishes itself as the current park owner in
# state/.agy-park-owner, and once a newer stop has published its claim an older
# park still running stands down without emitting. Newest stop wins; the arm's
# own singleton keeps the overlap from starting a second watcher.
#
# docs/turnend-guard.md owns the cross-harness contract and compatibility limits.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
OWNER="$STATE/.agy-park-owner"
OWNER_LOCK="$STATE/.agy-park-owner.lock"
BUDGET_FILE="$STATE/.turnend-agy-blocks"

LOOP_CEILING=${FM_AGY_TURNEND_LOOP_CEILING:-8}
BLOCK_BUDGET=${FM_AGY_TURNEND_BLOCK_BUDGET:-3}
PARK_SECONDS=${FM_AGY_PARK_SECONDS:-3300}
ARM_ATTEMPTS=${FM_AGY_PARK_ATTEMPTS:-2}
POLL=${FM_AGY_PARK_POLL:-2}
LOCK_ATTEMPTS=${FM_AGY_LOCK_ATTEMPTS:-50}
case "$LOOP_CEILING" in ''|*[!0-9]*|0) LOOP_CEILING=8 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
case "$PARK_SECONDS" in ''|*[!0-9]*|0) PARK_SECONDS=3300 ;; esac
case "$ARM_ATTEMPTS" in 1|2|3) : ;; *) ARM_ATTEMPTS=2 ;; esac
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
case "$LOCK_ATTEMPTS" in ''|*[!0-9]*|0) LOCK_ATTEMPTS=50 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

# agy's documented no-op: let the loop stop.
allow_stop() {
  printf '{}\n'
  exit 0
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || allow_stop
command -v jq >/dev/null 2>&1 || allow_stop

# A malformed payload is uncertainty, not a reason to park: fail open and let
# the pull guard report the problem on the next fleet command.
EXEC_NUM=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("executionNum") then
    if ((.executionNum | type) == "number") then (.executionNum | floor) else error("executionNum") end
  else 0
  end
' 2>/dev/null) || allow_stop
case "$EXEC_NUM" in ''|*[!0-9]*) allow_stop ;; esac
REASON_CODE=$(printf '%s' "$PAYLOAD" | jq -r '.terminationReason // "NO_TOOL_CALL"' 2>/dev/null || printf 'NO_TOOL_CALL')
FULLY_IDLE=$(printf '%s' "$PAYLOAD" | jq -r 'if (.fullyIdle == false) then "false" else "true" end' 2>/dev/null || printf 'true')
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.conversationId // "unknown"' 2>/dev/null || printf 'unknown')
case "$SESSION_ID" in ''|*[!A-Za-z0-9._-]*) SESSION_ID=unknown ;; esac

# Only a normal turn completion on a fully idle loop is a turn end worth
# guarding. A cancel hands control back to the human, an error or limit stop
# must not be argued with, and a stop with background work running is not yet
# the end of the turn.
[ "$REASON_CODE" = NO_TOOL_CALL ] || allow_stop
[ "$FULLY_IDLE" = true ] || allow_stop

fm_primary_scope_matches "$FM_ROOT" "$STATE" || allow_stop

lock_acquire_bounded() {  # <lock>
  local lock=$1 attempt=0
  while [ "$attempt" -lt "$LOCK_ATTEMPTS" ]; do
    fm_lock_try_acquire "$lock" && return 0
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$LOCK_ATTEMPTS" ] && sleep 0.1
  done
  return 1
}

# Emit exactly one continuation object and stop. jq owns the JSON escaping so an
# embedded quote, newline, or the U+2063 prefix cannot corrupt the response.
emit_continue() {  # <kind> <body> [reset-budget]
  local kind=$1 body=$2 reset_budget=${3-} encoded response
  fm_operational_input_encode "$kind" "$body" encoded || allow_stop
  response=$(jq -n --arg m "$encoded" '{decision:"continue",reason:$m}' 2>/dev/null) || allow_stop
  lock_acquire_bounded "$OWNER_LOCK" || allow_stop
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    allow_stop
  fi
  if [ "$reset_budget" = reset-budget ] && ! budget_reset; then
    fm_lock_release "$OWNER_LOCK"
    allow_stop
  fi
  printf '%s\n' "$response" || true
  fm_lock_release "$OWNER_LOCK"
  exit 0
}

budget_read() {
  local session count
  BUDGET_COUNT=0
  [ -f "$BUDGET_FILE" ] || return 0
  session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$session" = "$SESSION_ID" ] && BUDGET_COUNT=$count
  return 0
}

budget_write() {  # <count>
  local tmp="$BUDGET_FILE.tmp.$$" status=0
  [ ! -d "$BUDGET_FILE" ] || return 1
  printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$1" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null \
    || status=1
  rm -f "$tmp" 2>/dev/null || true
  return "$status"
}

budget_reset() {
  rm -f "$BUDGET_FILE" 2>/dev/null
}

budget_reset_if_ours() {
  lock_acquire_bounded "$OWNER_LOCK" || allow_stop
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    allow_stop
  fi
  budget_reset || {
    fm_lock_release "$OWNER_LOCK"
    allow_stop
  }
  fm_lock_release "$OWNER_LOCK"
}

emit_repair_continue() {  # <reason> <arm-tail> <attempt>
  local reason=$1 arm_tail=$2 attempt_count=$3 prior count body encoded response
  park_still_ours || allow_stop
  budget_read
  [ "$BUDGET_COUNT" -lt "$BLOCK_BUDGET" ] || allow_stop
  prior=$BUDGET_COUNT
  count=$((prior + 1))

  body="TURN WOULD END BLIND - supervision is off. The hook-owned watcher park could not establish a live cycle after $attempt_count bounded attempts (nag $count of $BLOCK_BUDGET).
$arm_tail

$reason"
  fm_operational_input_encode turn-end-guard "$body" encoded || allow_stop
  response=$(jq -n --arg m "$encoded" '{decision:"continue",reason:$m}' 2>/dev/null) || allow_stop

  lock_acquire_bounded "$OWNER_LOCK" || allow_stop
  if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
    fm_lock_release "$OWNER_LOCK"
    allow_stop
  fi
  budget_read
  if [ "$BUDGET_COUNT" -ne "$prior" ] || ! budget_write "$count"; then
    fm_lock_release "$OWNER_LOCK"
    allow_stop
  fi
  printf '%s\n' "$response" || true
  fm_lock_release "$OWNER_LOCK"
  exit 0
}

# --- park ownership ----------------------------------------------------------
# Last arrival wins. The short owner lock serializes publication with only the
# final ownership, away-mode, output, and repair-budget commit.
claim_park() {
  local seq tmp
  lock_acquire_bounded "$OWNER_LOCK" || return 1
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  PARK_SEQ=$((seq + 1))
  tmp="$OWNER.tmp.${BASHPID:-$$}"
  if ! printf 'seq=%s pid=%s updated_at=%s\n' "$PARK_SEQ" "${BASHPID:-$$}" "$(date +%s)" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$OWNER" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$OWNER_LOCK"
  return 0
}

park_still_ours() {
  local seq
  seq=$(sed -n 's/^seq=\([0-9][0-9]*\) .*/\1/p' "$OWNER" 2>/dev/null || true)
  [ "$seq" = "$PARK_SEQ" ]
}

current_session_still_ours() {
  local owner
  owner=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  [ "$owner" = "$OWNER_ID" ] || return 1
  fm_session_lock_owned_by_current_session "$STATE"
}

# Only the lock-owning session may arm or wake. A prior session that died
# leaving its numeric harness pid behind is the one recoverable
# case, delegated to bin/fm-lock.sh so acquisition keeps its single owner.
if ! fm_session_lock_owned_by_current_session "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in ''|*[!0-9]*) allow_stop ;; esac
  fm_harness_pid_alive "$LOCK_PID" && allow_stop
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || allow_stop
  fm_session_lock_owned_by_current_session "$STATE" || allow_stop
fi

OWNER_ID=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$OWNER_ID" in ''|*[!0-9]*) allow_stop ;; esac

PARK_SEQ=
claim_park || allow_stop

# agy's own chain limit is the outer ceiling; this inner one bites first so the
# session is told once, loudly, instead of supervision going quiet unannounced.
if [ "$EXEC_NUM" -ge "$LOOP_CEILING" ]; then
  [ "$EXEC_NUM" -eq "$LOOP_CEILING" ] || allow_stop
  fm_supervision_needed "$STATE" "$GRACE" || allow_stop
  emit_continue turn-end-guard "FIRSTMATE SUPERVISION CONTINUATION CEILING REACHED - this session has taken $EXEC_NUM consecutive hook-driven continuations without a captain message, so automatic wake delivery stops here to bound the loop. Queued wakes stay durable: run bin/fm-wake-drain.sh, handle them, and run its exact WAKE_ACK_REQUIRED command. Supervision resumes automatically at the next turn end after the captain's next message."
fi

# Away mode owns the watcher and its own triage; never park and never wake.
[ -e "$STATE/.afk" ] && allow_stop

if ! fm_supervision_needed "$STATE" "$GRACE"; then
  budget_reset_if_ours
  allow_stop
fi

# X mode cadence: an opted-in home polls Relay at its generated cadence.
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- the park ----------------------------------------------------------------
# The arm runs as a tracked child of THIS hook process, which stays alive and
# waits on it - never a fire-and-forget shell `&`, whose child would be reaped
# the moment the hook returned, leaving no watcher at all. Polling rather than
# blocking in `wait` is what lets a superseded park stand down promptly instead
# of surfacing a duplicate wake much later, and it is what enforces the park's
# own time bound below agy's registered hook timeout.
ARM_OUT=
ARM_PID=
ACTIONABLE=0
HEALTHY=0
STAND_DOWN=0
TIMED_OUT=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
PARK_DEADLINE=$(( $(date +%s) + PARK_SECONDS ))

# Never leave an arm child or its capture file behind, on any exit path.
trap '[ -n "$ARM_PID" ] && kill "$ARM_PID" 2>/dev/null; [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null; :' EXIT

attempt=0
while [ "$attempt" -lt "$ARM_ATTEMPTS" ]; do
  current_session_still_ours || allow_stop
  attempt=$((attempt + 1))
  ARM_OUT=$(mktemp "$STATE/.agy-park-output.XXXXXX") || ARM_OUT=
  if [ -n "$ARM_OUT" ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 &
  else
    "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  while kill -0 "$ARM_PID" 2>/dev/null; do
    # Stand down for either reason: a newer stop claimed the baton, or away mode
    # started and its daemon now owns the watcher and all triage.
    if ! park_still_ours || ! current_session_still_ours || [ -e "$STATE/.afk" ]; then
      STAND_DOWN=1
      break
    fi
    if [ "$(date +%s)" -ge "$PARK_DEADLINE" ]; then
      TIMED_OUT=1
      break
    fi
    sleep "$POLL"
  done
  if [ "$STAND_DOWN" -eq 1 ]; then
    kill "$ARM_PID" 2>/dev/null
    ARM_PID=
    allow_stop
  fi
  if [ "$TIMED_OUT" -eq 1 ]; then
    kill "$ARM_PID" 2>/dev/null
    ARM_PID=
    break
  fi
  wait "$ARM_PID" 2>/dev/null
  ARM_PID=

  # Away mode may have been entered while parked: the daemon owns triage now.
  [ -e "$STATE/.afk" ] && allow_stop

  ACTIONABLE=0
  if [ -n "$ARM_OUT" ]; then
    grep -Eq "$ACTIONABLE_RE" "$ARM_OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating inside the shared grace window.
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$ARM_ATTEMPTS" ] || break
  [ -n "$ARM_OUT" ] && rm -f "$ARM_OUT" 2>/dev/null
  ARM_OUT=
done

# The need may have vanished while parked - the fleet was torn down, or Relay
# was opted out. Nothing left to supervise, so let the loop stop quietly.
if ! fm_supervision_needed "$STATE" "$GRACE"; then
  budget_reset_if_ours
  allow_stop
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  WAKE=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$ARM_OUT" 2>/dev/null | head -8)
  emit_continue watcher "firstmate watcher wake - one supervision event needs a handling turn now.
$WAKE

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This stop hook owns watcher continuity: when the handling turn ends, the next needed cycle parks automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake." reset-budget
fi

# The park window elapsed with a healthy quiet fleet: hand the loop one bounded
# checkpoint turn so the next stop parks again under a fresh registered timeout.
if [ "$TIMED_OUT" -eq 1 ]; then
  emit_continue watcher "firstmate watcher checkpoint - the hook-owned park window of ${PARK_SECONDS}s elapsed with no wake. Run bin/fm-wake-drain.sh, handle anything it emits and run its exact WAKE_ACK_REQUIRED command, then end the turn; the next stop parks again automatically - do NOT run bin/fm-watch-arm.sh." reset-budget
fi

# A verified live cycle with a fresh beacon is positive recovery even though this
# park closed without a wake of its own: the next stop parks again.
if [ "$HEALTHY" -eq 1 ]; then
  budget_reset_if_ours
  allow_stop
fi

# The park could not establish supervision. Ask the SHARED predicate whether
# this turn would genuinely end blind, rather than deciding that here a second
# time: bin/fm-turnend-guard.sh owns the block decision and its banner for every
# harness.
GUARD_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-agy.XXXXXX") || allow_stop
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>"$GUARD_ERR"
GUARD_RC=$?
REASON=$(cat "$GUARD_ERR" 2>/dev/null || true)
rm -f "$GUARD_ERR" 2>/dev/null || true
[ "$GUARD_RC" -eq 2 ] || allow_stop

# Bounded so a persistent failure nags a few times and then stops, instead of
# turning every stop into another unproductive continuation.
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
ARM_TAIL=
[ -n "$ARM_OUT" ] && ARM_TAIL=$(grep -E '^watcher:' "$ARM_OUT" 2>/dev/null | head -4)
emit_repair_continue "$REASON" "$ARM_TAIL" "$attempt"
