#!/usr/bin/env bash
# release-watch.sh - merged and failing pull requests. No model call.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
state_dir=${FM_AGENT_STATE:-$HOME/dev/mini-state/local-agents}
summary_file=$job_dir/summary.txt
report=$job_dir/report.md
task=$(job_get task)
repo=$(job_input "repo:")

if [ "$task" != "poll" ] && [ "$task" != "digest" ]; then
  printf '%s\n' "task not allowed" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

if [ -z "$repo" ]; then
  repo=Pentforge-io/cyber-bot.ro
fi
if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  printf '%s\n' "bad repo input" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

since=$(python3 - <<'PY'
from datetime import datetime, timedelta
print((datetime.now().astimezone() - timedelta(hours=24)).date().isoformat())
PY
)

mkdir -p "$state_dir"
merged_file=$job_dir/merged.json
open_file=$job_dir/open.json

set +e
gh pr list -R "$repo" --state merged --search "merged:>=$since" \
  --json number,title,baseRefName,mergedAt >"$merged_file" 2>"$job_dir/gh-merged.err"
merged_rc=$?
gh pr list -R "$repo" --state open \
  --json number,title,baseRefName,statusCheckRollup >"$open_file" 2>"$job_dir/gh-open.err"
open_rc=$?
set -e

if [ "$merged_rc" -ne 0 ] || [ "$open_rc" -ne 0 ]; then
  printf '%s\n' "gh pr list failed" >"$summary_file"
  write_result failed "$summary_file" "merged exit $merged_rc; open exit $open_rc"
  exit 0
fi

python3 - "$repo" "$since" "$merged_file" "$open_file" "$report" "$state_dir/digest.md" "$summary_file" <<'PY'
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

repo, since, merged_path, open_path, report_path, digest_path, summary_path = sys.argv[1:8]
now = datetime.now().astimezone()
cutoff = now - timedelta(hours=24)

def load(path):
    data = json.loads(Path(path).read_text(encoding="utf-8") or "[]")
    if not isinstance(data, list):
        raise SystemExit("gh json was not a list")
    return data

def parse_time(value):
    if not isinstance(value, str) or not value:
        return None
    text = value.replace("Z", "+00:00")
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=now.tzinfo)
    return moment

merged = []
for pr in load(merged_path):
    base = pr.get("baseRefName")
    if base not in ("main", "prelive"):
        continue
    moment = parse_time(pr.get("mergedAt"))
    if moment is not None and moment < cutoff:
        continue
    merged.append(pr)

failures = []
for pr in load(open_path):
    base = pr.get("baseRefName")
    if base not in ("main", "prelive"):
        continue
    for check in pr.get("statusCheckRollup") or []:
        if not isinstance(check, dict):
            continue
        conclusion = str(check.get("conclusion") or "")
        state = str(check.get("state") or "")
        if conclusion.upper() == "FAILURE" or state.upper() == "FAILURE":
            failures.append(pr)
            break

lines = [
    "# Release watch %s" % repo,
    "",
    "Window start: %s (search merged:>=%s)." % (cutoff.isoformat(timespec="seconds"), since),
    "",
    "## Merged into main or prelive",
    "",
]
if not merged:
    lines.append("None.")
else:
    for pr in merged:
        lines.append("- #%s %s (%s) at %s" % (
            pr.get("number"), pr.get("title"), pr.get("baseRefName"), pr.get("mergedAt")))
lines.extend(["", "## Open pull requests with a failing check", ""])
if not failures:
    lines.append("None.")
else:
    for pr in failures:
        lines.append("- #%s %s (%s)" % (pr.get("number"), pr.get("title"), pr.get("baseRefName")))
lines.append("")
text = "\n".join(lines)
Path(report_path).write_text(text, encoding="utf-8")
Path(digest_path).write_text(text, encoding="utf-8")
if failures:
    summary = "blocked: %s open pull request(s) targeting main or prelive have a failing check" % len(failures)
    status = "blocked"
else:
    summary = "succeeded: %s merged, no failing checks on open main or prelive pull requests" % len(merged)
    status = "succeeded"
Path(summary_path).write_text(summary + "\n", encoding="utf-8")
Path(summary_path).with_name("status.txt").write_text(status + "\n", encoding="utf-8")
PY

status=$(tr -d '[:space:]' <"$job_dir/status.txt")
write_result "$status" "$summary_file" ""
exit 0
