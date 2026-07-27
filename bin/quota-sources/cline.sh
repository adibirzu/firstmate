#!/usr/bin/env bash
# quota source: cline surface — the Cline gateway that serves kimi3 and other open
# models. Emits ONE normalized JSON object on stdout:
#   {surface,status,headroom,unit,models,note}
# Read-only. Reads ONLY local cline state (never a secret to stdout). Cline credits/
# usage live server-side (Cline Hub), so headroom is null until an authed usage adapter
# is wired; status reflects whether the CLI is installed + a provider is configured.
set -uo pipefail
prov="$HOME/.cline/data/settings/providers.json"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; root="$(cd "$here/../.." && pwd)"
ov="$root/config/quota-overrides.json"; hr=null

override() { # surface -> echoes int 0-100 or nothing
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$ov" ] || return 0
  local cmd; cmd=$(jq -r --arg s "$1" '.[$s] // ""' "$ov" 2>/dev/null)
  [ -n "$cmd" ] || return 0
  local out; out=$(bash -c "$cmd" 2>/dev/null | tr -dc '0-9'); [ -n "$out" ] || return 0
  [ "$out" -ge 0 ] 2>/dev/null && [ "$out" -le 100 ] 2>/dev/null && printf '%s' "$out"
}

emit() { # status note
  printf '{"surface":"cline","status":"%s","headroom":%s,"unit":"credits","models":["kimi3","open-models"],"note":"%s"}\n' "$1" "$hr" "$2"
}

if ! command -v cline >/dev/null 2>&1; then
  emit unavailable "cline CLI not installed"; exit 0
fi
o=$(override cline); [ -n "$o" ] && hr=$o
if [ -f "$prov" ] && grep -q '"tokenSource"' "$prov" 2>/dev/null; then
  emit configured "kimi3 + open models; credits are server-side (set config/quota-overrides.json .cline for a real number)"
else
  emit auth_required "run: cline auth cline"
fi
