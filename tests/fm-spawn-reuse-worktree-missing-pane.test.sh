#!/usr/bin/env bash
# fm-spawn.sh --reuse-worktree: the recorded herdr pane can be gone
# (pane_not_found) - the server restarted, the workspace was closed, or the
# pane's process died and herdr already reaped it. --reuse-worktree only
# ADOPTS an agent-free endpoint; it never assumed the recorded one had to
# still exist, and the classifier correctly reports a gone pane as `missing`
# (bin/backends/herdr.sh's fm_backend_herdr_agent_state), which routes the
# relaunch into the same endpoint-creation path an ordinary first spawn uses.
#
# What was actually broken: the final two steps that put the launch command
# into the new pane - spawn_send_literal (bin/fm-spawn.sh) typing the launch
# command, and spawn_send_key sending Enter to submit it - were called as
# bare, unguarded statements with no return-code check and no diagnostic,
# unlike their sibling spawn_send_text_line (used for the earlier `cd` into
# the worktree), which already checked and reported failures. Under this
# script's `set -eu` (line ~358), a failure in either bare call aborted the
# whole spawn immediately: the endpoint got created and published to
# state/<id>.meta, but the launch command was never typed or submitted, so
# no working agent was running in it - and NOTHING was printed to say why.
# The fix makes spawn_send_literal/spawn_send_key check and report exactly
# like spawn_send_text_line already did.
#
# This suite drives the executable interface with a stateful fake `herdr`
# binary. It pins two things: (1) a herdr endpoint recorded in the record is
# genuinely gone (pane_not_found) does not block --reuse-worktree from
# creating a fresh one and completing the launch when every downstream herdr
# call succeeds, and (2) a failure in the final launch-text-send step is
# reported with a clear diagnostic and a clean nonzero exit, never a silent
# unexplained exit or an unbound-variable crash.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-reuse-worktree-missing-pane)

# A minimal stateful fake herdr CLI. State lives under $HERDR_FAKE_STATE (one
# directory per test case) as plain files, so the fake can answer `list`/`get`
# calls about workspaces/tabs/panes it created earlier in the same run.
# <omit-launch-io>: when "1", `pane send-text` and `pane send-keys` are left
# unimplemented (fall through to the catch-all failure), reproducing a real
# herdr call failing at the final launch-command-submission step.
make_herdr_stub() {  # <dir> <omit-launch-io: 0|1> -> echoes fakebin dir
  local fb="$1/fakebin" omit_launch_io=$2
  mkdir -p "$fb" "$1/herdrstate"
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
set -u
ST="$1/herdrstate"
OMIT_LAUNCH_IO=$omit_launch_io
mkdir -p "\$ST/workspaces" "\$ST/tabs" "\$ST/panes"

next_id() {
  local n
  n=\$(( \$(cat "\$ST/counter" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "\$n" > "\$ST/counter"
  printf 'x%d' "\$n"
}

# Strip the trailing "--session <name>" fm_backend_herdr_cli always appends.
ARGS=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    --session) shift 2 ;;
    *) ARGS+=("\$1"); shift ;;
  esac
done
set -- "\${ARGS[@]:-}"

cmd="\${1:-} \${2:-}"
case "\$cmd" in
  "status --json")
    printf '{"client":{"version":"0.7.1","channel":"stable","protocol":14},"server":{"running":true}}\n'
    ;;
  "server ")
    : # already running; no-op
    ;;
  "workspace list")
    {
      printf '{"result":{"workspaces":['
      first=1
      for f in "\$ST"/workspaces/*; do
        [ -e "\$f" ] || continue
        id=\$(basename "\$f")
        label=\$(cat "\$f")
        [ "\$first" = 1 ] || printf ','
        first=0
        printf '{"workspace_id":"%s","label":"%s"}' "\$id" "\$label"
      done
      printf ']}}\n'
    }
    ;;
  "workspace create")
    label=""
    while [ \$# -gt 0 ]; do
      case "\$1" in --label) label=\$2; shift 2 ;; *) shift ;; esac
    done
    wsid=\$(next_id)
    printf '%s' "\$label" > "\$ST/workspaces/\$wsid"
    tabid=\$(next_id)
    paneid=\$(next_id)
    printf 'workspace=%s\nlabel=__seed__\npane=%s\n' "\$wsid" "\$paneid" > "\$ST/tabs/\$tabid"
    printf 'tab=%s\nworkspace=%s\n' "\$tabid" "\$wsid" > "\$ST/panes/\$paneid"
    printf '{"result":{"workspace":{"workspace_id":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "\$wsid" "\$tabid" "\$paneid"
    ;;
  "tab list")
    wsid=""
    while [ \$# -gt 0 ]; do
      case "\$1" in --workspace) wsid=\$2; shift 2 ;; *) shift ;; esac
    done
    {
      printf '{"result":{"tabs":['
      first=1
      for f in "\$ST"/tabs/*; do
        [ -e "\$f" ] || continue
        id=\$(basename "\$f")
        tws=\$(grep '^workspace=' "\$f" | cut -d= -f2)
        [ "\$tws" = "\$wsid" ] || continue
        label=\$(grep '^label=' "\$f" | cut -d= -f2)
        [ "\$first" = 1 ] || printf ','
        first=0
        printf '{"tab_id":"%s","label":"%s"}' "\$id" "\$label"
      done
      printf ']}}\n'
    }
    ;;
  "tab create")
    wsid="" label=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --workspace) wsid=\$2; shift 2 ;;
        --label) label=\$2; shift 2 ;;
        *) shift ;;
      esac
    done
    tabid=\$(next_id)
    paneid=\$(next_id)
    printf 'workspace=%s\nlabel=%s\npane=%s\n' "\$wsid" "\$label" "\$paneid" > "\$ST/tabs/\$tabid"
    printf 'tab=%s\nworkspace=%s\n' "\$tabid" "\$wsid" > "\$ST/panes/\$paneid"
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "\$tabid" "\$paneid"
    ;;
  "tab close")
    rm -f "\$ST/tabs/\${2:-}"
    printf '{"result":{}}\n'
    ;;
  "pane get")
    paneid="\${3:-}"
    if [ -f "\$ST/panes/\$paneid" ] && [ ! -f "\$ST/panes/\$paneid.closed" ]; then
      cwd=""
      [ -f "\$ST/panes/\$paneid.cwd" ] && cwd=\$(cat "\$ST/panes/\$paneid.cwd")
      printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "\$paneid" "\$cwd"
    else
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "\$paneid"
      exit 1
    fi
    ;;
  "pane run")
    paneid="\${3:-}" text="\${4:-}"
    if [ -f "\$ST/panes/\$paneid" ] && [ ! -f "\$ST/panes/\$paneid.closed" ]; then
      case "\$text" in
        "cd "*)
          rest=\${text#cd }
          rest=\${rest#\'}
          rest=\${rest%\'}
          printf '%s' "\$rest" > "\$ST/panes/\$paneid.cwd"
          ;;
      esac
      printf '{"result":{}}\n'
    else
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "\$paneid"
      exit 1
    fi
    ;;
  "pane send-text"|"pane send-keys")
    paneid="\${3:-}"
    if [ "\$OMIT_LAUNCH_IO" = 1 ]; then
      printf '{"error":{"code":"unsupported","message":"fake herdr: launch IO disabled for this case"}}\n' >&2
      exit 1
    fi
    if [ -f "\$ST/panes/\$paneid" ] && [ ! -f "\$ST/panes/\$paneid.closed" ]; then
      printf '{"result":{}}\n'
    else
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "\$paneid"
      exit 1
    fi
    ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "\${3:-}"
    exit 1
    ;;
  *)
    printf '{"error":{"code":"unsupported","message":"fake herdr: unhandled command %s"}}\n' "\$cmd" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# new_case <name> <id> <omit-launch-io> -> echoes the case dir. The recorded
# herdr_pane_id ("w1:p2") never corresponds to any pane the fake ever creates
# (its own ids are "x1", "x2", ...), so `pane get` on it always answers
# pane_not_found - exactly the gone-endpoint scenario this suite targets.
new_case() {
  local name=$1 id=$2 omit_launch_io=$3 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/home/config"
  fm_git_worktree "$dir/proj" "$dir/wt" "fm/$id"
  {
    printf '# Task\n\n'
    printf '## Captain'"'"'s intent\n\ndo the thing\n\n'
    printf '## Firstmate spec\n\nspec body\n'
  } > "$dir/home/data/$id/brief.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=default:w1:p2" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=herdr" \
    "herdr_session=default" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  make_herdr_stub "$dir" "$omit_launch_io" >/dev/null
  printf '%s\n' "$dir"
}

run_reuse_worktree() {  # <case-dir> <id>
  local dir=$1 id=$2
  # A herdr-launched harness (this very session, when the fake herdr's calls
  # happen to run under one) injects HERDR_PANE_ID/HERDR_SESSION/
  # HERDR_SOCKET_PATH into the environment; fm_backend_herdr_launcher_identity
  # (bin/backends/herdr.sh) would otherwise try to verify ancestry against
  # them against this test's unrelated fake session. Scrub them so placement
  # falls through to the ordinary per-home workspace lookup this suite stubs.
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
      -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" --reuse-worktree --harness claude
}

test_reuse_worktree_recreates_endpoint_when_recorded_pane_is_gone() {
  local dir out rc
  dir=$(new_case recreate rw1 0)
  out=$(run_reuse_worktree "$dir" rw1 2>&1); rc=$?
  expect_code 0 "$rc" "a gone recorded pane should not block --reuse-worktree from completing the relaunch"
  assert_contains "$out" "spawned rw1" "the relaunch should report a completed spawn"
  assert_not_contains "$out" "unbound variable" \
    "the relaunch must not crash on an unbound endpoint variable"
  local pane_after
  pane_after=$(grep '^herdr_pane_id=' "$dir/home/state/rw1.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$pane_after" ] || fail "the relaunched record should have a herdr_pane_id"
  [ "$pane_after" != "w1:p2" ] || fail "the record still names the gone pane instead of a freshly created one"
  pass "fm-spawn --reuse-worktree: a gone recorded herdr pane is replaced by a freshly created one, launch completes"
}

test_reuse_worktree_diagnoses_launch_send_failure_instead_of_dying_silently() {
  local dir out rc
  dir=$(new_case launchfail rw2 1)
  out=$(run_reuse_worktree "$dir" rw2 2>&1); rc=$?
  expect_code 1 "$rc" "a failed launch-command send should fail the relaunch"
  assert_contains "$out" "error: failed to send literal text to" \
    "a failed launch-command send must be reported, not swallowed silently"
  assert_not_contains "$out" "unbound variable" \
    "the relaunch must not crash on an unbound endpoint variable instead of reporting the send failure"
  pass "fm-spawn --reuse-worktree: a failed launch-command send is diagnosed, not a silent exit"
}

test_reuse_worktree_recreates_endpoint_when_recorded_pane_is_gone
test_reuse_worktree_diagnoses_launch_send_failure_instead_of_dying_silently
echo "ALL PASS: fm-spawn-reuse-worktree-missing-pane"
