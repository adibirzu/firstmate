#!/usr/bin/env bash
# tests/fm-fleet-agents.test.sh - TDD unit & integration suite for:
#   1. bin/fm-agent-process-lib.sh harness identity detection (agy, grok,
#      opencode, codex, claude, cursor-agent, gemini, hermes + decoys)
#   2. bin/fm-fleet-agents cross-machine project-organized agent radar
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-agents-test.XXXXXX")"
trap 'rm -rf "$LAB"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Part 1: fm-agent-process-lib.sh classification & canonical harness identity
# ---------------------------------------------------------------------------
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"

assert_harness() {
  local label=$1 name=$2 argv0=$3 args=$4 expected_kind=$5
  local cls kind
  cls=$(fm_agent_process_classify "$name" "$argv0" "$args")
  [ "$cls" = "agent" ] || fail "$label: expected classify=agent, got '$cls'"
  kind=$(fm_agent_process_identify_harness "$name" "$argv0" "$args")
  [ "$kind" = "$expected_kind" ] || fail "$label: expected harness='$expected_kind', got '$kind'"
}

assert_not_agent() {
  local label=$1 name=$2 argv0=$3 args=$4 expected_cls=$5
  local cls kind
  cls=$(fm_agent_process_classify "$name" "$argv0" "$args")
  [ "$cls" = "$expected_cls" ] || fail "$label: expected classify=$expected_cls, got '$cls'"
  kind=$(fm_agent_process_identify_harness "$name" "$argv0" "$args" || true)
  [ -z "$kind" ] || fail "$label: expected empty harness kind, got '$kind'"
}

# Build Cursor symlink tree under a directory intentionally containing `/claude/`
# to prove Cursor structural matching beats parent-path component false matches.
mkdir -p "$LAB/claude/cursor-agent/versions/2026.08.11" "$LAB/claude/bin"
cat > "$LAB/claude/cursor-agent/versions/2026.08.11/cursor-agent" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$LAB/claude/cursor-agent/versions/2026.08.11/cursor-agent"
ln -s "$LAB/claude/cursor-agent/versions/2026.08.11/cursor-agent" "$LAB/claude/bin/agent"

assert_harness "agy bare binary" "agy" "agy" "agy --dangerously-skip-permissions" "agy"
assert_harness "agy full path" "/home/dev/.local/bin/agy" "agy" "agy --conversation 00000000" "agy"
assert_not_agent "agy decoy baggy" "baggy" "baggy" "baggy --run" "other"
assert_not_agent "agy decoy stagy" "stagy" "stagy" "stagy" "other"

assert_harness "grok cli" "grok" "grok" "grok --model grok-4" "grok"
assert_harness "grok-bot daemon" "node" "/opt/grok-bot/bin/grok-bot" "node /opt/grok-bot/bin/grok-bot" "grok"

assert_harness "opencode cli" "opencode" "/home/dev/.opencode/bin/opencode" "opencode -c" "opencode"
assert_harness "codex cli" "codex" "codex" "codex --full-auto" "codex"
assert_harness "claude versioned path" "2.1.220" "/home/dev/.local/share/claude/versions/2.1.220" "claude" "claude"
assert_harness "cursor-agent direct under claude parent dir" "node" "$LAB/claude/cursor-agent/versions/2026.08.11/cursor-agent" "node cursor-agent" "cursor-agent"
assert_harness "cursor-agent legacy agent symlink" "node" "$LAB/claude/bin/agent" "agent" "cursor-agent"
assert_not_agent "decoy generic agent binary" "agent" "/usr/local/bin/agent" "/usr/local/bin/agent" "other"

assert_harness "gemini node bundle" "MainThread" "/usr/local/bin/node" "node /home/dev/.local/bin/gemini -y" "gemini"
assert_not_agent "gemini mentioned only in prompt" "node" "/usr/local/bin/node" "node server.js gemini" "other"

assert_harness "hermes bare binary" "hermes" "/opt/hermes/venv/bin/hermes" "hermes chat" "hermes"
assert_not_agent "hermes decoy hermesd" "hermesd" "/usr/sbin/hermesd" "hermesd" "other"
assert_not_agent "hermes folder decoy python3" "python3" "/opt/hermes/venv/bin/python3" "python3 gateway.py" "other"
assert_not_agent "hermes folder decoy node" "node" "/opt/hermes/data/node" "node worker.js" "other"
assert_not_agent "idle zsh shell" "zsh" "-zsh" "-zsh" "shell"

pass "fm-agent-process-lib: classifies and identifies agy, grok, opencode, codex, claude, cursor-agent, gemini, hermes and rejects decoys"

# ---------------------------------------------------------------------------
# Part 2: bin/fm-fleet-agents multi-host discovery, null-safety, and filters
# ---------------------------------------------------------------------------
FM_TEST_HOME="$LAB/fm-home"
mkdir -p "$FM_TEST_HOME/state" "$FM_TEST_HOME/data" "$FM_TEST_HOME/config" "$LAB/mock-bin"

# Optional gitignored host alias map
cat > "$FM_TEST_HOME/config/fleet-host-aliases.json" <<'JSON'
{
  "box4-vps": "host4"
}
JSON

# FirstMate task meta matching a worktree on localHost ("workstation-a")
cat > "$FM_TEST_HOME/state/task-orca-radar.meta" <<'EOF'
id=task-orca-radar
worktree=/srv/workspaces/orca-axi/fleet-agent-radar
harness=agy
model=gemini-2.5-pro
status=running
EOF

# SecondMate registry with local + remote provisioned scopes
cat > "$FM_TEST_HOME/data/secondmates.md" <<'EOF'
# Secondmates

- fm-infra - Fleet infrastructure scope. (home: /srv/fm-infra/firstmate; scope: firstmate and orca-axi tooling; projects: firstmate, orca-axi; added 2026-08-02)
- app-remote - App overflow on host1. (host: host1; root: /home/dev/firstmate; home: /home/dev/.firstmate-app; scope: App suite; projects: alpha-web, beta-hr; added 2026-09-25)
- sec-remote - Security on host2 via Tailscale suffix. (host: host2-ts; root: /home/dev/firstmate; home: /home/dev/.firstmate-sec; scope: Security; projects: sentinel-ops; added 2026-10-15)
EOF

cat > "$LAB/mock-bin/orca-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "agents" ]; then
  cat <<'JSON'
{
  "agents": {
    "generatedAt": "2026-11-11T22:45:00.000Z",
    "localHost": "workstation-a",
    "totals": {
      "agents": 6,
      "working": 4,
      "bridged": 1,
      "idle": 1,
      "machinesOnline": 5,
      "machinesTotal": 5,
      "activeProjects": 5,
      "harnesses": { "agy": 2, "claude": 1, "codex": 1, "cursor-agent": 1, "unknown": 1 }
    },
    "machines": [
      { "host": "workstation-a", "reachable": true, "agentCount": 2, "workingCount": 2, "durationMs": 120 },
      { "host": "host1", "reachable": true, "agentCount": 1, "workingCount": 1, "durationMs": 310 },
      { "host": "host2", "reachable": true, "agentCount": 1, "workingCount": 1, "durationMs": 420 },
      { "host": "host3", "reachable": true, "agentCount": 1, "workingCount": 0, "durationMs": 280 },
      { "host": "box4-vps", "reachable": true, "agentCount": 1, "workingCount": 1, "durationMs": 390 }
    ],
    "items": [
      {
        "id": "workstation-a:57264",
        "host": "workstation-a",
        "pid": 57264,
        "ppid": 44241,
        "tty": "ttys000",
        "harness": "agy",
        "state": "bridged",
        "surface": "orca",
        "surfaces": ["terminal", "tmux", "herdr", "orca"],
        "cwd": "/srv/dev/firstmate",
        "project": "firstmate",
        "branch": "main",
        "linearIssue": null,
        "conversationId": "00000000-1111-2222-3333-444444444444"
      },
      {
        "id": "workstation-a:61001",
        "host": null,
        "pid": 61001,
        "ppid": 57264,
        "tty": "ttys004",
        "harness": "agy",
        "state": "working",
        "surface": "orca",
        "surfaces": ["orca"],
        "cwd": "/srv/workspaces/orca-axi/fleet-agent-radar",
        "project": "orca-axi",
        "worktreePath": "/srv/workspaces/orca-axi/fleet-agent-radar",
        "branch": "feat/fleet-agent-radar",
        "linearIssue": "PROJ-501",
        "conversationId": "11111111-2222-3333-4444-555555555555"
      },
      {
        "id": "host1:18420",
        "host": "host1",
        "pid": 18420,
        "harness": "codex",
        "state": "working",
        "surface": "tmux",
        "surfaces": ["tmux"],
        "cwd": "/home/dev/worktrees/alpha-web/feat-sso",
        "project": "alpha-web",
        "branch": "feat/proj-312-sso",
        "linearIssue": "PROJ-312"
      },
      {
        "id": "host2:9921",
        "host": "host2",
        "pid": 9921,
        "harness": "cursor-agent",
        "state": "working",
        "surface": "tmux",
        "surfaces": ["tmux"],
        "cwd": "/home/dev/sentinel-ops",
        "project": "sentinel-ops",
        "branch": "feat/engine"
      },
      {
        "id": "host3:4410",
        "host": "host3",
        "pid": 4410,
        "harness": null,
        "state": null,
        "surface": null,
        "surfaces": null,
        "cwd": null,
        "project": null,
        "branch": null
      },
      {
        "id": "host4:3102",
        "host": "box4-vps",
        "pid": 3102,
        "harness": "grok",
        "state": "working",
        "surface": "terminal",
        "surfaces": ["terminal"],
        "cwd": "/opt/grok-bot",
        "project": "grok-bot",
        "branch": "main"
      }
    ],
    "projects": []
  }
}
JSON
  exit 0
fi
exit 1
SH
chmod +x "$LAB/mock-bin/orca-axi"

cat > "$LAB/mock-bin/fm-fleet-herdr-collect.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"schema":"fm-fleet-herdr.v1","generated":1794437100,"host":"local","hosts":[{"host":"local","ok":true,"source":"local","sessions":[]}]}
JSON
SH
chmod +x "$LAB/mock-bin/fm-fleet-herdr-collect.sh"

CLI="$ROOT/bin/fm-fleet-agents"
[ -x "$CLI" ] || fail "bin/fm-fleet-agents must exist and be executable"

JSON_OUT=$(FM_HOME="$FM_TEST_HOME" \
  FM_ORCA_AXI_BIN="$LAB/mock-bin/orca-axi" \
  FM_HERDR_COLLECT_BIN="$LAB/mock-bin/fm-fleet-herdr-collect.sh" \
  "$CLI" --all-machines --json)

printf '%s' "$JSON_OUT" | jq -e '.schema == "fm-fleet-agents.v1" and .localHost == "workstation-a"' >/dev/null \
  || fail "JSON schema and dynamic localHost must be populated"
printf '%s' "$JSON_OUT" | jq -e '.summary.machinesOnline == 5 and .summary.totalAgents == 6' >/dev/null \
  || fail "summary counts must reflect 5 online machines and 6 agents"
printf '%s' "$JSON_OUT" | jq -e '.agents[] | select(.id == "workstation-a:61001") | .host == "workstation-a" and .matchedTaskId == "task-orca-radar" and .secondmate == "fm-infra"' >/dev/null \
  || fail "null-host local agent must default to localHost, match task-orca-radar, and resolve secondmate fm-infra"
printf '%s' "$JSON_OUT" | jq -e '.agents[] | select(.id == "host1:18420") | .secondmate == "app-remote"' >/dev/null \
  || fail "alpha-web agent on host1 must map to secondmate app-remote"
printf '%s' "$JSON_OUT" | jq -e '.agents[] | select(.id == "host2:9921") | .secondmate == "sec-remote"' >/dev/null \
  || fail "sentinel-ops agent on host2 must match host2-ts secondmate sec-remote"
printf '%s' "$JSON_OUT" | jq -e '.agents[] | select(.id == "host4:3102") | .host == "host4"' >/dev/null \
  || fail "box4-vps must normalize to host4 via config/fleet-host-aliases.json"
printf '%s' "$JSON_OUT" | jq -e '.agents[] | select(.id == "host3:4410") | .harness == "unknown" and .state == "idle" and .project == "unassigned"' >/dev/null \
  || fail "null fields must coerce safely to unknown/idle/unassigned"
pass "fm-fleet-agents: --json merges orca-axi fleet, dynamic localHost task metas, SecondMate scopes, aliases, and null-safe defaults"

# Filter flags: --host, --active-only, --project, --harness cursor
FILTERED=$(FM_HOME="$FM_TEST_HOME" \
  FM_ORCA_AXI_BIN="$LAB/mock-bin/orca-axi" \
  FM_HERDR_COLLECT_BIN="$LAB/mock-bin/fm-fleet-herdr-collect.sh" \
  "$CLI" --all-machines --active-only --host host1 --json)
printf '%s' "$FILTERED" | jq -e '(.agents | length) == 1 and .agents[0].project == "alpha-web" and .summary.machinesTotal == 1' >/dev/null \
  || fail "--active-only --host host1 must filter both agents and machine summary to host1"

CURSOR_FILTER=$(FM_HOME="$FM_TEST_HOME" \
  FM_ORCA_AXI_BIN="$LAB/mock-bin/orca-axi" \
  FM_HERDR_COLLECT_BIN="$LAB/mock-bin/fm-fleet-herdr-collect.sh" \
  "$CLI" --all-machines --harness cursor --project sentinel --json)
printf '%s' "$CURSOR_FILTER" | jq -e '(.agents | length) == 1 and .agents[0].harness == "cursor-agent"' >/dev/null \
  || fail "--harness cursor --project sentinel must match cursor-agent on sentinel-ops"

ACTIVE_ONLY=$(FM_HOME="$FM_TEST_HOME" \
  FM_ORCA_AXI_BIN="$LAB/mock-bin/orca-axi" \
  FM_HERDR_COLLECT_BIN="$LAB/mock-bin/fm-fleet-herdr-collect.sh" \
  "$CLI" --all-machines --active-only --json)
printf '%s' "$ACTIVE_ONLY" | jq -e '(.agents | length) == 5' >/dev/null \
  || fail "--active-only must exclude idle agent and keep 5 working/bridged agents"
pass "fm-fleet-agents: --host, --project, --harness cursor, and --active-only filters work accurately"

# Human-readable project-grouped output (must handle null fields without crashing)
HUMAN_OUT=$(FM_HOME="$FM_TEST_HOME" \
  FM_ORCA_AXI_BIN="$LAB/mock-bin/orca-axi" \
  FM_HERDR_COLLECT_BIN="$LAB/mock-bin/fm-fleet-herdr-collect.sh" \
  "$CLI" --all-machines)
printf '%s\n' "$HUMAN_OUT" | grep -Fq "Project: orca-axi [secondmate: fm-infra] [issues: PROJ-501]" \
  || fail "human output must render exact project header with secondmate and issue badges"
printf '%s\n' "$HUMAN_OUT" | grep -Fq "Project: alpha-web [secondmate: app-remote] [issues: PROJ-312]" \
  || fail "human output must render remote project header with secondmate badge"
pass "fm-fleet-agents: human output renders project-organized fleet table cleanly"

# Invalid flag rejection must exit with status 2
rc=0
FM_HOME="$FM_TEST_HOME" "$CLI" --bogus-flag >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown flag must exit 2, got $rc"
pass "fm-fleet-agents: rejects unknown flags with exit status 2"
