#!/usr/bin/env bash
# tests/fm-install-ocr.test.sh - unit tests for bin/fm-install-ocr.sh, the
# npm-based installer for `ocr` (bin/fm-review.sh's required dependency).
# Fakes `npm` so no network call and no real ocr install are required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-ocr.sh"

TMP_ROOT=$(fm_test_tmproot fm-install-ocr)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# A curated PATH that resolves every real tool except `npm`, so the
# "missing required tool" case does not depend on this host happening to lack
# npm, and does not accidentally hide bash/mkdir/ln too.
NO_NPM_PATH=$(fm_test_base_path_sans "$PATH" npm)

# fake_npm writes a fake `npm` into FAKEBIN. On `install --global --prefix
# <dir> <pkg>` it logs the invocation to $TMP_ROOT/npm.log, then either fails
# with $NPM_FAKE_INSTALL_EXIT (if nonzero), skips producing the bin shim (if
# NPM_FAKE_SKIP_BIN=1), or drops a working `<prefix>/bin/ocr` shim that prints
# a canned version string on --version - simulating a real npm global install.
fake_npm() {
  cat > "$FAKEBIN/npm" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$NPM_LOG"
if [ "${1:-}" = install ]; then
  shift
  prefix=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) prefix=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "${NPM_FAKE_INSTALL_EXIT:-}" ] && [ "${NPM_FAKE_INSTALL_EXIT}" != 0 ]; then
    echo "fake npm: simulated install failure" >&2
    exit "${NPM_FAKE_INSTALL_EXIT}"
  fi
  if [ "${NPM_FAKE_SKIP_BIN:-}" = 1 ]; then
    exit 0
  fi
  mkdir -p "$prefix/bin"
  cat > "$prefix/bin/ocr" <<'INNER'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  echo "fake-ocr 0.0.0-test"
  exit 0
fi
exit 0
INNER
  chmod +x "$prefix/bin/ocr"
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKEBIN/npm"
}

run_installer() {
  PATH="$FAKEBIN:$PATH" NPM_LOG="$TMP_ROOT/npm.log" "$INSTALLER" "$@"
}

# --- missing dependency -------------------------------------------------------

OUT=$(PATH="$NO_NPM_PATH" "$INSTALLER" "$TMP_ROOT/missing-npm-dest" 2>&1) && fail "must fail with npm missing from PATH"
assert_contains "$OUT" "npm is required" "must name the missing required tool"
pass "fm-install-ocr.sh refuses to run when npm is missing from PATH"

# --- install failure -----------------------------------------------------------

fake_npm
: > "$TMP_ROOT/npm.log"
DEST="$TMP_ROOT/install-fail-dest"
OUT=$(NPM_FAKE_INSTALL_EXIT=1 run_installer "$DEST" 2>&1) && fail "must fail when npm install fails"
assert_contains "$OUT" "npm install" "failure must name the failed npm install step"
assert_contains "$OUT" "failed" "failure must report the npm install failure"
[ ! -e "$DEST/ocr" ] || fail "installer produced an ocr entry after a failed npm install"
pass "fm-install-ocr.sh reports a failed npm install and installs nothing"

# --- npm succeeds but produces no bin ------------------------------------------

: > "$TMP_ROOT/npm.log"
DEST="$TMP_ROOT/no-bin-dest"
OUT=$(NPM_FAKE_SKIP_BIN=1 run_installer "$DEST" 2>&1) && fail "must fail when npm produces no ocr bin"
assert_contains "$OUT" "was not produced" "failure must report the missing produced binary"
[ ! -e "$DEST/ocr" ] || fail "installer produced an ocr entry when npm never produced one"
pass "fm-install-ocr.sh fails closed when npm install completes without producing an ocr binary"

# --- successful install, absolute destination ----------------------------------

: > "$TMP_ROOT/npm.log"
DEST="$TMP_ROOT/abs-dest"
OUT=$(run_installer "$DEST" 2>&1) || fail "installer failed for a successful absolute-destination install"$'\n'"$OUT"
assert_contains "$OUT" "fake-ocr 0.0.0-test" "installer's own smoke test did not print the installed version"
[ -L "$DEST/ocr" ] || fail "installer did not create ocr as a symlink at the destination"
[ -x "$DEST/ocr" ] || fail "installed ocr is not executable"
[ "$("$DEST/ocr" --version)" = "fake-ocr 0.0.0-test" ] \
  || fail "installed ocr symlink does not resolve to a working binary"
pass "fm-install-ocr.sh installs a working ocr symlink for an absolute destination"

# --- successful install, relative destination (regression: broken symlink) ----

: > "$TMP_ROOT/npm.log"
mkdir -p "$TMP_ROOT/relwork"
REL_DEST="rel-dest"
OUT=$(cd "$TMP_ROOT/relwork" && PATH="$FAKEBIN:$PATH" NPM_LOG="$TMP_ROOT/npm.log" "$INSTALLER" "$REL_DEST" 2>&1) \
  || fail "installer failed for a successful relative-destination install"$'\n'"$OUT"
assert_contains "$OUT" "fake-ocr 0.0.0-test" \
  "installer's own smoke test did not print the installed version for a relative destination"
ABS_DEST="$TMP_ROOT/relwork/$REL_DEST"
[ -L "$ABS_DEST/ocr" ] || fail "installer did not create ocr as a symlink for a relative destination"
LINK_TARGET=$(readlink "$ABS_DEST/ocr")
case "$LINK_TARGET" in
  /*) ;;
  *) fail "ocr symlink target is not absolute, got: $LINK_TARGET" ;;
esac
[ "$("$ABS_DEST/ocr" --version)" = "fake-ocr 0.0.0-test" ] \
  || fail "installed ocr symlink for a relative destination does not resolve to a working binary"
# The regression itself: resolving the symlink from a different cwd than the
# one the installer ran in must still work, which only holds for an absolute
# symlink target.
OUT2=$(cd "$TMP_ROOT" && "$ABS_DEST/ocr" --version) \
  || fail "ocr symlink installed via a relative destination breaks when resolved from a different cwd"
[ "$OUT2" = "fake-ocr 0.0.0-test" ] \
  || fail "ocr symlink resolved from a different cwd produced unexpected output: $OUT2"
pass "fm-install-ocr.sh installs a working, absolute-target ocr symlink even for a relative destination argument"

echo "# fm-install-ocr.test.sh: all assertions passed"
