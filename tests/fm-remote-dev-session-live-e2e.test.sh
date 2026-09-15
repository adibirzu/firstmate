#!/usr/bin/env bash
# Opt-in live guard for bin/fm-remote-dev-session.sh against a real station.
#
# The portable suite proves the command's behavior with stubs; this guard proves
# its read-only half against a genuine registered station over the real
# SSH/fm-on route. It runs only `check` (readiness plus equivalence), so it never
# launches, relaunches, or writes a continuity record.
#
# It opens with tests/lib.sh's fm_live_gate, so it skips cleanly when the guard
# is not opted in or ssh is absent, and fails naming the gap when it is forced on
# but the station is not configured:
#
#   FM_RDS_LIVE=1 FM_RDS_LIVE_STATION=adi2 FM_RDS_LIVE_SECONDMATE=infra-remote \
#     bin/fm-test-run.sh tests/fm-remote-dev-session-live-e2e.test.sh
#
# FM_RDS_LIVE_STATION names a registered station; FM_RDS_LIVE_SECONDMATE names a
# remote second mate registered on it (the check's target). The record schema and
# the command contract are owned by docs/remote-dev-sessions.md.
set -u

# The general test harness clears FM_HOME to isolate ordinary fixture tests.
# Preserve the caller-selected real home before loading that shared library so
# this explicitly opt-in guard can exercise the requested live registry.
RDS_LIVE_HOME=${FM_HOME:-${FM_RDS_LIVE_HOME:-}}

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_RDS_LIVE ssh

STATION=${FM_RDS_LIVE_STATION:-}
MATE=${FM_RDS_LIVE_SECONDMATE:-}

if [ -z "$STATION" ] || [ -z "$MATE" ]; then
  if [ "${FM_RDS_LIVE:-}" = 1 ]; then
    printf 'not ok - FM_RDS_LIVE=1 was requested but FM_RDS_LIVE_STATION and FM_RDS_LIVE_SECONDMATE must name a real station and its remote second mate\n' >&2
    exit 1
  fi
  printf 'skip: live: set FM_RDS_LIVE_STATION and FM_RDS_LIVE_SECONDMATE to run this guard\n'
  exit 0
fi

out=$(mktemp "${TMPDIR:-/tmp}/fm-rds-live.XXXXXX")
status=0
FM_HOME="$RDS_LIVE_HOME" "$ROOT/bin/fm-remote-dev-session.sh" check "$STATION" --secondmate "$MATE" >"$out" 2>&1 || status=$?
if [ "$status" -ne 0 ]; then
  fail "live check failed for station $STATION: $(cat "$out")"
fi
assert_contains "$(cat "$out")" 'check=ok' "the live station did not pass the readiness and equivalence gate"
assert_contains "$(cat "$out")" 'attach:' "the live check did not render an attach command"
assert_contains "$(cat "$out")" "station=$STATION" "the live check did not name the station"

status=0
FM_HOME="$RDS_LIVE_HOME" "$ROOT/bin/fm-remote-dev-session.sh" check "$STATION" --secondmate "$MATE" --backend tmux >"$out" 2>&1 || status=$?
if [ "$status" -eq 0 ]; then
  fail "live tmux check unexpectedly accepted remote secondmate $MATE on station $STATION"
fi
assert_contains "$(cat "$out")" 'require the herdr backend' \
  "the live tmux check did not reject the incompatible backend"

rm -f "$out"
pass "live remote development session check passes for $STATION"
