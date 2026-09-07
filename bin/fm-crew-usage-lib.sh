#!/usr/bin/env bash
# fm-crew-usage-lib.sh - single owner of the per-crew usage row (harness,
# model, context percentage, provider quota) surfaced by fm-fleet-snapshot.sh
# and rendered by the bearings skill's fleet-wide fallback view.
#
# Scope, deliberately narrow (Slice 1/2 of data/fm-harness-usage-bar/report.md,
# captain-approved 2026-09-06):
#   - harness, model: the caller reads these straight from state/<id>.meta;
#     this file does not re-parse meta and takes them as arguments.
#   - context percentage: firstmate reads the verified Codex/Claude statusline
#     diagnostic when its pane format carries Context N% left. Confirmed absent
#     for opencode (`opencode
#     stats` is a pull-only cost/token command, not a per-turn live
#     percentage), `pi --mode json` (single-turn JSON carries no token/context
#     field), and `cline --json` (same: no token/context field in its
#     per-message JSON). context_pct is therefore always "n/a" today; this is
#     a recorded finding, not a gap to route around with pane-scraping, which
#     firstmate-coding-guidelines' "Harness-dependent checks" section would
#     require two-test live proof for and this task's scope does not cover.
#   - quota: quota-axi's per-provider spendPriority, read only under the task's
#     recorded account isolation; an absent or unsupported account is unavailable.
#     It is the same comparable
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
#     bound miss is treated the same as quota-axi being absent. Fetched once
#     per account per process and cached, so every task on that account shares
#     one quota-axi call. No new poller: this
#     file adds a pure, on-demand read to fm-fleet-snapshot.sh's existing
#     per-task loop; nothing here schedules or repeats on its own.
#
# Depends on fm_account_quota_provider and fm_account_quota_json
# (bin/fm-accounts-lib.sh) for account-bound quota reads, and fm_run_timed
# (bin/fm-timeout-lib.sh) for the bounded call; callers must source both files first.

FM_CREW_USAGE_QUOTA_TIMEOUT=${FM_CREW_USAGE_QUOTA_TIMEOUT:-5}
FM_CREW_USAGE_ACCOUNTS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-accounts-lib.sh"
FM_CREW_USAGE_QUOTA_CACHE_ACCOUNTS=()
FM_CREW_USAGE_QUOTA_CACHE_VALUES=()
FM_CREW_USAGE_QUOTA_CACHE_RESULT=""

fm_crew_usage_validate_quota_timeout() { # value
  case "$1" in
    ''|*[!0-9]*|0) printf 'fm-crew-usage: FM_CREW_USAGE_QUOTA_TIMEOUT must be a positive integer\n' >&2; return 2 ;;
  esac
}

fm_crew_usage_validate_quota_timeout "$FM_CREW_USAGE_QUOTA_TIMEOUT" || return $?

# Fetch quota-axi's full JSON once per process; cache the raw text (empty
# string on any failure, including quota-axi absent or the bound being hit).
# Never called unless a caller asks for a quota value AND opts in (see the
# FM_CREW_USAGE_ENABLE_QUOTA gate in fm_crew_usage_quota_spend_priority).
_fm_crew_usage_fetch_quota() { # account provider
  local account=$1 prov=$2 i out=""
  FM_CREW_USAGE_QUOTA_CACHE_RESULT=""
  for i in "${!FM_CREW_USAGE_QUOTA_CACHE_ACCOUNTS[@]}"; do
    if [ "${FM_CREW_USAGE_QUOTA_CACHE_ACCOUNTS[i]}" = "$account" ]; then
      FM_CREW_USAGE_QUOTA_CACHE_RESULT=${FM_CREW_USAGE_QUOTA_CACHE_VALUES[i]}
      return 0
    fi
  done
  out=$(fm_run_timed "$FM_CREW_USAGE_QUOTA_TIMEOUT" bash -c '
    . "$1"
    fm_account_quota_json "$2" "$3"
  ' _ "$FM_CREW_USAGE_ACCOUNTS_LIB" "$account" "$prov" 2>/dev/null) || out=""
  FM_CREW_USAGE_QUOTA_CACHE_ACCOUNTS+=("$account")
  FM_CREW_USAGE_QUOTA_CACHE_VALUES+=("$out")
  FM_CREW_USAGE_QUOTA_CACHE_RESULT=$out
}

# spendPriority for one harness's mapped provider, or empty when the live
# lookup is not opted in (FM_CREW_USAGE_ENABLE_QUOTA != 1), quota-axi is
# absent, the provider has no coverage, or the field is not published for it.
fm_crew_usage_prepare_quota() { # harness account
  local harness=$1 account=${2:-} prov
  [ "${FM_CREW_USAGE_ENABLE_QUOTA:-0}" = 1 ] || return 0
  [ -n "$account" ] || return 0
  prov=$(fm_account_quota_provider "$harness" 2>/dev/null) || return 0
  [ -n "$prov" ] || return 0
  _fm_crew_usage_fetch_quota "$account" "$prov"
}

fm_crew_usage_quota_spend_priority() {  # harness account
  local harness=$1 account=${2:-} prov
  [ "${FM_CREW_USAGE_ENABLE_QUOTA:-0}" = 1 ] || return 0
  [ -n "$account" ] || return 0
  prov=$(fm_account_quota_provider "$harness" 2>/dev/null) || return 0
  _fm_crew_usage_fetch_quota "$account" "$prov"
  [ -n "$FM_CREW_USAGE_QUOTA_CACHE_RESULT" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$FM_CREW_USAGE_QUOTA_CACHE_RESULT" | jq -r --arg p "$prov" '
    [.providers[]? | select(.provider==$p)
     | .quotaSemantics.effectiveAvailability[0]?.selection.spendPriority?]
    | map(select(. != null)) | first // empty' 2>/dev/null
}

# Context percentage for a live task, as read from its verified statusline
# diagnostic where that pane contract is supported.
fm_crew_usage_context_pct() {  # harness target
  local harness=$1 target=$2 status source context
  case "$harness" in codex|claude) ;; *) printf 'n/a'; return 0 ;; esac
  [ -n "$target" ] || { printf 'n/a'; return 0; }
  status=$("${FM_CREW_USAGE_STATUSLINE_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-statusline-quota.sh}" "$target" 2>/dev/null) || {
    printf 'n/a'; return 0;
  }
  source=$(printf '%s\n' "$status" | sed -nE 's/.*(^| )source=([^ ]+).*/\2/p' | tail -n1)
  [ "$source" = "$harness" ] || { printf 'n/a'; return 0; }
  context=$(printf '%s\n' "$status" | sed -nE 's/.*(^| )context_pct=([0-9]+).*/\2/p' | tail -n1)
  case "$context" in ''|*[!0-9]*) printf 'n/a' ;; *) printf '%s' "$context" ;; esac
}

# The full usage row as JSON: {harness, model, context_pct, quota}. quota and
# context_pct are the string "n/a" when unavailable, never null, so a
# consumer can render the field directly without a null check.
fm_crew_usage_json() {  # <harness> <model> <target> <account>
  local harness=$1 model=${2:-} target=${3:-} account=${4:-} ctx quota
  ctx=$(fm_crew_usage_context_pct "$harness" "$target")
  quota=$(fm_crew_usage_quota_spend_priority "$harness" "$account")
  [ -n "$quota" ] || quota="n/a"
  jq -n --arg harness "$harness" --arg model "$model" --arg context_pct "$ctx" --arg quota "$quota" \
    '{harness:($harness // ""),model:($model // ""),context_pct:$context_pct,quota:$quota}'
}
