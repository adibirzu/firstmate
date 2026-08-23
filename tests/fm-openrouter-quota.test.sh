#!/usr/bin/env bash
# Behavior tests for the firstmate-side OpenRouter capacity reader.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READER="$ROOT/bin/fm-openrouter-quota.sh"
TMP_ROOT=$(fm_test_tmproot fm-openrouter-quota)
NOW=1000
SECRET='sk-or-test-secret-do-not-print'
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-$(dirname "$JQ_BIN"):/usr/bin:/bin:/usr/sbin:/sbin}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# The fake curl is the observation point for everything the reader hands to
# its HTTP client: argv, the header it receives on stdin, the request body,
# and (when FAKE_SECRET_SCAN_DIR is set) whether the live key is on disk at
# the moment of the request. It never writes the key anywhere.
make_fake_curl() {
  local home=$1 fakebin
  fakebin="$TMP_ROOT/$(basename "$(dirname "$home")")/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET url="" data="" auth=none
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --max-time|-m|-w) shift 2 ;;
    --data-binary)
      case "$2" in
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -H)
      case "$2" in
        @-)
          hdr=$(cat)
          case "$hdr" in
            "Authorization: Bearer ${OPENROUTER_API_KEY_TOKENS:-}") auth=stdin-bearer-ok ;;
            "Authorization: Bearer "*) auth=stdin-bearer-mismatch ;;
            *) auth=stdin-other ;;
          esac
          ;;
        @*) auth=file ;;
        Authorization:*) auth=argv ;;
      esac
      shift 2
      ;;
    -s|-sS|-S) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
model=""
if [ -n "$data" ]; then
  model=$(printf '%s' "$data" | jq -r '.model // empty')
fi
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  printf 'method=%s url=%s model=%s auth=%s t=%s\n' "$method" "$url" "$model" "$auth" "$(date +%s)" >> "$FAKE_CURL_LOG"
fi
if [ -n "${FAKE_SECRET_SCAN_DIR:-}" ] && [ -n "${OPENROUTER_API_KEY_TOKENS:-}" ]; then
  grep -rlF -- "$OPENROUTER_API_KEY_TOKENS" "$FAKE_SECRET_SCAN_DIR" >> "${FAKE_SECRET_HITS:?}" 2>/dev/null || true
fi
if [ -n "${FAKE_HOOK_MODEL:-}" ] && [ "$model" = "$FAKE_HOOK_MODEL" ]; then
  bash -c "$FAKE_HOOK_CMD" >"${FAKE_HOOK_OUT:?}" 2>&1
  printf '%s\n' "$?" > "${FAKE_HOOK_RESULT:?}"
fi
code=200
body='{}'
case "$url" in
  */api/v1/key)
    code=${FAKE_KEY_CODE:-200}
    body=${FAKE_KEY_BODY:-'{"data":{"usage":0,"usage_daily":0,"usage_weekly":0,"usage_monthly":0,"limit":null,"limit_remaining":null,"is_free_tier":true}}'}
    ;;
  */api/v1/models)
    code=${FAKE_MODELS_CODE:-200}
    body=${FAKE_MODELS_BODY:-'{"data":[]}'}
    ;;
  */api/v1/chat/completions)
    case "$model" in
      cohere/north-mini-code:free)
        code=${FAKE_FREE_OK_CODE:-200}
        body=${FAKE_FREE_OK_BODY:-'{"choices":[{"message":{"content":"ok"}}]}'}
        ;;
      meta/llama-3.2-3b-instruct:free)
        code=${FAKE_LLAMA_CODE:-404}
        body=${FAKE_LLAMA_BODY:-'{"error":{"message":"No allowed providers are available for the selected model"}}'}
        ;;
      openai/gpt-oss-20b:free)
        code=403
        body='{"error":{"message":"only available on agent platforms"}}'
        ;;
      google/gemma-4-31b-it:free)
        code=${FAKE_GEMMA_CODE:-429}
        body=${FAKE_GEMMA_BODY:-'{"error":{"message":"Provider returned error"}}'}
        ;;
      example/reentrant-model:free)
        code=200
        body='{"choices":[{"message":{"content":"ok"}}]}'
        ;;
      *)
        code=599
        body='{"error":{"message":"unexpected probe"}}'
        ;;
    esac
    ;;
  *)
    code=599
    body='{"error":{"message":"unexpected url"}}'
    ;;
esac
if [ -n "$ofile" ]; then
  printf '%s' "$body" > "$ofile"
fi
printf '%s' "$code"
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

fixture_models() {
  cat <<'JSON'
{"data":[
  {"id":"meta/llama-3.2-3b-instruct:free","pricing":{"prompt":"0","completion":"0"}},
  {"id":"openai/gpt-oss-20b:free","pricing":{"prompt":"0","completion":"0"}},
  {"id":"google/gemma-4-31b-it:free","pricing":{"prompt":"0","completion":"0"}},
  {"id":"cohere/north-mini-code:free","pricing":{"prompt":"0","completion":"0"}},
  {"id":"openai/gpt-oss-20b","pricing":{"prompt":"0.00000003","completion":"0.00000013"}},
  {"id":"openai/gpt-oss-120b","pricing":{"prompt":"0.000000037","completion":"0.00000017"}},
  {"id":"google/gemma-3-12b-it","pricing":{"prompt":"0.00000005","completion":"0.00000015"}},
  {"id":"openrouter/auto","pricing":{"prompt":"-1","completion":"-1"}}
]}
JSON
}

run_reader() {
  local home=$1 fakebin=$2
  shift 2
  FAKE_MODELS_BODY=${FAKE_MODELS_BODY_OVERRIDE:-$(fixture_models)} \
    OPENROUTER_API_KEY_TOKENS="$SECRET" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_OPENROUTER_STATE_FILE="$home/state/.openrouter-quota.json" \
    FM_OPENROUTER_PROBE_INTERVAL_SECONDS="${FM_TEST_PROBE_INTERVAL:-0}" \
    PATH="$fakebin:$BASE_PATH" \
    "$READER" "$@"
}

assert_no_secret() {
  local text=$1 label=$2
  assert_not_contains "$text" "$SECRET" "$label leaked the API key"
}

probe_lines() {
  grep -F 'chat/completions' "$1" || true
}

test_missing_key_fails_closed() {
  local home fakebin rc=0 out
  home=$(make_home missing-key)
  fakebin=$(make_fake_curl "$home")
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    env -u OPENROUTER_API_KEY_TOKENS -u OPENROUTER_API_KEY \
    "$READER" report --now "$NOW" 2>&1) || rc=$?
  expect_code 2 "$rc" "missing key must fail closed"
  assert_contains "$out" "OPENROUTER_API_KEY_TOKENS is unset" "missing-key refusal did not name the required variable"
  assert_no_secret "$out" "missing-key path"
  pass "missing OpenRouter key fails closed without guessing"
}

test_healthy_free_model_is_eligible_and_paid_prices_parse() {
  local home fakebin out err rc=0
  home=$(make_home healthy)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  out=$(FAKE_CURL_LOG="$home/curl.log" run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "healthy report must succeed"
  assert_no_secret "$out$(cat "$err")" "healthy report"
  printf '%s\n' "$out" | jq -e '.schemaVersion == 1' >/dev/null \
    || fail "report JSON was missing schemaVersion: $out"
  [ "$(printf '%s\n' "$out" | jq -r '.routing.eligibleFree | join(",")')" = 'cohere/north-mini-code:free' ] \
    || fail "healthy free model was not the sole eligible free route: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="cohere/north-mini-code:free") | .eligible==true and .tier=="free" and .promptPerMillion==0' \
    >/dev/null || fail "healthy free model was not eligible at price zero: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-20b") | .eligible==false and .tier=="paid" and .reason=="priced and not in cooldown; reachability unverified" and .promptPerMillion==0.03 and .completionPerMillion==0.13' \
    >/dev/null || fail "paid gpt-oss-20b was not published as priced-but-unverified: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-120b") | .eligible==false and .promptPerMillion==0.037 and .completionPerMillion==0.17' \
    >/dev/null || fail "paid gpt-oss-120b per-million prices did not parse: $out"
  printf '%s\n' "$out" | jq -e '[.models[] | select(.tier=="paid" and .eligible)] | length == 0' >/dev/null \
    || fail "a paid row was published with a verified-eligible claim: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="cohere/north-mini-code:free") | .eligible==true and .reason=="live completion succeeded"' \
    >/dev/null || fail "the probed free model lost its verified eligibility: $out"
  printf '%s\n' "$out" | jq -e 'has("routing") and (.routing | has("eligiblePaidByCost") | not)' >/dev/null \
    || fail "the false-claim eligiblePaidByCost field is still published: $out"
  [ "$(printf '%s\n' "$out" | jq -r '.routing.unverifiedPaidByCost[0]')" = 'openai/gpt-oss-20b' ] \
    || fail "cheapest paid model was not first in unverifiedPaidByCost: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openrouter/auto") | .eligible==false and .promptPerMillion==null' \
    >/dev/null || fail "negative sentinel pricing was treated as a cheap paid route: $out"
  grep -E 'chat/completions model=openai/gpt-oss-20b ' "$home/curl.log" >/dev/null \
    && fail "paid models were probed"
  pass "healthy free model is eligible and paid prices become per-million figures"
}

test_per_million_prices_are_rounded() {
  local home fakebin out err rc=0
  home=$(make_home rounding)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  out=$(run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "rounding report must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-3-12b-it") | .promptPerMillion==0.05 and .completionPerMillion==0.15' \
    >/dev/null || fail "gemma-3-12b-it per-million prices were not exact: $out"
  assert_not_contains "$out" "0.049999" "published JSON carried float noise"
  assert_not_contains "$out" "0.169999" "published JSON carried float noise"
  pass "per-million prices are rounded before they are published"
}

test_allowed_providers_404_is_skipped() {
  local home fakebin out err rc=0
  home=$(make_home skip-404)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  out=$(run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "privacy-gate skip must not fail the report"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="meta/llama-3.2-3b-instruct:free") | .eligible==false' \
    >/dev/null || fail "404 model remained eligible: $out"
  assert_contains "$(cat "$err")" "account privacy gate: no allowed providers" \
    "404 skip omitted its privacy-gate reason"
  printf '%s\n' "$out" | jq -e '.routing.eligibleFree == ["cohere/north-mini-code:free"]' >/dev/null \
    || fail "404 skip changed the eligible free set: $out"
  pass "404 allowed-providers skip is recorded and is not a cooldown"
}

test_platform_restricted_403_is_skipped() {
  local home fakebin out err rc=0
  home=$(make_home skip-403)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  out=$(run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "403 skip must not fail the report"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-20b:free") | .eligible==false and .reason=="platform-restricted"' \
    >/dev/null || fail "403 model was not skipped as platform-restricted: $out"
  assert_contains "$(cat "$err")" "platform-restricted" "403 skip omitted its reason"
  pass "403 platform-restricted skip is recorded and is not a cooldown"
}

test_429_sets_per_model_cooldown_that_expires() {
  local home fakebin out err rc=0
  home=$(make_home cooldown)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"

  out=$(FAKE_CURL_LOG="$home/curl.log" run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "429 report must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-4-31b-it:free") | .eligible==false' \
    >/dev/null || fail "rate-limited model stayed eligible: $out"
  assert_contains "$(cat "$err")" "cooldown until epoch 2800" "429 cooldown omitted its bound"

  : > "$home/curl.log"
  out=$(FAKE_CURL_LOG="$home/curl.log" FAKE_GEMMA_CODE=200 \
    run_reader "$home" "$fakebin" report --now 1001 2>"$err") || rc=$?
  expect_code 0 "$rc" "in-cooldown report must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-4-31b-it:free") | .eligible==false' \
    >/dev/null || fail "cooldown did not keep the model ineligible: $out"
  grep -F 'google/gemma-4-31b-it:free' "$home/curl.log" >/dev/null \
    && fail "cooled-down model was probed again before expiry"

  out=$(FAKE_GEMMA_CODE=200 run_reader "$home" "$fakebin" report --now 2800 2>"$err") || rc=$?
  expect_code 0 "$rc" "expired cooldown report must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-4-31b-it:free") | .eligible==true' \
    >/dev/null || fail "expired cooldown did not restore eligibility: $out"
  pass "429 per-model cooldown is set, skipped on read, and expires"
}

test_record_failure_and_clear() {
  local home fakebin out err rc=0
  home=$(make_home record)
  fakebin=$(make_fake_curl "$home")
  err="$home/record.err"

  FAKE_MODELS_BODY=$(fixture_models) \
    OPENROUTER_API_KEY_TOKENS="$SECRET" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$BASE_PATH" \
    "$READER" record-failure --model 'google/gemma-4-31b-it:free' --now "$NOW" \
    2>"$err" || fail "record-failure did not persist a cooldown"
  assert_contains "$(cat "$err")" "cooldown recorded until epoch 2800" "record-failure omitted its bound"
  assert_no_secret "$(cat "$err")" "record-failure"

  out=$(FAKE_GEMMA_CODE=200 run_reader "$home" "$fakebin" report --now 1001 2>"$err") || rc=$?
  expect_code 0 "$rc" "report after record-failure must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-4-31b-it:free") | .eligible==false' \
    >/dev/null || fail "record-failure did not make the model ineligible: $out"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" clear --model 'google/gemma-4-31b-it:free' 2>"$err" \
    || fail "clear did not drop the cooldown"
  assert_contains "$(cat "$err")" "cleared" "clear omitted its confirmation"

  out=$(FAKE_GEMMA_CODE=200 run_reader "$home" "$fakebin" report --now 1001 2>"$err") || rc=$?
  expect_code 0 "$rc" "report after clear must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-4-31b-it:free") | .eligible==true' \
    >/dev/null || fail "clear did not restore eligibility: $out"
  pass "record-failure and clear own the per-model cooldown"
}

test_key_never_reaches_disk_and_reaches_curl_on_stdin() {
  local home fakebin out err rc=0 hits
  home=$(make_home key-disk)
  fakebin=$(make_fake_curl "$home")
  mkdir -p "$home/tmp"
  err="$home/report.err"
  hits="$TMP_ROOT/key-disk/hits"
  : > "$hits"
  out=$(TMPDIR="$home/tmp" FAKE_CURL_LOG="$home/curl.log" \
    FAKE_SECRET_SCAN_DIR="$home" FAKE_SECRET_HITS="$hits" \
    run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "key-transport report must succeed"
  [ ! -s "$hits" ] || fail "the API key was on disk while a request was in flight: $(cat "$hits")"
  grep -rlF -- "$SECRET" "$home" >/dev/null 2>&1 \
    && fail "the API key was left on disk after the run: $(grep -rlF -- "$SECRET" "$home")"
  [ "$(grep -c 'auth=stdin-bearer-ok' "$home/curl.log")" -ge 3 ] \
    || fail "requests did not carry the bearer header on stdin: $(cat "$home/curl.log")"
  grep -Ev 'auth=stdin-bearer-ok' "$home/curl.log" >/dev/null \
    && fail "a request carried the key some other way: $(cat "$home/curl.log")"
  assert_no_secret "$out$(cat "$err")" "key-transport report"
  pass "the API key reaches curl on stdin and never touches disk"
}

test_record_failure_during_sweep_succeeds_and_is_merged() {
  local home fakebin out err rc=0 hook_rc
  home=$(make_home reentrant)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  out=$(FAKE_HOOK_MODEL='cohere/north-mini-code:free' \
    FAKE_HOOK_CMD="'$READER' record-failure --model example/reentrant-model:free --now $NOW" \
    FAKE_HOOK_OUT="$home/hook.out" FAKE_HOOK_RESULT="$home/hook.rc" \
    run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "report with a mid-sweep record-failure must succeed"
  [ -f "$home/hook.rc" ] || fail "the mid-sweep record-failure never ran"
  hook_rc=$(cat "$home/hook.rc")
  expect_code 0 "$hook_rc" "record-failure during a sweep must not wait on the lock: $(cat "$home/hook.out")"
  assert_contains "$(cat "$home/hook.out")" "cooldown recorded until epoch 2800" "mid-sweep record-failure did not record"

  out=$(FAKE_MODELS_BODY_OVERRIDE="$(fixture_models | jq -c '.data += [{"id":"example/reentrant-model:free","pricing":{"prompt":"0","completion":"0"}}]')" \
    FAKE_GEMMA_CODE=200 run_reader "$home" "$fakebin" report --now 1001 2>"$err") || rc=$?
  expect_code 0 "$rc" "follow-up report must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="example/reentrant-model:free") | .eligible==false and .reason=="cooldown until epoch 2800"' \
    >/dev/null || fail "the concurrent record-failure was overwritten by the sweep merge: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-4-31b-it:free") | .eligible==false and .reason=="cooldown until epoch 2800"' \
    >/dev/null || fail "the sweep's own 429 cooldown was lost: $out"
  pass "a record-failure during a sweep succeeds and is merged, not overwritten"
}

test_busy_lock_is_kept_and_dead_owner_lock_is_reaped() {
  local live_home dead_home live_lock dead_lock dead_pid out rc=0
  live_home=$(make_home lock-live)
  dead_home=$(make_home lock-dead)
  live_lock="$live_home/state/.openrouter-quota.json.lock"
  dead_lock="$dead_home/state/.openrouter-quota.json.lock"
  mkdir -p "$live_lock" "$dead_lock"
  printf '%s\n' "$$" > "$live_lock/owner"
  ( : ) &
  dead_pid=$!
  wait "$dead_pid"
  printf '%s\n' "$dead_pid" > "$dead_lock/owner"

  (
    FM_HOME="$live_home" FM_STATE_OVERRIDE="$live_home/state" PATH="$BASE_PATH" \
      "$READER" record-failure --model 'google/gemma-4-31b-it:free' --now "$NOW" \
      >"$live_home/out" 2>"$live_home/err"
    printf '%s\n' "$?" > "$live_home/rc"
  ) &
  (
    FM_HOME="$dead_home" FM_STATE_OVERRIDE="$dead_home/state" PATH="$BASE_PATH" \
      "$READER" record-failure --model 'google/gemma-4-31b-it:free' --now "$NOW" \
      >"$dead_home/out" 2>"$dead_home/err"
    printf '%s\n' "$?" > "$dead_home/rc"
  ) &
  wait

  expect_code 3 "$(cat "$live_home/rc")" "a lock held by a live process must stay busy"
  assert_contains "$(cat "$live_home/err")" "lock remained busy" "busy-lock failure did not say so"
  [ -d "$live_lock" ] || fail "the busy lock owned by another live process was deleted"
  [ "$(cat "$live_lock/owner")" = "$$" ] || fail "the busy lock's owner was overwritten"

  expect_code 0 "$(cat "$dead_home/rc")" "a lock whose owner is dead must be reaped: $(cat "$dead_home/err")"
  [ ! -d "$dead_lock" ] || fail "the reaped lock was left behind"
  assert_contains "$(cat "$dead_home/err")" "cooldown recorded until epoch 2800" "record-failure after reaping did not record"
  rm -rf "$live_lock"

  out=$(FM_HOME="$dead_home" FM_STATE_OVERRIDE="$dead_home/state" PATH="$BASE_PATH" \
    "$READER" clear --model 'google/gemma-4-31b-it:free' 2>&1) || rc=$?
  expect_code 0 "$rc" "clear after the reaped run must succeed: $out"
  pass "a busy lock is never deleted and a dead owner's lock is reaped"
}

test_permanent_verdicts_are_remembered_and_cleared() {
  local home fakebin out err rc=0
  home=$(make_home remembered)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"

  out=$(FAKE_CURL_LOG="$home/curl.log" run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "first report must succeed"
  [ "$(probe_lines "$home/curl.log" | wc -l | tr -d ' ')" = 4 ] \
    || fail "first sweep did not probe every free model once: $(cat "$home/curl.log")"

  : > "$home/curl.log"
  out=$(FAKE_CURL_LOG="$home/curl.log" FAKE_GEMMA_CODE=200 run_reader "$home" "$fakebin" report --now 2800 2>"$err") || rc=$?
  expect_code 0 "$rc" "second report must succeed"
  grep -F 'model=meta/llama-3.2-3b-instruct:free ' "$home/curl.log" >/dev/null \
    && fail "404 allowed-providers model was probed again: $(cat "$home/curl.log")"
  grep -F 'model=openai/gpt-oss-20b:free ' "$home/curl.log" >/dev/null \
    && fail "403 platform-restricted model was probed again: $(cat "$home/curl.log")"
  grep -F 'model=cohere/north-mini-code:free ' "$home/curl.log" >/dev/null \
    || fail "healthy free model was not probed live on the second run: $(cat "$home/curl.log")"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="meta/llama-3.2-3b-instruct:free") | .eligible==false and .reason=="account privacy gate: no allowed providers"' \
    >/dev/null || fail "remembered 404 verdict was not reported: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-20b:free") | .eligible==false and .reason=="platform-restricted"' \
    >/dev/null || fail "remembered 403 verdict was not reported: $out"
  assert_contains "$(cat "$err")" "remembered verdict" "remembered verdicts were not announced on stderr"
  printf '%s\n' "$out" | jq -e '.routing.eligibleFree | sort == ["cohere/north-mini-code:free","google/gemma-4-31b-it:free"]' >/dev/null \
    || fail "remembered verdicts changed the eligible free set: $out"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" clear --model 'meta/llama-3.2-3b-instruct:free' 2>"$err" \
    || fail "clear did not drop the remembered verdict"
  : > "$home/curl.log"
  out=$(FAKE_CURL_LOG="$home/curl.log" FAKE_LLAMA_CODE=200 FAKE_LLAMA_BODY='{"choices":[{"message":{"content":"ok"}}]}' \
    FAKE_GEMMA_CODE=200 run_reader "$home" "$fakebin" report --now 2801 2>"$err") || rc=$?
  expect_code 0 "$rc" "report after clear must succeed"
  grep -F 'model=meta/llama-3.2-3b-instruct:free ' "$home/curl.log" >/dev/null \
    || fail "cleared model was not probed live again: $(cat "$home/curl.log")"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="meta/llama-3.2-3b-instruct:free") | .eligible==true' \
    >/dev/null || fail "a widened privacy setting was not picked up after clear: $out"
  pass "404 and 403 verdicts are remembered across runs and clear re-probes them"
}

test_clear_all_verdicts_reprobes_and_keeps_cooldowns() {
  local home fakebin out err rc=0
  home=$(make_home clear-all)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  out=$(run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "seed report must succeed"

  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" clear 2>&1) || rc=$?
  expect_code 2 "$rc" "clear without a target must be a usage error"
  assert_contains "$out" "--all-verdicts" "clear usage error did not name the bulk flag"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" clear --all-verdicts --model 'meta/llama-3.2-3b-instruct:free' 2>&1) || rc=$?
  expect_code 2 "$rc" "clear with both targets must be a usage error"

  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" clear --all-verdicts 2>&1) || rc=$?
  expect_code 0 "$rc" "clear --all-verdicts must succeed: $out"
  assert_contains "$out" "remembered verdicts cleared: 2" "bulk clear did not report the dropped verdicts"
  assert_contains "$out" "cooldowns kept" "bulk clear did not say cooldowns are kept"

  rc=0
  out=$(FAKE_CURL_LOG="$home/curl.log" FAKE_GEMMA_CODE=200 \
    FAKE_LLAMA_CODE=200 FAKE_LLAMA_BODY='{"choices":[{"message":{"content":"ok"}}]}' \
    run_reader "$home" "$fakebin" report --now 1001 2>"$err") || rc=$?
  expect_code 0 "$rc" "report after bulk clear must succeed"
  grep -F 'model=meta/llama-3.2-3b-instruct:free ' "$home/curl.log" >/dev/null \
    || fail "404 model was not re-probed after clear --all-verdicts: $(cat "$home/curl.log")"
  grep -F 'model=openai/gpt-oss-20b:free ' "$home/curl.log" >/dev/null \
    || fail "403 model was not re-probed after clear --all-verdicts: $(cat "$home/curl.log")"
  grep -F 'model=google/gemma-4-31b-it:free ' "$home/curl.log" >/dev/null \
    && fail "a live cooldown was wiped by clear --all-verdicts: $(cat "$home/curl.log")"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-4-31b-it:free") | .eligible==false and .reason=="cooldown until epoch 2800"' \
    >/dev/null || fail "the 429 cooldown did not survive clear --all-verdicts: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="meta/llama-3.2-3b-instruct:free") | .eligible==true' \
    >/dev/null || fail "a widened privacy setting was not picked up after clear --all-verdicts: $out"
  pass "clear --all-verdicts re-probes remembered models and keeps live cooldowns"
}

test_paid_record_failure_verdict_is_permanent_and_rate_limit_is_short() {
  local home fakebin out err rc=0
  home=$(make_home paid-verdict)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"

  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" record-failure --model 'openai/gpt-oss-20b' --observed 500 --now "$NOW" 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown --observed value must be refused"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" clear --model 'openai/gpt-oss-20b' --observed 404 2>&1) || rc=$?
  expect_code 2 "$rc" "--observed outside record-failure must be refused"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" record-failure --model 'openai/gpt-oss-20b' --now "$NOW" 2>"$err" \
    || fail "rate-limit record-failure on a paid id failed: $(cat "$err")"
  assert_contains "$(cat "$err")" "cooldown recorded until epoch 2800" "paid rate-limit did not record a cooldown"
  printf '%s' '{"error":{"message":"No allowed providers are available for the selected model"}}' > "$home/gate-body.json"
  printf '%s' '{"error":{"message":"No endpoints found for example/retired-model"}}' > "$home/plain-body.json"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" record-failure --model 'openai/gpt-oss-120b' --observed 404 --body "$home/gate-body.json" --now "$NOW" 2>"$err" \
    || fail "404 record-failure on a paid id failed: $(cat "$err")"
  assert_contains "$(cat "$err")" "permanent verdict recorded: account privacy gate: no allowed providers" "paid gate 404 was not recorded as a permanent verdict"
  assert_not_contains "$(cat "$err")" "cooldown" "paid gate 404 was recorded as a cooldown"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" record-failure --model 'google/gemma-3-12b-it' --observed 404 --body "$home/plain-body.json" --now "$NOW" 2>"$err" \
    || fail "plain 404 record-failure failed: $(cat "$err")"
  assert_contains "$(cat "$err")" "transient http-404 recorded as cooldown until epoch 2800" "plain 404 was not recorded as a transient cooldown"
  assert_not_contains "$(cat "$err")" "permanent verdict" "plain 404 was recorded as a permanent verdict"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" record-failure --model '~example/alias-latest' --observed 404 --now "$NOW" 2>"$err" \
    || fail "bodyless 404 record-failure failed: $(cat "$err")"
  assert_contains "$(cat "$err")" "transient http-404 recorded as cooldown" "bodyless 404 was not treated as transient"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" record-failure --model 'openai/gpt-oss-120b' --observed 404 --body "$home/missing.json" --now "$NOW" 2>&1) || rc=$?
  expect_code 2 "$rc" "an unreadable --body file must be refused"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" clear --model 'openai/gpt-oss-120b' --body "$home/gate-body.json" 2>&1) || rc=$?
  expect_code 2 "$rc" "--body outside record-failure must be refused"

  rc=0
  out=$(run_reader "$home" "$fakebin" report --now 1001 2>"$err") || rc=$?
  expect_code 0 "$rc" "report after paid record-failure must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-20b") | .eligible==false and .reason=="cooldown until epoch 2800"' \
    >/dev/null || fail "paid rate-limit cooldown was not applied: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-120b") | .eligible==false and .reason=="account privacy gate: no allowed providers"' \
    >/dev/null || fail "paid permanent verdict was not applied: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-3-12b-it") | .eligible==false and .reason=="cooldown until epoch 2800"' \
    >/dev/null || fail "plain 404 did not become a short cooldown: $out"
  printf '%s\n' "$out" | jq -e '.routing.unverifiedPaidByCost | index("openai/gpt-oss-20b") == null and index("openai/gpt-oss-120b") == null and index("google/gemma-3-12b-it") == null' >/dev/null \
    || fail "rejected paid ids were still offered in unverifiedPaidByCost: $out"

  rc=0
  out=$(run_reader "$home" "$fakebin" report --now 9000 2>"$err") || rc=$?
  expect_code 0 "$rc" "later report must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-20b") | .reason=="priced and not in cooldown; reachability unverified"' \
    >/dev/null || fail "paid rate-limit cooldown did not expire: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-120b") | .reason=="account privacy gate: no allowed providers"' \
    >/dev/null || fail "paid permanent verdict expired like a cooldown: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-3-12b-it") | .reason=="priced and not in cooldown; reachability unverified"' \
    >/dev/null || fail "plain 404 cooldown did not expire, it persisted like a permanent verdict: $out"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" record-failure --model 'openai/gpt-oss-20b' --now 9000 2>"$err" \
    || fail "second rate-limit record-failure failed: $(cat "$err")"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" clear --all-verdicts 2>"$err" || fail "clear --all-verdicts failed: $(cat "$err")"
  rc=0
  out=$(run_reader "$home" "$fakebin" report --now 9001 2>"$err") || rc=$?
  expect_code 0 "$rc" "report after bulk clear must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-120b") | .reason=="priced and not in cooldown; reachability unverified"' \
    >/dev/null || fail "clear --all-verdicts did not release the paid permanent verdict: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-20b") | .reason=="cooldown until epoch 10800"' \
    >/dev/null || fail "clear --all-verdicts wiped a live paid cooldown: $out"
  pass "paid record-failure: gate 404 is permanent, plain 404 and 429 are short cooldowns, bulk clear keeps cooldowns"
}

test_ownerless_lock_is_reaped_only_when_stale() {
  local stale_home fresh_home stale_lock fresh_lock rc=0
  stale_home=$(make_home lock-stale)
  fresh_home=$(make_home lock-fresh)
  stale_lock="$stale_home/state/.openrouter-quota.json.lock"
  fresh_lock="$fresh_home/state/.openrouter-quota.json.lock"
  mkdir -p "$stale_lock" "$fresh_lock"
  touch -t 200001010000 "$stale_lock"
  (
    FM_HOME="$stale_home" FM_STATE_OVERRIDE="$stale_home/state" PATH="$BASE_PATH" \
      "$READER" record-failure --model 'google/gemma-4-31b-it:free' --now "$NOW" \
      >"$stale_home/out" 2>"$stale_home/err"
    printf '%s\n' "$?" > "$stale_home/rc"
  ) &
  (
    FM_HOME="$fresh_home" FM_STATE_OVERRIDE="$fresh_home/state" PATH="$BASE_PATH" \
      "$READER" record-failure --model 'google/gemma-4-31b-it:free' --now "$NOW" \
      >"$fresh_home/out" 2>"$fresh_home/err"
    printf '%s\n' "$?" > "$fresh_home/rc"
  ) &
  wait
  expect_code 0 "$(cat "$stale_home/rc")" "an ownerless lock older than 60 seconds must be reaped: $(cat "$stale_home/err")"
  assert_contains "$(cat "$stale_home/err")" "reaped a stale OpenRouter quota state lock" "stale reap was not logged"
  assert_contains "$(cat "$stale_home/err")" "cooldown recorded until epoch 2800" "record-failure after the stale reap did not record"
  [ ! -d "$stale_lock" ] || fail "the stale lock was left behind"
  expect_code 3 "$(cat "$fresh_home/rc")" "a fresh ownerless lock must stay busy"
  [ -d "$fresh_lock" ] || fail "a fresh ownerless lock was deleted"
  rm -rf "$fresh_lock"
  pass "an ownerless lock is reaped only once it is older than 60 seconds"
}

test_flags_are_refused_outside_their_command() {
  local home fakebin out rc=0
  home=$(make_home flag-guard)
  fakebin=$(make_fake_curl "$home")
  out=$(FAKE_CURL_LOG="$home/curl.log" run_reader "$home" "$fakebin" --all-verdicts --now "$NOW" 2>&1) || rc=$?
  expect_code 2 "$rc" "--all-verdicts without clear must be refused"
  assert_contains "$out" "clear --all-verdicts" "refusal did not name the valid command"
  [ ! -s "$home/curl.log" ] || fail "a refused --all-verdicts still ran a sweep: $(cat "$home/curl.log")"
  rc=0
  out=$(FAKE_CURL_LOG="$home/curl.log" run_reader "$home" "$fakebin" report --model 'cohere/north-mini-code:free' --now "$NOW" 2>&1) || rc=$?
  expect_code 2 "$rc" "--model with report must be refused"
  assert_contains "$out" "record-failure or clear" "report --model refusal did not name the valid commands"
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$BASE_PATH" \
    "$READER" record-failure --model 'cohere/north-mini-code:free' --all-verdicts --now "$NOW" 2>&1) || rc=$?
  expect_code 2 "$rc" "record-failure --all-verdicts must be refused"
  pass "--all-verdicts and --model are refused outside the commands that use them"
}

test_probe_budget_keeps_partial_report() {
  local home fakebin out err rc=0
  home=$(make_home budget)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  out=$(FAKE_CURL_LOG="$home/curl.log" FM_OPENROUTER_PROBE_MAX=2 \
    run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "report over the probe budget must still be emitted"
  [ "$(probe_lines "$home/curl.log" | wc -l | tr -d ' ')" = 2 ] \
    || fail "probe budget was not honoured: $(cat "$home/curl.log")"
  printf '%s\n' "$out" | jq -e \
    '[.models[] | select(.reason=="probe-budget-exhausted") | .id] | sort == ["cohere/north-mini-code:free","google/gemma-4-31b-it:free"]' \
    >/dev/null || fail "unprobed free models were not reported as probe-budget-exhausted: $out"
  printf '%s\n' "$out" | jq -e '.routing.eligibleFree == []' >/dev/null \
    || fail "an unprobed model was guessed eligible: $out"
  printf '%s\n' "$out" | jq -e '.routing.unverifiedPaidByCost[0]=="openai/gpt-oss-20b"' >/dev/null \
    || fail "paid fallback was dropped from the partial report: $out"
  assert_contains "$(cat "$err")" "probe-budget-exhausted" "truncation was not logged"

  : > "$home/curl.log"
  out=$(FAKE_CURL_LOG="$home/curl.log" FM_OPENROUTER_PROBE_MAX=2 \
    run_reader "$home" "$fakebin" report --now 1001 2>"$err") || rc=$?
  expect_code 0 "$rc" "second budgeted report must succeed"
  printf '%s\n' "$out" | jq -e '.routing.eligibleFree == ["cohere/north-mini-code:free"]' >/dev/null \
    || fail "remembered verdicts did not free the budget for the unprobed models: $out"
  pass "hitting the probe budget keeps the partial report and names the unprobed models"
}

test_probes_are_paced() {
  local home fakebin err rc=0 first last
  home=$(make_home paced)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  FAKE_CURL_LOG="$home/curl.log" FM_TEST_PROBE_INTERVAL=1 \
    FAKE_MODELS_BODY_OVERRIDE='{"data":[{"id":"meta/llama-3.2-3b-instruct:free","pricing":{"prompt":"0","completion":"0"}},{"id":"openai/gpt-oss-20b:free","pricing":{"prompt":"0","completion":"0"}},{"id":"cohere/north-mini-code:free","pricing":{"prompt":"0","completion":"0"}}]}' \
    run_reader "$home" "$fakebin" report --now "$NOW" >/dev/null 2>"$err" || rc=$?
  expect_code 0 "$rc" "paced report must succeed"
  [ "$(probe_lines "$home/curl.log" | wc -l | tr -d ' ')" = 3 ] \
    || fail "paced sweep did not probe three models: $(cat "$home/curl.log")"
  first=$(probe_lines "$home/curl.log" | head -n1 | sed 's/.*t=//')
  last=$(probe_lines "$home/curl.log" | tail -n1 | sed 's/.*t=//')
  [ $((last - first)) -ge 2 ] || fail "probes were not spaced by the interval: $(cat "$home/curl.log")"
  pass "live probes are paced by the configured interval"
}

test_tilde_alias_is_priced_by_tier_and_sorted_cheapest_first() {
  local home fakebin out err rc=0
  home=$(make_home tilde-alias)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  out=$(FAKE_CURL_LOG="$home/curl.log" \
    FAKE_MODELS_BODY_OVERRIDE="$(fixture_models | jq -c '.data += [{"id":"~example/alias-latest","pricing":{"prompt":"0.00000001","completion":"0.00000002"}},{"id":"~example/free-alias-latest","pricing":{"prompt":"0","completion":"0"}}]')" \
    run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "report with tilde aliases must succeed"
  assert_not_contains "$(cat "$err")" "~example/alias-latest skipped" "tilde alias was still skipped"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="~example/alias-latest") | .tier=="paid" and .free==false and .eligible==false and .promptPerMillion==0.01 and .completionPerMillion==0.02 and .reason=="priced and not in cooldown; reachability unverified"' \
    >/dev/null || fail "tilde paid alias was not priced as an ordinary paid row: $out"
  [ "$(printf '%s\n' "$out" | jq -r '.routing.unverifiedPaidByCost[0]')" = '~example/alias-latest' ] \
    || fail "cheapest eligible paid id was not first, a floor or threshold is interfering: $out"
  grep -F 'model=~example/alias-latest ' "$home/curl.log" >/dev/null \
    && fail "a paid tilde alias was probed: $(cat "$home/curl.log")"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="~example/free-alias-latest") | .tier=="free" and .free==true' \
    >/dev/null || fail "price-zero tilde alias was not classed free by price: $out"
  grep -F 'model=~example/free-alias-latest ' "$home/curl.log" >/dev/null \
    || fail "price-zero tilde alias was not probed live: $(cat "$home/curl.log")"
  pass "tilde aliases are ordinary rows: tier from price, paid sorted cheapest-first, free probed"
}

test_unsupported_model_id_is_logged_not_silent() {
  local home fakebin out err rc=0
  home=$(make_home bad-id)
  fakebin=$(make_fake_curl "$home")
  err="$home/report.err"
  out=$(FAKE_MODELS_BODY_OVERRIDE="$(fixture_models | jq -c '.data += [{"id":"bad id@x","pricing":{"prompt":"0","completion":"0"}}]')" \
    run_reader "$home" "$fakebin" report --now "$NOW" 2>"$err") || rc=$?
  expect_code 0 "$rc" "report with an unsupported id must succeed"
  assert_contains "$(cat "$err")" "model=bad id@x skipped: unsupported id shape" "unsupported id was dropped silently"
  printf '%s\n' "$out" | jq -e '[.models[] | select(.id=="bad id@x")] | length == 0' >/dev/null \
    || fail "unsupported id leaked into the model list: $out"
  pass "an unsupported catalog id is logged instead of vanishing"
}

test_rejected_key_is_reported_once() {
  local home fakebin out rc=0
  home=$(make_home rejected)
  fakebin=$(make_fake_curl "$home")
  out=$(FAKE_KEY_CODE=401 run_reader "$home" "$fakebin" report --now "$NOW" 2>&1) || rc=$?
  expect_code 3 "$rc" "a rejected key must fail with exit 3"
  [ "$(printf '%s\n' "$out" | grep -c 'OpenRouter rejected the API key')" = 1 ] \
    || fail "rejected-key diagnostic was not printed exactly once: $out"
  assert_no_secret "$out" "rejected-key path"
  pass "a rejected key is reported once without key material"
}

test_missing_key_fails_closed
test_healthy_free_model_is_eligible_and_paid_prices_parse
test_per_million_prices_are_rounded
test_allowed_providers_404_is_skipped
test_platform_restricted_403_is_skipped
test_429_sets_per_model_cooldown_that_expires
test_record_failure_and_clear
test_key_never_reaches_disk_and_reaches_curl_on_stdin
test_record_failure_during_sweep_succeeds_and_is_merged
test_busy_lock_is_kept_and_dead_owner_lock_is_reaped
test_permanent_verdicts_are_remembered_and_cleared
test_clear_all_verdicts_reprobes_and_keeps_cooldowns
test_paid_record_failure_verdict_is_permanent_and_rate_limit_is_short
test_ownerless_lock_is_reaped_only_when_stale
test_flags_are_refused_outside_their_command
test_probe_budget_keeps_partial_report
test_probes_are_paced
test_tilde_alias_is_priced_by_tier_and_sorted_cheapest_first
test_unsupported_model_id_is_logged_not_silent
test_rejected_key_is_reported_once

echo "# all fm-openrouter-quota tests passed"
