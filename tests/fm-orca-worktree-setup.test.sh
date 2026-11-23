#!/usr/bin/env bash
# tests/fm-orca-worktree-setup.test.sh - Orca worktree setup and archive helpers.
# Runs both scripts inside an isolated temporary Git repo and linked worktree.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="$ROOT/scripts/orca-worktree-setup.sh"
ARCHIVE="$ROOT/scripts/orca-worktree-archive.sh"
ORCA_YAML="$ROOT/orca.yaml"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-orca-wt-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() {  # <label> <command...>
  local label=$1
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

# --- orca.yaml contract -----------------------------------------------------
check "orca.yaml exists" test -f "$ORCA_YAML"
check "orca.yaml setup script" grep -q 'setup: bash scripts/orca-worktree-setup.sh' "$ORCA_YAML"
check "orca.yaml archive script" grep -q 'archive: bash scripts/orca-worktree-archive.sh' "$ORCA_YAML"
check "orca.yaml wait-for-setup" grep -q 'setupAgentStartupPolicy: wait-for-setup' "$ORCA_YAML"
check "scripts executable" test -x "$SETUP" -a -x "$ARCHIVE"
no_users() {
  local needle="/Us""ers/"
  test -f "$ORCA_YAML" -a -f "$SETUP" -a -f "$ARCHIVE" || return 1
  ! grep -q "$needle" "$ORCA_YAML" "$SETUP" "$ARCHIVE"
}
check "no hardcoded home paths" no_users

# --- isolated repo + linked worktree ---------------------------------------
MAIN="$TMP/main"
WT="$TMP/linked"
git init -q "$MAIN"
git -C "$MAIN" config user.email test@example.invalid
git -C "$MAIN" config user.name test
printf 'keep\n' >"$MAIN/tracked.txt"
git -C "$MAIN" add tracked.txt
git -C "$MAIN" commit -q -m init
git -C "$MAIN" worktree add -q -b linked "$WT"

for d in data state config projects; do
  mkdir -p "$WT/$d/__pycache__"
  printf 'private\n' >"$WT/$d/secret.txt"
  printf 'x\n' >"$WT/$d/__pycache__/m.pyc"
done
before=$(cd "$WT" && find data state config projects -type f | LC_ALL=C sort | xargs shasum | shasum)

run_setup() { (cd "$WT" && bash "$SETUP"); }
out1=$(run_setup 2>&1) || fail "setup run 1 exits 0"
out2=$(run_setup 2>&1) || fail "setup run 2 exits 0"
pass "setup ran twice"

exclude=$(cd "$WT" && git rev-parse --git-path info/exclude)
for pat in '__pycache__/' '*.pyc' '.ruff_cache/' 'firebase-debug.log'; do
  n=$(grep -cxF -- "$pat" "$exclude" || true)
  if [ "$n" = 1 ]; then pass "exclude entry once: $pat"; else fail "exclude entry once: $pat (got $n)"; fi
done
case "$out1" in *bash*git*jq*python3*) pass "summary names runtime binaries" ;; *) fail "summary names runtime binaries" ;; esac
lines=$(printf '%s\n' "$out2" | wc -l | tr -d ' ')
if [ "$lines" -le 2 ]; then pass "compact output"; else fail "compact output ($lines lines)"; fi

mkdir -p "$WT/pkg/__pycache__"
printf 'x\n' >"$WT/pkg/__pycache__/foo.pyc"
printf 'x\n' >"$WT/firebase-debug.log"
mkdir -p "$WT/.ruff_cache"
printf 'x\n' >"$WT/.ruff_cache/c"
printf 'src\n' >"$WT/pkg/mod.py"
st=$(cd "$WT" && git status --short | grep -v -E '^\?\? (data|state|config|projects)/' || true)
case "$st" in *firebase-debug.log*|*__pycache__*|*.pyc*|*.ruff_cache*) fail "scratch ignored by git status ($st)" ;; *) pass "scratch ignored by git status" ;; esac

# --- archive ---------------------------------------------------------------
(cd "$WT" && bash "$ARCHIVE") >/dev/null
check "archive removed pkg/__pycache__" test ! -e "$WT/pkg/__pycache__"
check "archive removed .ruff_cache" test ! -e "$WT/.ruff_cache"
check "archive kept regular file" test -f "$WT/pkg/mod.py"
check "archive kept tracked file" test -f "$WT/tracked.txt"
(cd "$WT" && bash "$ARCHIVE") >/dev/null
pass "archive idempotent"

# --- private dirs untouched -------------------------------------------------
after=$(cd "$WT" && find data state config projects -type f | LC_ALL=C sort | xargs shasum | shasum)
check "private dirs untouched" test "$before" = "$after"
check "private pycache preserved" test -f "$WT/data/__pycache__/m.pyc"
tracked_dirty=$(cd "$WT" && git status --short --untracked-files=no)
check "tracked files unmodified" test -z "$tracked_dirty"

if [ "$fails" -ne 0 ]; then
  printf '%s check(s) failed\n' "$fails"
  exit 1
fi
printf 'all checks passed\n'
