#!/usr/bin/env bash
# fm-commandopc-wsl-portproxy-refresh.sh - keep the commandopc WSL SSH route alive.
#
# Usage:
#   fm-commandopc-wsl-portproxy-refresh.sh          converge the route, print the result
#   fm-commandopc-wsl-portproxy-refresh.sh --check  read-only: report in-sync or stale
#   fm-commandopc-wsl-portproxy-refresh.sh --help   print this help
#
# Why this exists: `ssh commandopc` lands in Windows PowerShell, so the POSIX
# landing for that machine is a separate alias (`commandopc-wsl`) routed
# through one Windows portproxy rule, `0.0.0.0:<port> -> <wsl-ip>:22`, into
# sshd inside the Ubuntu-24.04 distro. WSL2 NAT hands that distro a new
# private IP on (almost) every Windows restart, which silently strands the
# rule at the previous address. Re-running this script after a restart (or
# whenever `ssh commandopc-wsl` stops answering) re-points exactly that one
# rule at the distro's current IP and changes nothing else.
#
# The script is idempotent and fail-closed. It reads the distro's current IP
# over `ssh commandopc` and reads the live rule table with
# `netsh interface portproxy show all`; when the rule already points at the
# current IP it prints `in-sync: ...` and runs no write. A write is always the
# scoped pair `delete v4tov4 listenport=<port>` + `add v4tov4
# listenport=<port> ... connectport=22 connectaddress=<wsl-ip>`, so the
# pre-existing rules for the other forwarded ports are never addressed, and
# the table is re-read afterwards to prove the new target plus the untouched
# neighbors. Any unreadable input (no WSL IP, no rule table, a failed rewrite)
# aborts nonzero having changed nothing it cannot prove.
#
# The full route inventory (distro sshd setup, authorized key, firewall rule,
# Mac ssh-config entry, and what must never be touched on that host) lives in
# docs/commandopc-wsl-ssh.md; this header owns only the refresh mechanics.
#
# Environment knobs (all overridable for tests):
#   FM_SSH_BIN            ssh client to invoke (default ssh)
#   FM_COMMANDOPC_HOST    Windows-side alias, still PowerShell (default commandopc)
#   FM_WSL_DISTRO         WSL distro hosting sshd (default Ubuntu-24.04)
#   FM_WSL_SSH_PORT       external portproxy listen port (default 2221)
set -u

SSH_BIN="${FM_SSH_BIN:-ssh}"
WIN_HOST="${FM_COMMANDOPC_HOST:-commandopc}"
DISTRO="${FM_WSL_DISTRO:-Ubuntu-24.04}"
PORT="${FM_WSL_SSH_PORT:-2221}"

usage() {
  sed -n '1,/^set -u/p' "${BASH_SOURCE[0]}" | sed -n '2,/^set -u/p' | sed 's/^# \{0,1\}//'
}

valid_ipv4() { # <value> -> 0 when dotted-quad
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

# wsl_current_ip: print the distro's eth0 IPv4 address, nothing else.
wsl_current_ip() {
  local out ip
  out=$("$SSH_BIN" -o ConnectTimeout=15 "$WIN_HOST" \
    "wsl.exe -d $DISTRO -- ip -4 -o addr show eth0" 2>/dev/null) || return 1
  ip=$(printf '%s\n' "$out" | sed -n 's/.*inet \([0-9][0-9.]*\)\/.*/\1/p' | head -n 1)
  valid_ipv4 "${ip:-}" || return 1
  printf '%s\n' "$ip"
}

# rule_target_ip: print the connect address of our listen port, nothing else.
rule_target_ip() {
  local out ip
  out=$("$SSH_BIN" -o ConnectTimeout=15 "$WIN_HOST" \
    'netsh interface portproxy show all' 2>/dev/null) || return 1
  ip=$(printf '%s\n' "$out" | awk -v port="$PORT" '$1 == "0.0.0.0" && $2 == port {print $3}' | head -n 1)
  valid_ipv4 "${ip:-}" || return 1
  printf '%s\n' "$ip"
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --check) MODE=check ;;
  "") MODE=converge ;;
  *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
esac

current_ip=$(wsl_current_ip) || { echo "error: cannot read $DISTRO eth0 IP via $WIN_HOST; changed nothing" >&2; exit 1; }
rule_ip=$(rule_target_ip) || rule_ip=""

if [ "$rule_ip" = "$current_ip" ]; then
  echo "in-sync: 0.0.0.0:$PORT -> $current_ip:22 ($DISTRO)"
  exit 0
fi

if [ "$MODE" = check ]; then
  echo "stale: rule points at ${rule_ip:-<absent>}, distro is at $current_ip; re-run without --check to repair" >&2
  exit 1
fi

"$SSH_BIN" -o ConnectTimeout=15 "$WIN_HOST" \
  "netsh interface portproxy delete v4tov4 listenport=$PORT listenaddress=0.0.0.0" >/dev/null 2>&1
"$SSH_BIN" -o ConnectTimeout=15 "$WIN_HOST" \
  "netsh interface portproxy add v4tov4 listenport=$PORT listenaddress=0.0.0.0 connectport=22 connectaddress=$current_ip" >/dev/null 2>&1 || {
  echo "error: failed to add the $PORT rule for $current_ip; inspect 'netsh interface portproxy show all' on $WIN_HOST" >&2
  exit 1
}

rule_ip=$(rule_target_ip) || { echo "error: rule written but the table is unreadable; verify on $WIN_HOST" >&2; exit 1; }
[ "$rule_ip" = "$current_ip" ] || { echo "error: rule still points at $rule_ip after rewrite; verify on $WIN_HOST" >&2; exit 1; }
echo "repointed: 0.0.0.0:$PORT -> $current_ip:22 ($DISTRO)"
