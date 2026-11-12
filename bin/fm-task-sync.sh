#!/usr/bin/env bash
# fm-task-sync.sh - guarded FirstMate task-sync bridge across Paperclip, Linear,
# GitHub PRs, cross-Mac custody fences, and this home's local backlog.
#
# Usage:
#   fm-task-sync.sh [--dry-run | --apply] [--project <slug>] [--initiative <id>]
#                   [--limit <n>] [--inbox-note <note-id>] [--json]
#   fm-task-sync.sh --help
#
# Flags:
#   --dry-run              Read external state and compute the reconciliation
#                          plan without modifying external trackers, backlog.md,
#                          local project clones, or last-sync.json (default when
#                          neither --dry-run nor --apply is specified).
#   --apply                Reconcile external tracker metadata (via paperclip-cyb
#                          sync --apply, or cyb-linear-sync --apply when
#                          LINEAR_API_KEY is set), queue unblocked [CYB-xxx]
#                          items locally via bin/fm-tasks-axi.sh (never with
#                          --start), refresh clean local clones for newly merged
#                          PRs via bin/fm-fleet-sync.sh, and atomically write
#                          $FM_HOME/state/paperclip-sync/last-sync.json.
#   --project <slug>       Restrict reconciliation to one exact project or repo
#                          slug (for example firstmate or pentforge).
#   --initiative <id>      Restrict reconciliation to one Linear initiative
#                          (for example I-3 .. I-8).
#   --limit <n>            Cap newly queued [CYB-xxx] tasks in a single pass
#                          (non-negative integer; 0 = unlimited).
#   --inbox-note <note-id> Requires --apply. Publishes the standalone outcome
#                          reply via bin/fm-inbox.sh reply <note-id> - (if not
#                          already recorded under state/inbox/.replies/) and
#                          acknowledges via bin/fm-inbox.sh drain --ack <note-id>.
#   --json                 Print the structured fm-task-sync.v1 JSON receipt on
#                          stdout instead of the human outcome digest.
#   -h, --help             Print this header and exit 0.
#
# State files (gitignored under $FM_HOME/state/paperclip-sync/):
#   .sync.lock             Single-flight directory lock acquired via fm-wake-lib.
#   last-sync.json         Atomic receipt written after each --apply pass.
#
# Safety boundaries & refusals:
#   - Hard Rule 1: never writes to any file under $FM_HOME/projects/ or any
#     project worktree; clone updates go strictly through bin/fm-fleet-sync.sh
#     with validated single-segment repository basenames.
#   - Coding host invariant: refuses control-plane hosts adi4 and adi5 on both
#     the real machine hostname and FM_CODING_HOST (must equal adi0; exit 2).
#   - Custody fence: adrians-macbook-pro items (OCD-* / RF* custody, non-adi0
#     executionTarget, and wip/adrians-macbook-pro/*) stay in fenced[] and are
#     never queued as ready adi0 tasks.
#   - Backlog safety: never passes --start to bin/fm-tasks-axi.sh add; tasks
#     enter Queued idempotently keyed by [CYB-xxx].
#   - Lock contention: exits 3 if .sync.lock is held past FM_TASK_SYNC_LOCK_WAIT_SECS.
set -euo pipefail

if [ "${FM_TASK_SYNC_NO_USER_PATH:-0}" != "1" ]; then
  for _extra in "$HOME/.toolbox/bin" "$HOME/.local/bin"; do
    case ":$PATH:" in
      *":$_extra:"*) ;;
      *) [ -d "$_extra" ] && PATH="$PATH:$_extra" ;;
    esac
  done
  unset _extra
fi
export PATH

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
  LINK_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"
  LINK_TARGET="$(readlink "$SOURCE_PATH")"
  case "$LINK_TARGET" in
    /*) SOURCE_PATH="$LINK_TARGET" ;;
    *) SOURCE_PATH="$LINK_DIR/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

PLANNER_PY="$SCRIPT_DIR/fm-task-sync-plan.py"
TASKS_AXI_WRAPPER="${FM_TASK_SYNC_TASKS_AXI_BIN:-$FM_ROOT/bin/fm-tasks-axi.sh}"
FLEET_SYNC_BIN="${FM_TASK_SYNC_FLEET_SYNC_BIN:-$FM_ROOT/bin/fm-fleet-sync.sh}"
INBOX_BIN="${FM_TASK_SYNC_INBOX_BIN:-$FM_ROOT/bin/fm-inbox.sh}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SOURCE_PATH"
}

die() {
  printf 'fm-task-sync: %s\n' "$*" >&2
  exit 2
}

sanitize_reason() {
  python3 -c '
import re, sys
raw = " ".join(sys.stdin.read().split())
raw = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1[REDACTED]", raw)
raw = re.sub(r"\b(?:lin_api|pcp|ghp|ghs|github_pat)_[A-Za-z0-9_]+\b", "[REDACTED]", raw)
raw = re.sub(r"https?://[^\s/@]+@", "https://[REDACTED]@", raw)
print(raw[:280])
'
}

MODE="dry-run"
PROJECT_FILTER=""
INITIATIVE_FILTER=""
LIMIT=0
INBOX_NOTE=""
JSON_OUT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --project)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--project requires a non-empty slug"
      PROJECT_FILTER=$2
      shift 2
      ;;
    --project=*)
      PROJECT_FILTER=${1#--project=}
      [ -n "$PROJECT_FILTER" ] || die "--project requires a non-empty slug"
      shift
      ;;
    --initiative)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--initiative requires a non-empty id"
      INITIATIVE_FILTER=$2
      shift 2
      ;;
    --initiative=*)
      INITIATIVE_FILTER=${1#--initiative=}
      [ -n "$INITIATIVE_FILTER" ] || die "--initiative requires a non-empty id"
      shift
      ;;
    --limit)
      [ "$#" -ge 2 ] || die "--limit requires a non-negative integer"
      case "$2" in
        ''|*[!0-9]*) die "--limit must be a non-negative integer (got '$2')" ;;
      esac
      LIMIT=$2
      shift 2
      ;;
    --limit=*)
      LIMIT=${1#--limit=}
      case "$LIMIT" in
        ''|*[!0-9]*) die "--limit must be a non-negative integer (got '$LIMIT')" ;;
      esac
      shift
      ;;
    --inbox-note)
      [ "$#" -ge 2 ] && [ -n "${2:-}" ] || die "--inbox-note requires a note id"
      case "$2" in
        *[!A-Za-z0-9._-]*) die "invalid --inbox-note id: '$2'" ;;
      esac
      INBOX_NOTE=$2
      shift 2
      ;;
    --inbox-note=*)
      INBOX_NOTE=${1#--inbox-note=}
      [ -n "$INBOX_NOTE" ] || die "--inbox-note requires a note id"
      case "$INBOX_NOTE" in
        *[!A-Za-z0-9._-]*) die "invalid --inbox-note id: '$INBOX_NOTE'" ;;
      esac
      shift
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    *)
      die "unknown argument: $1 (pass --help for usage)"
      ;;
  esac
done

if [ -n "$INBOX_NOTE" ] && [ "$MODE" != "apply" ]; then
  die "--inbox-note requires --apply so a preview never consumes an inbox request"
fi

REAL_HOST="${FM_REAL_HOST_OVERRIDE:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '')}"
REAL_HOST_LOWER="$(printf '%s' "$REAL_HOST" | tr '[:upper:]' '[:lower:]')"
case "$REAL_HOST_LOWER" in
  adi4|adi4.*|adi5|adi5.*|adihost4|adihost4.*|adihost5|adihost5.*|srv2083966|srv2083966.*|srv2121823|srv2121823.*)
    die "refusing task sync on control-plane host '$REAL_HOST': coding tasks execute strictly on adi0"
    ;;
esac

if [ -f "$FM_HOME/config/task-sync.json" ]; then
  if ! python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
blocked = set()
for raw in (cfg.get("blockedHosts") or []):
    if raw:
        h = str(raw).strip().lower()
        blocked.add(h)
        blocked.add(h.split(".", 1)[0])
real_h = sys.argv[2].strip().lower()
real_short = real_h.split(".", 1)[0]
if real_h in blocked or real_short in blocked:
    sys.exit(1)
' "$FM_HOME/config/task-sync.json" "$REAL_HOST_LOWER" 2>/dev/null; then
    die "refusing task sync on blocked host '$REAL_HOST' per config/task-sync.json"
  fi
fi

CODING_HOST="${FM_CODING_HOST:-adi0}"
if [ "$CODING_HOST" != "adi0" ]; then
  die "refusing task sync on FM_CODING_HOST='$CODING_HOST': coding tasks execute strictly on adi0 (adi4 and adi5 are control-plane only)"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -f "$PLANNER_PY" ] || die "missing planner helper: $PLANNER_PY"

# shellcheck source=bin/fm-lock-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

SYNC_STATE_DIR="$STATE/paperclip-sync"
SYNC_LOCK="$SYNC_STATE_DIR/.sync.lock"
LOCK_WAIT="${FM_TASK_SYNC_LOCK_WAIT_SECS:-5}"
case "$LOCK_WAIT" in
  ''|*[!0-9]*) LOCK_WAIT=5 ;;
esac

mkdir -p "$SYNC_STATE_DIR"
LOCK_HELD=0
SCRATCH=""

cleanup() {
  if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then
    rm -rf "$SCRATCH"
  fi
  if [ "$LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$SYNC_LOCK" || true
  fi
}
trap cleanup EXIT

if [ "$LOCK_WAIT" -eq 0 ]; then
  if ! fm_lock_try_acquire "$SYNC_LOCK"; then
    printf 'fm-task-sync: another task sync is already active (%s)\n' "$SYNC_LOCK" >&2
    exit 3
  fi
else
  if ! fm_lock_acquire_wait_max "$SYNC_LOCK" "$LOCK_WAIT"; then
    printf 'fm-task-sync: another task sync is already active (%s)\n' "$SYNC_LOCK" >&2
    exit 3
  fi
fi
LOCK_HELD=1

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-sync.XXXXXX")
PC_JSON="$SCRATCH/paperclip.json"
PC_ERR="$SCRATCH/paperclip.err"
LIN_JSON="$SCRATCH/linear.json"
LIN_ERR="$SCRATCH/linear.err"
RF_JSON="$SCRATCH/rf-mac.json"
PLAN_JSON="$SCRATCH/plan.json"
ADDED_JSONL="$SCRATCH/added.jsonl"
SYNCED_REPOS_TXT="$SCRATCH/synced-repos.txt"
EXTRA_WARNINGS_TXT="$SCRATCH/extra-warnings.txt"
: > "$ADDED_JSONL"
: > "$SYNCED_REPOS_TXT"
: > "$EXTRA_WARNINGS_TXT"

CYB_MAP_PATH="${FM_CYB_PROJECT_MAP:-$HOME/.config/orca-axi/cyb-project-map.json}"

PAPERCLIP_STATUS="ok"
PAPERCLIP_REASON=""
FALLBACK_STATUS="not_needed"

if command -v paperclip-cyb >/dev/null 2>&1; then
  pc_args=(sync)
  if [ "$MODE" = "apply" ]; then
    pc_args+=(--apply)
  else
    pc_args+=(--dry-run)
  fi
  if [ -n "$PROJECT_FILTER" ]; then
    pc_args+=(--project "$PROJECT_FILTER")
  fi
  if [ -n "$INITIATIVE_FILTER" ]; then
    pc_args+=(--initiative "$INITIATIVE_FILTER")
  fi
  pc_args+=(--json)
  if ! paperclip-cyb "${pc_args[@]}" >"$PC_JSON" 2>"$PC_ERR"; then
    PAPERCLIP_STATUS="unavailable"
    PAPERCLIP_REASON=$(sanitize_reason <"$PC_ERR")
    [ -n "$PAPERCLIP_REASON" ] || PAPERCLIP_REASON="paperclip-cyb sync exited non-zero"
  elif ! python3 -c '
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(doc, dict) and doc.get("success") is False:
    sys.exit(1)
' "$PC_JSON" 2>/dev/null; then
    PAPERCLIP_STATUS="unavailable"
    PAPERCLIP_REASON="paperclip-cyb reported unsuccessful response"
  fi
else
  PAPERCLIP_STATUS="unavailable"
  PAPERCLIP_REASON="paperclip-cyb CLI not found on PATH"
fi

if [ "$PAPERCLIP_STATUS" = "unavailable" ]; then
  printf 'PAPERCLIP_UNAVAILABLE: %s\n' "$PAPERCLIP_REASON" >> "$EXTRA_WARNINGS_TXT"
  if [ "$JSON_OUT" -eq 0 ]; then
    printf 'PAPERCLIP_UNAVAILABLE: %s\n' "$PAPERCLIP_REASON" >&2
  fi
  if command -v cyb-linear-sync >/dev/null 2>&1; then
    lin_repo=""
    if [ -n "$PROJECT_FILTER" ] && [ -f "$CYB_MAP_PATH" ]; then
      lin_repo=$(python3 -c '
import json, re, sys
def slug(v):
    return re.sub(r"[^a-z0-9-]+", "-", v.strip().lower()).strip("-")
needle = slug(sys.argv[2])
doc = json.load(open(sys.argv[1], encoding="utf-8"))
for p in doc.get("projects") or []:
    repos = p.get("repos") or ([] if not p.get("primaryRepo") else [p["primaryRepo"]])
    cands = [str(p.get("id") or ""), str(p.get("name") or ""), str(p.get("primaryRepo") or "").split("/")[-1]]
    slugs = {slug(c) for c in cands if c}
    if needle in slugs and len(repos) == 1:
        print(repos[0])
        break
' "$CYB_MAP_PATH" "$PROJECT_FILTER" 2>/dev/null || true)
    fi
    if [ -n "$lin_repo" ]; then
      lin_args=(--repo "$lin_repo")
    else
      lin_args=(--all)
    fi
    if [ "$MODE" = "apply" ] && [ -n "${LINEAR_API_KEY:-}" ]; then
      lin_args+=(--apply)
    else
      lin_args+=(--audit)
    fi
    lin_args+=(--json)
    if cyb-linear-sync "${lin_args[@]}" >"$LIN_JSON" 2>"$LIN_ERR"; then
      FALLBACK_STATUS="ok"
    else
      FALLBACK_STATUS="failed"
      lin_err_msg=$(sanitize_reason <"$LIN_ERR")
      printf 'LINEAR_FALLBACK_WARNING: %s\n' "${lin_err_msg:-cyb-linear-sync failed}" >> "$EXTRA_WARNINGS_TXT"
      printf '{}' > "$LIN_JSON"
    fi
  else
    FALLBACK_STATUS="failed"
    printf 'LINEAR_FALLBACK_WARNING: cyb-linear-sync not found on PATH\n' >> "$EXTRA_WARNINGS_TXT"
    printf '{}' > "$LIN_JSON"
  fi
fi

if command -v rf-mac-sync >/dev/null 2>&1; then
  rf-mac-sync status --json >"$RF_JSON" 2>/dev/null || printf '{}' >"$RF_JSON"
else
  printf '{}' >"$RF_JSON"
fi

python3 "$PLANNER_PY" plan \
  "$PAPERCLIP_STATUS" \
  "$PC_JSON" \
  "$LIN_JSON" \
  "$RF_JSON" \
  "$DATA" \
  "$PROJECTS" \
  "$CYB_MAP_PATH" \
  "$PROJECT_FILTER" \
  "$INITIATIVE_FILTER" \
  "$LIMIT" \
  "$PLAN_JSON"

if [ "$MODE" = "apply" ]; then
  while IFS=$'\t' read -r task_id cyb_id repo_short prio title; do
    [ -n "$task_id" ] || continue
    add_args=(add "$task_id" "[$cyb_id] $title" --kind ship --repo "$repo_short" --priority "$prio" --queue)
    if FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" bash "$TASKS_AXI_WRAPPER" "${add_args[@]}" >/dev/null 2>&1; then
      python3 - "$task_id" "$cyb_id" "$repo_short" "$title" >> "$ADDED_JSONL" <<'PY'
import json, sys
tid, cid, repo, title = sys.argv[1:5]
print(json.dumps({"taskId": tid, "identifier": cid, "repo": repo, "title": title}))
PY
    else
      printf 'BACKLOG_ADD_WARNING: could not queue %s (%s)\n' "$cyb_id" "$task_id" >> "$EXTRA_WARNINGS_TXT"
    fi
  done < <(python3 - "$PLAN_JSON" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
for item in plan.get("toQueue", []):
    tid = str(item["taskId"]).replace("\t", "").replace("\n", "").strip()
    cid = str(item["identifier"]).replace("\t", "").replace("\n", "").strip()
    rshort = str(item["repoShort"]).replace("\t", "").replace("\n", "").strip()
    prio = int(item["priority"])
    clean_title = str(item["title"]).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()
    print(f"{tid}\t{cid}\t{rshort}\t{prio}\t{clean_title}")
PY
  )

  while IFS= read -r repo_short; do
    [ -n "$repo_short" ] || continue
    case "$repo_short" in
      .|..|-*|*[!A-Za-z0-9._-]*)
        printf 'FLEET_SYNC_WARNING: rejected unsafe repository basename %s\n' "$repo_short" >> "$EXTRA_WARNINGS_TXT"
        continue
        ;;
    esac
    if FM_HOME="$FM_HOME" FM_PROJECTS_OVERRIDE="$PROJECTS" bash "$FLEET_SYNC_BIN" "$repo_short" >/dev/null 2>&1; then
      printf '%s\n' "$repo_short" >> "$SYNCED_REPOS_TXT"
    else
      printf 'FLEET_SYNC_WARNING: local copy refresh skipped or needs attention for %s\n' "$repo_short" >> "$EXTRA_WARNINGS_TXT"
    fi
  done < <(python3 - "$PLAN_JSON" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
for repo in plan.get("clonedMergedRepos", []):
    print(repo)
PY
  )
fi

RECEIPT_FILE="$SCRATCH/receipt.json"
DIGEST_FILE="$SCRATCH/captain-digest.txt"

python3 "$PLANNER_PY" receipt \
  "$MODE" \
  "$CODING_HOST" \
  "$PAPERCLIP_STATUS" \
  "$FALLBACK_STATUS" \
  "$PROJECT_FILTER" \
  "$INITIATIVE_FILTER" \
  "$PLAN_JSON" \
  "$ADDED_JSONL" \
  "$SYNCED_REPOS_TXT" \
  "$EXTRA_WARNINGS_TXT" \
  "$RECEIPT_FILE" \
  "$DIGEST_FILE" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$MODE" = "apply" ] && { [ "$PAPERCLIP_STATUS" = "ok" ] || [ "$FALLBACK_STATUS" = "ok" ]; }; then
  tmp_last=$(mktemp "$SYNC_STATE_DIR/.last-sync.XXXXXX")
  cp "$RECEIPT_FILE" "$tmp_last"
  mv "$tmp_last" "$SYNC_STATE_DIR/last-sync.json"
fi

if [ -n "$INBOX_NOTE" ]; then
  if [ ! -f "$STATE/inbox/.replies/$INBOX_NOTE" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" bash "$INBOX_BIN" reply "$INBOX_NOTE" - < "$DIGEST_FILE" >/dev/null
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" bash "$INBOX_BIN" drain --ack "$INBOX_NOTE" >/dev/null
fi

if [ "$JSON_OUT" -eq 1 ]; then
  cat "$RECEIPT_FILE"
else
  cat "$DIGEST_FILE"
fi
