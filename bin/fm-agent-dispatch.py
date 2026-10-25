#!/usr/bin/env python3
"""fm-agent-dispatch.py - poll GitHub issues and hand one job to a local agent.

Commands:
  loop [--config PATH] [--once] [--dry-run]
      Poll every poll_seconds. --once polls a single round.
      --dry-run logs the claim, the result comment, and any reap it would perform.
      It does not edit labels, post comments, start a runner, kill a job, or write a result.
  parse-job FILE [--config PATH] [--label LABEL ...] [--author LOGIN]
      Print the parsed and validated job as JSON.
      A non-zero exit prints {"error": "..."}.
  render-result FILE.json
      Print the result comment Markdown.
  select-host --agent NAME [--host-pref a,b] [--config PATH]
      Print the host decision as JSON. FM_AGENT_NOW overrides the clock.
      FM_AGENT_STATE/<running> supplies live job counts.
      A window open_file is relative to FM_AGENT_STATE. The window is open
      only when now >= not_before and that file exists. Absolute paths and
      any '..' segment are rejected when the config is loaded.

State directory: ${FM_AGENT_STATE:-$HOME/dev/mini-state/local-agents}
  running/ outbox/ artifacts/<job-id>/ events.jsonl dispatch.log lock/

running/<slug>#<n>.json is the claim and result transaction for one issue.
phase moves claiming -> claimed -> running -> result_posting -> result_posted -> labelled.
The record is written before the GitHub call it describes, and a later poll resumes that phase.
Claim and result comments count only when author.login is this dispatcher's
GitHub login and the body carries the nonce stored on that record before the
post. The login is `gh api user --jq .login`, cached as self-login in the state
directory, unless FM_AGENT_SELF_LOGIN is set. secrets.token_hex creates the
nonce. A comment from another author, or with a different nonce, is ignored.

Job text is written to a file for the runner. It is never interpolated into a
shell command. The remote command may contain only the validated job id, the
registry runner name, and the registry SSH host.
"""

import argparse
import json
import os
import re
import secrets
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
PR_INPUT_RE = re.compile(r"^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+)$")
NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
SECRET_PATTERNS = (
    re.compile(r"gh[pousr]_[A-Za-z0-9_]{8,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{8,}"),
    re.compile(r"sk-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"xai-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bBearer\s+[A-Za-z0-9\-._~+/]{8,}={0,2}"),
    re.compile(
        r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
        re.DOTALL,
    ),
    re.compile(
        r"(?i)\b((?:key|token|secret|password)=)"
        r"([A-Za-z0-9+/]{20,}={0,2}|[0-9a-fA-F]{16,})"
    ),
)
TERMINAL_STATES = {"state:running", "state:done", "state:failed", "state:needs-adi"}
STATUS_LABEL = {
    "succeeded": "state:done",
    "failed": "state:failed",
    "blocked": "state:needs-adi",
}
MAX_WALL = 6 * 3600
GH_TIMEOUT_CAP = 60.0
LOCK_PID_STALE_S = 60.0
LOCK_FRESH_RETRIES = 8
LOCK_FRESH_PAUSE = 0.05
BASE_JOB_KEYS = {"job", "id", "task", "host_pref", "budget", "inputs"}
EXTRA_JOB_KEYS = {
    "issue-mapper": {"create"},
    "review-first-pass": {"reviewer", "author_family"},
}
ACTIVE_PHASES = ("claiming", "claimed", "running", "result_posting", "result_posted")
STATE = None
STOP = {"flag": False}
DRY_RUN = False
ACTIVE = []
DETAILS_REPOS = set()
CLOCK_OFFSET = {"seconds": 0.0}

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
  "$FM_AGENT_REGISTRY_SRC"
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


def redact_text(text):
    if not isinstance(text, str) or not text:
        return text if isinstance(text, str) else "", 0
    count = 0

    def bump(repl):
        def apply(match):
            nonlocal count
            count += 1
            if callable(repl):
                return repl(match)
            return repl
        return apply

    updated = text
    for pattern in SECRET_PATTERNS[:-1]:
        updated = pattern.sub(bump("[REDACTED]"), updated)

    def keep_label(match):
        return match.group(1) + "[REDACTED]"

    updated = SECRET_PATTERNS[-1].sub(bump(keep_label), updated)
    return updated, count


def redact(text):
    cleaned, _count = redact_text(text or "")
    return cleaned


def redact_obj(value):
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        total = 0
        cleaned = []
        for item in value:
            new_item, count = redact_obj(item)
            cleaned.append(new_item)
            total += count
        return cleaned, total
    if isinstance(value, dict):
        total = 0
        cleaned = {}
        for key, item in value.items():
            new_key, key_count = redact_text(key) if isinstance(key, str) else (str(key), 0)
            new_item, item_count = redact_obj(item)
            cleaned[new_key] = new_item
            total += key_count + item_count
        return cleaned, total
    return value, 0


def redact_result(result):
    if not isinstance(result, dict):
        return {"redactions": 0}
    cleaned, total = redact_obj(result)
    if not isinstance(cleaned, dict):
        cleaned = {}
    cleaned["redactions"] = total
    return cleaned


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


def clock_now():
    if os.environ.get("FM_AGENT_NOW"):
        return current_now().timestamp() + CLOCK_OFFSET["seconds"]
    return time.time()


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


def process_start_time(pid):
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return ""
    try:
        raw = Path("/proc") / str(pid) / "stat"
        tail = raw.read_text(encoding="utf-8").rsplit(")", 1)[1].split()
        if len(tail) > 19:
            return "proc:" + tail[19]
    except (OSError, IndexError):
        pass
    try:
        proc = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            capture_output=True, text=True, timeout=2, check=False, shell=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        proc = None
    if proc is not None and proc.returncode == 0:
        value = " ".join((proc.stdout or "").split())
        if value:
            return "ps:" + value
    return ""


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


def read_lock_pid(lock):
    try:
        text = (lock / "pid").read_text(encoding="utf-8")
    except OSError:
        return None
    lines = text.splitlines()
    if not lines:
        return None
    try:
        return int(lines[0].strip())
    except ValueError:
        return None


def lock_age(lock):
    try:
        return time.time() - lock.stat().st_mtime
    except OSError:
        return 0.0


def lock_gap_is_fresh(lock):
    if read_lock_pid(lock) is not None:
        return False
    return lock_age(lock) < LOCK_PID_STALE_S


def lock_snapshot(lock):
    text = ""
    try:
        text = (lock / "pid").read_text(encoding="utf-8")
    except OSError:
        text = ""
    try:
        st = lock.stat()
        ino = st.st_ino
        mtime_ns = st.st_mtime_ns
    except OSError:
        ino = None
        mtime_ns = None
    return {"text": text, "ino": ino, "mtime_ns": mtime_ns, "pid": read_lock_pid(lock)}


def snapshot_age(snap):
    if snap.get("mtime_ns") is None:
        return 0.0
    return time.time() - (snap["mtime_ns"] / 1e9)


def snapshot_is_stale(snap):
    pid = snap.get("pid")
    if pid is not None and pid_alive(pid):
        return False
    if pid is not None:
        return True
    return snapshot_age(snap) >= LOCK_PID_STALE_S


def unlink_quiet(path):
    try:
        path.unlink()
    except OSError:
        pass


def publish_lock_pid(state, lock):
    payload = "%s\n%s\n" % (os.getpid(), "%.3f" % time.time())
    tmp = state / (".lock-pid.%s.%s" % (os.getpid(), time.time_ns()))
    try:
        fd = os.open(str(tmp), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except OSError:
        return False
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, payload.encode("utf-8"))
    except OSError:
        os.close(fd)
        unlink_quiet(tmp)
        return False
    os.close(fd)
    dest = lock / "pid"
    try:
        os.link(str(tmp), str(dest))
    except OSError:
        unlink_quiet(tmp)
        return False
    unlink_quiet(tmp)
    return read_lock_pid(lock) == os.getpid()


def hold_stolen_lock():
    raw = os.environ.get("FM_AGENT_LOCK_STEAL_HOLD", "")
    if not raw:
        return
    path = Path(raw)
    try:
        path.write_text("held\n", encoding="utf-8")
    except OSError:
        return
    limit = time.time() + 15
    while path.exists() and time.time() < limit:
        time.sleep(0.05)


def steal_stale_lock(state, lock):
    before = lock_snapshot(lock)
    if not snapshot_is_stale(before):
        if before.get("pid") is not None and pid_alive(before.get("pid")):
            return "live"
        return "fresh"
    stolen = state / (".lock-stale.%s.%s" % (os.getpid(), time.time_ns()))
    try:
        os.rename(str(lock), str(stolen))
    except OSError:
        return "lost"
    after = lock_snapshot(stolen)
    same = after["text"] == before["text"] and after["ino"] == before["ino"]
    if not same or not snapshot_is_stale(after):
        try:
            os.rename(str(stolen), str(lock))
        except OSError:
            pass
        return "lost"
    hold_stolen_lock()
    shutil.rmtree(stolen, ignore_errors=True)
    return "stolen"


def wait_for_fresh_lock(fresh_waits):
    fresh_waits += 1
    if fresh_waits > LOCK_FRESH_RETRIES:
        raise SystemExit("could not acquire dispatcher lock")
    time.sleep(LOCK_FRESH_PAUSE)
    return fresh_waits


def acquire_lock(state):
    lock = state / "lock"
    fresh_waits = 0
    for _ in range(50):
        try:
            lock.mkdir()
        except FileExistsError:
            pid = read_lock_pid(lock)
            if pid is not None and pid_alive(pid):
                raise SystemExit("dispatcher already running (pid %s)" % pid)
            if lock_gap_is_fresh(lock):
                fresh_waits = wait_for_fresh_lock(fresh_waits)
                continue
            outcome = steal_stale_lock(state, lock)
            if outcome == "live":
                pid = read_lock_pid(lock)
                raise SystemExit("dispatcher already running (pid %s)" % pid)
            if outcome != "stolen":
                fresh_waits = wait_for_fresh_lock(fresh_waits)
                continue
            continue
        pause = os.environ.get("FM_AGENT_LOCK_PAUSE", "")
        if pause:
            try:
                time.sleep(float(pause))
            except ValueError:
                pass
        if publish_lock_pid(state, lock):
            return lock
    raise SystemExit("could not acquire dispatcher lock")


def release_lock(lock):
    if lock is None or not lock.is_dir():
        return
    if read_lock_pid(lock) == os.getpid():
        shutil.rmtree(lock, ignore_errors=True)


def open_file_error(value):
    if not isinstance(value, str) or value == "" or value != value.strip():
        return "bad open_file"
    if any(ord(char) < 32 for char in value):
        return "bad open_file"
    if value.startswith("/") or value.startswith("\\") or re.match(r"^[A-Za-z]:", value):
        return "bad open_file: %s" % value
    if any(part == ".." for part in re.split(r"[/\\]", value)):
        return "bad open_file: %s" % value
    if Path(value).is_absolute():
        return "bad open_file: %s" % value
    return None


def validate_window_open_files(data):
    windows = data.get("windows") or {}
    if not isinstance(windows, dict):
        return
    for window in windows.values():
        if not isinstance(window, dict) or "open_file" not in window:
            continue
        value = window.get("open_file")
        if value is None:
            continue
        error = open_file_error(value)
        if error:
            raise SystemExit(error)


def load_config(path):
    config_path = Path(path) if path else DEFAULT_CONFIG
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit("cannot read config: %s" % exc)
    if not isinstance(data, dict) or data.get("version") != 1:
        raise SystemExit("config version must be 1")
    validate_window_open_files(data)
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


def input_items(data):
    raw = data.get("inputs")
    if raw is None:
        return [], None
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list) or not all(isinstance(item, str) for item in raw):
        return None, "bad inputs"
    return raw, None


def repo_input(items):
    for item in items:
        if item.startswith("repo:"):
            return item[5:]
    return None


def validate_job(config, data, labels, issue_repo=None):
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
    allowed_keys = set(BASE_JOB_KEYS) | set(EXTRA_JOB_KEYS.get(agent) or ())
    unknown = sorted(key for key in data if key not in allowed_keys)
    if unknown:
        return None, "unknown job field: %s" % unknown[0]
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
    items, error = input_items(data)
    if error:
        return None, error
    known_repos = set(config.get("repos") or [])
    for item in items:
        if item.startswith("repo:"):
            target = item[5:]
            if target not in known_repos:
                return None, "repo is not allowed: %s" % target
        if item.startswith("pr:"):
            match = PR_INPUT_RE.fullmatch(item[3:])
            if not match:
                return None, "bad pr input"
            if match.group(1) not in known_repos:
                return None, "pr repo is not allowed: %s" % match.group(1)
    if agent == "ocr-runner" and items:
        return None, "ocr-runner does not accept inputs"
    if "create" in data:
        if not isinstance(data.get("create"), bool):
            return None, "bad create"
        if data.get("create") is True:
            target = repo_input(items) or issue_repo
            configured = agents[agent].get("allowed_create_repos")
            if isinstance(configured, list) and configured:
                allowed_targets = [item for item in configured if isinstance(item, str)]
            else:
                allowed_targets = []
            if not target or target not in allowed_targets:
                return None, "create target is not allowed"
    normalized = dict(data)
    normalized["agent"] = agent
    if wall_seconds is not None:
        normalized["wall_seconds"] = wall_seconds
    return normalized, None


def window_reason(window, host):
    reason = window.get("reason")
    if isinstance(reason, str) and reason.strip():
        return reason
    return "%s is closed until %s" % (host, window.get("not_before"))


def window_block(config, host, agent, now, state):
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
            return window_reason(window, host)
        open_file = window.get("open_file")
        if not isinstance(open_file, str) or open_file == "":
            continue
        marker = Path(state) / open_file
        if not marker.is_file():
            return "%s; open file %s is missing" % (window_reason(window, host), open_file)
    return None


def choose_host(config, agent_name, host_pref, now, live_counts, state):
    agent_hosts = list((config.get("agents") or {})[agent_name].get("hosts") or [])
    order = list(host_pref) if host_pref else list(agent_hosts)
    allowed = set(agent_hosts)
    candidates = [host for host in order if host in allowed]
    closed = {}
    runnable = []
    for host in candidates:
        reason = window_block(config, host, agent_name, now, state)
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
            reason = window_block(config, host, agent_name, now, state)
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


def render_result_markdown(result, include_details=True):
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
        ("status", result.get("status")),
        ("pr", result.get("pr")),
        ("redactions", result.get("redactions") if isinstance(result.get("redactions"), int) else 0),
    ]
    if include_details:
        fields[2:2] = [
            ("host", result.get("host")),
            ("repo", repo_ref),
            ("started", result.get("started")),
            ("finished", result.get("finished")),
            ("wall_s", result.get("wall_s") if result.get("wall_s") is not None else 0),
            ("cost", result.get("cost") if isinstance(result.get("cost"), dict) else {}),
            ("artifacts", result.get("artifacts") if isinstance(result.get("artifacts"), list) else []),
            ("details", result.get("details") or ""),
        ]
    body = ["result:"]
    for key, value in fields:
        body.append("  %s: %s" % (key, json.dumps(neutralize(value), ensure_ascii=False)))
    body.append("  summary: |")
    body.append(block)
    heading = "%s@%s" % (agent, host) if include_details else agent
    text = "**Local agent result** \u2014 %s\n```yaml\n%s\n```\n" % (heading, "\n".join(body))
    if not include_details:
        text += "details: kept in the local outbox (%s)\n" % str(result.get("job") or "unknown")
    return text


def seconds_until_deadline(active):
    if not active:
        return None
    now = clock_now()
    deltas = []
    for item in active:
        epoch = item.get("deadline_epoch")
        if isinstance(epoch, (int, float)):
            deltas.append(epoch - now)
    if not deltas:
        return None
    return min(deltas)


def poll_delay(active, configured):
    try:
        delay = float(configured)
    except (TypeError, ValueError):
        delay = 180.0
    if delay < 0:
        delay = 180.0
    remain = seconds_until_deadline(active)
    if remain is None:
        return delay
    return min(delay, max(0.0, remain))


def resolve_timeout(explicit):
    if explicit is None:
        raw = os.environ.get("FM_AGENT_GH_TIMEOUT", "60")
        try:
            explicit = float(raw)
        except ValueError:
            explicit = GH_TIMEOUT_CAP
    else:
        explicit = float(explicit)
    if explicit <= 0:
        explicit = GH_TIMEOUT_CAP
    timeout = min(GH_TIMEOUT_CAP, explicit)
    remain = seconds_until_deadline(ACTIVE)
    if remain is not None:
        timeout = min(timeout, max(0.2, remain))
    return timeout


def gh(args, timeout=None):
    timeout = resolve_timeout(timeout)
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


def atomic_write(path, record):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(".%s.%s.tmp" % (path.name, os.getpid()))
    tmp.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def load_record(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def pid_matches(record):
    pid = record.get("pid")
    pgid = record.get("pgid")
    started = record.get("process_started")
    if not pid_alive(pid):
        return False
    if isinstance(pgid, bool) or not isinstance(pgid, int) or pgid <= 0:
        return False
    if not isinstance(started, str) or not started or process_start_time(pid) != started:
        return False
    try:
        return os.getpgid(pid) == pgid
    except (ProcessLookupError, PermissionError, OSError):
        return False


def record_occupies_slot(record):
    phase = record.get("phase") or "running"
    if phase in ("claiming", "claimed"):
        return True
    if phase != "running":
        return False
    if pid_matches(record):
        return True
    pgid = record.get("pgid")
    if isinstance(pgid, bool) or not isinstance(pgid, int) or pgid <= 0:
        return pid_alive(record.get("pid"))
    return False


def live_counts(state):
    counts = {}
    running = state / "running"
    if not running.is_dir():
        return counts
    for path in running.glob("*.json"):
        record = load_record(path)
        if not isinstance(record, dict) or not record_occupies_slot(record):
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


def claim_marker(job_id, agent, host, token):
    return "dispatcher: claimed %s \u2192 %s@%s token:%s" % (job_id, agent, host, token)


def claim_mentions(body, job_id):
    needle = "dispatcher: claimed %s" % job_id
    index = body.find(needle)
    if index < 0:
        return False
    end = index + len(needle)
    if end < len(body) and (body[end].isalnum() or body[end] in "._-"):
        return False
    return True


def marker_bounded(body, marker):
    if not marker:
        return False
    start = 0
    while True:
        index = body.find(marker, start)
        if index < 0:
            return False
        end = index + len(marker)
        if end >= len(body) or not (body[end].isalnum() or body[end] in "._-"):
            return True
        start = end


def text_bounded(body, needle):
    if not needle:
        return False
    start = 0
    while True:
        index = body.find(needle, start)
        if index < 0:
            return False
        end = index + len(needle)
        before_ok = index == 0 or not (body[index - 1].isalnum() or body[index - 1] in "._-")
        after_ok = end >= len(body) or not (body[end].isalnum() or body[end] in "._-")
        if before_ok and after_ok:
            return True
        start = index + 1


def comment_author(item):
    if not isinstance(item, dict):
        return ""
    author = item.get("author")
    if isinstance(author, dict):
        return str(author.get("login") or "")
    if isinstance(author, str):
        return author
    return str(item.get("login") or "")


def normalize_comment(item):
    if isinstance(item, str):
        return {"body": item, "login": ""}
    if not isinstance(item, dict):
        return None
    return {"body": str(item.get("body") or ""), "login": comment_author(item)}


def fetch_issue_comments(repo, number):
    proc = gh(["issue", "view", "-R", repo, str(number), "--json", "comments"])
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    comments = data.get("comments")
    if comments is None:
        return []
    if not isinstance(comments, list):
        return None
    parsed = []
    for item in comments:
        normalized = normalize_comment(item)
        if normalized is not None:
            parsed.append(normalized)
    return parsed


def persist_nonce(record, key):
    current = record.get(key)
    if isinstance(current, str) and NONCE_RE.fullmatch(current):
        return current
    nonce = secrets.token_hex(16)
    record[key] = nonce
    return nonce


def login_cache_path(state):
    if state is None:
        return None
    return Path(state) / "self-login"


def read_login_cache(state):
    path = login_cache_path(state)
    if path is None:
        return ""
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""
    if LOGIN_RE.fullmatch(text):
        return text
    return ""


def write_login_cache(state, login):
    path = login_cache_path(state)
    if path is None or not LOGIN_RE.fullmatch(login):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(".%s.%s.tmp" % (path.name, os.getpid()))
    tmp.write_text(login + "\n", encoding="utf-8")
    os.replace(tmp, path)


def self_login(state):
    override = os.environ.get("FM_AGENT_SELF_LOGIN", "").strip()
    if override:
        if LOGIN_RE.fullmatch(override):
            return override
        return ""
    cached = read_login_cache(state)
    if cached:
        return cached
    proc = gh(["api", "user", "--jq", ".login"])
    if proc.returncode != 0:
        return ""
    login = (proc.stdout or "").strip()
    if not login:
        return ""
    login = login.splitlines()[0].strip()
    if not LOGIN_RE.fullmatch(login):
        return ""
    write_login_cache(state, login)
    return login


def record_state(path):
    if STATE is not None:
        return STATE
    if path is None:
        return None
    parent = Path(path).parent
    if parent.name == "running":
        return parent.parent
    return parent


def owned_claim(comments, login, job_id, token):
    if not login or not token:
        return False
    marker = "token:%s" % token
    for item in comments:
        if item.get("login") != login:
            continue
        body = item.get("body") or ""
        if claim_mentions(body, job_id) and marker_bounded(body, marker):
            return True
    return False


def owned_result(comments, login, job_id, nonce):
    if not login or not nonce or not job_id:
        return False
    marker = "result-nonce:%s" % nonce
    for item in comments:
        if item.get("login") != login:
            continue
        body = item.get("body") or ""
        if (
            "Local agent result" in body
            and text_bounded(body, job_id)
            and marker_bounded(body, marker)
        ):
            return True
    return False


def write_outbox(state, result, nonce="", include_details=True):
    job_id = str(result.get("job") or "unknown")
    if not ID_RE.fullmatch(job_id):
        job_id = "unknown"
    outbox = state / "outbox" / ("%s.json" % job_id)
    outbox.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    stage = state / "artifacts" / job_id
    stage.mkdir(parents=True, exist_ok=True)
    body_path = stage / "comment.md"
    text = render_result_markdown(result, include_details=include_details)
    if isinstance(nonce, str) and nonce:
        text += "result-nonce:%s\n" % nonce
    body_path.write_text(text, encoding="utf-8")
    return body_path


def post_result(state, result, had_running, had_queued):
    result = dict(result)
    job_id = str(result.get("job") or "unknown")
    if not ID_RE.fullmatch(job_id):
        job_id = "unknown"
        result["job"] = job_id
    repo = result.get("repo") or ""
    number = result.get("issue")
    if DRY_RUN:
        log("dry-run: would comment result for %s on %s#%s" % (job_id, repo, number))
        log("dry-run: would label %s" % STATUS_LABEL.get(result.get("status"), "state:failed"))
        return False
    path = running_path(state, repo, number) if repo and number is not None else None
    record = load_record(path) if path is not None else None
    if not isinstance(record, dict):
        record = {
            "job_id": job_id,
            "agent": result.get("agent") or "unknown",
            "host": result.get("host") or "none",
            "repo": repo,
            "issue": number,
        }
    phase = record.get("phase")
    if phase in ("result_posting", "result_posted", "labelled") and isinstance(record.get("result"), dict):
        result = record["result"]
    else:
        result = redact_result(result)
        record["result"] = result
        record["phase"] = "result_posting"
        record["had_running"] = bool(had_running)
        record["had_queued"] = bool(had_queued)
        record["job_id"] = job_id
    nonce = persist_nonce(record, "result_nonce")
    had_running = bool(record.get("had_running"))
    had_queued = bool(record.get("had_queued"))
    if path is not None:
        atomic_write(path, record)
    body_path = write_outbox(state, result, nonce, include_details=repo in DETAILS_REPOS)
    if not repo or number is None:
        return False
    if record.get("phase") == "labelled":
        if path is not None and path.exists():
            path.unlink()
        return True
    if record.get("phase") == "result_posting":
        comments = fetch_issue_comments(repo, number)
        if comments is None:
            return False
        if not owned_result(comments, self_login(state), job_id, nonce):
            comment = gh(["issue", "comment", "-R", repo, str(number), "--body-file", str(body_path)])
            if comment.returncode != 0:
                return False
        record["phase"] = "result_posted"
        if path is not None:
            atomic_write(path, record)
    if record.get("phase") == "result_posted":
        label = STATUS_LABEL[result["status"]]
        command = ["issue", "edit", "-R", repo, str(number), "--add-label", label]
        if had_running:
            command.extend(["--remove-label", "state:running"])
        if had_queued:
            command.extend(["--remove-label", "state:queued"])
        edit = gh(command)
        if edit.returncode != 0:
            return False
        if not record.get("event_written"):
            append_event(state, result)
            record["event_written"] = True
        record["phase"] = "labelled"
        if path is not None:
            atomic_write(path, record)
            path.unlink()
        return True
    return False


def ensure_claim(record, path):
    repo = record.get("repo") or ""
    number = record.get("issue")
    job_id = str(record.get("job_id") or "")
    agent = record.get("agent") or "unknown"
    host = record.get("host") or "none"
    if not repo or number is None or not job_id:
        return False
    token = persist_nonce(record, "claim_token")
    if path is not None:
        atomic_write(path, record)
    login = self_login(record_state(path))
    if not login:
        return False
    marker = claim_marker(job_id, agent, host, token)
    comments = fetch_issue_comments(repo, number)
    if comments is None:
        return False
    command = ["issue", "edit", "-R", repo, str(number), "--add-label", "state:running"]
    if record.get("had_queued"):
        command.extend(["--remove-label", "state:queued"])
    edit = gh(command)
    if edit.returncode != 0:
        return False
    if not owned_claim(comments, login, job_id, token) and not record.get("claim_posted"):
        comment = gh(["issue", "comment", "-R", repo, str(number), "--body", marker])
        if comment.returncode != 0:
            return False
        record["claim_posted"] = True
        if path is not None:
            atomic_write(path, record)
    comments = fetch_issue_comments(repo, number)
    if comments is None:
        return False
    return owned_claim(comments, login, job_id, token)


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
    registry = ROOT / "local-agents" / "agents.json"
    (stage / "agents.json").write_text(registry.read_text(encoding="utf-8"), encoding="utf-8")
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
            env["FM_AGENT_REGISTRY_SRC"] = str(ROOT / "local-agents" / "agents.json")
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


def signal_child_group(proc):
    if not isinstance(proc, subprocess.Popen) or proc.poll() is not None:
        return False
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        return False
    return True


def deadline_epoch_of(record):
    raw = record.get("deadline")
    if not isinstance(raw, str) or not raw:
        return None
    try:
        moment = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.now().astimezone().tzinfo)
    return moment.timestamp()


def deadline_reached(record):
    epoch = deadline_epoch_of(record)
    if epoch is None:
        return False
    return clock_now() >= epoch


def track_job(active, record, path, proc=None):
    for item in active:
        if item.get("path") == path:
            item["record"] = record
            item["deadline_epoch"] = deadline_epoch_of(record)
            return item
    item = {
        "proc": proc,
        "supervised": isinstance(proc, subprocess.Popen),
        "record": record,
        "path": path,
        "deadline_epoch": deadline_epoch_of(record),
    }
    active.append(item)
    return item


def job_id_in_use(state, job_id, except_path=None):
    running = state / "running"
    if not running.is_dir():
        return False
    for path in running.glob("*.json"):
        if except_path is not None and path.resolve() == Path(except_path).resolve():
            continue
        record = load_record(path)
        if not isinstance(record, dict) or record.get("job_id") != job_id:
            continue
        phase = record.get("phase") or "running"
        if phase == "labelled":
            continue
        if phase == "running" and pid_alive(record.get("pid")):
            return True
        if phase in ("claiming", "claimed", "result_posting", "result_posted"):
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


def wall_seconds_for(job, agent_cfg):
    seconds = job.get("wall_seconds")
    if isinstance(seconds, int):
        return seconds
    return parse_duration((agent_cfg or {}).get("wall_default") or "10m")


def runner_or_orphan_result(state, record):
    stage = Path(record.get("stage") or (state / "artifacts" / str(record.get("job_id") or "unknown")))
    if record.get("ssh"):
        try:
            fetch_remote_result(record, stage)
        except (OSError, subprocess.TimeoutExpired) as exc:
            log("orphan fetch failed: %s" % exc)
    if (stage / "result.json").is_file():
        return read_runner_result(stage, record, None)
    return base_result(
        record,
        "failed",
        "orphaned after dispatcher restart; remove state:failed (and re-add state:queued) to retry",
    )


def finish_item(state, item, timed_out):
    if DRY_RUN:
        job_id = item["record"].get("job_id")
        if timed_out:
            log("dry-run: would reap %s at deadline" % job_id)
        else:
            log("dry-run: would finish %s" % job_id)
        return
    if item.get("finishing"):
        return
    item["finishing"] = True
    record = item["record"]
    proc = item["proc"]
    stage_raw = record.get("stage")
    stage = Path(stage_raw) if stage_raw else state / "artifacts" / str(record.get("job_id") or "unknown")
    if timed_out:
        if item["supervised"]:
            signal_child_group(proc)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            result = base_result(record, "failed", "timeout")
        else:
            result = base_result(record, "blocked", "runner not supervised after dispatcher restart; not signalled")
    else:
        if record.get("ssh"):
            try:
                fetch_remote_result(record, stage)
            except (OSError, subprocess.TimeoutExpired) as exc:
                log("orphan fetch failed: %s" % exc)
        code = None
        if isinstance(proc, subprocess.Popen):
            code = proc.returncode if proc.returncode is not None else proc.poll()
        result = read_runner_result(stage, record, code)
    post_result(state, result, True, bool(record.get("had_queued")))


def reap_active(state, active):
    if DRY_RUN:
        return
    still = []
    now = clock_now()
    for item in list(active):
        proc = item["proc"]
        deadline = item.get("deadline_epoch")
        if not item["supervised"]:
            if not pid_matches(item["record"]):
                result = base_result(item["record"], "failed", "runner lost: pid reused")
                post_result(state, result, True, bool(item["record"].get("had_queued")))
                continue
            if isinstance(deadline, (int, float)) and now >= deadline:
                finish_item(state, item, True)
                continue
            still.append(item)
            continue
        running = proc.poll() is None
        if running and isinstance(deadline, (int, float)) and now >= deadline:
            finish_item(state, item, True)
            continue
        if not running:
            finish_item(state, item, False)
            continue
        still.append(item)
    active[:] = still


def start_recorded(state, config, record, path, active):
    job = record.get("job")
    agent_name = job.get("agent") if isinstance(job, dict) else None
    host = record.get("host")
    agents = config.get("agents") or {}
    hosts = config.get("hosts") or {}
    if not isinstance(job, dict) or agent_name not in agents or host not in hosts:
        post_result(state, base_result(record, "failed", "cannot resume job"), True, bool(record.get("had_queued")))
        return
    agent_cfg = agents[agent_name]
    host_cfg = hosts[host]
    job = dict(job)
    job["_runner"] = agent_cfg["runner"]
    record["job"] = job
    issue = {
        "repo": record.get("repo"),
        "number": record.get("issue"),
        "title": record.get("title") or "",
        "body": record.get("body") or "",
        "url": record.get("url") or "",
    }
    try:
        stage = prepare_stage(state, job, issue, host)
    except (OSError, ValueError) as exc:
        post_result(state, base_result(record, "failed", "runner did not start: %s" % exc), True, bool(record.get("had_queued")))
        return
    record["stage"] = str(stage)
    atomic_write(path, record)
    try:
        proc = start_process(state, job, host_cfg, stage)
    except (OSError, ValueError) as exc:
        post_result(state, base_result(record, "failed", "runner did not start: %s" % exc), True, bool(record.get("had_queued")))
        return
    try:
        pgid = os.getpgid(proc.pid)
    except (ProcessLookupError, PermissionError, OSError):
        pgid = proc.pid
    started = datetime.now().astimezone()
    seconds = record.get("wall_seconds")
    if not isinstance(seconds, int):
        seconds = wall_seconds_for(job, agent_cfg)
    deadline = started + timedelta(seconds=seconds)
    record["pid"] = proc.pid
    record["pgid"] = pgid
    record["process_started"] = process_start_time(proc.pid)
    if not record["process_started"]:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        proc.wait()
        post_result(state, base_result(record, "failed", "runner did not start: process identity unavailable"), True, bool(record.get("had_queued")))
        return
    record["phase"] = "running"
    record["started_at"] = iso(started)
    record["deadline"] = iso(deadline)
    record["had_running"] = True
    atomic_write(path, record)
    item = track_job(active, record, path, proc)
    if proc.poll() is not None:
        finish_item(state, item, False)


def continue_job(state, config, record, path, active):
    phase = record.get("phase") or ("running" if record.get("pid") else "claiming")
    record["phase"] = phase
    if phase in ("result_posting", "result_posted", "labelled"):
        result = record.get("result")
        if not isinstance(result, dict):
            result = runner_or_orphan_result(state, record)
        post_result(state, result, bool(record.get("had_running")), bool(record.get("had_queued")))
        return
    if phase == "running":
        if pid_matches(record):
            track_job(active, record, path)
            return
        result = base_result(record, "failed", "runner lost: pid reused")
        post_result(state, result, True, bool(record.get("had_queued")))
        return
    if phase == "claiming":
        if not ensure_claim(record, path):
            log("claim incomplete for %s; not starting" % record.get("job_id"))
            atomic_write(path, record)
            return
        record["phase"] = "claimed"
        atomic_write(path, record)
        phase = "claimed"
    if phase == "claimed":
        if record.get("pid"):
            if pid_matches(record):
                record["phase"] = "running"
                atomic_write(path, record)
                track_job(active, record, path)
            else:
                result = base_result(record, "failed", "runner lost: pid reused")
                post_result(state, result, True, bool(record.get("had_queued")))
            return
        start_recorded(state, config, record, path, active)


def launch_job(state, config, job, issue, names, host, dry_run, active):
    agent_cfg = config["agents"][job["agent"]]
    host_cfg = config["hosts"][host]
    job = dict(job)
    job["_runner"] = agent_cfg["runner"]
    path = running_path(state, issue["repo"], issue["number"])
    existing = load_record(path)
    if isinstance(existing, dict) and (existing.get("phase") or "claiming") in ACTIVE_PHASES:
        if dry_run or DRY_RUN:
            log("dry-run: would resume %s for %s" % (existing.get("phase") or "claiming", existing.get("job_id")))
            log("dry-run: not starting %s on %s" % (job["id"], host))
            return
        continue_job(state, config, existing, path, active)
        return
    if dry_run or DRY_RUN:
        log("dry-run: would claim %s on %s#%s -> %s@%s" % (job["id"], issue["repo"], issue["number"], job["agent"], host))
        log("dry-run: would comment %s" % claim_marker(job["id"], job["agent"], host, "dry-run"))
        log("dry-run: not starting %s on %s" % (job["id"], host))
        return
    if job_id_in_use(state, job["id"], path):
        record, summary = failure_record(issue, job["agent"], job["id"], host, "job id already in use")
        post_result(state, base_result(record, "failed", summary), False, "state:queued" in names)
        return
    record = {
        "phase": "claiming",
        "job_id": job["id"],
        "job": job,
        "host": host,
        "pid": None,
        "pgid": None,
        "started_at": None,
        "deadline": None,
        "repo": issue["repo"],
        "issue": issue["number"],
        "agent": job["agent"],
        "title": issue.get("title") or "",
        "body": issue.get("body") or "",
        "url": issue.get("url") or "",
        "stage": None,
        "ssh": host_cfg.get("ssh"),
        "dev_guard": bool(host_cfg.get("dev_guard")),
        "had_queued": "state:queued" in names,
        "had_running": False,
        "wall_seconds": wall_seconds_for(job, agent_cfg),
    }
    atomic_write(path, record)
    continue_job(state, config, record, path, active)


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


def rehydrate(state, config, active):
    running = state / "running"
    if not running.is_dir():
        return
    for path in sorted(running.glob("*.json")):
        record = load_record(path)
        if not isinstance(record, dict):
            continue
        phase = record.get("phase") or ("running" if record.get("pid") else "claiming")
        if DRY_RUN:
            if phase == "running" and pid_matches(record) and deadline_reached(record):
                log("dry-run: would finish %s unsupervised at deadline" % record.get("job_id"))
            else:
                log("dry-run: would resume %s for %s" % (phase, record.get("job_id")))
            continue
        continue_job(state, config, record, path, active)


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
            if dry_run or DRY_RUN:
                log("dry-run: would comment failure on %s#%s" % (repo, number))
                continue
            record, _summary = failure_record(wrapped, "unknown", "unknown", "none", str(exc))
            post_result(state, base_result(record, "failed", "job block is not valid yaml: %s" % exc), False, "state:queued" in names)
            continue
        job, error = validate_job(config, data, names, wrapped["repo"])
        if error:
            if dry_run or DRY_RUN:
                log("dry-run: would comment failure on %s#%s" % (repo, number))
                continue
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
            state,
        )
        if decision["action"] == "retry":
            log("retry %s#%s %s" % (repo, number, job["id"]))
            continue
        if decision["action"] == "blocked":
            if dry_run or DRY_RUN:
                log("dry-run: would comment blocked on %s#%s" % (repo, number))
                continue
            record, _summary = failure_record(wrapped, job["agent"], job["id"], "none", decision["reason"])
            post_result(state, base_result(record, "blocked", decision["reason"]), False, "state:queued" in names)
            continue
        launch_job(state, config, job, wrapped, names, decision["host"], dry_run, active)


def sleep_poll(seconds, stop):
    delay = max(0.0, float(seconds))
    log("poll sleep %.3f" % delay)
    if os.environ.get("FM_AGENT_NOW"):
        CLOCK_OFFSET["seconds"] += delay
        return
    end = time.time() + delay
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
    global STATE, DRY_RUN, ACTIVE, DETAILS_REPOS
    DRY_RUN = bool(args.dry_run)
    CLOCK_OFFSET["seconds"] = 0.0
    config = load_config(args.config)
    DETAILS_REPOS = {
        repo for repo in config.get("details_repos") or []
        if isinstance(repo, str) and repo in (config.get("repos") or [])
    }
    STATE = ensure_state()
    lock = acquire_lock(STATE)
    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    active = []
    ACTIVE = active
    try:
        rehydrate(STATE, config, active)
        reap_active(STATE, active)
        while not STOP["flag"]:
            for repo in config.get("repos") or []:
                if STOP["flag"]:
                    break
                reap_active(STATE, active)
                if STOP["flag"]:
                    break
                try:
                    poll_repo(STATE, config, repo, args.dry_run, active)
                except Exception as exc:
                    log("poll %s failed: %s" % (repo, exc))
                reap_active(STATE, active)
            if args.once or STOP["flag"]:
                break
            configured = config.get("poll_seconds")
            if configured is None:
                configured = 180
            sleep_poll(poll_delay(active, configured), STOP)
            reap_active(STATE, active)
    finally:
        release_lock(lock)
        DRY_RUN = False
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
    job, error = validate_job(config, data, args.label or [], issue_repo=args.repo or None)
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
    data = redact_result(data)
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
    decision = choose_host(config, agent, host_pref, current_now(), live_counts(STATE), STATE)
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
    parse.add_argument("--repo", default="")
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
