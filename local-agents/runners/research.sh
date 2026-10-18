#!/usr/bin/env bash
# research.sh - one research report through llm-run. Nothing is published.
set -euo pipefail

# shellcheck disable=SC1091 source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
id=$(job_get id)
task=$(job_get task)
wall=$(job_get budget.wall_max)
summary_file=$job_dir/summary.txt
report=$job_dir/report.md
prompt=$job_dir/prompt.md

if [ "$task" != "research" ]; then
  printf '%s\n' "task not allowed" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

if [[ ! "$wall" =~ ^[0-9]+[smh]$ ]]; then
  wall=45m
fi

{
  printf '%s\n\n' "$(cat "$job_dir/agent.md")"
  printf '%s\n\n' "$(cat "$job_dir/brief.md")"
  printf '%s\n' "Write a report in Markdown to report.md; first section '## Summary' max 10 lines"
} >"$prompt"

limiter=""
if command -v timeout >/dev/null 2>&1; then
  limiter=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  limiter=gtimeout
fi

run_claude() {
  if [ -n "$limiter" ]; then
    "$limiter" "$wall" llm-run claude --task "$id" --agent local-research --role scout -- \
      -p --output-format text --allowedTools WebSearch WebFetch Read \
      --disallowedTools Bash Edit Write <"$prompt"
  else
    llm-run claude --task "$id" --agent local-research --role scout -- \
      -p --output-format text --allowedTools WebSearch WebFetch Read \
      --disallowedTools Bash Edit Write <"$prompt"
  fi
}

: >"$report"
set +e
run_claude >"$report" 2>"$job_dir/claude.err"
claude_rc=$?
set -e

report_bytes=0
if [ -f "$report" ]; then
  report_bytes=$(wc -c <"$report" | tr -d '[:space:]')
fi

if [ "$claude_rc" -ne 0 ] || [ "$report_bytes" -eq 0 ]; then
  prompt_bytes=$(wc -c <"$prompt" | tr -d '[:space:]')
  if [ "$prompt_bytes" -gt 100000 ]; then
    printf '%s\n' "prompt exceeds the agy argument cap and claude produced no report" >"$summary_file"
    write_result failed "$summary_file" "claude exit $claude_rc"
    exit 0
  fi
  prompt_text=$(cat "$prompt")
  set +e
  if [ -n "$limiter" ]; then
    LLM_RUN_BIN=agy "$limiter" "$wall" llm-run gemini \
      --task "$id" --agent local-research --role scout \
      --model gemini-3.8-flash-high -- \
      --model gemini-3.8-flash-high --output-format text -p "$prompt_text" \
      >"$report" 2>"$job_dir/agy.err"
  else
    LLM_RUN_BIN=agy llm-run gemini \
      --task "$id" --agent local-research --role scout \
      --model gemini-3.8-flash-high -- \
      --model gemini-3.8-flash-high --output-format text -p "$prompt_text" \
      >"$report" 2>"$job_dir/agy.err"
  fi
  agy_rc=$?
  set -e
  report_bytes=$(wc -c <"$report" | tr -d '[:space:]')
  if [ "$agy_rc" -ne 0 ] || [ "$report_bytes" -eq 0 ]; then
    printf '%s\n' "research produced no report" >"$summary_file"
    write_result failed "$summary_file" "claude exit $claude_rc; agy exit $agy_rc"
    exit 0
  fi
fi

python3 - "$report" "$summary_file" <<'PY'
import sys
from pathlib import Path

report_path, summary_path = sys.argv[1], sys.argv[2]
lines = Path(report_path).read_text(encoding="utf-8").splitlines()
picked = []
in_summary = False
seen_heading = False
for line in lines:
    if line.startswith("## Summary"):
        in_summary = True
        seen_heading = True
        continue
    if in_summary and line.startswith("## "):
        break
    if in_summary:
        picked.append(line)
if not seen_heading or not any(line.strip() for line in picked):
    picked = [line for line in lines if line.strip()][:10]
else:
    picked = picked[:10]
Path(summary_path).write_text("\n".join(picked).strip() + "\n", encoding="utf-8")
PY

write_result succeeded "$summary_file" ""
exit 0
