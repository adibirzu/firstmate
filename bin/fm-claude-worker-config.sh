#!/usr/bin/env bash
# Build launch-only Claude worker configuration without changing login stores.
# Usage: fm-claude-worker-config.sh settings <worktree>
#        fm-claude-worker-config.sh mcp <config-directory>
# settings emits explicit false entries for every user/project/local plugin.
# mcp emits config/crew-mcp.json, or {"mcpServers":{}} when absent.
# Both outputs are JSON strings for fm-spawn's CLI arguments, never shell code.
set -eu
command -v jq >/dev/null || { echo 'error: Claude worker isolation requires jq' >&2; exit 1; }
case "${1:-}" in
  settings)
    files=()
    for file in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" \
      "$2/.claude/settings.json" "$2/.claude/settings.local.json"; do
      if [ -e "$file" ]; then
        [ -r "$file" ] || { echo "error: unreadable Claude settings: $file" >&2; exit 1; }
        files+=("$file")
      fi
    done
    if [ "${#files[@]}" -eq 0 ]; then
      printf '%s\n' '{"enabledPlugins":{}}'
    else
      jq -ces '
        if all(.[]; type == "object" and
          ((.enabledPlugins // {}) | type == "object")) then
          {enabledPlugins: ([.[] | (.enabledPlugins // {}) | keys[]] |
            unique | map({key: ., value: false}) | from_entries)}
        else error("invalid Claude plugin settings") end
      ' "${files[@]}"
    fi
    ;;
  mcp)
    if [ -e "$2/crew-mcp.json" ]; then
      jq -ces 'if length != 1 then error("expected one MCP configuration") else .[0] end |
        if type == "object" and (keys == ["mcpServers"]) and
        (.mcpServers | type == "object") and
        all(.mcpServers[]; type == "object") then .
        else error("crew-mcp.json must contain only an mcpServers object") end' "$2/crew-mcp.json"
    else
      printf '%s\n' '{"mcpServers":{}}'
    fi
    ;;
  *) echo 'usage: fm-claude-worker-config.sh settings <worktree> | mcp <config-directory>' >&2; exit 2 ;;
esac
