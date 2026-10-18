#!/usr/bin/env bash
# Behavior tests for the local-agent dispatcher and its runners.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

set -euo pipefail

DISPATCH=$ROOT/bin/fm-agent-dispatch.py
CFG=$ROOT/local-agents/agents.json
TMP_ROOT=$(fm_test_tmproot fm-agent-dispatch)
unset FM_AGENT_NOW || true
export FM_AGENT_STATE=$TMP_ROOT/state
mkdir -p "$FM_AGENT_STATE"

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
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-18T23:59:59+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media --host-pref adi1)
  assert_py "adi1 closed" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "blocked", data
assert "textbook OCR" in data["reason"], data
' "$out"
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-18T23:59:59+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media)
  assert_py "adi2 while adi1 closed" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "run", data
assert data["host"] == "adi2", data
' "$out"
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T00:00:00+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media --host-pref adi1)
  assert_py "adi1 open at window" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "run", data
assert data["host"] == "adi1", data
' "$out"

  state=$TMP_ROOT/capacity-state
  mkdir -p "$state/running"
  python3 - "$state/running" "$$" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
pid = int(sys.argv[2])
for name, host in (("one.json", "adi2"), ("two.json", "adi2")):
    (root / name).write_text(json.dumps({"job_id": name, "host": host, "pid": pid}), encoding="utf-8")
PY
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T01:00:00+03:00 \
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
  out=$(FM_AGENT_STATE="$state" FM_AGENT_NOW=2026-10-19T01:00:00+03:00 \
    python3 "$DISPATCH" select-host --config "$CFG" --agent studio-media)
  assert_py "both hosts full retries" '
import json, sys
data = json.load(sys.stdin)
assert data["action"] == "retry", data
' "$out"
  pass "window and max_jobs"
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

test_parse_job_without_pyyaml
test_parse_job_with_pyyaml_loader
test_validation_failures
test_window_and_capacity
test_render_result_neutralises
test_unknown_author_is_ignored
test_dry_run_claims_without_runner
test_runner_smokes
test_shell_syntax
