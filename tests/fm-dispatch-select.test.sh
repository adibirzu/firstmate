#!/usr/bin/env bash
# Behavior tests for subscription-aware crew dispatch selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECTOR="$ROOT/bin/fm-dispatch-select.mjs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-dispatch-select.XXXXXX")
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}
NOW=1000
STAMP=1970-01-01T00:16:40.000Z

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

make_fakebin() {
  local name=$1 dir
  dir="$TMP_ROOT/$name/fakebin"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

write_quota() { # <file> <claude-status> <claude-remaining> <codex-status> <codex-remaining> [stamp]
  local file=$1 cst=$2 crem=$3 ost=$4 orem=$5 stamp=${6:-$STAMP}
  cat > "$file" <<JSON
{"schemaVersion":3,"generatedAt":"$stamp","providers":[
  {"provider":"claude","state":{"status":"$cst","stale":false},"windows":[{"id":"all","percentRemaining":$crem}]},
  {"provider":"codex","state":{"status":"$ost","stale":false},"windows":[{"id":"all","percentRemaining":$orem}]}
]}
JSON
}

run_select() { # <home> <fakebin> <quota> <state-file-name> <json> [now]
  local home=$1 fakebin=$2 quota=$3 state_name=$4 body=$5 now=${6:-$NOW}
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DISPATCH_STATE_FILE="$home/state/$state_name" \
    PATH="$fakebin:$BASE_PATH" \
    "$SELECTOR" select --quota-json "$quota" --now "$now" "$body"
}

test_distribution_is_deterministic_balanced_and_array_order_independent() {
  local home fakebin quota profiles reversed first reversed_first selected seen count
  home=$(make_home distribution)
  fakebin=$(make_fakebin distribution)
  quota="$home/quota.json"
  write_quota "$quota" fresh 80 fresh 80
  profiles='[{"harness":"claude","model":"sonnet"},{"harness":"codex","model":"gpt"}]'
  reversed='[{"harness":"codex","model":"gpt"},{"harness":"claude","model":"sonnet"}]'

  first=$(run_select "$home" "$fakebin" "$quota" a.json "$profiles" 2>/dev/null | jq -r .harness)
  reversed_first=$(run_select "$home" "$fakebin" "$quota" b.json "$reversed" 2>/dev/null | jq -r .harness)
  [ "$first" = "$reversed_first" ] || fail "initial deterministic choice changed with array order: $first vs $reversed_first"

  seen=$first
  selected=$(run_select "$home" "$fakebin" "$quota" a.json "$profiles" 2>/dev/null | jq -r .harness)
  seen="$seen $selected"
  for selected in claude codex; do
    count=$(printf '%s\n' "$seen" | tr ' ' '\n' | grep -cx "$selected")
    [ "$count" -eq 1 ] || fail "two healthy subscriptions did not rotate once each: $seen"
  done
  pass "dispatch selection is array-order independent and rotates healthy subscriptions exactly"
}

test_stale_unavailable_and_reserve_thresholds_fail_closed() {
  local home fakebin quota out rc profiles old_stamp
  home=$(make_home fail-closed)
  fakebin=$(make_fakebin fail-closed)
  quota="$home/quota.json"
  profiles='[{"harness":"claude"},{"harness":"codex"}]'
  old_stamp=1970-01-01T00:00:00.000Z

  write_quota "$quota" fresh 90 fresh 90 "$old_stamp"
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" stale.json "$profiles" 2>&1) || rc=$?
  expect_code 3 "$rc" "stale telemetry must stop all metered dispatch"
  assert_contains "$out" "stale or undated" "stale telemetry refusal was not inspectable"

  write_quota "$quota" fresh 20 fresh 21
  out=$(run_select "$home" "$fakebin" "$quota" reserve.json "$profiles" 2>"$home/reserve.err")
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = codex ] || fail "candidate above reserve did not beat candidate at reserve: $out"
  assert_contains "$(cat "$home/reserve.err")" "at or below 20% reserve" "reserve refusal omitted its threshold"

  write_quota "$quota" auth_required 99 fresh 75
  out=$(run_select "$home" "$fakebin" "$quota" unavailable.json "$profiles" 2>/dev/null)
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = codex ] || fail "fresh provider did not fail over around unavailable telemetry: $out"

  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"claude","state":{"status":"fresh","stale":false},"quotaSemantics":{"effectiveAvailability":[{"status":"known","effectivePercentRemaining":90}]}},
  {"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"percentRemaining":80}]}
]}
JSON
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" windowless.json '[{"harness":"claude"}]' 2>&1) || rc=$?
  expect_code 3 "$rc" "windowless telemetry must stop metered dispatch despite aggregate availability"
  assert_contains "$out" "no usable live window percentage" "windowless telemetry refusal was unclear"
  pass "dispatch excludes stale, unavailable, and reserve-tight metered providers"
}

test_verified_failure_creates_cooldown_and_failover() {
  local home fakebin quota profiles out rc
  home=$(make_home cooldown)
  fakebin=$(make_fakebin cooldown)
  quota="$home/quota.json"
  write_quota "$quota" fresh 80 fresh 80
  profiles='[{"harness":"claude"},{"harness":"codex"}]'
  printf 'harness=codex\n' > "$home/state/rate-task.meta"
  printf 'failed: provider rate limit reached\n' > "$home/state/rate-task.status"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$BASE_PATH" "$SELECTOR" record-failure --provider codex --task rate-task --now 1000 \
    >/dev/null 2>&1 || fail "verified rate-limit evidence did not create cooldown"
  out=$(run_select "$home" "$fakebin" "$quota" .dispatch-routing.json "$profiles" 1001 2>"$home/select.err")
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = claude ] || fail "cooldown did not fail over to Claude: $out"
  assert_contains "$(cat "$home/select.err")" "cooldown until epoch 2800" "cooldown diagnostic omitted its bound"

  printf 'harness=codex\n' > "$home/state/no-evidence.meta"
  printf 'working: ordinary task\n' > "$home/state/no-evidence.status"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$SELECTOR" record-failure --provider codex --task no-evidence --now 1000 2>&1) || rc=$?
  expect_code 2 "$rc" "cooldown without evidence must be rejected"
  assert_contains "$out" "contains no rate-limit or quota-exhaustion evidence" "evidence refusal was unclear"

  printf 'harness=pi\nprovider=claude\n' > "$home/state/pi-rate-task.meta"
  printf 'failed: provider quota exhausted\n' > "$home/state/pi-rate-task.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$BASE_PATH" "$SELECTOR" record-failure --provider claude --task pi-rate-task --now 1000 \
    >/dev/null 2>&1 || fail "recorded non-native routing provider did not create cooldown"
  pass "verified provider failure creates cooldown and deterministic failover"
}

test_invalid_profiles_and_settings_are_actionable() {
  local home fakebin quota out rc
  home=$(make_home invalid)
  fakebin=$(make_fakebin invalid)
  quota="$home/quota.json"
  write_quota "$quota" fresh 80 fresh 80

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" mismatch.json \
    '[{"harness":"kimi","model":"kimi-code/k3"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "Kimi must remain outside subscription dispatch"
  assert_contains "$out" "Kimi is unsupported for subscription dispatch" "Kimi exclusion was unclear"

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" native-mismatch.json \
    '[{"harness":"codex","provider":"claude"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "native harness/provider mismatch must be rejected"
  assert_contains "$out" "native harness codex requires provider codex" "native provider mismatch was unclear"

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" kimi-provider.json \
    '[{"harness":"kimi","provider":"claude"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "Kimi must remain unavailable even with another provider"
  assert_contains "$out" "Kimi is unsupported for subscription dispatch" "Kimi provider override was unclear"

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" raw-kimi.json \
    '[{"harness":"env X=1 kimi --auto","provider":"claude"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "raw commands must remain outside subscription dispatch"
  assert_contains "$out" "subscription dispatch requires a verified harness" "raw command exclusion was unclear"

  printf '%s\n' '{"subscriptionRouting":{"reservePercent":100}}' > "$home/config/crew-dispatch.json"
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" settings.json '[{"harness":"codex"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "out-of-range reserve must be rejected"
  assert_contains "$out" "reservePercent must be an integer from 0 to 99" "settings error omitted its range"

  printf '%s\n' '[]' > "$home/config/crew-dispatch.json"
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" root-array.json '[{"harness":"codex"}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "non-object dispatch config roots must be rejected"
  assert_contains "$out" "config/crew-dispatch.json must be an object" "root schema refusal was unclear"
  pass "subscription route mismatches and malformed settings fail as configuration errors"
}

test_existing_wrapper_and_grok_routes_remain_selectable() {
  local home fakebin quota out
  home=$(make_home compatible-routes)
  fakebin=$(make_fakebin compatible-routes)
  quota="$home/quota.json"
  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"percentRemaining":70}]},
  {"provider":"grok","state":{"status":"fresh","stale":false},"windows":[{"percentRemaining":70}]}
]}
JSON
  out=$(run_select "$home" "$fakebin" "$quota" state.json \
    '[{"harness":"pi","provider":"claude","model":"anthropic/example"},{"harness":"grok"}]' 2>/dev/null)
  run_select "$home" "$fakebin" "$quota" state.json \
    '[{"harness":"pi","provider":"claude","model":"anthropic/example"},{"harness":"grok"}]' 2>/dev/null \
    | jq -e --arg first "$(printf '%s\n' "$out" | jq -r .harness)" '.harness != $first' >/dev/null \
    || fail "existing explicit wrapper and native Grok routes did not rotate"
  pass "existing explicit wrapper-provider and native Grok routes remain selectable"
}

# grok's real quota surface reports NO windows at all: quota-axi tries its web
# and pi:xai sources, resolves nothing, and reports status=error with
# authStatus=usable. That combination is the trap - auth is fine, so a selector
# that only checked auth would price grok as if it had headroom. Usable auth is
# not capacity evidence, and unavailable evidence makes only that provider
# ineligible while a healthy candidate still wins.
test_grok_without_a_resolvable_quota_window_is_not_priced() {
  local home fakebin quota out rc=0
  home=$(make_home grok-no-window)
  fakebin=$(make_fakebin grok-no-window)
  quota="$home/quota.json"
  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":80}]},
  {"provider":"grok","source":"unavailable","windows":[],"state":{"status":"error","stale":false,"error":"Grok quota unavailable","authStatus":"usable"}}
]}
JSON
  # Against a healthy candidate, the one with no resolvable window must not win.
  out=$(run_select "$home" "$fakebin" "$quota" mixed.json \
    '[{"harness":"claude","model":"sonnet"},{"harness":"grok"}]' 2>/dev/null)
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = claude ] \
    || fail "grok with no resolvable quota window was priced against a healthy candidate: $out"

  # Alone, it must fail as an inspectable refusal rather than silently dispatch
  # on capacity nobody measured.
  out=$(run_select "$home" "$fakebin" "$quota" alone.json '[{"harness":"grok"},{"harness":"grok"}]' 2>&1) || rc=$?
  [ "$rc" != 0 ] \
    || fail "a grok-only array with no resolvable quota window should not report a priced selection: $out"
  pass "fm-dispatch-select: usable grok auth with no quota window is not treated as capacity"
}

test_new_verified_adapters_with_providers_are_selectable() {
  local home fakebin quota out harness provider
  home=$(make_home new-adapters)
  fakebin=$(make_fakebin new-adapters)
  quota="$home/quota.json"
  # cursor is native to the `cursor` provider quota-axi reports, so the
  # fixture must carry cursor telemetry alongside claude/codex.
  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":80}]},
  {"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":80}]},
  {"provider":"cursor","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":80}]}
]}
JSON

  # cline/copilot are BYO adapters with no subscription quota, so they borrow an
  # explicit provider's credit identity; cursor resolves natively to cursor.
  out=$(run_select "$home" "$fakebin" "$quota" state.json \
    '[{"harness":"cline","provider":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"cursor"},{"harness":"copilot","provider":"claude","model":"gpt-5.6","effort":"max"}]' 2>/dev/null)
  harness=$(printf '%s\n' "$out" | jq -r .harness)
  provider=$(printf '%s\n' "$out" | jq -r .provider)
  case "$harness:$provider" in
    cline:claude|cursor:cursor|copilot:claude) ;;
    *) fail "new verified adapter profile selected an unexpected concrete route: $out" ;;
  esac

  # Credit-gating: with cursor exhausted (0% window, below the 20% reserve),
  # cursor must be excluded and dispatch redirects to a healthy provider.
  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":80}]},
  {"provider":"cursor","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":0}]}
]}
JSON
  out=$(run_select "$home" "$fakebin" "$quota" state2.json \
    '[{"harness":"cursor"},{"harness":"codex"}]' 2>/dev/null)
  [ "$(printf '%s\n' "$out" | jq -r .provider)" = "codex" ] \
    || fail "exhausted cursor should have redirected away from cursor, got: $out"
  pass "new verified adapters selectable; cursor credit-routes on native cursor quota"
}

# A provider whose pools are billed separately: its worst window is spent while
# the pool a given route draws on is healthy. Priced provider-wide the whole
# provider is refused; priced on its declared pool the healthy route survives.
write_split_pool_quota() { # <file> <api-remaining> [stamp]
  local file=$1 api=$2 stamp=${3:-$STAMP}
  cat > "$file" <<JSON
{"schemaVersion":3,"generatedAt":"$stamp","providers":[
  {"provider":"cursor","state":{"status":"fresh","stale":false},
   "windows":[{"id":"included_usage","percentRemaining":84},
              {"id":"auto_usage","percentRemaining":97},
              {"id":"api_usage","percentRemaining":$api}],
   "quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":$api}]}}
]}
JSON
}

test_a_declared_quota_window_is_priced_instead_of_the_provider_minimum() {
  local home fakebin quota out rc
  home=$(make_home declared-window)
  fakebin=$(make_fakebin declared-window)
  quota="$home/quota.json"
  write_split_pool_quota "$quota" 0

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" undeclared.json \
    '[{"harness":"cursor","model":"cursor-grok-4.6-high"}]' 2>&1) || rc=$?
  expect_code 3 "$rc" "an undeclared candidate must keep the conservative provider-wide minimum"
  assert_contains "$out" "quota headroom 0% is at or below 20% reserve" \
    "the provider-wide refusal must name the figure it priced on"

  out=$(run_select "$home" "$fakebin" "$quota" declared.json \
    '[{"harness":"cursor","model":"cursor-grok-4.6-high","quotaWindow":"auto_usage"}]' 2>"$home/declared.err")
  [ "$(printf '%s\n' "$out" | jq -r .model)" = cursor-grok-4.6-high ] \
    || fail "a candidate declaring a healthy pool was refused on another pool's figure: $out"
  assert_contains "$(cat "$home/declared.err")" "window auto_usage headroom=97%" \
    "the honoured window must be inspectable in the diagnostic"
  [ "$(printf '%s\n' "$out" | jq -r '.quotaWindow // "none"')" = none ] \
    || fail "quotaWindow is a pricing declaration and must not reach the launch profile: $out"

  # The declaration reprices; it never exempts. The reserve still binds.
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" spent-pool.json \
    '[{"harness":"cursor","quotaWindow":"api_usage"}]' 2>&1) || rc=$?
  expect_code 3 "$rc" "a declared window at zero must still be refused"
  assert_contains "$out" "window api_usage headroom 0% is at or below 20% reserve" \
    "the declared-window refusal must name the window it priced on"
  pass "a declared quota window is priced instead of the provider-wide minimum"
}

test_a_declared_window_absent_from_telemetry_fails_closed() {
  local home fakebin quota out rc
  home=$(make_home missing-window)
  fakebin=$(make_fakebin missing-window)
  quota="$home/quota.json"
  write_split_pool_quota "$quota" 0

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" missing.json \
    '[{"harness":"cursor","quotaWindow":"renamed_usage"}]' 2>&1) || rc=$?
  expect_code 3 "$rc" "a declared window the telemetry does not carry must stop the dispatch"
  assert_contains "$out" "declared quota window renamed_usage is absent from provider telemetry" \
    "the missing-window refusal must name the window it could not find"
  assert_not_contains "$out" "eligible" "a missing declared window must never be repriced on another figure"

  # An unusable figure in the declared window is the same refusal, not a
  # fallback to the healthy windows sitting beside it.
  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"cursor","state":{"status":"fresh","stale":false},
   "windows":[{"id":"auto_usage"},{"id":"included_usage","percentRemaining":90}]}
]}
JSON
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" unusable.json \
    '[{"harness":"cursor","quotaWindow":"auto_usage"}]' 2>&1) || rc=$?
  expect_code 3 "$rc" "a declared window with no usable percentage must stop the dispatch"
  assert_contains "$out" "declared quota window auto_usage has no usable live percentage" \
    "the unusable-window refusal was unclear"

  # Everything upstream of pricing still applies to a declared window.
  write_split_pool_quota "$quota" 97 1970-01-01T00:00:00.000Z
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" stale-declared.json \
    '[{"harness":"cursor","quotaWindow":"auto_usage"}]' 2>&1) || rc=$?
  expect_code 3 "$rc" "a declaration must not bypass the staleness gate"
  assert_contains "$out" "stale or undated" "stale telemetry must still refuse a declared window"

  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" malformed.json \
    '[{"harness":"cursor","quotaWindow":""}]' 2>&1) || rc=$?
  expect_code 2 "$rc" "an empty quotaWindow must be a configuration error"
  assert_contains "$out" "quotaWindow must be a non-empty string when present" \
    "the malformed declaration error was unclear"
  pass "a declared window missing from telemetry fails closed instead of repricing"
}

test_known_spendPriority_ranks_above_headroom() {
  local home fakebin quota selected
  home=$(make_home spend-priority)
  fakebin=$(make_fakebin spend-priority)
  quota="$home/quota.json"
  cat > "$quota" <<JSON
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
  selected=$(run_select "$home" "$fakebin" "$quota" spend.json \
    '[{"harness":"claude","model":"sonnet"},{"harness":"codex","model":"gpt"}]' 2>/dev/null | jq -r .harness)
  [ "$selected" = codex ] || fail "known spendPriority did not beat higher headroom: $selected"
  pass "a known spendPriority ranks above raw headroom among eligible candidates"
}

test_tied_or_unknown_spendPriority_still_rotates() {
  local home fakebin quota first second
  home=$(make_home spend-priority-tie)
  fakebin=$(make_fakebin spend-priority-tie)
  quota="$home/quota.json"
  cat > "$quota" <<JSON
{"schemaVersion":5,"generatedAt":"$STAMP","providers":[
  {"provider":"claude","state":{"status":"fresh","stale":false},
   "windows":[{"id":"all","percentRemaining":80}],
   "quotaSemantics":{"status":"known","effectiveAvailability":[
     {"scope":"all_models","status":"known","effectivePercentRemaining":80,
      "selection":{"status":"known","spendPriority":0}}]}},
  {"provider":"codex","state":{"status":"fresh","stale":false},
   "windows":[{"id":"all","percentRemaining":80}],
   "quotaSemantics":{"status":"known","effectiveAvailability":[
     {"scope":"all_models","status":"known","effectivePercentRemaining":80,
      "selection":{"status":"known","spendPriority":0}}]}}
]}
JSON
  first=$(run_select "$home" "$fakebin" "$quota" tie.json \
    '[{"harness":"claude"},{"harness":"codex"}]' 2>/dev/null | jq -r .harness)
  second=$(run_select "$home" "$fakebin" "$quota" tie.json \
    '[{"harness":"claude"},{"harness":"codex"}]' 2>/dev/null | jq -r .harness)
  [ "$first" != "$second" ] || fail "tied spendPriority did not rotate: $first then $second"
  pass "tied known spendPriority still rotates by least-recent use"
}

test_agy_with_declared_quota_windows_prices_separate_pools() {
  local home fakebin quota out rc
  home=$(make_home agy-windows)
  fakebin=$(make_fakebin agy-windows)
  quota="$home/quota.json"
  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"agy","state":{"status":"fresh","stale":false},
   "windows":[
     {"id":"gemini_5h","percentRemaining":100},
     {"id":"gemini_weekly","percentRemaining":93},
     {"id":"claude_gpt_5h","percentRemaining":0},
     {"id":"claude_gpt_weekly","percentRemaining":32}
   ],
   "quotaSemantics":{"effectiveAvailability":[]}}
]}
JSON

  # Undeclared: worst window (claude_gpt_5h at 0%) refuses the dispatch.
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" agy-undeclared.json \
    '[{"harness":"agy","model":"gemini-3.7-flash-high"}]' 2>&1) || rc=$?
  expect_code 3 "$rc" "undeclared agy profile must price on the worst window and fail closed"
  assert_contains "$out" "quota headroom 0% is at or below 20% reserve" \
    "the provider-wide refusal must name the figure it priced on"

  # Declared healthy window (gemini_5h at 100%): succeeds.
  out=$(run_select "$home" "$fakebin" "$quota" agy-gemini.json \
    '[{"harness":"agy","model":"gemini-3.7-flash-high","quotaWindow":"gemini_5h"}]' 2>"$home/gemini.err")
  [ "$(printf '%s\n' "$out" | jq -r .model)" = "gemini-3.7-flash-high" ] \
    || fail "agy candidate with declared healthy gemini_5h window was refused: $out"
  assert_contains "$(cat "$home/gemini.err")" "window gemini_5h headroom=100%" \
    "the honoured gemini window must be inspectable in the diagnostic"
  [ "$(printf '%s\n' "$out" | jq -r '.provider')" = "agy" ] \
    || fail "native agy profile must establish agy provider identity: $out"
  [ "$(printf '%s\n' "$out" | jq -r '.quotaWindow // "none"')" = none ] \
    || fail "quotaWindow must not reach the launch profile: $out"

  # Declared exhausted window (claude_gpt_5h at 0%): refused.
  rc=0
  out=$(run_select "$home" "$fakebin" "$quota" agy-claude.json \
    '[{"harness":"agy","model":"claude-sonnet-4-6","quotaWindow":"claude_gpt_5h"}]' 2>&1) || rc=$?
  expect_code 3 "$rc" "agy candidate with exhausted claude_gpt_5h window must be refused"
  assert_contains "$out" "window claude_gpt_5h headroom 0% is at or below 20% reserve" \
    "exhausted declared window refusal must name the window"
  pass "agy declared quota windows price Gemini and Claude pools separately"
}

test_agy_record_failure_and_cooldown() {
  local home fakebin quota profiles out rc
  home=$(make_home agy-cooldown)
  fakebin=$(make_fakebin agy-cooldown)
  quota="$home/quota.json"
  cat > "$quota" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"agy","state":{"status":"fresh","stale":false},
   "windows":[{"id":"gemini_5h","percentRemaining":100}]},
  {"provider":"codex","state":{"status":"fresh","stale":false},
   "windows":[{"id":"all","percentRemaining":90}]}
]}
JSON

  profiles='[{"harness":"agy","model":"gemini-3.7-flash-high","quotaWindow":"gemini_5h"},{"harness":"codex","model":"gpt"}]'
  printf 'harness=agy\n' > "$home/state/agy-task.meta"
  printf 'failed: 429 Too Many Requests - hit your 5-hour limit\n' > "$home/state/agy-task.status"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$BASE_PATH" "$SELECTOR" record-failure --provider agy --task agy-task --now 1000 \
    >/dev/null 2>&1 || fail "verified 429 status evidence on agy did not create cooldown"

  out=$(run_select "$home" "$fakebin" "$quota" .dispatch-routing.json "$profiles" 1001 2>"$home/select.err")
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = "codex" ] || fail "cooldown did not fail over from agy to codex: $out"
  assert_contains "$(cat "$home/select.err")" "candidate provider=agy unavailable: cooldown until epoch 2800" \
    "cooldown diagnostic on agy omitted its bound"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$BASE_PATH" "$SELECTOR" clear --provider agy \
    >/dev/null 2>&1 || fail "clear --provider agy failed"

  # Rotation is least-recently-used and agy has never been dispatched here, so
  # only a genuinely cleared cooldown can put it back at the front.
  out=$(run_select "$home" "$fakebin" "$quota" .dispatch-routing.json "$profiles" 1002 2>/dev/null)
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = "agy" ] \
    || fail "cleared agy cooldown did not restore candidate eligibility: $out"
  pass "agy verified failure records cooldown and clear restores eligibility"
}

test_depletion_evidence_gate_separates_quota_from_working_limits() {
  local home fakebin quota out rc name status
  home=$(make_home evidence-gate)
  fakebin=$(make_fakebin evidence-gate)
  quota="$home/quota.json"
  write_quota "$quota" fresh 80 fresh 80

  # Authentic subscription depletion must be accepted as cooldown evidence.
  while IFS='^' read -r name status; do
    [ -n "$name" ] || continue
    printf 'harness=codex\n' > "$home/state/$name.meta"
    printf '%s\n' "$status" > "$home/state/$name.status"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      PATH="$fakebin:$BASE_PATH" "$SELECTOR" record-failure --provider codex --task "$name" --now 1000 \
      >/dev/null 2>&1 || fail "quota depletion evidence was rejected: $status"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      PATH="$fakebin:$BASE_PATH" "$SELECTOR" clear --provider codex >/dev/null 2>&1 \
      || fail "clear after $name failed"
  done <<'ROWS'
http-429^failed: request failed with status code 429
insufficient-quota^failed: insufficient_quota - add credits to continue
out-of-credits^failed: you are out of credits for this billing period
weekly-allowance^failed: your weekly usage allowance is exhausted
ROWS

  # A working ceiling is not spent quota: parking the provider on it would push
  # dispatch onto a weaker lane for a whole cooldown with full headroom left.
  while IFS='^' read -r name status; do
    [ -n "$name" ] || continue
    printf 'harness=codex\n' > "$home/state/$name.meta"
    printf '%s\n' "$status" > "$home/state/$name.status"
    rc=0
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      PATH="$fakebin:$BASE_PATH" "$SELECTOR" record-failure --provider codex --task "$name" --now 1000 2>&1) || rc=$?
    expect_code 2 "$rc" "benign working text must not qualify as quota evidence: $status"
    assert_contains "$out" "contains no rate-limit or quota-exhaustion evidence" \
      "benign refusal was unclear for: $status"
  done <<'ROWS'
context-window^working: context token limit reached; compacting
tool-output^failed: exceeded the tool output limit
line-number^working: applying the hunk at line 429 of the diff
max-tokens^working: max output tokens limit hit; continuing
ROWS

  # The refused cases must have left dispatch untouched.
  out=$(run_select "$home" "$fakebin" "$quota" .dispatch-routing.json \
    '[{"harness":"codex"}]' 1001 2>/dev/null)
  [ "$(printf '%s\n' "$out" | jq -r .harness)" = "codex" ] \
    || fail "a benign working line parked a healthy provider: $out"
  pass "depletion evidence accepts quota vocabulary and rejects working ceilings"
}

test_distribution_is_deterministic_balanced_and_array_order_independent
test_stale_unavailable_and_reserve_thresholds_fail_closed
test_a_declared_quota_window_is_priced_instead_of_the_provider_minimum
test_a_declared_window_absent_from_telemetry_fails_closed
test_known_spendPriority_ranks_above_headroom
test_tied_or_unknown_spendPriority_still_rotates
test_verified_failure_creates_cooldown_and_failover
test_invalid_profiles_and_settings_are_actionable
test_existing_wrapper_and_grok_routes_remain_selectable
test_grok_without_a_resolvable_quota_window_is_not_priced
test_new_verified_adapters_with_providers_are_selectable
test_agy_with_declared_quota_windows_prices_separate_pools
test_agy_record_failure_and_cooldown
test_depletion_evidence_gate_separates_quota_from_working_limits
test_depletion_signal_applies_model_fallback

echo "# all fm-dispatch-select tests passed"
