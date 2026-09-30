#!/usr/bin/env bash
# Tests for remote overflow dispatch (bin/fm-remote-overflow-lib.sh and the
# bin/fm-spawn.sh guard-refusal hook): when the local machine-capacity guard
# declines a fresh ship/scout spawn, the work is offered to a registered remote
# secondmate home with headroom through the existing remote handoff, and the
# spawn reports which machine took it. When no remote home has headroom, the
# refusal stands exactly as before.
#
# Every cross-host read is a stubbed fm-on.sh and every handoff a stubbed
# fm-backlog-handoff.sh, so no case touches a real station. One spawn-level
# case drives the real fm-spawn.sh entrypoint against a fake home with a real
# markdown backlog to prove the refusal-to-routed path end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

LIB="$ROOT/bin/fm-remote-overflow-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-overflow)
export FM_BACKEND=tmux
unset TASKS_AXI_BACKEND || :

REMOTE_B='- b-mate - overflow mate (host: b-host; root: /remote/firstmate; home: /remote/home-b; scope: overflow; projects: ; added 2026-09-13)'
REMOTE_A='- a-mate - overflow mate (host: a-host; root: /remote/firstmate; home: /remote/home-a; scope: overflow; projects: ; added 2026-09-13)'
LOCAL_REC='- l-mate - local mate (home: /local/home-l; scope: local; projects: ; added 2026-08-02)'

make_data() {  # <name> [registry lines...] -> prints data dir
  local name=$1 dir
  shift
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  : > "$dir/secondmates.md"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$dir/secondmates.md"
  done
  printf '%s\n' "$dir"
}

# Stub fm-on.sh: answers `fm-capacity.sh check` per secondmate id from the
# FM_TEST_CAP_<ID> environment (0 = headroom, anything else = refusal), honors
# FM_TEST_CAP_SLEEP for the timeout case, and logs calls for order assertions.
write_fm_on_stub() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_TEST_CAP_LOG:-/dev/null}"
id=$1
shift
case "$*" in
  *fm-capacity.sh*) ;;
  *) exit 2 ;;
esac
[ -n "${FM_TEST_CAP_SLEEP:-}" ] && sleep "$FM_TEST_CAP_SLEEP"
var="FM_TEST_CAP_$(printf '%s' "$id" | tr 'a-z-.' 'A-Z__')"
rc=$(eval "printf '%s' \"\${$var:-1}\"")
exit "$rc"
SH
  chmod +x "$1"
}

write_handoff_stub() {  # <path> <exit> — logs argv, prints a receipt line
  local path=$1 rc=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_HANDOFF_LOG"
echo "stub-handoff receipt: \$*"
exit $rc
SH
  chmod +x "$path"
}

# --- enumeration ------------------------------------------------------------

{
  data=$(make_data enum "$REMOTE_B" "$REMOTE_A" "$LOCAL_REC")
  out=$(DATA="$data" bash -c '. "$1"; fm_overflow_remote_ids' _ "$LIB")
  [ "$out" = "$(printf 'a-mate\nb-mate')" ] || fail "remote ids must be alphabetical and exclude local routes, got: $out"
  pass "overflow enumerates remote ids alphabetically and skips local routes"
}

{
  data=$(make_data enum-local "$LOCAL_REC")
  out=$(DATA="$data" bash -c '. "$1"; fm_overflow_remote_ids' _ "$LIB")
  [ -z "$out" ] || fail "a local-only registry must enumerate nothing, got: $out"
  pass "overflow enumerates nothing without remote routes"
}

# --- picking -----------------------------------------------------------------

{
  data=$(make_data pick "$REMOTE_B" "$REMOTE_A")
  stub="$TMP_ROOT/fm-on-pick"; write_fm_on_stub "$stub"
  : > "$TMP_ROOT/pick.log"
  out=$(DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_TEST_CAP_LOG="$TMP_ROOT/pick.log" \
    FM_TEST_CAP_A_MATE=1 FM_TEST_CAP_B_MATE=0 \
    bash -c '. "$1"; fm_overflow_pick' _ "$LIB") || fail "pick should succeed when b-mate has headroom"
  [ "$out" = "b-mate b-host" ] || fail "pick must print '<id> <host>', got: $out"
  pass "overflow picks the alphabetically-first remote home with headroom"
}

{
  data=$(make_data pick-order "$REMOTE_B" "$REMOTE_A")
  stub="$TMP_ROOT/fm-on-order"; write_fm_on_stub "$stub"
  : > "$TMP_ROOT/order.log"
  out=$(DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_TEST_CAP_LOG="$TMP_ROOT/order.log" \
    FM_TEST_CAP_A_MATE=0 FM_TEST_CAP_B_MATE=0 \
    bash -c '. "$1"; fm_overflow_pick' _ "$LIB") || fail "pick should succeed when both have headroom"
  [ "$out" = "a-mate a-host" ] || fail "with two qualified homes the alphabetical winner must be a-mate, got: $out"
  first=$(head -1 "$TMP_ROOT/order.log")
  [ "$first" = "a-mate" ] || fail "the alphabetical home must be probed first, log: $(cat "$TMP_ROOT/order.log")"
  pass "overflow tie-breaks alphabetically and probes in that order"
}

{
  data=$(make_data pick-none "$REMOTE_B" "$REMOTE_A")
  stub="$TMP_ROOT/fm-on-none"; write_fm_on_stub "$stub"
  if DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_TEST_CAP_A_MATE=1 FM_TEST_CAP_B_MATE=1 \
    bash -c '. "$1"; fm_overflow_pick' _ "$LIB" >/dev/null 2>&1; then
    fail "pick must fail when every probe refuses"
  fi
  pass "overflow reports no pick when every remote probe refuses"
}

{
  data=$(make_data pick-transport "$REMOTE_A")
  stub="$TMP_ROOT/fm-on-transport"; write_fm_on_stub "$stub"
  if DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_TEST_CAP_A_MATE=255 \
    bash -c '. "$1"; fm_overflow_pick' _ "$LIB" >/dev/null 2>&1; then
    fail "pick must treat transport failure (255) as no headroom"
  fi
  pass "overflow treats a failed probe as no headroom, never as headroom"
}

{
  data=$(make_data pick-timeout "$REMOTE_A")
  stub="$TMP_ROOT/fm-on-timeout"; write_fm_on_stub "$stub"
  if DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_TEST_CAP_A_MATE=0 FM_TEST_CAP_SLEEP=30 \
    FM_OVERFLOW_PROBE_SECONDS=2 \
    bash -c '. "$1"; fm_overflow_pick' _ "$LIB" >/dev/null 2>&1; then
    fail "pick must treat a timed-out probe as no headroom"
  fi
  pass "overflow treats a timed-out probe as no headroom"
}

{
  data=$(make_data pick-disabled "$REMOTE_A")
  stub="$TMP_ROOT/fm-on-disabled"; write_fm_on_stub "$stub"
  if DATA="$data" FM_OVERFLOW=0 FM_OVERFLOW_FM_ON="$stub" FM_TEST_CAP_A_MATE=0 \
    bash -c '. "$1"; fm_overflow_pick' _ "$LIB" >/dev/null 2>&1; then
    fail "pick must honor FM_OVERFLOW=0"
  fi
  pass "overflow stays off under FM_OVERFLOW=0"
}

# --- project scope ------------------------------------------------------------
# A remote only qualifies for a repo-bound task when its seeded `projects:`
# field (bin/fm-remote-home-seed.sh) lists that repo; it has never cloned any
# other project and could never work it (docs/remote-secondmates.md).

REMOTE_SCOPE_OTHER='- a-mate - overflow mate (host: a-host; root: /remote/firstmate; home: /remote/home-a; scope: overflow; projects: other-project; added 2026-09-13)'
REMOTE_SCOPE_DEMO='- b-mate - overflow mate (host: b-host; root: /remote/firstmate; home: /remote/home-b; scope: overflow; projects: demo-project; added 2026-09-13)'

make_scope_data() {  # <name> <task-id> <repo> [registry-line...] -> prints data dir
  local name=$1 id=$2 repo=$3 dir line
  shift 3
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$dir/data/backlog.md"
  cat > "$dir/.tasks.toml" <<EOF
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  : > "$dir/data/secondmates.md"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$dir/data/secondmates.md"
  done
  if [ -n "$repo" ]; then
    tasks-axi add "$id" "scope test $id" --kind ship --repo "$repo" --file "$dir/data/backlog.md" >/dev/null
  else
    tasks-axi add "$id" "scope test $id" --kind ship --file "$dir/data/backlog.md" >/dev/null
  fi
  printf '%s\n' "$dir/data"
}

{
  data=$(make_scope_data scope-match t-scope-1 demo-project "$REMOTE_SCOPE_OTHER" "$REMOTE_SCOPE_DEMO")
  stub="$TMP_ROOT/fm-on-scope-match"; write_fm_on_stub "$stub"
  out=$(DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_TEST_CAP_A_MATE=0 FM_TEST_CAP_B_MATE=0 \
    bash -c '. "$1"; fm_overflow_pick "$2"' _ "$LIB" t-scope-1) \
    || fail "pick should succeed when the project-scoped remote has headroom"
  [ "$out" = "b-mate b-host" ] \
    || fail "pick must skip a-mate (projects: other-project) and choose the scoped b-mate, got: $out"
  pass "overflow skips a remote whose seeded projects exclude the task's repo"
}

{
  data=$(make_scope_data scope-none t-scope-2 demo-project "$REMOTE_SCOPE_OTHER")
  stub="$TMP_ROOT/fm-on-scope-none"; write_fm_on_stub "$stub"
  if DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_TEST_CAP_A_MATE=0 \
    bash -c '. "$1"; fm_overflow_pick "$2"' _ "$LIB" t-scope-2 >/dev/null 2>&1; then
    fail "pick must fail when every candidate's seeded projects exclude the task's repo"
  fi
  pass "overflow reports no pick when no remote's project scope includes the task's repo"
}

{
  data=$(make_scope_data scope-unset t-scope-3 "" "$REMOTE_SCOPE_OTHER")
  stub="$TMP_ROOT/fm-on-scope-unset"; write_fm_on_stub "$stub"
  out=$(DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_TEST_CAP_A_MATE=0 \
    bash -c '. "$1"; fm_overflow_pick "$2"' _ "$LIB" t-scope-3) \
    || fail "pick should still succeed on headroom alone when the task names no repo"
  [ "$out" = "a-mate a-host" ] \
    || fail "a task with no recorded repo must never be scope-restricted, got: $out"
  pass "overflow never scope-restricts a task with no recorded repo"
}

# --- handoff -----------------------------------------------------------------

{
  data=$(make_data try-ok "$REMOTE_A")
  stub="$TMP_ROOT/fm-on-try"; write_fm_on_stub "$stub"
  handoff="$TMP_ROOT/handoff-ok"; write_handoff_stub "$handoff" 0
  : > "$TMP_ROOT/try-ok.log"
  out=$(DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_OVERFLOW_HANDOFF="$handoff" \
    FM_TEST_CAP_A_MATE=0 FM_TEST_HANDOFF_LOG="$TMP_ROOT/try-ok.log" \
    bash -c '. "$1"; fm_overflow_try t1' _ "$LIB") || fail "try should succeed with headroom and a working handoff"
  [ "$out" = "routed t1 remote=a-mate host=a-host" ] || fail "try must report the landing machine, got: $out"
  [ "$(cat "$TMP_ROOT/try-ok.log")" = "a-mate t1" ] || fail "handoff must receive '<mate> <id>', got: $(cat "$TMP_ROOT/try-ok.log")"
  pass "overflow hands the item off and reports the landing machine"
}

{
  data=$(make_data try-handoff-fail "$REMOTE_A")
  stub="$TMP_ROOT/fm-on-tryfail"; write_fm_on_stub "$stub"
  handoff="$TMP_ROOT/handoff-fail"; write_handoff_stub "$handoff" 1
  : > "$TMP_ROOT/try-fail.log"
  if DATA="$data" FM_OVERFLOW_FM_ON="$stub" FM_OVERFLOW_HANDOFF="$handoff" \
    FM_TEST_CAP_A_MATE=0 FM_TEST_HANDOFF_LOG="$TMP_ROOT/try-fail.log" \
    bash -c '. "$1"; fm_overflow_try t1' _ "$LIB" >/dev/null 2>"$TMP_ROOT/try-fail.err"; then
    fail "try must fail when the handoff fails"
  fi
  grep -F 'overflow handoff:' "$TMP_ROOT/try-fail.err" >/dev/null \
    || fail "a failed handoff must stay observable on stderr"
  pass "overflow surfaces a failed handoff and refuses"
}

# --- spawn-level ---------------------------------------------------------------

make_spawn_home() {  # <name> <task-id> -> prints home dir
  local name=$1 id=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  printf '%s\n' "$REMOTE_A" > "$home/data/secondmates.md"
  tasks-axi add "$id" "overflow work $id" --kind ship --file "$home/data/backlog.md" >/dev/null
  printf '%s\n' "$home"
}

write_refusing_router() {  # <dir>
  cat > "$1/llm-router-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capacity) printf '{"ok":false,"measured":{},"reasons":["fleet is at or above the 15-agent ceiling (agents=16)"],"signals":[]}\n' ;;
esac
exit 0
SH
  chmod +x "$1/llm-router-axi"
}

run_spawn_refused() {  # <home> <id> <out-file> -> exit status
  local home=$1 id=$2 out=$3
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_LLM_ROUTER_AXI="$ROUTER_DIR/llm-router-axi" \
    FM_OVERFLOW_FM_ON="$SPAWN_FM_ON" FM_OVERFLOW_HANDOFF="$SPAWN_HANDOFF" \
    "$SPAWN" "$id" projects/nowhere --mode no-mistakes --yolo off >"$out" 2>&1
}

{
  home=$(make_spawn_home spawn-ok t-overflow-1)
  ROUTER_DIR="$TMP_ROOT/router"; mkdir -p "$ROUTER_DIR"; write_refusing_router "$ROUTER_DIR"
  SPAWN_FM_ON="$TMP_ROOT/fm-on-spawn"; write_fm_on_stub "$SPAWN_FM_ON"
  SPAWN_HANDOFF="$TMP_ROOT/handoff-spawn"; write_handoff_stub "$SPAWN_HANDOFF" 0
  : > "$TMP_ROOT/spawn-ok.log"
  export FM_TEST_CAP_A_MATE=0 FM_TEST_HANDOFF_LOG="$TMP_ROOT/spawn-ok.log"
  run_spawn_refused "$home" t-overflow-1 "$TMP_ROOT/spawn-ok.out"; rc=$?
  out=$(cat "$TMP_ROOT/spawn-ok.out")
  [ "$rc" -eq 0 ] || fail "a refused spawn with remote headroom must route, rc=$rc out: $out"
  printf '%s\n' "$out" | grep -F 'routed t-overflow-1 remote=a-mate host=a-host' >/dev/null \
    || fail "the spawn must report the landing machine, got: $out"
  [ "$(cat "$TMP_ROOT/spawn-ok.log")" = "a-mate t-overflow-1" ] || fail "the handoff must receive the refused task, got: $(cat "$TMP_ROOT/spawn-ok.log")"
  [ ! -e "$home/state/t-overflow-1.meta" ] || fail "a routed spawn must leave no local task record behind"
  pass "a refused spawn routes to the remote home and reports the machine"
}

{
  home=$(make_spawn_home spawn-full t-overflow-2)
  : > "$TMP_ROOT/spawn-full.log"
  export FM_TEST_CAP_A_MATE=1 FM_TEST_HANDOFF_LOG="$TMP_ROOT/spawn-full.log"
  run_spawn_refused "$home" t-overflow-2 "$TMP_ROOT/spawn-full.out"; rc=$?
  out=$(cat "$TMP_ROOT/spawn-full.out")
  [ "$rc" -eq 1 ] || fail "with no remote headroom the refusal must stand, rc=$rc out: $out"
  printf '%s\n' "$out" | grep -F 'overflow: task t-overflow-2 stays queued locally' >/dev/null \
    || fail "the fallback must say the work stays local, got: $out"
  [ ! -s "$TMP_ROOT/spawn-full.log" ] || fail "no handoff may run without headroom"
  pass "with no remote headroom the spawn refusal stands and stays local"
}

# A refusal caused by broken local tooling (no llm-router-axi on PATH) is not a
# genuine over-capacity verdict, so it must never be offered to a remote home:
# it would silently mask a broken capacity toolchain behind "routed ...".
{
  home=$(make_spawn_home spawn-tooling t-overflow-3)
  SPAWN_FM_ON="$TMP_ROOT/fm-on-spawn-tooling"; write_fm_on_stub "$SPAWN_FM_ON"
  SPAWN_HANDOFF="$TMP_ROOT/handoff-spawn-tooling"; write_handoff_stub "$SPAWN_HANDOFF" 0
  : > "$TMP_ROOT/spawn-tooling.log"
  export FM_TEST_CAP_A_MATE=0 FM_TEST_HANDOFF_LOG="$TMP_ROOT/spawn-tooling.log"
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_LLM_ROUTER_AXI="$TMP_ROOT/no-such-router" \
    FM_OVERFLOW_FM_ON="$SPAWN_FM_ON" FM_OVERFLOW_HANDOFF="$SPAWN_HANDOFF" \
    "$SPAWN" t-overflow-3 projects/nowhere --mode no-mistakes --yolo off \
    >"$TMP_ROOT/spawn-tooling.out" 2>&1; rc=$?
  out=$(cat "$TMP_ROOT/spawn-tooling.out")
  [ "$rc" -eq 1 ] || fail "a tooling-failure refusal must still exit non-zero, rc=$rc out: $out"
  printf '%s\n' "$out" | grep -F 'llm-router-axi is not installed' >/dev/null \
    || fail "a tooling-failure refusal must surface its own diagnostic, got: $out"
  case "$out" in
    *routed*) fail "a tooling failure must never be routed to a remote home, got: $out" ;;
    *"stays queued locally"*) fail "a tooling failure is not an overflow-eligible refusal and must not print the overflow fallback, got: $out" ;;
  esac
  [ ! -s "$TMP_ROOT/spawn-tooling.log" ] || fail "no remote handoff may run for a tooling failure"
  pass "a tooling-failure refusal never triggers remote overflow"
}

printf 'All fm-remote-overflow tests passed.\n'
