#!/usr/bin/env bash
# Behavior tests for bin/fm-model-fallback.sh: automatic in-run model fallback
# on verified quota depletion.
#
# Guarantees under test:
#   - classify-evidence owns one depletion vocabulary: every subscription-
#     exhaustion signature classifies depleted; context-window, tool-output,
#     auth, and unframed codes never do
#   - plan walks the configured chain in order: entry-after-current, chain
#     head for an out-of-chain model, exhaustion at the tail, legacy alias
#   - an exhausted chain moves to the next fallbackLanes entry, starting that
#     lane's own chain head, and reports exhaustion when no lane follows
#   - malformed configuration refuses loudly instead of improvising
#   - apply relaunches in place through fm-runtime-handoff.sh with the next
#     model and a visibility note, records the provider cooldown, advances the
#     evidence cursor, logs the downgrade, and cannot double-step on the same
#     evidence - while a failure before the relaunch consumes nothing
#   - the real handoff path preserves the worktree, commits, and dirt
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FALLBACK="$ROOT/bin/fm-model-fallback.sh"
SELECTOR="$ROOT/bin/fm-dispatch-select.mjs"
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
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  *"#{pane_current_command}"*)
    printf '%s\n' "${FM_FAKE_PANE_CMD:-bash}"
    exit 0
    ;;
  *"list-windows"*)
    if [ -n "${FM_FAKE_WINDOW_FILE:-}" ]; then
      if [ -f "${FM_FAKE_WINDOW_FILE}" ]; then
        printf '%s\n' "${FM_FAKE_EXISTING_WINDOW:-${FM_FAKE_WINDOW_NAME:-fm-task}}"
      fi
    elif [ "${FM_FAKE_WINDOW_PRESENT:-0}" = 1 ]; then
      printf '%s\n' "${FM_FAKE_WINDOW_NAME:-fm-task}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  kill-window) exit 0 ;;
  # agy's project-trust readiness gate polls capture-pane for a past-trust
  # anchor; answer with the idle bar so a stubbed agy launch reads ready.
  *capture-pane*) printf '%s\n' '? for shortcuts' ; exit 0 ;;
  display-message) printf '%s\n' "${FM_FAKE_SESSION:-firstmate}" ; exit 0 ;;
  has-session|new-session|set-window-option|send-keys) exit 0 ;;
  new-window) printf '@9\n' ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  # Stub every admitted harness so no case depends on installed CLIs.
  for tool in pi-signed opencode cline copilot agy cursor cursor-agent muse grok kimi pi codex claude; do
    fm_fake_exit0 "$fakebin" "$tool"
  done

  printf '%s\n' "$fakebin"
}

# make_bin_farm <case-dir> [stub-handoff]: symlinks to the REAL bin scripts,
# with fm-send.sh always stubbed and, when stub-handoff=1, fm-runtime-handoff.sh
# replaced by an argument-recording stub. Running the fallback THROUGH the farm
# makes its absolute sibling invocations resolve here.
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
set -u
printf '%s\n' "$*" >> "${FM_FAKE_SEND_LOG:-/dev/null}"
[ -z "${FM_FAKE_SEND_MARKS_EXIT:-}" ] || : > "$FM_FAKE_SEND_MARKS_EXIT"
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
# Publish the model axis like the real handoff's spawn step does, so a follow-up
# run reads the stepped-down model from the durable record, not stale state.
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
exit 0
SH
    chmod +x "$farm/fm-runtime-handoff.sh"
  fi
  printf '%s\n' "$farm"
}

# setup_case <name> <id> <config-json-or-empty> <status-text-or-empty>:
# home + project + task worktree with a landed commit and dirty file, plus the
# given crew-dispatch.json body and task status log.
setup_case() {  # <name> <id> <config-body> <status-body>
  local name=$1 id=$2 config_body=$3 status_body=$4 fakebin
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
  printf '# brief for %s\n' "$id" > "$CASE_HOME/data/$id/brief.md"
  if [ -n "$config_body" ]; then
    printf '%s\n' "$config_body" > "$CASE_HOME/config/crew-dispatch.json"
  fi
  if [ -n "$status_body" ]; then
    printf '%s\n' "$status_body" > "$CASE_HOME/state/$id.status"
  fi
  fakebin=$(make_fakebin "$CASE_DIR")
  export FM_HOME="$CASE_HOME"
  export FM_FAKE_PANE_PATH="$CASE_WT"
  export FM_FAKE_TREEHOUSE_WT="$CASE_WT"
  export FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  export FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log"
  export FM_FAKE_SEND_LOG="$CASE_DIR/send.log"
  export FM_FAKE_HANDOFF_LOG="$CASE_DIR/handoff.log"
  export FM_FAKE_SESSION=firstmate
  export FM_FAKE_WINDOW_NAME="fm-$id"
  export FM_FAKE_WINDOW_PRESENT=0
  export FM_FAKE_PANE_CMD=bash
  export FM_FAKE_EXISTING_WINDOW=
  export FM_FAKE_WINDOW_FILE=
  export FM_FAKE_EXIT_MARKER=
  export FM_FAKE_SEND_MARKS_EXIT=
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

AGY_CHAIN_CONFIG='{"default":{"harness":"agy"},"modelFallback":{"agy":["gemini-3.7-flash-high","gemini-3.6-flash-high","gemini-3.5-flash-high"],"cursor":["cursor-grok-4.6-high","auto"]},"fallbackLanes":["agy","cursor","opencode"]}'
LEGACY_ALIAS_CONFIG='{"default":{"harness":"agy"},"_model_fallback":{"agy":["gemini-3.7-flash-high","gemini-3.6-flash-high"]}}'
DEPLETED_LINE='working: hit API Error 429 - Resource Exhausted: Quota exceeded for metric'

# --- classify-evidence: one depletion vocabulary -----------------------------

run_classify() {  # <text>
  printf '%s' "$1" | FM_HOME=/tmp/nonexistent-home-for-classify "$SELECTOR" classify-evidence
}

{
  out=$(run_classify 'Error 429: quota exceeded for model gemini-3.7-flash')
  assert_contains "$out" "classification=depleted" "framed 429 classifies depleted"
  pass "classify: framed 429 => depleted"
}
{
  out=$(run_classify 'RESOURCE_EXHAUSTED: Quota exceeded for metric')
  assert_contains "$out" "classification=depleted" "RESOURCE_EXHAUSTED classifies depleted"
  pass "classify: RESOURCE_EXHAUSTED => depleted"
}
{
  out=$(run_classify 'API Error 403 - spending limit reached for this organization')
  assert_contains "$out" "classification=depleted" "403 spending limit classifies depleted"
  pass "classify: 403 spending limit => depleted"
}
{
  out=$(run_classify 'insufficient credits remaining for this account')
  assert_contains "$out" "classification=depleted" "insufficient credits classifies depleted"
  pass "classify: insufficient credits => depleted"
}
{
  out=$(run_classify 'Your credit balance is too low to run this request')
  assert_contains "$out" "classification=depleted" "credit balance too low classifies depleted"
  pass "classify: credit balance too low => depleted"
}
{
  out=$(run_classify 'rate limit exceeded, retry later')
  assert_contains "$out" "classification=depleted" "rate limit classifies depleted"
  pass "classify: explicit rate limit => depleted"
}
{
  out=$(run_classify 'context token limit reached; compacting conversation')
  case "$out" in
    *classification=depleted*) fail "a context-window ceiling must never read as depletion: $out" ;;
  esac
  pass "classify: context token ceiling => none (ordinary working state)"
}
{
  out=$(run_classify 'exceeded the tool output limit of 32000 characters')
  case "$out" in
    *classification=depleted*) fail "a tool-output ceiling must never read as depletion: $out" ;;
  esac
  pass "classify: tool-output ceiling => none"
}
{
  out=$(run_classify 'request failed with HTTP 403 Forbidden')
  case "$out" in
    *classification=depleted*) fail "a plain authorization 403 must never read as depletion: $out" ;;
  esac
  pass "classify: plain authorization 403 => none"
}
{
  out=$(run_classify 'a bare 429 with no framing words around it must never park a provider')
  case "$out" in
    *classification=depleted*) fail "an unframed 429 must never read as depletion: $out" ;;
  esac
  pass "classify: unframed 429 => none"
}

# --- plan: chain traversal ---------------------------------------------------

{
  setup_case plan-mid plan-p1 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  out=$("$FALLBACK" plan-p1 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "mid-chain plan should succeed, rc=$rc: $out"
  assert_contains "$out" "action=harness-step" "plan names a harness step"
  assert_contains "$out" "from_model=gemini-3.7-flash-high" "plan names the depleted model"
  assert_contains "$out" "to_model=gemini-3.6-flash-high" "plan steps to the NEXT chain entry"
  grep -q '^fallback_cursor=' "$CASE_HOME/state/plan-p1.meta" && fail "plan must be read-only over meta"
  pass "plan walks the chain to the entry after the current model"
}

{
  setup_case plan-head plan-p2 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  fm_write_meta "$CASE_HOME/state/plan-p2.meta" \
    "window=firstmate:fm-plan-p2" \
    "endpoint_task_id=plan-p2" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=agy" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off" \
    "model=default"
  out=$("$FALLBACK" plan-p2 plan 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "head plan should succeed, rc=$rc: $out"
  assert_contains "$out" "action=harness-step" "out-of-chain model plans a step"
  assert_contains "$out" "to_model=gemini-3.7-flash-high" "out-of-chain model starts at the chain head"
  pass "plan starts an out-of-chain (default) model at the strongest configured entry"
}

{
  setup_case plan-tail plan-p3 '{"default":{"harness":"agy"},"modelFallback":{"agy":["gemini-3.7-flash-high","gemini-3.6-flash-high","gemini-3.5-flash-high"]}}' "$DEPLETED_LINE"
  sed -i.bak 's/^model=.*/model=gemini-3.5-flash-high/' "$CASE_HOME/state/plan-p3.meta"
  rm -f "$CASE_HOME/state/plan-p3.meta.bak"
  out=$("$FALLBACK" plan-p3 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 3 ] || fail "exhausted plan should exit 3, got rc=$rc: $out"
  assert_contains "$out" "action=exhausted" "tail-of-chain plans exhaustion"
  pass "plan reports exhaustion at the chain tail with exit 3"
}

{
  setup_case plan-lane plan-p4 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  sed -i.bak 's/^model=.*/model=gemini-3.5-flash-high/' "$CASE_HOME/state/plan-p4.meta"
  rm -f "$CASE_HOME/state/plan-p4.meta.bak"
  out=$("$FALLBACK" plan-p4 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "lane-move plan should succeed, rc=$rc: $out"
  assert_contains "$out" "action=lane-move" "chain tail with lanes plans a lane move"
  assert_contains "$out" "to_harness=cursor" "lane order decides the successor runtime"
  assert_contains "$out" "to_model=cursor-grok-4.6-high" "successor lane starts at its own chain head"
  pass "an exhausted chain moves to the next configured lane's chain head"
}

{
  setup_case plan-lane-default plan-p5 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  # cursor's chain walks out and the NEXT lane (opencode) has no configured
  # chain of its own: the move still happens, launching that lane on whatever
  # its own default model resolves to.
  fm_write_meta "$CASE_HOME/state/plan-p5.meta" \
    "window=firstmate:fm-plan-p5" \
    "endpoint_task_id=plan-p5" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=cursor" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "model=auto"
  out=$("$FALLBACK" plan-p5 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "chainless-successor plan should succeed, rc=$rc: $out"
  assert_contains "$out" "action=lane-move" "exhausted cursor plans a lane move"
  assert_contains "$out" "to_harness=opencode" "lane order supplies the successor"
  grep -q '^to_model=$' <<< "$out" || fail "a lane with no chain must launch on its default, got: $out"
  pass "moving to a lane with no configured chain launches on that lane's default model"
}

{
  LANES_TAIL_CONFIG='{"default":{"harness":"agy"},"modelFallback":{"agy":["gemini-3.7-flash-high","gemini-3.6-flash-high"],"cursor":["cursor-grok-4.6-high","auto"],"opencode":["x-preview-f-free","big-pickle"]},"fallbackLanes":["agy","cursor","opencode"]}'
  setup_case plan-final plan-p5b "$LANES_TAIL_CONFIG" "$DEPLETED_LINE"
  fm_write_meta "$CASE_HOME/state/plan-p5b.meta" \
    "window=firstmate:fm-plan-p5b" \
    "endpoint_task_id=plan-p5b" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=opencode" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "model=big-pickle"
  out=$("$FALLBACK" plan-p5b plan 2>/dev/null); rc=$?
  [ "$rc" -eq 3 ] || fail "fully exhausted plan should exit 3, got rc=$rc: $out"
  assert_contains "$out" "action=exhausted" "final lane's tail reports exhaustion"
  pass "walking out the final configured lane reports exhaustion rather than wrapping"
}

{
  setup_case plan-legacy plan-p6 "$LEGACY_ALIAS_CONFIG" "$DEPLETED_LINE"
  out=$("$FALLBACK" plan-p6 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "legacy alias plan should succeed, rc=$rc: $out"
  assert_contains "$out" "to_model=gemini-3.6-flash-high" "legacy alias walks the same chain"
  pass "_model_fallback remains a first-class spelling of the chain"
}

# --- refusals ----------------------------------------------------------------

{
  setup_case refuse-noconfig plan-r1 "" "$DEPLETED_LINE"
  out=$("$FALLBACK" plan-r1 plan 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "missing config should refuse, rc=$rc"
  assert_contains "$out" "no crew-dispatch config" "missing config message"
  pass "refuses when no crew-dispatch.json exists"
}

{
  setup_case refuse-malformed plan-r2 '{"modelFallback": broken' "$DEPLETED_LINE"
  out=$("$FALLBACK" plan-r2 plan 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "malformed config should refuse, rc=$rc"
  assert_contains "$out" "malformed JSON" "malformed config message"
  pass "refuses malformed config loudly instead of selecting around it"
}

{
  setup_case refuse-duplicate plan-r2b '{"modelFallback":{"agy":["gemini-3.7-flash-high","gemini-3.6-flash-high","gemini-3.7-flash-high"]}}' "$DEPLETED_LINE"
  out=$("$FALLBACK" plan-r2b plan 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "duplicate chain should refuse, rc=$rc: $out"
  assert_contains "$out" "duplicate model ids" "duplicate chain message"
  pass "refuses duplicate chain ids at fallback execution time"
}

{
  setup_case refuse-nochain plan-r3 '{"modelFallback":{"claude":["sonnet"]}}' "$DEPLETED_LINE"
  out=$("$FALLBACK" plan-r3 plan 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "missing chain should refuse, rc=$rc"
  assert_contains "$out" "no modelFallback chain configured for harness 'agy'" "missing chain message"
  pass "refuses a harness with no configured chain"
}

{
  setup_case refuse-noevidence plan-r4 "$AGY_CHAIN_CONFIG" 'working: making steady progress on the brief'
  out=$("$FALLBACK" plan-r4 plan 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "healthy-worker plan should stay quiet-successful, rc=$rc: $out"
  assert_contains "$out" "action=none" "healthy worker plans nothing"
  if out=$("$FALLBACK" plan-r4 apply 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] || fail "apply without evidence must refuse, rc=$rc"
  assert_contains "$out" "no depletion evidence" "apply-without-evidence refusal"
  pass "a healthy worker is never relaunched by fallback: no evidence, no action"
}

{
  setup_case refuse-secondmate plan-r5 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$CASE_HOME/state/plan-r5.meta"
  rm -f "$CASE_HOME/state/plan-r5.meta.bak"
  out=$("$FALLBACK" plan-r5 plan 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "secondmate should refuse, rc=$rc"
  assert_contains "$out" "ship and scout tasks only" "secondmate refusal message"
  pass "refuses a secondmate; its recovery is a different owner"
}

# --- apply through the stubbed handoff --------------------------------------

{
  setup_case apply-step apply-a1 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  : > "$FM_FAKE_HANDOFF_LOG"
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$(make_bin_farm "$CASE_DIR" 1)/fm-model-fallback.sh" apply-a1 apply 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "apply should succeed, rc=$rc: $out"

  handoff_args=$(cat "$FM_FAKE_HANDOFF_LOG")
  assert_contains "$handoff_args" "apply-a1" "handoff addressed the exact task"
  assert_contains "$handoff_args" "--harness agy" "same-harness step stays in the lane"
  assert_contains "$handoff_args" "--model gemini-3.6-flash-high" "handoff carries the NEXT model"
  assert_contains "$handoff_args" "--progress-note Automatic model fallback" "visibility note travels to the replacement worker"
  assert_contains "$handoff_args" 'depletion evidence ("Error 429")' "note names the matched evidence signature"

  meta=$(cat "$CASE_HOME/state/apply-a1.meta")
  size=$(wc -c < "$CASE_HOME/state/apply-a1.status" | tr -d ' ')
  assert_contains "$meta" "fallback_cursor=$size" "cursor lands exactly at the log end"
  status_log=$(cat "$CASE_HOME/state/apply-a1.status")
  assert_contains "$status_log" "working: automatic model fallback gemini-3.7-flash-high -> gemini-3.6-flash-high" "downgrade logged as a working event"
  assert_contains "$status_log" "auto-step-down logged per standing quota rule" "step-down rule cited for visibility"

  routing_state="$CASE_HOME/state/.dispatch-routing.json"
  [ -f "$routing_state" ] || fail "record-failure should have parked the depleted telemetry provider"
  assert_contains "$(cat "$routing_state")" '"agy"' "agy cooldown recorded for dispatch pricing"
  pass "apply relaunches in place with the next model, logs the downgrade, parks the provider, and consumes the evidence"
}

{
  setup_case apply-idempotent apply-a2 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  farm=$(make_bin_farm "$CASE_DIR" 1)
  : > "$FM_FAKE_HANDOFF_LOG"
  FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a2 apply >/dev/null 2>&1 \
    || fail "first apply should succeed"
  first_calls=$(wc -l < "$FM_FAKE_HANDOFF_LOG" | tr -d ' ')
  if out=$(FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a2 apply 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "second apply on consumed evidence must refuse: $out"
  assert_contains "$out" "no depletion evidence" "second-apply refusal names the cursor guard"
  second_calls=$(wc -l < "$FM_FAKE_HANDOFF_LOG" | tr -d ' ')
  [ "$second_calls" = "$first_calls" ] || fail "consumed evidence must not trigger another relaunch ($first_calls -> $second_calls)"
  pass "the same evidence can never trigger a second step-down"
}

{
  setup_case apply-fresh apply-a3 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  farm=$(make_bin_farm "$CASE_DIR" 1)
  : > "$FM_FAKE_HANDOFF_LOG"
  FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a3 apply >/dev/null 2>&1 \
    || fail "first apply should succeed"
  printf 'working: gemini-3.6-flash-high also returned 429 quota exceeded\n' >> "$CASE_HOME/state/apply-a3.status"
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a3 apply 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "fresh-evidence apply should step again, rc=$rc: $out"
  handoff_args=$(cat "$FM_FAKE_HANDOFF_LOG")
  assert_contains "$handoff_args" "--model gemini-3.5-flash-high" "fresh evidence walks to the third entry"
  pass "new depletion evidence after the cursor continues down the chain"
}

{
  LANES_TAIL_CONFIG='{"default":{"harness":"agy"},"modelFallback":{"agy":["gemini-3.7-flash-high","gemini-3.6-flash-high"],"cursor":["cursor-grok-4.6-high","auto"],"opencode":["x-preview-f-free","big-pickle"]},"fallbackLanes":["agy","cursor","opencode"]}'
  setup_case apply-exhausted apply-a4 "$LANES_TAIL_CONFIG" "$DEPLETED_LINE"
  fm_write_meta "$CASE_HOME/state/apply-a4.meta" \
    "window=firstmate:fm-apply-a4" \
    "endpoint_task_id=apply-a4" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=opencode" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "model=big-pickle"
  farm=$(make_bin_farm "$CASE_DIR" 1)
  : > "$FM_FAKE_HANDOFF_LOG"
  if out=$(FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-model-fallback.sh" apply-a4 apply 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 3 ] || fail "exhausted apply should exit 3, rc=$rc: $out"
  [ ! -s "$FM_FAKE_HANDOFF_LOG" ] || fail "exhaustion must not launch anything"
  status_log=$(cat "$CASE_HOME/state/apply-a4.status")
  assert_contains "$status_log" "blocked: model fallback exhausted for opencode" "exhaustion surfaces as a blocked event"
  pass "full exhaustion stops loudly with a blocked status instead of a blind relaunch"
}

{
  setup_case apply-failure apply-a5 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  farm=$(make_bin_farm "$CASE_DIR" 1)
  : > "$FM_FAKE_HANDOFF_LOG"
  if out=$(FM_ROOT_OVERRIDE="$ROOT" FM_STUB_HANDOFF_RC=1 "$farm/fm-model-fallback.sh" apply-a5 apply 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] || fail "failed relaunch should surface failure, rc=$rc: $out"
  assert_contains "$out" "in-place fallback relaunch failed" "failure names the stage"
  grep -q '^fallback_cursor=' "$CASE_HOME/state/apply-a5.meta" \
    && fail "a failed relaunch must not consume the evidence"
  pass "when the relaunch fails, the evidence stays unconsumed for the retry supervisor"
}

# --- apply over the REAL handoff path ---------------------------------------

{
  setup_case apply-real apply-r1 "$AGY_CHAIN_CONFIG" "$DEPLETED_LINE"
  export FM_FAKE_WINDOW_PRESENT=0
  export FM_FAKE_PANE_CMD=bash
  : > "$FM_FAKE_TREEHOUSE_LOG"
  head_before=$(git -C "$CASE_WT" rev-parse HEAD)
  dirty_before=$(cat "$CASE_WT/dirty.txt")
  farm=$(make_bin_farm "$CASE_DIR" 0)

  if out=$(FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_SETTLE_POLLS=2 "$farm/fm-model-fallback.sh" apply-r1 apply 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || fail "real-path apply should succeed: $out"

  [ "$(git -C "$CASE_WT" rev-parse HEAD)" = "$head_before" ] || fail "fallback must preserve HEAD"
  [ "$(cat "$CASE_WT/dirty.txt")" = "$dirty_before" ] || fail "fallback must preserve uncommitted changes"
  meta=$(cat "$CASE_HOME/state/apply-r1.meta")
  assert_contains "$meta" "model=gemini-3.6-flash-high" "meta records the stepped-down model"
  assert_contains "$meta" "harness=agy" "same-harness step keeps the harness"
  assert_contains "$meta" "pr=https://example.test/pr/9" "non-owned meta keys survive"
  assert_contains "$meta" "fallback_cursor=" "evidence cursor recorded"
  prompt=$(cat "$CASE_HOME/state/apply-r1.handoff-prompt")
  assert_contains "$prompt" "Automatic model fallback" "replacement worker inherits the downgrade note"
  if [ -s "$FM_FAKE_TREEHOUSE_LOG" ]; then
    fail "fallback must not lease a new worktree; log=$(cat "$FM_FAKE_TREEHOUSE_LOG")"
  fi
  pass "over the real handoff path, fallback preserves the worktree and work while stepping the model down"
}

printf 'All fm-model-fallback tests passed.\n'
