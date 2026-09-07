#!/usr/bin/env python3
import argparse
import json
import subprocess


def descendants(root):
    rows={}
    for line in subprocess.check_output(['ps','-axo','pid=,ppid=,args='], text=True).splitlines():
        fields=line.strip().split(None, 2)
        if len(fields) == 3:
            rows[int(fields[0])]=(int(fields[1]), fields[2])
    if root not in rows:
        raise SystemExit(f'root process {root} is absent')
    found=set()
    pending=[root]
    while pending:
        parent=pending.pop()
        children=[pid for pid,(ppid,_) in rows.items() if ppid == parent and pid not in found]
        found.update(children)
        pending.extend(children)
    return [{'pid':pid, 'ppid':rows[pid][0], 'args':rows[pid][1]} for pid in sorted(found)]


parser=argparse.ArgumentParser()
parser.add_argument('--json', action='store_true')
parser.add_argument('--require-empty', action='store_true')
parser.add_argument('root', type=int)
args=parser.parse_args()
tree=descendants(args.root)
if args.json:
    print(json.dumps({'root':args.root, 'descendants':tree}))
if args.require_empty and tree:
    raise SystemExit(f'worker descendants present: {tree}')
