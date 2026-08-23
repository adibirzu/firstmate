#!/usr/bin/env bash
# fm-openrouter-quota.sh - firstmate-side OpenRouter capacity reader.
#
# quota-axi cannot price OpenRouter and is not modified by this script. This
# reader queries OpenRouter's own API and emits a machine-readable JSON view
# that later dispatch can route on: live free-model eligibility first, then
# cheap-paid fallback. Eligibility is read live from the API and is never a
# hardcoded model list, so a later privacy-setting change is picked up with no
# code change. The reader stays useful when exactly one free model is eligible
# and does not require a pool of free models to function.
#
# Usage:
#   fm-openrouter-quota.sh report [--now <epoch>]
#   fm-openrouter-quota.sh record-failure --model <id> [--observed <429|404|403>] [--body <file>] [--now <epoch>]
#   fm-openrouter-quota.sh clear --model <id>
#   fm-openrouter-quota.sh clear --all-verdicts
#   fm-openrouter-quota.sh --help
#
# `report` is the default command. It prints one JSON object on stdout.
# Diagnostics are sanitized summaries on stderr. API bodies and quota payloads
# are never printed or logged. The API key is read from the environment and
# handed to curl on standard input as the Authorization header; it is never
# printed, logged, written to a file, passed on a command line, or included
# in an error message.
#
# report:
#   GET /api/v1/key for usage and any key spend cap, and GET /api/v1/models for
#   ids and per-token USD pricing. A negative per-token price is OpenRouter's
#   variable-pricing sentinel, not a cost, and is reported as pricing-missing
#   rather than as a cheap paid model. Per-million prices are rounded to six
#   decimal places. Price-zero models are probed with one bounded
#   chat-completions request so 404 (account privacy / no allowed providers),
#   403 (platform-restricted), and 429 (upstream rate limit) stay distinct.
#   Paid models are not probed, so a paid row is never published as eligible:
#   it carries only what is known, priced and not in cooldown with
#   reachability unverified, and reachability is established on first real
#   use through record-failure rather than by an upfront probe cost. Probes are
#   paced FM_OPENROUTER_PROBE_INTERVAL_SECONDS
#   apart so one sweep stays under OpenRouter's 20 requests per minute
#   free-model limit; the default of 4 seconds is 15 requests per minute.
#   A 429, including one recorded later by record-failure,
#   marks that model id temporarily ineligible for cooldownSeconds; the
#   cooldown is per model id, never per provider and never global, and expired
#   entries are dropped on read. A 404 no-allowed-providers or 403
#   platform-restricted verdict is a stable account fact: it is remembered in
#   the state file and that model id is not probed again until
#   `clear --model <id>` drops it or `clear --all-verdicts` drops every
#   remembered verdict. After changing the OpenRouter privacy or
#   allowed-provider settings, run `clear --all-verdicts` so every remembered
#   model is probed live again; that command keeps live 429 cooldowns. When the
#   number of free models to probe exceeds FM_OPENROUTER_PROBE_MAX the report
#   is still emitted: the unprobed models are reported ineligible with reason
#   probe-budget-exhausted, so nothing is guessed. Catalog ids outside
#   [A-Za-z0-9._:/~-] are skipped with a sanitized stderr line and are not in
#   the output; OpenRouter's ~vendor/model-latest aliases are ordinary rows.
#   Network work runs without the state lock; the lock is held only
#   for the final load, prune, merge, and save of the state file, so a
#   record-failure or clear that lands during a sweep still succeeds.
#
# record-failure:
#   Persist what a real launch observed for one model id, free or paid. The
#   observation is classified by the same body-aware classifier the report
#   sweep uses, so the two paths cannot disagree: --observed 429 (the default)
#   records a per-model cooldown; --observed 403 records the permanent
#   platform-restricted verdict; --observed 404 records the permanent
#   no-allowed-providers verdict only when --body <file> names the response
#   body the caller received and that body contains "No allowed providers",
#   and any other 404 (a retired, delisted, or mistyped id) is transient and
#   records only a cooldown, never a permanent verdict. A paid model rejected
#   on first use therefore drops out of the unverified ordering until `clear`
#   releases it. The body file is read for classification only and is never
#   printed. Unlike fm-dispatch-select.mjs, this does not inspect a task status
#   file: the caller already observed the outcome for this model id.
#
# clear:
#   With --model <id>, drop the persisted cooldown and any remembered verdict
#   for that one model id. With --all-verdicts, drop every remembered 404 and
#   403 verdict while keeping live 429 cooldowns, so the next report probes
#   those models live again. Run `clear --all-verdicts` after changing the
#   OpenRouter privacy or allowed-provider settings; until then the remembered
#   verdicts keep those models unprobed and ineligible.
#
# JSON fields on stdout (schemaVersion 1):
#   key                     sanitized /api/v1/key data (usage, usage_daily,
#                           usage_weekly, usage_monthly, limit, limit_remaining,
#                           is_free_tier)
#   models[]                id, tier (free|paid), free, promptPerMillion,
#                           completionPerMillion, eligible, reason; eligible is
#                           true only for a free model a live probe reached
#   routing.eligibleFree    eligible free model ids (may be empty or one)
#   routing.unverifiedPaidByCost  priced paid model ids that are not in cooldown
#                           and carry no remembered verdict, cheapest first;
#                           their reachability is unverified and is learned on
#                           first use via record-failure
#
# Paths:
#   state/.openrouter-quota.json     persisted per-model cooldowns and
#                                    remembered verdicts
#   state/.openrouter-quota.json.lock  mkdir lock for serialized state updates;
#                                    a lock whose owner pid is dead, or that has
#                                    no readable owner and is older than 60
#                                    seconds, is reaped with a stderr line
#
# Environment:
#   FM_HOME                         required and explicit
#   OPENROUTER_API_KEY_TOKENS       required working key; never printed
#   OPENROUTER_API_KEY              last-resort fallback only, with an explicit
#                                   stderr reason line; never a silent default
#   FM_STATE_OVERRIDE               optional state directory
#   FM_OPENROUTER_STATE_FILE        optional state-file override
#   FM_OPENROUTER_API_BASE          API origin (default https://openrouter.ai)
#   FM_OPENROUTER_COOLDOWN_SECONDS  integer 60..86400 (default 1800)
#   FM_OPENROUTER_PROBE_MAX         max free-model probes per report (default 64)
#   FM_OPENROUTER_PROBE_INTERVAL_SECONDS  integer 0..60 seconds between live
#                                   probes (default 4; 0 disables pacing)
#   FM_OPENROUTER_TIMEOUT           per-request seconds (default 20)
#
# Test-only seams:
#   --now fixes the current epoch second.
#   FM_OPENROUTER_STATE_FILE, FM_OPENROUTER_API_BASE, and
#   FM_OPENROUTER_PROBE_INTERVAL_SECONDS as above.
#
# Exit status: 0 on success, 2 on usage or missing-key errors, 3 when the API
# rejects the key, the lock stays busy, or required telemetry is unusable.
set -eu

SELF=fm-openrouter-quota
DEFAULT_API_BASE=https://openrouter.ai
DEFAULT_COOLDOWN=1800
DEFAULT_PROBE_MAX=64
DEFAULT_PROBE_INTERVAL=4
DEFAULT_TIMEOUT=20
COOLDOWN_MIN=60
COOLDOWN_MAX=86400
PROBE_INTERVAL_MAX=60
LOCK_WAIT_SECONDS=5
LOCK_STALE_SECONDS=60

WORKDIR=
LOCKDIR=
LOCK_HELD=0
AUTH_KEY=

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  local message=$1 code=${2:-2}
  printf '%s: %s\n' "$SELF" "$message" >&2
  exit "$code"
}

log() {
  printf '%s: %s\n' "$SELF" "$1" >&2
}

cleanup() {
  AUTH_KEY=
  if [ -n "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
  release_lock
}

is_integer() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

parse_now() {
  local raw=${1:-}
  if [ -z "$raw" ]; then
    date +%s
    return 0
  fi
  is_integer "$raw" || die '--now must be a non-negative epoch second'
  printf '%s\n' "$raw"
}

explicit_home() {
  local home
  [ -n "${FM_HOME:-}" ] || die 'FM_HOME must be explicit'
  home=$(cd "$FM_HOME" && pwd -P) || die "FM_HOME is not a readable directory: ${FM_HOME}"
  printf '%s\n' "$home"
}

cooldown_seconds() {
  local raw=${FM_OPENROUTER_COOLDOWN_SECONDS:-$DEFAULT_COOLDOWN}
  is_integer "$raw" || die "FM_OPENROUTER_COOLDOWN_SECONDS must be an integer from $COOLDOWN_MIN to $COOLDOWN_MAX"
  if [ "$raw" -lt "$COOLDOWN_MIN" ] || [ "$raw" -gt "$COOLDOWN_MAX" ]; then
    die "FM_OPENROUTER_COOLDOWN_SECONDS must be an integer from $COOLDOWN_MIN to $COOLDOWN_MAX"
  fi
  printf '%s\n' "$raw"
}

probe_max() {
  local raw=${FM_OPENROUTER_PROBE_MAX:-$DEFAULT_PROBE_MAX}
  is_integer "$raw" || die 'FM_OPENROUTER_PROBE_MAX must be a positive integer'
  [ "$raw" -ge 1 ] || die 'FM_OPENROUTER_PROBE_MAX must be a positive integer'
  printf '%s\n' "$raw"
}

probe_interval() {
  local raw=${FM_OPENROUTER_PROBE_INTERVAL_SECONDS:-$DEFAULT_PROBE_INTERVAL}
  is_integer "$raw" || die "FM_OPENROUTER_PROBE_INTERVAL_SECONDS must be an integer from 0 to $PROBE_INTERVAL_MAX"
  [ "$raw" -le "$PROBE_INTERVAL_MAX" ] || die "FM_OPENROUTER_PROBE_INTERVAL_SECONDS must be an integer from 0 to $PROBE_INTERVAL_MAX"
  printf '%s\n' "$raw"
}

request_timeout() {
  local raw=${FM_OPENROUTER_TIMEOUT:-$DEFAULT_TIMEOUT}
  is_integer "$raw" || die 'FM_OPENROUTER_TIMEOUT must be a positive integer'
  [ "$raw" -ge 1 ] || die 'FM_OPENROUTER_TIMEOUT must be a positive integer'
  printf '%s\n' "$raw"
}

api_base() {
  local base=${FM_OPENROUTER_API_BASE:-$DEFAULT_API_BASE}
  [ -n "$base" ] || die 'FM_OPENROUTER_API_BASE must be a non-empty origin'
  printf '%s\n' "${base%/}"
}

model_id_ok() {
  local id=$1
  case "$id" in
    ''|*[!A-Za-z0-9._:/~-]*|[-._:/~*]|/*) return 1 ;;
  esac
  case "$id" in
    [A-Za-z0-9]*|~[A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

sanitize_for_log() {
  printf '%s' "$1" | tr -cd '[:print:]' | cut -c1-120
}

resolve_key() {
  local tokens=${OPENROUTER_API_KEY_TOKENS:-}
  local fallback=${OPENROUTER_API_KEY:-}
  case "$tokens" in
    *$'\n'*|*$'\r'*) die 'OPENROUTER_API_KEY_TOKENS has an unsafe shape' ;;
  esac
  case "$fallback" in
    *$'\n'*|*$'\r'*) die 'OPENROUTER_API_KEY has an unsafe shape' ;;
  esac
  if [ -n "$tokens" ]; then
    AUTH_KEY=$tokens
    return 0
  fi
  if [ -n "$fallback" ]; then
    log 'OPENROUTER_API_KEY_TOKENS is unset; using OPENROUTER_API_KEY as last-resort fallback'
    AUTH_KEY=$fallback
    return 0
  fi
  die 'OPENROUTER_API_KEY_TOKENS is unset'
}

lock_is_stale() {
  local owner mtime now_epoch
  owner=$(cat "$LOCKDIR/owner" 2>/dev/null | tr -d '[:space:]') || owner=
  if ! is_integer "$owner" || [ "$owner" -le 1 ]; then
    mtime=$(stat -c %Y "$LOCKDIR" 2>/dev/null) || mtime=$(stat -f %m "$LOCKDIR" 2>/dev/null) || return 1
    is_integer "$mtime" || return 1
    now_epoch=$(date +%s)
    [ $((now_epoch - mtime)) -ge "$LOCK_STALE_SECONDS" ] && return 0
    return 1
  fi
  if kill -0 "$owner" 2>/dev/null; then
    return 1
  fi
  if ps -p "$owner" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

acquire_lock() {
  local deadline=$((SECONDS + LOCK_WAIT_SECONDS))
  mkdir -p "$(dirname "$LOCKDIR")" || die "could not create $(dirname "$LOCKDIR")" 3
  while true; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      LOCK_HELD=1
      printf '%s\n' "$$" > "$LOCKDIR/owner"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      if lock_is_stale; then
        rm -rf "$LOCKDIR"
        log 'reaped a stale OpenRouter quota state lock'
        continue
      fi
      die "OpenRouter quota state lock remained busy for ${LOCK_WAIT_SECONDS} seconds" 3
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
}

release_lock() {
  if [ "$LOCK_HELD" -eq 1 ] && [ -n "$LOCKDIR" ]; then
    rm -rf "$LOCKDIR"
    LOCK_HELD=0
  fi
}

empty_state() {
  printf '%s\n' '{"version":1,"cooldowns":{},"verdicts":{}}'
}

load_state() {
  local file=$1
  if [ ! -f "$file" ]; then
    empty_state
    return 0
  fi
  jq -e 'type=="object" and .version==1 and (.cooldowns|type=="object") and ((.verdicts // {})|type=="object")' "$file" >/dev/null 2>&1 \
    || die 'OpenRouter quota state has an unsupported or malformed schema' 3
  jq -c '.verdicts //= {}' "$file"
}

save_state() {
  local file=$1 json=$2 tmp
  mkdir -p "$(dirname "$file")" || die "could not create $(dirname "$file")" 3
  tmp=$(umask 077; mktemp "${file}.tmp.XXXXXX") || die 'could not write OpenRouter quota state' 3
  printf '%s\n' "$json" > "$tmp" || die 'could not write OpenRouter quota state' 3
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file" || die 'could not publish OpenRouter quota state' 3
}

prune_cooldowns() {
  local state=$1 now=$2
  printf '%s' "$state" | jq -c --argjson now "$now" \
    '.cooldowns |= with_entries(select(.value.until|type=="number" and . > $now))'
}

cooldown_until() {
  local state=$1 id=$2 now=$3
  printf '%s' "$state" | jq -r --arg id "$id" --argjson now "$now" \
    '(.cooldowns[$id].until // 0) as $u | if ($u|type=="number") and ($u > $now) then ($u|tostring) else empty end'
}

remembered_verdict() {
  local state=$1 id=$2
  printf '%s' "$state" | jq -r --arg id "$id" \
    '.verdicts[$id].class // empty | select(. == "allowed-providers-unavailable" or . == "platform-restricted")'
}

set_cooldown() {
  local state=$1 id=$2 now=$3 seconds=$4 reason=$5 until_epoch
  until_epoch=$((now + seconds))
  printf '%s' "$state" | jq -c --arg id "$id" --argjson now "$now" --argjson until "$until_epoch" --arg reason "$reason" \
    '.cooldowns[$id] = {until:$until, reason:$reason, recordedAt:$now}'
}

set_verdict() {
  local state=$1 id=$2 now=$3 class=$4
  printf '%s' "$state" | jq -c --arg id "$id" --argjson now "$now" --arg class "$class" \
    '.verdicts[$id] = {class:$class, recordedAt:$now}'
}

http_exchange() {
  local method=$1 url=$2 body_file=$3 payload_file=${4:-} timeout=$5
  local err_file code rc=0
  err_file="${WORKDIR}/curl.err"
  : > "$err_file"
  if [ "$method" = POST ]; then
    code=$(printf 'Authorization: Bearer %s\n' "$AUTH_KEY" | curl -sS --max-time "$timeout" \
      -o "$body_file" -w '%{http_code}' \
      -X POST \
      -H @- \
      -H 'Content-Type: application/json' \
      --data-binary "@${payload_file}" \
      "$url" 2>"$err_file") || rc=$?
  else
    code=$(printf 'Authorization: Bearer %s\n' "$AUTH_KEY" | curl -sS --max-time "$timeout" \
      -o "$body_file" -w '%{http_code}' \
      -H @- \
      "$url" 2>"$err_file") || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'curl-%s\n' "$rc"
    return 1
  fi
  printf '%s\n' "$code"
}

classify_http_failure() {
  local code=$1 body_file=$2
  case "$code" in
    401) printf '%s\n' 'key-rejected' ;;
    403) printf '%s\n' 'platform-restricted' ;;
    404)
      if grep -qi 'no allowed providers' "$body_file" 2>/dev/null; then
        printf '%s\n' 'allowed-providers-unavailable'
      else
        printf '%s\n' 'http-404'
      fi
      ;;
    429) printf '%s\n' 'rate-limited' ;;
    curl-*) printf '%s\n' 'probe-request-failed' ;;
    *) printf 'http-%s\n' "$code" ;;
  esac
}

reason_for_class() {
  local class=$1 until_epoch=${2:-}
  case "$class" in
    allowed-providers-unavailable) printf '%s\n' 'account privacy gate: no allowed providers' ;;
    platform-restricted) printf '%s\n' 'platform-restricted' ;;
    rate-limited)
      if [ -n "$until_epoch" ]; then
        printf 'cooldown until epoch %s\n' "$until_epoch"
      else
        printf '%s\n' 'rate-limited'
      fi
      ;;
    key-rejected) printf '%s\n' 'OpenRouter rejected the API key' ;;
    pricing-missing) printf '%s\n' 'pricing-missing' ;;
    key-spend-cap-exhausted) printf '%s\n' 'key spend cap exhausted' ;;
    live-ok) printf '%s\n' 'live completion succeeded' ;;
    paid-unverified) printf '%s\n' 'priced and not in cooldown; reachability unverified' ;;
    probe-request-failed) printf '%s\n' 'probe-request-failed' ;;
    probe-budget-exhausted) printf '%s\n' 'probe-budget-exhausted' ;;
    *) printf '%s\n' "$class" ;;
  esac
}

fetch_json() {
  local url=$1 body_file=$2 timeout=$3 label=$4
  local code
  code=$(http_exchange GET "$url" "$body_file" '' "$timeout") || true
  [ -n "$code" ] || code=curl-fail
  case "$code" in
    200) ;;
    401)
      die 'OpenRouter rejected the API key' 3
      ;;
    curl-*)
      die "OpenRouter ${label} request failed" 3
      ;;
    *)
      die "OpenRouter ${label} returned HTTP ${code}" 3
      ;;
  esac
  jq -e 'type=="object"' "$body_file" >/dev/null 2>&1 || die "OpenRouter ${label} response was not JSON" 3
}

probe_model() {
  local id=$1 timeout=$2 base=$3 body_file=$4
  local payload code
  payload="${WORKDIR}/probe.json"
  jq -nc --arg id "$id" \
    '{model:$id, messages:[{role:"user", content:"ok"}], max_tokens:1}' > "$payload" \
    || die 'could not write a probe payload' 3
  code=$(http_exchange POST "${base}/api/v1/chat/completions" "$body_file" "$payload" "$timeout") || true
  [ -n "$code" ] || code=curl-fail
  printf '%s\n' "$code"
}

emit_model_json() {
  local id=$1 tier=$2 prompt=$3 completion=$4 eligible=$5 reason=$6
  jq -nc \
    --arg id "$id" \
    --arg tier "$tier" \
    --arg prompt "$prompt" \
    --arg completion "$completion" \
    --arg eligible "$eligible" \
    --arg reason "$reason" \
    '{
      id: $id,
      tier: $tier,
      free: ($tier == "free"),
      promptPerMillion: (if $prompt == "" then null else ($prompt | tonumber) end),
      completionPerMillion: (if $completion == "" then null else ($completion | tonumber) end),
      eligible: ($eligible == "true"),
      reason: $reason
    }'
}

record_observation() {
  local file=$1 kind=$2 id=$3 class=$4
  jq -nc --arg kind "$kind" --arg id "$id" --arg class "$class" '{kind:$kind, id:$id, class:$class}' >> "$file"
}

merge_observations_under_lock() {
  local state_file=$1 now=$2 cooldown=$3 observations=$4
  local state
  acquire_lock
  state=$(load_state "$state_file")
  state=$(printf '%s' "$state" | jq -c --slurpfile obs "$observations" --argjson now "$now" --argjson cd "$cooldown" '
    .cooldowns |= with_entries(select(.value.until|type=="number" and . > $now))
    | reduce $obs[] as $o (.;
        if $o.kind == "cooldown" then .cooldowns[$o.id] = {until: ($now + $cd), reason: $o.class, recordedAt: $now}
        elif $o.kind == "verdict" then .verdicts[$o.id] = {class: $o.class, recordedAt: $now}
        else . end)')
  save_state "$state_file" "$state"
  release_lock
}

cmd_report() {
  local now=$1 state_file=$2
  local base timeout cooldown max_probes interval body_key body_models body_probe
  local state models_jsonl observations model_count free_count probe_count remembered_count unprobed_count skipped_count
  local id prompt_m completion_m tier reason class until_epoch code
  local cap_exhausted=0 limit_remaining
  local row is_free

  command -v curl >/dev/null 2>&1 || die 'curl is required' 3
  command -v jq >/dev/null 2>&1 || die 'jq is required' 3

  base=$(api_base)
  timeout=$(request_timeout)
  cooldown=$(cooldown_seconds)
  max_probes=$(probe_max)
  interval=$(probe_interval)
  resolve_key

  body_key="${WORKDIR}/key.json"
  body_models="${WORKDIR}/models.json"
  body_probe="${WORKDIR}/probe-body.json"
  models_jsonl="${WORKDIR}/models.jsonl"
  observations="${WORKDIR}/observations.jsonl"
  : > "$models_jsonl"
  : > "$observations"

  fetch_json "${base}/api/v1/key" "$body_key" "$timeout" 'key'
  fetch_json "${base}/api/v1/models" "$body_models" "$timeout" 'models'

  jq -e '.data|type=="object"' "$body_key" >/dev/null 2>&1 \
    || die 'OpenRouter key response was missing data' 3
  jq -e '.data|type=="array"' "$body_models" >/dev/null 2>&1 \
    || die 'OpenRouter models response was missing data' 3

  limit_remaining=$(jq -r '.data.limit_remaining // empty' "$body_key")
  if [ -n "$limit_remaining" ] && jq -e --argjson n "$limit_remaining" '$n <= 0' >/dev/null 2>&1; then
    cap_exhausted=1
  fi

  state=$(load_state "$state_file")
  state=$(prune_cooldowns "$state" "$now")

  model_count=0
  free_count=0
  probe_count=0
  remembered_count=0
  unprobed_count=0
  skipped_count=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id // empty')
    [ -n "$id" ] || continue
    if ! model_id_ok "$id"; then
      skipped_count=$((skipped_count + 1))
      log "model=$(sanitize_for_log "$id") skipped: unsupported id shape"
      continue
    fi
    model_count=$((model_count + 1))
    prompt_m=$(printf '%s' "$row" | jq -r 'try ((.prompt | tonumber) as $n | if $n < 0 then empty else ((($n * 1000000 * 1000000) | round) / 1000000 | tostring) end) catch empty')
    completion_m=$(printf '%s' "$row" | jq -r 'try ((.completion | tonumber) as $n | if $n < 0 then empty else ((($n * 1000000 * 1000000) | round) / 1000000 | tostring) end) catch empty')
    if [ -z "$prompt_m" ] || [ -z "$completion_m" ]; then
      emit_model_json "$id" paid '' '' false "$(reason_for_class pricing-missing)" >> "$models_jsonl"
      continue
    fi
    is_free=$(printf '%s' "$row" | jq -r 'try ((.prompt | tonumber) == 0 and (.completion | tonumber) == 0) catch false')
    if [ "$is_free" = true ]; then
      tier=free
      free_count=$((free_count + 1))
    else
      tier=paid
    fi

    until_epoch=$(cooldown_until "$state" "$id" "$now")
    if [ -n "$until_epoch" ]; then
      log "model=${id} unavailable: cooldown until epoch ${until_epoch}"
      emit_model_json "$id" "$tier" "$prompt_m" "$completion_m" false "$(reason_for_class rate-limited "$until_epoch")" >> "$models_jsonl"
      continue
    fi

    class=$(remembered_verdict "$state" "$id")
    if [ -n "$class" ]; then
      remembered_count=$((remembered_count + 1))
      reason=$(reason_for_class "$class")
      log "model=${id} unavailable: ${reason} (remembered verdict)"
      emit_model_json "$id" "$tier" "$prompt_m" "$completion_m" false "$reason" >> "$models_jsonl"
      continue
    fi

    if [ "$tier" = paid ]; then
      if [ "$cap_exhausted" -eq 1 ]; then
        emit_model_json "$id" paid "$prompt_m" "$completion_m" false "$(reason_for_class key-spend-cap-exhausted)" >> "$models_jsonl"
        continue
      fi
      emit_model_json "$id" paid "$prompt_m" "$completion_m" false "$(reason_for_class paid-unverified)" >> "$models_jsonl"
      continue
    fi

    if [ "$probe_count" -ge "$max_probes" ]; then
      unprobed_count=$((unprobed_count + 1))
      reason=$(reason_for_class probe-budget-exhausted)
      log "model=${id} unprobed: ${reason} (FM_OPENROUTER_PROBE_MAX=${max_probes})"
      emit_model_json "$id" free "$prompt_m" "$completion_m" false "$reason" >> "$models_jsonl"
      continue
    fi
    if [ "$probe_count" -gt 0 ] && [ "$interval" -gt 0 ]; then
      sleep "$interval"
    fi
    probe_count=$((probe_count + 1))
    code=$(probe_model "$id" "$timeout" "$base" "$body_probe")
    if [ "$code" = 200 ]; then
      log "model=${id} eligible: live completion succeeded"
      emit_model_json "$id" free "$prompt_m" "$completion_m" true "$(reason_for_class live-ok)" >> "$models_jsonl"
      continue
    fi
    class=$(classify_http_failure "$code" "$body_probe")
    if [ "$class" = key-rejected ]; then
      die 'OpenRouter rejected the API key' 3
    fi
    if [ "$class" = rate-limited ]; then
      record_observation "$observations" cooldown "$id" rate-limited
      until_epoch=$((now + cooldown))
      log "model=${id} unavailable: cooldown until epoch ${until_epoch}"
      emit_model_json "$id" free "$prompt_m" "$completion_m" false "$(reason_for_class rate-limited "$until_epoch")" >> "$models_jsonl"
      continue
    fi
    if [ "$class" = allowed-providers-unavailable ] || [ "$class" = platform-restricted ]; then
      record_observation "$observations" verdict "$id" "$class"
    fi
    reason=$(reason_for_class "$class")
    log "model=${id} unavailable: ${reason}"
    emit_model_json "$id" free "$prompt_m" "$completion_m" false "$reason" >> "$models_jsonl"
  done < <(jq -c '.data[] | select(.id != null) | {id, prompt: (.pricing.prompt // null), completion: (.pricing.completion // null)}' "$body_models")

  [ "$model_count" -gt 0 ] || die 'OpenRouter returned no models' 3
  merge_observations_under_lock "$state_file" "$now" "$cooldown" "$observations"

  jq -n \
    --argjson generatedAt "$now" \
    --arg unverified "$(reason_for_class paid-unverified)" \
    --argjson key "$(jq -c '{
        usage: .data.usage,
        usage_daily: .data.usage_daily,
        usage_weekly: .data.usage_weekly,
        usage_monthly: .data.usage_monthly,
        limit: .data.limit,
        limit_remaining: .data.limit_remaining,
        is_free_tier: .data.is_free_tier
      }' "$body_key")" \
    --slurpfile models "$models_jsonl" \
    '{
      schemaVersion: 1,
      generatedAt: $generatedAt,
      key: $key,
      models: (
        $models
        | sort_by(
            [
              (if .eligible and .tier == "free" then 0
               elif .tier == "paid" and .reason == $unverified then 1
               elif .tier == "free" then 2
               else 3 end),
              ((.promptPerMillion // 0) + (.completionPerMillion // 0)),
              .id
            ]
          )
      ),
      routing: {
        eligibleFree: [$models[] | select(.eligible and .tier == "free") | .id],
        unverifiedPaidByCost: (
          [$models[] | select(
              .tier == "paid" and .reason == $unverified
              and (.promptPerMillion != null) and (.completionPerMillion != null)
              and .promptPerMillion >= 0 and .completionPerMillion >= 0
            )]
          | sort_by((.promptPerMillion + .completionPerMillion), .id)
          | map(.id)
        )
      }
    }'
  log "report models=${model_count} free=${free_count} probes=${probe_count} remembered=${remembered_count} unprobed=${unprobed_count} skipped=${skipped_count}"
}

cmd_record_failure() {
  local now=$1 state_file=$2 id=$3 observed=$4 body_file=$5
  local cooldown state until_epoch class
  model_id_ok "$id" || die 'record-failure needs --model <id>'
  case "$observed" in
    429|404|403) ;;
    *) die 'record-failure --observed must be 429, 404, or 403' ;;
  esac
  [ -n "$body_file" ] || body_file=/dev/null
  [ -r "$body_file" ] || die '--body must name a readable response body file'
  class=$(classify_http_failure "$observed" "$body_file")
  cooldown=$(cooldown_seconds)
  acquire_lock
  state=$(load_state "$state_file")
  state=$(prune_cooldowns "$state" "$now")
  case "$class" in
    allowed-providers-unavailable|platform-restricted)
      state=$(set_verdict "$state" "$id" "$now" "$class")
      ;;
    *)
      state=$(set_cooldown "$state" "$id" "$now" "$cooldown" "$class")
      ;;
  esac
  save_state "$state_file" "$state"
  release_lock
  case "$class" in
    allowed-providers-unavailable|platform-restricted)
      log "model=${id} permanent verdict recorded: $(reason_for_class "$class")"
      ;;
    rate-limited)
      until_epoch=$((now + cooldown))
      log "model=${id} cooldown recorded until epoch ${until_epoch}"
      ;;
    *)
      until_epoch=$((now + cooldown))
      log "model=${id} transient ${class} recorded as cooldown until epoch ${until_epoch}"
      ;;
  esac
}

cmd_clear() {
  local now=$1 state_file=$2 id=$3
  local state
  model_id_ok "$id" || die 'clear needs --model <id>'
  acquire_lock
  state=$(load_state "$state_file")
  state=$(printf '%s' "$state" | jq -c --arg id "$id" 'del(.cooldowns[$id]) | del(.verdicts[$id])')
  save_state "$state_file" "$state"
  release_lock
  log "model=${id} cooldown and remembered verdict cleared"
}

cmd_clear_all_verdicts() {
  local now=$1 state_file=$2
  local state count
  acquire_lock
  state=$(load_state "$state_file")
  count=$(printf '%s' "$state" | jq -r '.verdicts | length')
  state=$(printf '%s' "$state" | jq -c '.verdicts = {}')
  save_state "$state_file" "$state"
  release_lock
  log "remembered verdicts cleared: ${count}; live cooldowns kept"
}

main() {
  local command=report now_raw='' now='' model='' observed=429 observed_set=0 body_file='' all_verdicts=0 home state_dir state_file
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      report|record-failure|clear)
        command=$1
        shift
        ;;
      --now)
        [ $# -ge 2 ] || die '--now requires a value'
        now_raw=$2
        shift 2
        ;;
      --model)
        [ $# -ge 2 ] || die '--model requires a value'
        model=$2
        shift 2
        ;;
      --observed)
        [ $# -ge 2 ] || die '--observed requires a value'
        observed=$2
        observed_set=1
        shift 2
        ;;
      --body)
        [ $# -ge 2 ] || die '--body requires a value'
        body_file=$2
        shift 2
        ;;
      --all-verdicts)
        all_verdicts=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option $1"
        ;;
      *)
        die "unexpected argument $1"
        ;;
    esac
  done
  [ $# -eq 0 ] || die "unexpected argument $1"
  if [ "$all_verdicts" -eq 1 ] && [ "$command" != clear ]; then
    die '--all-verdicts is only valid with clear: run clear --all-verdicts'
  fi
  if [ -n "$model" ] && [ "$command" = report ]; then
    die '--model is only valid with record-failure or clear, not report'
  fi
  if [ "$observed_set" -eq 1 ] && [ "$command" != record-failure ]; then
    die '--observed is only valid with record-failure'
  fi
  if [ -n "$body_file" ] && [ "$command" != record-failure ]; then
    die '--body is only valid with record-failure'
  fi

  command -v jq >/dev/null 2>&1 || die 'jq is required' 3
  now=$(parse_now "$now_raw")
  home=$(explicit_home)
  state_dir=${FM_STATE_OVERRIDE:-$home/state}
  state_file=${FM_OPENROUTER_STATE_FILE:-$state_dir/.openrouter-quota.json}
  LOCKDIR="${state_file}.lock"

  WORKDIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-openrouter-quota.XXXXXX") \
    || die 'could not create a work directory' 3
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT
  trap 'cleanup; exit 143' TERM

  case "$command" in
    report) cmd_report "$now" "$state_file" ;;
    record-failure)
      [ -n "$model" ] || die 'record-failure needs --model <id>'
      cmd_record_failure "$now" "$state_file" "$model" "$observed" "$body_file"
      ;;
    clear)
      if [ "$all_verdicts" -eq 1 ]; then
        [ -z "$model" ] || die 'clear takes either --model <id> or --all-verdicts, not both'
        cmd_clear_all_verdicts "$now" "$state_file"
      else
        [ -n "$model" ] || die 'clear needs --model <id> or --all-verdicts'
        cmd_clear "$now" "$state_file" "$model"
      fi
      ;;
    *) die "unknown command $command" ;;
  esac
}

main "$@"
