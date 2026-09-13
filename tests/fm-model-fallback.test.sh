#!/usr/bin/env bash
# Behavior tests for bin/fm-model-fallback.sh: automatic in-run model fallback
# on verified quota depletion.
#
# The step-down chain and the depletion vocabulary now live in llm-router-axi,
# so these tests drive a fake router and pin what this script still owns:
#   - it classifies evidence through the router and ignores declared-pause
#     bookkeeping
#   - it asks the router for the next move and prints one action block
#   - apply relaunches in place through fm-runtime-handoff.sh with the next
#     model and a visibility note, records the provider outcome, advances the
#     evidence cursor, logs the downgrade, and cannot double-step on the same
#     evidence - while a failure before the relaunch consumes nothing
#   - an absent router refuses loudly rather than improvising
#   - the real handoff path preserves the worktree, commits, and dirt
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FALLBACK="$ROOT/bin/fm-model-fallback.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-fallback)
fm_git_identity

# --- helpers ----------------------------------------------------------------

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_CMD:-bash}"; exit 0 ;;
  *"list-windows"*)
    if [ -n "${FM_FAKE_WINDOW_FILE:-}" ]; then
      if [ -f "${FM_FAKE_WINDOW_FILE}" ]; then printf '%s\n' "${FM_FAKE_EXISTING_WINDOW:-${FM_FAKE_WINDOW_NAME:-fm-task}}"; fi
    elif [ "${FM_FAKE_WINDOW_PRESENT:-0}" = 1 ]; then
      printf '%s\n' "${FM_FAKE_WINDOW_NAME:-fm-task}"
    fi
    exit 0 ;;
esac
case "${1:-}" in
  kill-window) exit 0 ;;
  *capture-pane*) printf '%s\n' '? for shortcuts' ; exit 0 ;;
  display-message) printf '%s\n' "${FM_FAKE_SESSION:-firstmate}" ; exit 0 ;;
  has-session|new-session|set-window-option|send-keys) exit 0 ;;
  new-window) printf '@9\n' ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  for tool in pi-signed opencode cline copilot agy cursor cursor-agent muse grok kimi pi codex claude; do
    fm_fake_exit0 "$fakebin" "$tool"
  done
  printf '%s\n' "$fakebin"
}

# make_bin_farm <case-dir> [stub-handoff]: symlinks to the REAL bin scripts,
# with fm-send.sh always stubbed and, when stub-handoff=1, fm-runtime-handoff.sh
# replaced by an argument-recording stub.
make_bin_farm() {
  local dir=$1 stub_handoff=${2:-0} src farm
  farm="$dir/binfarm"
  mkdir -p "$farm/backends" "$farm/quota-sources"
  for src in "$ROOT"/bin/*; do
    [ -f "$src" ] || continue
    ln -sf "$src" "$farm/${src##*/}"
  done
  for src in "$ROOT"/bin/backends/*; do
    [ -f "$src" ] || continue
    ln -sf "$src" "$farm/backends/${src##*/}"
  done
  for src in "$ROOT"/bin/quota-sources/*; do
    [ -f "$src" ] || continue
    ln -sf "$src" "$farm/quota-sources/${src##*/}"
  done
  rm -f "$farm/fm-send.sh"
  cat > "$farm/fm-send.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$farm/fm-send.sh"
  if [ "$stub_handoff" = 1 ]; then
    rm -f "$farm/fm-runtime-handoff.sh"
    cat > "$farm/fm-runtime-handoff.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HANDOFF_LOG:-/dev/null}"
[ "${FM_STUB_HANDOFF_RC:-0}" = 0 ] || exit "${FM_STUB_HANDOFF_RC}"
id=$1
shift
model=
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model=$2; shift 2 ;;
    *) shift ;;
  esac
done
meta="${FM_HOME:?}/state/${id}.meta"
if [ -f "$meta" ] && [ -n "$model" ]; then
  tmp=$(mktemp)
  { grep -v '^model=' "$meta"; printf 'model=%s\n' "$model"; } > "$tmp" && mv "$tmp" "$meta"
fi
[ -z "${FM_STUB_HANDOFF_STATUS_APPEND:-}" ] || printf '%s\n' "$FM_STUB_HANDOFF_STATUS_APPEND" >> "${FM_HOME:?}/state/$id.status"
exit 0
SH
    chmod +x "$farm/fm-runtime-handoff.sh"
  fi
  printf '%s\n' "$farm"
}

# install_fake_router <case-dir> <classify-output-file> <chain-json-file>:
# a fake llm-router-axi that answers the verbs fm-model-fallback.sh calls.
install_fake_router() {
  local dir=$1 classify=$2 chain=$3
  cat > "$dir/llm-router-axi" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  classify-evidence)
    input=\$(cat)
    if [ -z "\$input" ]; then printf 'classification=none\n'; else cat "$classify"; fi
    exit 0 ;;
  route)
    printf '%s\n' "\$*" >> "$dir/route.calls"
    cat "$chain"; exit 0 ;;
  record)
    printf '%s\n' "\$*" >> "$dir/record.calls"; exit 0 ;;
  capacity)
    printf '{"ok":true,"measured":{},"reasons":[],"signals":[]}\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$dir/llm-router-axi"
}

# setup_case <name> <id> <chain-json-or-empty> <status-text-or-empty> <classification-or-empty>:
# home + project + task worktree with a landed commit and dirty file, a fake
# router, and the task status log.
setup_case() {  # <name> <id> <chain-json> <status-body> [classification]
  local name=$1 id=$2 chain=$3 status_body=$4 classification=${5:-none}
  CASE_DIR="$TMP_ROOT/$name"
  CASE_HOME="$CASE_DIR/home"
  CASE_PROJ="$CASE_DIR/project"
  CASE_WT="$CASE_DIR/wt"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/data/$id" "$CASE_HOME/config" "$CASE_HOME/projects"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "fm/$id"
  printf 'commit-body\n' > "$CASE_WT/feature.txt"
  git -C "$CASE_WT" add feature.txt
  git -C "$CASE_WT" commit -qm 'task work'
  printf 'uncommitted\n' > "$CASE_WT/dirty.txt"
  printf '%s\n' '# Task' '' "## Captain's intent" '' "Preserve the existing worktree for $id." '' \
    '## Firstmate spec' '' 'Relaunch in place with the recorded endpoint.' \
    > "$CASE_HOME/data/$id/brief.md"
  [ -n "$status_body" ] && printf '%s\n' "$status_body" > "$CASE_HOME/state/$id.status"

  printf '%s\n' "classification=$classification" > "$CASE_DIR/classify.txt"
  [ "$classification" = depleted ] && printf '%s\n' 'signature="Error 429 - Resource Exhausted"' >> "$CASE_DIR/classify.txt"
  [ -n "$chain" ] || chain='{"action":"exhausted","harness":"agy","chain":[],"fallbackLanes":[]}'
  printf '%s\n' "$chain" > "$CASE_DIR/chain.json"
  install_fake_router "$CASE_DIR" "$CASE_DIR/classify.txt" "$CASE_DIR/chain.json"

  fakebin=$(make_fakebin "$CASE_DIR")
  export FM_LLM_ROUTER_AXI="$CASE_DIR/llm-router-axi"
  export FM_HOME="$CASE_HOME"
  export FM_FAKE_PANE_PATH="$CASE_WT"
  export FM_FAKE_TREEHOUSE_WT="$CASE_WT"
  export FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log"
  export FM_FAKE_HANDOFF_LOG="$CASE_DIR/handoff.log"
  export FM_FAKE_SESSION=firstmate
  export FM_FAKE_WINDOW_NAME="fm-$id"
  export FM_FAKE_WINDOW_PRESENT=0
  export FM_FAKE_PANE_CMD=bash
  export FM_STUB_HANDOFF_RC=0
  export PATH="$fakebin:$PATH"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=agy" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "model=gemini-3.7-flash-high" \
    "effort=high" \
    "pr=https://example.test/pr/9"
}

STEP_CHAIN='{"action":"harness-step","harness":"agy","fromModel":"gemini-3.7-flash-high","toModel":"gemini-3.6-flash-high","chain":["gemini-3.7-flash-high","gemini-3.6-flash-high","gemini-3.5-flash-high"]}'
EXHAUSTED_CHAIN='{"action":"exhausted","harness":"agy","fromModel":"gemini-3.7-flash-high","reason":"every model in the '"'"'agy'"'"' chain is depleted and no fallbackLanes successor exists","chain":["gemini-3.7-flash-high"],"fallbackLanes":[]}'
DEPLETED_LINE='working: hit API Error 429 - Resource Exhausted: Quota exceeded for metric'

# --- evidence routing ---------------------------------------------------------

{
  setup_case noevidence plan-e1 "$STEP_CHAIN" 'working: making steady progress on the brief' none
  out=$("$FALLBACK" plan-e1 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "healthy-worker plan should stay quiet-successful, rc=$rc: $out"
  assert_contains "$out" "action=none" "healthy worker plans nothing"
  if out=$("$FALLBACK" plan-e1 apply 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || fail "apply without evidence must refuse, rc=$rc"
  assert_contains "$out" "no depletion evidence" "apply-without-evidence refusal"
  pass "a healthy worker is never relaunched by fallback: no evidence, no action"
}

{
  setup_case depleted plan-e2 "$STEP_CHAIN" "$DEPLETED_LINE" depleted
  out=$("$FALLBACK" plan-e2 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "depleted plan should succeed, rc=$rc: $out"
  assert_contains "$out" "action=harness-step" "the router's step is reported"
  assert_contains "$out" "to_model=gemini-3.6-flash-high" "plan reports the router's next model"
  assert_contains "$out" 'signature="Error 429 - Resource Exhausted"' "plan reports the router's matched signature"
  grep -q '^fallback_cursor=' "$CASE_HOME/state/plan-e2.meta" && fail "plan must be read-only over meta"
  pass "plan delegates depletion and the step-down decision to the router"
}

# A paused: line is the declared external-wait verb; depletion words inside it
# must never read as live evidence.
PAUSED_BOOKKEEPING_LINE='paused: session exited on purpose (OpenCode balance exhausted); awaiting external: CRM rate-limit'
{
  setup_case paused plan-e3 "$STEP_CHAIN" "$PAUSED_BOOKKEEPING_LINE" depleted
  out=$("$FALLBACK" plan-e3 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "paused-bookkeeping plan should stay quiet-successful, rc=$rc: $out"
  assert_contains "$out" "action=none" "a declared-pause line plans nothing without sending evidence to the router"
  pass "firstmate's own paused: bookkeeping is never read as depletion evidence"
}

{
  setup_case paused-then-real plan-e4 "$STEP_CHAIN" "$PAUSED_BOOKKEEPING_LINE" depleted
  printf '%s\n' "$DEPLETED_LINE" >> "$CASE_HOME/state/plan-e4.status"
  out=$("$FALLBACK" plan-e4 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "real evidence after a paused line should still plan, rc=$rc: $out"
  assert_contains "$out" "action=harness-step" "genuine live evidence after a paused line still plans"
  pass "filtering paused: bookkeeping never hides genuine evidence that follows it"
}

# --- router failures and refusals --------------------------------------------

{
  setup_case exhausted plan-r1 "$EXHAUSTED_CHAIN" "$DEPLETED_LINE" depleted
  if out=$("$FALLBACK" plan-r1 plan 2>/dev/null); then rc=0; else rc=$?; fi
  [ "$rc" -eq 3 ] || fail "exhausted plan should exit 3, got rc=$rc: $out"
  assert_contains "$out" "action=exhausted" "exhaustion is reported"
  pass "an exhausted router chain exits 3 without improvising a model"
}

{
  setup_case no-router plan-r2 "$STEP_CHAIN" "$DEPLETED_LINE" depleted
  export FM_LLM_ROUTER_AXI="$CASE_DIR/does-not-exist"
  if out=$("$FALLBACK" plan-r2 plan 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || fail "an absent router should refuse, rc=$rc: $out"
  assert_contains "$out" "llm-router-axi is not installed" "absent-router message"
  export FM_LLM_ROUTER_AXI="$CASE_DIR/llm-router-axi"
  pass "an absent router refuses loudly rather than improvising a step-down"
}

{
  setup_case secondmate plan-r3 "$STEP_CHAIN" "$DEPLETED_LINE" depleted
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$CASE_HOME/state/plan-r3.meta"
  rm -f "$CASE_HOME/state/plan-r3.meta.bak"
  if out=$("$FALLBACK" plan-r3 plan 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || fail "secondmate should refuse, rc=$rc"
  assert_contains "$out" "ship and scout tasks only" "secondmate refusal message"
  pass "refuses a secondmate; its recovery is a different owner"
}

# --- apply through the stubbed handoff --------------------------------------

{
  setup_case apply-step apply-a1 "$STEP_CHAIN" "$DEPLETED_LINE" depleted
  : > "$FM_FAKE_HANDOFF_LOG"
  evidence_size=$(wc -c < "$CASE_HOME/state/apply-a1.status" | tr -d ' ')
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$(make_bin_farm "$CASE_DIR" 1)/fm-model-fallback.sh" apply-a1 apply 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "apply should succeed, rc=$rc: $out"

  handoff_args=$(cat "$FM_FAKE_HANDOFF_LOG")
  assert_contains "$handoff_args" "apply-a1" "handoff addressed the exact task"
  assert_contains "$handoff_args" "--harness agy" "same-harness step stays in the lane"
  assert_contains "$handoff_args" "--model gemini-3.6-flash-high" "handoff carries the router's next model"
  assert_contains "$handoff_args" "--progress-note Automatic model fallback" "visibility note travels to the replacement worker"

  meta=$(cat "$CASE_HOME/state/apply-a1.meta")
  assert_contains "$meta" "fallback_cursor=$evidence_size" "cursor lands at the consumed evidence boundary"
  status_log=$(cat "$CASE_HOME/state/apply-a1.status")
  assert_contains "$status_log" "working: automatic model fallback gemini-3.7-flash-high -> gemini-3.6-flash-high" "downgrade logged as a working event"
  record_calls=$(cat "$CASE_DIR/record.calls" 2>/dev/null || true)
  assert_contains "$record_calls" "--provider agy" "depleted native provider is recorded for cooldown"
  assert_contains "$record_calls" "--outcome rate_limit" "the recorded outcome is a rate limit"
  pass "apply relaunches in place with the next model, logs the downgrade, records the provider, and consumes the evidence"
}

{
  setup_case apply-idempotent apply-a2 "$STEP_CHAIN" "$DEPLETED_LINE" depleted
  farm=$(make_bin_farm "$CASE_DIR" 1)
  : > "$FM_FAKE_HANDOFF_LOG"
  FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a2 apply >/dev/null 2>&1 \
    || fail "first apply should succeed"
  if out=$(FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a2 apply 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "second apply on consumed evidence must refuse: $out"
  assert_contains "$out" "no depletion evidence" "second-apply refusal names the cursor guard"
  pass "the same evidence can never trigger a second step-down"
}

{
  setup_case apply-fresh apply-a3 "$STEP_CHAIN" "$DEPLETED_LINE" depleted
  farm=$(make_bin_farm "$CASE_DIR" 1)
  : > "$FM_FAKE_HANDOFF_LOG"
  FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a3 apply >/dev/null 2>&1 \
    || fail "first apply should succeed"
  printf '%s\n' "$DEPLETED_LINE" >> "$CASE_HOME/state/apply-a3.status"
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a3 apply 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "fresh-evidence apply should step again, rc=$rc: $out"
  pass "new depletion evidence after the cursor is actioned again"
}

{
  setup_case apply-failure apply-a5 "$STEP_CHAIN" "$DEPLETED_LINE" depleted
  farm=$(make_bin_farm "$CASE_DIR" 1)
  : > "$FM_FAKE_HANDOFF_LOG"
  if out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STUB_HANDOFF_RC=1 "$farm/fm-model-fallback.sh" apply-a5 apply 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || fail "failed relaunch should surface failure, rc=$rc: $out"
  assert_contains "$out" "in-place fallback relaunch failed" "failure names the stage"
  grep -q '^fallback_cursor=' "$CASE_HOME/state/apply-a5.meta" \
    && fail "a failed relaunch must not consume the evidence"
  pass "when the relaunch fails, the evidence stays unconsumed for the retry supervisor"
}

{
  setup_case apply-exhausted apply-a4 "$EXHAUSTED_CHAIN" "$DEPLETED_LINE" depleted
  farm=$(make_bin_farm "$CASE_DIR" 1)
  : > "$FM_FAKE_HANDOFF_LOG"
  if out=$(FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a4 apply 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 3 ] || fail "exhausted apply should exit 3, rc=$rc: $out"
  [ ! -s "$FM_FAKE_HANDOFF_LOG" ] || fail "exhaustion must not launch anything"
  status_log=$(cat "$CASE_HOME/state/apply-a4.status")
  assert_contains "$status_log" "blocked: model fallback exhausted for agy" "exhaustion surfaces as a blocked event"
  cursor=$(sed -n 's/^fallback_cursor=//p' "$CASE_HOME/state/apply-a4.meta")
  status_size=$(wc -c < "$CASE_HOME/state/apply-a4.status" | tr -d ' ')
  [ "$cursor" = "$status_size" ] || fail "exhaustion must consume its evidence ($cursor != $status_size)"
  if out=$(FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a4 apply 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || fail "consumed exhausted evidence must not re-block, rc=$rc: $out"
  assert_contains "$out" "no depletion evidence" "second exhausted apply respects the cursor"
  pass "full exhaustion consumes evidence before blocking, and never blocks twice on it"
}

# --- apply over the REAL handoff path ---------------------------------------

{
  setup_case apply-real apply-r1 "$STEP_CHAIN" "$DEPLETED_LINE" depleted
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=bash
  head_before=$(git -C "$CASE_WT" rev-parse HEAD)
  dirty_before=$(cat "$CASE_WT/dirty.txt")
  farm=$(make_bin_farm "$CASE_DIR" 0)
  if out=$(FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_SETTLE_POLLS=2 "$farm/fm-model-fallback.sh" apply-r1 apply 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] || fail "real-path apply should succeed: $out"
  [ "$(git -C "$CASE_WT" rev-parse HEAD)" = "$head_before" ] || fail "fallback must preserve HEAD"
  [ "$(cat "$CASE_WT/dirty.txt")" = "$dirty_before" ] || fail "fallback must preserve uncommitted changes"
  meta=$(cat "$CASE_HOME/state/apply-r1.meta")
  assert_contains "$meta" "model=gemini-3.6-flash-high" "meta records the stepped-down model"
  assert_contains "$meta" "harness=agy" "same-harness step keeps the harness"
  assert_contains "$meta" "pr=https://example.test/pr/9" "non-owned meta keys survive"
  prompt=$(cat "$CASE_HOME/state/apply-r1.handoff-prompt")
  assert_contains "$prompt" "Automatic model fallback" "replacement worker inherits the downgrade note"
  pass "over the real handoff path, fallback preserves the worktree and work while stepping the model down"
}

printf 'All fm-model-fallback tests passed.\n'
