#!/usr/bin/env bash
# fm-crew-usage-lib.sh - single owner of the per-crew usage row (harness,
# model, context percentage, provider quota) surfaced by fm-fleet-snapshot.sh
# and rendered by the bearings skill's fleet-wide fallback view.
#
# Scope, deliberately narrow (Slice 1/2 of data/fm-harness-usage-bar/report.md,
# captain-approved 2026-09-06):
#   - harness, model: the caller reads these straight from state/<id>.meta;
#     this file does not re-parse meta and takes them as arguments.
#   - context percentage: firstmate observes a task from OUTSIDE the harness
#     process (a pane capture or a status file). No checked harness exposes
#     its live context-window percentage on that external channel - the
#     LifeOS statusline computes it INSIDE the harness's own stdin hook,
#     which firstmate never receives. Confirmed absent for opencode (`opencode
#     stats` is a pull-only cost/token command, not a per-turn live
#     percentage), `pi --mode json` (single-turn JSON carries no token/context
#     field), and `cline --json` (same: no token/context field in its
#     per-message JSON). context_pct is therefore always "n/a" today; this is
#     a recorded finding, not a gap to route around with pane-scraping, which
#     firstmate-coding-guidelines' "Harness-dependent checks" section would
#     require two-test live proof for and this task's scope does not cover.
#   - quota: quota-axi's per-provider spendPriority, the same comparable
#     scalar AGENTS.md section 4 already treats as the dispatch selector's
#     input ("quota-axi publishes spendPriority as a comparable scalar").
#     quota-axi is a LIVE, network-backed, per-account call - fine for a
#     single ad-hoc bearings read, but fm-fleet-snapshot.sh's per-task loop
#     also runs recursively (a secondmate home's own snapshot, walked from
#     the parent's summary), so an unconditional call here multiplies into
#     several live network round trips per snapshot and measurably slows or
#     flakes every consumer of the canonical snapshot, tests included. It is
#     therefore OFF by default and gated behind FM_CREW_USAGE_ENABLE_QUOTA=1,
#     so the canonical snapshot's existing performance and determinism are
#     unchanged for every caller that has not explicitly asked for live
#     quota data. Bounded by fm_run_timed (bin/fm-timeout-lib.sh) even when
#     enabled, so a slow or hung quota-axi can never stall a snapshot read; a
#     bound miss is treated the same as quota-axi being absent. Fetched at
#     most once per process and cached, so reading N tasks' usage rows in one
#     enabled invocation costs one quota-axi call, not N. No new poller: this
#     file adds a pure, on-demand read to fm-fleet-snapshot.sh's existing
#     per-task loop; nothing here schedules or repeats on its own.
#
# Depends on fm_account_quota_provider (bin/fm-accounts-lib.sh) for the
# harness->quota-axi-provider mapping, and fm_run_timed (bin/fm-timeout-lib.sh)
# for the bounded call; callers must source both files first.

FM_CREW_USAGE_QUOTA_JSON_CACHE=""
FM_CREW_USAGE_QUOTA_FETCHED=0
FM_CREW_USAGE_QUOTA_TIMEOUT=${FM_CREW_USAGE_QUOTA_TIMEOUT:-5}

# Fetch quota-axi's full JSON once per process; cache the raw text (empty
# string on any failure, including quota-axi absent or the bound being hit).
# Never called unless a caller asks for a quota value AND opts in (see the
# FM_CREW_USAGE_ENABLE_QUOTA gate in fm_crew_usage_quota_spend_priority).
_fm_crew_usage_fetch_quota() {
  [ "$FM_CREW_USAGE_QUOTA_FETCHED" = 1 ] && return 0
  FM_CREW_USAGE_QUOTA_FETCHED=1
  command -v quota-axi >/dev/null 2>&1 || return 0
  FM_CREW_USAGE_QUOTA_JSON_CACHE=$(fm_run_timed "$FM_CREW_USAGE_QUOTA_TIMEOUT" quota-axi --full --json 2>/dev/null) \
    || FM_CREW_USAGE_QUOTA_JSON_CACHE=""
}

# spendPriority for one harness's mapped provider, or empty when the live
# lookup is not opted in (FM_CREW_USAGE_ENABLE_QUOTA != 1), quota-axi is
# absent, the provider has no coverage, or the field is not published for it.
fm_crew_usage_quota_spend_priority() {  # harness
  local harness=$1 prov
  [ "${FM_CREW_USAGE_ENABLE_QUOTA:-0}" = 1 ] || return 0
  prov=$(fm_account_quota_provider "$harness" 2>/dev/null) || return 0
  [ -n "$prov" ] || return 0
  _fm_crew_usage_fetch_quota
  [ -n "$FM_CREW_USAGE_QUOTA_JSON_CACHE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$FM_CREW_USAGE_QUOTA_JSON_CACHE" | jq -r --arg p "$prov" '
    [.providers[]? | select(.provider==$p)
     | .quotaSemantics.effectiveAvailability[0]?.selection.spendPriority?]
    | map(select(. != null)) | first // empty' 2>/dev/null
}

# Context percentage for a live task, as read from OUTSIDE the harness
# process. Always "n/a": see the file header for the confirmed absence of a
# firstmate-visible per-task live context signal on every harness checked so
# far. Takes harness so a future confirmed exception can branch here without
# changing every caller.
fm_crew_usage_context_pct() {  # harness
  printf 'n/a'
}

# The full usage row as JSON: {harness, model, context_pct, quota}. quota and
# context_pct are the string "n/a" when unavailable, never null, so a
# consumer can render the field directly without a null check.
fm_crew_usage_json() {  # <harness> <model>
  local harness=$1 model=${2:-} ctx quota
  ctx=$(fm_crew_usage_context_pct "$harness")
  quota=$(fm_crew_usage_quota_spend_priority "$harness")
  [ -n "$quota" ] || quota="n/a"
  jq -n --arg harness "$harness" --arg model "$model" --arg context_pct "$ctx" --arg quota "$quota" \
    '{harness:($harness // ""),model:($model // ""),context_pct:$context_pct,quota:$quota}'
}
