#!/usr/bin/env bash
# tests/capacity-pin.sh - the single owner of the fake dispatch-tool bindings
# every suite that drives a real bin/fm-spawn.sh or the router shims runs
# against.
#
# Source this from a test file that does NOT source tests/lib.sh:
#   # shellcheck source=tests/capacity-pin.sh
#   . "$ROOT/tests/capacity-pin.sh"
# tests/lib.sh sources it for every other suite, so most tests get it for free.
#
# WHY
# Spawn admission now asks `llm-router-axi capacity` for the live machine
# verdict instead of measuring in-repo (bin/fm-capacity-lib.sh). Firstmate's
# own suite runs on exactly the busy machines that guard exists to protect, so
# an unpinned spawn test would pass or fail depending on the memory pressure at
# that second, and a runner without the tool installed would refuse every spawn.
# These bindings point the shims at a permissive fake router so ordinary spawn
# tests admit. A suite testing the guard or the absent-tool path overrides
# FM_LLM_ROUTER_AXI per case with its own fake.
#
# The fake answers the router verbs the fork calls: `capacity [--json]` admits,
# `classify-evidence` reports no depletion, and everything else exits 0.

FM_CAPACITY_FAKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fm-router-fake.XXXXXX")"
FM_CAPACITY_FAKE_ROUTER="$FM_CAPACITY_FAKE_ROOT/llm-router-axi"
cat > "$FM_CAPACITY_FAKE_ROUTER" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capacity)
    printf '{"ok":true,"measured":{},"reasons":[],"signals":[]}\n'
    exit 0
    ;;
  classify-evidence)
    printf 'classification=none\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$FM_CAPACITY_FAKE_ROUTER"
export FM_LLM_ROUTER_AXI="$FM_CAPACITY_FAKE_ROUTER"
