#!/usr/bin/env bash
# Behavior tests for bin/fm-task-sync.sh, bin/fm-task-sync-plan.py, and bin/fm-sync.sh:
#   - --help, --dry-run, and --apply modes with stubbed external sync authorities
#   - Hard Rule 1 preservation (zero writes inside $FM_HOME/projects/*)
#   - adi0-only coding guard (refuses FM_CODING_HOST or real host adi4 / adi5)
#   - Idempotent [CYB-xxx] backlog insertion via bin/fm-tasks-axi.sh (never --start)
#   - Merged PR clone refresh via bin/fm-fleet-sync.sh on matching local clones
#   - adrians-macbook-pro (OCD-*) custody fencing (reported in fenced, never queued)
#   - Graceful fallback to cyb-linear-sync + rf-mac-sync when Paperclip is unreachable
#   - Lock contention safety ($FM_HOME/state/paperclip-sync/.sync.lock)
#   - --inbox-note <id> reply + drain --ack roundtrip and retry idempotency
#   - fm-sync.sh convenience entrypoint routing (live inbox note vs direct sync)
set -euo pipefail

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC_BIN="$ROOT/bin/fm-task-sync.sh"
PLAN_PY="$ROOT/bin/fm-task-sync-plan.py"
ENTRY_BIN="$ROOT/bin/fm-sync.sh"
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
[ -f "$PLAN_PY" ] || fail "missing $PLAN_PY"
TMP_ROOT=$(fm_test_tmproot fm-task-sync)

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE \
  FM_CODING_HOST

make_case_home() {  # <case-name>
  local dir="$TMP_ROOT/$1"
  mkdir -p \
    "$dir/home/data" \
    "$dir/home/state" \
    "$dir/home/config" \
    "$dir/home/projects/pentforge" \
    "$dir/fakebin" \
    "$dir/logs"
  cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
  printf 'unchanged-project-sentinel\n' > "$dir/home/projects/pentforge/README.md"

  # Portable tasks-axi stub that enforces no --start on add and appends to TASKS_AXI_FILE.
  cat > "$dir/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TEST_LOG_DIR:?}"
printf '%s\n' "$*" >> "$log_dir/tasks-axi.calls"
cmd="${1:-}"
shift || true
case "$cmd" in
  add|create)
    id="${1:-}"
    title="${2:-}"
    shift 2 || true
    repo=""
    kind="ship"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --start)
          printf 'tasks-axi stub: forbidden --start passed!\n' >&2
          exit 99
          ;;
        --repo) repo="$2"; shift 2 ;;
        --kind) kind="$2"; shift 2 ;;
        --priority|--body|--body-file|--blocked-by|--pr|--report|--prefix) shift 2 ;;
        --queue|--json|--mint) shift ;;
        *) shift ;;
      esac
    done
    backlog="${TASKS_AXI_FILE:?}"
    python3 - "$backlog" "$id" "$title" "$repo" "$kind" <<'PY'
import pathlib, sys
backlog = pathlib.Path(sys.argv[1])
tid, title, repo, kind = sys.argv[2:6]
text = backlog.read_text(encoding="utf-8")
meta = []
if repo:
    meta.append(f"(repo: {repo})")
if kind:
    meta.append(f"(kind: {kind})")
suffix = (" " + " ".join(meta)) if meta else ""
line = f"- [ ] {tid} - {title}{suffix}\n"
if "## Queued\n" in text:
    text = text.replace("## Queued\n", "## Queued\n" + line, 1)
else:
    text += "\n## Queued\n" + line
backlog.write_text(text, encoding="utf-8")
PY
    ;;
  list)
    backlog="${TASKS_AXI_FILE:?}"
    cat "$backlog"
    ;;
  *)
    ;;
esac
EOF
  chmod +x "$dir/fakebin/tasks-axi"

  # Default paperclip-cyb stub returning rich 4-way sync payload.
  cat > "$dir/fakebin/paperclip-cyb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TEST_LOG_DIR:?}"
printf '%s\n' "$*" >> "$log_dir/paperclip-cyb.calls"
if [ "${PAPERCLIP_STUB_FAIL:-0}" = "1" ]; then
  printf 'paperclip-cyb: Tailscale HTTPS https://adi5.example.invalid:9448 unreachable\n' >&2
  exit 1
fi
cat <<'JSON'
{
  "success": true,
  "data": {
    "orgs": [
      {"slug": "cyb-01-fleet-harness", "initiative": "I-3", "budgetHealthy": true},
      {"slug": "cyb-02-pentforge-sec", "initiative": "I-4", "budgetHealthy": true}
    ],
    "readyTasks": [
      {
        "identifier": "CYB-501",
        "title": "Harden Pentforge webhook signature verification",
        "repo": "adibirzu/pentforge",
        "project": "pentforge",
        "initiative": "I-4",
        "priority": 1,
        "executionTarget": "adi0-firstmate"
      },
      {
        "identifier": "CYB-502",
        "title": "Add AetherOps OCI guardrail telemetry",
        "repo": "adibirzu/aetherops",
        "project": "aetherops",
        "initiative": "I-7",
        "priority": 2,
        "executionTarget": "adi0-firstmate"
      },
      {
        "identifier": "OCD-498",
        "title": "Sol 6.1 primary custody packaging",
        "repo": "adibirzu/reviewforge",
        "project": "reviewforge",
        "custodyHost": "adrians-macbook-pro",
        "fenced": true
      }
    ],
    "openPrs": [
      {
        "identifier": "CYB-490",
        "repo": "adibirzu/pentforge",
        "number": 42,
        "url": "https://github.com/adibirzu/pentforge/pull/42",
        "ciStatus": "green",
        "awaitingCaptainMerge": true
      }
    ],
    "mergedPrs": [
      {
        "identifier": "CYB-488",
        "repo": "adibirzu/pentforge",
        "number": 41,
        "url": "https://github.com/adibirzu/pentforge/pull/41"
      },
      {
        "identifier": "CYB-489",
        "repo": "adibirzu/uncloned-service",
        "number": 9,
        "url": "https://github.com/adibirzu/uncloned-service/pull/9"
      }
    ],
    "fenced": [
      {
        "identifier": "RF08/OCD-503",
        "host": "adrians-macbook-pro",
        "reason": "Active Sol 6.1 / Terra 6.1 primary custody"
      }
    ]
  }
}
JSON
EOF
  chmod +x "$dir/fakebin/paperclip-cyb"

  # Fallback cyb-linear-sync stub.
  cat > "$dir/fakebin/cyb-linear-sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TEST_LOG_DIR:?}"
printf '%s\n' "$*" >> "$log_dir/cyb-linear-sync.calls"
cat <<'JSON'
{
  "success": true,
  "data": {
    "repos": [
      {
        "repo": "adibirzu/pentforge",
        "projectId": "P-CYB-9",
        "projectName": "Pentforge",
        "matched": [
          {
            "ghNumber": 12,
            "ghTitle": "Fallback Pentforge CSP enforcement",
            "linearIdentifier": "CYB-610",
            "state": "Todo"
          }
        ],
        "foreignMirrors": [],
        "reconcileProject": [],
        "missingInLinear": []
      }
    ],
    "applied": []
  },
  "error": null,
  "meta": {"mode": "audit", "agentDispatch": "forbidden"}
}
JSON
EOF
  chmod +x "$dir/fakebin/cyb-linear-sync"

  # rf-mac-sync stub exposing adrians-macbook-pro OCD-* custody fence.
  cat > "$dir/fakebin/rf-mac-sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TEST_LOG_DIR:?}"
printf '%s\n' "$*" >> "$log_dir/rf-mac-sync.calls"
cat <<'JSON'
{
  "project": "P-OCD-70 (ReviewForge)",
  "hosts": [
    {
      "host": "adrians-macbook-pro",
      "custody_role": "primary_repo_custody",
      "active_issues": ["RF03/OCD-498", "RF08/OCD-503"]
    },
    {
      "host": "adi0",
      "custody_role": "orthogonal_companion_custody",
      "deliverables": ["RF02/OCD-497 ADRs"]
    }
  ]
}
JSON
EOF
  chmod +x "$dir/fakebin/rf-mac-sync"

  # Stub fleet-sync recorder injected via FM_TASK_SYNC_FLEET_SYNC_BIN.
  cat > "$dir/fakebin/fleet-sync-spy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_dir="${TEST_LOG_DIR:?}"
printf '%s\n' "$*" >> "$log_dir/fleet-sync.calls"
printf 'updated: %s\n' "${1:-all}"
EOF
  chmod +x "$dir/fakebin/fleet-sync-spy"

  printf '%s\n' "$dir"
}

run_sync() {  # <case-dir> [args...]
  local dir=$1
  shift
  HOME="$dir/home" \
    FM_TASK_SYNC_NO_USER_PATH=1 \
    PATH="$dir/fakebin:$PATH" \
    TEST_LOG_DIR="$dir/logs" \
    FM_HOME="$dir/home" \
    FM_TASK_SYNC_FLEET_SYNC_BIN="$dir/fakebin/fleet-sync-spy" \
    bash "$SYNC_BIN" "$@"
}

test_help_renders_header_without_side_effects() {
  local dir out
  dir=$(make_case_home help-case)
  [ -x "$SYNC_BIN" ] || fail "bin/fm-task-sync.sh must exist and be executable"
  out=$(run_sync "$dir" --help)
  assert_contains "$out" "--apply" "help must document --apply"
  assert_contains "$out" "--dry-run" "help must document --dry-run"
  assert_contains "$out" "--project" "help must document --project"
  assert_contains "$out" "--initiative" "help must document --initiative"
  assert_contains "$out" "--limit" "help must document --limit"
  assert_contains "$out" "--inbox-note" "help must document --inbox-note"
  assert_contains "$out" "--json" "help must document --json"
  assert_contains "$out" "last-sync.json" "help must document state/paperclip-sync/last-sync.json"
  [ ! -e "$dir/home/state/paperclip-sync/last-sync.json" ] \
    || fail "--help must not create state/paperclip-sync/last-sync.json"
  pass "fm-task-sync: --help documents flags and state contract without side effects"
}

test_refuses_non_adi0_coding_host() {
  local dir err rc
  dir=$(make_case_home host-refusal)
  for forbidden_host in adi4 adi5; do
    rc=0
    err=$(FM_CODING_HOST="$forbidden_host" run_sync "$dir" --apply 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "FM_CODING_HOST=$forbidden_host must fail closed"
    assert_contains "$err" "$forbidden_host" "refusal must name forbidden host $forbidden_host"
    assert_contains "$err" "adi0" "refusal must state adi0-only coding boundary"
  done
  [ ! -e "$dir/logs/tasks-axi.calls" ] || fail "host refusal must not mutate backlog"
  pass "fm-task-sync: refuses execution when FM_CODING_HOST is adi4 or adi5"
}

test_dry_run_computes_plan_without_mutating_backlog_or_clones() {
  local dir out sentinel
  dir=$(make_case_home dry-run)
  out=$(run_sync "$dir" --dry-run --json)
  python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["mode"] == "dry-run", doc
assert doc["codingHost"] == "adi0", doc
planned_ids = [item["identifier"] for item in doc["readyQueue"]]
assert "CYB-501" in planned_ids and "CYB-502" in planned_ids, planned_ids
assert all(not i.startswith("OCD-") for i in planned_ids), f"OCD item leaked into readyQueue: {planned_ids}"
fenced_text = json.dumps(doc["fenced"])
assert "OCD-498" in fenced_text and "OCD-503" in fenced_text, fenced_text
assert doc["backlogAdded"] == [], f"dry-run must not add backlog items: {doc['backlogAdded']}"
assert doc["fleetSyncedRepos"] == [], f"dry-run must not run fleet-sync: {doc['fleetSyncedRepos']}"
PY
  [ ! -e "$dir/logs/tasks-axi.calls" ] || fail "--dry-run must not call tasks-axi add"
  [ ! -e "$dir/logs/fleet-sync.calls" ] || fail "--dry-run must not call fm-fleet-sync.sh"
  [ ! -e "$dir/home/state/paperclip-sync/last-sync.json" ] || fail "--dry-run must not write last-sync.json"
  sentinel=$(cat "$dir/home/projects/pentforge/README.md")
  assert_equals "unchanged-project-sentinel" "$sentinel" "Hard Rule 1: project files must stay untouched"
  pass "fm-task-sync: --dry-run reports full reconciliation plan with zero mutations"
}

test_apply_idempotent_backlog_and_merged_pr_fleet_sync() {
  local dir out1 out2 backlog_content cyb501_count fleet_calls
  dir=$(make_case_home apply-idempotent)

  out1=$(run_sync "$dir" --apply --json)
  python3 - "$out1" "$dir/home/state/paperclip-sync/last-sync.json" <<'PY'
import json, pathlib, sys
doc = json.loads(sys.argv[1])
saved = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert doc["mode"] == "apply"
assert saved["schema"] == "fm-task-sync.v1"
added = [x["identifier"] for x in doc["backlogAdded"]]
assert added == ["CYB-501", "CYB-502"], f"expected CYB-501 and CYB-502 added, got {added}"
assert doc["fleetSyncedRepos"] == ["pentforge"], f"expected only cloned pentforge synced, got {doc['fleetSyncedRepos']}"
fenced_blob = json.dumps(doc["fenced"])
assert "OCD-498" in fenced_blob and "OCD-503" in fenced_blob, fenced_blob
PY

  backlog_content=$(cat "$dir/home/data/backlog.md")
  assert_contains "$backlog_content" "[CYB-501]" "backlog must include [CYB-501]"
  assert_contains "$backlog_content" "[CYB-502]" "backlog must include [CYB-502]"
  assert_not_contains "$backlog_content" "OCD-498" "fenced OCD-498 must never enter adi0 backlog"
  assert_not_contains "$backlog_content" "OCD-503" "fenced OCD-503 must never enter adi0 backlog"
  if grep -q -- '--start' "$dir/logs/tasks-axi.calls"; then
    fail "fm-task-sync must NEVER pass --start to fm-tasks-axi.sh"
  fi

  fleet_calls=$(cat "$dir/logs/fleet-sync.calls")
  assert_equals "pentforge" "$fleet_calls" "only cloned project pentforge must be passed to fm-fleet-sync.sh"

  # Second --apply must be 100% idempotent (0 duplicates added).
  out2=$(run_sync "$dir" --apply --json)
  python3 - "$out2" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["backlogAdded"] == [], f"second sync must add 0 duplicate items, got {doc['backlogAdded']}"
PY
  cyb501_count=$(grep -c '\[CYB-501\]' "$dir/home/data/backlog.md")
  assert_equals "1" "$cyb501_count" "[CYB-501] must appear exactly once after repeated syncs"
  pass "fm-task-sync: --apply queues [CYB-xxx] idempotently without --start, fences OCD-*, and syncs merged clones"
}

test_limit_and_project_filter_respected() {
  local dir out calls
  dir=$(make_case_home limit-filter)
  out=$(run_sync "$dir" --apply --project pentforge --initiative I-4 --limit 1 --json)
  python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
added = [x["identifier"] for x in doc["backlogAdded"]]
assert added == ["CYB-501"], f"expected --limit 1 to queue only CYB-501, got {added}"
PY
  calls=$(cat "$dir/logs/paperclip-cyb.calls")
  assert_contains "$calls" "--project pentforge" "paperclip-cyb must receive --project filter"
  assert_contains "$calls" "--initiative I-4" "paperclip-cyb must receive --initiative filter"
  pass "fm-task-sync: honors --project, --initiative, and --limit"
}

test_paperclip_unavailable_graceful_fallback() {
  local dir out
  dir=$(make_case_home fallback-case)
  out=$(PAPERCLIP_STUB_FAIL=1 run_sync "$dir" --apply --json)
  python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["paperclipStatus"] == "unavailable", doc
warnings_blob = "\n".join(doc["warnings"])
assert "PAPERCLIP_UNAVAILABLE:" in warnings_blob, warnings_blob
added = [x["identifier"] for x in doc["backlogAdded"]]
assert "CYB-610" in added, f"fallback cyb-linear-sync task CYB-610 must still sync: {added}"
fenced_blob = json.dumps(doc["fenced"])
assert "OCD-498" in fenced_blob, f"fallback rf-mac-sync custody fence must remain enforced: {fenced_blob}"
PY
  pass "fm-task-sync: falls back gracefully to cyb-linear-sync + rf-mac-sync with PAPERCLIP_UNAVAILABLE warning"
}

test_lock_contention_safety() {
  local dir holder_pid err rc
  dir=$(make_case_home lock-case)
  mkdir -p "$dir/home/state/paperclip-sync"

  # Hold .sync.lock in a live background process using fm-wake-lib's lock primitive.
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2"
    touch "$3"
    sleep 5
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/home/state/paperclip-sync/.sync.lock" "$dir/lock-held" &
  holder_pid=$!
  while [ ! -e "$dir/lock-held" ]; do sleep 0.05; done

  rc=0
  err=$(FM_TASK_SYNC_LOCK_WAIT_SECS=1 run_sync "$dir" --apply 2>&1) || rc=$?
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  rm -rf "$dir/home/state/paperclip-sync/.sync.lock"

  [ "$rc" -ne 0 ] || fail "concurrent sync must refuse when .sync.lock is held by a live process"
  assert_contains "$err" "sync" "contention diagnostic must mention active sync"
  [ ! -e "$dir/logs/tasks-axi.calls" ] || fail "contended sync must not mutate backlog"
  pass "fm-task-sync: .sync.lock prevents concurrent overlapping sync runs"
}

test_inbox_note_reply_and_ack_roundtrip() {
  local dir note_json note_id out receipts
  dir=$(make_case_home inbox-case)

  note_json=$(FM_HOME="$dir/home" bash "$INBOX_BIN" note --request-id req-sync-captain-1 --json -- "sync all development tasks" || true)
  note_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$note_json")

  out=$(run_sync "$dir" --apply --inbox-note "$note_id")
  assert_contains "$out" "Development tasks synchronized" "digest must report synchronized outcome"
  assert_contains "$out" "https://github.com/adibirzu/pentforge/pull/42" "digest must include full PR URL"
  assert_contains "$out" "adrians-macbook-pro" "digest must surface fenced adrians-macbook-pro custody"

  receipts=$(FM_HOME="$dir/home" bash "$INBOX_BIN" receipts --all-handled --all-replies)
  python3 - "$receipts" "$note_id" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
note_id = sys.argv[2]
assert doc["pending"] == [], f"handled note must be drained from pending: {doc['pending']}"
handled_ids = [n["id"] for n in doc["handled"]]
assert note_id in handled_ids, f"note {note_id} must be acknowledged in handled: {handled_ids}"
assert len(doc["replies"]) == 1, f"expected 1 durable reply, got {doc['replies']}"
reply_body = doc["replies"][0]["body"]
assert "Development tasks synchronized" in reply_body, reply_body
assert "https://github.com/adibirzu/pentforge/pull/42" in reply_body, reply_body
for forbidden in (".sync.lock", "wake-queue", "fail-closed", "fails closed", ".meta", "worktree"):
    assert forbidden not in reply_body, f"digest leaked internal jargon {forbidden!r}: {reply_body}"
PY
  pass "fm-task-sync: --inbox-note publishes outcome reply and acknowledges note"
}

test_fm_sync_entrypoint_routing() {
  local dir help_out direct_out live_out
  dir=$(make_case_home entry-case)
  [ -x "$ENTRY_BIN" ] || fail "bin/fm-sync.sh must exist and be executable"

  help_out=$(FM_HOME="$dir/home" bash "$ENTRY_BIN" --help)
  assert_contains "$help_out" "--direct" "fm-sync --help must document --direct"

  # Case A: No live FirstMate session holds the lock -> runs fm-task-sync.sh --apply directly.
  direct_out=$(
    HOME="$dir/home" \
    FM_TASK_SYNC_NO_USER_PATH=1 \
    PATH="$dir/fakebin:$PATH" \
    TEST_LOG_DIR="$dir/logs" \
    FM_HOME="$dir/home" \
    FM_SYNC_TASK_SYNC_BIN="$SYNC_BIN" \
    FM_TASK_SYNC_FLEET_SYNC_BIN="$dir/fakebin/fleet-sync-spy" \
    bash "$ENTRY_BIN"
  )
  assert_contains "$direct_out" "Development tasks synchronized" "offline primary must run direct sync and print digest"
  [ -f "$dir/home/state/paperclip-sync/last-sync.json" ] || fail "offline primary direct path must write last-sync.json"

  # Case B: Live FirstMate primary with healthy wake consumer -> queues idempotent inbox note!
  cat > "$dir/fakebin/inbox-live-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"
shift || true
case "$sub" in
  ready)
    printf '{"schema":"fm-primary-ready.v1","can_receive":true,"lock":{"state":"held","pid":12345,"live_harness":true},"wake_consumer":{"state":"healthy","reason":"supervised","beacon_age_seconds":2},"posture":{"state":"present"}}\n'
    ;;
  note)
    printf '%s\n' "note $*" >> "${TEST_LOG_DIR:?}/inbox-live.calls"
    printf '{"schema":"fm-inbox-note.v1","outcome":"created","id":"1700000000-abcdef","woken":true}\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$dir/fakebin/inbox-live-stub"

  live_out=$(
    PATH="$dir/fakebin:$PATH" \
    TEST_LOG_DIR="$dir/logs" \
    FM_HOME="$dir/home" \
    FM_SYNC_INBOX_BIN="$dir/fakebin/inbox-live-stub" \
    FM_SYNC_TASK_SYNC_BIN="$SYNC_BIN" \
    bash "$ENTRY_BIN" "sync pentforge tasks and start top 2"
  )
  assert_contains "$live_out" "1700000000-abcdef" "live primary path must report queued inbox note id"
  assert_contains "$(cat "$dir/logs/inbox-live.calls")" "--request-id" "live primary path must pass idempotent --request-id"
  assert_contains "$(cat "$dir/logs/inbox-live.calls")" "sync pentforge tasks and start top 2" "live primary path must forward user message"

  # Case C: --direct forces direct sync even when primary is live!
  rm -f "$dir/logs/inbox-live.calls"
  direct_out=$(
    HOME="$dir/home" \
    FM_TASK_SYNC_NO_USER_PATH=1 \
    PATH="$dir/fakebin:$PATH" \
    TEST_LOG_DIR="$dir/logs" \
    FM_HOME="$dir/home" \
    FM_SYNC_INBOX_BIN="$dir/fakebin/inbox-live-stub" \
    FM_SYNC_TASK_SYNC_BIN="$SYNC_BIN" \
    FM_TASK_SYNC_FLEET_SYNC_BIN="$dir/fakebin/fleet-sync-spy" \
    bash "$ENTRY_BIN" --direct
  )
  assert_contains "$direct_out" "Development tasks synchronized" "--direct must bypass inbox note and run sync immediately"
  [ ! -e "$dir/logs/inbox-live.calls" ] || fail "--direct must not enqueue an inbox note"
  pass "fm-sync: routes to live FirstMate inbox when ready and falls back to direct sync when unlocked or --direct"
}

test_paperclip_cyb_sync_plan_contract_compatibility() {
  local dir out
  dir=$(make_case_home sync-plan-contract)
  cat > "$dir/fakebin/paperclip-cyb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"success":true,"data":{"generatedAt":"2026-11-12T07:00:00Z","readyQueue":[{"linearIdentifier":"CYB-701","title":"[CYB-701] Tighten Pentforge token rotation","priority":1,"paperclipPriority":"critical","orgSlug":"cyb-02-pentforge-sec","projectSlug":"pentforge","primaryRepo":"adibirzu/pentforge","linearUrl":"https://linear.app/cyber-sec/issue/CYB-701"}],"fencedItems":[{"linearIdentifier":"OCD-504","orgSlug":"cyb-01-fleet-harness","projectSlug":"reviewforge","fencedBy":"adrians-macbook-pro","reason":"Sol 6.1 active custody"}],"fleetSyncRepos":["adibirzu/pentforge"],"mutations":[{"target":"paperclip","action":"update","linearIdentifier":"CYB-699","linearIssueUuid":"uuid-699","orgSlug":"cyb-02-pentforge-sec","targetStatus":"in_review","githubPrUrl":"https://github.com/adibirzu/pentforge/pull/77","ciState":"SUCCESS","contentHash":"abc123","reason":"Open PR"}]}}
JSON
EOF
  chmod +x "$dir/fakebin/paperclip-cyb"

  out=$(run_sync "$dir" --apply --json)
  python3 - "$out" "$dir/home/data/backlog.md" <<'PY'
import json, pathlib, sys
doc = json.loads(sys.argv[1])
backlog = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert [x["identifier"] for x in doc["backlogAdded"]] == ["CYB-701"], doc["backlogAdded"]
assert doc["backlogAdded"][0]["repo"] == "pentforge", doc["backlogAdded"]
assert "[CYB-701] [CYB-701]" not in backlog, f"must not double-prefix [CYB-701]: {backlog}"
assert "[CYB-701] Tighten Pentforge token rotation" in backlog, backlog
assert doc["fleetSyncedRepos"] == ["pentforge"], doc["fleetSyncedRepos"]
assert any(f["identifier"] == "OCD-504" for f in doc["fenced"]), doc["fenced"]
assert any(p["url"] == "https://github.com/adibirzu/pentforge/pull/77" for p in doc["openPrs"]), doc["openPrs"]
PY
  pass "fm-task-sync: natively parses paperclip-cyb SyncPlan (primaryRepo, fencedItems, fleetSyncRepos, mutations)"
}

test_real_hostname_and_execution_target_fencing() {
  local dir rc err out
  dir=$(make_case_home real-host-fence)
  printf '{"blockedHosts":["custom-ctrl-node.example.com"]}\n' > "$dir/home/config/task-sync.json"
  for bad_real in adi4 adi5 srv2083966 srv2121823 adihost4 adihost5 custom-ctrl-node custom-ctrl-node.example.com; do
    set +e
    err=$(
      env -u FM_CODING_HOST \
        HOME="$dir/home" \
        FM_TASK_SYNC_NO_USER_PATH=1 \
        PATH="$dir/fakebin:$PATH" \
        FM_REAL_HOST_OVERRIDE="$bad_real" \
        FM_HOME="$dir/home" \
        bash "$SYNC_BIN" --dry-run 2>&1
    )
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "expected exit 2 on real host $bad_real even with FM_CODING_HOST unset, got $rc"
    assert_contains "$err" "refusing task sync" "real-host refusal must explain host guard"
  done

  cat > "$dir/fakebin/paperclip-cyb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"success":true,"data":{"readyQueue":[{"linearIdentifier":"CYB-801","title":"Fenced to MacBook Pro","priority":1,"projectSlug":"reviewforge","primaryRepo":"adibirzu/reviewforge","executionTarget":"adrians-macbook-pro"},{"linearIdentifier":"CYB-802","title":"Eligible on adi0","priority":2,"projectSlug":"pentforge","primaryRepo":"adibirzu/pentforge","executionTarget":"adi0"}]}}
JSON
EOF
  chmod +x "$dir/fakebin/paperclip-cyb"

  out=$(run_sync "$dir" --apply --json)
  python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert [x["identifier"] for x in doc["readyQueue"]] == ["CYB-802"], doc["readyQueue"]
assert any(f["identifier"] == "CYB-801" for f in doc["fenced"]), doc["fenced"]
PY
  pass "fm-task-sync: enforces real-hostname (srv2083966/srv2121823/adi4/adi5) guard and fences non-adi0 executionTarget"
}

test_inbox_retry_idempotency_and_dry_run_guard() {
  local dir note_out note_id rc err
  dir=$(make_case_home inbox-retry)
  note_out=$(FM_HOME="$dir/home" bash "$ROOT/bin/fm-inbox.sh" note --request-id req-retry-1 --json -- "sync all development tasks")
  note_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$note_out")

  set +e
  err=$(run_sync "$dir" --dry-run --inbox-note "$note_id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--inbox-note under --dry-run must exit 2, got $rc"
  assert_contains "$err" "--apply" "dry-run --inbox-note refusal must require --apply"

  # Simulate interrupted previous run: reply already recorded in state/inbox/.replies/<id>, note still pending!
  printf 'Prior reply\n' | FM_HOME="$dir/home" bash "$ROOT/bin/fm-inbox.sh" reply "$note_id" - >/dev/null
  [ -f "$dir/home/state/inbox/.replies/$note_id" ] || fail "expected reply file under state/inbox/.replies/"

  run_sync "$dir" --apply --inbox-note "$note_id" >/dev/null
  status_out=$(FM_HOME="$dir/home" bash "$INBOX_BIN" receipts --all-handled --all-replies)
  python3 - "$status_out" "$note_id" <<'PY'
import json, sys
doc, nid = json.loads(sys.argv[1]), sys.argv[2]
assert doc["pending"] == [], f"retry must drain/ack pending note even when reply pre-existed: {doc['pending']}"
assert any(h["id"] == nid for h in doc["handled"]), doc["handled"]
assert len(doc["replies"]) == 1, doc["replies"]
PY
  pass "fm-task-sync: refuses --inbox-note on --dry-run and completes ack cleanly when reply already exists"
}

test_repo_traversal_and_substring_filter_hardening() {
  local dir out
  dir=$(make_case_home repo-hardening)
  if grep -Eq '/Users/' "$ENTRY_BIN" "$SYNC_BIN"; then
    fail "tracked scripts must never embed personal /Users/ paths"
  fi
  mkdir -p "$dir/home/projects/pentforge-compliance-watch"

  cat > "$dir/fakebin/paperclip-cyb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{
  "success": true,
  "data": {
    "readyQueue": [
      {
        "linearIdentifier": "CYB-810",
        "title": "Exact pentforge match",
        "priority": 1,
        "projectSlug": "pentforge",
        "primaryRepo": "adibirzu/pentforge"
      },
      {
        "linearIdentifier": "CYB-811",
        "title": "Substring neighbor must not match --project pentforge",
        "priority": 1,
        "projectSlug": "pentforge-compliance-watch",
        "primaryRepo": "adibirzu/pentforge-compliance-watch"
      },
      {
        "linearIdentifier": "CYB-812",
        "title": "Unsafe traversal repo must be rejected",
        "priority": 1,
        "projectSlug": "pentforge",
        "primaryRepo": "adibirzu/.."
      }
    ],
    "mergedPrs": [
      {"identifier": "CYB-800", "repo": "adibirzu/..", "number": 1, "url": "https://example.invalid/pr/1"},
      {"identifier": "CYB-801", "repo": "", "number": 2, "url": "https://example.invalid/pr/2"},
      {"identifier": "CYB-802", "repo": ".", "number": 3, "url": "https://example.invalid/pr/3"}
    ],
    "fleetSyncRepos": ["adibirzu/..", "", "."]
  }
}
JSON
EOF
  chmod +x "$dir/fakebin/paperclip-cyb"

  out=$(run_sync "$dir" --apply --project pentforge --json)
  python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert [x["identifier"] for x in doc["readyQueue"]] == ["CYB-810"], doc["readyQueue"]
assert doc["fleetSyncedRepos"] == [], f"unsafe repo basenames must never run fleet-sync: {doc['fleetSyncedRepos']}"
PY
  [ ! -e "$dir/logs/fleet-sync.calls" ] || fail "fleet-sync must not be called for .., ., or empty repo"
  pass "fm-task-sync: blocks .. / empty repo traversal, enforces exact --project slug match, and keeps tracked scripts path-clean"
}

test_linear_fallback_excludes_claimed_states_and_fences_custody() {
  local dir out
  dir=$(make_case_home fallback-states)
  rm -f "$dir/fakebin/paperclip-cyb"
  cat > "$dir/fakebin/cyb-linear-sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{
  "success": true,
  "data": {
    "repos": [
      {
        "repo": "adibirzu/pentforge",
        "projectName": "Pentforge",
        "matched": [
          {"linearIdentifier": "CYB-820", "ghTitle": "Ready todo item", "state": "Todo"},
          {"linearIdentifier": "CYB-821", "ghTitle": "Already claimed in progress", "state": "In Progress"},
          {"linearIdentifier": "CYB-822", "ghTitle": "Blocked item", "state": "Blocked"},
          {"linearIdentifier": "CYB-823", "ghTitle": "Unscheduled backlog item", "state": "Backlog"},
          {"linearIdentifier": "CYB-824", "ghTitle": "Duplicate item", "state": "Duplicate"},
          {"linearIdentifier": "CYB-825", "ghTitle": "MacBook branch custody", "state": "Todo", "branchName": "wip/adrians-macbook-pro/fix"}
        ]
      }
    ]
  }
}
JSON
EOF
  chmod +x "$dir/fakebin/cyb-linear-sync"

  out=$(HOME="$dir/home" FM_TASK_SYNC_NO_USER_PATH=1 PATH="$dir/fakebin:/usr/bin:/bin" TEST_LOG_DIR="$dir/logs" FM_HOME="$dir/home" FM_TASK_SYNC_FLEET_SYNC_BIN="$dir/fakebin/fleet-sync-spy" bash "$SYNC_BIN" --apply --json)
  python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert [x["identifier"] for x in doc["readyQueue"]] == ["CYB-820"], doc["readyQueue"]
assert any(f["identifier"] == "CYB-825" for f in doc["fenced"]), doc["fenced"]
PY

  # Total outage: both paperclip-cyb and cyb-linear-sync unavailable -> honest degradation message!
  rm -f "$dir/fakebin/cyb-linear-sync"
  out=$(HOME="$dir/home" FM_TASK_SYNC_NO_USER_PATH=1 PATH="$dir/fakebin:/usr/bin:/bin" TEST_LOG_DIR="$dir/logs" FM_HOME="$dir/home" FM_TASK_SYNC_FLEET_SYNC_BIN="$dir/fakebin/fleet-sync-spy" bash "$SYNC_BIN" --dry-run --json)
  python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["fallbackStatus"] == "failed", doc
assert "reconciled directly" not in doc["captainDigest"], doc["captainDigest"]
assert "degraded" in doc["captainDigest"] or "unreachable" in doc["captainDigest"], doc["captainDigest"]
PY
  pass "fm-task-sync: Linear fallback excludes claimed/blocked/backlog states, fences custody branches, and reports dual-outage honestly"
}

test_custom_tasks_toml_archive_and_partial_warning_digest() {
  local dir out digest
  dir=$(make_case_home archive-and-warnings)
  cat > "$dir/home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/old-done.md"
done_keep = 10
TOML
  printf -- '- [x] cyb-501 - [CYB-501] Already archived task (repo: pentforge) (kind: ship)\n' > "$dir/home/data/old-done.md"
  mkdir -p "$dir/home/projects/--help"
  cat > "$dir/fakebin/paperclip-cyb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"success":true,"data":{"readyQueue":[{"linearIdentifier":"CYB-501","title":"Archived item must not requeue","priority":1,"projectSlug":"pentforge","primaryRepo":"adibirzu/pentforge"},{"linearIdentifier":"CYB-502","title":"Next unqueued item","priority":2,"projectSlug":"pentforge","primaryRepo":"adibirzu/pentforge"},{"linearIdentifier":"CYB-503","title":"Leading hyphen repo must reject","priority":2,"projectSlug":"pentforge","primaryRepo":"adibirzu/--help"}],"fleetSyncRepos":["adibirzu/--help"]}}
JSON
EOF
  chmod +x "$dir/fakebin/paperclip-cyb"

  out=$(run_sync "$dir" --dry-run --limit 1 --json)
  python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["counts"]["plannedBacklogAdds"] == 1, doc["counts"]
assert [x["identifier"] for x in doc["readyQueue"]] == ["CYB-501", "CYB-502"], doc["readyQueue"]
PY

  # Failing tasks-axi must surface "partially synchronized" and name CYB-502 in human digest!
  cat > "$dir/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$dir/fakebin/tasks-axi"
  digest=$(run_sync "$dir" --apply --limit 1)
  assert_contains "$digest" "partially synchronized" "add failure must mark digest partially synchronized"
  assert_contains "$digest" "CYB-502" "add failure must surface the failed CYB identifier in digest"
  [ ! -e "$dir/logs/fleet-sync.calls" ] || fail "leading-hyphen --help repo must never reach fleet-sync"
  pass "fm-task-sync: honors [markdown].archive in .tasks.toml, rejects -* repos, and surfaces add warnings in digest"
}

test_help_renders_header_without_side_effects
test_refuses_non_adi0_coding_host
test_dry_run_computes_plan_without_mutating_backlog_or_clones
test_apply_idempotent_backlog_and_merged_pr_fleet_sync
test_limit_and_project_filter_respected
test_paperclip_unavailable_graceful_fallback
test_lock_contention_safety
test_inbox_note_reply_and_ack_roundtrip
test_fm_sync_entrypoint_routing
test_paperclip_cyb_sync_plan_contract_compatibility
test_real_hostname_and_execution_target_fencing
test_inbox_retry_idempotency_and_dry_run_guard
test_repo_traversal_and_substring_filter_hardening
test_linear_fallback_excludes_claimed_states_and_fences_custody
test_custom_tasks_toml_archive_and_partial_warning_digest

printf 'ALL PASS: fm-task-sync\n'
