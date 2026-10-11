import json, sys
from pathlib import Path
root, tmp, shell, output = sys.argv[1:]
stream = open(output, 'w')

def emit(record):
    stream.write(json.dumps(record, sort_keys=True) + '\n')
    stream.flush()

def observe(frame, event, value):
    if event != 'return' or frame.f_code.co_filename != 'bootstrap-scenarios':
        return
    if frame.f_code.co_name == 'run' and hasattr(value, 'returncode'):
        local = frame.f_locals
        emit({'case': local['case']['path'].name, 'command': local['script'],
              'args': [str(x) for x in local['args']], 'status': value.returncode,
              'stdout': value.stdout.decode(errors='replace'),
              'stderr': value.stderr.decode(errors='replace')})
    if frame.f_code.co_name == 'passed':
        case = frame.f_globals['case']
        records = {}
        for path in case['path'].rglob('*'):
            if path.is_file() and not path.is_symlink() and (path.name in
                ('manifest', 'transport.jsonl', 'router.jsonl', 'spawn-capacity',
                 '.fm-inherit-spawn-capacity.generation', 'secondmates.md', 'outside', 'committed-capacity')):
                records[str(path.relative_to(case['path']))] = path.read_text()
        emit({'scenario': frame.f_locals['message'], 'contracts': records})

source = (Path(root) / 'tests/fm-remote-home-seed.test.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
sys.argv = ['bootstrap-scenarios', root, tmp, shell]
sys.setprofile(observe)
exec(compile(source, 'bootstrap-scenarios', 'exec'), {'__name__': '__main__'})
sys.setprofile(None)
stream.close()
