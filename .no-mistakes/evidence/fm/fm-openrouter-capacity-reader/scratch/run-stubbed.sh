#!/usr/bin/env bash
# Drives bin/fm-openrouter-quota.sh against the stub curl and prints a transcript.
set -u
EV=$(cd "$(dirname "$0")/.." && pwd -P)
SCRATCH="$EV/scratch"
REPO=$1
HOME_T="$SCRATCH/home"
rm -rf "$HOME_T"
mkdir -p "$HOME_T/state"
chmod +x "$SCRATCH/bin/curl"
export FM_HOME="$HOME_T" FM_OPENROUTER_PROBE_INTERVAL_SECONDS=0 OPENROUTER_API_KEY_TOKENS='sk-or-stub-not-a-real-key' PATH="$SCRATCH/bin:$PATH"
R="$REPO/bin/fm-openrouter-quota.sh"

echo '### Stubbed HTTP (offline) end-to-end transcript: key is a dummy value, curl is a stub on PATH'
echo
echo '$ fm-openrouter-quota.sh report --now 1000   # stub catalog: 1 healthy free model, one 404 privacy gate, one 403, one 429, 2 paid, 1 variable-priced'
"$R" report --now 1000 2>"$SCRATCH/err1"; echo "exit=$?"
echo '--- stderr (sanitized diagnostics) ---'; cat "$SCRATCH/err1"
echo
echo '$ cat state/.openrouter-quota.json   # persisted per-model state (429 cooldown + remembered 404/403 verdicts)'
jq . "$HOME_T/state/.openrouter-quota.json"
echo
echo '$ fm-openrouter-quota.sh report --now 1001   # upstream gemma would now answer 200, but its cooldown is live: not re-probed, still ineligible'
STUB_GEMMA_CODE=200 "$R" report --now 1001 2>"$SCRATCH/err2" | jq -c '.routing, (.models[]|select(.id=="google/gemma-4-31b-it:free"))'; echo "exit=$?"
cat "$SCRATCH/err2"
echo
echo '$ fm-openrouter-quota.sh report --now 2800   # cooldown expired on read: probed live again and eligible'
STUB_GEMMA_CODE=200 "$R" report --now 2800 2>"$SCRATCH/err3" | jq -c '.routing, (.models[]|select(.id=="google/gemma-4-31b-it:free"))'; echo "exit=$?"
cat "$SCRATCH/err3"
echo
echo '$ fm-openrouter-quota.sh record-failure --model cohere/north-mini-code:free --observed 429 --now 2801   # dispatch observed a real 429 on launch'
"$R" record-failure --model cohere/north-mini-code:free --observed 429 --now 2801; echo "exit=$?"
echo
echo '$ fm-openrouter-quota.sh report --now 2802 | jq .routing   # only free model cooling down: eligibleFree empty, cheap-paid ordering remains for fallback'
STUB_GEMMA_CODE=429 "$R" report --now 2802 2>/dev/null | jq -c '.routing'
echo
echo '$ fm-openrouter-quota.sh clear --model cohere/north-mini-code:free'
"$R" clear --model cohere/north-mini-code:free; echo "exit=$?"
echo
echo '$ fm-openrouter-quota.sh report --now 2803 | jq .routing'
STUB_GEMMA_CODE=429 "$R" report --now 2803 2>/dev/null | jq -c '.routing'
echo
echo '$ env -u OPENROUTER_API_KEY_TOKENS -u OPENROUTER_API_KEY fm-openrouter-quota.sh report   # missing key fails closed'
env -u OPENROUTER_API_KEY_TOKENS -u OPENROUTER_API_KEY "$R" report; echo "exit=$?"
