#!/usr/bin/env bash
# studio-media.sh - licence gate, probe, subtitle lint, and a planned ledger.
# Generative tasks stop after the planned ledger line.
set -euo pipefail

# shellcheck disable=SC1091 source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

job_dir=${FM_AGENT_JOB_DIR:?FM_AGENT_JOB_DIR is required}
home_dir=${HOME:?HOME is required}
summary_file=$job_dir/summary.txt
details_file=$job_dir/details.txt
id=$(job_get id)
catalogue=$job_dir/candidates.yaml
if [ ! -f "$catalogue" ]; then
  runner_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
  catalogue=$runner_dir/../studio-media/candidates.yaml
fi

set +e
decision=$(python3 - "$job_dir" "$home_dir" "$summary_file" "$details_file" "$catalogue" <<'PY'
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

job_dir = Path(sys.argv[1])
home = Path(sys.argv[2]).resolve()
summary_path = Path(sys.argv[3])
details_path = Path(sys.argv[4])
catalogue = Path(sys.argv[5])

def finish(status, summary, details=""):
    summary_path.write_text(summary.strip() + "\n", encoding="utf-8")
    details_path.write_text(details, encoding="utf-8")
    print(status)
    raise SystemExit(0)

job = json.loads((job_dir / "job.json").read_text(encoding="utf-8"))
brief = (job_dir / "brief.md").read_text(encoding="utf-8") if (job_dir / "brief.md").is_file() else ""
task = str(job.get("task") or "")
allowed = {
    "probe", "qa", "subtitle-lint", "plan",
    "assemble", "subtitle", "voiceover-mix", "broll", "lipsync",
}
if task not in allowed:
    finish("failed", "task not allowed")

excluded = []
current_id = None
current_check = None
if catalogue.is_file():
    for raw in catalogue.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if stripped.startswith("- id:"):
            if current_id and current_check == "excluded":
                excluded.append(current_id)
            current_id = stripped.split(":", 1)[1].strip().strip("\"'")
            current_check = None
        elif stripped.startswith("licence_check:"):
            current_check = stripped.split(":", 1)[1].strip()
    if current_id and current_check == "excluded":
        excluded.append(current_id)

scanned = brief + "\n" + (job_dir / "job.json").read_text(encoding="utf-8")
scanned_cf = scanned.casefold()
for model_id in excluded:
    if model_id.casefold() in scanned_cf:
        finish("failed", "excluded model: %s" % model_id)
aliases = ("minimax", "h3", "hunyuan", "musicgen", "thinksound")
for alias in aliases:
    if re.search(r"(?<![A-Za-z0-9])" + re.escape(alias) + r"(?![A-Za-z0-9])", scanned, re.I):
        finish("failed", "excluded model: %s" % alias)

if re.search(r"voice[\s-]*clon", scanned, re.I):
    finish("failed", "voice cloning is not allowed")

audience = str(job.get("audience") or "")
if job.get("publish_blocked") is True or audience.lower() == "children":
    finish("blocked", "children's content is publish_blocked")
if re.search(r"audience:\s*children", scanned, re.I) or re.search(r"publish_blocked:\s*true", scanned, re.I):
    finish("blocked", "children's content is publish_blocked")

def ledger(status):
    path = home / ".local-agents" / "media-ledger.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "job": job.get("id"),
        "task": task,
        "status": status,
        "cost_estimate": None,
        "budget_check": "not-run",
    }
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")

generative = {"assemble", "subtitle", "voiceover-mix", "broll", "lipsync"}
if task in generative:
    ledger("planned")
    finish("blocked", "v1: generative pipeline not wired to LVS/GPU window yet (#139)")

if task == "plan":
    ledger("planned")
    finish("plan", "plan")

def inputs():
    raw = job.get("inputs") or []
    if isinstance(raw, str):
        raw = [raw]
    found = []
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, str) and item.startswith("path:"):
                found.append(item[5:])
    return found

def allowed_file(text):
    candidate = Path(text)
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    try:
        resolved = candidate.resolve(strict=True)
    except OSError:
        return None, "path does not exist: %s" % text
    if not resolved.is_file():
        return None, "path is not a file: %s" % text
    roots = [home / "media", home / "Applications" / "localvideoediting"]
    for root in roots:
        try:
            root_resolved = root.resolve()
        except OSError:
            continue
        if resolved == root_resolved or root_resolved in resolved.parents:
            return resolved, ""
    return None, "path is outside the media roots: %s" % text

def fraction(value):
    text = str(value or "")
    if "/" in text:
        left, right = text.split("/", 1)
        denom = float(right)
        if denom == 0:
            return None
        return float(left) / denom
    try:
        return float(text)
    except ValueError:
        return None

def probe_file(path):
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,r_frame_rate,avg_frame_rate,sample_rate", "-of", "json", str(path)],
        capture_output=True, text=True, timeout=60, check=False,
    )
    if proc.returncode != 0:
        return ["ffprobe failed for %s" % path.name]
    try:
        payload = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return ["ffprobe json failed for %s" % path.name]
    problems = []
    streams = payload.get("streams") or []
    video = next((item for item in streams if item.get("codec_type") == "video"), None)
    audio = next((item for item in streams if item.get("codec_type") == "audio"), None)
    if video:
        left = fraction(video.get("r_frame_rate"))
        right = fraction(video.get("avg_frame_rate"))
        if left is None or right is None or abs(left - right) > 0.01:
            problems.append("%s is not CFR" % path.name)
    if audio:
        rate = str(audio.get("sample_rate") or "")
        if rate != "48000":
            problems.append("%s audio sample rate is %s" % (path.name, rate or "missing"))
        loud = subprocess.run(
            ["ffmpeg", "-nostats", "-i", str(path), "-af", "loudnorm=print_format=json", "-f", "null", "-"],
            capture_output=True, text=True, timeout=120, check=False,
        )
        blob = loud.stderr or ""
        start = blob.rfind("{")
        end = blob.rfind("}")
        parsed = None
        if start >= 0 and end > start:
            try:
                parsed = json.loads(blob[start:end + 1])
            except json.JSONDecodeError:
                parsed = None
        if not isinstance(parsed, dict):
            problems.append("%s loudnorm json missing" % path.name)
        else:
            try:
                measured_i = float(parsed.get("input_i"))
                measured_tp = float(parsed.get("input_tp"))
            except (TypeError, ValueError):
                problems.append("%s loudnorm values missing" % path.name)
            else:
                if measured_i < -17 or measured_i > -15:
                    problems.append("%s input_i %s is outside -16 LUFS +/-1" % (path.name, measured_i))
                if measured_tp > -1:
                    problems.append("%s input_tp %s is above -1 dBTP" % (path.name, measured_tp))
    elif task == "qa":
        problems.append("%s has no audio stream" % path.name)
    return problems

def lint_subtitle(path):
    raw = path.read_bytes()
    problems = []
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append("%s starts with a BOM" % path.name)
    text = raw.decode("utf-8-sig", errors="replace")
    cedilla = ("\u015f", "\u0163", "\u015e", "\u0162")
    for index, line in enumerate(text.splitlines(), start=1):
        if any(char in line for char in cedilla):
            problems.append("%s:%s uses cedilla s or t" % (path.name, index))
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.isdigit():
            continue
        if "-->" in stripped:
            continue
        upper = stripped.upper()
        if upper.startswith("WEBVTT") or upper.startswith("NOTE") or upper.startswith("STYLE") or upper.startswith("REGION"):
            continue
        if len(stripped) > 42:
            problems.append("%s:%s is longer than 42 characters" % (path.name, index))
    return problems

paths = inputs()
if not paths:
    finish("failed", "no path input")
problems = []
resolved_paths = []
for item in paths:
    resolved, error = allowed_file(item)
    if error:
        problems.append(error)
        continue
    resolved_paths.append(resolved)
if task == "subtitle-lint":
    for resolved in resolved_paths:
        if resolved.suffix.lower() not in (".srt", ".vtt"):
            problems.append("%s is not an srt or vtt file" % resolved.name)
            continue
        problems.extend(lint_subtitle(resolved))
elif task in ("probe", "qa"):
    for resolved in resolved_paths:
        problems.extend(probe_file(resolved))
else:
    finish("failed", "task not allowed")
if problems:
    finish("failed", "\n".join(problems[:10]), "\n".join(problems))
finish("succeeded", "%s passed for %s file(s)" % (task, len(resolved_paths)))
PY
)
py_rc=$?
set -e

if [ "$py_rc" -ne 0 ]; then
  printf '%s\n' "studio-media check failed" >"$summary_file"
  write_result failed "$summary_file" "python exit $py_rc"
  exit 0
fi

details=""
if [ -f "$details_file" ]; then
  details=$(cat "$details_file")
fi

if [ "$decision" != "plan" ]; then
  write_result "$decision" "$summary_file" "$details"
  exit 0
fi

report=$job_dir/report.md
prompt=$job_dir/prompt.md
lvs=$home_dir/Applications/localvideoediting/AGENTS.md
{
  if [ -f "$lvs" ]; then
    printf '%s\n\n' "$(cat "$lvs")"
  fi
  printf '%s\n\n' "$(cat "$job_dir/agent.md")"
  printf '%s\n\n' "$(cat "$job_dir/brief.md")"
  printf '%s\n' "Write a plan in Markdown to report.md. First section '## Summary' max 10 lines. Do not generate media."
} >"$prompt"

wall=$(job_get budget.wall_max)
if [[ ! "$wall" =~ ^[0-9]+[smh]$ ]]; then
  wall=2h
fi
limiter=""
if command -v timeout >/dev/null 2>&1; then
  limiter=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  limiter=gtimeout
fi

run_claude() {
  if [ -n "$limiter" ]; then
    "$limiter" "$wall" llm-run claude --task "$id" --agent local-studio-media --role scout -- \
      -p --output-format text --allowedTools WebSearch WebFetch Read \
      --disallowedTools Bash Edit Write <"$prompt"
  else
    llm-run claude --task "$id" --agent local-studio-media --role scout -- \
      -p --output-format text --allowedTools WebSearch WebFetch Read \
      --disallowedTools Bash Edit Write <"$prompt"
  fi
}

set +e
run_claude >"$report" 2>"$job_dir/claude.err"
claude_rc=$?
set -e
if [ "$claude_rc" -ne 0 ] || [ ! -s "$report" ]; then
  prompt_bytes=$(wc -c <"$prompt" | tr -d '[:space:]')
  if [ "$prompt_bytes" -gt 100000 ]; then
    printf '%s\n' "plan prompt exceeds the agy argument cap" >"$summary_file"
    write_result failed "$summary_file" "claude exit $claude_rc"
    exit 0
  fi
  prompt_text=$(cat "$prompt")
  set +e
  LLM_RUN_BIN=agy llm-run gemini --task "$id" --agent local-studio-media --role scout \
    --model gemini-3.8-flash-high -- \
    --model gemini-3.8-flash-high --output-format text -p "$prompt_text" \
    >"$report" 2>"$job_dir/agy.err"
  agy_rc=$?
  set -e
  if [ "$agy_rc" -ne 0 ] || [ ! -s "$report" ]; then
    printf '%s\n' "plan produced no report" >"$summary_file"
    write_result failed "$summary_file" "claude exit $claude_rc; agy exit $agy_rc"
    exit 0
  fi
fi

python3 - "$report" "$summary_file" <<'PY'
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
picked = []
in_summary = False
seen = False
for line in lines:
    if line.startswith("## Summary"):
        in_summary = True
        seen = True
        continue
    if in_summary and line.startswith("## "):
        break
    if in_summary:
        picked.append(line)
if not seen or not any(line.strip() for line in picked):
    picked = [line for line in lines if line.strip()][:10]
else:
    picked = picked[:10]
Path(sys.argv[2]).write_text("\n".join(picked).strip() + "\n", encoding="utf-8")
PY
write_result succeeded "$summary_file" ""
exit 0
