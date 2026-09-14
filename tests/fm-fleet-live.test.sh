#!/usr/bin/env bash
# Behavior tests for bin/fm-fleet-live.sh using a stateful fake Herdr client.
#
# These tests prove the live-view surface never depends on ambient session
# state, never targets a session it was not given, never calls a server-global
# or session-lifecycle Herdr operation, and is idempotent. The real-binary path
# is pinned separately in tests/fm-fleet-live-herdr-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVE="$ROOT/bin/fm-fleet-live.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-live)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/workspaces"
: > "$FAKE_STATE/tabs"
: > "$FAKE_STATE/panes"
: > "$FAKE_STATE/seeded"
: > "$FAKE_STATE/runs"
: > "$FAKE_STATE/calls"
printf '0\n' > "$FAKE_STATE/counter"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
# Stateful fake Herdr: models workspaces, tabs, panes and pane runs. Isolation
# is only accepted from a --session flag Herdr itself parses; a call with no
# session flag fails closed, and server/session lifecycle verbs are refused so
# the surface can never reach one.
set -e
state=${FM_FAKE_HERDR_STATE:?}
session=
expect_session=0
args=()
nargs=0
for arg in "$@"; do
  if [ "$expect_session" -eq 1 ]; then session=$arg; expect_session=0; continue; fi
  if [ "$arg" = "--session" ]; then expect_session=1; continue; fi
  case "$arg" in --session=*) session=${arg#--session=} ;; *) args[$nargs]=$arg; nargs=$((nargs + 1)) ;; esac
done
[ -n "$session" ] || { echo "fake herdr: missing --session" >&2; exit 90; }
printf '%s\n' "$session $*" >> "$state/calls"
next_id() { local n; n=$(cat "$state/counter"); n=$((n + 1)); printf '%s\n' "$n" > "$state/counter"; printf '%s' "$n"; }
json_ws_list() {
  local first=1 ws label
  printf '{"result":{"workspaces":['
  while IFS=$'\t' read -r ws label; do
    [ -n "$ws" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"workspace_id":"%s","label":"%s","focused":false}' "$ws" "$label"
  done < "$state/workspaces"
  printf ']}}\n'
}
json_tab_list() {  # <ws>
  local want=$1 first=1 tab ws label
  printf '{"result":{"tabs":['
  while IFS=$'\t' read -r tab ws label; do
    [ "$ws" = "$want" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"tab_id":"%s","workspace_id":"%s","label":"%s","focused":false}' "$tab" "$ws" "$label"
  done < "$state/tabs"
  printf ']}}\n'
}
json_pane_list() {  # <ws>
  local want=$1 first=1 pane tab ws
  printf '{"result":{"panes":['
  while IFS=$'\t' read -r pane tab ws; do
    [ "$ws" = "$want" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}' "$pane" "$tab" "$ws"
  done < "$state/panes"
  printf ']}}\n'
}
cmd=${1:-}; sub=${2:-}
case "$cmd $sub" in
  "server "*|"session stop"|"session delete")
    echo "fake herdr: refused lifecycle op: $cmd $sub" >&2
    exit 91
    ;;
  "workspace list")
    json_ws_list
    ;;
  "workspace create")
    n=$(next_id); ws="ws$n"; tab="tab$n"; pane="pane$n"; label=
    prev=
    for arg in "${args[@]}"; do
      [ "$prev" = "--label" ] && label=$arg
      prev=$arg
    done
    printf '%s\t%s\n' "$ws" "$label" >> "$state/workspaces"
    # Herdr seeds a fresh workspace with one auto-created default tab, never a
    # tab carrying the requested label; the surface prunes that exact seeded tab
    # after its own labeled tab exists.
    printf '%s\t%s\t%s\n' "$tab" "$ws" "default" >> "$state/tabs"
    printf '%s\t%s\t%s\n' "$pane" "$tab" "$ws" >> "$state/panes"
    printf '%s\t%s\n' "$ws" "$tab" >> "$state/seeded"
    printf '{"result":{"workspace":{"workspace_id":"%s"},"tab":{"tab_id":"%s"}}}\n' "$ws" "$tab"
    ;;
  "tab list")
    want=
    prev=
    for arg in "${args[@]}"; do [ "$prev" = "--workspace" ] && want=$arg; prev=$arg; done
    json_tab_list "$want"
    ;;
  "tab create")
    n=$(next_id); tab="tab$n"; pane="pane$n"; ws=; label=
    prev=
    for arg in "${args[@]}"; do
      [ "$prev" = "--workspace" ] && ws=$arg
      [ "$prev" = "--label" ] && label=$arg
      prev=$arg
    done
    printf '%s\t%s\t%s\n' "$tab" "$ws" "$label" >> "$state/tabs"
    printf '%s\t%s\t%s\n' "$pane" "$tab" "$ws" >> "$state/panes"
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tab" "$pane"
    ;;
  "tab close")
    want=${3:-}
    grep -v "^$want	" "$state/tabs" > "$state/tabs.new" 2>/dev/null || true
    mv "$state/tabs.new" "$state/tabs"
    grep -v "	$want	" "$state/panes" > "$state/panes.new" 2>/dev/null || true
    mv "$state/panes.new" "$state/panes"
    printf '{}\n'
    ;;
  "pane list")
    want=
    prev=
    for arg in "${args[@]}"; do [ "$prev" = "--workspace" ] && want=$arg; prev=$arg; done
    json_pane_list "$want"
    ;;
  "pane get")
    want=${3:-}
    if grep -q "^$want	" "$state/panes" 2>/dev/null; then
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$want"
    else
      exit 1
    fi
    ;;
  "pane run")
    want=${3:-}
    if grep -q "^$want	" "$state/panes" 2>/dev/null; then
      shift 3
      printf '%s\n' "$*" >> "$state/runs"
      printf '{}\n'
    else
      exit 1
    fi
    ;;
  *)
    echo "fake herdr: unexpected command: $cmd $sub" >&2
    exit 92
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

reset_fake() {
  : > "$FAKE_STATE/workspaces"
  : > "$FAKE_STATE/tabs"
  : > "$FAKE_STATE/panes"
  : > "$FAKE_STATE/seeded"
  : > "$FAKE_STATE/runs"
  : > "$FAKE_STATE/calls"
  printf '0\n' > "$FAKE_STATE/counter"
}

run_live() {  # <home> <args...>
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_STATE="$FAKE_STATE" FM_HOME="$home" "$LIVE" "$@"
}

record_field() {  # <home> <key>
  awk -F= -v k="$2" '$1 == k { sub("^" k "=", ""); print }' "$1/state/fleet-view.herdr" 2>/dev/null
}

test_open_creates_tab_and_runs_the_view() {
  local home out
  reset_fake
  home=$(make_home open)
  out=$(run_live "$home" open --session fm-lab-open-$$) || fail "open failed: $out"
  case "$out" in "opened fleet view tab "*) : ;; *) fail "open did not report opening a tab: $out" ;; esac
  [ "$(record_field "$home" session)" = "fm-lab-open-$$" ] || fail "record did not bind the session"
  [ -n "$(record_field "$home" workspace)" ] || fail "record did not capture a workspace id"
  [ -n "$(record_field "$home" tab)" ] || fail "record did not capture a tab id"
  [ -n "$(record_field "$home" pane)" ] || fail "record did not capture a pane id"
  grep -q "fm-fleet-view.sh" "$FAKE_STATE/runs" || fail "open did not run the renderer in the pane"
  grep -q "FM_HOME=" "$FAKE_STATE/runs" || fail "the pane command must pin FM_HOME"
  grep -q "tab close" "$FAKE_STATE/calls" || fail "a fresh workspace must prune its exact seeded tab"
  pass "fm-fleet-live open creates one labeled tab and runs the renderer in it"
}

test_open_is_idempotent_and_refreshes() {
  local home runs_before out
  reset_fake
  home=$(make_home idempotent)
  run_live "$home" open --session fm-lab-idem-$$ >/dev/null || fail "first open failed"
  runs_before=$(wc -l < "$FAKE_STATE/runs" | tr -d ' ')
  out=$(run_live "$home" open --session fm-lab-idem-$$) || fail "second open failed: $out"
  case "$out" in "refreshed fleet view tab "*) : ;; *) fail "second open should refresh in place: $out" ;; esac
  [ "$(wc -l < "$FAKE_STATE/workspaces" | tr -d ' ')" = "1" ] || fail "second open must not create a second workspace"
  [ "$(wc -l < "$FAKE_STATE/tabs" | tr -d ' ')" = "1" ] || fail "second open must not create a second tab"
  [ "$(wc -l < "$FAKE_STATE/runs" | tr -d ' ')" = "$((runs_before + 1))" ] || fail "second open must re-run the renderer"
  pass "fm-fleet-live open is idempotent and refreshes the recorded tab"
}

test_status_then_close() {
  local home out
  reset_fake
  home=$(make_home lifecycle)
  out=$(run_live "$home" status --session fm-lab-life-$$) || fail "status on an absent view failed: $out"
  case "$out" in "fleet-view: absent"*) : ;; *) fail "status should report absence first: $out" ;; esac
  run_live "$home" open --session fm-lab-life-$$ >/dev/null || fail "open failed"
  out=$(run_live "$home" status --session fm-lab-life-$$) || fail "status failed: $out"
  case "$out" in "fleet-view: present session=fm-lab-life-$$"*) : ;; *) fail "status should report the present tab: $out" ;; esac
  out=$(run_live "$home" close --session fm-lab-life-$$) || fail "close failed: $out"
  case "$out" in "closed fleet view tab "*) : ;; *) fail "close should report the closed tab: $out" ;; esac
  [ ! -f "$home/state/fleet-view.herdr" ] || fail "close must clear the record"
  [ ! -s "$FAKE_STATE/tabs" ] || fail "close must close the recorded tab"
  out=$(run_live "$home" status --session fm-lab-life-$$) || fail "status after close failed"
  case "$out" in "fleet-view: absent"*) : ;; *) fail "status should report absence after close: $out" ;; esac
  pass "fm-fleet-live status and close operate only on the recorded tab"
}

test_refresh_requires_a_record() {
  local home status=0 out
  reset_fake
  home=$(make_home refresh-none)
  out=$(run_live "$home" refresh --session fm-lab-none-$$ 2>&1) || status=$?
  expect_code 1 "$status" "refresh without a record must fail"
  case "$out" in *"no fleet-view tab recorded"*) : ;; *) fail "refresh refusal should name the missing record: $out" ;; esac
  pass "fm-fleet-live refresh refuses without a recorded tab"
}

test_stale_record_is_recreated() {
  local home pane before out
  reset_fake
  home=$(make_home stale-record)
  run_live "$home" open --session fm-lab-stale-$$ >/dev/null || fail "open failed"
  pane=$(record_field "$home" pane)
  grep -v "^$pane	" "$FAKE_STATE/panes" > "$FAKE_STATE/panes.new"
  mv "$FAKE_STATE/panes.new" "$FAKE_STATE/panes"
  before=$(wc -l < "$FAKE_STATE/workspaces" | tr -d ' ')
  out=$(run_live "$home" open --session fm-lab-stale-$$) || fail "re-open over a stale record failed: $out"
  case "$out" in "opened fleet view tab "*) : ;; *) fail "a stale record must be replaced, not refreshed: $out" ;; esac
  [ "$(wc -l < "$FAKE_STATE/workspaces" | tr -d ' ')" = "$before" ] \
    || fail "re-opening over a stale record must reuse the labeled workspace"
  pass "fm-fleet-live replaces a stale record without creating a duplicate workspace"
}

test_refuses_ambiguous_label() {
  local home status=0 out
  reset_fake
  home=$(make_home ambiguous)
  printf 'wsA\tadix-fleet-view\nwsB\tadix-fleet-view\n' > "$FAKE_STATE/workspaces"
  out=$(run_live "$home" open --session fm-lab-amb-$$ 2>&1) || status=$?
  expect_code 1 "$status" "two workspaces with the view label must refuse"
  case "$out" in *"refusing to guess"*) : ;; *) fail "ambiguous-label refusal should say why: $out" ;; esac
  pass "fm-fleet-live refuses an ambiguous view label instead of guessing"
}

test_session_resolution_prefers_explicit_then_config() {
  local home configured
  reset_fake
  home=$(make_home session)
  run_live "$home" open --session fm-lab-explicit-$$ >/dev/null || fail "explicit-session open failed"
  grep -q "fm-lab-explicit-$$" "$FAKE_STATE/calls" || fail "explicit --session was not used"
  reset_fake
  printf '%s' "fm-lab-config-$$" > "$home/config/fleet-view-session"
  run_live "$home" open >/dev/null || fail "config-session open failed"
  configured=$(grep -c -- "fm-lab-config-$$" "$FAKE_STATE/calls")
  [ "$configured" -gt 0 ] || fail "config/fleet-view-session was not honored"
  reset_fake
  printf '%s' "fm-lab-env-$$" > "$home/config/fleet-view-session"
  PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_STATE="$FAKE_STATE" FM_HOME="$home" \
    FM_FLEET_VIEW_SESSION="fm-lab-envp-$$" "$LIVE" open >/dev/null || fail "env-session open failed"
  grep -q "fm-lab-envp-$$" "$FAKE_STATE/calls" || fail "FM_FLEET_VIEW_SESSION did not override config"
  pass "fm-fleet-live resolves explicit --session, then FM_FLEET_VIEW_SESSION, then config"
}

test_default_session_targets_the_real_session() {
  local home
  reset_fake
  home=$(make_home default)
  run_live "$home" open >/dev/null || fail "default-session open failed"
  grep -q -- "--session default" "$FAKE_STATE/calls" \
    || fail "with no override, the view must target the real 'default' session"
  pass "fm-fleet-live defaults to the real default Herdr session"
}

test_never_calls_lifecycle_or_server_ops() {
  local home
  reset_fake
  home=$(make_home lifecycle-ops)
  run_live "$home" open --session fm-lab-guard-$$ >/dev/null || fail "open failed"
  run_live "$home" refresh --session fm-lab-guard-$$ >/dev/null || fail "refresh failed"
  run_live "$home" status --session fm-lab-guard-$$ >/dev/null || fail "status failed"
  run_live "$home" close --session fm-lab-guard-$$ >/dev/null || fail "close failed"
  if grep -qE '(^| )server |session (stop|delete)' "$FAKE_STATE/calls"; then
    fail "the live view must never call a server-global or session-lifecycle Herdr op"
  fi
  pass "fm-fleet-live never reaches a server-global or session-lifecycle Herdr operation"
}

test_open_rejects_an_invalid_session_name() {
  local home status=0 out
  reset_fake
  home=$(make_home invalid-session)
  out=$(run_live "$home" open --session 'bad session!' 2>&1) || status=$?
  expect_code 1 "$status" "an invalid session name must be refused"
  case "$out" in *"invalid Herdr session name"*) : ;; *) fail "invalid-session refusal should name the problem: $out" ;; esac
  status=0
  out=$(run_live "$home" open --session '-leading-dash' 2>&1) || status=$?
  expect_code 1 "$status" "a session name starting with '-' must be refused"
  pass "fm-fleet-live rejects an invalid session name before any Herdr call"
}

test_help_lists_every_verb() {
  local out
  out=$("$LIVE" --help) || fail "--help should exit 0"
  for verb in open refresh close status; do
    case "$out" in *"$verb"*) : ;; *) fail "--help must document '$verb': $out" ;; esac
  done
  pass "fm-fleet-live --help documents every verb"
}

test_open_creates_tab_and_runs_the_view
test_open_is_idempotent_and_refreshes
test_status_then_close
test_refresh_requires_a_record
test_stale_record_is_recreated
test_refuses_ambiguous_label
test_session_resolution_prefers_explicit_then_config
test_default_session_targets_the_real_session
test_never_calls_lifecycle_or_server_ops
test_open_rejects_an_invalid_session_name
test_help_lists_every_verb
