#!/usr/bin/env bash
# Credentialed guard: execute fm-spawn's captured Claude launch with real Claude.
# Only pane allocation is fake; print mode makes the real worker bounded.
set -eu
if [ "${FM_CLAUDE_MCP_LIVE:-0}" != 1 ]; then
  echo 'skip: set FM_CLAUDE_MCP_LIVE=1 for the credentialed Claude MCP guard'
  exit 0
fi
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
REAL_CLAUDE=$(command -v claude) || fail "Claude absent; no harness verified"
version=$("$REAL_CLAUDE" --version)
primary_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
primary_before=
[ ! -f "$primary_settings" ] || primary_before=$(cksum "$primary_settings")
TMP_ROOT=$(fm_test_tmproot fm-claude-mcp-live)
trap 'fm_test_cleanup "$TMP_ROOT"' EXIT
home="$TMP_ROOT/home"
proj="$TMP_ROOT/project"
wt="$TMP_ROOT/wt"
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_fake_treehouse "$fakebin"
fm_git_worktree "$proj" "$wt" mcp-live
fm_test_spawn_home "$home" claude
fm_test_spawn_brief "$home" mcp-live "Use Read on $home/data/mcp-live/brief.md. Use Bash to run: ps -axo pid=,ppid=,comm= > worker-processes.txt. Then say CREW_MCP_ISOLATION_OK. Make no other changes."
FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" mcp-live "$proj" --mode no-mistakes --yolo off --backend tmux --model sonnet --effort low > "$TMP_ROOT/spawn-output"
# A wrapper adds bounded output mode without changing any generated isolation flags.
mkdir -p "$TMP_ROOT/realbin"
cat > "$TMP_ROOT/realbin/claude" <<'WRAP'
#!/usr/bin/env bash
echo "$$" > "$FM_LIVE_PID"
exec "$FM_REAL_CLAUDE" --print --no-session-persistence --output-format stream-json --verbose "$@"
WRAP
chmod +x "$TMP_ROOT/realbin/claude"
(
  cd "$wt"
  FM_REAL_CLAUDE="$REAL_CLAUDE" FM_LIVE_PID="$TMP_ROOT/pid" PATH="$TMP_ROOT/realbin:$PATH" \
    bash "$TMP_ROOT/launch" > "$TMP_ROOT/output" 2> "$TMP_ROOT/stderr"
) || fail "$version: worker launch failed"
if [ -n "$primary_before" ]; then
  [ "$primary_before" = "$(cksum "$primary_settings")" ] || fail "primary settings changed"
fi
python3 - "$TMP_ROOT" "$version" <<'PY'
import json, pathlib, sys
d=pathlib.Path(sys.argv[1])
events=[json.loads(x) for x in (d/'output').read_text().splitlines() if x.startswith('{')]
init=next(x for x in events if x.get('subtype')=='init')
assert init['mcp_servers']==[], init['mcp_servers']
assert init.get('plugins',[])==[], init.get('plugins')
result=next(x for x in events if x.get('type')=='result')
assert not result['is_error'], result
assert 'CREW_MCP_ISOLATION_OK' in result['result'], result
used={c.get('name') for e in events for c in e.get('message',{}).get('content',[]) if isinstance(c,dict) and c.get('type')=='tool_use'}
assert {'Read','Bash'} <= used, used
rows={}
for line in (d/'wt/worker-processes.txt').read_text().splitlines():
    a=line.strip().split(None,2)
    if len(a)==3: rows[int(a[0])]=(int(a[1]),a[2])
desc={int((d/'pid').read_text())}
while True:
    expanded=desc|{p for p,(parent,_) in rows.items() if parent in desc}
    if expanded==desc: break
    desc=expanded
bad=[cmd for p,(_,cmd) in rows.items() if p in desc and ('mcp' in cmd.lower() or pathlib.Path(cmd).name=='node')]
assert not bad, bad
print(f"ok - {sys.argv[2]}: spawned worker authenticated, Read and Bash succeeded, MCP servers=0, plugins=0, MCP/node descendants=0")
PY
