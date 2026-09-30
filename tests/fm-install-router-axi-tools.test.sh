#!/usr/bin/env bash
# tests/fm-install-router-axi-tools.test.sh - contract tests for
# bin/fm-install-router-axi-tools.sh, the pinned builder for the two unpublished
# workflow tools that own machine-capacity admission.
#
# Fakes git and npm so no network clone and no real npm build/install run. The
# fake git refuses to fabricate a checkout unless the installer actually fetched
# a commit first, and the fake npm records every pack and install, so the tests
# prove the pinned build-and-install sequence rather than a stub of it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-router-axi-tools.sh"
LLM_SHA=bf42cff713ce8501301663a8377f4d6bca7c3881
USAGE_SHA=b140738e6bf074f280aca46dc48a3339e8ef1f6d

TMP_ROOT=$(fm_test_tmproot fm-install-router-axi-tools)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# fake_git simulates only the porcelain the installer uses. A checkout only
# succeeds after a matching fetch recorded that commit, so an installer that
# skipped the pinned fetch cannot pass.
fake_git() {
  cat > "$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
set -u
state_dir=
if [ "${1:-}" = "-C" ]; then state_dir=$2; shift 2; fi
sub=${1:-}
case "$sub" in
  init)
    mkdir -p "${@: -1}/.fakegit" ;;
  remote)
    mkdir -p "$state_dir/.fakegit"
    printf '%s\n' "${4:-}" > "$state_dir/.fakegit/origin" ;;
  fetch)
    mkdir -p "$state_dir/.fakegit"
    printf '%s\n' "${@: -1}" > "$state_dir/.fakegit/fetched"
    printf 'fetch %s\n' "${@: -1}" >> "${FAKE_GIT_LOG:-/dev/null}" ;;
  checkout)
    [ -f "$state_dir/.fakegit/fetched" ] || { echo "fake git: checkout without fetch" >&2; exit 1; }
    origin=$(cat "$state_dir/.fakegit/origin")
    case "$origin" in
      *llm-router-axi*) name=llm-router-axi; version=0.1.0 ;;
      *usage-axi*) name=usage-axi; version=0.1.1 ;;
      *) name=unknown; version=0.0.0 ;;
    esac
    printf '{"name":"%s","version":"%s"}\n' "$name" "$version" > "$state_dir/package.json" ;;
  rev-parse)
    if [ -n "${FAKE_GIT_HEAD_SHA:-}" ]; then printf '%s\n' "$FAKE_GIT_HEAD_SHA"; else cat "$state_dir/.fakegit/fetched"; fi ;;
  *) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/git"
}

# fake_npm simulates ci/build/pack/install. pack reads the package written by
# the fake git checkout, and install creates a bin shim printing that version,
# optionally overridden by NPM_FAKE_WRONG_VERSION to exercise the version guard.
fake_npm() {
  cat > "$FAKEBIN/npm" <<'EOF'
#!/usr/bin/env bash
set -u
sub=${1:-}
case "$sub" in
  ci) mkdir -p node_modules; exit 0 ;;
  run) mkdir -p dist; exit 0 ;;
  pack)
    dest=
    while [ "$#" -gt 0 ]; do
      case "$1" in --pack-destination) dest=$2; shift 2 ;; *) shift ;; esac
    done
    name=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json)
    version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json)
    printf 'fake package\n' > "$dest/$name-$version.tgz"
    printf '%s\n' "$name-$version.tgz"
    exit 0 ;;
  install)
    prefix=; tarball=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -g|--global) shift ;;
        --prefix) prefix=$2; shift 2 ;;
        *) tarball=$1; shift ;;
      esac
    done
    base=$(basename "$tarball" .tgz)
    name=${base%-*}
    version=${base##*-}
    [ -z "${NPM_FAKE_WRONG_VERSION:-}" ] || version=$NPM_FAKE_WRONG_VERSION
    mkdir -p "$prefix/bin" "$prefix/lib/node_modules/$name"
    printf '#!/usr/bin/env bash\necho %s\n' "$version" > "$prefix/bin/$name"
    chmod +x "$prefix/bin/$name"
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$FAKEBIN/npm"
}

run_installer() {
  PATH="$FAKEBIN:$PATH" FAKE_GIT_LOG="$TMP_ROOT/git.log" "$INSTALLER" "$@"
}

# --- cache key ----------------------------------------------------------------

KEY=$(run_installer --print-cache-key) || fail "--print-cache-key must exit 0"
case "$KEY" in
  llm-router-axi-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-usage-axi-*) ;;
  *) fail "--print-cache-key did not derive a stable key from the pins: $KEY" ;;
esac
pass "fm-install-router-axi-tools.sh prints a cache key derived from both pinned commits"

# --- help ---------------------------------------------------------------------

HELP=$("$INSTALLER" --help 2>&1) || fail "--help must exit 0"
assert_contains "$HELP" "fm-install-router-axi-tools.sh" "--help must print the usage header"
assert_contains "$HELP" "destination-prefix" "--help must name the destination argument"
pass "fm-install-router-axi-tools.sh --help prints its usage header"

# --- missing required tools ---------------------------------------------------

NO_GIT_PATH=$(fm_test_base_path_sans "$PATH" git)
OUT=$(PATH="$NO_GIT_PATH" "$INSTALLER" "$TMP_ROOT/no-git" 2>&1) && fail "must fail when git is missing"
assert_contains "$OUT" "git is required" "must name the missing git tool"
pass "fm-install-router-axi-tools.sh refuses when git is missing"

NO_NPM_PATH=$(fm_test_base_path_sans "$PATH" npm)
OUT=$(PATH="$NO_NPM_PATH" "$INSTALLER" "$TMP_ROOT/no-npm" 2>&1) && fail "must fail when npm is missing"
assert_contains "$OUT" "npm is required" "must name the missing npm tool"
pass "fm-install-router-axi-tools.sh refuses when npm is missing"

# --- successful pinned build and install -------------------------------------

fake_git
fake_npm
DEST="$TMP_ROOT/installed"
: > "$TMP_ROOT/git.log"
if ! OUT=$(run_installer "$DEST" 2>"$TMP_ROOT/install.err"); then
  cat "$TMP_ROOT/install.err" >&2
  fail "installer failed for a fresh destination"
fi
assert_contains "$(cat "$TMP_ROOT/install.err")" "building llm-router-axi 0.1.0" "must build llm-router-axi at its pin"
assert_contains "$(cat "$TMP_ROOT/install.err")" "building usage-axi 0.1.1" "must build usage-axi at its pin"
printf '%s\n' "$OUT" | tail -n 2 | grep -Fxq "0.1.0" || fail "installer did not print the llm-router-axi version last: $OUT"
printf '%s\n' "$OUT" | tail -n 1 | grep -Fxq "0.1.1" || fail "installer did not print the usage-axi version last: $OUT"
[ -x "$DEST/bin/llm-router-axi" ] || fail "llm-router-axi was not installed to <prefix>/bin"
[ -x "$DEST/bin/usage-axi" ] || fail "usage-axi was not installed to <prefix>/bin"
[ "$("$DEST/bin/llm-router-axi" --version)" = "0.1.0" ] || fail "installed llm-router-axi reports the wrong version"
[ "$("$DEST/bin/usage-axi" --version)" = "0.1.1" ] || fail "installed usage-axi reports the wrong version"
pass "fm-install-router-axi-tools.sh builds and installs both pinned tools"

# The installer must fetch each repo at the exact pinned commit, not a branch.
for sha in "$LLM_SHA" "$USAGE_SHA"; do
  grep -Fxq "fetch $sha" "$TMP_ROOT/git.log" \
    || fail "installer did not fetch the pinned commit $sha: $(cat "$TMP_ROOT/git.log" 2>/dev/null)"
done
pass "fm-install-router-axi-tools.sh fetches both repos at the pinned commits"

# --- idempotent cache-hit skip -------------------------------------------------

cat > "$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
echo "fake git: must not run on a satisfied prefix" >&2
exit 99
EOF
chmod +x "$FAKEBIN/git"
cat > "$FAKEBIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "fake npm: must not run on a satisfied prefix" >&2
exit 99
EOF
chmod +x "$FAKEBIN/npm"
if ! OUT=$(run_installer "$DEST" 2>"$TMP_ROOT/skip.err"); then
  cat "$TMP_ROOT/skip.err" >&2
  fail "a satisfied prefix must skip the build, not fail"
fi
assert_contains "$(cat "$TMP_ROOT/skip.err")" "already installed, skipping build" "cache hit must report the skip"
printf '%s\n' "$OUT" | tail -n 1 | grep -Fxq "0.1.1" || fail "cache hit must still print the installed versions: $OUT"
pass "fm-install-router-axi-tools.sh skips the build when the pinned version already exists"

# --- wrong fetched commit -----------------------------------------------------

fake_git
fake_npm
OUT=$(PATH="$FAKEBIN:$PATH" FAKE_GIT_HEAD_SHA=0000000000000000000000000000000000000000 \
  "$INSTALLER" "$TMP_ROOT/wrong-sha" 2>&1) \
  && fail "must fail when the checked-out commit is not the pin"
assert_contains "$OUT" "expected pinned" "must report the mismatched commit"
pass "fm-install-router-axi-tools.sh fails closed on a mismatched fetched commit"

# --- wrong installed version --------------------------------------------------

OUT=$(PATH="$FAKEBIN:$PATH" NPM_FAKE_WRONG_VERSION=9.9.9 \
  "$INSTALLER" "$TMP_ROOT/wrong-version" 2>&1) \
  && fail "must fail when the installed tool reports the wrong version"
assert_contains "$OUT" "expected exact pin" "must report the wrong installed version"
pass "fm-install-router-axi-tools.sh fails closed on a wrong installed version"

echo "# fm-install-router-axi-tools.test.sh: all assertions passed"
