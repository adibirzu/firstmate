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

# Positive classifications + exact harness kind
assert_harness() {
  local label=$1 name=$2 argv0=$3 args=$4 expected_kind=$5
  local cls kind
  cls=$(fm_agent_process_classify "$name" "$argv0" "$args")
  [ "$cls" = "agent" ] || fail "$label: expected classify=agent, got '$cls'"
  kind=$(fm_agent_process_identify_harness "$name" "$argv0" "$args")
  [ "$kind" = "$expected_kind" ] || fail "$label: expected harness='$expected_kind', got '$kind'"
}

# Negative decoy checks (must NOT classify as agent)
assert_not_agent() {
  local label=$1 name=$2 argv0=$3 args=$4 expected_cls=$5
  local cls kind
  cls=$(fm_agent_process_classify "$name" "$argv0" "$args")
  [ "$cls" = "$expected_cls" ] || fail "$label: expected classify=$expected_cls, got '$cls'"
  kind=$(fm_agent_process_identify_harness "$name" "$argv0" "$args" || true)
  [ -z "$kind" ] || fail "$label: expected empty harness kind, got '$kind'"
}

# Setup structural Cursor symlink tree in LAB for deterministic testing
mkdir -p "$LAB/cursor-agent/versions/2026.08.11" "$LAB/bin"
cat > "$LAB/cursor-agent/versions/2026.08.11/cursor-agent" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$LAB/cursor-agent/versions/2026.08.11/cursor-agent"
ln -s "$LAB/cursor-agent/versions/2026.08.11/cursor-agent" "$LAB/bin/agent"

assert_harness "agy bare binary" "agy" "agy" "agy --dangerously-skip-permissions" "agy"
assert_harness "agy full path" "/Users/adrianb/.local/bin/agy" "agy" "agy --conversation bff46a10" "agy"
assert_not_agent "agy decoy baggy" "baggy" "baggy" "baggy --run" "other"
assert_not_agent "agy decoy stagy" "stagy" "stagy" "stagy" "other"

assert_harness "grok cli" "grok" "grok" "grok --model grok-4" "grok"
assert_harness "grok-bot daemon" "node" "/opt/grok-bot/bin/grok-bot" "node /opt/grok-bot/bin/grok-bot" "grok"

assert_harness "opencode cli" "opencode" "/Users/adrianb/.opencode/bin/opencode" "opencode -c" "opencode"
assert_harness "codex cli" "codex" "codex" "codex --full-auto" "codex"
assert_harness "claude versioned path" "2.1.220" "/Users/adrianb/.local/share/claude/versions/2.1.220" "claude" "claude"
assert_harness "cursor-agent direct" "node" "$LAB/cursor-agent/versions/2026.08.11/cursor-agent" "node cursor-agent" "cursor-agent"
assert_harness "cursor-agent legacy agent symlink" "node" "$LAB/bin/agent" "agent" "cursor-agent"
assert_not_agent "decoy generic agent binary" "agent" "/usr/local/bin/agent" "/usr/local/bin/agent" "other"

assert_harness "gemini node bundle" "MainThread" "/usr/local/bin/node" "node /Users/adrianb/.local/bin/gemini -y" "gemini"
assert_not_agent "gemini mentioned only in prompt" "node" "/usr/local/bin/node" "node server.js gemini" "other"

assert_harness "hermes bare binary" "hermes" "/opt/hermes/venv/bin/hermes" "hermes chat" "hermes"
assert_not_agent "hermes decoy hermesd" "hermesd" "/usr/sbin/hermesd" "hermesd" "other"
assert_not_agent "idle zsh shell" "zsh" "-zsh" "-zsh" "shell"

pass "fm-agent-process-lib: classifies and identifies agy, grok, opencode, codex, claude, cursor-agent, gemini, hermes and rejects decoys"

# ---------------------------------------------------------------------------
# Part 2: bin/fm-fleet-agents integration across adi0, adi1, adi2, macmini, adi4
# ---------------------------------------------------------------------------
FM_TEST_HOME="$LAB/fm-home"
mkdir -p "$FM_TEST_HOME/state" "$FM_TEST_HOME/data" "$LAB/mock-bin"

# Create a FirstMate task meta matching a worktree on adi0
cat > "$FM_TEST_HOME/state/task-orca-radar.meta" <<'EOF'
id=task-orca-radar
worktree=/Users/adrianb/orca/workspaces/orca-axi/fleet-agent-radar
harness=agy
model=gemini-2.5-pro
status=running
EOF

# Create a SecondMate registry with local + remote captains
cat > "$FM_TEST_HOME/data/secondmates.md" <<'EOF'
# Secondmates

- fm-infra - Fleet infrastructure domain. (home: /Volumes/ExternalNVME/fm-infra/firstmate; scope: firstmate and orca-axi tooling; projects: firstmate, orca-axi; added 2026-08-02)
- pf-remote - Pentforge overflow on adi1. (host: adi1; root: /home/adi/GitHub/firstmate; home: /home/adi/.firstmate-pf; scope: Pentforge; projects: pentforge.app, mosaichr; added 2026-09-25)
- aetherops-remote - AetherOps on adi2. (host: adi2-ts; root: /home/adi/firstmate; home: /home/adi/.firstmate-aetherops; scope: AetherOps; projects: aetherops; added 2026-10-15)
EOF

# Mock orca-axi returning cross-machine fleet JSON across all 5 machines
cat > "$LAB/mock-bin/orca-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "agents" ]; then
  cat <<'JSON'
{
  "agents": {
    "generatedAt": "2026-11-11T22:45:00.000Z",
    "localHost": "adi0",
    "totals": {
      "agents": 6,
      "working": 4,
      "bridged": 1,
      "idle": 1,
      "machinesOnline": 5,
      "machinesTotal": 5,
      "activeProjects": 5,
      "harnesses": { "agy": 2, "claude": 1, "codex": 1, "grok": 1, "opencode": 1 }
    },
    "machines": [
      { "host": "adi0", "reachable": true, "agentCount": 2, "workingCount": 2, "durationMs": 120 },
      { "host": "adi1", "reachable": true, "agentCount": 1, "workingCount": 1, "durationMs": 310 },
      { "host": "adi2", "reachable": true, "agentCount": 1, "workingCount": 1, "durationMs": 420 },
      { "host": "macmini", "reachable": true, "agentCount": 1, "workingCount": 0, "durationMs": 280 },
      { "host": "adi4", "reachable": true, "agentCount": 1, "workingCount": 1, "durationMs": 390 }
    ],
    "items": [
    {
      "id": "adi0:57264",
      "host": "adi0",
      "pid": 57264,
      "ppid": 44241,
      "tty": "ttys000",
      "harness": "agy",
      "state": "bridged",
      "surface": "orca",
      "surfaces": ["terminal", "tmux", "herdr", "orca"],
      "cwd": "/Users/adrianb/dev/firstmate",
      "project": "firstmate",
      "repoPath": "/Users/adrianb/dev/firstmate",
      "worktreePath": "/Users/adrianb/dev/firstmate",
      "branch": "main",
      "linearIssue": null,
      "conversationId": "bff46a10-19ee-4d69-950c-42301d69c5ca",
      "cpuPercent": 4.2,
      "elapsed": "02:15:00",
      "lastActivityAt": "2026-11-11T22:44:58.000Z",
      "commandPreview": "agy --dangerously-skip-permissions",
      "tmuxTarget": "admiral:0.0",
      "herdrPane": "default/wG0:p1",
      "orcaTerminalId": "term_9d7748ff"
    },
    {
      "id": "adi0:61001",
      "host": "adi0",
      "pid": 61001,
      "ppid": 57264,
      "tty": "ttys004",
      "harness": "agy",
      "state": "working",
      "surface": "orca",
      "surfaces": ["orca"],
      "cwd": "/Users/adrianb/orca/workspaces/orca-axi/fleet-agent-radar",
      "project": "orca-axi",
      "repoPath": "/Users/adrianb/dev/orca-axi",
      "worktreePath": "/Users/adrianb/orca/workspaces/orca-axi/fleet-agent-radar",
      "branch": "feat/fleet-agent-radar",
      "linearIssue": "CYB-501",
      "conversationId": "f0efb389-25b9-49e0-97d6-0ab9b9fde67e",
      "cpuPercent": 12.5,
      "elapsed": "00:18:20",
      "lastActivityAt": "2026-11-11T22:45:00.000Z",
      "commandPreview": "agy --subagent",
      "tmuxTarget": null,
      "herdrPane": null,
      "orcaTerminalId": null
    },
    {
      "id": "adi1:18420",
      "host": "adi1",
      "pid": 18420,
      "ppid": 18000,
      "tty": "pts/2",
      "harness": "codex",
      "state": "working",
      "surface": "tmux",
      "surfaces": ["tmux"],
      "cwd": "/home/adi/worktrees/pentforge.app/feat-sso",
      "project": "pentforge.app",
      "repoPath": "/home/adi/worktrees/pentforge.app/feat-sso",
      "worktreePath": "/home/adi/worktrees/pentforge.app/feat-sso",
      "branch": "feat/cyb-312-sso",
      "linearIssue": "CYB-312",
      "conversationId": null,
      "cpuPercent": 19.1,
      "elapsed": "00:42:10",
      "lastActivityAt": null,
      "commandPreview": "codex --full-auto",
      "tmuxTarget": "pf:1.0",
      "herdrPane": null,
      "orcaTerminalId": null
    },
    {
      "id": "adi2:9921",
      "host": "adi2",
      "pid": 9921,
      "ppid": 9900,
      "tty": "pts/0",
      "harness": "claude",
      "state": "working",
      "surface": "tmux",
      "surfaces": ["tmux"],
      "cwd": "/home/adi/aetherops",
      "project": "aetherops",
      "repoPath": "/home/adi/aetherops",
      "worktreePath": "/home/adi/aetherops",
      "branch": "feat/engine",
      "linearIssue": null,
      "conversationId": null,
      "cpuPercent": 8.4,
      "elapsed": "01:05:00",
      "lastActivityAt": null,
      "commandPreview": "claude",
      "tmuxTarget": "ao:0.0",
      "herdrPane": null,
      "orcaTerminalId": null
    },
    {
      "id": "macmini:4410",
      "host": "macmini",
      "pid": 4410,
      "ppid": 4400,
      "tty": "ttys001",
      "harness": "opencode",
      "state": "idle",
      "surface": "terminal",
      "surfaces": ["terminal"],
      "cwd": "/Users/adi/dev/harness-library",
      "project": "harness-library",
      "repoPath": "/Users/adi/dev/harness-library",
      "worktreePath": "/Users/adi/dev/harness-library",
      "branch": "main",
      "linearIssue": null,
      "conversationId": null,
      "cpuPercent": 0.0,
      "elapsed": "04:10:00",
      "lastActivityAt": null,
      "commandPreview": "opencode",
      "tmuxTarget": null,
      "herdrPane": null,
      "orcaTerminalId": null
    },
    {
      "id": "adi4:3102",
      "host": "adi4",
      "pid": 3102,
      "ppid": 1,
      "tty": "?",
      "harness": "grok",
      "state": "working",
      "surface": "terminal",
      "surfaces": ["terminal"],
      "cwd": "/opt/grok-bot",
      "project": "grok-bot",
      "repoPath": "/opt/grok-bot",
      "worktreePath": "/opt/grok-bot",
      "branch": "main",
      "linearIssue": null,
      "conversationId": null,
      "cpuPercent": 3.8,
      "elapsed": "12:00:00",
      "lastActivityAt": null,
      "commandPreview": "grok-bot",
      "tmuxTarget": null,
      "herdrPane": null,
      "orcaTerminalId": null
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

# Mock herdr collector returning empty ok payload
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

printf '%s' "$JSON_OUT" | jq -e '.schema == "fm-fleet-agents.v1"' >/dev/null \
  || fail "JSON schema must be fm-fleet-agents.v1"
printf '%s' "$JSON_OUT" | jq -e '.summary.machinesOnline == 5 and .summary.totalAgents == 6' >/dev/null \
  || fail "summary counts must reflect 5 online machines and 6 agents"
printf '%s' "$JSON_OUT" | jq -e '.agents[] | select(.id == "adi0:61001") | .matchedTaskId == "task-orca-radar" and .captain == "fm-infra"' >/dev/null \
  || fail "adi0:61001 must match task-orca-radar and captain fm-infra"
printf '%s' "$JSON_OUT" | jq -e '.agents[] | select(.id == "adi1:18420") | .captain == "pf-remote"' >/dev/null \
  || fail "pentforge.app agent on adi1 must map to captain pf-remote"
printf '%s' "$JSON_OUT" | jq -e '.agents[] | select(.id == "adi2:9921") | .captain == "aetherops-remote"' >/dev/null \
  || fail "aetherops agent on adi2 must map to captain aetherops-remote"
pass "fm-fleet-agents: --json merges orca-axi fleet, FirstMate task metas, and SecondMate captains"

# Filter flags: --project, --host, --harness, --active-only
FILTERED=$(FM_HOME="$FM_TEST_HOME" \
  FM_ORCA_AXI_BIN="$LAB/mock-bin/orca-axi" \
  FM_HERDR_COLLECT_BIN="$LAB/mock-bin/fm-fleet-herdr-collect.sh" \
  "$CLI" --all-machines --active-only --host adi1 --json)
printf '%s' "$FILTERED" | jq -e '(.agents | length) == 1 and .agents[0].project == "pentforge.app"' >/dev/null \
  || fail "--active-only --host adi1 must filter to the 1 active agent on adi1"

ACTIVE_ONLY=$(FM_HOME="$FM_TEST_HOME" \
  FM_ORCA_AXI_BIN="$LAB/mock-bin/orca-axi" \
  FM_HERDR_COLLECT_BIN="$LAB/mock-bin/fm-fleet-herdr-collect.sh" \
  "$CLI" --all-machines --active-only --json)
printf '%s' "$ACTIVE_ONLY" | jq -e '(.agents | length) == 5' >/dev/null \
  || fail "--active-only must exclude idle opencode agent and keep 5 working/bridged agents"
pass "fm-fleet-agents: --host and --active-only filters work accurately"

# Human-readable project-grouped output
HUMAN_OUT=$(FM_HOME="$FM_TEST_HOME" \
  FM_ORCA_AXI_BIN="$LAB/mock-bin/orca-axi" \
  FM_HERDR_COLLECT_BIN="$LAB/mock-bin/fm-fleet-herdr-collect.sh" \
  "$CLI" --all-machines)
case "$HUMAN_OUT" in
  *"firstmate"*|*"orca-axi"*) ;;
  *) fail "human output must list active projects" ;;
esac
case "$HUMAN_OUT" in
  *"pf-remote"*|*"fm-infra"*) ;;
  *) fail "human output must display owning SecondMate captains" ;;
esac
pass "fm-fleet-agents: human output renders project-organized fleet table"

# Invalid flag rejection
if FM_HOME="$FM_TEST_HOME" "$CLI" --bogus-flag >/dev/null 2>&1; then
  fail "unknown flag must exit non-zero"
fi
pass "fm-fleet-agents: rejects unknown flags cleanly"
