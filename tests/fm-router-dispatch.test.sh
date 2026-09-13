#!/usr/bin/env bash
# Behavior tests for the shim-first wiring of usage-axi and llm-router-axi:
# tool resolution in bin/fm-router-lib.sh, the selector's preferred telemetry
# source, and the usage-axi machine section in bin/fm-capacity.sh. The tools are
# optional, so every case drives a fake executable on PATH rather than a real
# install.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECTOR="$ROOT/bin/fm-dispatch-select.mjs"
CAPACITY="$ROOT/bin/fm-capacity.sh"
ROUTER_LIB="$ROOT/bin/fm-router-lib.sh"
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}
NOW=1000
STAMP=1970-01-01T00:16:40.000Z

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-router-dispatch.XXXXXX")
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# A fake axi tool: it records every invocation to <calls> and prints <payload>
# for any argument shape. <calls> with no writes proves the tool was not run.
write_fake_axi() { # <dir> <name> <calls> <payload> [extra-args]
  local dir=$1 name=$2 calls=$3 payload=$4
  cat > "$dir/$name" <<SH
#!/usr/bin/env bash
printf '%s\n' invoked >> "$calls"
cat "$payload"
SH
  chmod +x "$dir/$name"
}

write_quota_payload() { # <file>
  cat > "$1" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"claude","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":90}]},
  {"provider":"codex","state":{"status":"fresh","stale":false},"windows":[{"id":"all","percentRemaining":90}]}
]}
JSON
}

test_router_lib_resolves_and_reports_hint() {
  local dir out
  dir="$TMP_ROOT/libbin"; mkdir -p "$dir"
  : > "$dir/usage-axi"; : > "$dir/llm-router-axi"
  chmod +x "$dir/usage-axi" "$dir/llm-router-axi"

  out=$(PATH="$dir:$BASE_PATH" bash -c '. "$1"; fm_usage_axi_bin; fm_router_axi_bin; fm_usage_axi_have && echo usage-have; fm_router_axi_have && echo router-have; fm_router_axi_install_hint' _ "$ROUTER_LIB")
  printf '%s\n' "$out" | grep -Fxq "$dir/usage-axi" || fail "usage-axi did not resolve from PATH: $out"
  printf '%s\n' "$out" | grep -Fxq "$dir/llm-router-axi" || fail "llm-router-axi did not resolve from PATH: $out"
  printf '%s\n' "$out" | grep -Fxq usage-have || fail "fm_usage_axi_have did not report the resolved tool"
  printf '%s\n' "$out" | grep -Fxq router-have || fail "fm_router_axi_have did not report the resolved tool"
  printf '%s\n' "$out" | grep -Fq 'npm install -g usage-axi llm-router-axi' || fail "install hint is missing the install command"

  out=$(PATH="$BASE_PATH" bash -c '. "$1"; fm_usage_axi_bin; fm_usage_axi_have && echo usage-have; fm_router_axi_have && echo router-have' _ "$ROUTER_LIB")
  printf '%s\n' "$out" | grep -Fxq usage-have && fail "fm_usage_axi_have reported an absent tool"
  printf '%s\n' "$out" | grep -Fxq router-have && fail "fm_router_axi_have reported an absent tool"
  pass "fm-router-lib resolves both tools and reports the install hint"
}

test_router_lib_honours_override() {
  local dir alt out
  dir="$TMP_ROOT/overridebin"; mkdir -p "$dir"
  alt="$dir/custom-usage"; printf '#!/usr/bin/env bash\n' > "$alt"; chmod +x "$alt"
  out=$(PATH="$BASE_PATH" FM_USAGE_AXI="$alt" bash -c '. "$1"; fm_usage_axi_bin; fm_usage_axi_have && echo have' _ "$ROUTER_LIB")
  printf '%s\n' "$out" | grep -Fxq "$alt" || fail "FM_USAGE_AXI override was ignored: $out"
  printf '%s\n' "$out" | grep -Fxq have || fail "override target was not reported as available"
  pass "fm-router-lib honours the executable overrides"
}

run_selector() { # <home> <path> <body>
  local home=$1 path=$2 body=$3
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DISPATCH_STATE_FILE="$home/state/routing.json" \
    PATH="$path" \
    "$SELECTOR" select --now "$NOW" "$body"
}

test_selector_prefers_usage_axi_then_falls_back() {
  local home fakebin payload calls_u calls_q body out
  home="$TMP_ROOT/sel/home"; mkdir -p "$home/state" "$home/config"
  fakebin="$TMP_ROOT/sel/fakebin"; mkdir -p "$fakebin"
  payload="$home/quota.json"; write_quota_payload "$payload"
  calls_u="$home/usage.calls"; calls_q="$home/quota.calls"; : > "$calls_u"; : > "$calls_q"
  write_fake_axi "$fakebin" usage-axi "$calls_u" "$payload"
  write_fake_axi "$fakebin" quota-axi "$calls_q" "$payload"
  body='[{"harness":"claude"},{"harness":"codex"}]'

  out=$(run_selector "$home" "$fakebin:$BASE_PATH" "$body" 2>/dev/null | jq -r .harness)
  [ -n "$out" ] || fail "selector produced no selection with usage-axi present"
  [ -s "$calls_u" ] || fail "selector did not run usage-axi when it was on PATH"
  [ -s "$calls_q" ] && fail "selector ran quota-axi even though usage-axi was present"

  # Remove usage-axi: the selector must fall back to quota-axi.
  rm -f "$fakebin/usage-axi"
  out=$(run_selector "$home" "$fakebin:$BASE_PATH" "$body" 2>/dev/null | jq -r .harness)
  [ -n "$out" ] || fail "selector produced no selection when only quota-axi was present"
  [ -s "$calls_q" ] || fail "selector did not fall back to quota-axi"

  # An explicit override wins over both.
  rm -f "$fakebin/quota-axi"
  write_fake_axi "$fakebin" explicit-axi "$calls_q" "$payload"
  out=$(FM_DISPATCH_QUOTA_AXI=explicit-axi run_selector "$home" "$fakebin:$BASE_PATH" "$body" 2>/dev/null | jq -r .harness)
  [ -n "$out" ] || fail "selector produced no selection with an explicit override"
  pass "fm-dispatch-select prefers usage-axi, falls back to quota-axi, and honours the override"
}

test_capacity_reports_usage_axi_machine_when_present() {
  local home fakebin payload calls out
  home="$TMP_ROOT/cap/home"; mkdir -p "$home/state" "$home/config"
  fakebin="$TMP_ROOT/cap/fakebin"; mkdir -p "$fakebin"
  payload="$home/usage.json"
  cat > "$payload" <<'TOON'
bin: usage-axi
description: fake
machine:
  agents: 3
  agentCeiling: 10
TOON
  calls="$home/calls"; : > "$calls"
  write_fake_axi "$fakebin" usage-axi "$calls" "$payload"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" PATH="$fakebin:$BASE_PATH" "$CAPACITY" 2>/dev/null)
  printf '%s\n' "$out" | grep -Fq 'usage-axi machine (' || fail "fm-capacity.sh did not print the usage-axi machine section"
  printf '%s\n' "$out" | grep -Fq 'agents: 3' || fail "fm-capacity.sh did not include the usage-axi measurement"
  [ -s "$calls" ] || fail "fm-capacity.sh did not run usage-axi machine"

  rm -f "$fakebin/usage-axi"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" PATH="$BASE_PATH" "$CAPACITY" 2>/dev/null)
  printf '%s\n' "$out" | grep -Fq 'usage-axi machine (' && fail "fm-capacity.sh printed the usage-axi section with the tool absent"
  pass "fm-capacity.sh reports usage-axi machine only when the tool is installed"
}

test_router_lib_resolves_and_reports_hint
test_router_lib_honours_override
test_selector_prefers_usage_axi_then_falls_back
test_capacity_reports_usage_axi_machine_when_present

echo "# all fm-router-dispatch tests passed"
