#!/usr/bin/env bash
# local-agents/runners/lib.sh - shared helpers for one local-agent job.
#
# Source this from a runner. FM_AGENT_JOB_DIR must point at the staged job
# directory (job.json, brief.md, agent.md). job_get prints one value from
# job.json. write_result writes result.json with json.dumps. llm_available
# reports whether a harness name resolves on PATH.
#
# shellcheck shell=bash

# A dev-guard host has no ledger writer until HOME and LLM_RUN_FM_HOME are set.
if [ -z "${HOME:-}" ]; then
  if command -v getent >/dev/null 2>&1; then
    _fm_resolved_home=$(getent passwd "$(id -u)" 2>/dev/null | awk -F: 'NR == 1 { print $6 }' || true)
    if [ -n "${_fm_resolved_home:-}" ]; then
      HOME=$_fm_resolved_home
    fi
    unset _fm_resolved_home
  fi
fi
if [ -z "${HOME:-}" ]; then
  HOME=~
fi
export HOME
if [ -z "${LLM_RUN_FM_HOME:-}" ] && [ -f "$HOME/dev/llm-ledger/bin/fm-fleet-ledger.sh" ]; then
  LLM_RUN_FM_HOME=$HOME/dev/llm-ledger
  export LLM_RUN_FM_HOME
fi

# job_get <dotted-key>
# Strings are written raw. Other JSON values are written with json.dumps.
# A missing key prints nothing and returns 0.
job_get() {
  local key=${1:?job_get: key required}
  local job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
  python3 - "$job_dir/job.json" "$key" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    current = json.load(handle)
for part in key.split("."):
    if isinstance(current, dict) and part in current:
        current = current[part]
    else:
        raise SystemExit(0)
if isinstance(current, str):
    sys.stdout.write(current)
else:
    json.dump(current, sys.stdout, ensure_ascii=False)
PY
}

# job_input <prefix>
# Prints the text after the first inputs entry that starts with prefix.
# Inputs are a list of strings such as repo:owner/name or path:/file.
job_input() {
  local prefix=${1:?job_input: prefix required}
  local job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
  python3 - "$job_dir/job.json" "$prefix" <<'PY'
import json
import sys

path, prefix = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
inputs = data.get("inputs") or []
if isinstance(inputs, str):
    inputs = [inputs]
if not isinstance(inputs, list):
    raise SystemExit(0)
for item in inputs:
    if isinstance(item, str) and item.startswith(prefix):
        sys.stdout.write(item[len(prefix):])
        raise SystemExit(0)
PY
}

# write_result <status> <summary-file> [details]
# status is succeeded, failed, or blocked. The summary is kept to 10 lines.
# A non-empty report.md in the job directory is added to artifacts.
write_result() {
  local status=${1:?write_result: status required}
  local summary_file=${2:?write_result: summary file required}
  local details=${3-}
  local job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
  python3 - "$job_dir/result.json" "$status" "$summary_file" "$details" "$job_dir/report.md" <<'PY'
import json
import sys
from pathlib import Path

out, status, summary_path, details, report = sys.argv[1:6]
if status not in ("succeeded", "failed", "blocked"):
    raise SystemExit("write_result: bad status")
text = Path(summary_path).read_text(encoding="utf-8")
lines = text.splitlines()
if len(lines) > 10:
    lines = lines[:10]
artifacts = []
report_path = Path(report)
if report_path.is_file() and report_path.stat().st_size > 0:
    artifacts.append("report.md")
payload = {
    "status": status,
    "summary": "\n".join(lines).strip(),
    "artifacts": artifacts,
    "pr": None,
    "cost": {},
    "details": details,
}
Path(out).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

# llm_available <harness>
# True when the harness name is an executable on PATH.
llm_available() {
  local harness=${1:?llm_available: harness required}
  command -v "$harness" >/dev/null 2>&1
}
