#!/usr/bin/env bash
# Credentialed guard: execute fm-spawn's captured Claude launch with real Claude.
# Only pane allocation is fake; a PTY runs the actual interactive worker.
# A deadline bounds the guard and process samples cover startup and tool events.
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
fm_test_spawn_brief "$home" mcp-live "Verify this isolated test worktree: read this brief at $home/data/mcp-live/brief.md with Read, then use Bash to run pwd and write the word verified to tool-proof.txt in the current worktree. Make no other changes."
FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" mcp-live "$proj" --mode no-mistakes --yolo off --backend tmux --model sonnet --effort low > "$TMP_ROOT/spawn-output"
# The real worker keeps its normal interactive mode, so status-line execution
# is exercised too. Its generated local hook publishes the completion marker.
python3 - "$TMP_ROOT" "$version" "$(dirname "${BASH_SOURCE[0]}")/fm-claude-mcp-process-tree.py" "$(dirname "${BASH_SOURCE[0]}")/fm-claude-mcp-diagnostics.py" <<'PYLIVE'
import fcntl, importlib.util, json, os, pathlib, pty, re, select, signal, struct, subprocess, sys, termios, time
d=pathlib.Path(sys.argv[1])
version=sys.argv[2]
tree_tool=sys.argv[3]
diagnostic_tool=sys.argv[4]
diagnostic_spec=importlib.util.spec_from_file_location('claude_mcp_diagnostics', diagnostic_tool)
diagnostics=importlib.util.module_from_spec(diagnostic_spec)
diagnostic_spec.loader.exec_module(diagnostics)
master, slave=pty.openpty()
fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack("HHHH",40,160,0,0))
env=os.environ.copy()
env.pop('CLAUDECODE',None)
env['TERM']='xterm-256color'
launch=(d/'launch').read_text().strip()
# Debug output establishes which hooks the real client matched and executed.
launch=launch.replace('claude --dangerously', 'claude --debug-file '+str(d/'debug')+' --dangerously',1)
p=subprocess.Popen(['bash','-c',launch],cwd=d/'wt',env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
os.close(slave)
transcript=b''
samples=[]
inventory_descendants=[]
inventory_text=''
deadline=time.monotonic()+100
trusted=False
bypass=False
completed=False
inventory_checked=False

def process_rows():
    rows={}
    for line in subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,args='],text=True).splitlines():
        a=line.strip().split(None,3)
        if len(a)==4: rows[int(a[0])]=(int(a[1]),int(a[2]),a[3])
    return rows

def process_group(rows):
    return {pid:cmd for pid,(_,pgid,cmd) in rows.items()
            if pgid==p.pid and not (cmd.startswith('(') and cmd.endswith(')'))}

def normalized_text():
    return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', transcript.decode(errors='replace'))

def inventory_is_empty(text):
    compact=' '.join(text.lower().split())
    return any(marker in compact for marker in (
        'no mcp servers', 'no configured mcp servers', '0 mcp servers',
        '0 servers configured', 'mcp servers: 0'))

def worker_descendants():
    out=subprocess.check_output([sys.executable, tree_tool, '--json', str(p.pid)], text=True)
    return json.loads(out)['descendants']

def require(condition, message):
    diagnostics.require(version, condition, message)

def read_text(path):
    return diagnostics.read_text(version, path)

def terminate_group():
    if p.poll() is None:
        try: os.killpg(p.pid,signal.SIGTERM)
        except ProcessLookupError: pass
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try: os.killpg(p.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: pass
    cleanup_deadline=time.monotonic()+3
    while time.monotonic()<cleanup_deadline:
        if not process_group(process_rows()): return
        time.sleep(0.1)
    survivors=process_group(process_rows())
    require(False, f"worker process group survived SIGTERM and SIGKILL: {survivors}")

try:
    while time.monotonic()<deadline:
        if select.select([master],[],[],0.25)[0]:
            try: transcript+=os.read(master,65536)
            except OSError: break
        (d/'transcript').write_bytes(transcript)
        text=normalized_text()
        if not trusted and ('Yes,Itrustthisfolder' in ''.join(text.split()) or 'Yes,Itrustthisproject' in ''.join(text.split())):
            os.write(master,b'\x1b[B')
            time.sleep(0.3)
            os.write(master,b'\r')
            trusted=True
        if not bypass and 'Yes,Iaccept' in ''.join(text.split()):
            os.write(master,b'2\r')
            bypass=True
        rows=process_rows()
        descendants={p.pid}
        while True:
            expanded=descendants|{pid for pid,(parent,_,_) in rows.items() if parent in descendants}
            if expanded==descendants: break
            descendants=expanded
        samples.extend(cmd for pid,(_,_,cmd) in rows.items() if pid in descendants and pid!=p.pid)
        if (d/'wt/tool-proof.txt').exists() and (d/'home/state/mcp-live.turn-ended').exists():
            completed=True
            break
        if p.poll() is not None: break
    if completed and p.poll() is None:
        os.write(master,b'/mcp\r')
        inventory_response=b''
        inventory_deadline=time.monotonic()+15
        while time.monotonic()<inventory_deadline:
            if select.select([master],[],[],0.25)[0]:
                try:
                    chunk=os.read(master,65536)
                    transcript+=chunk
                    inventory_response+=chunk
                except OSError: break
            inventory_text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', inventory_response.decode(errors='replace'))
            if inventory_is_empty(inventory_text):
                inventory_checked=True
                inventory_descendants=worker_descendants()
                break
finally:
    try: terminate_group()
    finally:
        os.close(master)
    (d/'transcript').write_bytes(transcript)
require(completed, f"worker did not finish Read/Bash proof: {transcript[-5000:]!r}")
require(read_text(d/'wt/tool-proof.txt').strip()=='verified', 'tool-proof.txt did not contain verified')
require(samples, 'no descendant process samples')
bad=[cmd for cmd in samples if 'LIFEOS_StatusLine.sh' in cmd or '/.claude/hooks/' in cmd]
require(not bad, bad)
require(inventory_checked, f"/mcp did not report an empty server inventory: {inventory_text[-5000:]!r}")
require(not inventory_descendants, f"empty MCP inventory has worker descendants: {inventory_descendants}")
debug=read_text(d/'debug')
# A real Read tool event, a Bash proof artifact, and the owned Stop hook prove
# that removing user settings did not disable the built-in tools or all hooks.
require('0 enabled' in debug, 'plugins were not disabled')
require('Read' in debug, 'no Read event in Claude debug log')
require('fm-busy-event.sh' in debug, 'owned supervision hooks did not run')
require('LIFEOS_StatusLine.sh' not in debug, 'primary status line was loaded')
require('/.claude/hooks/' not in debug, 'primary per-event automation was loaded')
print(f"ok - {sys.argv[2]}: interactive worker authenticated, Read/Bash and owned hooks succeeded, primary status-line/event automation=0")
PYLIVE
if [ -n "$primary_before" ]; then
  [ "$primary_before" = "$(cksum "$primary_settings")" ] || fail "primary settings changed"
fi
