#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's gemini genuineness guard.
#
# This Mac's own PATH carries a personal ~/.local/bin/gemini compatibility shim
# that transparently execs a different harness (agy), placed ahead of the
# genuine gemini-cli (a node script under /opt/homebrew/bin) on PATH. None of
# firstmate's gemini launch wiring (GEMINI_CLI_TRUST_WORKSPACE,
# GEMINI_CLI_SYSTEM_SETTINGS_PATH carrying the busy-state/turn-end hooks
# supervision depends on) is read by whatever a shim like that actually execs,
# so dispatching through it launches an uninstrumented worker that idles at
# first turn instead of failing loudly. These tests pin the refusal (bin/fm-
# spawn.sh's gemini_binary_is_genuine, per AGENTS.md section 4's "report it and
# fall back only to a verified adapter rather than launching it") and prove the
# guard does not also block a genuine gemini-cli install.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-gemini-shim-dispatch-guard)

# drop_gemini_shim <fakebin>: the exact shape verified on this fleet - a bash
# script whose shebang is not node, that would otherwise exec a different
# harness. The guard is deliberately structural (shebang-based), so this does
# not need to actually exec anything to prove the refusal.
drop_gemini_shim() {
  local fakebin=$1
  cat > "$fakebin/gemini" <<'SH'
#!/usr/bin/env bash
# Gemini CLI compatibility shim -> some other harness. A test double for the
# shadowing shape found on this fleet's own PATH; it must never actually run.
echo "shim: this should never execute" >&2
exit 1
SH
  chmod +x "$fakebin/gemini"
}

# drop_gemini_genuine <fakebin>: a node-shebang stand-in for the real gemini-cli
# (a node bundle, verified .agents/skills/harness-adapters/references/harness/
# gemini.md). The guard only reads the shebang line, so this never needs to
# actually execute node.
drop_gemini_genuine() {
  local fakebin=$1
  cat > "$fakebin/gemini" <<'SH'
#!/usr/bin/env node
console.log("test double: this should never actually run under the fake tmux");
SH
  chmod +x "$fakebin/gemini"
}

make_gemini_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" gemini
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_gemini_ship_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5 proj=$6
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off
}

test_gemini_dispatch_refuses_a_shadowed_binary() {
  local rec id out status
  id=gemini-shadowed-z1a
  rec=$(make_gemini_spawn_case gemini-shadowed "$id")
  read_case_record "$rec"
  drop_gemini_shim "$FAKEBIN_DIR"

  out=$(run_gemini_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a shadowed gemini binary must refuse the spawn"
  assert_contains "$out" "not genuine gemini-cli" \
    "shadowed-gemini refusal did not name the genuineness problem"
  assert_contains "$out" "$FAKEBIN_DIR/gemini" \
    "shadowed-gemini refusal did not name the resolved shadowing path"
  assert_absent "$HOME_DIR/state/$id.meta" "shadowed-gemini refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "shadowed-gemini refusal typed a launch command"
  pass "fm-spawn.sh: refuses a shadowed gemini binary with a clear diagnostic instead of launching it"
}

test_gemini_dispatch_launches_a_genuine_binary() {
  local rec id out status launch
  id=gemini-genuine-z1b
  rec=$(make_gemini_spawn_case gemini-genuine "$id")
  read_case_record "$rec"
  drop_gemini_genuine "$FAKEBIN_DIR"

  out=$(run_gemini_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a genuine (node-script) gemini binary should spawn cleanly"
  assert_contains "$out" "spawned $id harness=gemini" "genuine-gemini spawn did not report gemini"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/gemini' -y" \
    "genuine-gemini launch did not pin the resolved, verified binary"
  case "$launch" in
    *' gemini -y'*) fail "genuine-gemini launch used a bare 'gemini' instead of the resolved path: $launch" ;;
  esac
  pass "fm-spawn.sh: dispatches a genuine gemini-cli binary normally"
}

test_gemini_dispatch_refuses_a_shadowed_binary
test_gemini_dispatch_launches_a_genuine_binary
