#!/usr/bin/env bash
# Authed usage reader for the `cline` surface -> prints ONE integer 0-100 (headroom) or
# NOTHING (blind). Safe to reference from config/quota-overrides.json (.cline).
#
# Credential precedence:
#   1. CLINE_API_KEY  — a STABLE key from app.cline.bot. Preferred: never expires, so the
#      number is always live. Put it in a 0600 file and export it for this reader.
#   2. cline's own session token in ~/.cline/data/settings/providers.json. This is a
#      ~1h rotating WorkOS JWT that cline refreshes WHEN IT RUNS, so a real number appears
#      while cline is active and goes blank when the stored token has expired. We do NOT
#      refresh it ourselves — the refresh token is single-use and refreshing out-of-band
#      would rotate it and break cline's own login.
#
# Token hygiene: read into a var, written to a 0600 header file, passed via `curl -H @file`
# (never on argv), removed on exit. Nothing secret is printed.
set -uo pipefail
prov="$HOME/.cline/data/settings/providers.json"
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

tok="${CLINE_API_KEY:-}"
if [ -z "$tok" ] && [ -f "$prov" ]; then
  tok=$(jq -r '.providers.cline.settings.auth.accessToken // ""' "$prov" 2>/dev/null | sed 's/^workos://')
fi
[ -n "$tok" ] || exit 0
uid=$(jq -r '.providers.cline.settings.auth.accountId
             // .providers.cline.settings.auth.metadata.userInfo.clineUserId // ""' "$prov" 2>/dev/null)
[ -n "$uid" ] || exit 0

hdr=$(mktemp); chmod 600 "$hdr"; printf 'Authorization: Bearer %s\n' "$tok" > "$hdr"
trap 'rm -f "$hdr"' EXIT
resp=$(curl -sS -m 12 -H @"$hdr" "https://api.cline.bot/api/v1/users/$uid/balance" 2>/dev/null) || exit 0
bal=$(printf '%s' "$resp" | jq -r '(.balance // .currentBalance // .data.balance // .data.currentBalance // empty)' 2>/dev/null)
[ -n "$bal" ] || exit 0   # 401 / expired / unexpected shape -> stay blind

# Cline is usage-based (a credit balance, not a percent). Map to a routability headroom:
# credits remaining -> routable (100); drained -> 0. Override CLINE_LOW_CREDIT to tune.
awk -v b="$bal" -v lo="${CLINE_LOW_CREDIT:-0}" 'BEGIN{ b+=0; lo+=0; print (b>lo)?100:0 }'
