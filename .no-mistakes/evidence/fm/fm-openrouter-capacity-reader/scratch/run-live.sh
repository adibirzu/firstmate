#!/usr/bin/env bash
# Live end-to-end run of bin/fm-openrouter-quota.sh against openrouter.ai.
# Key is read from ~/.claude/.env into the environment only; it is never echoed.
set -u
EV=$(cd "$(dirname "$0")/.." && pwd -P)
SCRATCH="$EV/scratch"
REPO=$1
LIVE_HOME="$SCRATCH/live-home"
rm -rf "$LIVE_HOME"
mkdir -p "$LIVE_HOME/state"
key_line=$(grep -m1 '^OPENROUTER_API_KEY_TOKENS=' "$HOME/.claude/.env") || { echo "no OPENROUTER_API_KEY_TOKENS in ~/.claude/.env"; exit 9; }
key_val=${key_line#OPENROUTER_API_KEY_TOKENS=}
key_val=${key_val%\"}; key_val=${key_val#\"}; key_val=${key_val%\'}; key_val=${key_val#\'}
export OPENROUTER_API_KEY_TOKENS="$key_val"
unset OPENROUTER_API_KEY
export FM_HOME="$LIVE_HOME"
R="$REPO/bin/fm-openrouter-quota.sh"

start=$(date +%s)
"$R" report > "$SCRATCH/live-full.json" 2> "$SCRATCH/live.err"
rc=$?
end=$(date +%s)

{
  echo "### Live end-to-end run against https://openrouter.ai on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "### Key sourced from env (OPENROUTER_API_KEY_TOKENS); value redacted everywhere."
  echo
  echo '$ export FM_HOME=<isolated-dir>; export OPENROUTER_API_KEY_TOKENS=<redacted>'
  echo '$ bin/fm-openrouter-quota.sh report 2>live.err > live-full.json'
  echo "exit=$rc elapsed_seconds=$((end - start))"
  echo
  echo '--- stderr (sanitized diagnostics, verbatim) ---'
  cat "$SCRATCH/live.err"
  echo
  echo '--- bounded stdout: jq summary of live-full.json ---'
  jq '{
    schemaVersion, generatedAt, key,
    modelCount: (.models|length),
    freeCount: ([.models[] | select(.tier=="free")] | length),
    routing: {eligibleFree: .routing.eligibleFree, unverifiedPaidByCost: .routing.unverifiedPaidByCost[:5]},
    free: [.models[] | select(.tier=="free") | {id, eligible, reason}],
    paidSamples: [.models[] | select(.id=="openai/gpt-oss-20b" or .id=="openai/gpt-oss-120b" or .id=="openrouter/auto") | {id, tier, eligible, promptPerMillion, completionPerMillion, reason}],
    pricingMissingCount: ([.models[] | select(.reason=="pricing-missing")] | length),
    eligiblePaidCount: ([.models[] | select(.tier=="paid" and .eligible)] | length)
  }' "$SCRATCH/live-full.json"
  echo
  echo '--- persisted state file (state/.openrouter-quota.json), keys only ---'
  jq '{version, cooldowns: (.cooldowns|keys), verdicts: (.verdicts | to_entries | map({id: .key, class: .value.class}))}' "$LIVE_HOME/state/.openrouter-quota.json"
  echo
  echo '--- key-leak checks (counts of the live key value in outputs; all must be 0) ---'
  printf 'stdout: %s\n' "$(grep -cF -- "$OPENROUTER_API_KEY_TOKENS" "$SCRATCH/live-full.json")"
  printf 'stderr: %s\n' "$(grep -cF -- "$OPENROUTER_API_KEY_TOKENS" "$SCRATCH/live.err")"
  printf 'files under FM_HOME containing key: %s\n' "$(grep -rlF -- "$OPENROUTER_API_KEY_TOKENS" "$LIVE_HOME" | wc -l | tr -d ' ')"
  printf 'leftover fm-openrouter-quota temp dirs: %s\n' "$(ls -d "${TMPDIR:-/tmp}"/fm-openrouter-quota.* 2>/dev/null | wc -l | tr -d ' ')"
} > "$EV/live-e2e-transcript.txt" 2>&1

# Second run: remembered verdicts must be skipped (not re-probed) and only non-remembered free models probed.
start2=$(date +%s)
"$R" report > "$SCRATCH/live-full-2.json" 2> "$SCRATCH/live-2.err"
rc2=$?
end2=$(date +%s)
{
  echo
  echo '### Second live run in the same FM_HOME: remembered 404/403 verdicts are not re-probed'
  echo '$ bin/fm-openrouter-quota.sh report 2>live-2.err > live-full-2.json'
  echo "exit=$rc2 elapsed_seconds=$((end2 - start2))"
  echo '--- stderr ---'
  cat "$SCRATCH/live-2.err"
  echo '--- routing ---'
  jq -c '.routing | {eligibleFree, unverifiedPaidByCost: .unverifiedPaidByCost[:3]}' "$SCRATCH/live-full-2.json"
  printf 'key in stdout/stderr: %s/%s\n' "$(grep -cF -- "$OPENROUTER_API_KEY_TOKENS" "$SCRATCH/live-full-2.json")" "$(grep -cF -- "$OPENROUTER_API_KEY_TOKENS" "$SCRATCH/live-2.err")"
} >> "$EV/live-e2e-transcript.txt" 2>&1

# Final paranoia: assert the transcript itself does not contain the key, then scrub the scratch copies.
if grep -qF -- "$OPENROUTER_API_KEY_TOKENS" "$EV/live-e2e-transcript.txt"; then
  echo "KEY LEAKED INTO TRANSCRIPT" >&2
  rm -f "$EV/live-e2e-transcript.txt"
  exit 8
fi
rm -rf "$LIVE_HOME" "$SCRATCH/live-full.json" "$SCRATCH/live-full-2.json" "$SCRATCH/live.err" "$SCRATCH/live-2.err"
echo "live runs exit=$rc,$rc2"
