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
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
  [ "$out" = "40" ] || fail "context_pct for codex: expected 40, got '$out'"
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct claude task-1")
  [ "$out" = "40" ] || fail "context_pct for claude: expected 40, got '$out'"
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct pi task-1")
  [ "$out" = "n/a" ] || fail "context_pct for unsupported harness: expected n/a, got '$out'"
  pass "context percentage reads supported statusline output"
}

test_context_pct_rejects_out_of_range() {
  local fb statusline out
  fb=$(make_fakebin "$TMP_ROOT/context-range" '')
  statusline="$TMP_ROOT/statusline-range"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "status=ok source=codex context_pct=999\\n"' > "$statusline"
  chmod +x "$statusline"
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
  [ "$out" = "n/a" ] || fail "out-of-range context_pct: expected n/a, got '$out'"
  pass "context percentage rejects values outside 0 through 100"
}

test_context_pct_times_out() {
  local fb statusline out
  fb=$(make_fakebin "$TMP_ROOT/context-timeout" '')
  statusline="$TMP_ROOT/statusline-timeout"
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 2' 'printf "status=ok source=codex context_pct=40\\n"' > "$statusline"
  chmod +x "$statusline"
  out=$(FM_CREW_USAGE_CONTEXT_TIMEOUT=1 with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
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

# --- the watcher-contention regression -------------------------------------
# bin/fm-watch.sh backgrounds fm-home-summary-refresh.sh and
# fm-secondmate-reconcile.sh on EVERY poll, and both read the canonical
# snapshot. The statusline diagnostic captures the task's pane, so an
# unconditional read here races the watcher's own churn capture and costs it
# the evidence it uses to absorb a bare turn-end
# (tests/fm-watch-triage.test.sh, "pane churn resets prior wedge escalation
# state before the stale-path poll"). A bound is not enough - a fast extra
# capture is still an extra capture - so the read must not happen at all
# unless a caller opts in. These guard that it never fires by default.
test_context_pct_disabled_by_default() {
  local fb statusline out
  fb=$(make_fakebin "$TMP_ROOT/context-off" '')
  statusline="$TMP_ROOT/statusline-off"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "the statusline diagnostic must never run when the context gate is off" >&2' \
    'exit 1' > "$statusline"
  chmod +x "$statusline"
  out=$(with_libs "$fb" "FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
  [ "$out" = "n/a" ] || fail "context_pct must be n/a with the gate off, got '$out'"
  pass "context percentage never captures a pane by default (FM_CREW_USAGE_ENABLE_CONTEXT unset)"
}

test_usage_json_makes_no_live_read_by_default() {
  local fb statusline out
  fb=$(make_fakebin "$TMP_ROOT/row-off" '#!/usr/bin/env bash
echo "quota-axi must not run on a default snapshot row" >&2
exit 1
')
  statusline="$TMP_ROOT/statusline-row-off"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "the statusline diagnostic must not run on a default snapshot row" >&2' \
    'exit 1' > "$statusline"
  chmod +x "$statusline"
  make_account codex-account codex
  out=$(with_libs "$fb" "FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_json codex gpt-5.5 task-1 codex-account")
  printf '%s' "$out" | jq -e '
    .harness == "codex" and .model == "gpt-5.5"
      and .context_pct == "n/a" and .quota == "n/a"
  ' >/dev/null || fail "a default usage row must carry meta only, no live reads: $out"
  pass "a default usage row reads meta only: no pane capture and no quota call"
}

test_context_pct_opt_in_is_explicit() {
  local fb statusline out
  fb=$(make_fakebin "$TMP_ROOT/context-optin" '')
  statusline="$TMP_ROOT/statusline-optin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "status=ok source=codex context_pct=40\\n"' > "$statusline"
  chmod +x "$statusline"
  # Only the exact opt-in value enables it; anything else stays off.
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=0 FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
  [ "$out" = "n/a" ] || fail "explicit 0 must stay off, got '$out'"
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=yes FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
  [ "$out" = "n/a" ] || fail "a non-1 gate value must stay off, got '$out'"
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_STATUSLINE_BIN=$statusline fm_crew_usage_context_pct codex task-1")
  [ "$out" = "40" ] || fail "the opt-in must still read live, got '$out'"
  pass "the live context read turns on only for the exact opt-in value"
}

test_bearings_is_the_context_opt_in_caller() {
  grep -q 'FM_CREW_USAGE_ENABLE_CONTEXT' "$ROOT/bin/fm-bearings-snapshot.sh" \
    || fail "fm-bearings-snapshot.sh must opt into the live context read it renders"
  grep -q 'FM_CREW_USAGE_ENABLE_CONTEXT' "$ROOT/bin/fm-home-summary-refresh.sh" \
    && fail "the supervision-path home summary refresh must never opt into a pane capture"
  grep -q 'FM_CREW_USAGE_ENABLE_CONTEXT' "$ROOT/bin/fm-secondmate-reconcile.sh" \
    && fail "the supervision-path reconcile must never opt into a pane capture"
  pass "only the human-facing bearings reader opts into the live context read"
}

# --- model placeholders and the codex native-footer fallback ----------------
# bin/fm-spawn.sh writes model=default (and model=- on the secondmate path)
# whenever no model was chosen, so meta's model is often a placeholder. Live
# evidence in docs/verification/fm-harness-usage-bar.md: every running codex
# task in the reference home carried model=default while its own pane footer
# read "gpt-5.6-terra high". The row must never present a placeholder as a
# model name, and the footer recovery must never accept transcript text.
test_model_placeholders_are_not_reported_as_models() {
  local fb out m
  fb=$(make_fakebin "$TMP_ROOT/model-placeholder" '')
  for m in default - unknown "n/a" ""; do
    out=$(with_libs "$fb" "fm_crew_usage_json codex '$m' '' ''")
    printf '%s' "$out" | jq -e '.model == ""' >/dev/null \
      || fail "placeholder model '$m' must report as unrecorded, got: $out"
  done
  out=$(with_libs "$fb" "fm_crew_usage_json codex 'gpt-5.6-terra' '' ''")
  printf '%s' "$out" | jq -e '.model == "gpt-5.6-terra"' >/dev/null \
    || fail "a real model must pass through unchanged: $out"
  pass "model placeholders are reported as unrecorded, real models pass through"
}

test_model_footer_fallback_is_opt_in_and_shape_anchored() {
  local fb peek out
  fb=$(make_fakebin "$TMP_ROOT/model-footer" '')
  peek="$TMP_ROOT/peek-footer"
  # The exact live-captured codex footer shape.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'printf "\xe2\x80\xba Ask Codex to do anything\n\n  gpt-5.6-terra high \xc2\xb7 ~/work/repo\n"'
  } > "$peek"
  chmod +x "$peek"
  # Off by default: same gate as the context read, because it is the same capture.
  out=$(with_libs "$fb" "FM_CREW_USAGE_PEEK_BIN=$peek fm_crew_usage_json codex default task-1 ''")
  printf '%s' "$out" | jq -e '.model == ""' >/dev/null \
    || fail "the footer fallback must not capture a pane by default: $out"
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_PEEK_BIN=$peek fm_crew_usage_json codex default task-1 ''")
  printf '%s' "$out" | jq -e '.model == "gpt-5.6-terra"' >/dev/null \
    || fail "the opted-in footer fallback must recover the live model: $out"
  pass "the codex footer model fallback is opt-in and recovers the live model"
}

test_model_footer_fallback_ignores_transcript_lookalikes() {
  local fb peek out
  fb=$(make_fakebin "$TMP_ROOT/model-spoof" '')
  peek="$TMP_ROOT/peek-spoof"
  # A crew that printed model-ish text, but never the footer's own shape.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'printf "using evil-model high in the plan\n  evil-model turbo \xc2\xb7 ~/x\n+ echo gpt-9 high\n"'
  } > "$peek"
  chmod +x "$peek"
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_PEEK_BIN=$peek fm_crew_usage_json codex default task-1 ''")
  printf '%s' "$out" | jq -e '.model == ""' >/dev/null \
    || fail "transcript lookalikes must not be reported as the crew's model: $out"
  pass "the footer fallback rejects transcript text that is not the footer shape"
}

test_model_footer_fallback_is_codex_only_and_bounded() {
  local fb peek out
  fb=$(make_fakebin "$TMP_ROOT/model-bound" '')
  peek="$TMP_ROOT/peek-bound"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'printf "  gpt-5.6-terra high \xc2\xb7 ~/work/repo\n"'
  } > "$peek"
  chmod +x "$peek"
  # Claude renders its own statusline; only codex needs the footer recovery.
  out=$(with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_PEEK_BIN=$peek fm_crew_usage_json claude default task-1 ''")
  printf '%s' "$out" | jq -e '.model == ""' >/dev/null \
    || fail "the footer fallback must stay codex-only: $out"
  # A hung pane read must expire into "unrecorded", never stall the row.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'sleep 5'
  } > "$peek"
  out=$(FM_CREW_USAGE_CONTEXT_TIMEOUT=1 with_libs "$fb" "FM_CREW_USAGE_ENABLE_CONTEXT=1 FM_CREW_USAGE_PEEK_BIN=$peek fm_crew_usage_json codex default task-1 ''")
  printf '%s' "$out" | jq -e '.model == ""' >/dev/null \
    || fail "a hung pane read must expire to unrecorded: $out"
  pass "the footer fallback is codex-only and expires on a hung pane read"
}

test_context_pct_reads_supported_statusline
test_context_pct_rejects_out_of_range
test_context_pct_times_out
test_context_pct_disabled_by_default
test_context_pct_opt_in_is_explicit
test_usage_json_makes_no_live_read_by_default
test_bearings_is_the_context_opt_in_caller
test_model_placeholders_are_not_reported_as_models
test_model_footer_fallback_is_opt_in_and_shape_anchored
test_model_footer_fallback_ignores_transcript_lookalikes
test_model_footer_fallback_is_codex_only_and_bounded
test_quota_disabled_by_default
test_quota_unmapped_harness_returns_empty
test_quota_enabled_reads_spend_priority
test_quota_caches_across_calls_in_one_process
test_usage_json_row_shape
test_usage_json_row_defaults_quota_to_na
test_quota_requires_worker_account
test_quota_timeout_must_be_positive
