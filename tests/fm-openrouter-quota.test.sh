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

make_fake_curl() {
  local home=$1 fakebin
  fakebin="$TMP_ROOT/$(basename "$(dirname "$home")")/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET url="" data=""
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
        @*) shift 2 ;;
        *) shift 2 ;;
      esac
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
  printf 'method=%s url=%s model=%s\n' "$method" "$url" "$model" >> "$FAKE_CURL_LOG"
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
        code=404
        body='{"error":{"message":"No allowed providers are available for the selected model"}}'
        ;;
      openai/gpt-oss-20b:free)
        code=403
        body='{"error":{"message":"only available on agent platforms"}}'
        ;;
      google/gemma-4-31b-it:free)
        code=${FAKE_GEMMA_CODE:-429}
        body=${FAKE_GEMMA_BODY:-'{"error":{"message":"Provider returned error"}}'}
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
  {"id":"openrouter/auto","pricing":{"prompt":"-1","completion":"-1"}}
]}
JSON
}

run_reader() {
  local home=$1 fakebin=$2
  shift 2
  FAKE_MODELS_BODY=$(fixture_models) \
    OPENROUTER_API_KEY_TOKENS="$SECRET" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_OPENROUTER_STATE_FILE="$home/state/.openrouter-quota.json" \
    PATH="$fakebin:$BASE_PATH" \
    "$READER" "$@"
}

assert_no_secret() {
  local text=$1 label=$2
  assert_not_contains "$text" "$SECRET" "$label leaked the API key"
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
    '.models[] | select(.id=="openai/gpt-oss-20b") | .eligible==true and .tier=="paid" and ((.promptPerMillion*1000|round)==30) and ((.completionPerMillion*1000|round)==130)' \
    >/dev/null || fail "paid gpt-oss-20b per-million prices did not parse: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openai/gpt-oss-120b") | .eligible==true and ((.promptPerMillion*1000|round)==37) and ((.completionPerMillion*1000|round)==170)' \
    >/dev/null || fail "paid gpt-oss-120b per-million prices did not parse: $out"
  [ "$(printf '%s\n' "$out" | jq -r '.routing.eligiblePaidByCost[0]')" = 'openai/gpt-oss-20b' ] \
    || fail "cheapest paid model was not first in eligiblePaidByCost: $out"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="openrouter/auto") | .eligible==false and .promptPerMillion==null' \
    >/dev/null || fail "negative sentinel pricing was treated as a cheap paid route: $out"
  grep -E 'chat/completions model=openai/gpt-oss-20b$' "$home/curl.log" >/dev/null \
    && fail "paid models were probed"
  pass "healthy free model is eligible and paid prices become per-million figures"
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
  assert_contains "$(cat "$err")" "cooldown cleared" "clear omitted its confirmation"

  out=$(FAKE_GEMMA_CODE=200 run_reader "$home" "$fakebin" report --now 1001 2>"$err") || rc=$?
  expect_code 0 "$rc" "report after clear must succeed"
  printf '%s\n' "$out" | jq -e \
    '.models[] | select(.id=="google/gemma-4-31b-it:free") | .eligible==true' \
    >/dev/null || fail "clear did not restore eligibility: $out"
  pass "record-failure and clear own the per-model cooldown"
}

test_missing_key_fails_closed
test_healthy_free_model_is_eligible_and_paid_prices_parse
test_allowed_providers_404_is_skipped
test_platform_restricted_403_is_skipped
test_429_sets_per_model_cooldown_that_expires
test_record_failure_and_clear

echo "# all fm-openrouter-quota tests passed"
