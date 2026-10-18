#!/usr/bin/env bash
# fm-model-fallback.sh - the mechanical owner of automatic in-run model
# fallback on quota depletion. It turns the step-down decision owned by
# llm-router-axi's policy into a real depletion response instead of prose.
#
# Usage:
#   fm-model-fallback.sh <task-id> plan
#   fm-model-fallback.sh <task-id> apply
#
# `plan` decides only: it verifies fresh depletion evidence, asks
# `llm-router-axi route chain --harness <h> --model <m>` for the next move,
# and prints one `action=` block. `apply` executes that decision through
# bin/fm-runtime-handoff.sh, which owns the guarded in-place relaunch that
# preserves the worktree and every landed or unlanded change.
#
# What apply does, in order:
#   1. Reads state/<id>.meta for kind=ship|scout, harness=, model=, and the
#      fallback cursor (the byte offset of the last evidence this script
#      consumed).
#   2. Keeps only the status lines that report the worker's OWN failure before
#      classifying anything: a line is candidate evidence only when its leading
#      verb is the failure verb `failed` (the charter cannot be carried out) or
#      the obstacle verb `blocked` (stuck, needs help) - the two verbs the crew
#      brief routes a worker's own "the runtime could not serve" report to. The
#      verb is the structural signal that separates the worker's own
#      harness/model output from third-party prose: a genuine exhaustion message
#      is reported under one of those verbs, while ordinary narrative - including
#      a PR-review summary that merely mentions "usage limit" or "quota limit" -
#      is written under working:/done:/needs-decision:. Feeding every narrative
#      line to the shared classifier let Cursor Bugbot/Copilot review text
#      phrase-match as if it were the worker's own depletion and killed a healthy
#      worker mid-tool-call. The declared external-wait verb `paused:` (owned by
#      bin/fm-classify-lib.sh's status_is_paused) is a different verb and stays
#      excluded too, so depletion words inside that after-the-fact note never
#      relaunch an endpoint deliberately stopped. Known limit: detection is
#      narrowed to those two verbs, so an exhaustion message a worker wrote under
#      another verb (working:, needs-decision:) or as a bare non-verb error line
#      is not treated as evidence - the deliberate cost of keeping third-party
#      narrative out of the classifier. Only what remains is classified through
#      `llm-router-axi classify-evidence` plus this script's hosted-region opt-in
#      refusal signature below: the router owns the subscription-exhaustion
#      vocabulary, this script owns the refusal anchors, and either firing means
#      depletion. No evidence, no fallback - a healthy or ambiguous worker is
#      never relaunched by this script.
#   3. Asks `llm-router-axi route chain --harness <h> --model <m> --json` for
#      the next move: the entry after the recorded model is next; a model
#      absent from its chain steps to the chain head; the chain's last entry
#      means this runtime lane is exhausted unless the router policy's
#      modelFallbackCycles returns it to the chain head.
#   4. On apply, asks `llm-router-axi triage` for one advisory defect class
#      over the same evidence and appends `triage: <class> via jev|fallback`
#      to the status line. Triage is purely advisory: it never gates or
#      changes the step-down (its closed classes reuse the classify-evidence
#      vocabulary, so it cannot contradict it), and an unavailable answer is
#      a bare miss that lets the fallback proceed unchanged.
#   5. When the lane is exhausted and the router policy's fallbackLanes names
#      a later lane, moves there and starts that lane's own chain head (or
#      its default model when that lane has no chain).
#   6. For router-classified subscription exhaustion, when the depleted harness
#      carries a telemetry-backed routing provider, records the verified
#      failure through `llm-router-axi record` so future dispatches avoid the
#      account during the cooldown. A hosted-region opt-in refusal is specific
#      to the model, so it never cools down the provider; bookkeeping failure
#      never blocks the relaunch itself.
#   7. Relaunches in place with --model <next> and a progress note naming the
#      depletion signature and the automatic step-down. The effort axis is
#      deliberately reset so the replacement model launches on its own
#      default instead of inheriting an axis tuned for the depleted model.
#   8. Appends one `working:` status line recording the switch, then advances
#      the fallback cursor past the consumed evidence under the task's meta
#      lock, so the same evidence can never trigger a second step-down. A
#      negative classification is a completed outcome too: it consumes the
#      candidate evidence it evaluated so the same text is not rescanned on
#      every later status event. Only an inconclusive classification (the
#      router unavailable) and a failed relaunch leave the cursor untouched,
#      because neither is a completed response to the evidence.
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
# Refusals are loud: malformed config, unreadable meta, or absent evidence
# stops the script rather than improvising a relaunch. A chainless lane is
# exhausted in place and can continue through its configured lane successor.
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

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-router-lib.sh
. "$SCRIPT_DIR/fm-router-lib.sh"

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

# Telemetry-backed providers whose credit identity the router prices natively.
native_provider_of() {  # <harness>
  case "$1" in
    claude|codex|opencode|grok|cursor|agy) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

# advance_fallback_cursor <byte-offset>: record the evidence cursor under the
# task's meta lock. Defined before classification because both the negative
# outcome below and the applied step-down at the end consume evidence through
# it.
advance_fallback_cursor() {
  local cursor_end=$1 new_cursor_line lock update_ok
  new_cursor_line="fallback_cursor=$cursor_end"
  lock=$(fm_meta_lock_path "$META") || die "cannot derive the meta lock for $META"
  fm_lock_acquire_wait "$lock" || die "could not acquire the meta lock for $META"
  update_ok=1
  # Insert the cursor immediately before the canonical pr= identity block
  # rather than appending it. Appending after pr=/pr_head= pushed a
  # non-identity key past the identity block, which bin/fm-pr-lib.sh's
  # fm_pr_metadata_identity_parse used to read as a corrupt record and
  # silently disarm the task's merge poll. When no pr= line exists the cursor
  # still lands at the end; the identity block, once present, stays trailing.
  {
    awk -v cursor_line="$new_cursor_line" '
      /^fallback_cursor=/ { next }
      /^pr=/ && !placed { print cursor_line; placed=1 }
      { print }
      END { if (!placed) print cursor_line }
    ' "$META"
  } > "$META.locked-update" || update_ok=0
  if [ "$update_ok" = 1 ]; then
    mv "$META.locked-update" "$META" || update_ok=0
  fi
  rm -f "$META.locked-update"
  fm_lock_release "$lock" || true
  [ "$update_ok" = 1 ] || die "the fallback cursor could not be recorded; investigate duplicate-evidence handling for $ID"
  FALLBACK_CURSOR=$cursor_end
}

# --- router resolution ------------------------------------------------------

command -v jq >/dev/null 2>&1 || die "jq is not installed; refusing to parse the router's step-down decision without it"
ROUTER=$(fm_router_axi_bin)
if [ -z "$ROUTER" ]; then
  die "llm-router-axi is not installed ($(fm_router_axi_install_hint)); the step-down chain is owned by its policy"
fi

# --- evidence classification ------------------------------------------------

CURSOR=$(fm_meta_get "$META" fallback_cursor)
case "$CURSOR" in
  ''|*[!0-9]*) CURSOR=0 ;;
esac
STATUS_SIZE=$(wc -c < "$STATUS" | tr -d ' ')
[ "$CURSOR" -le "$STATUS_SIZE" ] || CURSOR=0
EVIDENCE_END=$STATUS_SIZE
EVIDENCE_BYTES=$((EVIDENCE_END - CURSOR))

# Drop this script's own exhaustion line before scoping. It is written under the
# `blocked:` verb, which the verb scope below keeps, and it describes a fallback
# this script already acted on, so without this it would be re-read as the
# worker's own fresh failure report if the cursor ever resets (a truncated status
# log). The step-down `working:` note this script also appends needs no such
# filter: the verb scope below already drops every `working:` line. Both events
# are still retained in the log itself.
if [ "$EVIDENCE_BYTES" -gt 0 ]; then
  EVIDENCE_RAW=$(tail -c +"$((CURSOR + 1))" "$STATUS" 2>/dev/null \
    | head -c "$EVIDENCE_BYTES" \
    | sed -e '/^blocked: model fallback exhausted for .*needs a routing decision/d' \
    || true)
else
  EVIDENCE_RAW=
fi
# Scope the evidence to the worker's OWN failure report. A status line's
# leading verb is the structural signal that separates the worker's own
# harness/model output from third-party prose: a genuine exhaustion message is
# the worker reporting its own runtime could not serve, which the crew brief
# routes to `failed:` (the charter cannot be carried out) or `blocked:`
# (stuck, needs help) - the two verbs kept here. Ordinary narrative - including
# a PR-review summary that merely mentions "usage limit" or "quota limit" - is
# written under working:/done:/needs-decision:. Feeding every narrative line to
# the shared classifier let Cursor Bugbot/Copilot review text phrase-match as if
# it were the worker's own depletion and killed a healthy worker mid-tool-call,
# so the narrative verbs are dropped. `paused:`, the declared external-wait verb
# owned by bin/fm-classify-lib.sh, is a different verb and stays excluded too.
evidence_verb_is_failure() {  # <verb>
  case "$1" in
    failed|blocked) return 0 ;;
    *) return 1 ;;
  esac
}
EVIDENCE_TEXT=
if [ -n "$EVIDENCE_RAW" ]; then
  while IFS= read -r evidence_line || [ -n "$evidence_line" ]; do
    evidence_verb_is_failure "$(status_line_verb "$evidence_line")" || continue
    EVIDENCE_TEXT="${EVIDENCE_TEXT}${evidence_line}
"
  done <<EOF_EVIDENCE
$EVIDENCE_RAW
EOF_EVIDENCE
fi
# Hosted-region opt-in refusal (this script is the single owner of this
# signature; the router's subscription vocabulary does not cover it). A worker
# whose model answers but refuses to serve without an explicit opt-in to
# China-hosted inference (e.g. `latest version only available hosted in China,
# requires explicit opt in`) is unavailable, not up against a working ceiling,
# so it triggers the same in-lane fallback without provider-wide cooldown. The
# evidence here is already scoped to the worker's own failure/obstacle verbs, so
# the match only needs the complete refusal wording in one status event,
# case-insensitive, so task content cannot combine partial anchors into a false
# refusal.
REFUSAL_SIGNATURE='hosted-region opt-in refusal'
REFUSAL_CLASSIFIED=0
evidence_has_refusal() {  # reads $EVIDENCE_TEXT
  local evidence_line lowered
  while IFS= read -r evidence_line || [ -n "$evidence_line" ]; do
    lowered=$(printf '%s' "$evidence_line" | tr '[:upper:]' '[:lower:]')
    case "$lowered" in
      *'latest version only available hosted in china,'*'requires explicit opt in'*|*'latest version only available hosted in china,'*'requires explicit opt-in'*)
        return 0
        ;;
    esac
  done <<EOF_REFUSAL
${EVIDENCE_TEXT:-}
EOF_REFUSAL
  return 1
}

# Classify through the router, then branch on whether it actually answered. The
# script runs under `set -e`, so the substitution must not be a bare assignment:
# a failing command substitution would abort the whole script before the status
# could be read (regressing plan's documented quiet `action=none` and losing the
# apply diagnostic). An `if` condition is exempt from errexit, so this captures
# the exit status safely. A router that cannot answer - nonzero exit, or no
# output at all - is inconclusive, never a negative verdict, so it must not let
# the evidence be consumed below as if it had been classified.
CLASSIFY_INCONCLUSIVE=0
if CLASSIFICATION=$(printf '%s' "$EVIDENCE_TEXT" | "$ROUTER" classify-evidence 2>/dev/null); then
  if [ -z "$CLASSIFICATION" ]; then
    CLASSIFY_INCONCLUSIVE=1
    CLASSIFICATION='classification=none'
  fi
else
  CLASSIFY_INCONCLUSIVE=1
  CLASSIFICATION='classification=none'
fi
case "$CLASSIFICATION" in
  classification=depleted*) ;;
  *)
    if evidence_has_refusal; then
      CLASSIFICATION=$(printf 'classification=depleted\nsignature="%s"\n' "$REFUSAL_SIGNATURE")
      REFUSAL_CLASSIFIED=1
    elif [ "$VERB" = plan ]; then
      echo "action=none"
      if [ "$CLASSIFY_INCONCLUSIVE" -eq 1 ]; then
        echo "reason=the depletion classifier could not answer; no verdict was reached and nothing was consumed"
      else
        echo "reason=no depletion evidence after the consumed cursor at byte $CURSOR"
      fi
      exit 0
    else
      # A negative classification is still a completed outcome: consume the
      # candidate evidence it evaluated so the same text cannot be rescanned and
      # re-classified on every later status event. Evidence with no candidate
      # failure line, and an inconclusive router answer, are left alone because
      # nothing was actually classified.
      if [ "$CLASSIFY_INCONCLUSIVE" -eq 0 ] && [ -n "$EVIDENCE_TEXT" ]; then
        advance_fallback_cursor "$EVIDENCE_END"
      fi
      die "no depletion evidence in $STATUS after byte $CURSOR; a healthy or already-consumed signal is never a fallback trigger"
    fi
    ;;
esac
SIGNATURE=$(printf '%s\n' "$CLASSIFICATION" | sed -n 's/^signature=//p')

# --- advisory triage (apply only) -------------------------------------------
#
# `triage` reclassifies the same depletion evidence into the closed defect
# classes (rate_limit, quota_exhausted, auth, region_refused, tool_error,
# test_failure, timeout, unknown) for one advisory token in the status line
# (docs/configuration.md "Jev shadow mode"). It is never a decision input:
# classify-evidence above stays the sole owner of whether depletion happened,
# and the route chain below stays the sole owner of what happens next. A
# missing router answer, malformed JSON, or an unsettled class falls out to a
# bare miss - the fallback proceeds exactly as it would have without triage,
# because a router outage must never stall a depletion response.
TRIAGE_TOKEN=
if [ "$VERB" = apply ] && [ -n "$EVIDENCE_TEXT" ]; then
  TRIAGE_JSON=$(printf '%s\n' "$EVIDENCE_TEXT" \
    | "$ROUTER" triage --evidence - --json 2>/dev/null \
    || true)
  if [ -n "$TRIAGE_JSON" ]; then
    TRIAGE_DEFECT=$(printf '%s' "$TRIAGE_JSON" | jq -r '.defect.value // empty' 2>/dev/null || true)
    TRIAGE_SOURCE=$(printf '%s' "$TRIAGE_JSON" | jq -r '.source // "fallback"' 2>/dev/null || true)
    case "$TRIAGE_SOURCE" in
      jev|fallback) ;;
      *) TRIAGE_SOURCE=fallback ;;
    esac
    case "$TRIAGE_DEFECT" in
      rate_limit|quota_exhausted|auth|region_refused|tool_error|test_failure|timeout|unknown)
        TRIAGE_TOKEN="triage: $TRIAGE_DEFECT via $TRIAGE_SOURCE"
        ;;
    esac
  fi
  [ -n "$TRIAGE_TOKEN" ] || log "advisory triage unavailable for $ID; falling through on the router's classification alone"
fi

if [ "$VERB" = apply ] && [ "$REFUSAL_CLASSIFIED" -eq 0 ]; then
  PROVIDER=$(fm_meta_get "$META" provider)
  if [ -z "$PROVIDER" ]; then
    PROVIDER=$(native_provider_of "$HARNESS") || PROVIDER=
  fi
  case "$PROVIDER" in
    claude|codex|opencode|grok|cursor|agy)
      "$ROUTER" record --provider "$PROVIDER" --outcome rate_limit --task "$ID" >/dev/null 2>&1 \
        || log "provider=$PROVIDER cooldown was not recorded; continuing with automatic fallback"
      ;;
    *) ;;
  esac
fi

# --- selection --------------------------------------------------------------
#
# The step-down chain lives in the router policy, not in config/crew-dispatch.json:
# ask the router for the one next move so this script and any other router caller
# always agree on lane order, cycles, and exhaustion.
STEP_ARGS=(route chain --harness "$HARNESS")
[ -z "$CURRENT_MODEL" ] || STEP_ARGS+=(--model "$CURRENT_MODEL")
STEP_ARGS+=(--json)
if ! STEP_JSON=$("$ROUTER" "${STEP_ARGS[@]}" 2>/dev/null) || [ -z "$STEP_JSON" ]; then
  die "llm-router-axi route chain produced no decision for harness '$HARNESS'; fix the router policy rather than improvising a step-down"
fi

ACTION=$(printf '%s' "$STEP_JSON" | jq -r '.action // empty')
NEXT_MODEL=$(printf '%s' "$STEP_JSON" | jq -r '.toModel // empty')
NEXT_HARNESS=$(printf '%s' "$STEP_JSON" | jq -r '.toHarness // empty')
ROUTER_REASON=$(printf '%s' "$STEP_JSON" | jq -r '.reason // empty')
CHAIN=$(printf '%s' "$STEP_JSON" | jq -r '.chain[]? // empty')
case "$ACTION" in
  harness-step|lane-move|exhausted) ;;
  *) die "llm-router-axi route chain returned an unusable action='$ACTION' for harness '$HARNESS'" ;;
esac

echo "action=$ACTION"
echo "task=$ID"
echo "harness=$HARNESS"
[ -z "$CURRENT_MODEL" ] || echo "from_model=$CURRENT_MODEL"
if [ "$ACTION" = exhausted ]; then
  exhausted_reason="every model in the '$HARNESS' chain is depleted and no fallbackLanes successor exists"
  echo "reason=${ROUTER_REASON:-$exhausted_reason}"
  if [ "$VERB" = apply ]; then
    printf 'blocked: model fallback exhausted for %s (%s); needs a routing decision%s\n' \
      "$HARNESS" "$(printf '%s' "$CHAIN" | tr '\n' ' ')" "${TRIAGE_TOKEN:+; $TRIAGE_TOKEN}" >> "$STATUS"
    advance_fallback_cursor "$(wc -c < "$STATUS" | tr -d ' ')"
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
printf 'working: automatic model fallback %s -> %s%s on depletion evidence (%s); auto-step-down logged per standing quota rule%s\n' \
  "${CURRENT_MODEL:-default}" "${NEXT_MODEL:-default}" "${NEXT_HARNESS:+ on $NEXT_HARNESS}" "$SIGNATURE" "${TRIAGE_TOKEN:+; $TRIAGE_TOKEN}" >> "$STATUS" || true

# Consume exactly the evidence this response acted on.
advance_fallback_cursor "$EVIDENCE_END"

log "applied $ACTION for $ID (${CURRENT_MODEL:-default} -> ${NEXT_MODEL:-default}${NEXT_HARNESS:+ on $NEXT_HARNESS}); evidence cursor advanced to byte $FALLBACK_CURSOR"
