#!/usr/bin/env bash
# fm-crew-usage-lib.sh - single owner of the per-crew usage row (harness,
# model, context percentage, provider quota) surfaced by fm-fleet-snapshot.sh
# and rendered by the bearings skill's fleet-wide fallback view.
#
# Scope, deliberately narrow:
#   - harness, model: the caller reads these straight from state/<id>.meta;
#     this file does not re-parse meta and takes them as arguments. It does
#     normalize model: bin/fm-spawn.sh records the placeholders "default" and
#     "-" when no model was chosen, and those are reported as unrecorded (the
#     empty string) rather than rendered as a model name. For codex only, and
#     only under the same opt-in as the context read below, an unrecorded model
#     is recovered from the pane's own native footer - see
#     fm_crew_usage_model_from_pane.
#   - context percentage: firstmate reads the verified Codex/Claude statusline
#     diagnostic when its pane format carries Context N% left. Confirmed absent
#     for opencode (`opencode
#     stats` is a pull-only cost/token command, not a per-turn live
#     percentage), `pi --mode json` (single-turn JSON does not expose the
#     running task's context), and `cline --json` (same: its per-message JSON
#     does not expose the running task's context). context_pct is "n/a" when unavailable or unsupported;
#     this is a recorded finding, not a gap to route around with pane-scraping, which
#     firstmate-coding-guidelines' "Harness-dependent checks" section would
#     require two-test live proof for and this task's scope does not cover.
#     Like quota below, the live read is OFF by default and gated behind
#     FM_CREW_USAGE_ENABLE_CONTEXT=1, because reading it CAPTURES THE TASK'S
#     PANE. bin/fm-watch.sh backgrounds two snapshot consumers on every single
#     poll - fm-home-summary-refresh.sh (--secondmate-home-summary) and
#     fm-secondmate-reconcile.sh process-requests (--json) - so an
#     unconditional read here turns the canonical snapshot into a second pane
#     reader racing the watcher's own capture. The watcher's bare-turn-end
#     absorption proves churn by comparing consecutive pane captures, so a
#     competing capture costs churn evidence and resurfaces a wake the watcher
#     had proof to absorb (tests/fm-watch-triage.test.sh, "pane churn resets
#     prior wedge escalation state before the stale-path poll"). A bound alone
#     cannot fix that: a fast extra capture is still an extra capture. Only the
#     human-facing reader that renders the usage bar opts in
#     (bin/fm-bearings-snapshot.sh), so every supervision-path caller keeps
#     main's capture behaviour exactly.
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
FM_CREW_USAGE_CONTEXT_TIMEOUT=${FM_CREW_USAGE_CONTEXT_TIMEOUT:-1}
FM_CREW_USAGE_ACCOUNTS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-accounts-lib.sh"
FM_CREW_USAGE_QUOTA_CACHE_ACCOUNTS=()
FM_CREW_USAGE_QUOTA_CACHE_VALUES=()
FM_CREW_USAGE_QUOTA_CACHE_RESULT=""

# Refuses a non-positive or non-numeric bound, naming the knob the CALLER
# actually set: fm_run_timed's documented contract disables the deadline for a
# non-positive bound, so an unvalidated 0 would silently remove the bound
# instead of applying it. Sourcing fails, and every caller must fail closed on
# that (see bin/fm-fleet-snapshot.sh) - a snapshot that keeps going without
# these functions drops whole task rows, not just their usage field.
fm_crew_usage_validate_timeout() { # name value
  case "$2" in
    ''|*[!0-9]*|0) printf 'fm-crew-usage: %s must be a positive integer\n' "$1" >&2; return 2 ;;
  esac
}

# Retained under its original name for callers that validate the quota knob directly.
fm_crew_usage_validate_quota_timeout() { # value
  fm_crew_usage_validate_timeout FM_CREW_USAGE_QUOTA_TIMEOUT "$1"
}

fm_crew_usage_validate_timeout FM_CREW_USAGE_QUOTA_TIMEOUT "$FM_CREW_USAGE_QUOTA_TIMEOUT" || return $?
fm_crew_usage_validate_timeout FM_CREW_USAGE_CONTEXT_TIMEOUT "$FM_CREW_USAGE_CONTEXT_TIMEOUT" || return $?

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
  # shellcheck disable=SC2016 # Inner shell expands positional parameters.
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
# diagnostic where that pane contract is supported. Opt-in only
# (FM_CREW_USAGE_ENABLE_CONTEXT=1): this captures the task's pane, and the
# watcher runs snapshot consumers on its own poll loop (see the header).
fm_crew_usage_context_pct() {  # harness target
  local harness=$1 target=$2 status context
  [ "${FM_CREW_USAGE_ENABLE_CONTEXT:-0}" = 1 ] || { printf 'n/a'; return 0; }
  case "$harness" in codex|claude) ;; *) printf 'n/a'; return 0 ;; esac
  [ -n "$target" ] || { printf 'n/a'; return 0; }
  # FM_GUARD_READ_ONLY=1: fm-statusline-quota.sh runs fm-guard.sh on entry, and
  # the guard prints its WATCHER DOWN banner once per down-episode, CLAIMING that
  # episode with a marker. This call discards stderr, so without read-only mode a
  # /bearings run during a supervision lapse would swallow the banner and leave
  # the next guarded command claiming it was "already printed this episode".
  status=$(FM_GUARD_READ_ONLY=1 fm_run_timed "$FM_CREW_USAGE_CONTEXT_TIMEOUT" "${FM_CREW_USAGE_STATUSLINE_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-statusline-quota.sh}" "$target" 2>/dev/null) || {
    printf 'n/a'; return 0;
  }
  context=$(printf '%s\n' "$status" | sed -nE 's/.*(^| )context_pct=([0-9]+).*/\2/p' | tail -n1)
  case "$context" in
    ''|*[!0-9]*) printf 'n/a' ;;
    *) if [ "$context" -le 100 ]; then printf '%s' "$context"; else printf 'n/a'; fi ;;
  esac
}

# bin/fm-spawn.sh records model=default (and the secondmate path model=-) when
# no explicit model was chosen, so meta's model is frequently a PLACEHOLDER
# rather than a model name. Rendering "default" in a usage bar states a model
# firstmate never verified, so these sentinels are treated as "not recorded".
fm_crew_usage_model_is_placeholder() {  # model
  case "${1:-}" in ''|default|-|unknown|n/a) return 0 ;; *) return 1 ;; esac
}

# Codex's interactive TUI does not render the configured external statusline
# proxy (docs/verification/fm-harness-usage-bar.md, Slice 0), so its usage row
# has no model from that path. Its NATIVE footer does carry one, verified live
# on three running panes: "  gpt-5.6-terra high - <cwd>" (also xhigh). This
# recovers exactly that, and only that.
#
# Deliberately conservative, because a pane tail also contains transcript the
# crew may have printed: a line is accepted only from the bounded footer tail,
# only when it is <model> <effort> followed by the footer's middle-dot
# separator, and only when <effort> is one of Codex's own effort tokens. A
# pasted or echoed model name without that exact footer shape is ignored rather
# than reported as this crew's model.
#
# Opt-in behind the SAME gate as the context read, because it is the same cost:
# a pane capture. It also runs only when meta has no usable model, so an
# ordinary opted-in row adds no capture at all.
fm_crew_usage_model_from_pane() {  # harness target
  local harness=$1 target=$2 tail_out line model effort
  [ "${FM_CREW_USAGE_ENABLE_CONTEXT:-0}" = 1 ] || return 0
  [ -n "$target" ] || return 0
  case "$harness" in codex) ;; *) return 0 ;; esac
  # Read-only guard for the same reason as the context read above: fm-peek.sh
  # also runs fm-guard.sh, and this call discards stderr.
  tail_out=$(FM_GUARD_READ_ONLY=1 fm_run_timed "$FM_CREW_USAGE_CONTEXT_TIMEOUT" \
    "${FM_CREW_USAGE_PEEK_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-peek.sh}" \
    "$target" 6 2>/dev/null) || return 0
  while IFS= read -r line; do
    # <model> <effort> <middle-dot> <cwd>
    if [[ $line =~ ^[[:space:]]*([A-Za-z0-9][A-Za-z0-9._-]*)[[:space:]]+(minimal|low|medium|high|xhigh)[[:space:]]+·[[:space:]] ]]; then
      model=${BASH_REMATCH[1]}
      effort=${BASH_REMATCH[2]}
      [ -n "$effort" ] || continue
      printf '%s' "$model"
      return 0
    fi
  done <<< "$tail_out"
  return 0
}

# The full usage row as JSON: {harness, model, context_pct, quota}. quota and
# context_pct are the string "n/a" when unavailable, never null, so a
# consumer can render the field directly without a null check. model is the
# empty string when neither meta nor the harness's own footer records one, so
# the bearings renderer's "append when non-empty" rule omits it instead of
# printing a placeholder as a model name.
fm_crew_usage_json() {  # <harness> <model> <target> <account>
  local harness=$1 model=${2:-} target=${3:-} account=${4:-} ctx quota
  if fm_crew_usage_model_is_placeholder "$model"; then
    model=$(fm_crew_usage_model_from_pane "$harness" "$target")
  fi
  ctx=$(fm_crew_usage_context_pct "$harness" "$target")
  quota=$(fm_crew_usage_quota_spend_priority "$harness" "$account")
  [ -n "$quota" ] || quota="n/a"
  jq -n --arg harness "$harness" --arg model "$model" --arg context_pct "$ctx" --arg quota "$quota" \
    '{harness:($harness // ""),model:($model // ""),context_pct:$context_pct,quota:$quota}'
}
