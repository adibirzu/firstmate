#!/usr/bin/env bash
# issue-mapper.sh - map closing references, or draft issues from findings.
# gh issue create runs only when the job sets create: true.
set -euo pipefail

# shellcheck disable=SC1091 source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
summary_file=$job_dir/summary.txt
report=$job_dir/report.md
id=$(job_get id)
task=$(job_get task)
repo=$(job_input "repo:")
create_flag=$(job_get create)

if [ -z "$repo" ]; then
  repo=$(job_get _dispatch.repo)
fi
if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  printf '%s\n' "bad repo" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

if [ "$task" = "map" ]; then
  set +e
  gh pr list -R "$repo" --state all --limit 100 \
    --json number,title,state,body,url >"$job_dir/prs.json" 2>"$job_dir/gh.err"
  gh_rc=$?
  set -e
  if [ "$gh_rc" -ne 0 ]; then
    printf '%s\n' "gh pr list failed" >"$summary_file"
    write_result failed "$summary_file" "exit $gh_rc"
    exit 0
  fi
  python3 - "$job_dir/prs.json" "$report" "$summary_file" <<'PY'
import json
import re
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8") or "[]")
pattern = re.compile(r"(?i)\b(?:Closes|Fixes|Resolves)\s+#(\d+)")
rows = []
refs = 0
if isinstance(payload, list):
    for pr in payload:
        if not isinstance(pr, dict):
            continue
        found = pattern.findall(str(pr.get("body") or ""))
        refs += len(found)
        rows.append((pr.get("number"), pr.get("state"), pr.get("title"), ", ".join("#%s" % n for n in found), pr.get("url")))
lines = ["# Pull request to issue map", "", "| PR | State | Closes | Title |", "| --- | --- | --- | --- |"]
for number, state, title, closes, _url in rows:
    title_cell = str(title or "").replace("|", "/")
    lines.append("| #%s | %s | %s | %s |" % (number, state, closes or "-", title_cell))
lines.append("")
Path(sys.argv[2]).write_text("\n".join(lines) + "\n", encoding="utf-8")
Path(sys.argv[3]).write_text(
    "scanned %s pull requests; %s closing references\n" % (len(rows), refs),
    encoding="utf-8",
)
PY
  write_result succeeded "$summary_file" ""
  exit 0
fi

if [ "$task" != "from-findings" ]; then
  printf '%s\n' "task not allowed" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

prompt=$job_dir/prompt.md
{
  printf '%s\n\n' "$(cat "$job_dir/agent.md")"
  printf '%s\n\n' "$(cat "$job_dir/brief.md")"
  printf '%s\n' "Draft a JSON array of issues. Each item has title and body strings. Write only the JSON array."
} >"$prompt"

prompt_bytes=$(wc -c <"$prompt" | tr -d '[:space:]')
if [ "$prompt_bytes" -gt 100000 ]; then
  printf '%s\n' "prompt exceeds the agy argument cap" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi
prompt_text=$(cat "$prompt")
set +e
LLM_RUN_BIN=agy llm-run gemini --task "$id" --agent local-issue-mapper --role scout \
  --model gemini-3.8-flash-high -- \
  --model gemini-3.8-flash-high --output-format text -p "$prompt_text" \
  >"$report" 2>"$job_dir/llm.err"
llm_rc=$?
set -e
if [ "$llm_rc" -ne 0 ] || [ ! -s "$report" ]; then
  printf '%s\n' "issue draft model failed" >"$summary_file"
  write_result failed "$summary_file" "llm exit $llm_rc"
  exit 0
fi

set +e
python3 - "$repo" "$report" "$summary_file" "$create_flag" "$job_dir" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

repo, report_path, summary_path, create_flag, job_dir = sys.argv[1:6]
text = Path(report_path).read_text(encoding="utf-8")
start = text.find("[")
end = text.rfind("]")
if start < 0 or end < start:
    Path(summary_path).write_text("model output had no JSON list\n", encoding="utf-8")
    raise SystemExit(2)
try:
    items = json.loads(text[start:end + 1])
except json.JSONDecodeError:
    Path(summary_path).write_text("model output was not valid JSON\n", encoding="utf-8")
    raise SystemExit(2)
if not isinstance(items, list):
    Path(summary_path).write_text("model output was not a JSON list\n", encoding="utf-8")
    raise SystemExit(2)
drafts = []
for item in items:
    if isinstance(item, dict) and isinstance(item.get("title"), str) and item.get("title").strip():
        body = item.get("body") if isinstance(item.get("body"), str) else ""
        drafts.append((item["title"].strip(), body))
created = []
if create_flag == "true":
    for index, (title, body) in enumerate(drafts):
        body_file = Path(job_dir) / ("issue-body-%s.md" % index)
        body_file.write_text(body, encoding="utf-8")
        proc = subprocess.run(
            ["gh", "issue", "create", "-R", repo, "--title", title, "--body-file", str(body_file), "--label", "agent-draft"],
            capture_output=True, text=True, timeout=60, check=False,
        )
        if proc.returncode != 0:
            Path(summary_path).write_text("gh issue create failed\n", encoding="utf-8")
            raise SystemExit(3)
        created.append((proc.stdout or "").strip())
if create_flag == "true":
    summary = "created %s draft issues" % len(created)
else:
    summary = "drafted %s issues; create is false" % len(drafts)
Path(summary_path).write_text(summary + "\n", encoding="utf-8")
details = Path(job_dir) / "create-details.txt"
details.write_text("\n".join(created), encoding="utf-8")
PY
map_rc=$?
set -e
if [ "$map_rc" -ne 0 ]; then
  write_result failed "$summary_file" ""
  exit 0
fi
details=""
if [ -f "$job_dir/create-details.txt" ]; then
  details=$(cat "$job_dir/create-details.txt")
fi
write_result succeeded "$summary_file" "$details"
exit 0
