#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TREE="$ROOT/tests/fm-claude-mcp-process-tree.py"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-mcp-tree.XXXXXX")
root_pid=
clean_pid=

cleanup() {
  [ -z "$root_pid" ] || kill "$root_pid" 2>/dev/null || true
  [ -z "$clean_pid" ] || kill "$clean_pid" 2>/dev/null || true
  wait "$root_pid" 2>/dev/null || true
  wait "$clean_pid" 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

sleep 30 &
clean_pid=$!
python3 "$TREE" --require-empty "$clean_pid"

bash -c 'python3 -c "import time; time.sleep(30)" & child=$!; printf "%s\\n" "$child" > "$1"; wait' _ "$TMP_ROOT/child" &
root_pid=$!
while [ ! -s "$TMP_ROOT/child" ]; do sleep 0.05; done
child_pid=$(cat "$TMP_ROOT/child")
python3 "$TREE" --json "$root_pid" > "$TMP_ROOT/tree.json"
python3 - "$TMP_ROOT/tree.json" "$child_pid" <<'PY'
import json, sys
tree=json.load(open(sys.argv[1]))
assert int(sys.argv[2]) in {node['pid'] for node in tree['descendants']}
PY
if python3 "$TREE" --require-empty "$root_pid" > "$TMP_ROOT/rejected" 2>&1; then
  echo 'not ok - direct child was accepted as an empty worker tree' >&2
  exit 1
fi
printf '%s\n' 'ok - direct Python child rejects empty Claude MCP process tree'
