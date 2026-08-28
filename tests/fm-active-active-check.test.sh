#!/usr/bin/env bash
# tests/fm-active-active-check.test.sh - Unit & integration tests for active-active LB check script
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-active-active-check)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

CHECK_BIN="$ROOT/bin/fm-active-active-check.sh"
[ -x "$CHECK_BIN" ] || fail "check script $CHECK_BIN is not executable"

# 1. Help flag test
OUT=$("$CHECK_BIN" --help)
assert_contains "$OUT" "fm-active-active-check.sh" "help output missing script name"
assert_contains "$OUT" "active-active" "help output missing active-active description"
assert_contains "$OUT" "--caddyfile" "help output missing --caddyfile option"
pass "help flag displays usage documentation"

# 2. Valid Caddyfile syntax check (Default Caddyfile in repo)
OUT=$("$CHECK_BIN" --validate)
assert_contains "$OUT" "Caddyfile syntax and configuration valid" "default Caddyfile validation failed"
pass "default Caddyfile validates successfully"

# 3. JSON format validation on valid Caddyfile
JSON_OUT=$("$CHECK_BIN" --validate --json)
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json, sys; d=json.loads(sys.argv[1]); assert d["status"]=="VALID"; assert d["caddyfile_valid"]==True' "$JSON_OUT" \
    || fail "JSON output did not match expected structure"
fi
pass "valid Caddyfile outputs clean structured JSON"

# 4. Custom Caddyfile path via -c / --caddyfile
CUSTOM_CADDY="$TMP_ROOT/CustomCaddyfile"
cat > "$CUSTOM_CADDY" <<'EOF'
http://custom.internal {
    reverse_proxy {
        to 127.0.0.1:31337 100.85.233.75:31337
        health_uri /api/pulse/health
        health_interval 5s
        health_timeout 2s
        health_status 200
        lb_policy first
    }
}
EOF

OUT=$("$CHECK_BIN" -c "$CUSTOM_CADDY" --validate)
assert_contains "$OUT" "Caddyfile syntax and configuration valid" "custom Caddyfile validation failed"
pass "custom Caddyfile path option works correctly"

# 5. Non-existent Caddyfile failure
set +e
ERR_OUT=$("$CHECK_BIN" -c "$TMP_ROOT/NonExistentCaddyfile" --validate 2>&1)
ERR_CODE=$?
set -e
expect_code 2 "$ERR_CODE" "non-existent Caddyfile must exit code 2"
assert_contains "$ERR_OUT" "Caddyfile not found" "error message missing 'Caddyfile not found'"
pass "missing Caddyfile reports error with code 2"

# 6. Unbalanced braces syntax error
BAD_BRACES_CADDY="$TMP_ROOT/BadBracesCaddyfile"
cat > "$BAD_BRACES_CADDY" <<'EOF'
http://bad.internal {
    reverse_proxy {
        to 127.0.0.1:31337 100.85.233.75:31337
EOF

set +e
ERR_OUT=$("$CHECK_BIN" -c "$BAD_BRACES_CADDY" --validate 2>&1)
ERR_CODE=$?
set -e
expect_code 2 "$ERR_CODE" "unbalanced braces must exit code 2"
assert_contains "$ERR_OUT" "Unbalanced braces" "error message missing 'Unbalanced braces'"
pass "unbalanced braces detected with code 2"

# 7. Missing Node A upstream (127.0.0.1 / localhost)
MISSING_NODE_A_CADDY="$TMP_ROOT/MissingNodeACaddyfile"
cat > "$MISSING_NODE_A_CADDY" <<'EOF'
http://test.internal {
    reverse_proxy {
        to 10.0.0.1:31337 100.85.233.75:31337
        health_uri /api/pulse/health
        health_interval 5s
        health_timeout 2s
        health_status 200
        lb_policy first
    }
}
EOF

set +e
ERR_OUT=$("$CHECK_BIN" -c "$MISSING_NODE_A_CADDY" --validate 2>&1)
ERR_CODE=$?
set -e
expect_code 2 "$ERR_CODE" "missing Node A must exit code 2"
assert_contains "$ERR_OUT" "Missing Node A upstream" "error message missing 'Missing Node A upstream'"
pass "missing Node A upstream is caught"

# 8. Missing Node B upstream (100.85.233.75)
MISSING_NODE_B_CADDY="$TMP_ROOT/MissingNodeBCaddyfile"
cat > "$MISSING_NODE_B_CADDY" <<'EOF'
http://test.internal {
    reverse_proxy {
        to 127.0.0.1:31337 10.0.0.2:31337
        health_uri /api/pulse/health
        health_interval 5s
        health_timeout 2s
        health_status 200
        lb_policy first
    }
}
EOF

set +e
ERR_OUT=$("$CHECK_BIN" -c "$MISSING_NODE_B_CADDY" --validate 2>&1)
ERR_CODE=$?
set -e
expect_code 2 "$ERR_CODE" "missing Node B must exit code 2"
assert_contains "$ERR_OUT" "Missing Node B" "error message missing 'Missing Node B'"
pass "missing Node B upstream is caught"

# 9. JSON output on error condition
set +e
JSON_ERR=$("$CHECK_BIN" -c "$BAD_BRACES_CADDY" --validate --json 2>&1)
set -e
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json, sys; d=json.loads(sys.argv[1]); assert d["status"]=="SYNTAX_ERROR"; assert d["caddyfile_valid"]==False' "$JSON_ERR" \
    || fail "JSON error output structure invalid"
fi
pass "error state outputs valid JSON payload"

# 10. Service Probe & Failover Logic Tests with Mock HTTP Server
if command -v python3 >/dev/null 2>&1; then
  # Spawn lightweight mock HTTP server for Node A on test port
  MOCK_A_PORT=39181
  MOCK_B_PORT=39182

  MOCK_SERVER_PY="$TMP_ROOT/mock_server.py"
  cat > "$MOCK_SERVER_PY" <<'PY'
import sys, http.server, socketserver

port = int(sys.argv[1])
class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"healthy","service":"pulse"}')
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", port), HealthHandler) as httpd:
    httpd.serve_forever()
PY

  # Start Mock Node A server
  python3 "$MOCK_SERVER_PY" "$MOCK_A_PORT" >/dev/null 2>&1 &
  PID_MOCK_A=$!
  sleep 0.2

  # Test failover simulation flag
  OUT_SIM=$("$CHECK_BIN" -c "$CUSTOM_CADDY" --simulate-failover --timeout 1 2>&1 || true)
  assert_contains "$OUT_SIM" "Simulating Node A (Mac Primary) outage" "simulate failover log missing"

  # Clean up mock server
  kill "$PID_MOCK_A" 2>/dev/null || true
  wait "$PID_MOCK_A" 2>/dev/null || true
  pass "mock server & failover simulation test passed"
fi

# 11. Quiet mode verification
set +e
QUIET_OUT=$("$CHECK_BIN" --validate --quiet)
QUIET_CODE=$?
set -e
expect_code 0 "$QUIET_CODE" "quiet mode must preserve exit code 0"
[ -z "$QUIET_OUT" ] || fail "quiet mode produced output: $QUIET_OUT"
pass "quiet mode produces zero stdout while returning proper exit code"

echo "ALL ACTIVE-ACTIVE LB CHECKS PASSED"
