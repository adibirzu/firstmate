#!/usr/bin/env bash
# Behavior tests for the Pulse fleet page publisher.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUBLISH="$ROOT/bin/fm-fleet-pulse.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-pulse)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# make_fixtures <dir>: fake snapshot/collector bins plus two task metas (one
# router-dispatched, one subscription) for lane derivation.
make_fixtures() {  # <dir>
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fb/fake-snap.sh" <<SH
#!/usr/bin/env bash
cat "$dir/snap.json"
SH
  cat > "$fb/fake-herdr.sh" <<SH
#!/usr/bin/env bash
cat "$dir/herdr.json"
SH
  chmod +x "$fb/fake-snap.sh" "$fb/fake-herdr.sh"
  cat > "$dir/snap.json" <<'EOF'
{"schema":"fm-fleet-snapshot.v1","generated":"t","fm_home":"/h","tasks":[
{"id":"a1","kind":"ship","harness":"opencode","mode":"m","project":"/p","usage":{"model":"m1"},"current_state":{"state":"working","source":"run-step"},"pr":{"url":"https://example.com/pull/1","source":"meta"},"backlog":{"state":"in_flight"}}],
"backlog":{"records":[]},"main_inventory":{"valid":true,"reason":""},
"secondmate_current":{"records":[]},"remote_dev_sessions":[],
"jev_shadow":{"samples":10,"recorded":8,"allFieldsAgree":0.9,"routeAgree":0.8}}
EOF
  cat > "$dir/herdr.json" <<'EOF'
{"schema":"fm-fleet-herdr.v1","generated":1,"host":"local","hosts":[
{"host":"local","ok":true,"source":"local","error":null,"sessions":[
{"name":"default","running":true,"agents":[
{"agent":"claude","status":"idle","cwd":"/side/project","pane_id":"p9","tab_id":"t9","workspace_id":"w9","title":"Side quest","matched_task_id":null,"matched_home":null,"matched_harness":null,"managed":false}],
"plain_panes":[]}]}]}
EOF
  fm_write_meta "$dir/state/a1.meta" \
    "window=tmux:a1" \
    "worktree=/tmp/wt-a1" \
    "harness=opencode" \
    "kind=ship" \
    "provider=litellm"
  fm_write_meta "$dir/state/b2.meta" \
    "window=tmux:b2" \
    "worktree=/tmp/wt-b2" \
    "harness=claude" \
    "kind=ship"
  printf '%s\n' "$fb"
}

test_publish_merges_snapshot_herdr_and_lanes() {
  local dir fakebin out
  dir=$TMP_ROOT/merge
  mkdir -p "$dir"
  fakebin=$(make_fixtures "$dir")
  FM_FLEET_SNAPSHOT_BIN="$fakebin/fake-snap.sh" \
    FM_FLEET_HERDR_BIN="$fakebin/fake-herdr.sh" \
    FM_FLEET_PULSE_PUBLISH=0 FM_STATE_OVERRIDE="$dir/state" \
    "$PUBLISH" publish --out "$dir/out" >/dev/null \
    || fail "publish must succeed on fixture input"
  out=$(cat "$dir/out/fleet.json")
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-pulse.v1"
    and .snapshot.tasks[0].id == "a1"
    and .herdr.hosts[0].sessions[0].agents[0].managed == false
    and .lanes.a1 == "routed" and .lanes.b2 == "subscription"
  ' >/dev/null || fail "merged payload must carry snapshot, herdr, and lanes: $out"
  grep -q "Unmanaged Herdr" "$dir/out/fleet.html" \
    || fail "page must render the unmanaged section"
  grep -q "Jev shadow" "$dir/out/fleet.html" \
    || fail "page must render the Jev shadow summary"
  grep -q "https://example.com/pull/1" "$dir/out/fleet.html" \
    || fail "page must inline the payload PR URL"
  pass "publish merges snapshot, herdr, lanes, and renders the page sections"
}

test_publish_degrades_without_herdr() {
  local dir fakebin out
  dir=$TMP_ROOT/degrade
  mkdir -p "$dir"
  fakebin=$(make_fixtures "$dir")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/dead-herdr.sh"
  chmod +x "$fakebin/dead-herdr.sh"
  FM_FLEET_SNAPSHOT_BIN="$fakebin/fake-snap.sh" \
    FM_FLEET_HERDR_BIN="$fakebin/dead-herdr.sh" \
    FM_FLEET_PULSE_PUBLISH=0 FM_STATE_OVERRIDE="$dir/state" \
    "$PUBLISH" publish --out "$dir/out" >/dev/null \
    || fail "publish must survive a dead collector"
  out=$(cat "$dir/out/fleet.json")
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-pulse.v1" and .snapshot.tasks[0].id == "a1"
  ' >/dev/null || fail "managed fleet must still publish without herdr data: $out"
  pass "publish degrades gracefully when herdr collection fails"
}

test_best_effort_is_silent_and_zero() {
  local dir fakebin out rc
  dir=$TMP_ROOT/best-effort
  mkdir -p "$dir"
  fakebin=$(make_fixtures "$dir")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/dead-snap.sh"
  chmod +x "$fakebin/dead-snap.sh"
  out=$(FM_FLEET_SNAPSHOT_BIN="$fakebin/dead-snap.sh" \
    FM_FLEET_HERDR_BIN="$fakebin/fake-herdr.sh" \
    FM_FLEET_PULSE_PUBLISH=0 FM_STATE_OVERRIDE="$dir/state" \
    "$PUBLISH" publish --best-effort --out "$dir/out" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "best-effort publish must return zero on failure"
  [ -z "$out" ] || fail "best-effort publish must print nothing, got: $out"
  pass "best-effort publish is a silent zero-exit no-op on failure"
}

# The outer FM_FLEET_PULSE_BEST_EFFORT_TIMEOUT bound (above) only stops
# blocking the caller if it actually reaches into the process it wraps. Before
# this fix, the snapshot step re-wrapped itself in its own nested
# fm_run_timed, which isolates into a SEPARATE process group every mechanism
# fm-timeout-lib.sh provides (that isolation is deliberate, so a bound's kill
# never hits unrelated processes) - one the outer bound's kill cannot reach.
# A hung snapshot binary then survived, reparented to init, after the caller
# had already resumed. This pins that the outer bound terminates the hung
# subprocess, not just unblocks the caller.
test_best_effort_terminates_hung_snapshot_subprocess() {
  command -v pgrep >/dev/null 2>&1 || { echo "skip: pgrep not found"; return 0; }
  local dir fakebin nonce rc t0 t1 elapsed waited
  dir=$TMP_ROOT/hang
  mkdir -p "$dir/state"
  fakebin=$(fm_fakebin "$dir")
  # A large, effectively-unique sleep duration doubles as the process-table
  # marker: nothing else on the box is expected to run "sleep <nonce>", and it
  # would never finish naturally within this test's lifetime, so any survivor
  # found after the bound fires is unambiguously the leak this pins.
  nonce=$(( (($$ * 7919) + RANDOM) % 900000 + 100000 ))
  cat > "$fakebin/hang-snap.sh" <<SH
#!/usr/bin/env bash
exec sleep $nonce
SH
  chmod +x "$fakebin/hang-snap.sh"
  cat > "$fakebin/fake-herdr.sh" <<'SH'
#!/usr/bin/env bash
echo '{"schema":"fm-fleet-herdr.v1","generated":1,"host":"local","hosts":[]}'
SH
  chmod +x "$fakebin/fake-herdr.sh"

  t0=$(date +%s)
  FM_FLEET_SNAPSHOT_BIN="$fakebin/hang-snap.sh" \
    FM_FLEET_HERDR_BIN="$fakebin/fake-herdr.sh" \
    FM_FLEET_PULSE_PUBLISH=0 FM_STATE_OVERRIDE="$dir/state" \
    FM_FLEET_PULSE_BEST_EFFORT_TIMEOUT=2 \
    "$PUBLISH" publish --best-effort --out "$dir/out" >/dev/null 2>&1
  rc=$?
  t1=$(date +%s)
  elapsed=$(( t1 - t0 ))
  [ "$rc" -eq 0 ] || fail "best-effort publish against a hung snapshot must still return zero"
  [ "$elapsed" -le 15 ] || fail "best-effort publish must return within its outer bound, took ${elapsed}s"

  waited=0
  while [ "$waited" -lt 30 ]; do
    pgrep -f "sleep $nonce" >/dev/null 2>&1 || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if pgrep -f "sleep $nonce" >/dev/null 2>&1; then
    pkill -KILL -f "sleep $nonce" 2>/dev/null || true
    fail "hung snapshot subprocess must be terminated once the outer best-effort bound fires, not merely orphaned"
  fi
  pass "best-effort publish terminates a hung snapshot subprocess when the outer bound fires"
}

# Companion to test_best_effort_terminates_hung_snapshot_subprocess above:
# that test pins the outer FM_FLEET_PULSE_BEST_EFFORT_TIMEOUT as the last-resort
# bound. This one pins that a caller-supplied --timeout on the collector step
# is actually honored rather than silently discarded - before the fix,
# pulse_run_step ran the best-effort child's step unbounded, so only the much
# larger outer bound (here 30s) ever fired.
test_best_effort_honors_the_requested_step_timeout() {
  command -v pgrep >/dev/null 2>&1 || { echo "skip: pgrep not found"; return 0; }
  local dir fakebin nonce rc t0 t1 elapsed waited
  dir=$TMP_ROOT/step-timeout
  mkdir -p "$dir/state"
  fakebin=$(fm_fakebin "$dir")
  nonce=$(( (($$ * 7919) + RANDOM) % 900000 + 100000 ))
  cat > "$fakebin/fast-snap.sh" <<'SH'
#!/usr/bin/env bash
echo '{"schema":"fm-fleet-snapshot.v1","generated":"t","fm_home":"/h","tasks":[],"backlog":{"records":[]},"main_inventory":{"valid":true,"reason":""},"secondmate_current":{"records":[]},"remote_dev_sessions":[],"jev_shadow":null}'
SH
  chmod +x "$fakebin/fast-snap.sh"
  cat > "$fakebin/hang-herdr.sh" <<SH
#!/usr/bin/env bash
exec sleep $nonce
SH
  chmod +x "$fakebin/hang-herdr.sh"

  t0=$(date +%s)
  FM_FLEET_SNAPSHOT_BIN="$fakebin/fast-snap.sh" \
    FM_FLEET_HERDR_BIN="$fakebin/hang-herdr.sh" \
    FM_FLEET_PULSE_PUBLISH=0 FM_STATE_OVERRIDE="$dir/state" \
    FM_FLEET_PULSE_BEST_EFFORT_TIMEOUT=30 \
    "$PUBLISH" publish --best-effort --out "$dir/out" --timeout 2 >/dev/null 2>&1
  rc=$?
  t1=$(date +%s)
  elapsed=$(( t1 - t0 ))
  [ "$rc" -eq 0 ] || fail "best-effort publish with --timeout against a hung collector must still return zero"
  [ "$elapsed" -le 10 ] || fail "publish --best-effort --timeout 2 must honor the requested bound, not the 30s outer default, took ${elapsed}s"

  waited=0
  while [ "$waited" -lt 30 ]; do
    pgrep -f "sleep $nonce" >/dev/null 2>&1 || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if pgrep -f "sleep $nonce" >/dev/null 2>&1; then
    kill -KILL "$(pgrep -f "sleep $nonce")" 2>/dev/null || true
    fail "hung collector subprocess must be terminated once the requested --timeout fires"
  fi
  pass "best-effort publish honors the caller's --timeout for the collector step"
}

test_dashboard_copy_opt_in_and_out() {
  local dir fakebin
  dir=$TMP_ROOT/dash
  mkdir -p "$dir"
  fakebin=$(make_fixtures "$dir")
  mkdir -p "$dir/dashdir"
  FM_FLEET_SNAPSHOT_BIN="$fakebin/fake-snap.sh" \
    FM_FLEET_HERDR_BIN="$fakebin/fake-herdr.sh" \
    FM_FLEET_PULSE_DASHBOARD_DIR="$dir/dashdir" \
    FM_STATE_OVERRIDE="$dir/state" \
    "$PUBLISH" publish --out "$dir/out" >/dev/null \
    || fail "publish with dashboard dir must succeed"
  [ -f "$dir/dashdir/fleet.html" ] && [ -f "$dir/dashdir/fleet.json" ] \
    || fail "dashboard copy must land fleet.html and fleet.json"
  rm -f "$dir/dashdir/fleet.html" "$dir/dashdir/fleet.json"
  FM_FLEET_SNAPSHOT_BIN="$fakebin/fake-snap.sh" \
    FM_FLEET_HERDR_BIN="$fakebin/fake-herdr.sh" \
    FM_FLEET_PULSE_PUBLISH=0 \
    FM_FLEET_PULSE_DASHBOARD_DIR="$dir/dashdir" \
    FM_STATE_OVERRIDE="$dir/state" \
    "$PUBLISH" publish --out "$dir/out" >/dev/null \
    || fail "publish with FM_FLEET_PULSE_PUBLISH=0 must succeed"
  [ ! -e "$dir/dashdir/fleet.html" ] && [ ! -e "$dir/dashdir/fleet.json" ] \
    || fail "FM_FLEET_PULSE_PUBLISH=0 must skip the dashboard copy"
  pass "dashboard copy honors the publish opt-out"
}

test_render_script_parses() {
  local dir fakebin
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }
  dir=$TMP_ROOT/js
  mkdir -p "$dir"
  fakebin=$(make_fixtures "$dir")
  FM_FLEET_SNAPSHOT_BIN="$fakebin/fake-snap.sh" \
    FM_FLEET_HERDR_BIN="$fakebin/fake-herdr.sh" \
    FM_FLEET_PULSE_PUBLISH=0 FM_STATE_OVERRIDE="$dir/state" \
    "$PUBLISH" publish --out "$dir/out" >/dev/null \
    || fail "publish must succeed for the JS check"
  python3 -c "
import re, sys
html = open('$dir/out/fleet.html').read()
scripts = re.findall(r'<script>(.*?)</script>', html, re.S)
assert scripts, 'no render script block found'
open('$dir/render.js', 'w').write(scripts[-1])
" || fail "render script block must be extractable"
  node --check "$dir/render.js" || fail "render script must parse"
  pass "published page render script parses"
}

test_publish_merges_snapshot_herdr_and_lanes
test_publish_degrades_without_herdr
test_best_effort_is_silent_and_zero
test_best_effort_terminates_hung_snapshot_subprocess
test_best_effort_honors_the_requested_step_timeout
test_dashboard_copy_opt_in_and_out
test_render_script_parses
