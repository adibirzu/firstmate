#!/usr/bin/env bash
# Operator-level walkthrough of the reconciled quota-aware crew dispatch.
# Drives the real bin/fm-dispatch-select.mjs the way crew dispatch does.
set -u
ROOT=${1:?repo root}
SEL="$ROOT/bin/fm-dispatch-select.mjs"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-dispatch-demo.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
NOW=1000
STAMP=1970-01-01T00:16:40.000Z   # == epoch 1000, fresh at --now 1000
OLD=1970-01-01T00:00:00.000Z     # 1000s old: past telemetryMaxAgeSeconds

home() { local h="$LAB/$1/home"; mkdir -p "$h/state" "$h/config"; printf '%s' "$h"; }

run() { # <label> <home> <quota> <profiles> [now]
  # FM_DISPATCH_STATE_FILE is left at its default so recorded cooldowns are read.
  local label=$1 h=$2 q=$3 body=$4 now=${5:-$NOW} out err rc=0
  err="$h/err.txt"
  printf '\n--- %s\n' "$label"
  printf '$ fm-dispatch-select.mjs select --quota-json quota.json %s\n' "$body"
  out=$(FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_CONFIG_OVERRIDE="$h/config" \
        "$SEL" select --quota-json "$q" --now "$now" "$body" 2>"$err") || rc=$?
  [ -n "$out" ] && printf 'selected -> %s\n' "$out"
  [ -s "$err" ] && sed 's/^/diagnostic: /' "$err"
  printf 'exit=%s\n' "$rc"
}

echo "=============================================================="
echo " Quota-aware crew dispatch — reconciled fork+upstream design"
echo " selector: bin/fm-dispatch-select.mjs   (real binary, fixture telemetry)"
echo "=============================================================="

# ---------------------------------------------------------------- A
H=$(home healthy); Q="$H/quota.json"
cat > "$Q" <<JSON
{"schemaVersion":5,"generatedAt":"$STAMP","providers":[
 {"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":80}]},
 {"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":80}]}
]}
JSON
echo
echo "A. Healthy fleet: two subscriptions above reserve rotate (no starvation)."
for i in 1 2 3 4; do
  FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
    FM_DISPATCH_STATE_FILE="$H/state/dispatch.json" \
    "$SEL" select --quota-json "$Q" --now "$NOW" \
    '[{"harness":"claude","model":"sonnet"},{"harness":"codex","model":"gpt"}]' 2>/dev/null \
    | sed "s/^/  dispatch $i -> /"
done

# ---------------------------------------------------------------- B
H=$(home reserve); Q="$H/quota.json"
cat > "$Q" <<JSON
{"schemaVersion":5,"generatedAt":"$STAMP","providers":[
 {"provider":"cursor","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":12}]},
 {"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":70}]}
]}
JSON
run "B. Fork reservePercent (default 20): Cursor at 12% is held back, work redirects." \
  "$H" "$Q" '[{"harness":"cursor"},{"harness":"codex"}]'

# ---------------------------------------------------------------- C
H=$(home stale); Q="$H/quota.json"
cat > "$Q" <<JSON
{"schemaVersion":5,"generatedAt":"$OLD","providers":[
 {"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":90}]},
 {"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":90}]}
]}
JSON
run "C. Fork telemetryMaxAgeSeconds: stale telemetry fails CLOSED, never guesses unmetered." \
  "$H" "$Q" '[{"harness":"claude"},{"harness":"codex"}]'

# ---------------------------------------------------------------- D
H=$(home window); Q="$H/quota.json"
cat > "$Q" <<JSON
{"schemaVersion":5,"generatedAt":"$STAMP","providers":[
 {"provider":"cursor","state":{"status":"fresh","stale":false},"windows":[
   {"id":"api_usage","percentRemaining":3},
   {"id":"auto_usage","percentRemaining":88}]}
]}
JSON
run "D1. Fork per-profile quotaWindow: undeclared profile is priced on the WORST pool (3%) and refused." \
  "$H" "$Q" '[{"harness":"cursor","model":"cursor-grok-4.6-high"}]'
run "D2. Same telemetry, profile declares its own pool auto_usage -> dispatched on its healthy pool." \
  "$H" "$Q" '[{"harness":"cursor","model":"cursor-grok-4.6-high","quotaWindow":"auto_usage"}]'
run "D3. Declared pool absent from telemetry -> fails closed, no fallback to a rosier window." \
  "$H" "$Q" '[{"harness":"cursor","quotaWindow":"renamed_usage"}]'

# ---------------------------------------------------------------- E
H=$(home spend); Q="$H/quota.json"
cat > "$Q" <<JSON
{"schemaVersion":5,"generatedAt":"$STAMP","providers":[
 {"provider":"claude","state":{"status":"fresh","stale":false},
  "windows":[{"id":"all","percentRemaining":80}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":80,
     "selection":{"status":"known","spendPriority":-1.1111}}]}},
 {"provider":"codex","state":{"status":"fresh","stale":false},
  "windows":[{"id":"all","percentRemaining":40}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":40,
     "selection":{"status":"known","spendPriority":-0.8333}}]}}
]}
JSON
run "E. Upstream spendPriority ranks the remaining eligible candidates: codex (40% but better spend priority) beats claude (80%)." \
  "$H" "$Q" '[{"harness":"claude","model":"sonnet"},{"harness":"codex","model":"gpt"}]'

# ---------------------------------------------------------------- F
H=$(home cooldown); Q="$H/quota.json"
cat > "$Q" <<JSON
{"schemaVersion":5,"generatedAt":"$STAMP","providers":[
 {"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":80}]},
 {"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":80}]}
]}
JSON
printf 'harness=codex\n' > "$H/state/rate-task.meta"
printf 'failed: provider rate limit reached\n' > "$H/state/rate-task.status"
printf '\n--- F. Fork cooldownSeconds: a VERIFIED rate-limit on a real task parks that provider.\n'
printf '$ fm-dispatch-select.mjs record-failure --provider codex --task rate-task\n'
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
  "$SEL" record-failure --provider codex --task rate-task --now "$NOW" 2>&1 | sed 's/^/  /'
run "   next dispatch after the cooldown is recorded" \
  "$H" "$Q" '[{"harness":"claude"},{"harness":"codex"}]' 1001
printf '$ fm-dispatch-select.mjs record-failure --provider codex --task ordinary-task  # no rate-limit evidence\n'
printf 'harness=codex\n' > "$H/state/ordinary-task.meta"
printf 'working: ordinary task\n' > "$H/state/ordinary-task.status"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
  "$SEL" record-failure --provider codex --task ordinary-task --now "$NOW" 2>&1 | sed 's/^/  refused: /'
echo
echo "=============================================================="
