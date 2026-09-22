#!/usr/bin/env bash
# tests/fm-station-bootstrap.test.sh - the bare-to-doctor-green station script.
#
# Drives the real bin/fm-station-bootstrap.sh against a stubbed SSH transport
# (FM_SSH_BIN): the fake ssh executes each remote command with a fixture HOME
# and a fixture tool bin, so clone, symlink, package, npm, curl-installer,
# router-build, policy-transfer, and doctor-invocation behavior are exercised
# for real without touching any live host. Nothing here opens an SSH
# connection or reads the runner's own router policy unless a case opts in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-station-bootstrap)
BOOTSTRAP="$ROOT/bin/fm-station-bootstrap.sh"
FORK="https://github.com/adibirzu/firstmate.git"

new_fixture() { # <name>; sets FIX_* vars and writes the stub transport
  local name=$1
  FIX_DIR="$TMP_ROOT/$name"
  FIX_HOME="$FIX_DIR/home"
  FIX_BIN="$FIX_DIR/bin"
  mkdir -p "$FIX_HOME" "$FIX_BIN"

  cat > "$FIX_BIN/uname" <<'SH'
#!/bin/sh
printf 'Linux\n'
SH
  cat > "$FIX_BIN/id" <<'SH'
#!/bin/sh
if [ "${1:-}" = -u ]; then printf '1000\n'; else printf 'uid=1000(adi) gid=1000(adi)\n'; fi
SH
  cat > "$FIX_BIN/sudo" <<'SH'
#!/bin/sh
[ "${1:-}" = -n ] && shift
exec "$@"
SH
  cat > "$FIX_BIN/apt-get" <<'SH'
#!/bin/sh
bin_dir=${FM_FIX_BIN:?}
if [ "${1:-}" = update ]; then exit 0; fi
shift # install
[ "${1:-}" = -y ] && shift
for pkg in "$@"; do
  case "$pkg" in
    -*) continue ;;
    nodejs) tools="node nodejs" ;;
    *) tools="$pkg" ;;
  esac
  for t in $tools; do
    [ -e "$bin_dir/$t" ] || { printf '#!/bin/sh\necho "%s stub 1.0"\n' "$t" > "$bin_dir/$t"; chmod +x "$bin_dir/$t"; }
  done
done
SH
  cat > "$FIX_BIN/git" <<'SH'
#!/bin/sh
# Minimal git shape: clone, -C rev-parse, -C remote get-url origin.
if [ "${1:-}" = clone ]; then
  url=$2; dir=$3
  mkdir -p "$dir/.git" "$dir/bin"
  printf '%s\n' "$url" > "$dir/.git/origin"
  # The clone carries the tracked entrypoint the symlink step points at, so
  # the fresh-PATH probe resolves exactly as on a real host.
  printf '#!/bin/sh\nexit 0\n' > "$dir/bin/fm-remote-entrypoint.sh"
  chmod +x "$dir/bin/fm-remote-entrypoint.sh"
  cat > "$dir/bin/fm-remote-doctor.sh" <<'DOCTOR'
#!/bin/sh
if [ "${1:-}" = --fix ]; then echo "fix remote-job-worker=applied: test worker"; fi
echo "platform=linux"
echo "check herdr-server=ok: test"
echo "ok: remote second-mate readiness confirmed on this host"
exit "${FAKE_DOCTOR_RC:-0}"
DOCTOR
  chmod +x "$dir/bin/fm-remote-doctor.sh"
  exit 0
fi
if [ "${1:-}" = -C ]; then
  dir=$2; shift 2
  case "${1:-}" in
    rev-parse) [ -d "$dir/.git" ] && { printf 'true\n'; exit 0; }; exit 128 ;;
    remote) cat "$dir/.git/origin" 2>/dev/null || exit 128 ;;
  esac
  exit 0
fi
printf 'git stub 1.0\n'
SH
  cat > "$FIX_BIN/curl" <<'SH'
#!/bin/sh
# Emulates `curl -fsSL <url> | sh`: prints an installer that drops one stub
# binary into the remote account's .local/bin.
url=
for a in "$@"; do case "$a" in -*) ;; *) url=$a ;; esac; done
case "$url" in
  *herdr.dev*) tool=herdr; ver="herdr version 0.8.2" ;;
  *treehouse*) tool=treehouse; ver="v2.3.0" ;;
  *opencode.ai*) tool=opencode; ver="opencode 1.18.20" ;;
  *) printf 'curl stub: unknown url %s\n' "$url" >&2; exit 22 ;;
esac
printf 'mkdir -p "$HOME/.local/bin"\n'
printf 'printf "#!/bin/sh\\necho \\"%s\\"\\n" > "$HOME/.local/bin/%s"\n' "$ver" "$tool"
printf 'chmod +x "$HOME/.local/bin/%s"\n' "$tool"
SH
  cat > "$FIX_BIN/npm" <<'SH'
#!/bin/sh
# Emulates global installs and the router source builds.
if [ "${1:-}" = install ] && [ "${2:-}" = -g ]; then
  shift 2
  prefix=; pkg=
  for a in "$@"; do
    if [ -n "${want_prefix:-}" ]; then prefix=$a; want_prefix=; continue; fi
    case "$a" in --prefix) want_prefix=1 ;; --prefix=*) prefix=${a#--prefix=} ;; -*) ;; *) pkg=$a ;; esac
  done
  if [ "$pkg" = . ]; then
    # `npm install -g --prefix X .` inside a repo dir: name the binary for it.
    pkg=$(basename "$PWD")
    dest=$prefix/bin
    mkdir -p "$dest"
    case "$pkg" in
      llm-router-axi)
        cat > "$dest/llm-router-axi" <<'ROUTER'
#!/bin/sh
if [ "${1:-}" = policy ]; then echo "policy:"; echo "  valid: true"; exit 0; fi
if [ "${1:-}" = classify ]; then printf '{"source": "fallback", "reason": "no TYPESAFE_API_KEY in the environment"}\n'; exit 0; fi
if [ "${1:-}" = doctor ]; then echo "router ok"; exit 0; fi
exit 0
ROUTER
        chmod +x "$dest/llm-router-axi" ;;
      *) printf '#!/bin/sh\nexit 0\n' > "$dest/$pkg"; chmod +x "$dest/$pkg" ;;
    esac
    exit 0
  fi
  # A bare `npm install -g` without a prefix always fails here, emulating a
  # non-root account, so the script's user-local prefix fallback is exercised
  # and the runner's own filesystem is never touched.
  dest=${prefix:-/usr/local}/bin
  [ -n "$prefix" ] || exit 1
  mkdir -p "$dest" 2>/dev/null || exit 1
  printf '#!/bin/sh\necho "%s stub 1.0"\n' "${pkg:-unknown}" > "$dest/${pkg:-unknown}" || exit 1
  chmod +x "$dest/${pkg:-unknown}"
  exit 0
fi
if [ "${1:-}" = ci ]; then exit 0; fi
if [ "${1:-}" = run ]; then exit 0; fi
exit 0
SH
  chmod +x "$FIX_BIN"/uname "$FIX_BIN"/id "$FIX_BIN"/sudo "$FIX_BIN"/apt-get \
    "$FIX_BIN"/git "$FIX_BIN"/curl "$FIX_BIN"/npm

  cat > "$FIX_DIR/fake-ssh" <<'SH'
#!/bin/sh
# Stub SSH transport: parses ssh flags, then runs the remote command with the
# fixture HOME and tool bin. FAKE_POWERSHELL=1 emulates a Windows landing.
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift # alias
if [ "${FAKE_POWERSHELL:-0}" = 1 ]; then
  printf "'printf' is not recognized as an internal or external command.\nHOME=C:\\Users\\Adi\n"
  exit 0
fi
cmd="$*"
HOME="$FM_FIX_HOME" FAKE_DOCTOR_RC="${FAKE_DOCTOR_RC:-0}" \
  PATH="$FM_FIX_HOME/.local/bin:$FM_FIX_BIN:/usr/bin:/bin" sh -c "$cmd"
SH
  chmod +x "$FIX_DIR/fake-ssh"
  export FM_FIX_HOME="$FIX_HOME" FM_FIX_BIN="$FIX_BIN"
}

run_bootstrap() { # <fixture> [extra args...]; prints output, returns status
  local fix=$1; shift
  local run_home=${RUN_BOOTSTRAP_HOME:-$TMP_ROOT/$fix/localhome}
  mkdir -p "$run_home"
  FM_SSH_BIN="$TMP_ROOT/$fix/fake-ssh" FM_SSH_CONNECT_TIMEOUT=5 \
    FM_FIX_HOME="$TMP_ROOT/$fix/home" FM_FIX_BIN="$TMP_ROOT/$fix/bin" \
    HOME="$run_home" \
    "$BOOTSTRAP" testalias --fork "$FORK" "$@"
}

# 1. usage and validation need no transport.
OUT=$("$BOOTSTRAP" 2>&1); RC=$?
expect_code 2 "$RC" "bare invocation exits 2"
OUT=$("$BOOTSTRAP" 'bad alias!' --fork "$FORK" 2>&1); RC=$?
expect_code 2 "$RC" "unsafe alias exits 2"
OUT=$("$BOOTSTRAP" testalias --code-root relative/path --fork "$FORK" 2>&1); RC=$?
expect_code 2 "$RC" "relative code root exits 2"
OUT=$("$BOOTSTRAP" testalias --code-root '/x/../y' --fork "$FORK" 2>&1); RC=$?
expect_code 2 "$RC" "traversal code root exits 2"
OUT=$("$BOOTSTRAP" testalias --fork 'not a url' 2>&1); RC=$?
expect_code 2 "$RC" "invalid fork exits 2"

# 2. PowerShell landing is refused with operator guidance.
new_fixture powershell
OUT=$(FAKE_POWERSHELL=1 run_bootstrap powershell 2>&1); RC=$?
expect_code 1 "$RC" "powershell landing exits 1"
assert_contains "$OUT" "PowerShell" "powershell landing names the cause"

# 3. Dry run changes nothing but reports what would change.
new_fixture dry
OUT=$(run_bootstrap dry --dry-run 2>&1); RC=$?
expect_code 0 "$RC" "dry run exits 0"
assert_contains "$OUT" "WOULD CHANGE" "dry run reports pending steps"
assert_absent "$TMP_ROOT/dry/home/firstmate" "dry run clones nothing"
assert_absent "$TMP_ROOT/dry/home/.local/bin/fm-remote-entrypoint.sh" "dry run links nothing"
assert_absent "$TMP_ROOT/dry/home/.config/llm-router-axi/policy.json" "dry run writes no policy"

# 4. Full run on a bare host installs everything and ends at the doctor.
new_fixture bare
OUT=$(run_bootstrap bare 2>&1); RC=$?
expect_code 0 "$RC" "bare host run exits 0"
assert_contains "$OUT" "INSTALLED" "bare host run reports installs"
assert_contains "$OUT" "station is ready" "bare host run reports readiness"
assert_contains "$OUT" "source: fallback" "router fallback probe is reported"
assert_present "$TMP_ROOT/bare/home/firstmate/.git" "fork is cloned"
assert_contains "$(cat "$TMP_ROOT/bare/home/firstmate/.git/origin")" "$FORK" "clone uses the fork URL"
LINK=$(readlink "$TMP_ROOT/bare/home/.local/bin/fm-remote-entrypoint.sh")
assert_equals "$TMP_ROOT/bare/home/firstmate/bin/fm-remote-entrypoint.sh" "$LINK" "entrypoint links at the code root"
for tool in herdr tasks-axi treehouse opencode llm-router-axi usage-axi; do
  assert_present "$TMP_ROOT/bare/home/.local/bin/$tool" "$tool resolves user-locally"
done
# jq and python3 may legitimately resolve from the host system PATH instead of
# user-local installs; what matters is that the script leaves them resolving.
JQ_PROBE=$(FM_SSH_BIN="$TMP_ROOT/bare/fake-ssh" FM_FIX_HOME="$TMP_ROOT/bare/home" \
  FM_FIX_BIN="$TMP_ROOT/bare/bin" "$TMP_ROOT/bare/fake-ssh" testalias 'command -v jq')
assert_not_equals "" "$JQ_PROBE" "jq resolves on the host"
POLICY="$TMP_ROOT/bare/home/.config/llm-router-axi/policy.json"
assert_present "$POLICY" "router policy is written"
assert_grep '"enabled":true' "$POLICY" "policy enables jev shadow"

# 5. Rerun is idempotent: everything skipped, nothing reinstalled.
OUT=$(run_bootstrap bare 2>&1); RC=$?
expect_code 0 "$RC" "rerun exits 0"
assert_contains "$OUT" "OK (already present)" "rerun skips satisfied steps"
assert_not_contains "$OUT" "INSTALLED" "rerun installs nothing"
assert_not_contains "$OUT" "OPERATOR NEEDED" "rerun opens no gaps"

# 6. A foreign directory at the code root is a gap, never clobbered.
new_fixture foreign
mkdir -p "$TMP_ROOT/foreign/home/firstmate"
OUT=$(run_bootstrap foreign --dry-run 2>&1); RC=$?
expect_code 0 "$RC" "foreign root dry run exits 0"
assert_contains "$OUT" "WOULD CHANGE" "foreign root dry run still reports other steps"
OUT=$(FAKE_DOCTOR_RC=0 run_bootstrap foreign 2>&1); RC=$?
expect_code 1 "$RC" "foreign root exits 1"
assert_contains "$OUT" "OPERATOR NEEDED" "foreign root opens an operator gap"
assert_absent "$TMP_ROOT/foreign/home/firstmate/.git" "foreign root is never clobbered"

# 7. A foreign file at the entrypoint path is a gap, never overwritten.
new_fixture linkforeign
mkdir -p "$TMP_ROOT/linkforeign/home/.local/bin"
printf '#!/bin/sh\necho foreign\n' > "$TMP_ROOT/linkforeign/home/.local/bin/fm-remote-entrypoint.sh"
OUT=$(run_bootstrap linkforeign 2>&1); RC=$?
expect_code 1 "$RC" "foreign entrypoint exits 1"
assert_contains "$OUT" "OPERATOR NEEDED" "foreign entrypoint opens an operator gap"
assert_contains "$(cat "$TMP_ROOT/linkforeign/home/.local/bin/fm-remote-entrypoint.sh")" "foreign" "foreign entrypoint is never overwritten"

# 8. Doctor failure propagates even when every step applied.
new_fixture sickdoc
OUT=$(FAKE_DOCTOR_RC=1 run_bootstrap sickdoc 2>&1); RC=$?
expect_code 1 "$RC" "failing doctor exits 1"
assert_contains "$OUT" "doctor still reports gaps" "doctor failure names the cause"

# 9. Local policy is mirrored, never invented: shadow forced on, lanes kept.
new_fixture mirror
LOCAL_HOME="$TMP_ROOT/mirror-local"
mkdir -p "$LOCAL_HOME/.config/llm-router-axi"
printf '{"version":1,"marker":"local-shape","candidateGroups":{"workers":[]},"jev":{"shadow":{"enabled":false}}}\n' \
  > "$LOCAL_HOME/.config/llm-router-axi/policy.json"
OUT=$(RUN_BOOTSTRAP_HOME="$LOCAL_HOME" run_bootstrap mirror 2>&1); RC=$?
expect_code 0 "$RC" "mirror run exits 0"
MIRRORED="$TMP_ROOT/mirror/home/.config/llm-router-axi/policy.json"
assert_grep '"marker": "local-shape"' "$MIRRORED" "mirrored policy keeps the local shape"
assert_grep '"enabled": true' "$MIRRORED" "mirrored policy forces shadow on"

pass "fm-station-bootstrap"
