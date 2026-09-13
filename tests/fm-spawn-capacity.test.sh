#!/usr/bin/env bash
# Behavior tests for the machine-capacity spawn guard after the router wiring:
# bin/fm-capacity-lib.sh (the admission wrapper over llm-router-axi capacity),
# its bin/fm-capacity.sh report, and the absent-tool refusal.
#
# The measurement and thresholds live in llm-router-axi, so these tests drive a
# fake router rather than the live machine and pin what this repo still owns:
#   - the guard admits when the router says ok and refuses when it says no
#   - the refusal prints the router's reasons and names the refused work
#   - an absent or unreadable router refuses rather than spawning blind
#   - fm-capacity.sh prints the router reading and the usage-axi measurement,
#     and `check` propagates the router's exit status
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPACITY="$ROOT/bin/fm-capacity.sh"
CAPACITY_LIB="$ROOT/bin/fm-capacity-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-capacity)

write_fake_router() { # <dir> <capacity-json> [check-exit]
  local dir=$1 json=$2 check_exit=${3:-0}
  cat > "$dir/llm-router-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  capacity)
    printf '%s\n' '$json'
    exit '$check_exit'
    ;;
esac
exit 0
SH
  chmod +x "$dir/llm-router-axi"
}

run_guard() { # <router-path> -> prints stderr, returns guard status
  FM_LLM_ROUTER_AXI="$1" bash -c '. "$1"; fm_capacity_guard ignored "ship task t1"' _ "$CAPACITY_LIB"
}

{
  dir="$TMP_ROOT/admit"; mkdir -p "$dir"
  write_fake_router "$dir" '{"ok":true,"measured":{},"reasons":[],"signals":[]}'
  if run_guard "$dir/llm-router-axi" 2>"$dir/err"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] || fail "guard should admit when the router says ok, rc=$rc: $(cat "$dir/err")"
  [ ! -s "$dir/err" ] || fail "an admitting guard must stay silent, got: $(cat "$dir/err")"
  pass "fm-capacity-lib admits when llm-router-axi reports headroom"
}

{
  dir="$TMP_ROOT/refuse"; mkdir -p "$dir"
  write_fake_router "$dir" '{"ok":false,"measured":{},"reasons":["memory free 5% is under the 10% reserve","the one-suite-at-a-time slot is occupied"],"signals":[]}'
  if run_guard "$dir/llm-router-axi" 2>"$dir/err"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || fail "guard should decline when the router says no, rc=$rc"
  err=$(cat "$dir/err")
  assert_contains "$err" "memory free 5% is under the 10% reserve" "refusal prints the router's measured reason"
  assert_contains "$err" "the one-suite-at-a-time slot is occupied" "refusal prints every reason"
  assert_contains "$err" "ship task t1" "refusal names the refused work"
  pass "fm-capacity-lib declines with the router's reasons and the refused work named"
}

{
  if run_guard "$TMP_ROOT/does-not-exist" 2>"$TMP_ROOT/missing.err"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || fail "an absent router must decline, rc=$rc"
  err=$(cat "$TMP_ROOT/missing.err")
  assert_contains "$err" "llm-router-axi is not installed" "absent-router message names the missing tool"
  pass "fm-capacity-lib declines rather than spawning blind when the router is absent"
}

{
  dir="$TMP_ROOT/report"; mkdir -p "$dir"
  write_fake_router "$dir" 'capacity:
  ok: true
  summary: headroom available'
  out=$(FM_LLM_ROUTER_AXI="$dir/llm-router-axi" "$CAPACITY" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "fm-capacity.sh report should exit 0, rc=$rc"
  assert_contains "$out" "headroom available" "fm-capacity.sh prints the router reading"
  pass "fm-capacity.sh reports the llm-router-axi capacity reading"
}

{
  dir="$TMP_ROOT/check"; mkdir -p "$dir"
  write_fake_router "$dir" 'capacity:
  ok: false
  summary: no headroom' 1
  if out=$(FM_LLM_ROUTER_AXI="$dir/llm-router-axi" "$CAPACITY" check 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || fail "fm-capacity.sh check should propagate the router refusal, rc=$rc: $out"
  pass "fm-capacity.sh check exits 1 when the router reports no headroom"
}

{
  dir="$TMP_ROOT/toolreport"; mkdir -p "$dir"
  cat > "$dir/usage-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = machine ] || exit 0
printf 'agents: 3\nagentCeiling: 10\n'
SH
  chmod +x "$dir/usage-axi"
  write_fake_router "$dir" 'capacity:
  ok: true
  summary: headroom available'
  out=$(FM_LLM_ROUTER_AXI="$dir/llm-router-axi" FM_USAGE_AXI="$dir/usage-axi" "$CAPACITY" 2>/dev/null)
  assert_contains "$out" "usage-axi machine (" "fm-capacity.sh prints the usage-axi machine section when installed"
  assert_contains "$out" "agents: 3" "fm-capacity.sh includes the usage-axi measurement"
  out=$(FM_LLM_ROUTER_AXI="$dir/llm-router-axi" FM_USAGE_AXI="$dir/also-missing" "$CAPACITY" 2>/dev/null)
  case "$out" in
    *"usage-axi machine ("*) fail "fm-capacity.sh printed the usage-axi section with the tool absent" ;;
  esac
  pass "fm-capacity.sh reports usage-axi machine only when the tool is installed"
}

printf 'All fm-spawn-capacity tests passed.\n'
