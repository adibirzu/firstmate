#!/usr/bin/env bash
# tests/fm-orca-worktree-setup.test.sh - Orca worktree setup and archive helpers.
# Runs both hooks inside isolated temporary Git repos and linked worktrees.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="$ROOT/bin/fm-orca-worktree-setup.sh"
ARCHIVE="$ROOT/bin/fm-orca-worktree-archive.sh"
ORCA_YAML="$ROOT/orca.yaml"
TAG_SIG='Signature: 8a477f597d28d172789f06886806bc55'

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
new_repo() {  # <dir>
  git init -q "$1"
  git -C "$1" config user.email test@example.invalid
  git -C "$1" config user.name test
  printf 'keep\n' >"$1/tracked.txt"
  git -C "$1" add tracked.txt
  git -C "$1" commit -q -m init
}

# --- orca.yaml contract -----------------------------------------------------
SETUP_CMD='if [ -f bin/fm-orca-worktree-setup.sh ]; then bash bin/fm-orca-worktree-setup.sh; fi'
ARCHIVE_CMD='if [ -f bin/fm-orca-worktree-archive.sh ]; then bash bin/fm-orca-worktree-archive.sh; fi'
check "orca.yaml exists" test -f "$ORCA_YAML"
check "orca.yaml guarded setup" grep -qxF "  setup: \"$SETUP_CMD\"" "$ORCA_YAML"
check "orca.yaml guarded archive" grep -qxF "  archive: \"$ARCHIVE_CMD\"" "$ORCA_YAML"
check "orca.yaml wait-for-setup" grep -q 'setupAgentStartupPolicy: wait-for-setup' "$ORCA_YAML"
check "hooks executable" test -x "$SETUP" -a -x "$ARCHIVE"
check "scripts/ dir gone" test ! -e "$ROOT/scripts"
no_users() {
  local needle="/Us""ers/"
  test -f "$ORCA_YAML" -a -f "$SETUP" -a -f "$ARCHIVE" || return 1
  ! grep -q "$needle" "$ORCA_YAML" "$SETUP" "$ARCHIVE"
}
check "no hardcoded home paths" no_users

# --- isolated repo + linked worktree ---------------------------------------
MAIN="$TMP/main"
WT="$TMP/linked"
new_repo "$MAIN"
mkdir -p "$MAIN/trk/__pycache__" "$MAIN/rt/.ruff_cache"
printf 'x\n' >"$MAIN/trk/__pycache__/tracked.pyc"
printf '%s\n' "$TAG_SIG" >"$MAIN/rt/.ruff_cache/CACHEDIR.TAG"
printf 'x\n' >"$MAIN/rt/.ruff_cache/tracked-entry"
git -C "$MAIN" add -f trk/__pycache__/tracked.pyc rt/.ruff_cache/tracked-entry
git -C "$MAIN" commit -q -m cache-like-tracked
git -C "$MAIN" worktree add -q -b linked "$WT"
# Tagged cache in the linked worktree itself, next to the tracked entry, so the
# tracked-inode guard (not the missing tag) is what preserves it.
printf '%s\n' "$TAG_SIG" >"$WT/rt/.ruff_cache/CACHEDIR.TAG"

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

exclude="$MAIN/.git/info/exclude"
for pat in '__pycache__/' '*.pyc' '.ruff_cache/' 'firebase-debug.log'; do
  n=$(grep -cxF -- "$pat" "$exclude" || true)
  if [ "$n" = 1 ]; then pass "exclude entry once: $pat"; else fail "exclude entry once: $pat (got $n)"; fi
done
case "$out1" in *bash*git*jq*python3*) pass "summary names runtime binaries" ;; *) fail "summary names runtime binaries" ;; esac
lines=$(printf '%s\n' "$out2" | wc -l | tr -d ' ')
if [ "$lines" -le 2 ]; then pass "compact output"; else fail "compact output ($lines lines)"; fi

mkdir -p "$WT/pkg/__pycache__" "$WT/untagged/.ruff_cache" "$WT/tagged/.ruff_cache/sub"
printf 'x\n' >"$WT/pkg/__pycache__/foo.pyc"
printf 'x\n' >"$WT/pkg/__pycache__/foo.pyo"
printf 'src\n' >"$WT/pkg/__pycache__/notes.py"
printf 'x\n' >"$WT/firebase-debug.log"
printf 'x\n' >"$WT/untagged/.ruff_cache/c"
printf '%s\n' "$TAG_SIG" >"$WT/tagged/.ruff_cache/CACHEDIR.TAG"
printf 'x\n' >"$WT/tagged/.ruff_cache/sub/c"
printf 'src\n' >"$WT/pkg/mod.py"
st=$(cd "$WT" && git status --short --untracked-files=all | grep -v -E '^\?\? (data|state|config|projects)/' || true)
case "$st" in
  *firebase-debug.log*|*foo.pyc*|*foo.pyo*|*.ruff_cache*) fail "scratch ignored by git status ($st)" ;;
  *) pass "scratch ignored by git status" ;;
esac

# --- archive ---------------------------------------------------------------
out=$(cd "$WT" && bash "$ARCHIVE" 2>&1) || fail "archive exits 0"
check "archive removed pyc" test ! -e "$WT/pkg/__pycache__/foo.pyc"
check "archive removed pyo" test ! -e "$WT/pkg/__pycache__/foo.pyo"
check "archive kept untracked source in __pycache__" test -f "$WT/pkg/__pycache__/notes.py"
check "archive kept tracked file in __pycache__" test -f "$WT/trk/__pycache__/tracked.pyc"
check "archive kept untagged .ruff_cache" test -f "$WT/untagged/.ruff_cache/c"
check "archive removed tagged .ruff_cache" test ! -e "$WT/tagged/.ruff_cache"
check "archive kept tagged .ruff_cache with tracked entry" test -f "$WT/rt/.ruff_cache/tracked-entry"
check "archive kept regular file" test -f "$WT/pkg/mod.py"
check "archive kept tracked file" test -f "$WT/tracked.txt"
case "$out" in *cleaned*) pass "archive summary" ;; *) fail "archive summary ($out)" ;; esac
(cd "$WT" && bash "$ARCHIVE") >/dev/null
pass "archive idempotent"

# --- finding: tracked cache directory (gitlink) is preserved itself --------
GL="$TMP/gitlink"
new_repo "$GL"
glsha=$(git -C "$GL" rev-parse HEAD)
mkdir -p "$GL/.ruff_cache" "$GL/gp/__pycache__"
git -C "$GL" update-index --add --cacheinfo "160000,$glsha,.ruff_cache"
git -C "$GL" update-index --add --cacheinfo "160000,$glsha,gp/__pycache__"
git -C "$GL" commit -q -m gitlinks
printf '%s\n' "$TAG_SIG" >"$GL/.ruff_cache/CACHEDIR.TAG"
printf 'x\n' >"$GL/.ruff_cache/untracked-inside"
printf 'x\n' >"$GL/gp/__pycache__/m.pyc"
tag_bytes=$(wc -c <"$GL/.ruff_cache/CACHEDIR.TAG" | tr -d ' ')
check "gitlink tag is 43 bytes plus newline" test "$tag_bytes" = 44
(cd "$GL" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "gitlink archive exits 0"
check "tracked .ruff_cache dir preserved" test -d "$GL/.ruff_cache"
check "tracked .ruff_cache tag preserved" test -f "$GL/.ruff_cache/CACHEDIR.TAG"
check "tracked .ruff_cache contents preserved" test -f "$GL/.ruff_cache/untracked-inside"
check "tracked __pycache__ dir preserved" test -d "$GL/gp/__pycache__"

# --- finding: FIFO CACHEDIR.TAG must not hang -------------------------------
FF="$TMP/fifo"
new_repo "$FF"
mkdir -p "$FF/.ruff_cache"
mkfifo "$FF/.ruff_cache/CACHEDIR.TAG"
(cd "$FF" && bash "$ARCHIVE") >/dev/null 2>&1 &
fpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$fpid" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$fpid" 2>/dev/null; then
  fail "fifo tag archive returns promptly"
  kill "$fpid" 2>/dev/null || true
  # Unblock the python child stuck opening the FIFO so it can exit.
  (exec 3<>"$FF/.ruff_cache/CACHEDIR.TAG") 2>/dev/null || true
else
  pass "fifo tag archive returns promptly"
fi
fifo_status=0
wait "$fpid" 2>/dev/null || fifo_status=$?
check "fifo tag archive exits 0" test "$fifo_status" = 0
check "fifo tag .ruff_cache preserved" test -p "$FF/.ruff_cache/CACHEDIR.TAG"

# --- finding: ordinary-named tracked submodule is never entered ------------
SMR="$TMP/submod-src"
new_repo "$SMR"
mkdir -p "$SMR/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$SMR/.ruff_cache/CACHEDIR.TAG"
printf 'x\n' >"$SMR/.ruff_cache/inside-sub"
printf 'sub\n' >"$SMR/subtracked.txt"
git -C "$SMR" add subtracked.txt
git -C "$SMR" add -f .ruff_cache/inside-sub
git -C "$SMR" commit -q -m subfiles
SM="$TMP/submod-parent"
new_repo "$SM"
mkdir -p "$SM/vendor"
git clone -q "$SMR" "$SM/vendor/submod"
git -C "$SM" add vendor/submod 2>/dev/null
git -C "$SM" commit -q -m addsub
printf '%s\n' "$TAG_SIG" >"$SM/vendor/submod/.ruff_cache/CACHEDIR.TAG"
(cd "$SM" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "submodule archive exits 0"
check "submodule .ruff_cache preserved" test -f "$SM/vendor/submod/.ruff_cache/CACHEDIR.TAG"
check "submodule cache tracked file preserved" test -f "$SM/vendor/submod/.ruff_cache/inside-sub"
check "submodule tracked file preserved" test -f "$SM/vendor/submod/subtracked.txt"

# --- finding: nested repository under a tagged cache is never traversed -----
NR="$TMP/nested"
new_repo "$NR"
mkdir -p "$NR/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$NR/.ruff_cache/CACHEDIR.TAG"
new_repo "$NR/.ruff_cache/local-repo"
printf 'src\n' >"$NR/.ruff_cache/local-repo/source.py"
git -C "$NR/.ruff_cache/local-repo" add source.py
git -C "$NR/.ruff_cache/local-repo" commit -q -m src
(cd "$NR" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "nested repo archive exits 0"
check "nested repo source preserved" test -f "$NR/.ruff_cache/local-repo/source.py"
check "nested repo git HEAD preserved" test -f "$NR/.ruff_cache/local-repo/.git/HEAD"
check "nested repo tracked file preserved" test -f "$NR/.ruff_cache/local-repo/tracked.txt"

# --- finding: git metadata and protected dirs matched by case alias ---------
CA="$TMP/casealias"
new_repo "$CA"
mkdir -p "$CA/.GIT/objects/__pycache__"
printf 'x\n' >"$CA/.GIT/objects/__pycache__/probe.pyc"
for d in Data STATE Config PROJECTS; do
  mkdir -p "$CA/$d/__pycache__"
  printf 'x\n' >"$CA/$d/__pycache__/m.pyc"
done
(cd "$CA" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "case alias archive exits 0"
check "case alias .GIT pycache preserved" test -f "$CA/.GIT/objects/__pycache__/probe.pyc"
for d in Data STATE Config PROJECTS; do
  check "case alias $d pycache preserved" test -f "$CA/$d/__pycache__/m.pyc"
done
# Real rename of the git directory: where the filesystem is case-insensitive,
# git still finds the checkout and the resolved git dir is the identity guard.
CR="$TMP/caserename"
new_repo "$CR"
mv "$CR/.git" "$CR/.git-tmp-rename"
mv "$CR/.git-tmp-rename" "$CR/.GIT"
if git -C "$CR" rev-parse --git-dir >/dev/null 2>&1; then
  mkdir -p "$CR/.GIT/objects/__pycache__"
  printf 'x\n' >"$CR/.GIT/objects/__pycache__/probe.pyc"
  (cd "$CR" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "renamed git dir archive exits 0"
  check "renamed git dir pycache preserved" test -f "$CR/.GIT/objects/__pycache__/probe.pyc"
else
  pass "renamed git dir unsupported on this filesystem (skipped)"
fi

# --- finding: missing index fails closed ------------------------------------
MI="$TMP/noindex"
new_repo "$MI"
mkdir -p "$MI/pkg/__pycache__"
printf 'v1\n' >"$MI/pkg/__pycache__/committed.pyc"
git -C "$MI" add -f pkg/__pycache__/committed.pyc
git -C "$MI" commit -q -m pyc
printf 'v2-modified\n' >"$MI/pkg/__pycache__/committed.pyc"
printf 'x\n' >"$MI/pkg/__pycache__/other.pyc"
rm -f "$MI/.git/index"
rc=0
miout=$(cd "$MI" && bash "$ARCHIVE" 2>&1) || rc=$?
check "missing index archive exits 0" test "$rc" = 0
check "missing index keeps modified committed pyc" test -f "$MI/pkg/__pycache__/committed.pyc"
check "missing index deletes nothing else" test -f "$MI/pkg/__pycache__/other.pyc"
case "$miout" in *[Ww]arn*) pass "missing index warns" ;; *) fail "missing index warns ($miout)" ;; esac

# --- finding: active git metadata inside a tagged .ruff_cache ---------------
snap() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum); }
SG="$TMP/sepgit"
mkdir -p "$SG/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$SG/.ruff_cache/CACHEDIR.TAG"
git init -q --separate-git-dir="$SG/.ruff_cache/repo-metadata" "$SG"
git -C "$SG" config user.email test@example.invalid
git -C "$SG" config user.name test
printf 'keep\n' >"$SG/tracked.txt"
git -C "$SG" add tracked.txt
git -C "$SG" commit -q -m init
sg_before=$(snap "$SG/.ruff_cache/repo-metadata")
(cd "$SG" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "separate git dir archive exits 0"
check "separate git dir HEAD preserved" test -f "$SG/.ruff_cache/repo-metadata/HEAD"
check "separate git dir index preserved" test -f "$SG/.ruff_cache/repo-metadata/index"
check "separate git dir objects untouched" test "$sg_before" = "$(snap "$SG/.ruff_cache/repo-metadata")"
check "separate git dir repo still valid" git -C "$SG" rev-parse --verify -q HEAD

CD="$TMP/commondir-main"
LW="$TMP/commondir-linked"
new_repo "$CD"
git -C "$CD" worktree add -q "$LW" -b linked-branch
mkdir -p "$LW/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$LW/.ruff_cache/CACHEDIR.TAG"
mv "$CD/.git" "$LW/.ruff_cache/repo-metadata"
printf 'gitdir: %s\n' "$LW/.ruff_cache/repo-metadata" >"$CD/.git"
printf 'gitdir: %s\n' "$LW/.ruff_cache/repo-metadata/worktrees/commondir-linked" >"$LW/.git"
if git -C "$LW" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  cd_before=$(snap "$LW/.ruff_cache/repo-metadata")
  (cd "$LW" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "common dir archive exits 0"
  check "common dir HEAD preserved" test -f "$LW/.ruff_cache/repo-metadata/HEAD"
  check "common dir objects untouched" test "$cd_before" = "$(snap "$LW/.ruff_cache/repo-metadata")"
  check "common dir linked worktree still valid" git -C "$LW" rev-parse --verify -q HEAD
else
  fail "common dir fixture could not be built"
fi

# --- finding: symlinked GIT_INDEX_FILE inside a tagged .ruff_cache ---------
SI="$TMP/symindex"
new_repo "$SI"
mkdir -p "$SI/.ruff_cache" "$SI/pkg/__pycache__"
printf '%s\n' "$TAG_SIG" >"$SI/.ruff_cache/CACHEDIR.TAG"
printf 'x\n' >"$SI/pkg/__pycache__/stale.pyc"
ln -s "$SI/.git/index" "$SI/.ruff_cache/alt-index"
(cd "$SI" && GIT_INDEX_FILE="$SI/.ruff_cache/alt-index" bash "$ARCHIVE") >/dev/null 2>&1 || fail "symlinked index archive exits 0"
check "symlinked index: cleanup ran" test ! -e "$SI/pkg/__pycache__/stale.pyc"
check "symlinked index file preserved" test -L "$SI/.ruff_cache/alt-index"
check "symlinked index tagged cache preserved" test -f "$SI/.ruff_cache/CACHEDIR.TAG"
check "symlinked index real index preserved" test -f "$SI/.git/index"

# --- finding: lock on the symlink target of the active index ---------------
SK="$TMP/symlock"
new_repo "$SK"
mkdir -p "$SK/.ruff_cache" "$SK/pkg/__pycache__"
printf '%s\n' "$TAG_SIG" >"$SK/.ruff_cache/CACHEDIR.TAG"
printf 'x\n' >"$SK/pkg/__pycache__/m.pyc"
ln -s "$SK/.git/index" "$SK/.ruff_cache/alt-index"
: >"$SK/.git/index.lock"
rc=0
kout=$(cd "$SK" && GIT_INDEX_FILE="$SK/.ruff_cache/alt-index" bash "$ARCHIVE" 2>&1) || rc=$?
check "symlink target lock archive exits 0" test "$rc" = 0
check "symlink target lock deletes pycache nothing" test -f "$SK/pkg/__pycache__/m.pyc"
check "symlink target lock keeps tagged cache" test -f "$SK/.ruff_cache/CACHEDIR.TAG"
case "$kout" in *"index lock present"*) pass "symlink target lock warns" ;; *) fail "symlink target lock warns ($kout)" ;; esac

# --- finding: relocated GIT_OBJECT_DIRECTORY inside a tagged .ruff_cache ---
OD="$TMP/objdir"
new_repo "$OD"
mkdir -p "$OD/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$OD/.ruff_cache/CACHEDIR.TAG"
mkdir -p "$OD/pkg/__pycache__"
printf 'x\n' >"$OD/pkg/__pycache__/stale.pyc"
mv "$OD/.git/objects" "$OD/.ruff_cache/object-store"
od_before=$(snap "$OD/.ruff_cache/object-store")
(cd "$OD" && GIT_OBJECT_DIRECTORY="$OD/.ruff_cache/object-store" bash "$ARCHIVE") >/dev/null 2>&1 || fail "object dir archive exits 0"
check "object dir: cleanup ran" test ! -e "$OD/pkg/__pycache__/stale.pyc"
check "object dir tagged cache preserved" test -f "$OD/.ruff_cache/CACHEDIR.TAG"
check "object dir contents untouched" test "$od_before" = "$(snap "$OD/.ruff_cache/object-store")"

# --- private dirs untouched -------------------------------------------------
after=$(cd "$WT" && find data state config projects -type f | LC_ALL=C sort | xargs shasum | shasum)
check "private dirs untouched" test "$before" = "$after"
check "private pycache preserved" test -f "$WT/data/__pycache__/m.pyc"
tracked_dirty=$(cd "$WT" && git status --short --untracked-files=no)
check "tracked files unmodified" test -z "$tracked_dirty"

# --- finding 3: bracketed worktree path ------------------------------------
BR="$TMP/firstmate[old]"
new_repo "$BR"
for d in data state config projects; do
  mkdir -p "$BR/$d/__pycache__" "$BR/$d/.ruff_cache"
  printf 'x\n' >"$BR/$d/__pycache__/m.pyc"
  printf '%s\n' "$TAG_SIG" >"$BR/$d/.ruff_cache/CACHEDIR.TAG"
done
mkdir -p "$BR/pkg/__pycache__"
printf 'x\n' >"$BR/pkg/__pycache__/m.pyc"
(cd "$BR" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "bracketed archive exits 0"
for d in data state config projects; do
  check "bracketed path keeps $d pycache" test -f "$BR/$d/__pycache__/m.pyc"
  check "bracketed path keeps $d ruff cache" test -f "$BR/$d/.ruff_cache/CACHEDIR.TAG"
done
check "bracketed path still cleans pkg" test ! -e "$BR/pkg/__pycache__"

# --- finding 1: corrupt index fails closed ---------------------------------
CI="$TMP/corrupt"
new_repo "$CI"
mkdir -p "$CI/pkg/__pycache__"
printf 'x\n' >"$CI/pkg/__pycache__/m.pyc"
printf 'garbage-not-an-index' >"$CI/.git/index"
rc=0
cout=$(cd "$CI" && bash "$ARCHIVE" 2>&1) || rc=$?
check "corrupt index archive exits 0" test "$rc" = 0
check "corrupt index deletes nothing" test -f "$CI/pkg/__pycache__/m.pyc"
case "$cout" in *[Ww]arn*|*skip*|*refus*) pass "corrupt index warns" ;; *) fail "corrupt index warns ($cout)" ;; esac

# --- finding 5: symlink refusal --------------------------------------------
SL="$TMP/symexcl"
new_repo "$SL"
printf 'target-original\n' >"$TMP/sym-target"
rm -f "$SL/.git/info/exclude"
ln -s "$TMP/sym-target" "$SL/.git/info/exclude"
rc=0
sout=$(cd "$SL" && bash "$SETUP" 2>&1) || rc=$?
check "symlinked exclude setup exits 0" test "$rc" = 0
check "symlinked exclude target unmodified" test "$(cat "$TMP/sym-target")" = target-original
case "$sout" in *[Ww]arn*|*refus*|*skip*) pass "symlinked exclude warns" ;; *) fail "symlinked exclude warns ($sout)" ;; esac

SP="$TMP/symparent"
new_repo "$SP"
mkdir "$TMP/sym-dir"
rm -rf "$SP/.git/info"
ln -s "$TMP/sym-dir" "$SP/.git/info"
rc=0
pout=$(cd "$SP" && bash "$SETUP" 2>&1) || rc=$?
check "symlinked info setup exits 0" test "$rc" = 0
check "symlinked info target untouched" test -z "$(ls -A "$TMP/sym-dir")"
case "$pout" in *[Ww]arn*|*refus*|*skip*) pass "symlinked info warns" ;; *) fail "symlinked info warns ($pout)" ;; esac

# --- finding 2: unterminated exclude line ----------------------------------
NL="$TMP/nonl"
new_repo "$NL"
printf 'existing-rule' >"$NL/.git/info/exclude"
(cd "$NL" && bash "$SETUP") >/dev/null 2>&1 || fail "no-newline setup exits 0"
check "existing rule preserved on own line" grep -qxF 'existing-rule' "$NL/.git/info/exclude"
check "no joined rule" test -z "$(grep -F 'existing-rule__' "$NL/.git/info/exclude" || true)"
check "patterns appended after rule" grep -qxF '__pycache__/' "$NL/.git/info/exclude"

# --- finding 5: concurrent setups in sibling worktrees ---------------------
CC="$TMP/conc"
new_repo "$CC"
git -C "$CC" worktree add -q -b wa "$TMP/conc-a"
git -C "$CC" worktree add -q -b wb "$TMP/conc-b"
dups=0
for _ in 1 2 3 4 5; do
  : >"$CC/.git/info/exclude"
  (cd "$TMP/conc-a" && bash "$SETUP") >/dev/null 2>&1 &
  (cd "$TMP/conc-b" && bash "$SETUP") >/dev/null 2>&1 &
  wait
  dups=$((dups + $(sort "$CC/.git/info/exclude" | uniq -d | wc -l | tr -d ' ')))
done
check "concurrent setups leave no duplicate lines" test "$dups" = 0
check "concurrent setups wrote patterns" grep -qxF 'firebase-debug.log' "$CC/.git/info/exclude"

# --- finding: rename race between lstat and open_dir in purge ---------------
# Simulated deterministically: when purge() lstat()s an ordinary directory
# entry, a tracked directory is swapped into its place before open_dir().
RR="$TMP/racepurge"
new_repo "$RR"
mkdir -p "$RR/.ruff_cache/victim" "$RR/.ruff_cache/victim-empty" "$RR/trkdir" "$RR/trkempty"
printf '%s\n' "$TAG_SIG" >"$RR/.ruff_cache/CACHEDIR.TAG"
printf 'precious\n' >"$RR/trkdir/data.txt"
rrsha=$(git -C "$RR" rev-parse HEAD)
git -C "$RR" update-index --add --cacheinfo "160000,$rrsha,trkdir"
git -C "$RR" update-index --add --cacheinfo "160000,$rrsha,trkempty"
git -C "$RR" commit -q -m trk
RACE_DRIVER="$TMP/race_driver.py"
cat >"$RACE_DRIVER" <<'PYDRV'
import os, re, sys
src = open(sys.argv[1]).read()
body = re.search(r"<<'PY'\n(.*?)\nPY\n", src, re.S).group(1)
top = sys.argv[2]
swaps = {"victim": "trkdir", "victim-empty": "trkempty"}
real = os.lstat
done = set()
def hooked(path, *a, **k):
    res = real(path, *a, **k)
    if (path in swaps and "dir_fd" in k and path not in done
            and sys._getframe(1).f_code.co_name == "purge"):
        done.add(path)
        base = os.path.join(top, ".ruff_cache")
        os.rename(os.path.join(base, path), os.path.join(base, path + ".old"))
        os.rename(os.path.join(top, swaps[path]), os.path.join(base, path))
    return res
os.lstat = hooked
sys.argv = ["archive", top]
exec(compile(body, "archive-body", "exec"), {"__name__": "__main__"})
PYDRV
(cd "$RR" && python3 -B "$RACE_DRIVER" "$ARCHIVE" "$RR") >/dev/null 2>&1 || true
check "rename race: swapped-in tracked dir contents preserved" test -f "$RR/.ruff_cache/victim/data.txt"
check "rename race: swapped-in tracked dir itself preserved" test -d "$RR/.ruff_cache/victim"
check "rename race: swapped-in empty tracked gitlink preserved (no stray rmdir)" test -d "$RR/.ruff_cache/victim-empty"

# --- finding: git index lock marks the worktree busy -----------------------
IL="$TMP/indexlock"
new_repo "$IL"
mkdir -p "$IL/pkg/__pycache__" "$IL/.ruff_cache"
printf 'x\n' >"$IL/pkg/__pycache__/m.pyc"
printf '%s\n' "$TAG_SIG" >"$IL/.ruff_cache/CACHEDIR.TAG"
printf 'x\n' >"$IL/.ruff_cache/c"
: >"$IL/.git/index.lock"
rc=0
ilout=$(cd "$IL" && bash "$ARCHIVE" 2>&1) || rc=$?
check "index lock archive exits 0" test "$rc" = 0
check "index lock keeps __pycache__" test -f "$IL/pkg/__pycache__/m.pyc"
check "index lock keeps .ruff_cache" test -f "$IL/.ruff_cache/c"
case "$ilout" in *'index lock present'*) pass "index lock warns" ;; *) fail "index lock warns ($ilout)" ;; esac

# --- finding: alternate GIT_INDEX_FILE inside a tagged .ruff_cache ---------
AI="$TMP/altindex"
new_repo "$AI"
mkdir -p "$AI/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$AI/.ruff_cache/CACHEDIR.TAG"
cp "$AI/.git/index" "$AI/.ruff_cache/alt-index"
(cd "$AI" && GIT_INDEX_FILE="$AI/.ruff_cache/alt-index" bash "$ARCHIVE") >/dev/null 2>&1 || fail "alt index archive exits 0"
check "alternate index file preserved" test -f "$AI/.ruff_cache/alt-index"
check "alternate index cache tag preserved" test -f "$AI/.ruff_cache/CACHEDIR.TAG"

# --- finding 4: older worktree without the hooks ---------------------------
OLD="$TMP/old"
new_repo "$OLD"
for cmd in "$SETUP_CMD" "$ARCHIVE_CMD"; do
  rc=0
  (cd "$OLD" && sh -c "$cmd") >/dev/null 2>&1 || rc=$?
  check "guarded command exits 0 without hooks" test "$rc" = 0
done

# --- fix10: quoted alternates, ancestor symlinks, newline root, bare repos ---
# Each fixture plants a disposable __pycache__/stale.pyc; its removal proves the
# cleanup ran rather than exiting early.
plant_stale() {  # <repo>
  mkdir -p "$1/pkg/__pycache__"
  printf 'x\n' >"$1/pkg/__pycache__/stale.pyc"
}

QA="$TMP/quotedalt"
new_repo "$QA"
mkdir -p "$QA/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$QA/.ruff_cache/CACHEDIR.TAG"
plant_stale "$QA"
cp -R "$QA/.git/objects" "$QA/.ruff_cache/env:store"
cp -R "$QA/.git/objects" "$QA/.ruff_cache/file-store"
printf '%s\n' "$QA/.ruff_cache/file-store" >>"$QA/.git/objects/info/alternates"
qa_env=$(printf '"%s"' "$QA/.ruff_cache/env:store")
qa_before=$(snap "$QA/.ruff_cache/env:store")
qb_before=$(snap "$QA/.ruff_cache/file-store")
(cd "$QA" && GIT_ALTERNATE_OBJECT_DIRECTORIES="$qa_env" bash "$ARCHIVE") >/dev/null 2>&1 || fail "quoted alternates archive exits 0"
check "quoted alternates: cleanup ran" test ! -e "$QA/pkg/__pycache__/stale.pyc"
check "quoted env alternate preserved" test "$qa_before" = "$(snap "$QA/.ruff_cache/env:store")"
check "info/alternates store preserved" test "$qb_before" = "$(snap "$QA/.ruff_cache/file-store")"

AP="$TMP/ancestorsym"
new_repo "$AP"
mkdir -p "$AP/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$AP/.ruff_cache/CACHEDIR.TAG"
plant_stale "$AP"
ln -s ../.git "$AP/.ruff_cache/index-parent"
(cd "$AP" && GIT_INDEX_FILE="$AP/.ruff_cache/index-parent/index" bash "$ARCHIVE") >/dev/null 2>&1 || fail "ancestor symlink archive exits 0"
check "ancestor symlink: cleanup ran" test ! -e "$AP/pkg/__pycache__/stale.pyc"
check "ancestor directory symlink preserved" test -L "$AP/.ruff_cache/index-parent"
check "ancestor symlink index reachable" test -f "$AP/.ruff_cache/index-parent/index"

AL="$TMP/ancestorlock"
new_repo "$AL"
mkdir -p "$AL/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$AL/.ruff_cache/CACHEDIR.TAG"
plant_stale "$AL"
ln -s ../.git "$AL/.ruff_cache/index-parent"
: >"$AL/.git/index.lock"
rc=0
alout=$(cd "$AL" && GIT_INDEX_FILE="$AL/.ruff_cache/index-parent/index" bash "$ARCHIVE" 2>&1) || rc=$?
check "ancestor lock archive exits 0" test "$rc" = 0
check "ancestor lock deletes nothing" test -f "$AL/pkg/__pycache__/stale.pyc"
case "$alout" in *"index lock present"*) pass "ancestor lock warns" ;; *) fail "ancestor lock warns ($alout)" ;; esac

NL_BASE="$TMP/nl"
mkdir -p "$NL_BASE"
NLS="$NL_BASE/wt"
NLW="$NL_BASE/wt"$'\n'
new_repo "$NLS"
mkdir -p "$NLS/pkg/__pycache__"
printf 'x\n' >"$NLS/pkg/__pycache__/stale.pyc"
if mkdir -p "$NLW" 2>/dev/null; then
  git init -q "$NLW"
  git -C "$NLW" config user.email test@example.invalid
  git -C "$NLW" config user.name test
  printf 'keep\n' >"$NLW/tracked.txt"
  git -C "$NLW" add tracked.txt
  git -C "$NLW" commit -q -m init
  mkdir -p "$NLW/pkg/__pycache__"
  printf 'x\n' >"$NLW/pkg/__pycache__/stale.pyc"
  (cd "$NLW" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "newline root archive exits 0"
  check "newline root: own worktree cleaned" test ! -e "$NLW/pkg/__pycache__/stale.pyc"
  check "newline root: sibling checkout untouched" test -f "$NLS/pkg/__pycache__/stale.pyc"
else
  pass "newline root fixture unsupported on this filesystem"
fi

BG="$TMP/baretagged"
new_repo "$BG"
mkdir -p "$BG/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$BG/.ruff_cache/CACHEDIR.TAG"
plant_stale "$BG"
git init -q --bare "$BG/.ruff_cache/mirror.git"
bg_before=$(snap "$BG/.ruff_cache/mirror.git")
(cd "$BG" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "bare repo archive exits 0"
check "bare repo: cleanup ran" test ! -e "$BG/pkg/__pycache__/stale.pyc"
check "bare repo inside tagged cache preserved" test "$bg_before" = "$(snap "$BG/.ruff_cache/mirror.git")"
check "bare repo tagged cache preserved" test -f "$BG/.ruff_cache/CACHEDIR.TAG"

# --- fix11: symlink-before-dotdot, alternate depth/CR, registry, bare, newline setup
# Each alternate source gets its own tagged cache so neither can mask the other.
tag_cache() {  # <repo> -> creates a tagged .ruff_cache
  mkdir -p "$1/.ruff_cache"
  printf '%s\n' "$TAG_SIG" >"$1/.ruff_cache/CACHEDIR.TAG"
}

DD="$TMP/dotdot"
new_repo "$DD"
tag_cache "$DD"
plant_stale "$DD"
mkdir -p "$DD/.ruff_cache/deep/sub"
cp "$DD/.git/index" "$DD/.ruff_cache/index"
cp "$DD/.git/index" "$DD/index"
ln -s "$DD/.ruff_cache/deep/sub" "$DD/.ruff_cache/link"
(cd "$DD" && GIT_INDEX_FILE="$DD/.ruff_cache/link/../../index" bash "$ARCHIVE") >/dev/null 2>&1 || fail "dotdot archive exits 0"
check "dotdot: cleanup ran" test ! -e "$DD/pkg/__pycache__/stale.pyc"
check "dotdot: symlink-resolved index preserved" test -f "$DD/.ruff_cache/index"
check "dotdot: link preserved" test -L "$DD/.ruff_cache/link"

CH="$TMP/chain6"
new_repo "$CH"
tag_cache "$CH"
plant_stale "$CH"
prev="$CH/.git/objects"
for i in 1 2 3 4 5 6; do
  if [ "$i" = 6 ]; then store="$CH/.ruff_cache/s6"; else store="$TMP/chain-s$i"; fi
  mkdir -p "$store/info"
  printf '%s\n' "$store" >>"$prev/info/alternates"
  prev="$store"
done
printf 'sentinel\n' >"$CH/.ruff_cache/s6/sentinel"
(cd "$CH" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "chain archive exits 0"
check "chain6: cleanup ran" test ! -e "$CH/pkg/__pycache__/stale.pyc"
check "chain6: sixth store preserved" test -f "$CH/.ruff_cache/s6/sentinel"

CR="$TMP/cralt"
new_repo "$CR"
tag_cache "$CR"
plant_stale "$CR"
CR_STORE="$CR/.ruff_cache/store"$'\r'
mkdir -p "$CR_STORE/info"
printf 'sentinel\n' >"$CR_STORE/sentinel"
printf '%s\n' "$CR_STORE" >"$CR/.git/objects/info/alternates"
(cd "$CR" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "cr alternate archive exits 0"
check "cr alternate: cleanup ran" test ! -e "$CR/pkg/__pycache__/stale.pyc"
check "cr alternate: literal CR store preserved" test -f "$CR_STORE/sentinel"

RG="$TMP/registry"
new_repo "$RG"
tag_cache "$RG"
plant_stale "$RG"
mkdir -p "$TMP/rg-store"
cp -R "$RG/.git/objects/." "$TMP/rg-store/"
printf '%s\n' "$TMP/rg-store" >"$RG/.ruff_cache/alt-registry"
rm -f "$RG/.git/objects/info/alternates"
mkdir -p "$RG/.git/objects/info"
ln -s "$RG/.ruff_cache/alt-registry" "$RG/.git/objects/info/alternates"
(cd "$RG" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "registry archive exits 0"
check "registry: cleanup ran" test ! -e "$RG/pkg/__pycache__/stale.pyc"
check "registry: symlinked alternates target preserved" test -f "$RG/.ruff_cache/alt-registry"

BS="$TMP/baresym"
new_repo "$BS"
tag_cache "$BS"
plant_stale "$BS"
git init -q --bare "$BS/.ruff_cache/mirror.git"
mv "$BS/.ruff_cache/mirror.git/objects" "$BS/.ruff_cache/real-objects"
ln -s ../real-objects "$BS/.ruff_cache/mirror.git/objects"
(cd "$BS" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "bare symlink archive exits 0"
check "bare symlink: cleanup ran" test ! -e "$BS/pkg/__pycache__/stale.pyc"
check "bare symlink: HEAD preserved" test -f "$BS/.ruff_cache/mirror.git/HEAD"
check "bare symlink: refs preserved" test -d "$BS/.ruff_cache/mirror.git/refs"
check "bare symlink: objects target preserved" test -d "$BS/.ruff_cache/real-objects"

if [ -d "$NLW" ]; then
  (cd "$NLW" && bash "$SETUP") >/dev/null 2>&1 || fail "newline root setup exits 0"
  check "newline root setup: own exclude updated" grep -qxF '.ruff_cache/' "$NLW/.git/info/exclude"
  check "newline root setup: sibling exclude untouched" test -z "$(grep -xF '.ruff_cache/' "$NLS/.git/info/exclude" || true)"
fi

if [ "$fails" -ne 0 ]; then
  printf '%s check(s) failed\n' "$fails"
  exit 1
fi
printf 'all checks passed\n'
