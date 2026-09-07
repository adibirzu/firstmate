#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-usage-lib.sh: the fleet-wide usage row
# (harness, model, context_pct, quota) surfaced by fm-fleet-snapshot.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-crew-usage-lib)
ACCOUNTS_FILE=

# Source with a fakebin quota-axi ahead of PATH so no test ever calls the real
# thing, matching the pattern every other lib test in this suite uses.
make_fakebin() {  # <dir> <quota-axi-script-body-or-absent>
  local fb
  fb=$(fm_fakebin "$1")
  if [ -n "${2:-}" ]; then
    printf '%s' "$2" > "$fb/quota-axi"
    chmod +x "$fb/quota-axi"
  fi
  printf '%s\n' "$fb"
}

with_libs() {  # <fakebin-dir> <extra-env...> -- <shell-code>
  PATH="$1:$PATH" FM_ACCOUNTS_FILE="$ACCOUNTS_FILE" bash -s <<EOF
set -eu
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-accounts-lib.sh disable=SC1091
. "$ROOT/bin/fm-accounts-lib.sh"
# shellcheck source=bin/fm-crew-usage-lib.sh disable=SC1091
. "$ROOT/bin/fm-crew-usage-lib.sh"
${2:-}
EOF
}

make_account() {  # <name> <harness>
  local name=$1 harness=$2 dir
  dir="$TMP_ROOT/account-$name"
  mkdir -p "$dir/config"
  ACCOUNTS_FILE="$dir/accounts.json"
  jq -n --arg name "$name" --arg harness "$harness" --arg config "$dir/config" \
    '{($name):{harness:$harness,isolation:"config-dir-env",env:(if $harness == "codex" then "CODEX_HOME" else "CLAUDE_CONFIG_DIR" end),config_dir:$config}}' \
    > "$ACCOUNTS_FILE"
}

test_context_pct_reads_supported_statusline() {
  local fb statusline out
  fb=$(make_fakebin "$TMP_ROOT/context" '')
  statusline="$TMP_ROOT/statusline"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "status=ok source=codex context_pct=40\\n"' > "$statusline"
  chmod +x "$statusline"
  out=$(with_libs "$fb" "FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
  [ "$out" = "40" ] || fail "context_pct for codex: expected 40, got '$out'"
  out=$(with_libs "$fb" "FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct claude task-1")
  [ "$out" = "40" ] || fail "context_pct for claude: expected 40, got '$out'"
  out=$(with_libs "$fb" "FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct pi task-1")
  [ "$out" = "n/a" ] || fail "context_pct for unsupported harness: expected n/a, got '$out'"
  pass "context percentage reads supported statusline output"
}

test_context_pct_rejects_out_of_range() {
  local fb statusline out
  fb=$(make_fakebin "$TMP_ROOT/context-range" '')
  statusline="$TMP_ROOT/statusline-range"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "status=ok source=codex context_pct=999\\n"' > "$statusline"
  chmod +x "$statusline"
  out=$(with_libs "$fb" "FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
  [ "$out" = "n/a" ] || fail "out-of-range context_pct: expected n/a, got '$out'"
  pass "context percentage rejects values outside 0 through 100"
}

test_context_pct_times_out() {
  local fb statusline out
  fb=$(make_fakebin "$TMP_ROOT/context-timeout" '')
  statusline="$TMP_ROOT/statusline-timeout"
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 2' 'printf "status=ok source=codex context_pct=40\\n"' > "$statusline"
  chmod +x "$statusline"
  out=$(FM_CREW_USAGE_CONTEXT_TIMEOUT=1 with_libs "$fb" "FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
  [ "$out" = "n/a" ] || fail "timed-out context_pct: expected n/a, got '$out'"
  pass "context percentage returns n/a after diagnostic timeout"
}

test_quota_disabled_by_default() {
  local fb out
  fb=$(make_fakebin "$TMP_ROOT/disabled" '#!/usr/bin/env bash
echo "quota-axi should never be invoked when the gate is off" >&2
exit 1
')
  out=$(with_libs "$fb" 'fm_crew_usage_quota_spend_priority claude; echo "rc=$?"')
  [ "$out" = "rc=0" ] || fail "quota lookup should no-op with rc=0 when disabled, got: $out"
  pass "quota lookup is a no-op by default (FM_CREW_USAGE_ENABLE_QUOTA unset)"
}

test_quota_unmapped_harness_returns_empty() {
  local fb out
  fb=$(make_fakebin "$TMP_ROOT/unmapped" '#!/usr/bin/env bash
echo "quota-axi should never be invoked for an unmapped harness" >&2
exit 1
')
  # shellcheck disable=SC2016 # Inner shell expands command output variables.
  out=$(with_libs "$fb" 'export FM_CREW_USAGE_ENABLE_QUOTA=1
v=$(fm_crew_usage_quota_spend_priority pi)
printf "[%s]\n" "$v"')
  [ "$out" = "[]" ] || fail "unmapped harness (pi) should return empty, got: $out"
  pass "quota lookup returns empty for a harness quota-axi does not cover"
}

test_quota_enabled_reads_spend_priority() {
  local fb out
  make_account claude-account claude
  fb=$(make_fakebin "$TMP_ROOT/enabled" '#!/usr/bin/env bash
cat <<JSON
{"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"selection":{"status":"known","spendPriority":-4.75}}]}}]}
JSON
')
  out=$(with_libs "$fb" 'export FM_CREW_USAGE_ENABLE_QUOTA=1
fm_crew_usage_quota_spend_priority claude claude-account')
  [ "$out" = "-4.75" ] || fail "expected spendPriority -4.75, got '$out'"
  pass "quota lookup reads spendPriority from quota-axi's per-provider selection when enabled"
}

test_quota_caches_across_calls_in_one_process() {
  local fb calls out
  make_account codex-account codex
  fb=$(make_fakebin "$TMP_ROOT/cache" '')
  cat > "$fb/quota-axi" <<EOF
#!/usr/bin/env bash
count_file="$TMP_ROOT/cache/.calls"
n=\$(cat "\$count_file" 2>/dev/null || echo 0)
echo \$((n + 1)) > "\$count_file"
cat <<JSON
{"providers":[{"provider":"codex","quotaSemantics":{"effectiveAvailability":[{"selection":{"status":"known","spendPriority":1.5}}]}}]}
JSON
EOF
  chmod +x "$fb/quota-axi"
  # shellcheck disable=SC2016 # Inner shell expands command output variables.
  out=$(with_libs "$fb" 'export FM_CREW_USAGE_ENABLE_QUOTA=1
fm_crew_usage_prepare_quota codex codex-account
first=$(fm_crew_usage_json codex gpt task-1 codex-account)
second=$(fm_crew_usage_json codex gpt task-2 codex-account)
printf "%s\\n%s\\n" "$first" "$second" | jq -s -e "all(.[]; .quota == \"1.5\")" >/dev/null
printf 1.5')
  [ "$out" = "1.5" ] || fail "expected cached spendPriority 1.5, got '$out'"
  calls=$(cat "$TMP_ROOT/cache/.calls" 2>/dev/null || echo "?")
  [ "$calls" = "1" ] || fail "expected quota-axi invoked exactly once (cached), got $calls calls"
  pass "quota-axi is fetched at most once per process even across several usage rows"
}

test_usage_json_row_shape() {
  local fb out
  make_account codex-account codex
  fb=$(make_fakebin "$TMP_ROOT/row" '#!/usr/bin/env bash
cat <<JSON
{"providers":[{"provider":"codex","quotaSemantics":{"effectiveAvailability":[{"selection":{"status":"known","spendPriority":0.2}}]}}]}
JSON
')
  out=$(with_libs "$fb" 'export FM_CREW_USAGE_ENABLE_QUOTA=1
fm_crew_usage_json codex "gpt-5.5" task-1 codex-account')
  printf '%s' "$out" | jq -e '
    .harness == "codex" and .model == "gpt-5.5"
      and .context_pct == "n/a" and .quota == "0.2"
  ' >/dev/null || fail "usage row shape mismatch: $out"
  pass "usage row carries harness, model, context_pct, and quota as documented"
}

test_quota_requires_worker_account() {
  local fb out
  fb=$(make_fakebin "$TMP_ROOT/no-account" '#!/usr/bin/env bash
echo "quota-axi must not run without a worker account" >&2
exit 1
')
  out=$(with_libs "$fb" 'export FM_CREW_USAGE_ENABLE_QUOTA=1
fm_crew_usage_json codex gpt task-1 ""')
  printf '%s' "$out" | jq -e '.quota == "n/a"' >/dev/null || fail "missing worker account must report n/a: $out"
  pass "quota is unavailable without a worker account identity"
}

test_quota_timeout_must_be_positive() {
  local fb out rc
  fb=$(make_fakebin "$TMP_ROOT/timeout" '')
  set +e
  out=$(FM_CREW_USAGE_QUOTA_TIMEOUT=0 with_libs "$fb" '')
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "zero quota timeout should fail with 2, got $rc: $out"
  pass "quota timeout rejects a non-positive bound"
}

test_usage_json_row_defaults_quota_to_na() {
  local fb out
  fb=$(make_fakebin "$TMP_ROOT/nodef" '')
  out=$(with_libs "$fb" 'fm_crew_usage_json cline ""')
  printf '%s' "$out" | jq -e '
    .harness == "cline" and .model == "" and .context_pct == "n/a" and .quota == "n/a"
  ' >/dev/null || fail "usage row should default quota to n/a when disabled/unmapped: $out"
  pass "usage row defaults quota to n/a when the quota gate is off or the harness is unmapped"
}

test_context_pct_reads_supported_statusline
test_context_pct_rejects_out_of_range
test_context_pct_times_out
test_quota_disabled_by_default
test_quota_unmapped_harness_returns_empty
test_quota_enabled_reads_spend_priority
test_quota_caches_across_calls_in_one_process
test_usage_json_row_shape
test_usage_json_row_defaults_quota_to_na
test_quota_requires_worker_account
test_quota_timeout_must_be_positive
