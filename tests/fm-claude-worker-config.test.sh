#!/usr/bin/env bash
# Exercise generated launch JSON, including explicit false plugin overrides.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-worker-config)
trap 'fm_test_cleanup "$TMP_ROOT"' EXIT
CONFIG_TOOL="$ROOT/bin/fm-claude-worker-config.sh"
mkdir -p "$TMP_ROOT/user" "$TMP_ROOT/wt/.claude" "$TMP_ROOT/config"
printf '%s\n' '{"enabledPlugins":{"personal@market":true,"disabled@market":false},"model":"sonnet"}' > "$TMP_ROOT/user/settings.json"
printf '%s\n' '{"enabledPlugins":{"project@market":true,"personal@market":true}}' > "$TMP_ROOT/wt/.claude/settings.json"
printf '%s\n' '{"enabledPlugins":{"local@market":true},"hooks":{}}' > "$TMP_ROOT/wt/.claude/settings.local.json"
before=$(cksum "$TMP_ROOT/user/settings.json")
settings=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/user" "$CONFIG_TOOL" settings "$TMP_ROOT/wt")
printf '%s\n' "$settings" | jq -e '.enabledPlugins | length == 4 and all(.[]; . == false)' >/dev/null
[ "$before" = "$(cksum "$TMP_ROOT/user/settings.json")" ] || fail "primary settings changed"
pass "all user, project and local plugins disabled without changing primary"
[ "$("$CONFIG_TOOL" mcp "$TMP_ROOT/config")" = '{"mcpServers":{}}' ] || fail "default MCP set nonempty"
printf '%s\n' '{"mcpServers":{"approved":{"type":"http","url":"http://127.0.0.1:9999/mcp"}}}' > "$TMP_ROOT/config/crew-mcp.json"
"$CONFIG_TOOL" mcp "$TMP_ROOT/config" | jq -e '.mcpServers | keys == ["approved"]' >/dev/null
pass "default MCP empty and explicit opt-in contains only approved server"
printf '%s\n' '{"mcpServers":[]}' > "$TMP_ROOT/config/crew-mcp.json"
if "$CONFIG_TOOL" mcp "$TMP_ROOT/config" >/dev/null 2>&1; then fail "malformed MCP accepted"; fi
printf '%s\n' '{"enabledPlugins":[]}' > "$TMP_ROOT/user/settings.json"
if CLAUDE_CONFIG_DIR="$TMP_ROOT/user" "$CONFIG_TOOL" settings "$TMP_ROOT/wt" >/dev/null 2>&1; then fail "malformed plugin settings accepted"; fi
pass "invalid configuration fails closed"
