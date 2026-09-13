#!/usr/bin/env bash
# Behavior tests for the thin dispatch shims over llm-router-axi:
# tool resolution in bin/fm-router-lib.sh and the forwarding contract of
# bin/fm-dispatch-select.mjs. The tools are external, so every case drives a
# fake executable rather than a real install.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECTOR="$ROOT/bin/fm-dispatch-select.mjs"
ROUTER_LIB="$ROOT/bin/fm-router-lib.sh"
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-router-dispatch.XXXXXX")
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# A fake axi tool: records every invocation to <calls> and prints <payload>.
write_fake_axi() { # <dir> <name> <calls> <payload>
  local dir=$1 name=$2 calls=$3 payload=$4
  cat > "$dir/$name" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls"
cat "$payload"
SH
  chmod +x "$dir/$name"
}

test_router_lib_resolves_and_reports_hint() {
  local dir out
  dir="$TMP_ROOT/libbin"; mkdir -p "$dir"
  : > "$dir/usage-axi"; : > "$dir/llm-router-axi"
  chmod +x "$dir/usage-axi" "$dir/llm-router-axi"

  # shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1.
  out=$(env -u FM_LLM_ROUTER_AXI -u FM_USAGE_AXI PATH="$dir:$BASE_PATH" bash -c '. "$1"; fm_usage_axi_bin; fm_router_axi_bin; fm_usage_axi_have && echo usage-have; fm_router_axi_have && echo router-have; fm_router_axi_install_hint' _ "$ROUTER_LIB")
  printf '%s\n' "$out" | grep -Fxq "$dir/usage-axi" || fail "usage-axi did not resolve from PATH: $out"
  printf '%s\n' "$out" | grep -Fxq "$dir/llm-router-axi" || fail "llm-router-axi did not resolve from PATH: $out"
  printf '%s\n' "$out" | grep -Fxq usage-have || fail "fm_usage_axi_have did not report the resolved tool"
  printf '%s\n' "$out" | grep -Fxq router-have || fail "fm_router_axi_have did not report the resolved tool"
  printf '%s\n' "$out" | grep -Fq 'npm install -g usage-axi llm-router-axi' || fail "install hint is missing the install command"

  # shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1.
  out=$(env -u FM_LLM_ROUTER_AXI -u FM_USAGE_AXI PATH="$BASE_PATH" bash -c '. "$1"; fm_usage_axi_bin; fm_usage_axi_have && echo usage-have; fm_router_axi_have && echo router-have' _ "$ROUTER_LIB")
  printf '%s\n' "$out" | grep -Fxq usage-have && fail "fm_usage_axi_have reported an absent tool"
  printf '%s\n' "$out" | grep -Fxq router-have && fail "fm_router_axi_have reported an absent tool"
  pass "fm-router-lib resolves both tools and reports the install hint"
}

test_router_lib_honours_override() {
  local dir alt out
  dir="$TMP_ROOT/overridebin"; mkdir -p "$dir"
  alt="$dir/custom-router"; printf '#!/usr/bin/env bash\n' > "$alt"; chmod +x "$alt"
  # shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1.
  out=$(env -u FM_USAGE_AXI PATH="$BASE_PATH" FM_LLM_ROUTER_AXI="$alt" bash -c '. "$1"; fm_router_axi_bin; fm_router_axi_have && echo have' _ "$ROUTER_LIB")
  printf '%s\n' "$out" | grep -Fxq "$alt" || fail "FM_LLM_ROUTER_AXI override was ignored: $out"
  printf '%s\n' "$out" | grep -Fxq have || fail "override target was not reported as available"
  pass "fm-router-lib honours the executable override"
}

test_selector_forwards_to_router() {
  local dir payload calls out
  dir="$TMP_ROOT/shim"; mkdir -p "$dir"
  payload="$dir/payload"; printf '{"harness":"claude"}\n' > "$payload"
  calls="$dir/calls"; : > "$calls"
  write_fake_axi "$dir" llm-router-axi "$calls" "$payload"

  out=$(FM_LLM_ROUTER_AXI="$dir/llm-router-axi" "$SELECTOR" select --quota-json /q.json --now 1000 '[{"harness":"claude"}]' 2>/dev/null)
  [ "$out" = '{"harness":"claude"}' ] || fail "select did not forward the router's stdout: $out"
  call=$(cat "$calls")
  assert_contains "$call" "select" "select forwards the select subcommand"
  assert_contains "$call" "--quota-json /q.json" "select forwards --quota-json"
  assert_contains "$call" "--now 1000" "select forwards --now"

  : > "$calls"
  FM_LLM_ROUTER_AXI="$dir/llm-router-axi" "$SELECTOR" record-failure --provider agy --task t-7 >/dev/null 2>&1
  call=$(cat "$calls")
  assert_contains "$call" "record" "record-failure forwards to the record subcommand"
  assert_contains "$call" "--outcome rate_limit" "record-failure records a rate limit"
  assert_contains "$call" "--provider agy" "record-failure forwards the provider"
  assert_contains "$call" "--task t-7" "record-failure forwards the task"

  : > "$calls"
  FM_LLM_ROUTER_AXI="$dir/llm-router-axi" "$SELECTOR" clear --provider cursor >/dev/null 2>&1
  call=$(cat "$calls")
  assert_contains "$call" "--outcome ok" "clear records a clean outcome"
  assert_contains "$call" "--provider cursor" "clear forwards the provider"
  pass "fm-dispatch-select forwards select, record-failure, and clear to llm-router-axi"
}

test_selector_refuses_without_router() {
  local out rc
  if out=$(env -u FM_LLM_ROUTER_AXI PATH="$BASE_PATH" "$SELECTOR" select '[{"harness":"claude"}]' 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 2 ] || fail "an absent router should exit 2, got rc=$rc: $out"
  assert_contains "$out" "llm-router-axi is not available" "absent-router message"
  assert_contains "$out" "install it with" "absent-router install hint"
  pass "fm-dispatch-select refuses without llm-router-axi instead of silently dispatching"
}

test_router_lib_resolves_and_reports_hint
test_router_lib_honours_override
test_selector_forwards_to_router
test_selector_refuses_without_router

echo "# all fm-router-dispatch tests passed"
