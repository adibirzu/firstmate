#!/usr/bin/env python3
"""fm-agent-dispatch.py - poll GitHub issues and hand one job to a local agent.

Commands:
  loop [--config PATH] [--once] [--dry-run]
      Poll every poll_seconds. --once polls a single round.
      --dry-run still records the claim on the issue and does not start a runner.
  parse-job FILE [--config PATH] [--label LABEL ...] [--author LOGIN]
      Print the parsed and validated job as JSON.
      A non-zero exit prints {"error": "..."}.
  render-result FILE.json
      Print the result comment Markdown.
  select-host --agent NAME [--host-pref a,b] [--config PATH]
      Print the host decision as JSON. FM_AGENT_NOW overrides the clock.
      FM_AGENT_STATE/<running> supplies live job counts.

State directory: ${FM_AGENT_STATE:-$HOME/dev/mini-state/local-agents}
  running/ outbox/ artifacts/<job-id>/ events.jsonl dispatch.log lock/

Job text is written to a file for the runner. It is never interpolated into a
shell command. The remote command may contain only the validated job id, the
registry runner name, and the registry SSH host.
"""

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = ROOT / "local-agents" / "agents.json"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$")
JOB_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9_-]*)/v1$")
DURATION_RE = re.compile(r"^(\d+)([smh])$")
RUNNER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.sh$")
SSH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
FENCE_RE = re.compile(r"```(?:yaml|yml)[^\n]*\n(.*?)```", re.IGNORECASE | re.DOTALL)
SECRET_RE = re.compile(r"(ghp_|github_pat_|AKIA)[A-Za-z0-9_\-]+")
TERMINAL_STATES = {"state:running", "state:done", "state:failed", "state:needs-adi"}
STATUS_LABEL = {
    "succeeded": "state:done",
    "failed": "state:failed",
    "blocked": "state:needs-adi",
}
MAX_WALL = 6 * 3600
STATE = None
STOP = {"flag": False}

REMOTE_SCRIPT = """#!/bin/bash
set -euo pipefail
ssh -o BatchMode=yes "$FM_AGENT_SSH_HOST" "mkdir -p ~/.local-agents/jobs/${FM_AGENT_JOB_ID}"
scp_args=(scp -o BatchMode=yes
  "$FM_AGENT_STAGE/job.json"
  "$FM_AGENT_STAGE/brief.md"
  "$FM_AGENT_STAGE/agent.md")
if [ -f "$FM_AGENT_STAGE/candidates.yaml" ]; then
  scp_args+=("$FM_AGENT_STAGE/candidates.yaml")
fi
scp_args+=(
  "$FM_AGENT_RUNNER_SRC"
  "$FM_AGENT_LIB_SRC"
  "${FM_AGENT_SSH_HOST}:.local-agents/jobs/${FM_AGENT_JOB_ID}/"
)
"${scp_args[@]}"
runner=$(basename "$FM_AGENT_RUNNER_SRC")
if [ "$FM_AGENT_DEV_GUARD" = "1" ]; then
  remote_cmd="cd ~/.local-agents/jobs/${FM_AGENT_JOB_ID} && FM_AGENT_JOB_DIR=\\$PWD dev-guard bash ./${runner}"
else
  remote_cmd="cd ~/.local-agents/jobs/${FM_AGENT_JOB_ID} && FM_AGENT_JOB_DIR=\\$PWD bash ./${runner}"
fi
set +e
ssh -o BatchMode=yes "$FM_AGENT_SSH_HOST" "$remote_cmd"
rc=$?
set -e
scp -o BatchMode=yes "${FM_AGENT_SSH_HOST}:.local-agents/jobs/${FM_AGENT_JOB_ID}/result.json" "$FM_AGENT_STAGE/result.json" || true
scp -o BatchMode=yes "${FM_AGENT_SSH_HOST}:.local-agents/jobs/${FM_AGENT_JOB_ID}/report.md" "$FM_AGENT_STAGE/report.md" || true
exit "$rc"
"""


def redact(text):
    return SECRET_RE.sub("[redacted]", text or "")


def iso(moment):
    return moment.astimezone().isoformat(timespec="seconds")


def log(message):
    if STATE is None:
        return
    line = iso(datetime.now().astimezone()) + " " + redact(message).replace("\n", " ")
    path = STATE / "dispatch.log"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def current_now():
    raw = os.environ.get("FM_AGENT_NOW")
    if not raw:
        return datetime.now().astimezone()
    moment = datetime.fromisoformat(raw.strip())
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.now().astimezone().tzinfo)
    return moment


def parse_duration(value):
    if not isinstance(value, str):
        raise ValueError("bad wall_max")
    match = DURATION_RE.fullmatch(value.strip())
    if not match:
        raise ValueError("bad wall_max")
    number = int(match.group(1))
    unit = match.group(2)
    seconds = number * {"s": 1, "m": 60, "h": 3600}[unit]
    if seconds <= 0:
        raise ValueError("bad wall_max")
    if seconds > MAX_WALL:
        raise ValueError("wall_max exceeds 6h")
    return seconds


def pid_alive(pid):
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def ensure_state():
    raw = os.environ.get("FM_AGENT_STATE")
    if not raw:
        raw = str(Path.home() / "dev" / "mini-state" / "local-agents")
    path = Path(raw)
    path.mkdir(parents=True, exist_ok=True)
    try:
        path.chmod(0o700)
    except OSError:
        pass
    for name in ("running", "outbox", "artifacts"):
        (path / name).mkdir(exist_ok=True)
    return path


def acquire_lock(state):
    lock = state / "lock"
    for _ in range(3):
        try:
            lock.mkdir()
        except FileExistsError:
            pid = 0
            try:
                pid = int((lock / "pid").read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                pid = 0
            if pid_alive(pid):
                raise SystemExit("dispatcher already running (pid %s)" % pid)
            shutil.rmtree(lock, ignore_errors=True)
            continue
        (lock / "pid").write_text(str(os.getpid()) + "\n", encoding="utf-8")
        return lock
    raise SystemExit("could not acquire dispatcher lock")


def release_lock(lock):
    if lock is None or not lock.is_dir():
        return
    try:
        current = int((lock / "pid").read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return
    if current == os.getpid():
        shutil.rmtree(lock, ignore_errors=True)


def load_config(path):
    config_path = Path(path) if path else DEFAULT_CONFIG
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit("cannot read config: %s" % exc)
    if not isinstance(data, dict) or data.get("version") != 1:
        raise SystemExit("config version must be 1")
    return data


class MiniYaml:
    """Small YAML subset used when PyYAML is absent or FM_AGENT_NO_PYYAML=1."""

    def __init__(self, text):
        self.lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        self.n = len(self.lines)
        self.i = 0

    def parse(self):
        self.skip_noise()
        if self.i < self.n and self.lines[self.i].strip() == "---":
            self.i += 1
        value = self.parse_block(0)
        return value

    def indent_of(self, line):
        raw = line[: len(line) - len(line.lstrip(" \t"))]
        if "\t" in raw:
            raise ValueError("tabs are not allowed in job yaml")
        return len(raw)

    def skip_noise(self):
        while self.i < self.n:
            stripped = self.lines[self.i].strip()
            if not stripped or stripped.startswith("#"):
                self.i += 1
                continue
            return

    def parse_block(self, min_indent):
        self.skip_noise()
        if self.i >= self.n:
            return None
        line = self.lines[self.i]
        indent = self.indent_of(line)
        if indent < min_indent:
            return None
        if line.strip().startswith("- "):
            return self.parse_seq(indent)
        return self.parse_map(indent)

    def parse_map(self, indent):
        result = {}
        while self.i < self.n:
            self.skip_noise()
            if self.i >= self.n:
                break
            line = self.lines[self.i]
            current = self.indent_of(line)
            if current < indent:
                break
            if current > indent:
                raise ValueError("unexpected indent near %r" % line.strip())
            stripped = line.strip()
            if stripped.startswith("- "):
                break
            key, _sep, rest = stripped.partition(":")
            key = key.strip()
            if not key:
                raise ValueError("missing key near %r" % stripped)
            rest = rest.strip()
            self.i += 1
            if rest == "|" or rest.startswith("|"):
                chomp = "strip" if rest.startswith("|-") else "keep"
                result[key] = self.parse_block_scalar(indent, chomp)
            elif rest == "":
                result[key] = self.parse_block(indent + 1)
            else:
                result[key] = parse_scalar(rest)
        return result

    def parse_seq(self, indent):
        items = []
        while self.i < self.n:
            self.skip_noise()
            if self.i >= self.n:
                break
            line = self.lines[self.i]
            current = self.indent_of(line)
            stripped = line.strip()
            if current < indent or not stripped.startswith("- "):
                break
            if current > indent:
                raise ValueError("unexpected indent near %r" % stripped)
            rest = stripped[2:].strip()
            self.i += 1
            if rest == "":
                items.append(self.parse_block(indent + 1))
            else:
                items.append(parse_scalar(rest))
        return items

    def parse_block_scalar(self, parent_indent, chomp):
        lines = []
        base = None
        while self.i < self.n:
            line = self.lines[self.i]
            if not line.strip():
                lines.append("")
                self.i += 1
                continue
            current = self.indent_of(line)
            if current <= parent_indent:
                break
            if base is None:
                base = current
            if len(line) >= base:
                lines.append(line[base:])
            else:
                lines.append(line.lstrip(" "))
            self.i += 1
        while lines and lines[-1] == "":
            lines.pop()
            if chomp != "strip":
                break
        text = "\n".join(lines)
        if chomp != "strip" and lines:
            text += "\n"
        return text


def skip_ws(text, index):
    while index < len(text) and text[index] in " \t":
        index += 1
    return index


def read_quoted(text, index):
    quote = text[index]
    index += 1
    chars = []
    while index < len(text):
        char = text[index]
        if quote == "'":
            if char == "'":
                if index + 1 < len(text) and text[index + 1] == "'":
                    chars.append("'")
                    index += 2
                    continue
                return "".join(chars), index + 1
            chars.append(char)
            index += 1
            continue
        if char == "\\":
            if index + 1 >= len(text):
                break
            mapping = {"n": "\n", "t": "\t", "\\": "\\", '"': '"', "r": "\r"}
            chars.append(mapping.get(text[index + 1], text[index + 1]))
            index += 2
            continue
        if char == '"':
            return "".join(chars), index + 1
        chars.append(char)
        index += 1
    raise ValueError("unterminated string")


def coerce_scalar(text):
    value = text.strip()
    if value in ("true", "True", "TRUE"):
        return True
    if value in ("false", "False", "FALSE"):
        return False
    if value in ("null", "Null", "NULL", "~"):
        return None
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    return value


def strip_comment(text):
    in_single = False
    in_double = False
    for index, char in enumerate(text):
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        elif char == "#" and not in_single and not in_double and (index == 0 or text[index - 1] in " \t"):
            return text[:index]
    return text


def parse_flow_at(text, index):
    index = skip_ws(text, index)
    if index >= len(text):
        raise ValueError("expected a value")
    if text[index] == "[":
        return parse_flow_list(text, index)
    if text[index] == "{":
        return parse_flow_map(text, index)
    if text[index] in "\"'":
        return read_quoted(text, index)
    start = index
    while index < len(text) and text[index] not in ",}]#":
        index += 1
    return coerce_scalar(text[start:index]), index


def parse_flow_list(text, index):
    index += 1
    items = []
    while True:
        index = skip_ws(text, index)
        if index < len(text) and text[index] == "]":
            return items, index + 1
        value, index = parse_flow_at(text, index)
        items.append(value)
        index = skip_ws(text, index)
        if index < len(text) and text[index] == ",":
            index += 1
            continue
        if index < len(text) and text[index] == "]":
            return items, index + 1
        raise ValueError("flow list is not closed")


def parse_flow_map(text, index):
    index += 1
    result = {}
    while True:
        index = skip_ws(text, index)
        if index < len(text) and text[index] == "}":
            return result, index + 1
        if text[index] in "\"'":
            key, index = read_quoted(text, index)
        else:
            start = index
            while index < len(text) and text[index] != ":":
                index += 1
            key = text[start:index].strip()
        if not key:
            raise ValueError("flow map key is empty")
        index = skip_ws(text, index)
        if index >= len(text) or text[index] != ":":
            raise ValueError("flow map entry needs a colon")
        index += 1
        value, index = parse_flow_at(text, index)
        result[key] = value
        index = skip_ws(text, index)
        if index < len(text) and text[index] == ",":
            index += 1
            continue
        if index < len(text) and text[index] == "}":
            return result, index + 1
        raise ValueError("flow map is not closed")


def parse_scalar(text):
    raw = strip_comment(text).strip()
    if raw.startswith("[") or raw.startswith("{"):
        value, index = parse_flow_at(raw, 0)
        rest = raw[index:].strip()
        if rest and not rest.startswith("#"):
            raise ValueError("trailing junk after flow value")
        return value
    if raw.startswith('"') or raw.startswith("'"):
        value, index = read_quoted(raw, 0)
        rest = raw[index:].strip()
        if rest and not rest.startswith("#"):
            raise ValueError("trailing junk after quoted value")
        return value
    return coerce_scalar(raw)


def load_yaml(text):
    if os.environ.get("FM_AGENT_NO_PYYAML") == "1":
        return MiniYaml(text).parse()
    try:
        import yaml
    except ImportError:
        return MiniYaml(text).parse()
    return yaml.safe_load(text)


def extract_job_document(text):
    matches = list(FENCE_RE.finditer(text))
    if not matches:
        return text
    errors = []
    for match in matches:
        body = match.group(1)
        try:
            data = load_yaml(body)
        except Exception as exc:
            errors.append(str(exc))
            continue
        if isinstance(data, dict) and "job" in data:
            return body
    if errors:
        raise ValueError(errors[0])
    raise ValueError("job block not found")


def validate_host_pref(config, host_pref):
    if not isinstance(host_pref, list) or not all(isinstance(item, str) for item in host_pref):
        return "host_pref must be a list of host names"
    known = config.get("hosts") or {}
    for host in host_pref:
        if host not in known:
            return "unknown host: %s" % host
    return None


def validate_job(config, data, labels):
    if not isinstance(data, dict):
        return None, "job block must be a mapping"
    job_name = data.get("job")
    match = JOB_RE.fullmatch(job_name) if isinstance(job_name, str) else None
    if not match:
        return None, "bad job"
    agent = match.group(1)
    agent_labels = [label[6:] for label in labels if isinstance(label, str) and label.startswith("agent:")]
    if labels:
        if len(agent_labels) != 1:
            return None, "exactly one agent label"
        if agent_labels[0] != agent:
            return None, "job/agent mismatch"
    agents = config.get("agents") or {}
    if agent not in agents:
        return None, "unknown agent"
    job_id = data.get("id")
    if not isinstance(job_id, str) or not ID_RE.fullmatch(job_id):
        return None, "bad id"
    task = data.get("task")
    if task not in (agents[agent].get("tasks") or []):
        return None, "task not allowed"
    host_pref = data.get("host_pref")
    if host_pref is not None:
        error = validate_host_pref(config, host_pref)
        if error:
            return None, error
        if host_pref and not [host for host in host_pref if host in (agents[agent].get("hosts") or [])]:
            return None, "host_pref matches no agent host"
    budget = data.get("budget")
    wall_seconds = None
    if budget is not None:
        if not isinstance(budget, dict):
            return None, "bad wall_max"
        if budget.get("wall_max") is not None:
            try:
                wall_seconds = parse_duration(budget.get("wall_max"))
            except ValueError as exc:
                return None, str(exc)
    normalized = dict(data)
    normalized["agent"] = agent
    if wall_seconds is not None:
        normalized["wall_seconds"] = wall_seconds
    return normalized, None


def window_block(config, host, agent, now):
    for window in (config.get("windows") or {}).values():
        if not isinstance(window, dict):
            continue
        if window.get("host") != host:
            continue
        if agent not in (window.get("agents") or []):
            continue
        try:
            not_before = datetime.fromisoformat(str(window.get("not_before")))
        except ValueError:
            continue
        if not_before.tzinfo is None:
            not_before = not_before.replace(tzinfo=now.tzinfo)
        if now < not_before:
            return window.get("reason") or "%s is closed until %s" % (host, window.get("not_before"))
    return None


def choose_host(config, agent_name, host_pref, now, live_counts):
    agent_hosts = list((config.get("agents") or {})[agent_name].get("hosts") or [])
    order = list(host_pref) if host_pref else list(agent_hosts)
    allowed = set(agent_hosts)
    candidates = [host for host in order if host in allowed]
    closed = {}
    runnable = []
    for host in candidates:
        reason = window_block(config, host, agent_name, now)
        if reason:
            closed[host] = reason
            continue
        limit = int((config.get("hosts") or {})[host].get("max_jobs") or 1)
        if live_counts.get(host, 0) >= limit:
            continue
        runnable.append(host)
    if runnable:
        return {"action": "run", "host": runnable[0], "reason": ""}
    if host_pref and candidates and len(closed) == len(candidates):
        pref_reason = None
        pref_closed = True
        for host in host_pref:
            reason = window_block(config, host, agent_name, now)
            if not reason:
                pref_closed = False
                break
            pref_reason = pref_reason or reason
        if pref_closed and pref_reason:
            return {"action": "blocked", "host": None, "reason": pref_reason}
    return {"action": "retry", "host": None, "reason": "no eligible host"}


def neutralize(value):
    if isinstance(value, str):
        return value.replace("```", "'''")
    if isinstance(value, list):
        return [neutralize(item) for item in value]
    if isinstance(value, dict):
        return {str(key): neutralize(item) for key, item in value.items()}
    return value


def truncate_summary(summary):
    if not isinstance(summary, str):
        summary = "" if summary is None else str(summary)
    lines = summary.splitlines()
    if len(lines) > 10:
        lines = lines[:10]
    return "\n".join(lines)


def render_result_markdown(result):
    agent = str(result.get("agent") or "unknown")
    host = str(result.get("host") or "none")
    summary_lines = neutralize(truncate_summary(result.get("summary") or "")).splitlines()
    block = "\n".join("    " + line for line in summary_lines) if summary_lines else "    "
    repo = result.get("repo") or ""
    issue = result.get("issue")
    repo_ref = "%s#%s" % (repo, issue) if issue is not None and repo else str(repo)
    fields = [
        ("job", result.get("job")),
        ("agent", result.get("agent")),
        ("host", result.get("host")),
        ("status", result.get("status")),
        ("repo", repo_ref),
        ("started", result.get("started")),
        ("finished", result.get("finished")),
        ("wall_s", result.get("wall_s") if result.get("wall_s") is not None else 0),
        ("pr", result.get("pr")),
        ("cost", result.get("cost") if isinstance(result.get("cost"), dict) else {}),
        ("artifacts", result.get("artifacts") if isinstance(result.get("artifacts"), list) else []),
        ("details", result.get("details") or ""),
    ]
    body = ["result:"]
    for key, value in fields:
        body.append("  %s: %s" % (key, json.dumps(neutralize(value), ensure_ascii=False)))
    body.append("  summary: |")
    body.append(block)
    return "**Local agent result** \u2014 %s@%s\n```yaml\n%s\n```\n" % (agent, host, "\n".join(body))


def gh(args, timeout=None):
    if timeout is None:
        try:
            timeout = int(os.environ.get("FM_AGENT_GH_TIMEOUT", "60"))
        except ValueError:
            timeout = 60
    log("gh " + " ".join(shlex.quote(str(part)) for part in args))
    command = ["gh", *[str(part) for part in args]]
    try:
        proc = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            shell=False,
        )
    except subprocess.TimeoutExpired:
        log("gh timed out")
        return subprocess.CompletedProcess(command, 124, "", "timeout")
    if proc.returncode != 0:
        log("gh failed: " + redact(proc.stderr).replace("\n", " ")[:400])
    return proc


def label_names(issue):
    names = []
    for label in issue.get("labels") or []:
        if isinstance(label, str):
            names.append(label)
        elif isinstance(label, dict) and label.get("name"):
            names.append(str(label["name"]))
    return names


def author_login(issue):
    author = issue.get("author") or {}
    if isinstance(author, dict):
        return str(author.get("login") or "")
    return str(author or "")


def running_path(state, repo, number):
    slug = str(repo).replace("/", "-")
    return state / "running" / ("%s#%s.json" % (slug, number))


def live_counts(state):
    counts = {}
    running = state / "running"
    if not running.is_dir():
        return counts
    for path in running.glob("*.json"):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(record, dict) or not pid_alive(record.get("pid")):
            continue
        host = record.get("host")
        if isinstance(host, str):
            counts[host] = counts.get(host, 0) + 1
    return counts


def search_expr(config):
    parts = ",".join('"agent:%s"' % name for name in (config.get("agents") or {}))
    return "label:" + parts


def append_event(state, result):
    event = {
        "ts": iso(datetime.now().astimezone()),
        "kind": "local_agent.result",
        "job": result.get("job"),
        "agent": result.get("agent"),
        "host": result.get("host"),
        "repo": result.get("repo"),
        "issue": result.get("issue"),
        "status": result.get("status"),
        "wall_s": result.get("wall_s") if result.get("wall_s") is not None else 0,
    }
    with (state / "events.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False) + "\n")


def base_result(record, status, summary, started=None):
    finished = datetime.now().astimezone()
    if started is None:
        raw = record.get("started_at")
        try:
            started = datetime.fromisoformat(raw) if raw else finished
        except ValueError:
            started = finished
    wall = max(0, int((finished - started).total_seconds()))
    return {
        "job": record.get("job_id") or "unknown",
        "agent": record.get("agent") or "unknown",
        "host": record.get("host") or "none",
        "status": status,
        "summary": truncate_summary(summary),
        "artifacts": [],
        "pr": None,
        "cost": {},
        "details": "",
        "repo": record.get("repo") or "",
        "issue": record.get("issue"),
        "started": iso(started) if isinstance(started, datetime) else str(started),
        "finished": iso(finished),
        "wall_s": wall,
    }


def read_runner_result(stage, record, return_code):
    path = Path(stage) / "result.json"
    if not path.is_file():
        code = "none" if return_code is None else str(return_code)
        return base_result(record, "failed", "missing result.json (runner exit %s)" % code)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        code = "none" if return_code is None else str(return_code)
        return base_result(record, "failed", "invalid result.json (runner exit %s)" % code)
    if not isinstance(data, dict) or data.get("status") not in STATUS_LABEL:
        code = "none" if return_code is None else str(return_code)
        return base_result(record, "failed", "invalid result.json (runner exit %s)" % code)
    result = base_result(record, data["status"], data.get("summary") or "")
    if isinstance(data.get("artifacts"), list):
        result["artifacts"] = data["artifacts"]
    if isinstance(data.get("pr"), str) or data.get("pr") is None:
        result["pr"] = data.get("pr")
    if isinstance(data.get("cost"), dict):
        result["cost"] = data["cost"]
    if isinstance(data.get("details"), str):
        result["details"] = data["details"]
    return result


def post_result(state, result, had_running, had_queued):
    job_id = str(result.get("job") or "unknown")
    if not ID_RE.fullmatch(job_id):
        job_id = "unknown"
        result = dict(result)
        result["job"] = job_id
    outbox = state / "outbox" / ("%s.json" % job_id)
    outbox.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    stage = state / "artifacts" / job_id
    stage.mkdir(parents=True, exist_ok=True)
    body_path = stage / "comment.md"
    body_path.write_text(render_result_markdown(result), encoding="utf-8")
    repo = result.get("repo") or ""
    number = result.get("issue")
    comment = gh(["issue", "comment", "-R", repo, str(number), "--body-file", str(body_path)])
    label = STATUS_LABEL[result["status"]]
    command = ["issue", "edit", "-R", repo, str(number), "--add-label", label]
    if had_running:
        command.extend(["--remove-label", "state:running"])
    if had_queued:
        command.extend(["--remove-label", "state:queued"])
    edit = gh(command)
    append_event(state, result)
    if comment.returncode == 0 and edit.returncode == 0 and had_running:
        path = running_path(state, repo, number)
        if path.exists():
            path.unlink()
    return comment.returncode == 0 and edit.returncode == 0


def claim_issue(repo, number, names, job_id, agent, host):
    command = ["issue", "edit", "-R", repo, str(number), "--add-label", "state:running"]
    if "state:queued" in names:
        command.extend(["--remove-label", "state:queued"])
    edit = gh(command)
    comment = gh([
        "issue", "comment", "-R", repo, str(number), "--body",
        "dispatcher: claimed %s \u2192 %s@%s" % (job_id, agent, host),
    ])
    return edit.returncode == 0 and comment.returncode == 0


def runner_file(agent_cfg):
    name = agent_cfg.get("runner")
    if not isinstance(name, str) or not RUNNER_RE.fullmatch(name):
        raise ValueError("bad runner name")
    path = ROOT / "local-agents" / "runners" / name
    if not path.is_file():
        raise ValueError("runner is missing: %s" % name)
    return path


def prepare_stage(state, job, issue, host):
    job_id = job["id"]
    stage = state / "artifacts" / job_id
    stage.mkdir(parents=True, exist_ok=True)
    payload = dict(job)
    payload["_dispatch"] = {
        "repo": issue["repo"],
        "issue": issue["number"],
        "agent": job["agent"],
        "host": host,
        "url": issue.get("url") or "",
    }
    (stage / "job.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    brief = "# %s\n\n%s\n\n%s\n" % (issue.get("title") or "", issue.get("url") or "", issue.get("body") or "")
    (stage / "brief.md").write_text(brief, encoding="utf-8")
    agent_md = ROOT / "local-agents" / "agents" / ("%s.md" % job["agent"])
    (stage / "agent.md").write_text(agent_md.read_text(encoding="utf-8"), encoding="utf-8")
    if job["agent"] == "studio-media":
        source = ROOT / "local-agents" / "studio-media" / "candidates.yaml"
        (stage / "candidates.yaml").write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
    return stage


def open_logs(stage):
    stdout = (stage / "runner.stdout").open("w", encoding="utf-8")
    stderr = (stage / "runner.stderr").open("w", encoding="utf-8")
    return stdout, stderr


def start_process(state, job, host_cfg, stage):
    runner = runner_file((load_agent_cfg(job)))
    lib = ROOT / "local-agents" / "runners" / "lib.sh"
    env = os.environ.copy()
    env["FM_AGENT_JOB_DIR"] = str(stage)
    env["FM_AGENT_STATE"] = str(state)
    env["FM_AGENT_JOB_ID"] = job["id"]
    stdout, stderr = open_logs(stage)
    ssh_host = host_cfg.get("ssh")
    try:
        if not ssh_host:
            proc = subprocess.Popen(
                [str(runner)],
                cwd=str(stage),
                env=env,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
                shell=False,
            )
        else:
            if not isinstance(ssh_host, str) or not SSH_RE.fullmatch(ssh_host):
                raise ValueError("bad ssh host")
            script = stage / "remote-run.sh"
            script.write_text(REMOTE_SCRIPT, encoding="utf-8")
            script.chmod(0o700)
            env["FM_AGENT_SSH_HOST"] = ssh_host
            env["FM_AGENT_STAGE"] = str(stage)
            env["FM_AGENT_RUNNER_SRC"] = str(runner)
            env["FM_AGENT_LIB_SRC"] = str(lib)
            env["FM_AGENT_DEV_GUARD"] = "1" if host_cfg.get("dev_guard") else "0"
            proc = subprocess.Popen(
                ["bash", str(script)],
                cwd=str(stage),
                env=env,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
                shell=False,
            )
    finally:
        stdout.close()
        stderr.close()
    return proc


def load_agent_cfg(job):
    # The caller has already validated the agent against the loaded config.
    # This helper only exists so start_process can resolve the runner file
    # from the job without rebuilding a partial config.
    return {"runner": job.get("_runner")}


def kill_group(proc):
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.kill()
        except (ProcessLookupError, OSError):
            return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def job_id_in_use(state, job_id):
    running = state / "running"
    if not running.is_dir():
        return False
    for path in running.glob("*.json"):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(record, dict) and record.get("job_id") == job_id and pid_alive(record.get("pid")):
            return True
    return False


def failure_record(issue, agent, job_id, host, summary):
    now = datetime.now().astimezone()
    return {
        "job_id": job_id if isinstance(job_id, str) and ID_RE.fullmatch(job_id) else "unknown",
        "agent": agent or "unknown",
        "host": host or "none",
        "repo": issue["repo"],
        "issue": issue["number"],
        "started_at": iso(now),
    }, summary


def launch_job(state, config, job, issue, names, host, dry_run, active):
    agent_cfg = config["agents"][job["agent"]]
    host_cfg = config["hosts"][host]
    job = dict(job)
    job["_runner"] = agent_cfg["runner"]
    if job_id_in_use(state, job["id"]):
        record, summary = failure_record(issue, job["agent"], job["id"], host, "job id already in use")
        post_result(state, base_result(record, "failed", summary), False, "state:queued" in names)
        return
    claimed = claim_issue(issue["repo"], issue["number"], names, job["id"], job["agent"], host)
    if not claimed:
        log("claim failed for %s#%s" % (issue["repo"], issue["number"]))
        return
    if dry_run:
        log("dry-run: not starting %s on %s" % (job["id"], host))
        return
    stage = prepare_stage(state, job, issue, host)
    seconds = job.get("wall_seconds")
    if not isinstance(seconds, int):
        seconds = parse_duration(agent_cfg.get("wall_default") or "10m")
    started = datetime.now().astimezone()
    deadline = started + timedelta(seconds=seconds)
    record = {
        "job_id": job["id"],
        "host": host,
        "pid": None,
        "started_at": iso(started),
        "deadline": iso(deadline),
        "repo": issue["repo"],
        "issue": issue["number"],
        "agent": job["agent"],
        "stage": str(stage),
        "ssh": host_cfg.get("ssh"),
        "dev_guard": bool(host_cfg.get("dev_guard")),
    }
    path = running_path(state, issue["repo"], issue["number"])
    path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    try:
        proc = start_process(state, job, host_cfg, stage)
    except (OSError, ValueError) as exc:
        post_result(state, base_result(record, "failed", "runner did not start: %s" % exc), True, False)
        return
    record["pid"] = proc.pid
    path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    item = {"proc": proc, "record": record, "path": path, "deadline_epoch": deadline.timestamp()}
    if proc.poll() is not None:
        finish_item(state, item, False)
    else:
        active.append(item)


def finish_item(state, item, timed_out):
    proc = item["proc"]
    record = item["record"]
    stage = Path(record["stage"])
    if timed_out:
        kill_group(proc)
        result = base_result(record, "failed", "timeout")
    else:
        result = read_runner_result(stage, record, proc.returncode if proc.returncode is not None else proc.poll())
    post_result(state, result, True, False)


def reap_active(state, active):
    still = []
    now = time.time()
    for item in active:
        proc = item["proc"]
        if proc.poll() is None and now >= item["deadline_epoch"]:
            finish_item(state, item, True)
            continue
        if proc.poll() is not None:
            finish_item(state, item, False)
            continue
        still.append(item)
    active[:] = still


def fetch_remote_result(record, stage):
    ssh_host = record.get("ssh")
    job_id = record.get("job_id")
    if not ssh_host or not job_id or not SSH_RE.fullmatch(str(ssh_host)) or not ID_RE.fullmatch(str(job_id)):
        return
    stage.mkdir(parents=True, exist_ok=True)
    remote = "%s:.local-agents/jobs/%s" % (ssh_host, job_id)
    subprocess.run(
        ["scp", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", remote + "/result.json", str(stage / "result.json")],
        capture_output=True, text=True, timeout=30, check=False, shell=False,
    )
    subprocess.run(
        ["scp", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", remote + "/report.md", str(stage / "report.md")],
        capture_output=True, text=True, timeout=30, check=False, shell=False,
    )


def collect_orphans(state):
    running = state / "running"
    if not running.is_dir():
        return
    for path in list(running.glob("*.json")):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(record, dict) or pid_alive(record.get("pid")):
            continue
        stage = Path(record.get("stage") or (state / "artifacts" / str(record.get("job_id") or "unknown")))
        if record.get("ssh"):
            try:
                fetch_remote_result(record, stage)
            except (OSError, subprocess.TimeoutExpired) as exc:
                log("orphan fetch failed: %s" % exc)
        result_path = stage / "result.json"
        if result_path.is_file():
            result = read_runner_result(stage, record, None)
        else:
            result = base_result(
                record,
                "failed",
                "orphaned after dispatcher restart; remove state:failed (and re-add state:queued) to retry",
            )
        posted = post_result(state, result, True, False)
        if posted and path.exists():
            path.unlink()


def eligible(names):
    if any(name in TERMINAL_STATES for name in names):
        return False
    state_labels = [name for name in names if name.startswith("state:")]
    if not state_labels:
        return True
    return set(state_labels) == {"state:queued"}


def poll_repo(state, config, repo, dry_run, active):
    proc = gh([
        "issue", "list", "-R", repo, "--state", "open", "--limit", "50",
        "--json", "number,title,body,labels,author,url",
        "--search", search_expr(config),
    ])
    if proc.returncode != 0:
        return
    try:
        issues = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        log("issue list for %s was not json" % repo)
        return
    if not isinstance(issues, list):
        log("issue list for %s was not a list" % repo)
        return
    allowed = set(config.get("allowed_authors") or [])
    for issue in issues:
        if STOP["flag"] or not isinstance(issue, dict):
            continue
        number = issue.get("number")
        if not isinstance(number, int):
            continue
        names = label_names(issue)
        if not eligible(names):
            continue
        login = author_login(issue)
        if login not in allowed:
            log("ignore %s#%s author %s" % (repo, number, login))
            continue
        wrapped = {
            "repo": repo,
            "number": number,
            "title": issue.get("title") or "",
            "body": issue.get("body") or "",
            "url": issue.get("url") or "",
        }
        try:
            document = extract_job_document(wrapped["body"])
            data = load_yaml(document)
        except Exception as exc:
            record, _summary = failure_record(wrapped, "unknown", "unknown", "none", str(exc))
            post_result(state, base_result(record, "failed", "job block is not valid yaml: %s" % exc), False, "state:queued" in names)
            continue
        job, error = validate_job(config, data, names)
        if error:
            raw_id = data.get("id") if isinstance(data, dict) else "unknown"
            raw_agent = ""
            if isinstance(data, dict) and isinstance(data.get("job"), str) and "/" in data["job"]:
                raw_agent = data["job"].split("/", 1)[0]
            record, _summary = failure_record(wrapped, raw_agent or "unknown", raw_id, "none", error)
            post_result(state, base_result(record, "failed", error), False, "state:queued" in names)
            continue
        decision = choose_host(
            config,
            job["agent"],
            job.get("host_pref"),
            current_now(),
            live_counts(state),
        )
        if decision["action"] == "retry":
            log("retry %s#%s %s" % (repo, number, job["id"]))
            continue
        if decision["action"] == "blocked":
            record, _summary = failure_record(wrapped, job["agent"], job["id"], "none", decision["reason"])
            post_result(state, base_result(record, "blocked", decision["reason"]), False, "state:queued" in names)
            continue
        launch_job(state, config, job, wrapped, names, decision["host"], dry_run, active)


def sleep_poll(seconds, stop):
    end = time.time() + max(0, seconds)
    while time.time() < end:
        if stop["flag"]:
            return
        try:
            time.sleep(min(0.5, max(0.0, end - time.time())))
        except InterruptedError:
            stop["flag"] = True
            return


def handle_stop(signum, _frame):
    STOP["flag"] = True
    log("signal %s: stop polling, leave running jobs" % signum)


def cmd_loop(args):
    global STATE
    config = load_config(args.config)
    STATE = ensure_state()
    lock = acquire_lock(STATE)
    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    active = []
    try:
        collect_orphans(STATE)
        while not STOP["flag"]:
            reap_active(STATE, active)
            if STOP["flag"]:
                break
            for repo in config.get("repos") or []:
                if STOP["flag"]:
                    break
                try:
                    poll_repo(STATE, config, repo, args.dry_run, active)
                except Exception as exc:
                    log("poll %s failed: %s" % (repo, exc))
                reap_active(STATE, active)
            if args.once or STOP["flag"]:
                break
            try:
                delay = int(config.get("poll_seconds") or 180)
            except (TypeError, ValueError):
                delay = 180
            sleep_poll(delay, STOP)
    finally:
        release_lock(lock)
    return 0


def cmd_parse_job(args):
    config = load_config(args.config)
    try:
        text = Path(args.file).read_text(encoding="utf-8")
        document = extract_job_document(text)
        data = load_yaml(document)
    except Exception as exc:
        print(json.dumps({"error": "job block is not valid yaml: %s" % exc}, ensure_ascii=False))
        return 1
    if args.author:
        allowed = set(config.get("allowed_authors") or [])
        if args.author not in allowed:
            print(json.dumps({"ignored": True, "author": args.author}, ensure_ascii=False))
            return 0
    job, error = validate_job(config, data, args.label or [])
    if error:
        print(json.dumps({"error": error}, ensure_ascii=False))
        return 1
    print(json.dumps(job, ensure_ascii=False, indent=2))
    return 0


def cmd_render_result(args):
    try:
        data = json.loads(Path(args.file).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(json.dumps({"error": "invalid result json: %s" % exc}))
        return 1
    if isinstance(data, dict) and isinstance(data.get("result"), dict):
        data = data["result"]
    if not isinstance(data, dict):
        print(json.dumps({"error": "result json must be an object"}))
        return 1
    sys.stdout.write(render_result_markdown(data))
    return 0


def cmd_select_host(args):
    global STATE
    config = load_config(args.config)
    STATE = ensure_state()
    agent = args.agent
    if agent not in (config.get("agents") or {}):
        print(json.dumps({"error": "unknown agent"}))
        return 1
    host_pref = None
    if args.host_pref:
        host_pref = [part.strip() for part in args.host_pref.split(",") if part.strip()]
        error = validate_host_pref(config, host_pref)
        if error:
            print(json.dumps({"error": error}))
            return 1
    decision = choose_host(config, agent, host_pref, current_now(), live_counts(STATE))
    print(json.dumps(decision, ensure_ascii=False))
    return 0 if decision.get("action") != "error" else 1


def main(argv):
    parser = argparse.ArgumentParser(
        prog="fm-agent-dispatch.py",
        description="Issue-driven dispatcher for local agents.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    loop = sub.add_parser("loop", help="poll issues and dispatch jobs")
    loop.add_argument("--config", default=None)
    loop.add_argument("--once", action="store_true")
    loop.add_argument("--dry-run", action="store_true")
    loop.set_defaults(func=cmd_loop)

    parse = sub.add_parser("parse-job", help="parse and validate one job file")
    parse.add_argument("file")
    parse.add_argument("--config", default=None)
    parse.add_argument("--label", action="append", default=[])
    parse.add_argument("--author", default="")
    parse.set_defaults(func=cmd_parse_job)

    render = sub.add_parser("render-result", help="render a result comment")
    render.add_argument("file")
    render.set_defaults(func=cmd_render_result)

    select = sub.add_parser("select-host", help="choose a host for one agent")
    select.add_argument("--config", default=None)
    select.add_argument("--agent", required=True)
    select.add_argument("--host-pref", default="")
    select.set_defaults(func=cmd_select_host)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
