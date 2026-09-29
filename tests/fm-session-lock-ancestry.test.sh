#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone (FM_TEST_KILL_RC=1
# makes every pid dead). The suite itself may run inside a Claude session whose
# CLAUDE_CODE_SESSION_ID and CLAUDE_PID would leak into the expression, so both
# are scrubbed and only FM_TEST_SESSION_ID and FM_TEST_CLAUDE_PID reach it.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a session_env=()
  [ -z "${FM_TEST_SESSION_ID:-}" ] || session_env+=("CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION_ID")
  [ -z "${FM_TEST_CLAUDE_PID:-}" ] || session_env+=("CLAUDE_PID=$FM_TEST_CLAUDE_PID")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${session_env[@]+"${session_env[@]}"} \
    PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# A background Claude session's process table. The hook fires inside
# `claude bg-spare` (710), whose parent is `claude bg-pty-host` (720). With the
# transient daemon gone the pty-host is reparented to launchd, so the contiguous
# claude-named run from the hook ends at 720 and the live front-end 700 that
# holds the lock is no longer an ancestor at all. FM_TEST_DAEMON_PRESENT=1 puts
# the daemon (730) back between 720 and 700: the healthy topology.
write_background_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_DAEMON_PRESENT:-0}" in
  700:comm=:*) printf '%s\n' claude ;;
  700:args=:*) printf '%s\n' 'claude --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  730:comm=:*) printf '%s\n' claude ;;
  730:args=:*) printf '%s\n' 'claude daemon run --origin transient' ;;
  730:ppid=:*) printf '%s\n' 700 ;;
  720:comm=:*) printf '%s\n' 'claude bg-pty-host' ;;
  720:args=:*) printf '%s\n' 'claude bg-pty-host /tmp/pty.sock 120 40 -- claude --bg-spare' ;;
  720:ppid=:1) printf '%s\n' 730 ;;
  720:ppid=:*) printf '%s\n' 1 ;;
  710:comm=:*) printf '%s\n' 'claude bg-spare' ;;
  710:args=:*) printf '%s\n' 'claude bg-spare /tmp/claim.sock' ;;
  710:ppid=:*) printf '%s\n' 720 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$1/ps"
}

owned() {  # <fakebin> <state>
  lib_eval "$1" "fm_session_lock_owned_by_self '$2'"
}

foreign_owner() {  # <fakebin> <state>  -> prints the foreign pid
  lib_eval "$1" "fm_session_lock_foreign_owner_live '$2' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\""
}

test_same_session_id_owns_a_recycled_background_chain() {
  local dir fakebin state got
  dir="$TMP_ROOT/background-session"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_background_session_ps "$fakebin"
  printf '700\n' > "$state/.lock"
  printf 'S1\n' > "$state/.lock-session"

  # The divergence itself, so none of the verdicts below can be vacuous: with
  # the daemon gone the front-end is not an ancestor, with it back it is.
  if lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700; then
    fail "the recycled chain still reached the front-end, so the id cases would prove nothing"
  fi
  FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700 \
    || fail "the healthy chain did not reach the front-end"

  # 1. The session's own id from its model-loop process: owned, not foreign.
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "the same session's trusted id did not own the lock after the helper chain was recycled"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "the session's own live front-end was reported as a foreign owner despite the matching id"
  fi
  # 2. A different id: the existing refusal, naming the live owner.
  if FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a different session id claimed a live owner's lock"
  fi
  got=$(FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a different session id did not see the live owner as foreign"
  [ "$got" = 700 ] || fail "the foreign owner pid was '$got', expected 700"
  # 3. The trust gate: the right id carried by a CLAUDE_PID outside the run.
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 owned "$fakebin" "$state"; then
    fail "an id whose CLAUDE_PID is outside the current Claude run was trusted"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "an untrusted id suppressed the foreign-owner verdict"
  printf 'S1:x\n' > "$state/.lock-session"
  FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "a trusted id containing a colon did not own the lock"
  if FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "a matching id containing a colon was reported as a foreign owner"
  fi
  printf 'S1\r' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a recorded id containing a carriage return was treated as a session id"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "a carriage-return sidecar suppressed the foreign-owner verdict"
  printf 'S1\n' > "$state/.lock-session"
  # 4. No id at all: the legacy ancestry verdict, unchanged.
  if owned "$fakebin" "$state"; then
    fail "with no session id the recycled chain claimed the lock"
  fi
  foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "with no session id the live owner was not reported as foreign"
  # 5. The healthy chain owns by ancestry whatever the environment says.
  FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "ancestry membership lost to a different session id"
  FM_TEST_DAEMON_PRESENT=1 owned "$fakebin" "$state" \
    || fail "ancestry membership lost with no session id"
  if FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "an ancestor was reported as a foreign owner"
  fi
  # 6. Never fail open: no sidecar, a symlinked sidecar, and a dead recorded pid
  # are all ancestry-only, so the dead one is left for the ordinary reclaim.
  rm -f "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a lock with no recorded session id was owned through the environment id"
  fi
  printf 'S1\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a symlinked sidecar was trusted"
  fi
  rm -f "$state/.lock-session"
  printf 'S1\n' > "$state/.lock-session"
  if FM_TEST_KILL_RC=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a same-session lock whose recorded pid is dead was owned instead of left for reclaim"
  fi
  pass "session-lock: a trusted same-session id keeps owning a recycled background chain, and nothing weaker does"
}

test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id() {
  local dir fakebin got
  dir="$TMP_ROOT/background-anchor"
  fakebin=$(fm_fakebin "$dir")
  write_background_session_ps "$fakebin"

  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for a trusted id"
  [ "$got" = 710 ] || fail "a trusted id anchored '$got', expected the model-loop process 710"
  got=$(lib_eval "$fakebin" 'fm_session_lock_anchor_pid') || fail "no anchor pid was resolved without an id"
  [ "$got" = 720 ] || fail "without an id the anchor was '$got', expected the outermost pid 720"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for an untrusted id"
  [ "$got" = 720 ] || fail "an untrusted id anchored '$got', expected the outermost pid 720"
  got=$(FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain"
  [ "$got" = 700 ] || fail "the healthy chain without an id anchored '$got', expected the outermost pid 700"
  got=$(FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain with a trusted id"
  [ "$got" = 710 ] || fail "the healthy chain with a trusted id anchored '$got', expected 710 rather than the front-end"
  pass "session-lock: a trusted id anchors the lock on the model-loop process, anything else on the outermost pid"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  # The fixture arm written here stands in for the watcher arm, so the home opts out
  # of the supervision host a Claude home otherwise runs by default.
  mkdir -p "$dir/config"
  printf 'off\n' > "$dir/config/supervision-host"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
export CLAUDECODE=1
export CLAUDE_CODE_SESSION_ID=fixture-session
export CLAUDE_PID=$$
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# --- end-to-end layer: fm-lock.sh identity and the CLAUDE_PID fallback --------
#
# These run the REAL bin/fm-lock.sh inside real, orphaned process trees whose
# leaf is a genuine Claude-named executable, so the identity verdict comes from
# the live process table and never from a stub asserting its own assumption. The
# trees are orphaned to init before fm-lock.sh runs, so the ancestry walk
# terminates inside the fixture and can never escape into the session running
# this suite. The live-harness half of this contract - that the real installed
# Claude Code build, which does not export CLAUDE_PID, still resolves its lock
# identity - is proven end to end by tests/fm-claude-stop-autoarm-live-e2e.test.sh.

# Install the lock scripts and a reusable probe into <dir>. The probe orphans
# itself, publishes its own pid, drives the requested CLAUDE_PID / CLAUDECODE /
# session-id markers, runs fm-lock.sh against FM_LOCK_HOME, and records the exit
# code; with FM_PROBE_HOLD=1 it then keeps its pid live until a release file
# appears, so a second session can collide with a genuinely live owner.
make_lock_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  install_autoarm_scripts "$dir"
  cat > "$dir/lock-probe.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
out=$FM_PROBE_OUT
mkdir -p "$out"
printf '%s\n' "$$" > "$out/session-pid"
export CLAUDECODE="${FM_PROBE_CLAUDECODE:-1}"
export CLAUDE_CODE_SESSION_ID="$FM_PROBE_SESSION_ID"
if [ "${FM_PROBE_SET_CLAUDE_PID:-0}" = 1 ]; then
  export CLAUDE_PID=$$
else
  unset CLAUDE_PID
fi
FM_HOME="$FM_LOCK_HOME" "$FM_LOCK_HOME/bin/fm-lock.sh" </dev/null > "$out/lock.out" 2>&1
printf '%s\n' "$?" > "$out/lock.rc"
if [ "${FM_PROBE_HOLD:-0}" = 1 ]; then
  touch "$out/held"
  j=0
  while [ "$j" -lt 600 ] && [ ! -f "$out/release" ]; do
    sleep 0.05
    j=$((j + 1))
  done
fi
SH
  chmod +x "$dir/lock-probe.sh"
}

# Start a probe detached, so the launcher exits and the tree reparents to init.
launch_lock_probe() {  # <lock-home> <out> <leaf-bin> <set-claude-pid> <session-id> <hold> [claudecode]
  local home=$1 out=$2 leaf=$3 set_pid=$4 sid=$5 hold=$6 cc=${7:-1}
  mkdir -p "$out"
  FM_LOCK_HOME="$home" FM_PROBE_OUT="$out" FM_PROBE_SET_CLAUDE_PID="$set_pid" \
    FM_PROBE_SESSION_ID="$sid" FM_PROBE_HOLD="$hold" FM_PROBE_CLAUDECODE="$cc" \
    bash -c '"$0" "$1" &' "$leaf" "$home/lock-probe.sh"
}

wait_for_probe() {  # <out>
  local out=$1 i=0
  while [ "$i" -lt 600 ] && [ ! -s "$out/lock.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$out/lock.rc" ] || fail "the lock probe never finished"
}

wait_for_hold() {  # <out>
  local out=$1 i=0
  while [ "$i" -lt 600 ] && [ ! -e "$out/held" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$out/held" ] || fail "the holding lock probe never acquired"
}

test_e2e_claude_pid_set_resolves_identity() {
  local dir out selfpid lock record
  dir="$TMP_ROOT/e2e-claude-pid-set"
  make_lock_home "$dir"
  out="$dir/probe-out"
  launch_lock_probe "$dir" "$out" "$VERSIONED_CLAUDE" 1 pid-set-session 0
  wait_for_probe "$out"
  expect_code 0 "$(tr -d '[:space:]' < "$out/lock.rc")" "a claude session that exports CLAUDE_PID must acquire the lock"
  selfpid=$(tr -d '[:space:]' < "$out/session-pid")
  lock=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock" = "$selfpid" ] || fail "the lock pid did not record the claude session pid: expected $selfpid, got $lock"
  record=$(cat "$dir/state/.lock.session")
  [ "$record" = "$(printf 'format=1\nkind=claude\npid=%s\nsession=pid-set-session' "$selfpid")" ] \
    || fail "the CLAUDE_PID-set path wrote an unexpected binding: $record"
  pass "session-lock e2e: a claude session that exports CLAUDE_PID resolves its identity unchanged"
}

test_e2e_claude_pid_absent_resolves_via_ancestry_fallback() {
  local dir out selfpid lock record
  dir="$TMP_ROOT/e2e-claude-pid-absent"
  make_lock_home "$dir"
  out="$dir/probe-out"
  launch_lock_probe "$dir" "$out" "$VERSIONED_CLAUDE" 0 pid-absent-session 0
  wait_for_probe "$out"
  expect_code 0 "$(tr -d '[:space:]' < "$out/lock.rc")" "a claude session without CLAUDE_PID must still acquire via the ancestry fallback"
  selfpid=$(tr -d '[:space:]' < "$out/session-pid")
  lock=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock" = "$selfpid" ] || fail "the fallback recorded a pid other than the live claude ancestor: expected $selfpid, got $lock"
  record=$(cat "$dir/state/.lock.session")
  [ "$record" = "$(printf 'format=1\nkind=claude\npid=%s\nsession=pid-absent-session' "$selfpid")" ] \
    || fail "the fallback wrote an unexpected binding: $record"
  pass "session-lock e2e: a claude session with no CLAUDE_PID resolves identity from its live ancestry"
}

test_e2e_claude_markers_without_a_live_ancestor_refuse() {
  local dir out
  dir="$TMP_ROOT/e2e-no-claude-ancestor"
  make_lock_home "$dir"
  out="$dir/probe-out"
  # Identical CLAUDECODE and session-id markers to the fallback case and no
  # CLAUDE_PID, but a non-claude leaf: driving the two cases apart on the
  # ancestry signal alone proves the env markers cannot mint a claude lock on
  # their own, so the fallback did not open a hole.
  launch_lock_probe "$dir" "$out" /bin/bash 0 pid-absent-session 0
  wait_for_probe "$out"
  expect_code 1 "$(tr -d '[:space:]' < "$out/lock.rc")" "claude env markers without a live claude ancestor must refuse"
  case "$(cat "$out/lock.out")" in
    *"cannot establish this session's lock identity"*) ;;
    *) fail "the refusal was not the identity refusal: $(cat "$out/lock.out")" ;;
  esac
  [ ! -e "$dir/state/.lock" ] || fail "a session with no live claude ancestor wrote a lock"
  [ ! -e "$dir/state/.lock.session" ] || fail "a session with no live claude ancestor wrote a binding"
  pass "session-lock e2e: claude env markers without a live claude ancestor still fail closed"
}

test_e2e_fallback_owner_still_excludes_a_second_live_session() {
  local dir out_a out_b owner_a i
  dir="$TMP_ROOT/e2e-fallback-collision"
  make_lock_home "$dir"
  out_a="$dir/probe-a"
  out_b="$dir/probe-b"
  # Session A acquires through the CLAUDE_PID fallback and holds its pid live.
  launch_lock_probe "$dir" "$out_a" "$VERSIONED_CLAUDE" 0 owner-a-session 1
  wait_for_hold "$out_a"
  expect_code 0 "$(tr -d '[:space:]' < "$out_a/lock.rc")" "the fallback owner must acquire the lock"
  owner_a=$(tr -d '[:space:]' < "$out_a/session-pid")
  # Session B is a different live claude session, also using the fallback.
  launch_lock_probe "$dir" "$out_b" "$NAMED_CLAUDE" 0 intruder-b-session 0
  wait_for_probe "$out_b"
  expect_code 1 "$(tr -d '[:space:]' < "$out_b/lock.rc")" "a second live session must be refused"
  case "$(cat "$out_b/lock.out")" in
    *"another live firstmate session holds the lock (pid $owner_a)"*) ;;
    *) fail "the collision refusal did not name the live fallback owner pid $owner_a: $(cat "$out_b/lock.out")" ;;
  esac
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$owner_a" ] \
    || fail "the second session moved the lock off the fallback owner"
  # Release A and let the held session exit on its own.
  touch "$out_a/release"
  i=0
  while [ "$i" -lt 200 ] && kill -0 "$owner_a" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  pass "session-lock e2e: a fallback-acquired lock still excludes a second live claude session"
}

test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_same_session_id_owns_a_recycled_background_chain
test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_claude_pid_set_resolves_identity
test_e2e_claude_pid_absent_resolves_via_ancestry_fallback
test_e2e_claude_markers_without_a_live_ancestor_refuse
test_e2e_fallback_owner_still_excludes_a_second_live_session
test_e2e_background_session_keeps_its_lock_across_a_recycled_chain
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock
test_same_session_confirmation_does_not_steal_after_wait
test_failed_lock_write_restores_previous_sidecar
test_failed_lock_write_removes_new_sidecar_when_none_existed
test_verified_reclaim_keeps_new_sidecar
