#!/usr/bin/env bash
# Token-free native OpenCode 1.x composer/control guard. Uses a deterministic
# loopback HTTP model transport, never a fake harness/renderer or provider.
# Run through fm-test-run.sh with OpenCode 1.x on PATH. Unsupported versions
# fail naming the executable/version before launch; no 2.x adapter is implied.
# Truecolor is set only in supported lab children; a palette child must refuse.
# HERDR_LAB_HELPER may select the operator's required isolation helper.
# FM_OPENCODE_CONTROL_EVIDENCE_DIR retains raw ANSI frames when requested.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_OPENCODE_CONTROL_LIVE herdr jq python3 opencode lsof
VERSION=$(opencode --version)
case "$VERSION" in 1.*) ;; *) fail "opencode ($VERSION): this native control guard requires the supported 1.x executable" ;; esac
BIN=$(command -v opencode)
ORIGINAL_PATH=$PATH
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HELPER" name opencode-control)
D=$(mktemp -d /tmp/fmoc.XXXXXX)
D=$(cd "$D" && pwd -P)
grid_pid=
cleanup() {
  local rc=$?
  trap - EXIT
  exec 9>&-
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" || rc=1
  if [ -n "$grid_pid" ]; then wait "$grid_pid" || rc=1; fi
  if [ -n "${FM_OPENCODE_CONTROL_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_OPENCODE_CONTROL_EVIDENCE_DIR"
    cp "$D"/*.ansi "$FM_OPENCODE_CONTROL_EVIDENCE_DIR/" 2>/dev/null || true
  fi
  rm -rf "$D"
  exit "$rc"
}
trap cleanup EXIT
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
mkdir -p "$D/fixture" "$D/fm/state" "$D/fm/data/oc" "$D/shim"
printf '# isolated OpenCode control guard\n' > "$D/fm/data/oc/brief.md"
fm_git_worktree "$D/project" "$D/wt" opencode-control
printf 'preserve this uncommitted file\n' > "$D/wt/uncommitted.txt"
"$HELPER" provision "$SESSION"
ws=$(lab workspace create --cwd "$D/wt" --label transport --no-focus)
fpane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id')
lab pane run "$fpane" "python3 '$ROOT/tests/opencode-model-transport.py' '$D/fixture'" >/dev/null
for _ in $(seq 1 30); do [ ! -s "$D/fixture/listener.json" ] || break; sleep 0.1; done
port=$(jq -er '.port' "$D/fixture/listener.json")
fpid=$(jq -er '.pid' "$D/fixture/listener.json")
lab pane process-info --pane "$fpane" | jq -e --argjson pid "$fpid" '.result.process_info.foreground_processes[] | select(.pid == $pid)' >/dev/null
[ "$(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN | sort -u)" = "$fpid" ] || fail "fixture listener is not owned by its lab pane"
python3 - "$D/opencode.json" "$port" <<'PY'
import sys,json
p={'enabled_providers':['fm-fixture'],'model':'fm-fixture/control','small_model':'fm-fixture/control','permission':{'bash':'ask'},'provider':{'fm-fixture':{'npm':'@ai-sdk/openai-compatible','name':'Local deterministic transport','options':{'baseURL':'http://127.0.0.1:'+sys.argv[2]+'/v1','apiKey':'local-fixture-no-credential'},'models':{'control':{'name':'Local control fixture','tool_call':True,'limit':{'context':131072,'output':4096}},'alternate':{'name':'Local alternate fixture','tool_call':True,'limit':{'context':131072,'output':4096}}}}}}
open(sys.argv[1],'w').write(json.dumps(p))
PY
cat > "$D/shim/herdr" <<EOF
#!/usr/bin/env bash
set -eu
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 97
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$D/shim/herdr"
export PATH="$D/shim:$ORIGINAL_PATH"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr

launch() { # <label>
  local label=$1 color=${2:-truecolor} ws capability='COLORTERM=truecolor'
  [ "$color" != palette ] || capability=''
  mkdir -p "$D/$label/home" "$D/$label/config" "$D/$label/data" "$D/$label/cache"
  cat > "$D/$label/launch.sh" <<EOF
#!/usr/bin/env bash
exec env -i PATH='/opt/homebrew/bin:/usr/bin:/bin' TERM=xterm-256color $capability LANG=en_US.UTF-8 HOME='$D/$label/home' XDG_CONFIG_HOME='$D/$label/config' XDG_DATA_HOME='$D/$label/data' XDG_CACHE_HOME='$D/$label/cache' OPENCODE_CONFIG='$D/opencode.json' OPENCODE_DISABLE_AUTOUPDATE=true OPENCODE_DISABLE_MODELS_FETCH=true OPENCODE_DISABLE_DEFAULT_PLUGINS=true '$BIN' --pure
EOF
  ws=$(lab workspace create --cwd "$D/wt" --label "$label" --no-focus)
  PANE=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id')
  TARGET="$SESSION:$PANE"
  lab pane run "$PANE" "bash '$D/$label/launch.sh'" >/dev/null
  for _ in $(seq 1 45); do
    screen=$(fm_backend_herdr_visible_capture_ansi "$TARGET")
    plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
    if printf '%s\n' "$plain" | grep -q 'Ask anything'; then break; fi
    sleep 0.2
  done
  printf '%s\n' "$screen" > "$D/$label-start.ansi"
  if [ "$color" = palette ]; then
    [ "$(fm_backend_herdr_composer_state "$TARGET")" != empty ] || fail "opencode ($VERSION): unsupported palette hint became injectable"
    return 0
  fi
  if [ "$(fm_backend_herdr_composer_state "$TARGET")" != empty ]; then
    printf '# initial OpenCode frame (%s):\n' "$label" >&2
    printf '%s\n' "$plain" | tail -24 >&2
    printf '# direct verdict=%s\n' "$(fm_composer_classify_screen $'styled=1\nviewport=1\ncursor=0\nidentity=1' "$screen")" >&2
    fail "opencode ($VERSION): initial composer did not prove empty"
  fi
}
control() {
  env FM_HOME="$D/fm" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=10 \
    "$ROOT/bin/fm-control.sh" oc "$@" 2>&1
}
record() {
  local info workspace tab
  info=$(lab pane get "$PANE")
  workspace=$(printf '%s' "$info" | jq -er '.result.pane.workspace_id')
  tab=$(printf '%s' "$info" | jq -er '.result.pane.tab_id')
  lab pane report-agent "$PANE" --source fm-opencode-control-live --agent opencode --state idle >/dev/null
  cat > "$D/fm/state/oc.meta" <<EOF
window=$TARGET
endpoint_task_id=oc
worktree=$D/wt
project=$D/project
harness=opencode
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$workspace
herdr_tab_id=$tab
herdr_pane_id=$PANE
EOF
}
launch palette palette
lab pane send-text "$PANE" 'Ask anything… "keep me"' >/dev/null
sleep 0.2
[ "$(fm_backend_herdr_composer_state "$TARGET")" != empty ] || fail "opencode ($VERSION): palette hint-like draft became injectable"
pass "opencode ($VERSION): unsupported palette hint and real hint-like draft retain refusal"
launch drafts
record
mkfifo "$D/grid.in"
lab terminal session control "$PANE" --cols 120 --rows 60 < "$D/grid.in" > "$D/grid.log" 2>&1 &
grid_pid=$!
exec 9> "$D/grid.in"
sleep 0.3
kill -0 "$grid_pid" 2>/dev/null || fail "native grid controller exited before the session guard"
lab pane get "$PANE" | jq -e '.result.pane.scroll.viewport_rows == 60' >/dev/null \
  || fail "opencode ($VERSION): session guard did not obtain its 60-row viewport"
for draft in 'KEEP_REAL_DRAFT "quoted"' 'Ask anything… "keep me"' 'Ask anything... please investigate'; do
  lab pane send-text "$PANE" "$draft" >/dev/null
  sleep 0.2
  [ "$(fm_backend_herdr_composer_state "$TARGET")" = pending ] || fail "opencode ($VERSION): real hint-like draft became injectable"
  if out=$(control exit); then fail "opencode ($VERSION): exit accepted a real draft: $out"; fi
  case "$out" in *'composer visibly holds pending text'*) ;; *) fail "opencode ($VERSION): draft exit refused for an unrelated reason: $out" ;; esac
  fm_backend_herdr_visible_capture "$TARGET" | grep -qF "$draft" || fail "draft was changed by refused exit"
  lab pane send-keys "$PANE" ctrl+u >/dev/null
  sleep 0.1
done
pass "opencode ($VERSION): real drafts, including quoted hint text, survive refused control exit"
# Enter an actual session before opening /models: the home dialog hides the
# composer, whereas the session dialog leaves its floor and shortcuts intact.
lab pane send-text "$PANE" FM_SESSION_PROBE >/dev/null
lab pane send-keys "$PANE" enter >/dev/null
seen=0
for _ in $(seq 1 60); do
  screen=$(fm_backend_herdr_visible_capture_ansi "$TARGET")
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  if printf '%s\n' "$plain" | grep -q 'FM_LOCAL_FINISHED' \
     && [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ]; then seen=1;break;fi
  sleep 0.2
done
[ "$seen" = 1 ] || fail "opencode ($VERSION): native session blank composer was not observed"
printf '%s\n' "$screen" > "$D/session-idle.ansi"
for query in '' Local FM_NOMATCH_CONTROL; do
  lab pane send-text "$PANE" /models >/dev/null
  for _ in $(seq 1 20); do
    [ "$(fm_backend_herdr_composer_content "$TARGET")" != /models ] || break
    sleep 0.1
  done
  [ "$(fm_backend_herdr_composer_content "$TARGET")" = /models ] || fail "opencode ($VERSION): /models did not reach the actual composer"
  lab pane send-keys "$PANE" enter >/dev/null
  seen=0
  for _ in $(seq 1 30); do
    screen=$(fm_backend_herdr_visible_capture_ansi "$TARGET")
    plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
    if printf '%s\n' "$plain" | grep -q 'Select model'; then seen=1;break;fi
    sleep 0.1
  done
  [ "$seen" = 1 ] || fail "opencode ($VERSION): native model overlay was not observed"
  if [ -n "$query" ]; then lab pane send-text "$PANE" "$query" >/dev/null; fi
  seen=0
  for _ in $(seq 1 30); do
    screen=$(fm_backend_herdr_visible_capture_ansi "$TARGET")
    plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
    dialog=$(printf '%s\n' "$plain" | sed -n '/Select model/,/Connect provider/p')
    if printf '%s\n' "$dialog" | grep -Eq "^[[:space:]]*${query:-Search}[[:space:]]*$"; then seen=1;break;fi
    sleep 0.1
  done
  [ "$seen" = 1 ] || fail "opencode ($VERSION): native model query was not observed: $query"
  printf '%s\n' "$screen" > "$D/models-${query:-unfiltered}.ansi"
  case "$query" in
    FM_NOMATCH_CONTROL)
      if printf '%s\n' "$dialog" | grep -Eq 'Local (control|alternate)|●'; then
        fail "opencode ($VERSION): zero-result native dialog still contained an option"
      fi ;;
    *) printf '%s\n' "$dialog" | grep -q '●' \
         || fail "opencode ($VERSION): populated native model dialog had no options" ;;
  esac
  # Prove the live full frame still selects the intact blank composer and
  # complete status panel. A truncated slice cannot assert viewport authority.
  _fm_composer_scan_screen "$plain" '' 1
  _fm_composer_select_cursorless "$plain" || fail "opencode ($VERSION): modal obscured the underlying composer"
  [ "$FM_COMPOSER_SELECTED_KIND" = leftbar ] || fail "opencode ($VERSION): modal no longer overlays the selected OpenCode composer"
  floor=$((FM_COMPOSER_SELECTED_LAST + 1))
  footer_end=$(_fm_composer_opencode_footer_end "$plain" "$floor")
  [ "$footer_end" -gt "$floor" ] || fail "opencode ($VERSION): modal obscured the complete status panel"
  row=$FM_COMPOSER_SELECTED_FIRST
  while [ "$row" -lt "$FM_COMPOSER_SELECTED_LAST" ]; do
    content=$(_fm_composer_screen_row "$row" "$plain")
    fm_composer_normalize_trim_var content
    content=${content#┃}
    fm_composer_normalize_trim_var content
    [ -z "$content" ] || fail "opencode ($VERSION): native modal case no longer has a blank underlying composer"
    row=$((row + 1))
  done
  [ "$(fm_backend_herdr_composer_state "$TARGET")" = unknown ] || fail "opencode ($VERSION): observed model overlay became injectable: $query"
  if fm_backend_herdr_composer_content "$TARGET" >/dev/null; then fail "opencode ($VERSION): active model dialog allowed extraction: $query"; fi
  if out=$(control exit); then fail "opencode ($VERSION): exit accepted the active session model dialog: $out"; fi
  case "$out" in *"composer state is 'unknown', not proven empty"*) ;; *) fail "opencode ($VERSION): model dialog exit refused for an unrelated reason: $out" ;; esac
  after_screen=$(fm_backend_herdr_visible_capture_ansi "$TARGET")
  printf '%s\n' "$after_screen" > "$D/models-${query:-unfiltered}-after-refusal.ansi"
  after=$(printf '%s\n' "$after_screen" | fm_composer_strip_ansi | sed -n '/Select model/,/Connect provider/p')
  [ "$after" = "$dialog" ] || fail "opencode ($VERSION): refused exit changed the native model query/dialog"
  lab pane send-keys "$PANE" escape >/dev/null
  seen=0
  for _ in $(seq 1 30); do
    screen=$(fm_backend_herdr_visible_capture_ansi "$TARGET")
    printf '%s\n' "$screen" > "$D/session-after-model-close.ansi"
    plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
    if ! printf '%s\n' "$plain" | grep -q 'Select model' \
       && [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ]; then seen=1;break;fi
    sleep 0.1
  done
  [ "$seen" = 1 ] || fail "opencode ($VERSION): model overlay did not close to a proven composer"
done
pass "opencode ($VERSION): native unfiltered, filtered and zero-result model dialogs preserve queries and refuse control"
out=$(control exit) || fail "opencode ($VERSION): normal exit failed: $out"
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail "opencode ($VERSION): exit did not stop its actual process"
lab pane get "$PANE" >/dev/null
[ "$(cat "$D/wt/uncommitted.txt")" = 'preserve this uncommitted file' ] || fail "exit changed uncommitted work"
pass "opencode ($VERSION): control exit preserves the exact endpoint and uncommitted work"
launch permission
lab pane send-text "$PANE" FM_PERMISSION_PROBE >/dev/null
lab pane send-keys "$PANE" enter >/dev/null
seen=0
for _ in $(seq 1 45); do
  plain=$(fm_backend_herdr_visible_capture "$TARGET")
  if printf '%s\n' "$plain" | grep -q 'Permission required'; then seen=1;break;fi
  sleep 0.2
done
[ "$seen" = 1 ] || fail "opencode ($VERSION): local model transport did not produce a real native permission overlay"
[ "$(fm_backend_herdr_composer_state "$TARGET")" != empty ] || fail "opencode ($VERSION): native permission overlay became injectable"
pass "opencode ($VERSION): real native tool permission overlay refuses injection without approving access"
launch busy
lab pane send-text "$PANE" FM_BUSY_PROBE >/dev/null
lab pane send-keys "$PANE" enter >/dev/null
seen=0
for _ in $(seq 1 60); do
  plain=$(fm_backend_herdr_visible_capture "$TARGET")
  if [ -f "$D/fixture/busy-request" ] && printf '%s\n' "$plain" | grep -q 'esc interrupt'; then seen=1;break;fi
  sleep 0.2
done
[ "$seen" = 1 ] || fail "opencode ($VERSION): real generating-busy state was not observed"
[ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] || fail "opencode ($VERSION): genuine blank busy composer was not recognized"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" FM_QUEUE_PROBE 3 0.2 0.2)
[ "$verdict" = empty ] || fail "opencode ($VERSION): queued submit was not confirmed: $verdict"
python3 - "$port" <<'PY'
import sys,urllib.request
urllib.request.urlopen('http://127.0.0.1:'+sys.argv[1]+'/release',timeout=3).read()
PY
landed=0
for _ in $(seq 1 60); do
  if python3 - "$D/fixture/requests.jsonl" <<'PY'
import json,sys
requests=[json.loads(s)['body'] for s in open(sys.argv[1])]
sys.exit(0 if any(p.get('tools') and any(m.get('role')=='user' and m.get('content')=='FM_QUEUE_PROBE' for m in p['messages']) for p in requests) else 1)
PY
  then landed=1;break;fi
  sleep 0.2
done
[ "$landed" = 1 ] || fail "opencode ($VERSION): confirmed queue never reached its local model transport"
pass "opencode ($VERSION): native busy queued Enter reaches the deterministic loopback model transport"
