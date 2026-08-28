#!/usr/bin/env bash
# fm-active-active-check.sh — Deployment check & syntax validator for active-active
# dual-node Mac + Gb10 (adi1 at 100.85.233.75) load balancer.
#
# Usage:
#   fm-active-active-check.sh [OPTIONS]
#
# Options:
#   -c, --caddyfile <path>   Path to Caddyfile (default: repo root Caddyfile)
#   --validate, --syntax-only Validate Caddyfile syntax and configuration only (no network probes)
#   --network-only           Run network reachability and service health checks only
#   --simulate-failover      Simulate failover scenario (Node A down -> Node B active)
#   -j, --json               Output machine-readable JSON status summary
#   -q, --quiet              Quiet mode (suppress output, exit code only)
#   -v, --verbose            Verbose diagnostic logging
#   -t, --timeout <sec>      Probe timeout in seconds (default: 2)
#   -h, --help               Display this help message and exit
#
# Exit codes:
#   0: Healthy / Valid (Active-Active dual-node or Primary operational, Caddyfile valid)
#   1: Degraded (Failover active or single node down)
#   2: Critical (Caddyfile syntax invalid or all upstreams down)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configurable defaults & overrides
CADDYFILE="${CADDYFILE:-${DEFAULT_ROOT}/Caddyfile}"
NODE_A_HOST="${NODE_A_HOST:-127.0.0.1}"
NODE_B_HOST="${NODE_B_HOST:-100.85.233.75}"
TIMEOUT_SEC=2
SYNTAX_ONLY=0
NETWORK_ONLY=0
SIMULATE_FAILOVER=0
JSON_OUTPUT=0
QUIET=0
VERBOSE=0

PULSE_PORT=31337
DEVVIZ_PORT=8000
OLLAMA_PORT=11434
LB_HEALTH_PORT=2020

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//; s/^set -euo.*//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--caddyfile)
      [ -n "${2:-}" ] || { echo "Error: --caddyfile requires a file path" >&2; exit 2; }
      CADDYFILE="$2"
      shift 2
      ;;
    --validate|--syntax-only)
      SYNTAX_ONLY=1
      shift
      ;;
    --network-only)
      NETWORK_ONLY=1
      shift
      ;;
    --simulate-failover)
      SIMULATE_FAILOVER=1
      shift
      ;;
    -j|--json)
      JSON_OUTPUT=1
      shift
      ;;
    -q|--quiet)
      QUIET=1
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -t|--timeout)
      [ -n "${2:-}" ] || { echo "Error: --timeout requires a numeric argument" >&2; exit 2; }
      TIMEOUT_SEC="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() {
  if [ "$QUIET" -eq 0 ] && [ "$JSON_OUTPUT" -eq 0 ]; then
    printf '%s\n' "$*"
  fi
}

log_verbose() {
  if [ "$VERBOSE" -eq 1 ] && [ "$QUIET" -eq 0 ] && [ "$JSON_OUTPUT" -eq 0 ]; then
    printf '[DEBUG] %s\n' "$*"
  fi
}

# --- Caddyfile Validation ---
validate_caddyfile() {
  local target_file="$1"
  local errors=0
  local err_msg=""

  log_verbose "Validating Caddyfile at: $target_file"

  if [ ! -f "$target_file" ]; then
    err_msg="Caddyfile not found at '$target_file'"
    log_verbose "$err_msg"
    CADDY_VALID=0
    CADDY_ERROR="$err_msg"
    return 1
  fi

  if [ ! -r "$target_file" ]; then
    err_msg="Caddyfile at '$target_file' is not readable"
    log_verbose "$err_msg"
    CADDY_VALID=0
    CADDY_ERROR="$err_msg"
    return 1
  fi

  # Check brace balancing
  local open_braces close_braces
  open_braces=$(grep -o '{' "$target_file" | wc -l | tr -d ' ')
  close_braces=$(grep -o '}' "$target_file" | wc -l | tr -d ' ')

  if [ "$open_braces" -ne "$close_braces" ]; then
    err_msg="Syntax error: Unbalanced braces (open: $open_braces, close: $close_braces)"
    log_verbose "$err_msg"
    CADDY_VALID=0
    CADDY_ERROR="$err_msg"
    return 1
  fi

  # Check required node upstreams
  if ! grep -q "127.0.0.1" "$target_file" && ! grep -q "localhost" "$target_file"; then
    err_msg="Configuration error: Missing Node A upstream (127.0.0.1 / localhost)"
    log_verbose "$err_msg"
    CADDY_VALID=0
    CADDY_ERROR="$err_msg"
    return 1
  fi

  if ! grep -q "100.85.233.75" "$target_file"; then
    err_msg="Configuration error: Missing Node B (Gb10 / adi1 @ 100.85.233.75) upstream"
    log_verbose "$err_msg"
    CADDY_VALID=0
    CADDY_ERROR="$err_msg"
    return 1
  fi

  # Check required service ports
  for port in 31337 8000 11434; do
    if ! grep -q ":$port" "$target_file"; then
      err_msg="Configuration warning: Expected service port :$port not found in Caddyfile"
      log_verbose "$err_msg"
    fi
  done

  # Check health check directives
  if ! grep -q "health_uri" "$target_file"; then
    err_msg="Configuration warning: health_uri directive missing from Caddyfile"
    log_verbose "$err_msg"
  fi

  # Check load balancing policy
  if ! grep -q "lb_policy" "$target_file"; then
    err_msg="Configuration warning: lb_policy directive missing from Caddyfile"
    log_verbose "$err_msg"
  fi

  # Check with caddy binary if available
  if command -v caddy >/dev/null 2>&1; then
    log_verbose "Running caddy validate..."
    if ! caddy validate --config "$target_file" >/dev/null 2>&1; then
      err_msg="Caddy binary validation failed on '$target_file'"
      log_verbose "$err_msg"
      CADDY_VALID=0
      CADDY_ERROR="$err_msg"
      return 1
    fi
    log_verbose "caddy validate passed successfully."
  fi

  CADDY_VALID=1
  CADDY_ERROR=""
  return 0
}

# --- Network & Service Probing ---
probe_tcp() {
  local host="$1"
  local port="$2"
  local timeout="$3"

  if command -v nc >/dev/null 2>&1; then
    if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
      nc -z -G "$timeout" "$host" "$port" 2>/dev/null
    else
      nc -z -w "$timeout" "$host" "$port" 2>/dev/null
    fi
  else
    # Fallback to bash pseudo-device TCP connect with timeout
    (exec 3<>/dev/tcp/"$host"/"$port") 2>/dev/null
  fi
}

probe_http() {
  local url="$1"
  local timeout="$2"
  local expected_status="${3:-200}"

  if command -v curl >/dev/null 2>&1; then
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout" --max-time "$((timeout + 1))" "$url" 2>/dev/null || echo "000")
    if [ "$code" = "$expected_status" ] || [ "$code" = "200" ] || [ "$code" = "204" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
      echo "$code"
      return 0
    else
      echo "$code"
      return 1
    fi
  else
    echo "000"
    return 1
  fi
}

probe_node_network() {
  local ip="$1"
  local timeout="$2"

  if [ "$ip" = "127.0.0.1" ] || [ "$ip" = "localhost" ]; then
    return 0
  fi

  if command -v ping >/dev/null 2>&1; then
    if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
      ping -c 1 -t "$timeout" "$ip" >/dev/null 2>&1
    else
      ping -c 1 -W "$timeout" "$ip" >/dev/null 2>&1
    fi
  else
    return 0
  fi
}

# Initialize state variables
CADDY_VALID=0
CADDY_ERROR=""

NODE_A_NET_OK=0
NODE_B_NET_OK=0

NODE_A_PULSE_CODE="000"
NODE_A_PULSE_OK=0
NODE_B_PULSE_CODE="000"
NODE_B_PULSE_OK=0

NODE_A_DEVVIZ_CODE="000"
NODE_A_DEVVIZ_OK=0
NODE_B_DEVVIZ_CODE="000"
NODE_B_DEVVIZ_OK=0

NODE_A_OLLAMA_CODE="000"
NODE_A_OLLAMA_OK=0
NODE_B_OLLAMA_CODE="000"
NODE_B_OLLAMA_OK=0

OVERALL_STATUS="UNKNOWN"
EXIT_CODE=0

# 1. Run Caddyfile syntax validation
if [ "$NETWORK_ONLY" -eq 0 ]; then
  if validate_caddyfile "$CADDYFILE"; then
    log_verbose "Caddyfile structure valid."
  else
    log "Error validating Caddyfile: ${CADDY_ERROR}"
    if [ "$SYNTAX_ONLY" -eq 1 ]; then
      if [ "$JSON_OUTPUT" -eq 1 ]; then
        printf '{"status":"SYNTAX_ERROR","caddyfile_valid":false,"caddyfile_path":"%s","error":"%s"}\n' \
          "$CADDYFILE" "$CADDY_ERROR"
      fi
      exit 2
    fi
  fi
fi

if [ "$SYNTAX_ONLY" -eq 1 ]; then
  if [ "$CADDY_VALID" -eq 1 ]; then
    log "Caddyfile syntax and configuration valid: $CADDYFILE"
    if [ "$JSON_OUTPUT" -eq 1 ]; then
      printf '{"status":"VALID","caddyfile_valid":true,"caddyfile_path":"%s","nodes":{"node_a":"%s","node_b":"%s"}}\n' \
        "$CADDYFILE" "$NODE_A_HOST" "$NODE_B_HOST"
    fi
    exit 0
  else
    exit 2
  fi
fi

# 2. Run Network & Service Probes
log "==> Checking Dual-Node Network Connectivity..."
if probe_node_network "$NODE_A_HOST" "$TIMEOUT_SEC"; then
  NODE_A_NET_OK=1
  log "  [OK] Node A (Mac Primary: $NODE_A_HOST) network reachable"
else
  log "  [FAIL] Node A (Mac Primary: $NODE_A_HOST) unreachable"
fi

if probe_node_network "$NODE_B_HOST" "$TIMEOUT_SEC"; then
  NODE_B_NET_OK=1
  log "  [OK] Node B (Gb10 / adi1: $NODE_B_HOST) Tailscale mesh reachable"
else
  log "  [WARN] Node B (Gb10 / adi1: $NODE_B_HOST) unreachable over Tailscale"
fi

log "==> Probing Upstream Cluster Services..."

# Pulse Daemon (31337)
NODE_A_PULSE_CODE=$(probe_http "http://${NODE_A_HOST}:${PULSE_PORT}/api/pulse/health" "$TIMEOUT_SEC" || echo "$NODE_A_PULSE_CODE")
if [ "$NODE_A_PULSE_CODE" != "000" ] && [ "$NODE_A_PULSE_CODE" != "502" ] && [ "$NODE_A_PULSE_CODE" != "503" ]; then
  NODE_A_PULSE_OK=1
fi

NODE_B_PULSE_CODE=$(probe_http "http://${NODE_B_HOST}:${PULSE_PORT}/api/pulse/health" "$TIMEOUT_SEC" || echo "$NODE_B_PULSE_CODE")
if [ "$NODE_B_PULSE_CODE" != "000" ] && [ "$NODE_B_PULSE_CODE" != "502" ] && [ "$NODE_B_PULSE_CODE" != "503" ]; then
  NODE_B_PULSE_OK=1
fi

# DevViz Dashboard (8000)
NODE_A_DEVVIZ_CODE=$(probe_http "http://${NODE_A_HOST}:${DEVVIZ_PORT}/api/health" "$TIMEOUT_SEC" || echo "$NODE_A_DEVVIZ_CODE")
if [ "$NODE_A_DEVVIZ_CODE" != "000" ] && [ "$NODE_A_DEVVIZ_CODE" != "502" ] && [ "$NODE_A_DEVVIZ_CODE" != "503" ]; then
  NODE_A_DEVVIZ_OK=1
fi

NODE_B_DEVVIZ_CODE=$(probe_http "http://${NODE_B_HOST}:${DEVVIZ_PORT}/api/health" "$TIMEOUT_SEC" || echo "$NODE_B_DEVVIZ_CODE")
if [ "$NODE_B_DEVVIZ_CODE" != "000" ] && [ "$NODE_B_DEVVIZ_CODE" != "502" ] && [ "$NODE_B_DEVVIZ_CODE" != "503" ]; then
  NODE_B_DEVVIZ_OK=1
fi

# Ollama / AI Inference (11434)
NODE_A_OLLAMA_CODE=$(probe_http "http://${NODE_A_HOST}:${OLLAMA_PORT}/api/tags" "$TIMEOUT_SEC" || echo "$NODE_A_OLLAMA_CODE")
if [ "$NODE_A_OLLAMA_CODE" != "000" ] && [ "$NODE_A_OLLAMA_CODE" != "502" ] && [ "$NODE_A_OLLAMA_CODE" != "503" ]; then
  NODE_A_OLLAMA_OK=1
fi

NODE_B_OLLAMA_CODE=$(probe_http "http://${NODE_B_HOST}:${OLLAMA_PORT}/api/tags" "$TIMEOUT_SEC" || echo "$NODE_B_OLLAMA_CODE")
if [ "$NODE_B_OLLAMA_CODE" != "000" ] && [ "$NODE_B_OLLAMA_CODE" != "502" ] && [ "$NODE_B_OLLAMA_CODE" != "503" ]; then
  NODE_B_OLLAMA_OK=1
fi

# Apply failover simulation if requested
if [ "$SIMULATE_FAILOVER" -eq 1 ]; then
  log "==> [SIMULATION] Simulating Node A (Mac Primary) outage..."
  NODE_A_NET_OK=0
  NODE_A_PULSE_OK=0
  NODE_A_DEVVIZ_OK=0
  NODE_A_OLLAMA_OK=0
  NODE_A_PULSE_CODE="000"
  NODE_A_DEVVIZ_CODE="000"
  NODE_A_OLLAMA_CODE="000"
fi

# Determine Cluster State
NODE_A_ANY_OK=$(( NODE_A_PULSE_OK || NODE_A_DEVVIZ_OK || NODE_A_OLLAMA_OK ))
NODE_B_ANY_OK=$(( NODE_B_PULSE_OK || NODE_B_DEVVIZ_OK || NODE_B_OLLAMA_OK ))

if [ "$CADDY_VALID" -eq 0 ] && [ "$NETWORK_ONLY" -eq 0 ]; then
  OVERALL_STATUS="SYNTAX_ERROR"
  EXIT_CODE=2
elif [ "$NODE_A_ANY_OK" -eq 1 ] && [ "$NODE_B_ANY_OK" -eq 1 ]; then
  OVERALL_STATUS="ACTIVE_ACTIVE"
  EXIT_CODE=0
elif [ "$NODE_A_ANY_OK" -eq 1 ] && [ "$NODE_B_ANY_OK" -eq 0 ]; then
  OVERALL_STATUS="PRIMARY_ONLY"
  EXIT_CODE=0
elif [ "$NODE_A_ANY_OK" -eq 0 ] && [ "$NODE_B_ANY_OK" -eq 1 ]; then
  OVERALL_STATUS="FAILOVER_ACTIVE"
  EXIT_CODE=1
else
  OVERALL_STATUS="CRITICAL_ALL_DOWN"
  EXIT_CODE=2
fi

# Output Results
log ""
log "==> Dual-Node Cluster Load Balancer Status: [${OVERALL_STATUS}]"
log "------------------------------------------------------------------"
log "  Service          | Node A (Mac Primary) | Node B (Gb10 / adi1)"
log "------------------------------------------------------------------"
log "  Pulse (:31337)   | HTTP ${NODE_A_PULSE_CODE} $([ "$NODE_A_PULSE_OK" -eq 1 ] && echo '[UP]' || echo '[DOWN]')        | HTTP ${NODE_B_PULSE_CODE} $([ "$NODE_B_PULSE_OK" -eq 1 ] && echo '[UP]' || echo '[DOWN]')"
log "  DevViz (:8000)   | HTTP ${NODE_A_DEVVIZ_CODE} $([ "$NODE_A_DEVVIZ_OK" -eq 1 ] && echo '[UP]' || echo '[DOWN]')        | HTTP ${NODE_B_DEVVIZ_CODE} $([ "$NODE_B_DEVVIZ_OK" -eq 1 ] && echo '[UP]' || echo '[DOWN]')"
log "  Ollama (:11434)  | HTTP ${NODE_A_OLLAMA_CODE} $([ "$NODE_A_OLLAMA_OK" -eq 1 ] && echo '[UP]' || echo '[DOWN]')        | HTTP ${NODE_B_OLLAMA_CODE} $([ "$NODE_B_OLLAMA_OK" -eq 1 ] && echo '[UP]' || echo '[DOWN]')"
log "------------------------------------------------------------------"
log "  Caddyfile Config : $([ "$CADDY_VALID" -eq 1 ] && echo 'VALID' || echo "INVALID: ${CADDY_ERROR}")"
log "  Active Routing   : $([ "$NODE_A_ANY_OK" -eq 1 ] && echo "Node A (Mac Primary @ ${NODE_A_HOST})" || ([ "$NODE_B_ANY_OK" -eq 1 ] && echo "Node B (Gb10 Failover @ ${NODE_B_HOST})" || echo "NONE - ALL DOWN"))"
log "------------------------------------------------------------------"

if [ "$JSON_OUTPUT" -eq 1 ]; then
  printf '{"status":"%s","caddyfile_valid":%s,"caddyfile_path":"%s","caddyfile_error":"%s","nodes":{"node_a":{"host":"%s","reachable":%s},"node_b":{"host":"%s","reachable":%s}},"services":{"pulse":{"node_a":{"code":"%s","healthy":%s},"node_b":{"code":"%s","healthy":%s}},"devviz":{"node_a":{"code":"%s","healthy":%s},"node_b":{"code":"%s","healthy":%s}},"ollama":{"node_a":{"code":"%s","healthy":%s},"node_b":{"code":"%s","healthy":%s}}},"active_target":"%s","exit_code":%d}\n' \
    "$OVERALL_STATUS" \
    "$([ "$CADDY_VALID" -eq 1 ] && echo "true" || echo "false")" \
    "$CADDYFILE" \
    "$CADDY_ERROR" \
    "$NODE_A_HOST" \
    "$([ "$NODE_A_NET_OK" -eq 1 ] && echo "true" || echo "false")" \
    "$NODE_B_HOST" \
    "$([ "$NODE_B_NET_OK" -eq 1 ] && echo "true" || echo "false")" \
    "$NODE_A_PULSE_CODE" \
    "$([ "$NODE_A_PULSE_OK" -eq 1 ] && echo "true" || echo "false")" \
    "$NODE_B_PULSE_CODE" \
    "$([ "$NODE_B_PULSE_OK" -eq 1 ] && echo "true" || echo "false")" \
    "$NODE_A_DEVVIZ_CODE" \
    "$([ "$NODE_A_DEVVIZ_OK" -eq 1 ] && echo "true" || echo "false")" \
    "$NODE_B_DEVVIZ_CODE" \
    "$([ "$NODE_B_DEVVIZ_OK" -eq 1 ] && echo "true" || echo "false")" \
    "$NODE_A_OLLAMA_CODE" \
    "$([ "$NODE_A_OLLAMA_OK" -eq 1 ] && echo "true" || echo "false")" \
    "$NODE_B_OLLAMA_CODE" \
    "$([ "$NODE_B_OLLAMA_OK" -eq 1 ] && echo "true" || echo "false")" \
    "$([ "$NODE_A_ANY_OK" -eq 1 ] && echo "node_a" || ([ "$NODE_B_ANY_OK" -eq 1 ] && echo "node_b" || echo "none"))" \
    "$EXIT_CODE"
fi

exit "$EXIT_CODE"
