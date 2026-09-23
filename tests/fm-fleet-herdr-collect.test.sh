#!/usr/bin/env bash
# Behavior tests for the read-only per-host Herdr session/agent collector.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COLLECT="$ROOT/bin/fm-fleet-herdr-collect.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-herdr-collect)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# make_fake_herdr <dir> <worktree-hit>: a recording fake herdr that serves one
# running session with one matched agent, one unmatched agent, and one plain
# pane. Every invocation appends its argv to $dir/herdr-argv.log.
make_fake_herdr() {  # <dir> <worktree-hit>
  local dir=$1 hit=$2 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "herdr \$*" >> "$dir/herdr-argv.log"
case "\$*" in
  *"session list"*)
    printf '{"sessions":[{"name":"default","running":true,"default":true},{"name":"lab-old","running":false,"default":false}]}\n'
    ;;
  *"agent list"*)
    printf '{"id":"cli:agent:list","result":{"agents":[{"agent":"opencode","agent_status":"working","cwd":"$hit","foreground_cwd":"$hit","pane_id":"wF:p2","tab_id":"wF:t2","workspace_id":"wF","terminal_title_stripped":"Working task"},{"agent":"claude","agent_status":"idle","cwd":"/elsewhere/project","foreground_cwd":"/elsewhere/project","pane_id":"wX:p1","tab_id":"wX:t1","workspace_id":"wX","terminal_title_stripped":"Side quest"}],"type":"agent_list"}}\n'
    ;;
  *"pane list"*)
    printf '{"id":"cli:pane:list","result":{"panes":[{"cwd":"$hit","foreground_cwd":"$hit","pane_id":"wF:p2","tab_id":"wF:t2","workspace_id":"wF"},{"cwd":"/tmp/shell","foreground_cwd":"/tmp/shell","pane_id":"wS:p9","tab_id":"wS:t9","workspace_id":"wS"}],"type":"pane_list"}}\n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  mkdir -p "$home/projects/alpha-worktree"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=tmux:ship" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=opencode" \
    "kind=ship" \
    "mode=ship" \
    "model=default"
  printf '%s\n' "$home"
}

test_local_only_matches_and_labels_unmanaged() {
  local home fakebin out
  home=$(make_home local-only)
  fakebin=$(make_fake_herdr "$home" "$home/projects/alpha-worktree")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$COLLECT" --json --local-only)
  printf '%s' "$out" | jq -e '.schema == "fm-fleet-herdr.v1"' >/dev/null \
    || fail "collector schema id wrong: $out"
  printf '%s' "$out" | jq -e '
    .hosts | length == 1 and .[0].host == "local" and .[0].ok == true
  ' >/dev/null || fail "local host record wrong: $out"
  printf '%s' "$out" | jq -e '
    [.hosts[0].sessions[] | select(.name == "default")]
    | length == 1
  ' >/dev/null || fail "only the running session must be collected: $out"
  printf '%s' "$out" | jq -e '
    [.hosts[0].sessions[].agents[] | select(.managed == true)]
    | length == 1 and .[0].matched_task_id == "ship-task"
    and .[0].matched_home == "main" and .[0].matched_harness == "opencode"
  ' >/dev/null || fail "worktree-matched agent must be managed with its task: $out"
  printf '%s' "$out" | jq -e '
    [.hosts[0].sessions[].agents[] | select(.managed != true)]
    | length == 1 and .[0].matched_task_id == null and .[0].agent == "claude"
  ' >/dev/null || fail "unmatched agent must stay visible as unmanaged: $out"
  printf '%s' "$out" | jq -e '
    [.hosts[0].sessions[].plain_panes[]] | length == 1
  ' >/dev/null || fail "agent-less pane must be listed as a plain pane: $out"
  pass "local-only collection matches tracked worktrees and labels the rest unmanaged"
}

test_collector_is_read_only() {
  local home fakebin
  home=$(make_home read-only)
  fakebin=$(make_fake_herdr "$home" "$home/projects/alpha-worktree")
  PATH="$fakebin:$PATH" FM_HOME="$home" "$COLLECT" --json --local-only >/dev/null
  grep -Eq ' (attach|send-keys|input|prompt|start|stop|delete|close|run|focus|rename|wait|kill) ' "$home/herdr-argv.log" \
    && fail "collector invoked a mutating herdr verb: $(cat "$home/herdr-argv.log")"
  grep -Eq 'agent list|pane list|session list' "$home/herdr-argv.log" \
    || fail "collector must use only list verbs: $(cat "$home/herdr-argv.log")"
  pass "collector invokes only session/agent/pane list verbs"
}

test_missing_herdr_is_nonfatal() {
  local home out
  home=$(make_home no-herdr)
  out=$(PATH="/usr/bin:/bin" FM_HOME="$home" FM_HERDR_BIN_OVERRIDE="herdr-definitely-absent" "$COLLECT" --json --local-only)
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing herdr must not fail the collector"
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-herdr.v1" and .hosts[0].ok == false
    and ((.hosts[0].error // "") | length > 0)
  ' >/dev/null || fail "missing herdr must be an explicit ok:false record: $out"
  pass "missing herdr degrades to an explicit ok:false host record"
}

test_remote_hosts_merge_by_host() {
  local home fakebin out
  home=$(make_home remote-merge)
  fakebin=$(make_fake_herdr "$home" "$home/projects/alpha-worktree")
  cat > "$home/data/secondmates.md" <<EOF
- infra-remote - Infra helper (host: adi1; root: /r/firstmate; home: /r/homes/infra; scope: infra work; projects: none; added 2026-09-01)
- tms-adi2 - TMS helper (host: adi1; root: /r/firstmate; home: /r/homes/tms; scope: tms work; projects: none; added 2026-09-01)
EOF
  cat > "$fakebin/fm-on-stub.sh" <<SH
#!/usr/bin/env bash
printf '{"schema":"fm-fleet-herdr.v1","generated":1,"host":"local","hosts":[{"host":"local","ok":true,"source":"local","error":null,"sessions":[{"name":"default","running":true,"agents":[{"agent":"claude","status":"idle","cwd":"/r/wt","pane_id":"p1","tab_id":"t1","workspace_id":"w1","title":"Remote task","matched_task_id":"remote-task","matched_home":"main","matched_harness":"claude","managed":true}],"plain_panes":[]}]}]}\n'
SH
  chmod +x "$fakebin/fm-on-stub.sh"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_FLEET_HERDR_ON_BIN="$fakebin/fm-on-stub.sh" \
    "$COLLECT" --json)
  printf '%s' "$out" | jq -e '
    [.hosts[].host] | sort == ["adi1","local"]
  ' >/dev/null || fail "remote hosts must merge once per host: $out"
  printf '%s' "$out" | jq -e '
    .hosts[] | select(.host == "adi1")
    | .ok == true and (.source | startswith("remote-secondmate:"))
    and .sessions[0].agents[0].matched_task_id == "remote-task"
  ' >/dev/null || fail "remote host record must keep remote-side matching: $out"
  pass "remote homes merge once per host with remote-side matching intact"
}

test_remote_failure_is_nonfatal() {
  local home fakebin out
  home=$(make_home remote-fail)
  fakebin=$(make_fake_herdr "$home" "$home/projects/alpha-worktree")
  cat > "$home/data/secondmates.md" <<EOF
- dark-remote - Dark helper (host: adi9; root: /r/firstmate; home: /r/homes/dark; scope: dark work; projects: none; added 2026-09-01)
EOF
  printf '#!/usr/bin/env bash\nexit 255\n' > "$fakebin/fm-on-dead.sh"
  chmod +x "$fakebin/fm-on-dead.sh"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_FLEET_HERDR_ON_BIN="$fakebin/fm-on-dead.sh" \
    "$COLLECT" --json)
  rc=$?
  [ "$rc" -eq 0 ] || fail "unreachable remote must not fail the collector"
  printf '%s' "$out" | jq -e '
    .hosts[] | select(.host == "adi9") | .ok == false
  ' >/dev/null || fail "unreachable remote must be an ok:false record: $out"
  pass "unreachable remote degrades to an explicit ok:false record"
}

test_local_only_matches_and_labels_unmanaged
test_collector_is_read_only
test_missing_herdr_is_nonfatal
test_remote_hosts_merge_by_host
test_remote_failure_is_nonfatal
