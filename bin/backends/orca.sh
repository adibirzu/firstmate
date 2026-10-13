#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

FM_BACKEND_ORCA_BUNDLED_CLI_DEFAULT=/Applications/Orca.app/Contents/Resources/bin/orca

fm_backend_orca_bin() {
  local candidate
  if [ -n "${FM_ORCA_CLI:-}" ]; then
    case "$FM_ORCA_CLI" in
      /*) ;;
      *) echo "error: FM_ORCA_CLI must be an absolute executable path" >&2; return 1 ;;
    esac
    [ -x "$FM_ORCA_CLI" ] || {
      echo "error: configured Orca CLI is not executable: $FM_ORCA_CLI" >&2
      return 1
    }
    printf '%s' "$FM_ORCA_CLI"
    return 0
  fi

  if [ -n "${FM_ORCA_BUNDLED_CLI:-}" ]; then
    candidate=$FM_ORCA_BUNDLED_CLI
    [ -x "$candidate" ] || {
      echo "error: configured bundled Orca CLI is not executable: $candidate" >&2
      return 1
    }
    printf '%s' "$candidate"
    return 0
  fi
  candidate=$FM_BACKEND_ORCA_BUNDLED_CLI_DEFAULT
  if [ -x "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = 1 ]; then
    echo "error: backend=orca from Herdr requires an executable app-bundled CLI at $candidate or an explicit FM_ORCA_CLI; PATH fallback is disabled" >&2
    return 1
  fi

  candidate=$(type -P orca 2>/dev/null || true)
  [ -n "$candidate" ] && [ -x "$candidate" ] || {
    echo "error: backend=orca requires FM_ORCA_CLI, the app-bundled CLI, or an executable 'orca' CLI on PATH" >&2
    return 1
  }
  printf '%s' "$candidate"
}

fm_backend_orca_tool_check() {
  fm_backend_orca_bin >/dev/null
}

fm_backend_orca_runtime_check() {
  local out bin
  bin=$(fm_backend_orca_bin) || return 1
  out=$("$bin" status --json 2>/dev/null) || {
    echo "error: backend=orca selected but '$bin status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (field === "repo-path") v = repo.path || "";
if (field === "repo-identity") v = (repo.gitRemoteIdentity && (repo.gitRemoteIdentity.canonicalKey || repo.gitRemoteIdentity.remoteUrl)) || "";
if (field === "repo-default-base") v = repo.defaultBaseBranch || repo.defaultBaseBranchName || repo.baseBranch || r.defaultBaseBranch || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out bin
  bin=$(fm_backend_orca_bin) || return 1
  out=$("$bin" "$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_identity_normalize() {  # <remote-url-or-canonical-key>
  # shellcheck disable=SC2016  # The Node program intentionally receives raw JSON text on stdin.
  printf '%s' "$1" | node -e '
const fs = require("fs");
const raw = fs.readFileSync(0, "utf8").trim();
let host = "";
let pathname = "";
try {
  const scp = raw.match(/^(?:[^@/]+@)?([^/:]+):(.+)$/);
  if (scp && !raw.includes("://")) {
    host = scp[1];
    pathname = scp[2];
  } else if (/^[^/]+\/[^/]+\/.+$/.test(raw) && !raw.includes("://")) {
    const parts = raw.split("/");
    host = parts.shift();
    pathname = parts.join("/");
  } else {
    const url = new URL(raw);
    host = url.protocol === "file:" ? "file" : url.hostname;
    pathname = url.pathname;
    if (url.search || url.hash) process.exit(1);
  }
} catch (_) {
  process.exit(1);
}
pathname = pathname.replace(/^\/+|\/+$/g, "").replace(/\.git$/i, "").toLowerCase();
host = host.toLowerCase();
if (!host || !pathname || pathname.split("/").some(part => !part || part === "." || part === "..")) process.exit(1);
process.stdout.write(`${host}/${pathname}`);
'
}

fm_backend_orca_project_origin_identity() {  # <project-path>
  local project=$1 remote normalized
  remote=$(git -C "$project" remote get-url origin 2>/dev/null) || {
    echo "REFUSED: Orca requires a project with an explicit origin remote; no registration or worktree mutation was made." >&2
    return 1
  }
  normalized=$(fm_backend_orca_identity_normalize "$remote") || {
    echo "REFUSED: the project origin is not a supported repository identity; no Orca mutation was made." >&2
    return 1
  }
  printf '%s' "$normalized"
}

fm_backend_orca_project_base_branch() {  # <project-path>
  local project=$1 ref branch
  ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || {
    echo "REFUSED: origin/HEAD does not identify the intended Orca base branch; no Orca mutation was made." >&2
    return 1
  }
  case "$ref" in
    origin/*) branch=${ref#origin/} ;;
    *) echo "REFUSED: origin/HEAD resolved outside the origin remote; no Orca mutation was made." >&2; return 1 ;;
  esac
  git -C "$project" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}" >/dev/null || {
    echo "REFUSED: the intended origin base branch is not locally available; no Orca mutation was made." >&2
    return 1
  }
  printf '%s' "$branch"
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 project_path out repo_id registered_path registered_identity expected_identity registered_base base bin
  fm_backend_orca_runtime_check || return 1
  bin=$(fm_backend_orca_bin) || return 1
  project_path=$(cd "$project" 2>/dev/null && pwd -P) || {
    echo "REFUSED: Orca project path is unavailable; no registration or worktree mutation was made." >&2
    return 1
  }
  expected_identity=$(fm_backend_orca_project_origin_identity "$project_path") || return 1
  base=$(fm_backend_orca_project_base_branch "$project_path") || return 1
  out=$("$bin" repo show --repo "path:$project_path" --json 2>/dev/null) || {
    echo "REFUSED: Orca could not read the registered project identity; no registration or worktree mutation was made." >&2
    return 1
  }
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null) || {
    echo "REFUSED: the project is not registered in Orca; register it with the matching origin identity before spawning." >&2
    return 1
  }
  registered_path=$(printf '%s' "$out" | fm_backend_orca_json_get repo-path 2>/dev/null) || {
    echo "REFUSED: Orca did not return the registered repository path; no worktree mutation was made." >&2
    return 1
  }
  [ "$registered_path" = "$project_path" ] || {
    echo "REFUSED: Orca returned a different registered project path; no worktree mutation was made." >&2
    return 1
  }
  registered_identity=$(printf '%s' "$out" | fm_backend_orca_json_get repo-identity 2>/dev/null) || {
    echo "REFUSED: Orca did not return a canonical repository identity; no worktree mutation was made." >&2
    return 1
  }
  registered_identity=$(fm_backend_orca_identity_normalize "$registered_identity") || {
    echo "REFUSED: Orca's registered repository identity is malformed; no worktree mutation was made." >&2
    return 1
  }
  [ "$registered_identity" = "$expected_identity" ] || {
    echo "REFUSED: Orca's registered repository identity ($registered_identity) does not match project origin ($expected_identity); align the registration explicitly before spawning." >&2
    return 1
  }
  registered_base=$(printf '%s' "$out" | fm_backend_orca_json_get repo-default-base 2>/dev/null || true)
  if [ -n "$registered_base" ] && [ "$registered_base" != "$base" ]; then
    echo "REFUSED: Orca's registered default base ($registered_base) does not match origin/HEAD ($base); align the base explicitly before spawning." >&2
    return 1
  fi
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal base bin
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  base=$(fm_backend_orca_project_base_branch "$project") || return 1
  bin=$(fm_backend_orca_bin) || return 1
  out=$("$bin" worktree create --repo "id:$repo_id" --name "$name" --no-parent --base-branch "$base" --setup skip --json) || return 1
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal bin
  fm_backend_orca_runtime_check || return 1
  bin=$(fm_backend_orca_bin) || return 1
  out=$("$bin" terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_runtime_check || return 1
  fm_backend_orca_run_json worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path bin
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin) || return 1
  out=$("$bin" worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out bin
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin) || return 1
  out=$("$bin" terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

fm_backend_orca_json_field() {  # <field> <json>
  local field=$1
  printf '%s' "$2" | node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) process.exit(2);
const r = data.result || {};
const term = r.terminal || {};
function scalar(v) {
  return (typeof v === "string" || typeof v === "number" || typeof v === "boolean") ? String(v) : "";
}
let v = "";
if (field === "limited") v = scalar(r.limited ?? term.limited);
if (field === "oldestCursor") v = scalar(r.oldestCursor || term.oldestCursor);
if (field === "nextCursor") v = scalar(r.nextCursor || term.nextCursor);
if (field === "latestCursor") v = scalar(r.latestCursor || term.latestCursor);
if (!v) process.exit(1);
process.stdout.write(v);
' "$field"
}

# Retained as this adapter's only cursor-paged scrollback reader, for a caller
# that needs history beyond one screen. It has NO caller today: the composer read
# below is a bounded tail on purpose and must never fall back to paging.
fm_backend_orca_read_text_paged() {  # <terminal-id> <limit>
  local terminal=$1 limit=${2:-200} out limited oldest cursor_out text older_text bin
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin) || return 1
  out=$("$bin" terminal read --terminal "$terminal" --limit "$limit" --json) || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok || return 1
  text=$(fm_backend_orca_json_text "$out") || return 1
  limited=$(fm_backend_orca_json_field limited "$out" 2>/dev/null || true)
  oldest=$(fm_backend_orca_json_field oldestCursor "$out" 2>/dev/null || true)
  if [ "$limited" = true ] && [ -n "$oldest" ]; then
    cursor_out=$("$bin" terminal read --terminal "$terminal" --cursor "$oldest" --limit "$limit" --json) || return 1
    printf '%s' "$cursor_out" | fm_backend_orca_json_ok || return 1
    older_text=$(fm_backend_orca_json_text "$cursor_out") || return 1
    text="${older_text}"$'\n'"${text}"
  fi
  printf '%s' "$text"
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then retry Enter until
# the composer row reads empty. Retries send only Enter, so a slash-command
# popup placeholder fill gets the required second Enter without duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 state
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_orca_send_key "$terminal" Enter || true
    sleep "$sleep_s"
    state=$(fm_backend_orca_composer_state "$terminal")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never even attempted, not an endpoint proven gone - with no
# CLI there is no read that could show the terminal absent - so it reports the
# failure its tool check already named instead of a success. The close call
# itself stays best-effort: whether an accepted-then-failed close left the
# terminal alive is not yet decidable without a presence re-read proven
# against the real Orca binary (docs/verification/runtime-backends.md
# "Endpoint close").
fm_backend_orca_kill() {  # <terminal-id>
  local bin
  fm_backend_orca_tool_check || return 1
  bin=$(fm_backend_orca_bin) || return 1
  "$bin" terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}
