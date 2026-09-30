#!/usr/bin/env bash
# fm-commandopc-wsl-portproxy-refresh keeps one Windows portproxy rule glued
# to a WSL distro whose NAT IP drifts across restarts.
#
# These tests drive the real script against a stubbed ssh transport
# (FM_SSH_BIN seam) and pin:
#   1. An in-sync rule is reported and no write is attempted.
#   2. A stale rule is repaired with a scoped delete+add for our port only;
#      the neighboring forwarded ports are never addressed.
#   3. --check reports stale read-only and attempts no write.
#   4. An unreadable WSL IP fails loudly having attempted no write.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFRESH="$ROOT/bin/fm-commandopc-wsl-portproxy-refresh.sh"

TMP_ROOT=$(fm_test_tmproot fm-commandopc-wsl-refresh)

# fake-ssh answers the three fixed remote probes from canned environment and
# logs every invocation's argv, so each test asserts exactly which writes the
# script attempted. No byte of the script under test is asserted, only its
# transport behavior and exit contract.
make_fake_ssh() { # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_SSH_LOG:?}"
STATE_FILE="${FM_FAKE_STATE_DIR:?}/connect-ip"
if [[ "$*" == *"addr show eth0"* ]]; then
  [ "${FM_FAKE_IP_RC:-0}" -eq 0 ] || exit "${FM_FAKE_IP_RC:-0}"
  printf '%s\n' "${FM_FAKE_IP_LINE:-2: eth0    inet 172.19.131.83/20 brd 172.19.143.255 scope global eth0}"
  exit 0
fi
if [[ "$*" == *"portproxy show all"* ]]; then
  table="$FM_FAKE_RULE_TABLE"
  if [ -f "$STATE_FILE" ]; then
    table=$(printf '%s\n' "$table" | sed "s/\\(2221 *\\)[0-9.]*/\\1$(cat "$STATE_FILE")/")
  fi
  printf '%s\n' "$table"
  exit 0
fi
if [[ "$*" == *"portproxy delete"* ]]; then
  rm -f "$STATE_FILE"
  exit "${FM_FAKE_WRITE_RC:-0}"
fi
if [[ "$*" == *"portproxy add"* ]]; then
  printf '%s' "$*" | sed -n 's/.*connectaddress=\([0-9.]*\).*/\1/p' > "$STATE_FILE"
  exit "${FM_FAKE_WRITE_RC:-0}"
fi
echo "fake-ssh: unexpected argv: $*" >&2
exit 99
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

BASE_TABLE='Listen on ipv4:             Connect to ipv4:
Address         Port        Address         Port
0.0.0.0         80          172.19.131.83   80
0.0.0.0         8123        192.168.20.89   8123
0.0.0.0         8642        172.19.131.83   8642
0.0.0.0         2221        172.19.131.83   22'
CURRENT_IP_LINE='2: eth0    inet 172.19.131.83/20 brd 172.19.143.255 scope global eth0'
STALE_TABLE="${BASE_TABLE/172.19.131.83   22/172.19.99.7   22}"

# run_refresh <dir> <table> <ip-line> <ip-rc> [refresh args...]
# Runs the real script with the canned transport. Prefix assignment is safe
# here because the target is an external command, not a function.
run_refresh() {
  local dir=$1 table=$2 ip_line=$3 ip_rc=$4
  shift 4
  mkdir -p "$dir/state"
  FM_FAKE_RULE_TABLE="$table" FM_FAKE_IP_LINE="$ip_line" FM_FAKE_IP_RC="$ip_rc" \
    FM_FAKE_STATE_DIR="$dir/state" \
    FM_SSH_BIN="$dir/fakebin/fake-ssh" FM_SSH_LOG="$dir/ssh.log" \
    FM_COMMANDOPC_HOST=commandopc FM_WSL_DISTRO=Ubuntu-24.04 FM_WSL_SSH_PORT=2221 \
    "$REFRESH" "$@" >"$dir/out" 2>"$dir/err"
}

test_in_sync_attempts_no_write() {
  local dir out rc log
  dir="$TMP_ROOT/in-sync"; mkdir -p "$dir"
  make_fake_ssh "$dir" >/dev/null
  : > "$dir/ssh.log"
  run_refresh "$dir" "$BASE_TABLE" "$CURRENT_IP_LINE" 0; rc=$?
  out=$(cat "$dir/out")
  log=$(cat "$dir/ssh.log")
  expect_code 0 "$rc" "an in-sync rule should exit 0"
  assert_contains "$out" "in-sync" "an in-sync rule should be reported"
  assert_not_contains "$log" "portproxy delete" "an in-sync rule must attempt no delete"
  assert_not_contains "$log" "portproxy add" "an in-sync rule must attempt no add"
  pass "refresh: an in-sync rule is reported with no write attempted"
}

test_stale_repairs_only_our_port() {
  local dir out rc log
  dir="$TMP_ROOT/stale"; mkdir -p "$dir"
  make_fake_ssh "$dir" >/dev/null
  : > "$dir/ssh.log"
  run_refresh "$dir" "$STALE_TABLE" "$CURRENT_IP_LINE" 0; rc=$?
  out=$(cat "$dir/out")
  log=$(cat "$dir/ssh.log")
  expect_code 0 "$rc" "a repaired rule should exit 0"
  assert_contains "$out" "repointed" "a stale rule should be reported as repointed"
  assert_contains "$out" "172.19.131.83" "the report should name the new target"
  assert_contains "$log" "portproxy delete v4tov4 listenport=2221" \
    "the repair should delete exactly our listen port"
  assert_contains "$log" "connectaddress=172.19.131.83" \
    "the repair should add our port at the fresh IP"
  assert_not_contains "$log" "listenport=80" "the repair must never address the port-80 rule"
  assert_not_contains "$log" "listenport=8123" "the repair must never address the HomeAssistant rule"
  assert_not_contains "$log" "listenport=8642" "the repair must never address the Hermes rule"
  pass "refresh: a stale rule is repaired with a scoped delete+add, neighbors untouched"
}

test_check_is_read_only() {
  local dir rc log combined
  dir="$TMP_ROOT/check"; mkdir -p "$dir"
  make_fake_ssh "$dir" >/dev/null
  : > "$dir/ssh.log"
  run_refresh "$dir" "$STALE_TABLE" "$CURRENT_IP_LINE" 0 --check; rc=$?
  log=$(cat "$dir/ssh.log")
  combined="$(cat "$dir/out")$(cat "$dir/err")"
  [ "$rc" -ne 0 ] || fail "--check on a stale rule must exit nonzero"
  assert_contains "$combined" "stale" "--check should report the stale state"
  assert_not_contains "$log" "portproxy delete" "--check must attempt no delete"
  assert_not_contains "$log" "portproxy add" "--check must attempt no add"
  pass "refresh: --check reports stale read-only with no write attempted"
}

test_unreadable_ip_fails_without_write() {
  local dir rc log
  dir="$TMP_ROOT/noip"; mkdir -p "$dir"
  make_fake_ssh "$dir" >/dev/null
  : > "$dir/ssh.log"
  run_refresh "$dir" "$BASE_TABLE" "$CURRENT_IP_LINE" 1; rc=$?
  log=$(cat "$dir/ssh.log")
  [ "$rc" -ne 0 ] || fail "an unreadable WSL IP must exit nonzero"
  assert_not_contains "$log" "portproxy delete" "no IP must mean no delete"
  assert_not_contains "$log" "portproxy add" "no IP must mean no add"
  pass "refresh: an unreadable WSL IP fails loudly with no write attempted"
}

test_in_sync_attempts_no_write
test_stale_repairs_only_our_port
test_check_is_read_only
test_unreadable_ip_fails_without_write

echo "all fm-commandopc-wsl-portproxy-refresh tests passed"
