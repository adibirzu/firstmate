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
test_dashboard_copy_opt_in_and_out
test_render_script_parses
