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
python3 - "$TMP_ROOT" "$version" <<'PYLIVE'
import fcntl, os, pathlib, pty, re, select, signal, struct, subprocess, sys, termios, time
d=pathlib.Path(sys.argv[1])
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
deadline=time.monotonic()+100
trusted=False
bypass=False
completed=False
try:
    while time.monotonic()<deadline:
        if select.select([master],[],[],0.25)[0]:
            try: transcript+=os.read(master,65536)
            except OSError: break
        (d/'transcript').write_bytes(transcript)
        text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', transcript.decode(errors='replace'))
        if not trusted and ('Yes,Itrustthisfolder' in ''.join(text.split()) or 'Yes,Itrustthisproject' in ''.join(text.split())):
            os.write(master,b'\x1b[B')
            time.sleep(0.3)
            os.write(master,b'\r')
            trusted=True
        if not bypass and 'Yes,Iaccept' in ''.join(text.split()):
            os.write(master,b'2\r')
            bypass=True
        rows={}
        for line in subprocess.check_output(['ps','-axo','pid=,ppid=,args='],text=True).splitlines():
            a=line.strip().split(None,2)
            if len(a)==3: rows[int(a[0])]=(int(a[1]),a[2])
        descendants={p.pid}
        while True:
            expanded=descendants|{pid for pid,(parent,_) in rows.items() if parent in descendants}
            if expanded==descendants: break
            descendants=expanded
        # Skip the launching shell: its command text contains the debug path.
        samples.extend(cmd for pid,(_,cmd) in rows.items() if pid in descendants and pid!=p.pid)
        if (d/'wt/tool-proof.txt').exists() and (d/'home/state/mcp-live.turn-ended').exists():
            completed=True
            break
        if p.poll() is not None: break
finally:
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGTERM)
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL)
            p.wait(timeout=3)
    os.close(master)
    (d/'transcript').write_bytes(transcript)
assert completed, f"{sys.argv[2]}: worker did not finish Read/Bash proof: {transcript[-5000:]!r}"
assert (d/'wt/tool-proof.txt').read_text().strip()=='verified'
assert samples, 'no descendant process samples'
bad=[cmd for cmd in samples if 'LIFEOS_StatusLine.sh' in cmd or '/.claude/hooks/' in cmd]
assert not bad, bad
bad_mcp=[cmd for cmd in samples if pathlib.Path(cmd.split()[0]).name in ('node','nodejs') or 'mcp-server' in cmd.split()[0]]
assert not bad_mcp, bad_mcp
debug=(d/'debug').read_text()
# A real Read tool event, a Bash proof artifact, and the owned Stop hook prove
# that removing user settings did not disable the built-in tools or all hooks.
assert '0 enabled' in debug, 'plugins were not disabled'
assert 'Read' in debug, 'no Read event in Claude debug log'
assert 'fm-busy-event.sh' in debug, 'owned supervision hooks did not run'
assert 'LIFEOS_StatusLine.sh' not in debug, 'primary status line was loaded'
assert '/.claude/hooks/' not in debug, 'primary per-event automation was loaded'
print(f"ok - {sys.argv[2]}: interactive worker authenticated, Read/Bash and owned hooks succeeded, primary status-line/event automation=0")
PYLIVE
if [ -n "$primary_before" ]; then
  [ "$primary_before" = "$(cksum "$primary_settings")" ] || fail "primary settings changed"
fi
