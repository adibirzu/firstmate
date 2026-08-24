#!/usr/bin/env bash
# End-to-end operator walkthrough for the intent:
#   "Support agy subscription provider and automatic model fallback on depletion"
#
# Drives the REAL shipped scripts against fake tmux / quota-axi / harness CLIs and
# narrates exactly what an operator sees at each step of a depletion.
set -u
FM_REPO="/Users/adrianb/.no-mistakes/worktrees/80e4cf1781af/01M0SEQE0C1ZFKZDTZWW97YA0Y"
. "$FM_REPO/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-fallback-evidence)
fm_git_identity
NODE_BIN_DIR=$(dirname "$(command -v node)")
BASE_PATH="$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
SELECTOR="$ROOT/bin/fm-dispatch-select.mjs"
STAMP=1970-01-01T00:16:40.000Z

hr()  { printf '\n================================================================\n%s\n================================================================\n' "$1"; }
sub() { printf '\n--- %s\n' "$1"; }
run() { printf '\n$ %s\n' "$*"; }

# ------------------------------------------------------------------ fixtures
mk_toolchain() {  # <dir> -> fakebin with everything bootstrap probes
  local dir=$1 fakebin real_jq
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi gh
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" no-mistakes FM_FAKE_NO_MISTAKES_VERSION \
    'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z'
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { printf '0.2.4\n'; exit 0; }
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf 'usage: tasks-axi update <id> [flags]\n  --body-file <path>\n  --archive-body\n'; exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>\n'; exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  real_jq=$(command -v jq)
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real_jq" > "$fakebin/jq"
  chmod +x "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

validate_config() {  # <label> <json>
  local label=$1 body=$2 dir out
  dir="$TMP_ROOT/cfg-$(printf '%s' "$label" | tr -cd '[:alnum:]')"
  mkdir -p "$dir/home/config"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  printf '%s\n' "$body" > "$dir/home/config/crew-dispatch.json"
  local fakebin; fakebin=$(mk_toolchain "$dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  printf '\n$ cat config/crew-dispatch.json | jq -c .\n'
  printf '%s\n' "$body" | jq -c .
  printf '$ bin/fm-bootstrap.sh\n'
  if [ -z "$out" ]; then
    printf '(no CREW_DISPATCH diagnostic — config accepted)\n'
  else
    printf '%s\n' "$out"
  fi
}

select_home=$TMP_ROOT/select/home
mkdir -p "$select_home/state" "$select_home/config"
select_fakebin=$TMP_ROOT/select/fakebin
mkdir -p "$select_fakebin"
QUOTA="$select_home/quota.json"

write_quota() {  # <agy-gemini-5h> <agy-gemini-weekly> <agy-claude-5h> <codex>
  cat > "$QUOTA" <<JSON
{"schemaVersion":3,"generatedAt":"$STAMP","providers":[
  {"provider":"agy","state":{"status":"fresh","stale":false},
   "windows":[
     {"id":"gemini_5h","percentRemaining":$1},
     {"id":"gemini_weekly","percentRemaining":$2},
     {"id":"claude_gpt_5h","percentRemaining":$3},
     {"id":"claude_gpt_weekly","percentRemaining":41}
   ]},
  {"provider":"codex","state":{"status":"fresh","stale":false},
   "windows":[{"id":"all","percentRemaining":$4}]}
]}
JSON
}

sel() {  # <state-file> <profiles-json> <now>
  FM_HOME="$select_home" FM_STATE_OVERRIDE="$select_home/state" \
  FM_CONFIG_OVERRIDE="$select_home/config" FM_DISPATCH_STATE_FILE="$select_home/state/$1" \
  PATH="$select_fakebin:$BASE_PATH" "$SELECTOR" select --quota-json "$QUOTA" --now "$3" "$2"
}

selcmd() {  # <state-file> <profiles-json> <now>
  run "bin/fm-dispatch-select.mjs select '$2'"
  sel "$1" "$2" "$3" 2>&1
  printf '(exit %s)\n' "$?"
}

CHAIN='["gemini-3.7-flash-high","gemini-3.6-flash-high","gemini-3.5-flash-high"]'
CONFIG=$(cat <<'JSON'
{
  "rules": [
    {
      "when": "Standard coding work suited for Gemini models on Antigravity.",
      "use": [
        { "harness": "agy", "model": "gemini-3.7-flash-high", "effort": "high", "quotaWindow": "gemini_5h" }
      ],
      "why": "Antigravity bills its Gemini and Claude/GPT pools separately."
    }
  ],
  "default": [
    { "harness": "agy", "model": "gemini-3.7-flash-high", "quotaWindow": "gemini_5h" },
    { "harness": "codex", "provider": "codex", "model": "gpt-5.5" }
  ],
  "modelFallback": {
    "agy": ["gemini-3.7-flash-high", "gemini-3.6-flash-high", "gemini-3.5-flash-high"],
    "claude": ["claude-sonnet-5", "sonnet", "haiku"]
  }
}
JSON
)

################################################################################
hr "ACT 1 — the operator declares an agy lane and its model-fallback chain"
################################################################################
cat <<'TXT'
config/crew-dispatch.json is the file an operator edits. Before this change the
`agy` harness was not a routable provider and `modelFallback` did not exist, so
bootstrap would have rejected both. Below: the real bin/fm-bootstrap.sh reading
the real config.
TXT
validate_config "accepted" "$CONFIG"

sub "and a chain the operator got wrong is refused with an actionable diagnostic, not ignored"
validate_config "emptychain"   '{"default":{"harness":"agy"},"modelFallback":{"agy":[]}}'
validate_config "badharness"   '{"default":{"harness":"agy"},"modelFallback":{"spaceship":["a"]}}'
validate_config "blankmodel"   '{"default":{"harness":"agy"},"modelFallback":{"agy":["gemini-3.7-flash-high",""]}}'
validate_config "bothspelling" '{"modelFallback":{"agy":["a"]},"_model_fallback":{"agy":["b"]}}'
sub "the documented legacy spelling still loads"
validate_config "legacyalias"  '{"default":{"harness":"agy"},"_model_fallback":{"agy":["gemini-3.6-flash-high"]}}'

################################################################################
hr "ACT 2 — agy is dispatchable, priced on the Antigravity pool it draws from"
################################################################################
cat <<'TXT'
quota-axi reports agy with four windows. The Gemini pool is healthy; the
Claude/GPT pool is spent. A profile without quotaWindow is conservatively priced
on the WORST window and must fail closed.
TXT
write_quota 100 93 0 90
run "quota-axi --json   (fixture)"
jq -c '.providers[] | select(.provider=="agy") | {provider, windows: [.windows[] | "\(.id)=\(.percentRemaining)%"]}' "$QUOTA"

sub "undeclared window -> priced on the empty claude_gpt_5h pool -> fail closed (exit 3)"
selcmd a1.json '[{"harness":"agy","model":"gemini-3.7-flash-high"}]' 1000

sub "declared gemini_5h -> agy selected, native provider identity established"
selcmd a2.json '[{"harness":"agy","model":"gemini-3.7-flash-high","quotaWindow":"gemini_5h"}]' 1000

sub "declared claude_gpt_5h (the spent pool) -> refused by name"
selcmd a3.json '[{"harness":"agy","model":"claude-sonnet-4-6","quotaWindow":"claude_gpt_5h"}]' 1000

sub "fm-spawn.sh now accepts agy as a routing provider (and still rejects nonsense)"
run "bin/fm-spawn.sh --harness agy --provider agy   (argument gate; stops later on a real requirement)"
PATH="$select_fakebin:$BASE_PATH" "$ROOT/bin/fm-spawn.sh" --harness agy --provider agy 2>&1 | head -2
run "bin/fm-spawn.sh --harness agy --provider spaceship"
PATH="$select_fakebin:$BASE_PATH" "$ROOT/bin/fm-spawn.sh" --harness agy --provider spaceship 2>&1 | head -2

################################################################################
hr "ACT 2b - the same three commands run against the BASE commit (before the change)"
################################################################################
BASE=3c544d6a1958784845356e62bc09d3dd56ee8a67
mkdir -p "$TMP_ROOT/base"
# Extract the whole base bin/ tree so the base scripts find their own siblings.
git -C "$ROOT" archive "$BASE" bin skills | tar -x -C "$TMP_ROOT/base"
chmod +x "$TMP_ROOT/base/bin/"* 2>/dev/null || true

run "(base $BASE) fm-spawn.sh --harness agy --provider agy"
PATH="$select_fakebin:$BASE_PATH" bash "$TMP_ROOT/base/bin/fm-spawn.sh" --harness agy --provider agy 2>&1 | head -2

run "(base) fm-dispatch-select.mjs select agy profile on gemini_5h"
FM_HOME="$select_home" FM_STATE_OVERRIDE="$select_home/state" FM_CONFIG_OVERRIDE="$select_home/config" \
  FM_DISPATCH_STATE_FILE="$select_home/state/base.json" PATH="$select_fakebin:$BASE_PATH" \
  node "$TMP_ROOT/base/bin/fm-dispatch-select.mjs" select --quota-json "$QUOTA" --now 1000 \
  '[{"harness":"agy","model":"gemini-3.7-flash-high","quotaWindow":"gemini_5h"}]' 2>&1
printf '(exit %s)\n' "$?"

base_validate() {  # <label> <json>
  local label=$1 body=$2 dir out fakebin
  dir="$TMP_ROOT/basecfg-$(printf '%s' "$label" | tr -cd '[:alnum:]')"
  mkdir -p "$dir/home/config"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  printf '%s\n' "$body" > "$dir/home/config/crew-dispatch.json"
  fakebin=$(mk_toolchain "$dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 bash "$TMP_ROOT/base/bin/fm-bootstrap.sh" 2>/dev/null)
  printf '\n$ cat config/crew-dispatch.json | jq -c .\n'
  printf '%s\n' "$body" | jq -c .
  printf '$ (base) bin/fm-bootstrap.sh\n'
  [ -n "$out" ] && printf '%s\n' "$out" \
    || printf '(base emits NO diagnostic: the whole modelFallback object is an unknown key it silently ignores)\n'
}

sub "(base) a broken model-fallback chain is accepted and ignored; after the change it is refused"
base_validate "emptychain" '{"default":{"harness":"agy"},"modelFallback":{"agy":[]}}'
base_validate "badharness" '{"default":{"harness":"agy"},"modelFallback":{"spaceship":["a"]}}'
base_validate "bothspelling" '{"modelFallback":{"agy":["a"]},"_model_fallback":{"agy":["b"]}}'

################################################################################
hr "ACT 3 — the running agy worker depletes; firstmate records the depletion"
################################################################################
printf 'harness=agy\n' > "$select_home/state/ship-42.meta"
printf 'failed: 429 Too Many Requests - you have reached your 5-hour Gemini usage limit\n' \
  > "$select_home/state/ship-42.status"
run "cat state/ship-42.status"
cat "$select_home/state/ship-42.status"
run "bin/fm-dispatch-select.mjs record-failure --provider agy --task ship-42"
FM_HOME="$select_home" FM_STATE_OVERRIDE="$select_home/state" FM_CONFIG_OVERRIDE="$select_home/config" \
  PATH="$select_fakebin:$BASE_PATH" "$SELECTOR" record-failure --provider agy --task ship-42 --now 1000 2>&1
printf '(exit %s)\n' "$?"

sub "a working ceiling is NOT spent quota — it must not park a healthy lane"
for line in \
  'working: context token limit reached; compacting' \
  'failed: exceeded the tool output limit' \
  'working: applying the hunk at line 429 of the diff'; do
  printf 'harness=agy\n' > "$select_home/state/benign.meta"
  printf '%s\n' "$line" > "$select_home/state/benign.status"
  printf '\n$ echo %q > state/benign.status && record-failure --provider agy --task benign\n' "$line"
  FM_HOME="$select_home" FM_STATE_OVERRIDE="$select_home/state" FM_CONFIG_OVERRIDE="$select_home/config" \
    PATH="$select_fakebin:$BASE_PATH" "$SELECTOR" record-failure --provider agy --task benign --now 1000 2>&1
  printf '(exit %s)\n' "$?"
done

################################################################################
hr "ACT 4 — automatic model fallback: relaunch in place on the next chain entry"
################################################################################
cat <<TXT
The chain configured in ACT 1 for harness agy is:
  $CHAIN
The worker was running gemini-3.7-flash-high (chain[0]). Firstmate relaunches the
SAME task, in the SAME worktree, on chain[1] via bin/fm-runtime-handoff.sh --model.
TXT

CASE_DIR="$TMP_ROOT/handoff"
CASE_HOME="$CASE_DIR/home"; CASE_PROJ="$CASE_DIR/project"; CASE_WT="$CASE_DIR/wt"
mkdir -p "$CASE_HOME/state" "$CASE_HOME/data/ship-42" "$CASE_HOME/config" "$CASE_HOME/projects"
fm_git_worktree "$CASE_PROJ" "$CASE_WT" "fm/ship-42"
printf 'landed work\n' > "$CASE_WT/feature.txt"
git -C "$CASE_WT" add feature.txt && git -C "$CASE_WT" commit -qm 'task work'
printf 'work in progress, never committed\n' > "$CASE_WT/dirty.txt"
printf '# brief for ship-42: wire the invoice export\n' > "$CASE_HOME/data/ship-42/brief.md"

hfakebin=$(fm_fakebin "$CASE_DIR")
cat > "$hfakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_CMD:-bash}"; exit 0 ;;
  *"list-windows"*) exit 0 ;;
esac
case "${1:-}" in
  capture-pane)
    # agy past-trust idle footer, so the spawn-time project-trust gate clears.
    printf '%s\n' '? for shortcuts                                   Gemini 3.6 Flash - low'
    exit 0 ;;
esac
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{pane_id}'*) printf '%%1\n' ;;
      *'#{pane_current_path}'*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
      *) printf '%s\n' "${FM_FAKE_SESSION:-firstmate}" ;;
    esac; exit 0 ;;
  new-window) printf '@9\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$hfakebin/tmux"
fm_fake_exit0 "$hfakebin" agy claude codex grok cursor cline copilot muse kimi pi pi-signed opencode

export FM_HOME="$CASE_HOME" FM_FAKE_PANE_PATH="$CASE_WT" FM_FAKE_SESSION=firstmate \
       FM_FAKE_PANE_CMD=bash FM_FAKE_WINDOW_PRESENT=0 FM_FAKE_TREEHOUSE_WT="$CASE_WT"
export PATH="$hfakebin:$BASE_PATH"

fm_write_meta "$CASE_HOME/state/ship-42.meta" \
  "window=firstmate:fm-ship-42" "endpoint_task_id=ship-42" "worktree=$CASE_WT" \
  "project=$CASE_PROJ" "harness=agy" "kind=ship" "mode=no-mistakes" "yolo=off" \
  "tasktmp=/tmp/fm-evidence-ship-42" "model=gemini-3.7-flash-high" "effort=high" \
  "pr=https://example.test/pr/1" "pr_head=abc123"

run "cat state/ship-42.meta   (before)"
grep -E '^(harness|model|effort|worktree|pr)=' "$CASE_HOME/state/ship-42.meta"
head_before=$(git -C "$CASE_WT" rev-parse HEAD)
printf 'HEAD=%s  dirty.txt present=%s\n' "$head_before" "$([ -f "$CASE_WT/dirty.txt" ] && echo yes || echo no)"

run "bin/fm-runtime-handoff.sh ship-42 --harness agy --model gemini-3.6-flash-high --skip-exit --progress-note '...'"
set +e
out=$(FM_SPAWN_SETTLE_POLLS=2 FM_AGY_TRUST_POLLS=3 FM_AGY_POLL_INTERVAL=0 "$ROOT/bin/fm-runtime-handoff.sh" ship-42 \
  --harness agy --model gemini-3.6-flash-high --skip-exit \
  --progress-note "agy gemini-3.7-flash-high 5h pool depleted; falling back to chain[1]. 1 commit + uncommitted work remain." 2>&1)
rc=$?
set -e
printf '%s\n(exit %s)\n' "$out" "$rc"

run "cat state/ship-42.meta   (after)"
grep -E '^(harness|model|effort|worktree|pr)=' "$CASE_HOME/state/ship-42.meta"
printf 'HEAD=%s  (unchanged: %s)\n' "$(git -C "$CASE_WT" rev-parse HEAD)" \
  "$([ "$(git -C "$CASE_WT" rev-parse HEAD)" = "$head_before" ] && echo yes || echo NO)"
printf 'dirty.txt preserved: %s\n' "$([ -f "$CASE_WT/dirty.txt" ] && echo yes || echo NO)"
run "cat state/ship-42.status   (what status reporting shows)"
cat "$CASE_HOME/state/ship-42.status" 2>/dev/null || echo '(none)'
run "cat state/ship-42.handoff-prompt   (what the replacement worker is told)"
sed -n '1,12p' "$CASE_HOME/state/ship-42.handoff-prompt" 2>/dev/null || echo '(none)'

sub "walk chain[1] -> chain[2] the same way"
set +e
out=$(FM_SPAWN_SETTLE_POLLS=2 FM_AGY_TRUST_POLLS=3 FM_AGY_POLL_INTERVAL=0 "$ROOT/bin/fm-runtime-handoff.sh" ship-42 \
  --harness agy --model gemini-3.5-flash-high --skip-exit \
  --progress-note "gemini-3.6-flash-high depleted too; chain[2]." 2>&1)
rc=$?
set -e
printf '%s\n(exit %s)\n' "$out" "$rc"
grep -E '^(harness|model)=' "$CASE_HOME/state/ship-42.meta"

################################################################################
hr "ACT 5 — chain exhausted: only now does work leave the agy lane"
################################################################################
cat <<'TXT'
agy is on cooldown from the ACT 3 depletion, so the selector routes the next
dispatch to the next harness lane instead of re-picking a spent subscription.
TXT
PROFILES='[{"harness":"agy","model":"gemini-3.5-flash-high","quotaWindow":"gemini_5h"},{"harness":"codex","model":"gpt-5.5"}]'
selcmd .dispatch-routing.json "$PROFILES" 1001

sub "and once the operator clears the cooldown, agy is a first-class candidate again"
run "bin/fm-dispatch-select.mjs clear --provider agy"
FM_HOME="$select_home" FM_STATE_OVERRIDE="$select_home/state" FM_CONFIG_OVERRIDE="$select_home/config" \
  PATH="$select_fakebin:$BASE_PATH" "$SELECTOR" clear --provider agy 2>&1
selcmd .dispatch-routing.json "$PROFILES" 1002

printf '\n\n== end of walkthrough ==\n'
