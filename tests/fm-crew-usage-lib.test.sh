#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-usage-lib.sh: the fleet-wide usage row
# (harness, model, context_pct, quota) surfaced by fm-fleet-snapshot.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-crew-usage-lib)

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
  PATH="$1:$PATH" bash -s <<EOF
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

test_context_pct_is_always_na() {
  local out
  out=$(with_libs "$TMP_ROOT/nofb1" 'fm_crew_usage_context_pct claude')
  [ "$out" = "n/a" ] || fail "context_pct for claude: expected n/a, got '$out'"
  out=$(with_libs "$TMP_ROOT/nofb2" 'fm_crew_usage_context_pct pi')
  [ "$out" = "n/a" ] || fail "context_pct for pi: expected n/a, got '$out'"
  pass "context percentage is always n/a (no harness exposes it externally)"
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
  out=$(with_libs "$fb" 'export FM_CREW_USAGE_ENABLE_QUOTA=1
v=$(fm_crew_usage_quota_spend_priority pi)
printf "[%s]\n" "$v"')
  [ "$out" = "[]" ] || fail "unmapped harness (pi) should return empty, got: $out"
  pass "quota lookup returns empty for a harness quota-axi does not cover"
}

test_quota_enabled_reads_spend_priority() {
  local fb out
  fb=$(make_fakebin "$TMP_ROOT/enabled" '#!/usr/bin/env bash
cat <<JSON
{"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"selection":{"status":"known","spendPriority":-4.75}}]}}]}
JSON
')
  out=$(with_libs "$fb" 'export FM_CREW_USAGE_ENABLE_QUOTA=1
fm_crew_usage_quota_spend_priority claude')
  [ "$out" = "-4.75" ] || fail "expected spendPriority -4.75, got '$out'"
  pass "quota lookup reads spendPriority from quota-axi's per-provider selection when enabled"
}

test_quota_caches_across_calls_in_one_process() {
  local fb calls out
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
  out=$(with_libs "$fb" 'export FM_CREW_USAGE_ENABLE_QUOTA=1
fm_crew_usage_quota_spend_priority codex >/dev/null
fm_crew_usage_quota_spend_priority codex >/dev/null
fm_crew_usage_quota_spend_priority codex')
  [ "$out" = "1.5" ] || fail "expected cached spendPriority 1.5, got '$out'"
  calls=$(cat "$TMP_ROOT/cache/.calls" 2>/dev/null || echo "?")
  [ "$calls" = "1" ] || fail "expected quota-axi invoked exactly once (cached), got $calls calls"
  pass "quota-axi is fetched at most once per process even across several usage rows"
}

test_usage_json_row_shape() {
  local fb out
  fb=$(make_fakebin "$TMP_ROOT/row" '#!/usr/bin/env bash
cat <<JSON
{"providers":[{"provider":"grok","quotaSemantics":{"effectiveAvailability":[{"selection":{"status":"known","spendPriority":0.2}}]}}]}
JSON
')
  out=$(with_libs "$fb" 'export FM_CREW_USAGE_ENABLE_QUOTA=1
fm_crew_usage_json grok "grok-4.5"')
  printf '%s' "$out" | jq -e '
    .harness == "grok" and .model == "grok-4.5"
      and .context_pct == "n/a" and .quota == "0.2"
  ' >/dev/null || fail "usage row shape mismatch: $out"
  pass "usage row carries harness, model, context_pct, and quota as documented"
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

test_context_pct_is_always_na
test_quota_disabled_by_default
test_quota_unmapped_harness_returns_empty
test_quota_enabled_reads_spend_priority
test_quota_caches_across_calls_in_one_process
test_usage_json_row_shape
test_usage_json_row_defaults_quota_to_na
