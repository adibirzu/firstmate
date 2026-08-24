#!/usr/bin/env bash
# fm-model-fallback.sh - the mechanical owner of automatic in-run model
# fallback on quota depletion. It turns config/crew-dispatch.json's
# modelFallback chains into real depletion responses instead of prose.
#
# Usage:
#   fm-model-fallback.sh <task-id> plan
#   fm-model-fallback.sh <task-id> apply
#
# `plan` decides only: it verifies fresh depletion evidence, walks the task's
# configured chain, and prints one `action=` block. `apply` executes that
# decision through bin/fm-runtime-handoff.sh, which owns the guarded in-place
# relaunch that preserves the worktree and every landed or unlanded change.
#
# What apply does, in order:
#   1. Reads state/<id>.meta for kind=ship|scout, harness=, model=, and the
#      fallback cursor (the byte offset of the last evidence this script
#      consumed).
#   2. Classifies status-file text AFTER that cursor through
#      bin/fm-dispatch-select.mjs classify-evidence, whose subscription
#      vocabulary is the single owner of depletion signatures. No evidence,
#      no fallback - a healthy or ambiguous worker is never relaunched by
#      this script.
#   3. Walks the harness's modelFallback chain (legacy alias _model_fallback
#      honored): the entry after the recorded model is next; a model absent
#      from its chain steps to the chain head; the chain's last entry means
#      this runtime lane is exhausted.
#   4. When the lane is exhausted and an optional top-level fallbackLanes
#      array names a later lane, moves there and starts that lane's own
#      chain head (or its default model when that lane has no chain).
#   5. When the depleted harness carries a telemetry-backed routing provider,
#      records the verified failure through bin/fm-dispatch-select.mjs
#      record-failure so future dispatches avoid the account during the
#      cooldown; that bookkeeping failure never blocks the relaunch itself.
#   6. Relaunches in place with --model <next> and a progress note naming the
#      depletion signature and the automatic step-down. The effort axis is
#      deliberately reset so the replacement model launches on its own
#      default instead of inheriting an axis tuned for the depleted model.
#   7. Appends one `working:` status line recording the switch, then advances
#      the fallback cursor past the consumed evidence under the task's meta
#      lock, so the same evidence can never trigger a second step-down.
#
# Auto-step-down semantics (standing rule 2026-08-24): availability beats
# escalation. When the depleted model IS the strongest available class, the
# fallback still proceeds automatically - routine depletion never parks on
# the captain and never stops the fleet. The downgrade is made visible, not
# silent: the progress note, the status line, and stderr all name it.
#
# Exit codes:
#   0  plan found an action / apply executed it
#   1  refusal (bad task, missing configuration, no fresh evidence)
#   3  the whole chain - and, when configured, the whole lane order - is
#      exhausted; apply records a blocked status line before exiting
#
# Refusals are loud: a missing chain, malformed config, unreadable meta, or
# absent evidence stops the script rather than improvising a relaunch.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-model-fallback refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-model-fallback.sh <task-id> plan|apply
  plan    decide only; print action=harness-step|lane-move|exhausted fields
  apply   execute the decision through bin/fm-runtime-handoff.sh
EOF
  exit 2
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  printf 'fm-model-fallback: %s\n' "$*" >&2
}

[ $# -eq 2 ] || usage
ID=$1
VERB=$2
case "$VERB" in
  plan|apply) ;;
  *) usage ;;
esac

fm_task_id_creation_valid "$ID" || die "invalid task id '$ID'"

META="$STATE/$ID.meta"
[ -f "$META" ] || die "no meta for task $ID at $META"
[ ! -L "$META" ] || die "meta for task $ID is a symlink; refusing"

KIND=$(fm_meta_get "$META" kind)
case "$KIND" in
  ship|scout) ;;
  *)
    die "task $ID has kind='${KIND:-}'; model fallback applies to ship and scout tasks only"
    ;;
esac

HARNESS=$(fm_meta_get "$META" harness)
[ -n "$HARNESS" ] || die "meta for $ID records no harness="
CURRENT_MODEL=$(fm_meta_get "$META" model)

STATUS="$STATE/$ID.status"
[ -f "$STATUS" ] || die "no status log for task $ID at $STATUS; nothing could have reported depletion"

# Telemetry-backed providers whose credit identity quota-axi prices, mirroring
# PROVIDERS/NATIVE_PROVIDER ownership in fm-dispatch-select.mjs.
native_provider_of() {  # <harness>
  case "$1" in
    claude|codex|grok|cursor|agy) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

# --- configuration ----------------------------------------------------------

DISPATCH_CONFIG="$CONFIG/crew-dispatch.json"
if [ ! -f "$DISPATCH_CONFIG" ]; then
  die "no crew-dispatch config at $DISPATCH_CONFIG; there is no modelFallback chain to follow"
fi
command -v jq >/dev/null 2>&1 || die "jq is not installed; refusing to read crew-dispatch.json without it"
command -v node >/dev/null 2>&1 || die "node is not installed; the depletion classifier runs through bin/fm-dispatch-select.mjs"
if ! jq -e . "$DISPATCH_CONFIG" >/dev/null 2>&1; then
  die "$DISPATCH_CONFIG is malformed JSON; run bootstrap's CREW_DISPATCH validation and fix the file rather than selecting around it"
fi
if ! validation_error=$(node "$SCRIPT_DIR/fm-dispatch-select.mjs" validate-model-fallback --file "$DISPATCH_CONFIG" 2>&1); then
  validation_error=${validation_error#fm-dispatch-select: }
  die "$DISPATCH_CONFIG has invalid model fallback configuration: $validation_error"
fi

chain_of() {  # <harness> -> one model id per line, empty when unconfigured
  jq -r --arg h "$1" '
    ((.modelFallback // ._model_fallback // {})[$h] // [])
    | if type == "array" then .[] else empty end
  ' "$DISPATCH_CONFIG"
}

lanes_configured() {  # -> one harness per line, empty when unconfigured
  jq -r '.fallbackLanes // [] | if type == "array" then .[] else empty end' "$DISPATCH_CONFIG"
}

CHAIN=$(chain_of "$HARNESS")
[ -n "$CHAIN" ] || die "no modelFallback chain configured for harness '$HARNESS'; add one to $DISPATCH_CONFIG"

# --- evidence classification ------------------------------------------------

CURSOR=$(fm_meta_get "$META" fallback_cursor)
case "$CURSOR" in
  ''|*[!0-9]*) CURSOR=0 ;;
esac
STATUS_SIZE=$(wc -c < "$STATUS" | tr -d ' ')
[ "$CURSOR" -le "$STATUS_SIZE" ] || CURSOR=0

EVIDENCE_TEXT=$(tail -c +"$((CURSOR + 1))" "$STATUS" 2>/dev/null || true)
CLASSIFICATION=$(printf '%s' "$EVIDENCE_TEXT" \
  | FM_HOME="$FM_HOME" node "$SCRIPT_DIR/fm-dispatch-select.mjs" classify-evidence 2>/dev/null \
  || printf 'classification=none\n')
case "$CLASSIFICATION" in
  classification=depleted*) ;;
  *)
    if [ "$VERB" = plan ]; then
      echo "action=none"
      echo "reason=no depletion evidence after the consumed cursor at byte $CURSOR"
    else
      die "no depletion evidence in $STATUS after byte $CURSOR; a healthy or already-consumed signal is never a fallback trigger"
    fi
    exit 0
    ;;
esac
SIGNATURE=$(printf '%s\n' "$CLASSIFICATION" | sed -n 's/^signature=//p')

# --- selection --------------------------------------------------------------

NEXT_MODEL=
FOUND_CURRENT=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if [ "$FOUND_CURRENT" = 1 ]; then
    NEXT_MODEL=$entry
    break
  fi
  if [ "$entry" = "$CURRENT_MODEL" ]; then FOUND_CURRENT=1; fi
done <<EOF_CHAIN
$CHAIN
EOF_CHAIN
# A recorded model outside its chain (launched before the chain existed, or on
# the harness default) starts from the strongest configured entry; when that
# head IS the recorded model, the walk above already moved past it.
if [ "$FOUND_CURRENT" = 0 ]; then
  NEXT_MODEL=$(printf '%s\n' "$CHAIN" | sed -n '1p')
  if [ "$NEXT_MODEL" = "$CURRENT_MODEL" ]; then NEXT_MODEL=; fi
fi

ACTION=
NEXT_HARNESS=
if [ -n "$NEXT_MODEL" ]; then
  ACTION="harness-step"
else
  # This lane is walked out. Move to the next configured lane when one exists;
  # otherwise automation has done everything it can and says so loudly.
  PREV_LANE=
  while IFS= read -r lane; do
    [ -n "$lane" ] || continue
    if [ -z "$PREV_LANE" ]; then
      PREV_LANE=$lane
      continue
    fi
    if [ "$PREV_LANE" = "$HARNESS" ]; then
      NEXT_HARNESS=$lane
      break
    fi
    PREV_LANE=$lane
  done <<EOF_LANES
$(lanes_configured)
EOF_LANES
  if [ -n "$NEXT_HARNESS" ]; then
    ACTION="lane-move"
    NEXT_MODEL=$(chain_of "$NEXT_HARNESS" | sed -n '1p')
  else
    ACTION=exhausted
  fi
fi

echo "action=$ACTION"
echo "task=$ID"
echo "harness=$HARNESS"
[ -z "$CURRENT_MODEL" ] || echo "from_model=$CURRENT_MODEL"
if [ "$ACTION" = exhausted ]; then
  echo "reason=every model in the '$HARNESS' chain is depleted and no fallbackLanes successor exists"
  if [ "$VERB" = apply ]; then
    printf 'blocked: model fallback exhausted for %s (%s); needs a routing decision\n' \
      "$HARNESS" "$(printf '%s' "$CHAIN" | tr '\n' ' ')" >> "$STATUS"
  fi
  exit 3
fi
echo "to_model=$NEXT_MODEL"
[ -z "$NEXT_HARNESS" ] || echo "to_harness=$NEXT_HARNESS"
echo "signature=$SIGNATURE"

if [ "$VERB" = plan ]; then
  exit 0
fi

# --- apply ------------------------------------------------------------------

# Park the depleted provider for dispatch pricing too, best-effort: the
# cooldown keeps NEW tasks off the account while this task steps down inside
# its lane. record-failure re-verifies the evidence itself and refuses safely;
# its failure must never block the relaunch that actually rescues the work.
PROVIDER=$(native_provider_of "$HARNESS") || PROVIDER=
if [ -n "$PROVIDER" ]; then
  FM_HOME="$FM_HOME" node "$SCRIPT_DIR/fm-dispatch-select.mjs" record-failure \
    --provider "$PROVIDER" --task "$ID" >/dev/null 2>&1 \
    || log "provider=$PROVIDER cooldown was not recorded; continuing with the relaunch anyway"
fi

NOTE="Automatic model fallback: depletion evidence ($SIGNATURE) on ${CURRENT_MODEL:-the harness default model} of harness $HARNESS. Relaunching in place${NEXT_HARNESS:+ on harness $NEXT_HARNESS} with model '${NEXT_MODEL:-default}'. This automatic step-down may lower the reasoning class; standing quota rule makes availability beat escalation, and this note plus the status line keep the downgrade visible rather than silent. Preserve every commit and uncommitted change."

HANDOFF_ARGS=(
  "$ID"
  --harness "${NEXT_HARNESS:-$HARNESS}"
)
if [ -n "$NEXT_MODEL" ]; then
  HANDOFF_ARGS+=(--model "$NEXT_MODEL")
fi
HANDOFF_ARGS+=(
  --progress-note "$NOTE"
)

if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-runtime-handoff.sh" "${HANDOFF_ARGS[@]}"; then
  die "in-place fallback relaunch failed for $ID; worktree and work were left intact and the evidence cursor was not advanced"
fi

# The downgrade is logged, never silent: one status line names both models and
# the evidence that forced the switch.
printf 'working: automatic model fallback %s -> %s%s on depletion evidence (%s); auto-step-down logged per standing quota rule\n' \
  "${CURRENT_MODEL:-default}" "${NEXT_MODEL:-default}" "${NEXT_HARNESS:+ on $NEXT_HARNESS}" "$SIGNATURE" >> "$STATUS" || true

# Consume exactly the evidence this response acted on. The cursor is measured
# AFTER every append above, so this script's own handoff and downgrade lines
# can never re-classify as fresh depletion evidence on a later run.
FINAL_SIZE=$(wc -c < "$STATUS" | tr -d ' ')
NEW_CURSOR_LINE="fallback_cursor=$FINAL_SIZE"
LOCK=$(fm_meta_lock_path "$META") || die "cannot derive the meta lock for $META"
fm_lock_acquire_wait "$LOCK" || die "could not acquire the meta lock for $META"
UPDATE_OK=1
{
  grep -v '^fallback_cursor=' "$META" || true
  printf '%s\n' "$NEW_CURSOR_LINE"
} > "$META.locked-update" || UPDATE_OK=0
if [ "$UPDATE_OK" = 1 ]; then
  mv "$META.locked-update" "$META" || UPDATE_OK=0
fi
rm -f "$META.locked-update"
fm_lock_release "$LOCK" || true
[ "$UPDATE_OK" = 1 ] || die "relaunch succeeded but the fallback cursor could not be recorded; investigate duplicate-evidence handling for $ID"

log "applied $ACTION for $ID (${CURRENT_MODEL:-default} -> ${NEXT_MODEL:-default}${NEXT_HARNESS:+ on $NEXT_HARNESS}); evidence cursor advanced to byte $FINAL_SIZE"
