#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-update-window.sh.
#
# A stub no-mistakes stands in for the real CLI: the live update is never safe
# to run in CI or casually, so every case here drives argument parsing, the
# already-current short-circuit, the retry loop, delegation, and verification
# against the stub. The exact refusal text of a busy real daemon and the remote
# path against a real host stay untested pending a supervised run, as the
# script header owns.
set -u
# shellcheck disable=SC1091

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-nm-update-window.sh"

# make_stub <initial-version>: builds a stub no-mistakes plus its state dir
# and echoes the state dir. The stub reads its behavior from that dir:
#   version          current version answered to --version (rewritten on update)
#   fails-remaining  update refusals left before update succeeds
#   argv.log         every stub invocation's argv, one line per call
#   target           version the stub installs on a successful update
#   doctor-fail      when present, `doctor` exits non-zero
# Each case exports NM_STUB_DIR and NO_MISTAKES_BIN at the stub after building
# it, so the script under test always talks to that case's stub.
make_stub() {
  local dir stub
  dir=$(fm_test_tmproot fm-nm-stub) || fail "tmproot failed"
  mkdir -p "$dir/fakebin"
  printf '%s\n' "$1" > "$dir/version"
  printf '0\n' > "$dir/fails-remaining"
  : > "$dir/argv.log"
  stub="$dir/fakebin/no-mistakes"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
set -u
: "${NM_STUB_DIR:?stub needs NM_STUB_DIR}"
printf '%s\n' "$*" >> "$NM_STUB_DIR/argv.log"
case "${1:-}" in
  --version)
    printf 'no-mistakes version v%s (stub) 2026-01-01T00:00:00Z\n' "$(cat "$NM_STUB_DIR/version")"
    ;;
  update)
    remaining=$(cat "$NM_STUB_DIR/fails-remaining")
    if [ "$remaining" -gt 0 ]; then
      printf '%s\n' "$((remaining - 1))" > "$NM_STUB_DIR/fails-remaining"
      printf 'refusing: 2 pipeline runs are active (stub); use --force to override\n'
      exit 1
    fi
    printf '%s\n' "$(cat "$NM_STUB_DIR/target")" > "$NM_STUB_DIR/version"
    printf 'updated to %s (stub)\n' "$(cat "$NM_STUB_DIR/target")"
    ;;
  daemon)
    printf 'running (stub)\n'
    ;;
  doctor)
    if [ -e "$NM_STUB_DIR/doctor-fail" ]; then
      printf 'stub: doctor found a problem\n'
      exit 1
    fi
    printf 'all green (stub)\n'
    ;;
  *)
    printf 'stub: unknown command %s\n' "${1:-}" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$stub"
  printf '%s\n' "$dir"
}

use_stub() {
  export NM_STUB_DIR="$1" NO_MISTAKES_BIN="$1/fakebin/no-mistakes"
}

# --- argument parsing ---------------------------------------------------------

out=$("$SCRIPT" --help 2>&1); code=$?
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" "fm-nm-update-window.sh" "--help names the script"

out=$("$SCRIPT" local --bogus 2>&1); code=$?
[ "$code" -ne 0 ] || fail "unknown flag must fail"
pass "unknown flag fails"

out=$("$SCRIPT" local --max-wait abc 2>&1); code=$?
[ "$code" -ne 0 ] || fail "non-numeric --max-wait must fail"
out=$("$SCRIPT" local --max-wait -5 2>&1); code=$?
[ "$code" -ne 0 ] || fail "negative --max-wait must fail"
out=$("$SCRIPT" local --interval 0 2>&1); code=$?
[ "$code" -ne 0 ] || fail "zero --interval must fail"
out=$("$SCRIPT" local --target beta 2>&1); code=$?
[ "$code" -ne 0 ] || fail "non-version --target must fail"
out=$("$SCRIPT" local a b 2>&1); code=$?
[ "$code" -ne 0 ] || fail "two routes must fail"
pass "invalid arguments fail"

# --- already-current short-circuit --------------------------------------------

dir=$(make_stub 1.80.1)
printf '1.80.1\n' > "$dir/target"
use_stub "$dir"
out=$("$SCRIPT" local --target 1.80.1 2>&1); code=$?
expect_code 0 "$code" "already-current exits 0"
assert_contains "$out" "already current" "already-current reports itself"
assert_no_grep "update --beta" "$dir/argv.log" "already-current never invokes update"
pass "already-current short-circuits"

dir=$(make_stub 1.81.0)
printf '1.80.1\n' > "$dir/target"
use_stub "$dir"
out=$("$SCRIPT" local --target 1.80.1 2>&1); code=$?
expect_code 0 "$code" "newer-than-target exits 0"
assert_contains "$out" "already current" "newer-than-target reports already current"
assert_no_grep "update --beta" "$dir/argv.log" "newer-than-target never invokes update"
pass "newer version is already current"

# --- retry until a quiet window, then verify -----------------------------------

dir=$(make_stub 1.79.0)
printf '1.80.1\n' > "$dir/target"
printf '2\n' > "$dir/fails-remaining"
use_stub "$dir"
out=$("$SCRIPT" local --target 1.80.1 --max-wait 30 --interval 1 2>&1); code=$?
expect_code 0 "$code" "eventual success exits 0"
assert_contains "$out" "updated: 1.79.0 -> 1.80.1" "success reports the version change"
assert_contains "$out" "doctor: ok" "success reports doctor green"
assert_grep "update --beta" "$dir/argv.log" "update is attempted with --beta"
assert_no_grep "--force" "$dir/argv.log" "no invocation ever passes --force"
pass "refused attempts retry until success"

# --- max-wait exceeded surfaces the refusal -------------------------------------

dir=$(make_stub 1.79.0)
printf '1.80.1\n' > "$dir/target"
printf '99\n' > "$dir/fails-remaining"
use_stub "$dir"
out=$("$SCRIPT" local --target 1.80.1 --max-wait 3 --interval 1 2>&1); code=$?
[ "$code" -ne 0 ] || fail "exhausted max-wait must fail"
assert_contains "$out" "max-wait 3s exceeded" "timeout names the bound"
assert_contains "$out" "2 pipeline runs are active (stub)" "timeout surfaces the refusal verbatim"
assert_no_grep "--force" "$dir/argv.log" "timeout path never passes --force"
pass "max-wait expiry reports the blocker"

# --- failed verification fails distinctly ---------------------------------------

dir=$(make_stub 1.79.0)
printf '1.80.1\n' > "$dir/target"
: > "$dir/doctor-fail"
use_stub "$dir"
out=$("$SCRIPT" local --target 1.80.1 --max-wait 10 --interval 1 2>&1); code=$?
[ "$code" -ne 0 ] || fail "red doctor must fail"
assert_contains "$out" "doctor is not all-green" "red doctor is reported as verification failure"
pass "failed doctor fails the run"

# --- missing binary fails fast ---------------------------------------------------

export NO_MISTAKES_BIN=/nonexistent/no-mistakes
out=$("$SCRIPT" local --target 1.80.1 2>&1); code=$?
[ "$code" -ne 0 ] || fail "missing binary must fail"
assert_contains "$out" "not executable" "missing binary names the problem"
pass "missing binary fails fast"

# --- remote delegation ------------------------------------------------------------

rdir=$(fm_test_tmproot fm-nm-on) || fail "tmproot failed"
cat > "$rdir/fm-on.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$@" > "${FM_NM_ON_ARGSFILE:?needs FM_NM_ON_ARGSFILE}"
exit "${FM_NM_ON_EXIT:-0}"
SH
chmod +x "$rdir/fm-on.sh"

dir=$(make_stub 1.79.0)
use_stub "$dir"
export FM_NM_UPDATE_WINDOW_FM_ON="$rdir/fm-on.sh"
export FM_NM_ON_ARGSFILE="$rdir/args"
export FM_NM_ON_EXIT=0
out=$("$SCRIPT" adi1 --max-wait 120 --target 1.80.1 --interval 45 2>&1); code=$?
expect_code 0 "$code" "delegation passes through the remote exit code"
assert_grep "adi1" "$rdir/args" "delegation keeps the route first"
assert_grep "fm-nm-update-window.sh" "$rdir/args" "delegation names this script"
assert_grep "--max-wait" "$rdir/args" "delegation forwards flags"
assert_no_grep "update --beta" "$dir/argv.log" "delegation runs nothing locally"
[ "$(head -n 1 "$rdir/args")" = "adi1" ] || fail "route must be the first remote argument"
pass "named route delegates through fm-on"

export FM_NM_ON_EXIT=3
"$SCRIPT" adi1 >/dev/null 2>&1; code=$?
expect_code 3 "$code" "remote failure exit code passes through"
pass "remote exit code passes through"

printf 'ok - fm-nm-update-window\n'
