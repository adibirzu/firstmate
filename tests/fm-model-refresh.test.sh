#!/usr/bin/env bash
# Behavior tests for the harness model-catalog refresh.
#
# No real harness binary is ever invoked here. Every listing surface is a shim
# on PATH that reproduces the real CLI's output shape, and the harness set is
# pinned per case, so the same verdicts hold on a runner with no harness
# installed at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFRESH="$ROOT/bin/fm-model-refresh.sh"
command -v jq >/dev/null 2>&1 || fail "test needs jq"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# write_listing <file> <prefix> <suffix> <model>...: one harness listing surface's
# real output shape, header line included.
write_listing() {
  local file=$1 prefix=$2 suffix=$3 model
  shift 3
  printf 'Available models\n\n' > "$file"
  for model in "$@"; do
    printf '%s%s%s\n' "$prefix" "$model" "$suffix" >> "$file"
  done
}

# write_shim <path> <log> <listing-flag> <listing-file>: a harness shim that
# answers its listing surface and appends every invocation to <log>, so a test
# can prove which invocations did NOT happen. Any other invocation answers like
# a one-shot prompt.
write_shim() {
  local path=$1 log=$2 flag=$3 listing=$4
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
if [ "\${1:-}" = "$flag" ]; then
  cat "$listing"
  exit 0
fi
printf 'one token\n'
exit 0
SH
  chmod +x "$path"
}

# The real Grok CLI prints a bulleted list; the real Cursor CLI prints
# "<id> - <label>" pairs. Both shapes must parse.
write_grok_shim() { # <fakebin> <log> <model>...
  local fakebin=$1 log=$2
  shift 2
  write_listing "$fakebin/../grok-listing.txt" '  - ' '' "$@"
  write_shim "$fakebin/grok" "$log" models "$fakebin/../grok-listing.txt"
}

write_cursor_shim() { # <fakebin> <log> <model>...
  local fakebin=$1 log=$2
  shift 2
  write_listing "$fakebin/../cursor-listing.txt" '' ' - Label' "$@"
  write_shim "$fakebin/cursor-agent" "$log" --list-models "$fakebin/../cursor-listing.txt"
}

run_refresh() { # <fakebin> <harnesses> <catalog> [args...]
  local fakebin=$1 harnesses=$2 catalog=$3
  shift 3
  FM_MODEL_REFRESH_HARNESSES="$harnesses" PATH="$fakebin:$BASE_PATH" \
    "$REFRESH" --catalog "$catalog" "$@"
}

test_absent_harness_is_reported_and_a_pass_that_checked_nothing_is_refused() {
  local root fakebin catalog out rc
  root=$(fm_test_tmproot fm-model-refresh-absent) || fail "tmproot"
  fakebin=$(fm_fakebin "$root")
  catalog="$root/catalog.json"
  write_grok_shim "$fakebin" "$root/grok.log" grok-4.6

  out=$(run_refresh "$fakebin" "grok cursor kimi claude" "$catalog" 2>&1) \
    || fail "a run with one live listing should succeed: $out"
  assert_contains "$out" "harness=cursor status=absent" "an absent harness must be reported, not skipped silently"
  assert_contains "$out" "harness=kimi status=absent" "every absent harness must be named"
  assert_contains "$out" "harness=claude status=no-listing" "a harness with no listing surface must say so"
  assert_contains "$out" "harness=grok status=listed" "the installed harness must be listed"
  [ "$(jq -r '.harnesses[] | select(.harness == "cursor") | .reason' "$catalog")" != "null" ] \
    || fail "an absent harness must record why it was not checked"

  rc=0
  out=$(run_refresh "$fakebin" "cursor kimi" "$root/nothing.json" 2>&1) || rc=$?
  expect_code 3 "$rc" "a run where no harness produced a listing must refuse"
  assert_contains "$out" "checked nothing" "the refusal must say the run checked nothing"
  assert_absent "$root/nothing.json" "a run that checked nothing must not publish a catalog"
  pass "absent harnesses are reported explicitly and a pass that checked nothing is refused"
}

test_new_models_are_named_against_the_previous_run() {
  local root fakebin catalog first second third
  root=$(fm_test_tmproot fm-model-refresh-diff) || fail "tmproot"
  fakebin=$(fm_fakebin "$root")
  catalog="$root/catalog.json"

  write_cursor_shim "$fakebin" "$root/cursor.log" cursor-grok-4.6-high
  first=$(run_refresh "$fakebin" cursor "$catalog" 2>&1) || fail "first run failed: $first"
  assert_contains "$first" "new since last run: cursor-grok-4.6-high" "a first run must name every id as new"

  second=$(run_refresh "$fakebin" cursor "$catalog" 2>&1) || fail "second run failed: $second"
  assert_not_contains "$second" "new since last run" "an unchanged catalog must report nothing new"
  assert_contains "$second" "new=0 removed=0" "an unchanged catalog must report a zero diff"

  # The exact drift this tool exists to catch: a vendor grows an effort ladder
  # under an id family that was previously high-only.
  write_cursor_shim "$fakebin" "$root/cursor.log" \
    cursor-grok-4.6-high cursor-grok-4.6-low cursor-grok-4.6-medium
  third=$(run_refresh "$fakebin" cursor "$catalog" 2>&1) || fail "third run failed: $third"
  assert_contains "$third" "new since last run: cursor-grok-4.6-low, cursor-grok-4.6-medium" \
    "an added model must be named as new since the previous run"
  assert_not_contains "$third" "gone since last run" "an unchanged id must not read as removed"

  write_cursor_shim "$fakebin" "$root/cursor.log" cursor-grok-4.6-high
  third=$(run_refresh "$fakebin" cursor "$catalog" 2>&1) || fail "fourth run failed: $third"
  assert_contains "$third" "gone since last run: cursor-grok-4.6-low, cursor-grok-4.6-medium" \
    "a retired model must be named as gone"

  [ "$(jq -r '.generatedAt' "$catalog")" != "null" ] || fail "the catalog must carry its own date"
  [ "$(jq -r '.harnesses[0].models[0].firstSeen' "$catalog")" != "null" ] \
    || fail "each model must carry the date it was first seen"
  pass "the catalog names what is new and what is gone since the previous run"
}

test_probing_never_runs_without_its_flag_and_self_skips_an_absent_harness() {
  local root fakebin catalog log out rc
  root=$(fm_test_tmproot fm-model-refresh-probe) || fail "tmproot"
  fakebin=$(fm_fakebin "$root")
  catalog="$root/catalog.json"
  log="$root/grok.log"
  write_grok_shim "$fakebin" "$log" grok-4.6 grok-4.5

  run_refresh "$fakebin" grok "$catalog" >/dev/null 2>&1 || fail "default run failed"
  assert_no_grep "-p" "$log" "a default run must never spend quota on a probe"
  [ "$(grep -cx "models" "$log")" = 1 ] || fail "a default run must invoke only the listing surface: $(cat "$log")"
  [ "$(jq -r '.harnesses[0].models[0].probe' "$catalog")" = null ] \
    || fail "a default run must record no probe result"

  # An absent harness named for probing self-skips instead of failing the run.
  out=$(run_refresh "$fakebin" grok "$root/skip.json" --probe cursor 2>&1) \
    || fail "probing an absent harness must not fail the run: $out"
  assert_contains "$out" "probe skipped: cursor is not installed" "an absent probe target must be reported"

  rc=0
  out=$(run_refresh "$fakebin" grok "$root/unknown.json" --probe nonesuch 2>&1) || rc=$?
  expect_code 2 "$rc" "probing an unregistered harness must be a usage error"

  rc=0
  out=$(FM_MODEL_PROBE_MAX=1 run_refresh "$fakebin" grok "$root/bound.json" --probe grok 2>&1) || rc=$?
  expect_code 4 "$rc" "a probe set over its bound must be refused"
  assert_contains "$out" "exceeds the FM_MODEL_PROBE_MAX bound" "the bound refusal must name the bound"
  assert_no_grep "-p" "$log" "a refused probe set must not have probed anything first"
  pass "probing stays opt-in, self-skips an absent harness, and refuses a truncated set"
}

test_a_probe_records_a_per_model_verdict() {
  local root fakebin catalog out
  root=$(fm_test_tmproot fm-model-refresh-verdict) || fail "tmproot"
  fakebin=$(fm_fakebin "$root")
  catalog="$root/catalog.json"
  write_grok_shim "$fakebin" "$root/grok.log" grok-4.6

  out=$(run_refresh "$fakebin" grok "$catalog" --probe grok=grok-4.6 2>&1) \
    || fail "an explicit single-model probe should succeed: $out"
  assert_contains "$out" "probe harness=grok model=grok-4.6 result=usable" "the probe verdict must be reported"
  [ "$(jq -r '.harnesses[0].models[0].probe.status' "$catalog")" = usable ] \
    || fail "the probe verdict must be recorded against that model"
  assert_grep "-p" "$root/grok.log" "an explicit probe must actually invoke the one-shot form"
  pass "an explicit probe records a per-model verdict in the catalog"
}

test_absent_harness_is_reported_and_a_pass_that_checked_nothing_is_refused
test_new_models_are_named_against_the_previous_run
test_probing_never_runs_without_its_flag_and_self_skips_an_absent_harness
test_a_probe_records_a_per_model_verdict

echo "# all fm-model-refresh tests passed"
