#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIAGNOSTICS="$ROOT/tests/fm-claude-mcp-diagnostics.py"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-mcp-diagnostics.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
version='Claude Code test-version'

python3 - "$DIAGNOSTICS" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location('diagnostics', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    module.require('Claude Code imported-version', False, 'imported failure')
except AssertionError as error:
    assert str(error) == 'Claude Code imported-version: imported failure'
else:
    raise AssertionError('imported diagnostic did not fail')
PY

if output=$(python3 "$DIAGNOSTICS" --version "$version" --fail 'forced failure' 2>&1); then
  echo 'not ok - forced diagnostic unexpectedly passed' >&2
  exit 1
fi
case "$output" in *"$version: forced failure"*) ;; *) echo "$output" >&2; exit 1 ;; esac

if output=$(python3 "$DIAGNOSTICS" --version "$version" --read "$TMP_ROOT/missing" 2>&1); then
  echo 'not ok - missing diagnostic input unexpectedly passed' >&2
  exit 1
fi
case "$output" in *"$version:"*"missing"*) ;; *) echo "$output" >&2; exit 1 ;; esac
printf '%s\n' 'ok - Claude MCP diagnostics name the harness version'
