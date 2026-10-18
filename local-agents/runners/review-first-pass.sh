#!/usr/bin/env bash
# review-first-pass.sh - diff, semgrep, gitleaks, then one other-family review.
# The reviewer is refused before any model call when author_family matches.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
summary_file=$job_dir/summary.txt
report=$job_dir/report.md
id=$(job_get id)
task=$(job_get task)
pr_ref=$(job_input "pr:")
reviewer=$(job_get reviewer)
author_family=$(job_get author_family)

if [ "$task" != "review" ]; then
  printf '%s\n' "task not allowed" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

if [ -z "$reviewer" ]; then
  reviewer=agy/gemini-3.8-flash-high
fi

python3 - "$author_family" "$reviewer" <<'PY'
import sys

author = sys.argv[1].strip().lower()
spec = sys.argv[2].strip().lower()
if not author:
    raise SystemExit(0)
harness, sep, model = spec.partition("/")
families = set()
if harness:
    families.add(harness)
if sep and model:
    vendor = model.split("-", 1)[0]
    if vendor:
        families.add(vendor)
if author in families:
    raise SystemExit(2)
raise SystemExit(0)
PY
family_rc=$?
if [ "$family_rc" -eq 2 ]; then
  printf '%s\n' "refused: reviewer family matches author_family ($author_family vs $reviewer)" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

case "$pr_ref" in
  */*\#[0-9]*) ;;
  *)
    printf '%s\n' "missing pr:owner/repo#N input" >"$summary_file"
    write_result failed "$summary_file" ""
    exit 0
    ;;
esac

repo=${pr_ref%%#*}
number=${pr_ref##*#}
case "$repo" in
  [A-Za-z0-9._-]*/[A-Za-z0-9._-]*) ;;
  *)
    printf '%s\n' "bad pull request repo" >"$summary_file"
    write_result failed "$summary_file" ""
    exit 0
    ;;
esac
case "$number" in
  ''|*[!0-9]*)
    printf '%s\n' "bad pull request number" >"$summary_file"
    write_result failed "$summary_file" ""
    exit 0
    ;;
esac

if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  printf '%s\n' "bad pull request repo" >"$summary_file"
  write_result failed "$summary_file" ""
  exit 0
fi

workdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-review.XXXXXX")
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

set +e
gh pr diff -R "$repo" "$number" >"$job_dir/pr.diff" 2>"$job_dir/gh-diff.err"
diff_rc=$?
gh pr view -R "$repo" "$number" --json files,headRefOid >"$job_dir/pr-view.json" 2>"$job_dir/gh-view.err"
view_rc=$?
set -e

if [ "$diff_rc" -ne 0 ] || [ "$view_rc" -ne 0 ]; then
  printf '%s\n' "gh pr diff or view failed" >"$summary_file"
  write_result failed "$summary_file" "diff exit $diff_rc; view exit $view_rc"
  exit 0
fi

python3 - "$repo" "$job_dir/pr-view.json" "$workdir" <<'PY'
import base64
import json
import subprocess
import sys
from pathlib import Path

repo, view_path, work = sys.argv[1], sys.argv[2], Path(sys.argv[3])
view = json.loads(Path(view_path).read_text(encoding="utf-8"))
files = view.get("files") or []
head = str(view.get("headRefOid") or "")
note = work / "fetch-note.txt"
if not isinstance(files, list):
    note.write_text("files payload was not a list\n", encoding="utf-8")
    raise SystemExit(0)
if len(files) > 200:
    note.write_text("skipped content scan: %s files\n" % len(files), encoding="utf-8")
    raise SystemExit(0)
if not head:
    note.write_text("missing head sha\n", encoding="utf-8")
    raise SystemExit(0)
written = 0
for item in files:
    if not isinstance(item, dict):
        continue
    path = item.get("path")
    if not isinstance(path, str) or path.startswith("/") or ".." in path.split("/"):
        continue
    proc = subprocess.run(
        ["gh", "api", "repos/%s/contents/%s?ref=%s" % (repo, path, head)],
        capture_output=True, text=True, timeout=60, check=False,
    )
    if proc.returncode != 0:
        continue
    try:
        payload = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        continue
    if not isinstance(payload, dict) or payload.get("encoding") != "base64":
        continue
    raw = payload.get("content") or ""
    try:
        data = base64.b64decode(raw)
    except (ValueError, TypeError):
        continue
    dest = work / "tree" / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    written += 1
note.write_text("fetched %s files\n" % written, encoding="utf-8")
PY

semgrep_note="semgrep: not installed"
semgrep_bin=$HOME/.venvs/gate/bin/semgrep
tree=$workdir/tree
if [ -d "$tree" ] && [ -x "$semgrep_bin" ]; then
  set +e
  "$semgrep_bin" --config p/owasp-top-ten --metrics=off --json --quiet "$tree" \
    >"$job_dir/semgrep.json" 2>"$job_dir/semgrep.err"
  semgrep_rc=$?
  set -e
  semgrep_note="semgrep exit: $semgrep_rc"
fi

gitleaks_note="gitleaks: not installed"
if [ -d "$tree" ] && command -v gitleaks >/dev/null 2>&1; then
  set +e
  gitleaks detect --no-git --source "$tree" --redact --report-format json \
    --report-path "$job_dir/gitleaks.json" >"$job_dir/gitleaks.err" 2>&1
  gitleaks_rc=$?
  set -e
  gitleaks_note="gitleaks exit: $gitleaks_rc"
fi

python3 - "$job_dir" "$workdir/fetch-note.txt" "$summary_file" "$report" "$semgrep_note" "$gitleaks_note" <<'PY'
import json
import sys
from pathlib import Path

job_dir = Path(sys.argv[1])
note_path, summary_path, report_path = Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
semgrep_note, gitleaks_note = sys.argv[5], sys.argv[6]
fetch_note = note_path.read_text(encoding="utf-8").strip() if note_path.is_file() else ""
semgrep_count = 0
top = []
semgrep_path = job_dir / "semgrep.json"
if semgrep_path.is_file():
    try:
        payload = json.loads(semgrep_path.read_text(encoding="utf-8") or "{}")
    except json.JSONDecodeError:
        payload = {}
    results = payload.get("results") if isinstance(payload, dict) else None
    if isinstance(results, list):
        semgrep_count = len(results)
        for item in results[:5]:
            if isinstance(item, dict):
                top.append("%s %s" % (item.get("check_id"), item.get("path")))
leak_count = 0
leak_path = job_dir / "gitleaks.json"
if leak_path.is_file():
    try:
        leaks = json.loads(leak_path.read_text(encoding="utf-8") or "[]")
    except json.JSONDecodeError:
        leaks = []
    if isinstance(leaks, list):
        leak_count = len(leaks)
        for item in leaks[:5]:
            if isinstance(item, dict):
                top.append("gitleaks %s" % item.get("RuleID") or item.get("Description"))
lines = [
    "# Review first pass",
    "",
    fetch_note,
    semgrep_note,
    gitleaks_note,
    "semgrep findings: %s" % semgrep_count,
    "gitleaks findings: %s" % leak_count,
    "",
    "## Top findings",
    "",
]
if top:
    lines.extend("- %s" % item for item in top[:8])
else:
    lines.append("None.")
text = "\n".join(lines) + "\n"
report_path.write_text(text, encoding="utf-8")
summary = [
    "semgrep %s; gitleaks %s; %s" % (semgrep_count, leak_count, fetch_note),
]
summary.extend(top[:8])
summary_path.write_text("\n".join(summary) + "\n", encoding="utf-8")
PY

prompt=$job_dir/prompt.md
{
  printf '%s\n\n' "$(cat "$job_dir/agent.md")"
  printf '%s\n\n' "$(cat "$report")"
  printf '%s\n' "Review the diff in pr.diff. Write a Markdown report. First section '## Summary' max 10 lines. Do not suggest publishing secrets."
  printf '\n%s\n' "$(cat "$job_dir/pr.diff")"
} >"$prompt"

harness=${reviewer%%/*}
model=""
case "$reviewer" in
  */*) model=${reviewer#*/} ;;
esac

run_review() {
  if [ -n "$model" ]; then
    llm-run "$harness" --task "$id" --agent local-review-first-pass --role scout --model "$model" -- \
      -p --output-format text <"$prompt"
  else
    llm-run "$harness" --task "$id" --agent local-review-first-pass --role scout -- \
      -p --output-format text <"$prompt"
  fi
}

if [ "$harness" = "agy" ]; then
  prompt_bytes=$(wc -c <"$prompt" | tr -d '[:space:]')
  if [ "$prompt_bytes" -gt 100000 ]; then
    printf '%s\n' "review prompt exceeds the agy argument cap" >"$summary_file"
    write_result failed "$summary_file" ""
    exit 0
  fi
  prompt_text=$(cat "$prompt")
  set +e
  LLM_RUN_BIN=agy llm-run gemini --task "$id" --agent local-review-first-pass --role scout \
    --model "${model:-gemini-3.8-flash-high}" -- \
    --model "${model:-gemini-3.8-flash-high}" --output-format text -p "$prompt_text" \
    >"$job_dir/llm-review.md" 2>"$job_dir/llm.err"
  llm_rc=$?
  set -e
else
  set +e
  run_review >"$job_dir/llm-review.md" 2>"$job_dir/llm.err"
  llm_rc=$?
  set -e
fi

if [ -s "$job_dir/llm-review.md" ]; then
  cat "$job_dir/llm-review.md" >>"$report"
fi

if [ "$llm_rc" -ne 0 ]; then
  printf '%s\n' "review model failed after the local checks" >"$summary_file"
  write_result failed "$summary_file" "llm exit $llm_rc"
  exit 0
fi

write_result succeeded "$summary_file" ""
exit 0
