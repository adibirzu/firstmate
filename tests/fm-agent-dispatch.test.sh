#!/usr/bin/env bash
# Behavior tests for the local-agent dispatcher and its runners.
set -u

# shellcheck disable=SC1091 source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

set -euo pipefail

DISPATCH=$ROOT/bin/fm-agent-dispatch.py
CFG=$ROOT/local-agents/agents.json
TMP_ROOT=$(fm_test_tmproot fm-agent-dispatch)
unset FM_AGENT_NOW || true
export FM_AGENT_STATE=$TMP_ROOT/state
mkdir -p "$FM_AGENT_STATE"
FM_AGENT_TEST_PIDS=$TMP_ROOT/live-pids
: >"$FM_AGENT_TEST_PIDS"

track_pid() {
  printf '%s\n' "$1" >>"$FM_AGENT_TEST_PIDS"
}

agent_test_cleanup() {
  local pid
  if [ -f "${FM_AGENT_TEST_PIDS:-}" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
    done <"$FM_AGENT_TEST_PIDS"
  fi
  fm_test_cleanup
}
trap agent_test_cleanup EXIT
trap 'agent_test_cleanup; exit 130' INT
trap 'agent_test_cleanup; exit 143' TERM
trap 'agent_test_cleanup; exit 129' HUP
trap 'agent_test_cleanup; exit 131' QUIT

assert_py() {
  local label=$1
  local script=$2
  local payload=$3
  printf '%s' "$payload" | python3 -c "$script" || fail "$label"
}

write_job_file() {
  local path=$1
  local body=$2
  printf '%s\n' "$body" >"$path"
}

test_parse_job_without_pyyaml() {
  local file=$TMP_ROOT/job-ok.md
  local out
  write_job_file "$file" "$(cat <<'EOF'
```yaml
job: research/v1
id: res-test-01
task: research
host_pref: [ "adi2", "adi1" ]
budget: { wall_max: "45m" }
inputs:
  - repo:adibirzu/firstmate
```
EOF
)"
  out=$(FM_AGENT_NO_PYYAML=1 python3 "$DISPATCH" parse-job "$file" --config "$CFG")
  assert_py "fallback parser fields" '
import json, sys
data = json.load(sys.stdin)
assert data["id"] == "res-test-01"
assert data["task"] == "research"
assert data["host_pref"] == ["adi2", "adi1"]
assert data["budget"]["wall_max"] == "45m"
assert data["wall_seconds"] == 2700
assert data["inputs"] == ["repo:adibirzu/firstmate"]
' "$out"
  pass "parse-job fallback parser"
}

test_parse_job_with_pyyaml_loader() {
  local file=$TMP_ROOT/job-ok.md
  local out
  out=$(env -u FM_AGENT_NO_PYYAML python3 "$DISPATCH" parse-job "$file" --config "$CFG")
  assert_py "default parser fields" '
import json, sys
data = json.load(sys.stdin)
assert data["id"] == "res-test-01"
assert data["inputs"] == ["repo:adibirzu/firstmate"]
assert data["wall_seconds"] == 2700
' "$out"
  pass "parse-job default loader"
}

test_validation_failures() {
  local bad=$TMP_ROOT/bad-id.md
  local task=$TMP_ROOT/bad-task.md
  local mismatch=$TMP_ROOT/mismatch.md
  local out rc
  write_job_file "$bad" "$(cat <<'EOF'
```yaml
job: research/v1
id: x
task: research
```
EOF
)"
  write_job_file "$task" "$(cat <<'EOF'
```yaml
job: research/v1
id: res-test-01
task: probe
```
EOF
)"
  write_job_file "$mismatch" "$(cat <<'EOF'
```yaml
job: studio-media/v1
id: media-test-01
task: probe
```
EOF
)"
  local too_long=$TMP_ROOT/too-long.md
  write_job_file "$too_long" "$(cat <<'EOF'
```yaml
job: research/v1
id: res-test-01
task: research
budget: { wall_max: "7h" }
```
EOF
)"
  set +e
  out=$(FM_AGENT_NO_PYYAML=1 python3 "$DISPATCH" parse-job "$bad" --config "$CFG" --label agent:research 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "bad id should exit 1"
  assert_contains "$out" "bad id" "bad id error"
  set +e
  out=$(FM_AGENT_NO_PYYAML=1 python3 "$DISPATCH" parse-job "$task" --config "$CFG" --label agent:research 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "task not allowed should exit 1"
  assert_contains "$out" "task not allowed" "task error"
  set +e
  out=$(FM_AGENT_NO_PYYAML=1 python3 "$DISPATCH" parse-job "$mismatch" --config "$CFG" --label agent:research 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "mismatch should exit 1"
  assert_contains "$out" "job/agent mismatch" "mismatch error"
  assert_not_contains "$out" "task not allowed" "mismatch must win over task"
  set +e
  out=$(FM_AGENT_NO_PYYAML=1 python3 "$DISPATCH" parse-job "$too_long" --config "$CFG" --label agent:research 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "over-cap wall should exit 1"
  assert_contains "$out" "wall_max exceeds 6h" "over-cap wall error"
  pass "validation failures"
}

test_window_and_capacity() {
  local state out
  state=$TMP_ROOT/window-state
  mkdir -p "$state"
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T17:59:59+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media --host-pref adi1)
  assert_py "adi1 closed before not_before" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "blocked", data
assert "textbook OCR" in data["reason"], data
' "$out"
  mkdir -p "$state/windows"
  : >"$state/windows/adi1-media.open"
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T17:59:59+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media --host-pref adi1)
  assert_py "adi1 stays closed before not_before when the file exists" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "blocked", data
assert "textbook OCR" in data["reason"], data
' "$out"
  rm -f "$state/windows/adi1-media.open"
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T18:00:00+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media --host-pref adi1)
  assert_py "adi1 closed when open file is missing" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "blocked", data
assert "windows/adi1-media.open" in data["reason"], data
assert "textbook OCR" in data["reason"], data
' "$out"
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T18:00:00+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media)
  assert_py "adi2 while adi1 closed" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "run", data
assert data["host"] == "adi2", data
' "$out"
  : >"$state/windows/adi1-media.open"
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T18:00:00+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media --host-pref adi1)
  assert_py "adi1 open at window" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "run", data
assert data["host"] == "adi1", data
' "$out"

  state=$TMP_ROOT/capacity-state
  mkdir -p "$state/running" "$state/windows"
  : >"$state/windows/adi1-media.open"
  python3 - "$state/running" "$$" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
pid = int(sys.argv[2])
for name, host in (("one.json", "adi2"), ("two.json", "adi2")):
    (root / name).write_text(json.dumps({"job_id": name, "host": host, "pid": pid}), encoding="utf-8")
PY
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T19:00:00+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media)
  assert_py "adi2 full chooses adi1" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "run", data
assert data["host"] == "adi1", data
' "$out"
  python3 - "$state/running" "$$" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
pid = int(sys.argv[2])
for name, host in (("three.json", "adi1"), ("four.json", "adi1")):
    (root / name).write_text(json.dumps({"job_id": name, "host": host, "pid": pid}), encoding="utf-8")
PY
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T19:00:00+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media)
  assert_py "both hosts full retries" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "retry", data
' "$out"
  pass "window and max_jobs"
}

test_open_file_path_rejected() {
  local bad out rc
  bad=$TMP_ROOT/bad-open-file.json
  python3 - "$CFG" "$bad" <<'PY'
import json
import sys
from pathlib import Path

source, dest = sys.argv[1:]
data = json.loads(Path(source).read_text(encoding="utf-8"))
data["windows"]["adi1-media"]["open_file"] = "windows/../../etc/adi1-media.open"
Path(dest).write_text(json.dumps(data), encoding="utf-8")
PY
  set +e
  out=$(python3 "$DISPATCH" select-host --config "$bad" --agent studio-media 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "open_file with .. should be rejected"
  assert_contains "$out" "open_file" "dotdot open_file error"
  python3 - "$CFG" "$bad" <<'PY'
import json
import sys
from pathlib import Path

source, dest = sys.argv[1:]
data = json.loads(Path(source).read_text(encoding="utf-8"))
data["windows"]["adi1-media"]["open_file"] = "/var/tmp/adi1-media.open"
Path(dest).write_text(json.dumps(data), encoding="utf-8")
PY
  set +e
  out=$(python3 "$DISPATCH" select-host --config "$bad" --agent studio-media 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "absolute open_file should be rejected"
  assert_contains "$out" "open_file" "absolute open_file error"
  pass "open_file traversal rejected"
}

test_render_result_neutralises() {
  local file=$TMP_ROOT/result.json
  local out=$TMP_ROOT/result.md
  python3 - "$file" <<'PY'
import json
import sys
from pathlib import Path

lines = ["```marker"]
index = 2
while index <= 10:
    lines.append("L%02dKEEP" % index)
    index += 1
lines.append("L11SHOULDNOTAPPEAR")
lines.append("L12NO")
payload = {
    "job": "res-test-01",
    "agent": "research",
    "host": "adi2",
    "status": "succeeded",
    "summary": "\n".join(lines),
    "repo": "adibirzu/firstmate",
    "issue": 7,
}
Path(sys.argv[1]).write_text(json.dumps(payload), encoding="utf-8")
PY
  python3 "$DISPATCH" render-result "$file" >"$out"
  python3 - "$out" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.index("```yaml\n") + len("```yaml\n")
end = text.rindex("\n```")
body = text[start:end]
if text.count("```") != 2:
    raise SystemExit("expected only the outer fences, got %s" % text.count("```"))
if "```" in body:
    raise SystemExit("fence leaked into the yaml body")
if "'''marker" not in body:
    raise SystemExit("backtick run was not neutralised")
if "L10KEEP" not in body:
    raise SystemExit("line 10 was truncated")
if "L11SHOULDNOTAPPEAR" in text:
    raise SystemExit("line 11 was kept")
if not text.startswith("**Local agent result**"):
    raise SystemExit("missing result header")
PY
  pass "render-result neutralises and truncates"
}

install_issue_gh() {
  local bin=$1
  mkdir -p "$bin"
  cat >"$bin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${GH_LOG:?}"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  repo=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "-R" ]; then
      repo=$arg
    fi
    prev=$arg
  done
  if [ "$repo" = "adibirzu/firstmate" ] && [ -n "${GH_ISSUE_FILE:-}" ]; then
    cat "$GH_ISSUE_FILE"
  else
    printf '%s\n' "[]"
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$bin/gh"
}

install_stateful_gh() {
  local bin=$1
  mkdir -p "$bin"
  cat >"$bin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${GH_LOG:?}"
cmd=${1:-}
sub=${2:-}
if [ "$cmd" = "issue" ] && [ "$sub" = "list" ]; then
  if [ "${GH_SLOW_ONCE:-}" = "1" ] && [ ! -f "${GH_SLOW_FLAG:?}" ]; then
    : >"$GH_SLOW_FLAG"
    exec python3 -c 'import os, time; time.sleep(30); open(os.environ["GH_END"], "w", encoding="utf-8").write("end\n")'
  fi
  if [ -n "${GH_CRIT:-}" ]; then
    if ! mkdir "$GH_CRIT" 2>/dev/null; then
      printf '%s\n' "overlap" >>"${GH_OVERLAP:?}"
    else
      sleep 0.2
      rmdir "$GH_CRIT" 2>/dev/null || true
    fi
  fi
  if [ "${GH_LIST_EMPTY:-}" = "1" ] || [ -z "${GH_ISSUE_FILE:-}" ]; then
    printf '%s\n' "[]"
    exit 0
  fi
  repo=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "-R" ]; then
      repo=$arg
    fi
    prev=$arg
  done
  if [ "$repo" = "adibirzu/firstmate" ]; then
    cat "$GH_ISSUE_FILE"
  else
    printf '%s\n' "[]"
  fi
  exit 0
fi
if [ "$cmd" = "issue" ] && [ "$sub" = "view" ]; then
  if [ -n "${GH_COMMENTS_FILE:-}" ] && [ -f "$GH_COMMENTS_FILE" ]; then
    cat "$GH_COMMENTS_FILE"
  else
    printf '%s\n' '{"comments":[]}'
  fi
  exit 0
fi
if [ "$cmd" = "issue" ] && [ "$sub" = "comment" ]; then
  fails=0
  if [ -n "${GH_COMMENT_FAILS_FILE:-}" ] && [ -f "$GH_COMMENT_FAILS_FILE" ]; then
    fails=$(tr -d '[:space:]' <"$GH_COMMENT_FAILS_FILE")
  fi
  if [ "${fails:-0}" -gt 0 ]; then
    printf '%s\n' "$((fails - 1))" >"$GH_COMMENT_FAILS_FILE"
    printf '%s\n' "comment failed" >&2
    exit 1
  fi
  if [ -n "${GH_COMMENT_LOG:-}" ]; then
    printf '%s\n' "$*" >>"$GH_COMMENT_LOG"
  fi
  if [ "${GH_COMMENT_MIRROR:-}" = "1" ] && [ -n "${GH_COMMENTS_FILE:-}" ]; then
    mirror_body=""
    mirror_file=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--body" ]; then
        mirror_body=$arg
      elif [ "$prev" = "--body-file" ]; then
        mirror_file=$arg
      fi
      prev=$arg
    done
    python3 - "$GH_COMMENTS_FILE" "$mirror_body" "$mirror_file" <<'PY'
import json
import sys
from pathlib import Path

path, body, body_file = sys.argv[1:4]
text = body
if body_file:
    text = Path(body_file).read_text(encoding="utf-8")
if text == "" and body_file == "":
    raise SystemExit(0)
file = Path(path)
payload = {"comments": []}
if file.is_file():
    try:
        loaded = json.loads(file.read_text(encoding="utf-8") or "{}")
    except json.JSONDecodeError:
        loaded = {}
    if isinstance(loaded, dict) and isinstance(loaded.get("comments"), list):
        payload = loaded
comments = payload.get("comments")
if not isinstance(comments, list):
    comments = []
    payload["comments"] = comments
comments.append({"body": text})
file.write_text(json.dumps(payload), encoding="utf-8")
PY
  fi
  exit 0
fi
if [ "$cmd" = "issue" ] && [ "$sub" = "edit" ]; then
  fails=0
  if [ -n "${GH_EDIT_FAILS_FILE:-}" ] && [ -f "$GH_EDIT_FAILS_FILE" ]; then
    fails=$(tr -d '[:space:]' <"$GH_EDIT_FAILS_FILE")
  fi
  if [ "${fails:-0}" -gt 0 ]; then
    printf '%s\n' "$((fails - 1))" >"$GH_EDIT_FAILS_FILE"
    printf '%s\n' "edit failed" >&2
    exit 1
  fi
  if [ -n "${GH_EDIT_LOG:-}" ]; then
    printf '%s\n' "$*" >>"$GH_EDIT_LOG"
  fi
  exit 0
fi
if [ "$cmd" = "pr" ]; then
  printf '%s\n' "[]"
  exit 0
fi
exit 0
SH
  chmod +x "$bin/gh"
}

write_issue() {
  local path=$1
  local login=$2
  local number=$3
  local job_id=$4
  python3 - "$path" "$login" "$number" "$job_id" <<'PY'
import json
import sys
from pathlib import Path

path, login, number, job_id = sys.argv[1:5]
body = "```yaml\njob: release-watch/v1\nid: %s\ntask: poll\n```\n" % job_id
issue = [{
    "number": int(number),
    "title": "Watch releases",
    "body": body,
    "labels": [{"name": "agent:release-watch"}, {"name": "state:queued"}],
    "author": {"login": login},
    "url": "https://github.com/adibirzu/firstmate/issues/%s" % number,
}]
Path(path).write_text(json.dumps(issue), encoding="utf-8")
PY
}

test_unknown_author_is_ignored() {
  local state=$TMP_ROOT/ignore-state
  local bin=$TMP_ROOT/ignore-bin
  local issues=$TMP_ROOT/ignore-issues.json
  local log=$TMP_ROOT/ignore-gh.log
  local saved=$PATH
  mkdir -p "$state"
  install_issue_gh "$bin"
  write_issue "$issues" "someone" 7 "rel-watch-01"
  : >"$log"
  PATH="$bin:$PATH" \
    GH_LOG="$log" \
    GH_ISSUE_FILE="$issues" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --dry-run --config "$CFG"
  PATH=$saved
  assert_grep "issue list" "$log" "list was not called"
  assert_no_grep "issue edit" "$log" "unknown author was edited"
  assert_no_grep "issue comment" "$log" "unknown author was commented"
  assert_grep "ignore adibirzu/firstmate#7 author someone" "$state/dispatch.log" "ignore was not logged"
  pass "unknown author ignored"
}

test_dry_run_claims_without_runner() {
  local state=$TMP_ROOT/dry-state
  local bin=$TMP_ROOT/dry-bin
  local issues=$TMP_ROOT/dry-issues.json
  local log=$TMP_ROOT/dry-gh.log
  local saved=$PATH
  mkdir -p "$state/running"
  install_issue_gh "$bin"
  write_issue "$issues" "adibirzu" 42 "rel-watch-01"
  : >"$log"
  PATH="$bin:$PATH" \
    GH_LOG="$log" \
    GH_ISSUE_FILE="$issues" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --dry-run --config "$CFG"
  PATH=$saved
  assert_no_grep "issue edit" "$log" "dry-run edited the issue"
  assert_no_grep "issue comment" "$log" "dry-run commented on the issue"
  assert_grep "dry-run: would claim rel-watch-01" "$state/dispatch.log" "dry-run did not log the claim"
  assert_grep "dry-run: not starting rel-watch-01" "$state/dispatch.log" "dry-run did not skip the runner"
  if find "$state/running" -type f -name '*.json' | grep -q .; then
    fail "dry-run wrote a running record"
  fi
  pass "dry-run does not mutate and does not start a runner"
}

prepare_job() {
  local dir=$1
  local json_text=$2
  mkdir -p "$dir"
  printf '%s\n' "$json_text" >"$dir/job.json"
  printf '%s\n' "brief" >"$dir/brief.md"
  printf '%s\n' "agent" >"$dir/agent.md"
}

test_runner_smokes() {
  local saved=$PATH
  local home=$TMP_ROOT/home
  local bin=$TMP_ROOT/runner-bin
  local job result
  mkdir -p "$home" "$bin"
  cat >"$bin/llm-run" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${LLM_LOG:?}"
cat >/dev/null
if [[ "$*" == *claude* ]]; then
  printf '%s\n' "## Summary" "A short finding."
  exit 0
fi
printf '%s\n' "called" > "${LLM_TOUCH:?}"
exit 1
SH
  cat >"$bin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$*" in
  *"--state merged"*)
    printf '%s\n' "[]"
    ;;
  *"--state open"*)
    cat "${OPEN_JSON:?}"
    ;;
  *"pr list"*)
    printf '%s\n' '[{"number":3,"title":"Fix latch","state":"MERGED","body":"Fixes #12","url":"https://example.test/3"}]'
    ;;
  *)
    printf '%s\n' "[]"
    ;;
esac
exit 0
SH
  cat >"$bin/df" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "Filesystem 1024-blocks Used Available Capacity Mounted"
printf '%s\n' "/dev/disk 100 90 1000 99% /"
SH
  cat >"$bin/ssh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat >"$bin/docker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat >"$bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$bin/llm-run" "$bin/gh" "$bin/df" "$bin/ssh" "$bin/docker" "$bin/nvidia-smi"

  job=$TMP_ROOT/research-job
  prepare_job "$job" '{"id":"res-test-01","task":"research","job":"research/v1"}'
  : >"$TMP_ROOT/llm.log"
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" LLM_LOG="$TMP_ROOT/llm.log" \
    bash "$ROOT/local-agents/runners/research.sh"
  result=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["summary"])' "$job/result.json")
  assert_contains "$result" "A short finding." "research summary"

  job=$TMP_ROOT/release-job
  prepare_job "$job" '{"id":"rel-watch-01","task":"poll","job":"release-watch/v1"}'
  python3 - "$TMP_ROOT/open.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps([{
    "number": 9,
    "title": "Red check",
    "baseRefName": "main",
    "statusCheckRollup": [{"conclusion": "FAILURE", "state": "COMPLETED"}],
}]), encoding="utf-8")
PY
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" \
    FM_AGENT_STATE="$TMP_ROOT/release-state" \
    GH_LOG="$TMP_ROOT/release-gh.log" OPEN_JSON="$TMP_ROOT/open.json" \
    bash "$ROOT/local-agents/runners/release-watch.sh"
  python3 - "$job/result.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["status"] != "blocked":
    raise SystemExit(data)
PY
  [ -s "$TMP_ROOT/release-state/digest.md" ] || fail "digest was not written"

  job=$TMP_ROOT/map-job
  prepare_job "$job" '{"id":"map-test-01","task":"map","job":"issue-mapper/v1","_dispatch":{"repo":"adibirzu/firstmate"}}'
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" GH_LOG="$TMP_ROOT/map-gh.log" \
    bash "$ROOT/local-agents/runners/issue-mapper.sh"
  assert_grep "#12" "$job/report.md" "closing reference missing"

  job=$TMP_ROOT/review-job
  prepare_job "$job" '{"id":"rev-test-01","task":"review","job":"review-first-pass/v1","author_family":"gemini"}'
  rm -f "$TMP_ROOT/llm-touch"
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" \
    LLM_LOG="$TMP_ROOT/review-llm.log" LLM_TOUCH="$TMP_ROOT/llm-touch" \
    bash "$ROOT/local-agents/runners/review-first-pass.sh"
  python3 - "$job/result.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["status"] != "failed" or "reviewer family" not in data["summary"]:
    raise SystemExit(data)
PY
  [ ! -e "$TMP_ROOT/llm-touch" ] || fail "same-family review called a model"

  job=$TMP_ROOT/licence-job
  prepare_job "$job" '{"id":"media-test-01","task":"probe","job":"studio-media/v1"}'
  printf '%s\n' "Please render this with hunyuanvideo." >"$job/brief.md"
  cp "$ROOT/local-agents/studio-media/candidates.yaml" "$job/candidates.yaml"
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" \
    bash "$ROOT/local-agents/runners/studio-media.sh"
  python3 - "$job/result.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["status"] != "failed" or "excluded model" not in data["summary"]:
    raise SystemExit(data)
PY

  job=$TMP_ROOT/subtitle-job
  mkdir -p "$home/media"
  python3 - "$home/media/clip.srt" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("1\n00:00:00,000 --> 00:00:01,000\n\u015ft line that is definitely longer than forty two characters\n", encoding="utf-8")
PY
  prepare_job "$job" "$(python3 - "$home/media/clip.srt" <<'PY'
import json, sys
print(json.dumps({
    "id": "media-test-02",
    "task": "subtitle-lint",
    "job": "studio-media/v1",
    "inputs": ["path:" + sys.argv[1]],
}))
PY
)"
  cp "$ROOT/local-agents/studio-media/candidates.yaml" "$job/candidates.yaml"
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" \
    bash "$ROOT/local-agents/runners/studio-media.sh"
  python3 - "$job/result.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["status"] != "failed":
    raise SystemExit(data)
text = data["summary"]
if "cedilla" not in text or "42" not in text:
    raise SystemExit(data)
PY

  job=$TMP_ROOT/gen-job
  prepare_job "$job" '{"id":"media-test-03","task":"assemble","job":"studio-media/v1"}'
  cp "$ROOT/local-agents/studio-media/candidates.yaml" "$job/candidates.yaml"
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" \
    bash "$ROOT/local-agents/runners/studio-media.sh"
  python3 - "$job/result.json" "$home/.local-agents/media-ledger.jsonl" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
expected = "v1: generative pipeline not wired to LVS/GPU window yet (#139)"
if data["status"] != "blocked" or data["summary"] != expected:
    raise SystemExit(data)
rows = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8") if line.strip()]
if not rows or rows[-1]["status"] != "planned" or rows[-1]["task"] != "assemble":
    raise SystemExit(rows)
PY

  job=$TMP_ROOT/fleet-job
  prepare_job "$job" '{"id":"fleet-test-01","task":"check","job":"fleet-monitor/v1"}'
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" \
    bash "$ROOT/local-agents/runners/fleet-monitor.sh"
  python3 - "$job/result.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["status"] != "blocked":
    raise SystemExit(data)
PY

  job=$TMP_ROOT/ocr-job
  prepare_job "$job" '{"id":"ocr-test-01","task":"status","job":"ocr-runner/v1"}'
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" \
    bash "$ROOT/local-agents/runners/ocr-runner.sh"
  python3 - "$job/result.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["status"] != "blocked":
    raise SystemExit(data)
PY
  PATH=$saved
  pass "runner smokes"
}

test_shell_syntax() {
  local file
  local files=(
    "$ROOT/local-agents/runners/lib.sh"
    "$ROOT/local-agents/runners/research.sh"
    "$ROOT/local-agents/runners/release-watch.sh"
    "$ROOT/local-agents/runners/fleet-monitor.sh"
    "$ROOT/local-agents/runners/ocr-runner.sh"
    "$ROOT/local-agents/runners/review-first-pass.sh"
    "$ROOT/local-agents/runners/issue-mapper.sh"
    "$ROOT/local-agents/runners/studio-media.sh"
    "$ROOT/local-agents/fm-agent-dispatch.tmux.sh"
  )
  for file in "${files[@]}"; do
    bash -n "$file" || fail "bash -n failed for $file"
  done
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -P "$ROOT/local-agents/runners" "${files[@]}" || fail "shellcheck reported findings"
  fi
  pass "bash -n and shellcheck"
}

record_phase() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("phase", ""))' "$1"
}

run_parse() {
  local file=$1
  shift
  set +e
  PARSE_OUT=$(FM_AGENT_NO_PYYAML=1 python3 "$DISPATCH" parse-job "$file" --config "$CFG" "$@" 2>&1)
  PARSE_RC=$?
  set -e
}

test_job_schema() {
  local unknown=$TMP_ROOT/schema-unknown.md
  local evil=$TMP_ROOT/schema-evil.md
  local other=$TMP_ROOT/schema-other-repo.md
  local same=$TMP_ROOT/schema-same-repo.md
  local implicit=$TMP_ROOT/schema-implicit.md
  local alt=$TMP_ROOT/schema-agents.json
  local out
  write_job_file "$unknown" "$(cat <<'EOF'
```yaml
job: research/v1
id: res-test-01
task: research
create: true
```
EOF
)"
  run_parse "$unknown" --label agent:research
  [ "$PARSE_RC" -eq 1 ] || fail "create on research should exit 1"
  assert_contains "$PARSE_OUT" "unknown job field: create" "create is not a research field"

  write_job_file "$evil" "$(cat <<'EOF'
```yaml
job: issue-mapper/v1
id: map-test-01
task: map
inputs:
  - repo:evil/x
```
EOF
)"
  run_parse "$evil" --label agent:issue-mapper --repo adibirzu/firstmate
  [ "$PARSE_RC" -eq 1 ] || fail "evil repo should exit 1"
  assert_contains "$PARSE_OUT" "repo is not allowed: evil/x" "evil repo was accepted"

  write_job_file "$other" "$(cat <<'EOF'
```yaml
job: issue-mapper/v1
id: map-test-01
task: map
create: true
inputs:
  - repo:adibirzu/mini-tools
```
EOF
)"
  run_parse "$other" --label agent:issue-mapper --repo adibirzu/firstmate
  [ "$PARSE_RC" -eq 1 ] || fail "foreign create target should exit 1"
  assert_contains "$PARSE_OUT" "create target is not allowed" "foreign create target was accepted"

  write_job_file "$same" "$(cat <<'EOF'
```yaml
job: issue-mapper/v1
id: map-test-01
task: map
create: true
inputs:
  - repo:adibirzu/firstmate
```
EOF
)"
  run_parse "$same" --label agent:issue-mapper --repo adibirzu/firstmate
  [ "$PARSE_RC" -eq 0 ] || fail "issue repo create was rejected: $PARSE_OUT"
  assert_py "create on the issue repo" '
import json, sys
data = json.load(sys.stdin)
assert data["create"] is True, data
assert data["inputs"] == ["repo:adibirzu/firstmate"], data
' "$PARSE_OUT"

  write_job_file "$implicit" "$(cat <<'EOF'
```yaml
job: issue-mapper/v1
id: map-test-02
task: map
create: true
```
EOF
)"
  set +e
  out=$(env -u FM_AGENT_NO_PYYAML python3 "$DISPATCH" parse-job "$implicit" --config "$CFG" --label agent:issue-mapper --repo adibirzu/firstmate 2>&1)
  PARSE_RC=$?
  set -e
  [ "$PARSE_RC" -eq 0 ] || fail "implicit issue repo create was rejected: $out"
  assert_py "create defaults to the issue repo" '
import json, sys
data = json.load(sys.stdin)
assert data["create"] is True, data
' "$out"

  python3 - "$CFG" "$alt" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
data["agents"]["issue-mapper"]["allowed_create_repos"] = ["adibirzu/mini-tools"]
Path(sys.argv[2]).write_text(json.dumps(data), encoding="utf-8")
PY
  set +e
  out=$(FM_AGENT_NO_PYYAML=1 python3 "$DISPATCH" parse-job "$other" --config "$alt" --label agent:issue-mapper --repo adibirzu/firstmate 2>&1)
  PARSE_RC=$?
  set -e
  [ "$PARSE_RC" -eq 0 ] || fail "allowed_create_repos rejected its repo: $out"
  set +e
  out=$(FM_AGENT_NO_PYYAML=1 python3 "$DISPATCH" parse-job "$same" --config "$alt" --label agent:issue-mapper --repo adibirzu/firstmate 2>&1)
  PARSE_RC=$?
  set -e
  [ "$PARSE_RC" -eq 1 ] || fail "allowed_create_repos should reject the issue repo"
  assert_contains "$out" "create target is not allowed" "allowed list did not bind create"

  local bad_pr=$TMP_ROOT/schema-bad-pr.md
  local foreign_pr=$TMP_ROOT/schema-foreign-pr.md
  local allowed_pr=$TMP_ROOT/schema-allowed-pr.md
  write_job_file "$bad_pr" "$(cat <<'EOF'
```yaml
job: review-first-pass/v1
id: rev-schema-01
task: review
inputs:
  - pr:not-a-pr
```
EOF
)"
  run_parse "$bad_pr" --label agent:review-first-pass
  [ "$PARSE_RC" -eq 1 ] || fail "bad pr input should exit 1"
  assert_contains "$PARSE_OUT" "bad pr input" "bad pr input was accepted"

  write_job_file "$foreign_pr" "$(cat <<'EOF'
```yaml
job: review-first-pass/v1
id: rev-schema-02
task: review
reviewer: claude:sonnet
author_family: gemini
inputs:
  - pr:evil/foreign#4
```
EOF
)"
  run_parse "$foreign_pr" --label agent:review-first-pass
  [ "$PARSE_RC" -eq 1 ] || fail "foreign pr repo should exit 1"
  assert_contains "$PARSE_OUT" "pr repo is not allowed: evil/foreign" "foreign pr repo was accepted"

  write_job_file "$allowed_pr" "$(cat <<'EOF'
```yaml
job: review-first-pass/v1
id: rev-schema-03
task: review
reviewer: claude:sonnet
author_family: gemini
inputs:
  - pr:adibirzu/firstmate#12
```
EOF
)"
  run_parse "$allowed_pr" --label agent:review-first-pass
  [ "$PARSE_RC" -eq 0 ] || fail "allowed pr repo was rejected: $PARSE_OUT"
  assert_py "allowed pr input" '
import json, sys
data = json.load(sys.stdin)
assert data["inputs"] == ["pr:adibirzu/firstmate#12"], data
' "$PARSE_OUT"
  pass "job schema rejects unknown fields, foreign repos, and foreign pull requests"
}

test_dry_run_recovery() {
  local state=$TMP_ROOT/dry-recover-state
  local bin=$TMP_ROOT/dry-recover-bin
  local issues=$TMP_ROOT/dry-recover-issues.json
  local log=$TMP_ROOT/dry-recover-gh.log
  local saved=$PATH
  mkdir -p "$state/running"
  install_issue_gh "$bin"
  write_issue "$issues" "adibirzu" 43 "rel-recover-01"
  : >"$log"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_ISSUE_FILE="$issues" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --dry-run --config "$CFG"
  assert_no_grep "issue edit" "$log" "dry-run recovery edited the issue"
  assert_no_grep "issue comment" "$log" "dry-run recovery commented"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_ISSUE_FILE="$issues" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  assert_grep "issue edit" "$log" "later loop did not claim"
  assert_grep "dispatcher: claimed rel-recover-01" "$log" "later loop did not comment the claim"
  pass "dry-run leaves the issue claimable"
}

test_dry_run_open_claim() {
  local state=$TMP_ROOT/dry-open-state
  local bin=$TMP_ROOT/dry-open-bin
  local issues=$TMP_ROOT/dry-open-issues.json
  local empty=$TMP_ROOT/dry-open-empty.json
  local log=$TMP_ROOT/dry-open-gh.log
  local saved=$PATH
  local record=$state/running/adibirzu-firstmate#44.json
  mkdir -p "$state/running"
  install_issue_gh "$bin"
  write_issue "$issues" "adibirzu" 44 "rel-claim-09"
  printf '%s\n' "[]" >"$empty"
  python3 - "$record" <<'PY'
import json
import sys
from pathlib import Path

record = {
    "phase": "claiming",
    "job_id": "rel-claim-09",
    "job": {
        "id": "rel-claim-09",
        "job": "release-watch/v1",
        "task": "poll",
        "agent": "release-watch",
    },
    "host": "mini",
    "pid": None,
    "pgid": None,
    "repo": "adibirzu/firstmate",
    "issue": 44,
    "agent": "release-watch",
    "had_queued": True,
    "had_running": False,
    "wall_seconds": 600,
    "title": "Watch",
    "body": "",
    "url": "",
}
Path(sys.argv[1]).write_text(json.dumps(record), encoding="utf-8")
PY
  : >"$log"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_ISSUE_FILE="$issues" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --dry-run --config "$CFG"
  assert_no_grep "issue edit" "$log" "dry-run resumed a claim with an edit"
  assert_no_grep "issue comment" "$log" "dry-run resumed a claim with a comment"
  assert_grep "dry-run: would resume claiming for rel-claim-09" "$state/dispatch.log" "dry-run did not describe the open claim"
  [ "$(record_phase "$record")" = "claiming" ] || fail "dry-run changed the open claim"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_ISSUE_FILE="$empty" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  assert_grep "issue edit" "$log" "resume did not edit the issue"
  assert_grep "dispatcher: claimed rel-claim-09" "$log" "resume did not comment the claim"
  pass "dry-run does not finish an open claim"
}

test_claim_transaction() {
  local state=$TMP_ROOT/claim-tx-state
  local bin=$TMP_ROOT/claim-tx-bin
  local issues=$TMP_ROOT/claim-tx-issues.json
  local log=$TMP_ROOT/claim-tx-gh.log
  local comment_log=$TMP_ROOT/claim-tx-comments.log
  local edit_fails=$TMP_ROOT/claim-tx-edit-fails
  local comment_fails=$TMP_ROOT/claim-tx-comment-fails
  local saved=$PATH
  local record=$state/running/adibirzu-firstmate#45.json
  local count
  mkdir -p "$state/running"
  install_stateful_gh "$bin"
  write_issue "$issues" "adibirzu" 45 "claim-tx-01"
  : >"$log"
  : >"$comment_log"
  printf '%s\n' "1" >"$edit_fails"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_ISSUE_FILE="$issues" \
    GH_COMMENT_LOG="$comment_log" \
    GH_EDIT_FAILS_FILE="$edit_fails" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  [ -f "$record" ] || fail "failed edit left no claim record"
  [ "$(record_phase "$record")" = "claiming" ] || fail "failed edit advanced the claim"
  [ ! -s "$comment_log" ] || fail "failed edit still posted a claim comment"

  printf '%s\n' "1" >"$comment_fails"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    GH_COMMENT_LOG="$comment_log" \
    GH_COMMENT_FAILS_FILE="$comment_fails" \
    GH_EDIT_FAILS_FILE="$edit_fails" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  [ -f "$record" ] || fail "failed claim comment dropped the record"
  [ "$(record_phase "$record")" = "claiming" ] || fail "failed claim comment advanced the phase"
  [ ! -s "$comment_log" ] || fail "failed claim comment was recorded as posted"

  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    GH_COMMENT_LOG="$comment_log" \
    GH_COMMENT_FAILS_FILE="$comment_fails" \
    GH_EDIT_FAILS_FILE="$edit_fails" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  count=$(grep -c "dispatcher: claimed claim-tx-01" "$comment_log" || true)
  [ "$count" -eq 1 ] || fail "claim comment was posted $count times"
  pass "claim transaction resumes after a partial failure"
}

test_result_transaction_and_redaction() {
  local state=$TMP_ROOT/result-tx-state
  local bin=$TMP_ROOT/result-tx-bin
  local log=$TMP_ROOT/result-tx-gh.log
  local comment_log=$TMP_ROOT/result-tx-comments.log
  local comment_fails=$TMP_ROOT/result-tx-comment-fails
  local edit_fails=$TMP_ROOT/result-tx-edit-fails
  local comments=$TMP_ROOT/result-tx-view.json
  local saved=$PATH
  local record=$state/running/adibirzu-firstmate#79.json
  local stage=$state/artifacts/rel-secret-01
  local before after
  mkdir -p "$state/running" "$stage"
  install_stateful_gh "$bin"
  python3 - "$stage/result.json" "$record" <<'PY'
import json
import sys
from pathlib import Path

result_path, record_path = sys.argv[1:3]

def parts(*chunks):
    return "".join(chunks)

bearer = parts("Bea", "rer ", "abcdefghijklmnop")
akia = parts("AK", "IA", "IOSFODNN7EXAMPLE")
pem_begin = parts("-----BEGIN ", "OPENSSH PRIVATE KEY-----")
pem_end = parts("-----END ", "OPENSSH PRIVATE KEY-----")
hub = parts("gh", "p_", "ThisIsASecretToken99")
pw = parts("pass", "word=", "abcdefghijklmnopqrstuvwxyz")
model = parts("s", "k-", "abcdefghijklmnopqrst")
fine = parts("github_", "pat_", "abcdefghijklmnop")
vendor = parts("xa", "i-", "abcdefghijklmnopqrst")
kv = parts("to", "ken=", "0123456789abcdef")
details = "\n".join([
    bearer,
    akia,
    pem_begin,
    "AAAA",
    pem_end,
])
pr_field = parts("gh", "p_", "PrFieldSecretToken99")
cost_field = parts("s", "k-", "CostFieldSecretToken")
artifact_field = parts("xa", "i-", "ArtifactSecretToken")
payload = {
    "status": "succeeded",
    "summary": "saw %s and %s" % (hub, pw),
    "details": details,
    "pr": pr_field,
    "cost": {"note": cost_field, "usd": 1, "tags": [cost_field]},
    "artifacts": [
        model,
        fine,
        vendor,
        kv,
        {"token": artifact_field, "nested": [artifact_field]},
    ],
}
Path(result_path).write_text(json.dumps(payload), encoding="utf-8")
record = {
    "phase": "running",
    "job_id": "rel-secret-01",
    "pid": 99999999,
    "pgid": 99999999,
    "repo": "adibirzu/firstmate",
    "issue": 79,
    "agent": "release-watch",
    "host": "mini",
    "had_running": True,
    "had_queued": True,
    "stage": str(Path(result_path).parent),
    "job": {
        "id": "rel-secret-01",
        "agent": "release-watch",
        "task": "poll",
        "job": "release-watch/v1",
    },
}
Path(record_path).write_text(json.dumps(record), encoding="utf-8")
PY
  : >"$log"
  : >"$comment_log"
  printf '%s\n' "1" >"$comment_fails"
  printf '%s\n' "0" >"$edit_fails"
  printf '%s\n' '{"comments":[]}' >"$comments"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    GH_COMMENTS_FILE="$comments" \
    GH_COMMENT_LOG="$comment_log" \
    GH_COMMENT_FAILS_FILE="$comment_fails" \
    GH_EDIT_FAILS_FILE="$edit_fails" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  [ "$(record_phase "$record")" = "result_posting" ] || fail "failed result comment did not stay in result_posting"
  [ ! -s "$comment_log" ] || fail "failed result comment was recorded as posted"
  python3 - "$state/outbox/rel-secret-01.json" "$stage/comment.md" "$state/dispatch.log" <<'PY'
import json
import sys
from pathlib import Path

paths = [Path(item) for item in sys.argv[1:4]]
blobs = [path.read_text(encoding="utf-8") for path in paths]
def parts(*chunks):
    return "".join(chunks)

forbidden = [
    parts("gh", "p_", "ThisIsASecretToken99"),
    parts("github_", "pat_", "abcdefghijklmnop"),
    parts("s", "k-", "abcdefghijklmnopqrst"),
    parts("xa", "i-", "abcdefghijklmnopqrst"),
    parts("AK", "IA", "IOSFODNN7EXAMPLE"),
    parts("Bea", "rer ", "abcdefghijklmnop"),
    parts("-----BEGIN ", "OPENSSH PRIVATE KEY-----"),
    parts("pass", "word=", "abcdefghijklmnopqrstuvwxyz"),
    parts("to", "ken=", "0123456789abcdef"),
    parts("gh", "p_", "PrFieldSecretToken99"),
    parts("s", "k-", "CostFieldSecretToken"),
    parts("xa", "i-", "ArtifactSecretToken"),
]
for blob, path in zip(blobs, paths):
    for secret in forbidden:
        if secret in blob:
            raise SystemExit("secret leaked in %s" % path.name)
if "[REDACTED]" not in blobs[0] or "[REDACTED]" not in blobs[1]:
    raise SystemExit("redaction marker missing from the posted result")
data = json.loads(blobs[0])
if not isinstance(data.get("redactions"), int) or data["redactions"] < 1:
    raise SystemExit("redaction count missing: %s" % data.get("redactions"))
PY

  python3 - "$comments" <<'PY'
import json
import sys
from pathlib import Path

payload = {"comments": [
    {"body": "dispatcher: claimed rel-secret-01 -> release-watch@mini"},
    {"body": "Local agent result for an older note"},
]}
Path(sys.argv[1]).write_text(json.dumps(payload), encoding="utf-8")
PY
  printf '%s\n' "0" >"$comment_fails"
  printf '%s\n' "1" >"$edit_fails"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    GH_COMMENTS_FILE="$comments" \
    GH_COMMENT_LOG="$comment_log" \
    GH_COMMENT_FAILS_FILE="$comment_fails" \
    GH_EDIT_FAILS_FILE="$edit_fails" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  [ "$(record_phase "$record")" = "result_posted" ] || fail "split comments skipped the result post"
  before=$(grep -c "issue comment" "$comment_log" || true)
  [ "$before" -eq 1 ] || fail "split comments did not post the result once"

  python3 - "$record" "$comments" <<'PY'
import json
import sys
from pathlib import Path

record_path, comments_path = sys.argv[1:3]
record = json.loads(Path(record_path).read_text(encoding="utf-8"))
record["phase"] = "result_posting"
Path(record_path).write_text(json.dumps(record), encoding="utf-8")
payload = {"comments": [{
    "body": "**Local agent result** job rel-secret-01",
}]}
Path(comments_path).write_text(json.dumps(payload), encoding="utf-8")
PY
  printf '%s\n' "0" >"$edit_fails"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    GH_COMMENTS_FILE="$comments" \
    GH_COMMENT_LOG="$comment_log" \
    GH_COMMENT_FAILS_FILE="$comment_fails" \
    GH_EDIT_FAILS_FILE="$edit_fails" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  after=$(grep -c "issue comment" "$comment_log" || true)
  [ "$after" -eq "$before" ] || fail "existing result comment was posted again"
  [ ! -e "$record" ] || fail "labelled result record was kept"
  pass "result transaction redacts, resumes, and does not double-post"
}

test_lock_protocol() {
  local state bin saved err rc pid_text
  local log=$TMP_ROOT/lock-stale-gh.log
  saved=$PATH
  bin=$TMP_ROOT/lock-bin
  install_issue_gh "$bin"

  state=$TMP_ROOT/lock-fresh
  mkdir -p "$state/lock"
  printf '%s\n' "not-a-pid" >"$state/lock/pid"
  set +e
  err=$(PATH="$bin:$saved" FM_AGENT_STATE="$state" python3 "$DISPATCH" loop --once --config "$CFG" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fresh unreadable lock was acquired"
  assert_contains "$err" "could not acquire dispatcher lock" "fresh lock message"
  pid_text=$(tr -d '[:space:]' <"$state/lock/pid")
  assert_equals "not-a-pid" "$pid_text" "fresh lock pid was replaced"

  state=$TMP_ROOT/lock-fresh-empty
  mkdir -p "$state/lock"
  set +e
  err=$(PATH="$bin:$saved" FM_AGENT_STATE="$state" python3 "$DISPATCH" loop --once --config "$CFG" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fresh empty lock was acquired"
  assert_contains "$err" "could not acquire dispatcher lock" "empty fresh lock message"
  [ -d "$state/lock" ] || fail "empty fresh lock was removed"
  [ ! -e "$state/lock/pid" ] || fail "empty fresh lock gained a pid"

  state=$TMP_ROOT/lock-stale
  mkdir -p "$state/lock"
  printf '%s\n' "not-a-pid" >"$state/lock/pid"
  python3 - "$state/lock" "$state/lock/pid" <<'PY'
import os
import sys
import time

old = time.time() - 120
os.utime(sys.argv[1], (old, old))
os.utime(sys.argv[2], (old, old))
PY
  : >"$log"
  set +e
  err=$(PATH="$bin:$saved" GH_LOG="$log" FM_AGENT_STATE="$state" python3 "$DISPATCH" loop --once --config "$CFG" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "stale lock was not acquired: $err"
  [ ! -d "$state/lock" ] || fail "stale lock was not released"

  state=$TMP_ROOT/lock-live
  mkdir -p "$state/lock"
  printf '%s\n' "$$" >"$state/lock/pid"
  set +e
  err=$(PATH="$bin:$saved" FM_AGENT_STATE="$state" python3 "$DISPATCH" loop --once --config "$CFG" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "live lock was acquired"
  assert_contains "$err" "dispatcher already running (pid $$)" "live lock message"
  pid_text=$(tr -d '[:space:]' <"$state/lock/pid")
  assert_equals "$$" "$pid_text" "live lock pid changed"
  pass "lock ownership follows the pid and its age"
}

test_lock_race() {
  local state=$TMP_ROOT/lock-race-state
  local bin=$TMP_ROOT/lock-race-bin
  local log=$TMP_ROOT/lock-race-gh.log
  local crit=$TMP_ROOT/lock-race-crit
  local overlap=$TMP_ROOT/lock-race-overlap
  local a_err=$TMP_ROOT/lock-race-a.err
  local b_err=$TMP_ROOT/lock-race-b.err
  local saved=$PATH
  local a_pid b_rc a_rc count waited
  mkdir -p "$state"
  install_stateful_gh "$bin"
  : >"$log"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_CRIT="$crit" \
    GH_OVERLAP="$overlap" \
    FM_AGENT_LOCK_PAUSE=2 \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG" >"$TMP_ROOT/lock-race-a.out" 2>"$a_err" &
  a_pid=$!
  track_pid "$a_pid"
  waited=0
  while [ "$waited" -lt 20 ]; do
    if [ -d "$state/lock" ] && [ ! -f "$state/lock/pid" ]; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -d "$state/lock" ] || fail "holder did not create the lock"
  [ ! -f "$state/lock/pid" ] || fail "holder published a pid before the race"
  set +e
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_CRIT="$crit" \
    GH_OVERLAP="$overlap" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG" >"$TMP_ROOT/lock-race-b.out" 2>"$b_err"
  b_rc=$?
  set -e
  [ "$b_rc" -ne 0 ] || fail "second dispatcher acquired the fresh lock"
  if ! grep -F -e "could not acquire dispatcher lock" -e "dispatcher already running" "$b_err" >/dev/null; then
    fail "second dispatcher did not report the lock"
  fi
  [ -d "$state/lock" ] || fail "second dispatcher removed the fresh lock"
  set +e
  wait "$a_pid"
  a_rc=$?
  set -e
  [ "$a_rc" -eq 0 ] || fail "lock holder failed"
  count=$(grep -c "issue list" "$log" || true)
  [ "$count" -eq 5 ] || fail "expected one poll pass, saw $count issue lists"
  [ ! -e "$overlap" ] || fail "two dispatchers polled at once"
  pass "a fresh lock is not stolen by a second dispatcher"
}

test_max_jobs_blocks_launch() {
  local state=$TMP_ROOT/max-loop-state
  local bin=$TMP_ROOT/max-loop-bin
  local issues=$TMP_ROOT/max-loop-issues.json
  local log=$TMP_ROOT/max-loop-gh.log
  local saved=$PATH
  mkdir -p "$state/running"
  install_issue_gh "$bin"
  write_issue "$issues" "adibirzu" 46 "rel-full-01"
  python3 - "$state/running" "$$" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
pid = int(sys.argv[2])
for name in ("slot-one.json", "slot-two.json"):
    (root / name).write_text(json.dumps({
        "job_id": name,
        "host": "mini",
        "pid": pid,
    }), encoding="utf-8")
PY
  : >"$log"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_ISSUE_FILE="$issues" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  assert_no_grep "issue edit" "$log" "full host edited an issue"
  assert_no_grep "issue comment" "$log" "full host commented"
  assert_grep "retry adibirzu/firstmate#46 rel-full-01" "$state/dispatch.log" "full host did not retry"
  pass "max_jobs blocks another launch"
}

start_recorded_sleep() {
  python3 - <<'PY'
import os
import subprocess

proc = subprocess.Popen(
    ["sleep", "60"],
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
print("%s %s" % (proc.pid, os.getpgid(proc.pid)))
PY
}

test_restart_enforces_deadline() {
  local state=$TMP_ROOT/deadline-state
  local bin=$TMP_ROOT/deadline-bin
  local log=$TMP_ROOT/deadline-gh.log
  local saved=$PATH
  local info pid pgid
  mkdir -p "$state/running" "$state/artifacts/deadline-01"
  install_stateful_gh "$bin"
  info=$(start_recorded_sleep)
  pid=${info%% *}
  pgid=${info##* }
  track_pid "$pid"
  python3 - "$state/running/adibirzu-firstmate#77.json" "$pid" "$pgid" "$state/artifacts/deadline-01" <<'PY'
import json
import sys
from pathlib import Path

path, pid, pgid, stage = sys.argv[1:5]
record = {
    "phase": "running",
    "job_id": "deadline-01",
    "pid": int(pid),
    "pgid": int(pgid),
    "deadline": "2020-01-01T00:00:00+00:00",
    "repo": "adibirzu/firstmate",
    "issue": 77,
    "agent": "release-watch",
    "host": "mini",
    "had_running": True,
    "had_queued": True,
    "stage": stage,
    "job": {
        "id": "deadline-01",
        "agent": "release-watch",
        "task": "poll",
        "job": "release-watch/v1",
    },
}
Path(path).write_text(json.dumps(record), encoding="utf-8")
PY
  : >"$log"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  if kill -0 "$pid" 2>/dev/null; then
    fail "expired job was still running"
  fi
  python3 - "$state/outbox/deadline-01.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
if data.get("summary") != "timeout":
    raise SystemExit(data.get("summary"))
PY
  assert_grep "timeout" "$state/artifacts/deadline-01/comment.md" "timeout comment missing"
  pass "restart kills a live job at its saved deadline"
}

test_slow_poll_respects_deadline() {
  local state=$TMP_ROOT/slow-state
  local bin=$TMP_ROOT/slow-bin
  local log=$TMP_ROOT/slow-gh.log
  local flag=$TMP_ROOT/slow-flag
  local end=$TMP_ROOT/slow-end
  local saved=$PATH
  local info pid pgid start now elapsed
  mkdir -p "$state/running"
  install_stateful_gh "$bin"
  info=$(start_recorded_sleep)
  pid=${info%% *}
  pgid=${info##* }
  track_pid "$pid"
  python3 - "$state/running/adibirzu-firstmate#78.json" "$pid" "$pgid" <<'PY'
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

pid = int(sys.argv[2])
pgid = int(sys.argv[3])
deadline = (datetime.now().astimezone() + timedelta(seconds=3)).isoformat(timespec="seconds")
record = {
    "phase": "running",
    "job_id": "slow-poll-01",
    "pid": pid,
    "pgid": pgid,
    "deadline": deadline,
    "repo": "adibirzu/firstmate",
    "issue": 78,
    "agent": "release-watch",
    "host": "mini",
    "had_running": True,
    "had_queued": False,
    "stage": "",
    "job": {
        "id": "slow-poll-01",
        "agent": "release-watch",
        "task": "poll",
        "job": "release-watch/v1",
    },
}
Path(sys.argv[1]).write_text(json.dumps(record), encoding="utf-8")
PY
  : >"$log"
  start=$(date +%s)
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    GH_SLOW_ONCE=1 \
    GH_SLOW_FLAG="$flag" \
    GH_END="$end" \
    FM_AGENT_GH_TIMEOUT=120 \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  now=$(date +%s)
  elapsed=$((now - start))
  [ "$elapsed" -lt 8 ] || fail "slow poll ran for ${elapsed}s"
  [ ! -e "$end" ] || fail "slow poll finished the long gh call"
  assert_grep "gh timed out" "$state/dispatch.log" "slow poll was not timed out"
  if kill -0 "$pid" 2>/dev/null; then
    fail "slow poll left the expired job running"
  fi
  pass "polls are bounded by the nearest deadline"
}

test_reviewer_allow_list() {
  local saved=$PATH
  local home=$TMP_ROOT/reviewer-home
  local bin=$TMP_ROOT/reviewer-bin
  local log=$TMP_ROOT/reviewer-llm.log
  local touch=$TMP_ROOT/reviewer-llm-touch
  local job
  mkdir -p "$home" "$bin"
  cat >"$bin/llm-run" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${LLM_LOG:?}"
printf '%s\n' "called" > "${LLM_TOUCH:?}"
exit 1
SH
  chmod +x "$bin/llm-run"
  : >"$log"
  rm -f "$touch"

  job=$TMP_ROOT/reviewer-evil
  prepare_job "$job" '{"id":"rev-evil-01","task":"review","job":"review-first-pass/v1","author_family":"gemini","reviewer":"openai:gpt-4"}'
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" LLM_LOG="$log" LLM_TOUCH="$touch" \
    bash "$ROOT/local-agents/runners/review-first-pass.sh"
  python3 - "$job/result.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["status"] != "failed" or data["summary"] != "reviewer is not allowed":
    raise SystemExit(data)
PY

  job=$TMP_ROOT/reviewer-slash
  prepare_job "$job" '{"id":"rev-slash-01","task":"review","job":"review-first-pass/v1","author_family":"gemini","reviewer":"agy/gemini-3.8-flash-high"}'
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" LLM_LOG="$log" LLM_TOUCH="$touch" \
    bash "$ROOT/local-agents/runners/review-first-pass.sh"
  python3 - "$job/result.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["status"] != "failed" or "reviewer family" not in data["summary"]:
    raise SystemExit(data)
if "reviewer is not allowed" in data["summary"]:
    raise SystemExit(data)
PY

  job=$TMP_ROOT/reviewer-claude
  prepare_job "$job" '{"id":"rev-claude-01","task":"review","job":"review-first-pass/v1","author_family":"gemini","reviewer":"claude:sonnet"}'
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" LLM_LOG="$log" LLM_TOUCH="$touch" \
    bash "$ROOT/local-agents/runners/review-first-pass.sh"
  python3 - "$job/result.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data["status"] != "failed" or "missing pr:owner/repo#N" not in data["summary"]:
    raise SystemExit(data)
if "reviewer is not allowed" in data["summary"]:
    raise SystemExit(data)
PY
  [ ! -e "$touch" ] || fail "reviewer selection called a model"
  [ ! -s "$log" ] || fail "reviewer selection invoked llm-run"
  pass "reviewer selection stays on the allow-list"
}

test_ledger_home() {
  local lib=$ROOT/local-agents/runners/lib.sh
  local home=$TMP_ROOT/ledger-home
  local empty=$TMP_ROOT/ledger-empty
  local bin=$TMP_ROOT/ledger-bin
  local got home_line ledger_line
  mkdir -p "$home/dev/llm-ledger/bin" "$empty" "$bin"
  printf '%s\n' "#!/bin/bash" >"$home/dev/llm-ledger/bin/fm-fleet-ledger.sh"
  # shellcheck disable=SC2016 # The child bash, not this test shell, expands HOME and LLM_RUN_FM_HOME.
  got=$(env -u LLM_RUN_FM_HOME HOME="$home" bash -c 'source "$1"; printf "%s" "${LLM_RUN_FM_HOME-}"' _ "$lib")
  assert_equals "$home/dev/llm-ledger" "$got" "ledger home was not exported"
  # shellcheck disable=SC2016 # The child bash, not this test shell, expands HOME and LLM_RUN_FM_HOME.
  got=$(env LLM_RUN_FM_HOME=/keep HOME="$home" bash -c 'source "$1"; printf "%s" "$LLM_RUN_FM_HOME"' _ "$lib")
  assert_equals "/keep" "$got" "preset ledger home was replaced"
  # shellcheck disable=SC2016 # The child bash, not this test shell, expands HOME and LLM_RUN_FM_HOME.
  got=$(env -u LLM_RUN_FM_HOME HOME="$empty" bash -c 'source "$1"; if [ -n "${LLM_RUN_FM_HOME:-}" ]; then printf "%s" "$LLM_RUN_FM_HOME"; else printf "%s" "unset"; fi' _ "$lib")
  assert_equals "unset" "$got" "missing ledger writer still set a home"
  cat >"$bin/getent" <<SH
#!/usr/bin/env bash
printf '%s\n' "user:x:$(id -u):$(id -g)::${home}:/bin/sh"
SH
  chmod +x "$bin/getent"
  # shellcheck disable=SC2016 # The child bash, not this test shell, expands HOME and LLM_RUN_FM_HOME.
  got=$(env -u HOME -u LLM_RUN_FM_HOME PATH="$bin:$PATH" bash -c 'source "$1"; printf "%s\n%s" "$HOME" "${LLM_RUN_FM_HOME-}"' _ "$lib")
  home_line=${got%%$'\n'*}
  ledger_line=${got#*$'\n'}
  assert_equals "$home" "$home_line" "getent did not supply HOME"
  assert_equals "$home/dev/llm-ledger" "$ledger_line" "getent home did not select the ledger"
  # shellcheck disable=SC2016 # The child bash, not this test shell, expands HOME and LLM_RUN_FM_HOME.
  got=$(env -u HOME -u LLM_RUN_FM_HOME PATH="/usr/bin:/bin" bash -c 'source "$1"; printf "%s" "$HOME"' _ "$lib")
  [ -n "$got" ] || fail "HOME stayed empty"
  [ -d "$got" ] || fail "HOME is not a directory"
  pass "runner home reaches the local ledger"
}

seed_claim_record() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys
from pathlib import Path

path, job_id, number = sys.argv[1:4]
record = {
    "phase": "claiming",
    "job_id": job_id,
    "job": {
        "id": job_id,
        "job": "release-watch/v1",
        "task": "poll",
        "agent": "release-watch",
    },
    "host": "mini",
    "pid": None,
    "pgid": None,
    "started_at": None,
    "deadline": None,
    "repo": "adibirzu/firstmate",
    "issue": int(number),
    "agent": "release-watch",
    "title": "Watch",
    "body": "",
    "url": "",
    "had_queued": True,
    "had_running": False,
    "wall_seconds": 600,
}
dest = Path(path)
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(json.dumps(record), encoding="utf-8")
PY
}

stop_job_pid() {
  local record=$1
  local pid
  [ -f "$record" ] || return 0
  pid=$(python3 -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")).get("pid"); print("" if value is None else value)' "$record")
  if [ -n "$pid" ]; then
    track_pid "$pid"
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

test_lock_steal_preserves_new_lock() {
  local state=$TMP_ROOT/lock-steal-state
  local bin=$TMP_ROOT/lock-steal-bin
  local log=$TMP_ROOT/lock-steal-gh.log
  local crit=$TMP_ROOT/lock-steal-crit
  local overlap=$TMP_ROOT/lock-steal-overlap
  local hold=$TMP_ROOT/lock-steal-hold
  local a_err=$TMP_ROOT/lock-steal-a.err
  local b_err=$TMP_ROOT/lock-steal-b.err
  local saved=$PATH
  local a_pid b_pid a_rc b_rc waited count
  mkdir -p "$state/lock"
  install_stateful_gh "$bin"
  printf '%s\n' "not-a-pid" >"$state/lock/pid"
  python3 - "$state/lock" "$state/lock/pid" <<'PY'
import os
import sys
import time

old = time.time() - 120
os.utime(sys.argv[1], (old, old))
os.utime(sys.argv[2], (old, old))
PY
  : >"$log"
  rm -f "$hold"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_CRIT="$crit" \
    GH_OVERLAP="$overlap" \
    FM_AGENT_LOCK_STEAL_HOLD="$hold" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG" >"$TMP_ROOT/lock-steal-a.out" 2>"$a_err" &
  a_pid=$!
  track_pid "$a_pid"
  waited=0
  while [ "$waited" -lt 50 ]; do
    if [ -f "$hold" ] && [ ! -d "$state/lock" ]; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$hold" ] || fail "stale lock was not held aside"
  [ ! -d "$state/lock" ] || fail "stale lock stayed in place during the hold"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_CRIT="$crit" \
    GH_OVERLAP="$overlap" \
    FM_AGENT_LOCK_PAUSE=5 \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG" >"$TMP_ROOT/lock-steal-b.out" 2>"$b_err" &
  b_pid=$!
  track_pid "$b_pid"
  waited=0
  while [ "$waited" -lt 30 ]; do
    if [ -d "$state/lock" ]; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -d "$state/lock" ] || fail "second dispatcher did not create a lock"
  rm -f "$hold"
  set +e
  wait "$a_pid"
  a_rc=$?
  set -e
  [ "$a_rc" -ne 0 ] || fail "stealer acquired the replacement lock"
  assert_contains "$(cat "$a_err")" "could not acquire dispatcher lock" "stealer did not back off"
  [ -d "$state/lock" ] || fail "stealer removed the replacement lock"
  [ ! -e "$state/lock/pid" ] || fail "stealer replaced the new lock before its pid was published"
  set +e
  wait "$b_pid"
  b_rc=$?
  set -e
  [ "$b_rc" -eq 0 ] || fail "replacement lock holder failed"
  count=$(grep -c "issue list" "$log" || true)
  [ "$count" -eq 5 ] || fail "expected one poll pass, saw $count issue lists"
  [ ! -e "$overlap" ] || fail "two dispatchers polled at once"
  pass "a stolen stale lock cannot delete the next dispatcher lock"
}

test_claim_compare_and_set() {
  local saved=$PATH
  local state bin log comments record

  state=$TMP_ROOT/cas-lose-state
  bin=$TMP_ROOT/cas-lose-bin
  log=$TMP_ROOT/cas-lose-gh.log
  comments=$TMP_ROOT/cas-lose-comments.json
  record=$state/running/adibirzu-firstmate#82.json
  mkdir -p "$state/running"
  install_stateful_gh "$bin"
  seed_claim_record "$record" "cas-lose-01" 82
  python3 - "$comments" <<'PY'
import json
import sys
from pathlib import Path

payload = {"comments": [{
    "body": "dispatcher: claimed cas-lose-01 token:earlier-owner",
}]}
Path(sys.argv[1]).write_text(json.dumps(payload), encoding="utf-8")
PY
  : >"$log"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    GH_COMMENTS_FILE="$comments" \
    GH_COMMENT_MIRROR=1 \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  [ "$(record_phase "$record")" = "claiming" ] || fail "lost claim advanced the phase"
  python3 - "$record" "$comments" "$state/artifacts/cas-lose-01/runner.stdout" <<'PY'
import json
import sys
from pathlib import Path

record = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
comments = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))["comments"]
stdout = Path(sys.argv[3])
if record.get("pid") is not None:
    raise SystemExit("lost claim stored a pid")
if stdout.exists():
    raise SystemExit("lost claim started a runner")
if len(comments) < 2:
    raise SystemExit("lost claim did not post its own comment")
if "token:earlier-owner" not in comments[0]["body"]:
    raise SystemExit("earliest claim was replaced")
if "token:earlier-owner" in comments[1]["body"]:
    raise SystemExit("second comment reused the earlier token")
PY
  assert_grep "not starting" "$state/dispatch.log" "lost claim still started"

  state=$TMP_ROOT/cas-win-state
  bin=$TMP_ROOT/cas-win-bin
  log=$TMP_ROOT/cas-win-gh.log
  comments=$TMP_ROOT/cas-win-comments.json
  record=$state/running/adibirzu-firstmate#83.json
  mkdir -p "$state/running"
  install_stateful_gh "$bin"
  seed_claim_record "$record" "cas-win-01" 83
  printf '%s\n' '{"comments":[]}' >"$comments"
  : >"$log"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    GH_COMMENTS_FILE="$comments" \
    GH_COMMENT_MIRROR=1 \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  stop_job_pid "$record"
  [ -f "$state/artifacts/cas-win-01/runner.stdout" ] || fail "winning claim did not start"
  assert_no_grep "not starting" "$state/dispatch.log" "winning claim refused to start"
  pass "the earliest claim token owns the job"
}

test_dry_run_skips_deadline_reap() {
  local state=$TMP_ROOT/dry-reap-state
  local bin=$TMP_ROOT/dry-reap-bin
  local log=$TMP_ROOT/dry-reap-gh.log
  local saved=$PATH
  local info pid pgid
  local record=$state/running/adibirzu-firstmate#85.json
  mkdir -p "$state/running" "$state/artifacts/dry-reap-01"
  install_stateful_gh "$bin"
  info=$(start_recorded_sleep)
  pid=${info%% *}
  pgid=${info##* }
  track_pid "$pid"
  python3 - "$record" "$pid" "$pgid" "$state/artifacts/dry-reap-01" <<'PY'
import json
import sys
from pathlib import Path

path, pid, pgid, stage = sys.argv[1:5]
record = {
    "phase": "running",
    "job_id": "dry-reap-01",
    "pid": int(pid),
    "pgid": int(pgid),
    "deadline": "2020-01-01T00:00:00+00:00",
    "repo": "adibirzu/firstmate",
    "issue": 85,
    "agent": "release-watch",
    "host": "mini",
    "had_running": True,
    "had_queued": True,
    "stage": stage,
    "job": {
        "id": "dry-reap-01",
        "agent": "release-watch",
        "task": "poll",
        "job": "release-watch/v1",
    },
}
Path(path).write_text(json.dumps(record), encoding="utf-8")
PY
  : >"$log"
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --dry-run --config "$CFG"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "dry-run killed the expired job"
  fi
  [ ! -e "$state/outbox/dry-reap-01.json" ] || fail "dry-run wrote a result"
  [ ! -e "$state/artifacts/dry-reap-01/comment.md" ] || fail "dry-run wrote a result comment"
  assert_no_grep "issue edit" "$log" "dry-run edited a label"
  assert_no_grep "issue comment" "$log" "dry-run posted a result"
  assert_grep "dry-run: would reap dry-reap-01 at deadline" "$state/dispatch.log" "dry-run did not report the reap"
  [ "$(record_phase "$record")" = "running" ] || fail "dry-run changed the running job"
  pass "dry-run reports a deadline reap without killing or posting"
}

test_poll_wakes_for_deadline() {
  local state=$TMP_ROOT/sleep-bound-state
  local bin=$TMP_ROOT/sleep-bound-bin
  local log=$TMP_ROOT/sleep-bound-gh.log
  local saved=$PATH
  local info pid pgid d_pid start now elapsed waited
  local record=$state/running/adibirzu-firstmate#86.json
  mkdir -p "$state/running" "$state/artifacts/sleep-bound-01"
  install_stateful_gh "$bin"
  info=$(start_recorded_sleep)
  pid=${info%% *}
  pgid=${info##* }
  track_pid "$pid"
  python3 - "$record" "$pid" "$pgid" "$state/artifacts/sleep-bound-01" <<'PY'
import json
import sys
from pathlib import Path

path, pid, pgid, stage = sys.argv[1:5]
record = {
    "phase": "running",
    "job_id": "sleep-bound-01",
    "pid": int(pid),
    "pgid": int(pgid),
    "deadline": "2026-01-01T00:00:04+00:00",
    "repo": "adibirzu/firstmate",
    "issue": 86,
    "agent": "release-watch",
    "host": "mini",
    "had_running": True,
    "had_queued": False,
    "stage": stage,
    "job": {
        "id": "sleep-bound-01",
        "agent": "release-watch",
        "task": "poll",
        "job": "release-watch/v1",
    },
}
Path(path).write_text(json.dumps(record), encoding="utf-8")
PY
  : >"$log"
  start=$(date +%s)
  PATH="$bin:$saved" \
    GH_LOG="$log" \
    GH_LIST_EMPTY=1 \
    FM_AGENT_NOW="2026-01-01T00:00:00+00:00" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --config "$CFG" >"$TMP_ROOT/sleep-bound.out" 2>"$TMP_ROOT/sleep-bound.err" &
  d_pid=$!
  track_pid "$d_pid"
  waited=0
  while [ "$waited" -lt 40 ]; do
    if [ -f "$state/outbox/sleep-bound-01.json" ]; then
      break
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  now=$(date +%s)
  elapsed=$((now - start))
  kill -TERM "$d_pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "$d_pid" 2>/dev/null || true
  set +e
  wait "$d_pid"
  set -e
  [ -f "$state/outbox/sleep-bound-01.json" ] || fail "deadline did not reap during the short sleep"
  [ "$elapsed" -lt 8 ] || fail "deadline sleep took ${elapsed}s"
  python3 - "$state/dispatch.log" "$state/outbox/sleep-bound-01.json" <<'PY'
import json
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
found = re.findall(r"poll sleep ([0-9]+(?:\.[0-9]+)?)", text)
if not found:
    raise SystemExit("no poll sleep")
first = float(found[0])
if not 0 < first < 10:
    raise SystemExit("first poll sleep was %s" % first)
data = json.load(open(sys.argv[2], encoding="utf-8"))
if data.get("summary") != "timeout":
    raise SystemExit(data.get("summary"))
PY
  if kill -0 "$pid" 2>/dev/null; then
    fail "bounded sleep left the expired job running"
  fi
  pass "the poll loop wakes for the nearest deadline"
}

test_review_pr_repo_and_remote_registry() {
  local saved=$PATH
  local home=$TMP_ROOT/review-remote-home
  local stage=$TMP_ROOT/review-stage
  local bin=$TMP_ROOT/review-remote-bin
  local job
  mkdir -p "$home" "$stage" "$bin"
  cp "$ROOT/local-agents/runners/review-first-pass.sh" "$stage/review-first-pass.sh"
  cp "$ROOT/local-agents/runners/lib.sh" "$stage/lib.sh"
  cat >"$bin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat >"$bin/llm-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LLM_LOG:?}"
exit 1
SH
  chmod +x "$bin/gh" "$bin/llm-run"
  : >"$TMP_ROOT/review-remote-llm.log"

  job=$TMP_ROOT/review-unlisted
  prepare_job "$job" '{"id":"rev-stage-01","task":"review","job":"review-first-pass/v1","author_family":"gemini","reviewer":"claude:sonnet","inputs":["pr:adibirzu/firstmate#12"]}'
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" LLM_LOG="$TMP_ROOT/review-remote-llm.log" \
    bash "$stage/review-first-pass.sh"
  python3 - "$job/result.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if data.get("summary") != "reviewer is not allowed":
    raise SystemExit(data.get("summary"))
PY

  cp "$CFG" "$stage/agents.json"
  job=$TMP_ROOT/review-foreign-pr
  prepare_job "$job" '{"id":"rev-stage-02","task":"review","job":"review-first-pass/v1","author_family":"gemini","reviewer":"claude:sonnet","inputs":["pr:evil/foreign#4"]}'
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" LLM_LOG="$TMP_ROOT/review-remote-llm.log" \
    bash "$stage/review-first-pass.sh"
  python3 - "$job/result.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
summary = data.get("summary") or ""
if summary != "pr repo is not allowed: evil/foreign":
    raise SystemExit(summary)
if "reviewer is not allowed" in summary:
    raise SystemExit(summary)
PY

  job=$TMP_ROOT/review-allowed-pr
  prepare_job "$job" '{"id":"rev-stage-03","task":"review","job":"review-first-pass/v1","author_family":"gemini","reviewer":"claude:sonnet","inputs":["pr:adibirzu/firstmate#12"]}'
  PATH="$bin:$saved" HOME="$home" FM_AGENT_JOB_DIR="$job" LLM_LOG="$TMP_ROOT/review-remote-llm.log" \
    bash "$stage/review-first-pass.sh"
  python3 - "$job/result.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
summary = data.get("summary") or ""
if "gh pr diff or view failed" not in summary:
    raise SystemExit(summary)
if "reviewer is not allowed" in summary or "pr repo is not allowed" in summary:
    raise SystemExit(summary)
PY
  [ ! -s "$TMP_ROOT/review-remote-llm.log" ] || fail "registry checks called a model"

  local state=$TMP_ROOT/review-dispatch-state
  local disp=$TMP_ROOT/review-dispatch-bin
  local issues=$TMP_ROOT/review-dispatch-issues.json
  local comments=$TMP_ROOT/review-dispatch-comments.json
  local gh_log=$TMP_ROOT/review-dispatch-gh.log
  local ssh_log=$TMP_ROOT/review-dispatch-ssh.log
  local scp_log=$TMP_ROOT/review-dispatch-scp.log
  local ssh_mark=$TMP_ROOT/review-dispatch-ssh.mark
  local record=$state/running/adibirzu-firstmate#84.json
  mkdir -p "$state" "$disp"
  install_stateful_gh "$disp"
  cat >"$disp/ssh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${SSH_LOG:?}"
printf '%s\n' "fake-ssh" >> "${SSH_MARK:?}"
exit 0
SH
  cat >"$disp/scp" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${SCP_LOG:?}"
exit 0
SH
  chmod +x "$disp/ssh" "$disp/scp"
  python3 - "$issues" <<'PY'
import json
import sys
from pathlib import Path

body = "\n".join([
    "```yaml",
    "job: review-first-pass/v1",
    "id: rev-remote-01",
    "task: review",
    "reviewer: claude:sonnet",
    "author_family: gemini",
    "inputs:",
    "  - pr:adibirzu/firstmate#12",
    "```",
    "",
])
issue = [{
    "number": 84,
    "title": "Review",
    "body": body,
    "labels": [{"name": "agent:review-first-pass"}, {"name": "state:queued"}],
    "author": {"login": "adibirzu"},
    "url": "https://github.com/adibirzu/firstmate/issues/84",
}]
Path(sys.argv[1]).write_text(json.dumps(issue), encoding="utf-8")
PY
  printf '%s\n' '{"comments":[]}' >"$comments"
  : >"$gh_log"
  : >"$ssh_log"
  : >"$scp_log"
  : >"$ssh_mark"
  PATH="$disp:$saved" \
    GH_LOG="$gh_log" \
    GH_ISSUE_FILE="$issues" \
    GH_COMMENTS_FILE="$comments" \
    GH_COMMENT_MIRROR=1 \
    SSH_LOG="$ssh_log" \
    SSH_MARK="$ssh_mark" \
    SCP_LOG="$scp_log" \
    FM_AGENT_STATE="$state" \
    python3 "$DISPATCH" loop --once --config "$CFG"
  local waited=0
  while [ "$waited" -lt 40 ]; do
    if grep -F "agents.json" "$scp_log" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
    waited=$((waited + 1))
  done
  stop_job_pid "$record"
  assert_grep "agents.json" "$scp_log" "remote review did not stage the reviewer registry"
  assert_grep "fake-ssh" "$ssh_mark" "remote review invoked ssh outside the test double"
  assert_grep "BatchMode" "$ssh_log" "remote review did not call ssh"
  pass "review repos stay on the registry and remote runs stage it"
}

test_parse_job_without_pyyaml
test_parse_job_with_pyyaml_loader
test_validation_failures
test_window_and_capacity
test_open_file_path_rejected
test_render_result_neutralises
test_unknown_author_is_ignored
test_dry_run_claims_without_runner
test_dry_run_recovery
test_dry_run_open_claim
test_claim_transaction
test_claim_compare_and_set
test_result_transaction_and_redaction
test_job_schema
test_lock_protocol
test_lock_race
test_lock_steal_preserves_new_lock
test_max_jobs_blocks_launch
test_restart_enforces_deadline
test_slow_poll_respects_deadline
test_poll_wakes_for_deadline
test_dry_run_skips_deadline_reap
test_reviewer_allow_list
test_review_pr_repo_and_remote_registry
test_ledger_home
test_runner_smokes
test_shell_syntax
