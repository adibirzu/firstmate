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
check "orca.yaml exists" test -f "$ORCA_YAML"
check "hooks executable" test -x "$SETUP" -a -x "$ARCHIVE"
check "scripts/ dir gone" test ! -e "$ROOT/scripts"

ORCA_SETUP_FILE="$TMP/orca-setup.cmd"
ORCA_ARCHIVE_FILE="$TMP/orca-archive.cmd"
parse_orca_yaml() {
  python3 -B -I -c '
import sys


def strip_comment(line):
    dq = chr(34)
    sq = chr(39)
    quote = None
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if quote == dq:
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == dq:
                quote = None
        elif quote == sq:
            if ch == sq:
                if i + 1 < n and line[i + 1] == sq:
                    i += 2
                    continue
                quote = None
        else:
            if ch in (dq, sq):
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1].isspace()):
                return line[:i]
        i += 1
    return line


def parse_scalar(val):
    dq = chr(34)
    sq = chr(39)
    val = val.strip()
    if len(val) >= 2 and val[0] == dq and val[-1] == dq:
        out = []
        i = 1
        end = len(val) - 1
        escapes = {"n": "\n", "r": "\r", "t": "\t", dq: dq, "\\": "\\"}
        while i < end:
            if val[i] == "\\" and i + 1 < end:
                i += 1
                out.append(escapes.get(val[i], val[i]))
            else:
                out.append(val[i])
            i += 1
        return "".join(out)
    if len(val) >= 2 and val[0] == sq and val[-1] == sq:
        return val[1:-1].replace(sq * 2, sq)
    return val


def parse_yaml_stdlib(text):
    root = {}
    stack = [(-1, root)]
    for raw in text.splitlines():
        cleaned = strip_comment(raw)
        if not cleaned.strip():
            continue
        indent = len(cleaned) - len(cleaned.lstrip(" "))
        stripped = cleaned.lstrip(" ")
        if ":" not in stripped:
            raise ValueError("expected mapping entry: %r" % raw)
        idx = stripped.find(":")
        key = stripped[:idx].strip()
        rest = stripped[idx + 1 :]
        if rest and not rest[0].isspace():
            raise ValueError("invalid mapping separator: %r" % raw)
        while len(stack) > 1 and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if not rest.strip():
            child = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = parse_scalar(rest)
    return root


with open(sys.argv[1], "r", encoding="utf-8") as fh:
    text = fh.read()
try:
    import yaml  # type: ignore
    data = yaml.safe_load(text)
    stdlib_data = parse_yaml_stdlib(text)
    if stdlib_data != data:
        raise AssertionError("stdlib fallback diverged from PyYAML: %r != %r" % (stdlib_data, data))
except ImportError:
    data = parse_yaml_stdlib(text)

if not isinstance(data, dict):
    raise AssertionError("orca.yaml root must be a mapping")
policy = data.get("setupAgentStartupPolicy")
if policy != "wait-for-setup":
    raise AssertionError("unexpected setupAgentStartupPolicy: %r" % (policy,))
scripts = data.get("scripts")
if not isinstance(scripts, dict):
    raise AssertionError("orca.yaml scripts must be a mapping")
setup_cmd = scripts.get("setup")
archive_cmd = scripts.get("archive")
if not isinstance(setup_cmd, str) or not setup_cmd.strip():
    raise AssertionError("scripts.setup must be a non-empty string")
if not isinstance(archive_cmd, str) or not archive_cmd.strip():
    raise AssertionError("scripts.archive must be a non-empty string")

with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(setup_cmd)
with open(sys.argv[3], "w", encoding="utf-8") as fh:
    fh.write(archive_cmd)
' "$1" "$ORCA_SETUP_FILE" "$ORCA_ARCHIVE_FILE"
}

check "orca.yaml semantic contract (policy and hooks)" parse_orca_yaml "$ORCA_YAML"
SETUP_CMD=$(cat "$ORCA_SETUP_FILE")
ARCHIVE_CMD=$(cat "$ORCA_ARCHIVE_FILE")
check "orca.yaml setup command non-empty" test -n "$SETUP_CMD"
check "orca.yaml archive command non-empty" test -n "$ARCHIVE_CMD"

# Helpers present: extracted setup & archive hooks work end-to-end
HP="$TMP/contract-present"
new_repo "$HP"
mkdir -p "$HP/bin"
cp "$SETUP" "$HP/bin/fm-orca-worktree-setup.sh"
cp "$ARCHIVE" "$HP/bin/fm-orca-worktree-archive.sh"
chmod +x "$HP/bin/fm-orca-worktree-setup.sh" "$HP/bin/fm-orca-worktree-archive.sh"
git -C "$HP" add bin/fm-orca-worktree-setup.sh bin/fm-orca-worktree-archive.sh
git -C "$HP" commit -q -m hooks

hp_out1=$(cd "$HP" && bash -c "$SETUP_CMD" </dev/null 2>&1) || fail "contract present: setup run 1 exits 0"
hp_out2=$(cd "$HP" && bash -c "$SETUP_CMD" </dev/null 2>&1) || fail "contract present: setup run 2 exits 0"
pass "contract present: setup ran twice"
for pat in '__pycache__/' '*.pyc' '.ruff_cache/' 'firebase-debug.log'; do
  n=$(grep -cxF -- "$pat" "$HP/.git/info/exclude" || true)
  if [ "$n" = 1 ]; then
    pass "contract present: exclude entry once: $pat"
  else
    fail "contract present: exclude entry once: $pat (got $n)"
  fi
done
case "$hp_out1" in *bash*git*jq*python3*) pass "contract present: setup summary names runtime binaries" ;; *) fail "contract present: setup summary names runtime binaries ($hp_out1)" ;; esac
case "$hp_out2" in *bash*git*jq*python3*) pass "contract present: setup run 2 summary names runtime binaries" ;; *) fail "contract present: setup run 2 summary names runtime binaries ($hp_out2)" ;; esac

mkdir -p "$HP/pkg/__pycache__" "$HP/tagged/.ruff_cache"
printf 'x\n' >"$HP/pkg/__pycache__/foo.pyc"
printf '%s\n' "$TAG_SIG" >"$HP/tagged/.ruff_cache/CACHEDIR.TAG"
printf 'x\n' >"$HP/tagged/.ruff_cache/entry"
(cd "$HP" && bash -c "$ARCHIVE_CMD" </dev/null) >/dev/null 2>&1 || fail "contract present: archive exits 0"
check "contract present: archive removed pyc" test ! -e "$HP/pkg/__pycache__/foo.pyc"
check "contract present: archive removed tagged .ruff_cache" test ! -e "$HP/tagged/.ruff_cache"
check "contract present: archive preserved tracked file" test "$(cat "$HP/tracked.txt")" = keep
check "contract present: archive left git status clean" test -z "$(git -C "$HP" status --short)"

# Helpers absent: extracted setup & archive hooks exit 0 cleanly as no-ops
HA="$TMP/contract-absent"
new_repo "$HA"
rm -f "$HA/.git/info/exclude"
ha_setup_rc=0
(cd "$HA" && bash -c "$SETUP_CMD") >/dev/null 2>&1 || ha_setup_rc=$?
ha_archive_rc=0
(cd "$HA" && bash -c "$ARCHIVE_CMD") >/dev/null 2>&1 || ha_archive_rc=$?
check "contract absent: setup exits 0" test "$ha_setup_rc" = 0
check "contract absent: archive exits 0" test "$ha_archive_rc" = 0
check "contract absent: exclude not created" test ! -e "$HA/.git/info/exclude"
check "contract absent: tracked file preserved" test "$(cat "$HA/tracked.txt")" = keep
check "contract absent: git status clean" test -z "$(git -C "$HA" status --short)"

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
(cd "$RR" && python3 -B -c '
import os, re, sys
src = open(sys.argv[1]).read()
m = re.search(r"# FM_ARCHIVE_PY_START\n(.*?)\n# FM_ARCHIVE_PY_END", src, re.S)
assert m is not None, "archive python body markers not found"
body = m.group(1)
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
' "$ARCHIVE" "$RR") >/dev/null 2>&1 || true
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
cp "$OLD/.git/info/exclude" "$TMP/old-exclude-before"
for cmd in "$SETUP_CMD" "$ARCHIVE_CMD"; do
  rc=0
  (cd "$OLD" && sh -c "$cmd") >/dev/null 2>&1 || rc=$?
  check "guarded command exits 0 without hooks" test "$rc" = 0
done
check "guarded command leaves existing exclude untouched" cmp -s "$TMP/old-exclude-before" "$OLD/.git/info/exclude"

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
mkdir -p "$QA/lib/.ruff_cache"
printf '%s\n' "$TAG_SIG" >"$QA/lib/.ruff_cache/CACHEDIR.TAG"
cp -R "$QA/.git/objects" "$QA/lib/.ruff_cache/file-store"
printf '%s\n' "$QA/lib/.ruff_cache/file-store" >>"$QA/.git/objects/info/alternates"
qa_env=$(printf '"%s"' "$QA/.ruff_cache/env:store")
qa_before=$(snap "$QA/.ruff_cache/env:store")
qb_before=$(snap "$QA/lib/.ruff_cache/file-store")
(cd "$QA" && GIT_ALTERNATE_OBJECT_DIRECTORIES="$qa_env" bash "$ARCHIVE") >/dev/null 2>&1 || fail "quoted alternates archive exits 0"
check "quoted alternates: cleanup ran" test ! -e "$QA/pkg/__pycache__/stale.pyc"
check "quoted env alternate preserved" test "$qa_before" = "$(snap "$QA/.ruff_cache/env:store")"
check "info/alternates store preserved" test "$qb_before" = "$(snap "$QA/lib/.ruff_cache/file-store")"

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

# --- fix12: alternate order/depth, intermediate dirs, split bare storage, commondir
# Each store lives in its own tagged cache so every assertion is independent.
tag_at() {  # <dir> -> creates a tagged .ruff_cache inside <dir>
  mkdir -p "$1/.ruff_cache"
  printf '%s\n' "$TAG_SIG" >"$1/.ruff_cache/CACHEDIR.TAG"
}

AO="$TMP/altorder"
new_repo "$AO"
tag_cache "$AO"
plant_stale "$AO"
mkdir -p "$TMP/ao-x/info" "$AO/.ruff_cache/ystore/info"
printf 'sentinel\n' >"$AO/.ruff_cache/ystore/sentinel"
printf '%s\n' "$AO/.ruff_cache/ystore" >"$TMP/ao-x/info/alternates"
printf '%s\n' "$TMP/ao-x" >"$AO/.git/objects/info/alternates"
for i in 1 2 3 4 5; do mkdir -p "$TMP/ao-c$i/info"; done
for i in 1 2 3 4; do printf '%s\n' "$TMP/ao-c$((i + 1))" >"$TMP/ao-c$i/info/alternates"; done
# Only c1 is a direct entry; the chain c1..c5 then reaches x at depth 5.
printf '%s\n' "$TMP/ao-x" >"$AO/.git/objects/info/alternates"
printf '%s\n' "$TMP/ao-c1" >>"$AO/.git/objects/info/alternates"
printf '%s\n' "$TMP/ao-x" >"$TMP/ao-c5/info/alternates"
(cd "$AO" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "alt order archive exits 0"
check "alt order: cleanup ran" test ! -e "$AO/pkg/__pycache__/stale.pyc"
check "alt order: child of shallow-and-deep store preserved" test -f "$AO/.ruff_cache/ystore/sentinel"

AD="$TMP/altdepth"
new_repo "$AD"
tag_cache "$AD"
tag_at "$AD/lib"
plant_stale "$AD"
prev="$TMP/ad-e"
mkdir -p "$prev/info"
for i in 1 2 3 4; do
  mkdir -p "$TMP/ad-a$i/info"
  printf '%s\n' "$TMP/ad-a$i" >"$prev/info/alternates"
  prev="$TMP/ad-a$i"
done
mkdir -p "$AD/lib/.ruff_cache/s5/info" "$AD/.ruff_cache/s6/info"
printf 'sentinel\n' >"$AD/lib/.ruff_cache/s5/sentinel"
printf 'sentinel\n' >"$AD/.ruff_cache/s6/sentinel"
printf '%s\n' "$AD/lib/.ruff_cache/s5" >"$prev/info/alternates"
printf '%s\n' "$AD/.ruff_cache/s6" >"$AD/lib/.ruff_cache/s5/info/alternates"
(cd "$AD" && GIT_ALTERNATE_OBJECT_DIRECTORIES="$TMP/ad-e" bash "$ARCHIVE") >/dev/null 2>&1 || fail "alt depth archive exits 0"
check "alt depth: cleanup ran" test ! -e "$AD/pkg/__pycache__/stale.pyc"
check "alt depth: env store at depth 5 preserved" test -f "$AD/lib/.ruff_cache/s5/sentinel"
check "alt depth: store beyond Git depth limit not protected" test ! -e "$AD/.ruff_cache/s6/sentinel"

IM="$TMP/intermed"
new_repo "$IM"
tag_cache "$IM"
plant_stale "$IM"
mkdir -p "$IM/.ruff_cache/sub"
ln -s .ruff_cache/sub "$IM/link"
(cd "$IM" && GIT_INDEX_FILE="$IM/link/../../.git/index" bash "$ARCHIVE") >/dev/null 2>&1 || fail "intermediate archive exits 0"
check "intermediate: cleanup ran" test ! -e "$IM/pkg/__pycache__/stale.pyc"
check "intermediate: raw index path still reachable" test -f "$IM/link/../../.git/index"
check "intermediate: symlink target dir preserved" test -d "$IM/.ruff_cache/sub"

BX="$TMP/baresplit"
new_repo "$BX"
tag_cache "$BX"
tag_at "$BX/lib"
tag_at "$BX/vendor"
tag_at "$BX/extra"
plant_stale "$BX"
git init -q --bare "$BX/.ruff_cache/mirror.git"
mv "$BX/.ruff_cache/mirror.git/objects" "$BX/lib/.ruff_cache/real-objects"
mv "$BX/.ruff_cache/mirror.git/refs" "$BX/extra/.ruff_cache/real-refs"
ln -s "$BX/lib/.ruff_cache/real-objects" "$BX/.ruff_cache/mirror.git/objects"
ln -s "$BX/extra/.ruff_cache/real-refs" "$BX/.ruff_cache/mirror.git/refs"
mkdir -p "$BX/vendor/.ruff_cache/alt-store" "$BX/lib/.ruff_cache/real-objects/info"
printf 'sentinel\n' >"$BX/vendor/.ruff_cache/alt-store/sentinel"
printf '%s\n' "$BX/vendor/.ruff_cache/alt-store" >"$BX/lib/.ruff_cache/real-objects/info/alternates"
(cd "$BX" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "split bare archive exits 0"
check "split bare: cleanup ran" test ! -e "$BX/pkg/__pycache__/stale.pyc"
check "split bare: HEAD preserved" test -f "$BX/.ruff_cache/mirror.git/HEAD"
check "split bare: objects storage preserved" test -d "$BX/lib/.ruff_cache/real-objects/pack"
check "split bare: refs storage preserved" test -d "$BX/extra/.ruff_cache/real-refs/heads"
check "split bare: alternates target preserved" test -f "$BX/vendor/.ruff_cache/alt-store/sentinel"

CD="$TMP/commondir"
new_repo "$CD"
tag_cache "$CD"
tag_at "$CD/lib"
plant_stale "$CD"
git init -q --bare "$CD/lib/.ruff_cache/common.git"
rm -f "$CD/lib/.ruff_cache/common.git/HEAD"
mkdir -p "$CD/.ruff_cache/wt.git"
printf 'ref: refs/heads/main\n' >"$CD/.ruff_cache/wt.git/HEAD"
printf '../../lib/.ruff_cache/common.git\n' >"$CD/.ruff_cache/wt.git/commondir"
cd_before=$(snap "$CD/lib/.ruff_cache/common.git")
(cd "$CD" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "commondir archive exits 0"
check "commondir: cleanup ran" test ! -e "$CD/pkg/__pycache__/stale.pyc"
check "commondir: gitdir preserved" test -f "$CD/.ruff_cache/wt.git/commondir"
check "commondir: common dir preserved" test "$cd_before" = "$(snap "$CD/lib/.ruff_cache/common.git")"

# --- fix13: case-spelled symlink target, trailing-space commondir, NUL commondir,
# --- nested non-bare repos, symlinked objects/pack
CT="$TMP/casetop"
new_repo "$CT"
tag_cache "$CT"
plant_stale "$CT"
mkdir -p "$CT/.ruff_cache/sub"
ct_alt="$TMP/CASETOP"
if [ -d "$ct_alt/.ruff_cache" ] && [ "$ct_alt" -ef "$CT" ]; then
  ln -s "$ct_alt/.ruff_cache/sub" "$CT/link"
  (cd "$CT" && GIT_INDEX_FILE="$CT/link/../../.git/index" bash "$ARCHIVE") >/dev/null 2>&1 || fail "case top archive exits 0"
  check "case top: cleanup ran" test ! -e "$CT/pkg/__pycache__/stale.pyc"
  check "case top: intermediate dir preserved" test -d "$CT/.ruff_cache/sub"
  check "case top: raw index path reachable" test -f "$CT/link/../../.git/index"
else
  pass "case top fixture needs a case-insensitive filesystem"
fi

TS="$TMP/trailspace"
new_repo "$TS"
tag_cache "$TS"
tag_at "$TS/lib"
plant_stale "$TS"
ts_common="$TS/lib/.ruff_cache/common .git "
mkdir -p "$ts_common/objects/pack" "$ts_common/refs/heads"
printf 'sentinel\n' >"$ts_common/refs/heads/sentinel"
mkdir -p "$TS/.ruff_cache/wt.git"
printf 'ref: refs/heads/main\n' >"$TS/.ruff_cache/wt.git/HEAD"
printf '../../lib/.ruff_cache/common .git \n' >"$TS/.ruff_cache/wt.git/commondir"
(cd "$TS" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "trailing space archive exits 0"
check "trailing space: cleanup ran" test ! -e "$TS/pkg/__pycache__/stale.pyc"
check "trailing space: gitdir preserved" test -f "$TS/.ruff_cache/wt.git/commondir"
check "trailing space: common dir preserved" test -f "$ts_common/refs/heads/sentinel"

NU="$TMP/nulcommon"
new_repo "$NU"
plant_stale "$NU"
mkdir -p "$NU/junk1" "$NU/junk2"
printf 'ref: refs/heads/main\n' >"$NU/junk1/HEAD"
printf '\0\n' >"$NU/junk1/commondir"
printf 'ref: refs/heads/main\n' >"$NU/junk2/HEAD"
printf 'a\0b\n' >"$NU/junk2/commondir"
(cd "$NU" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "nul commondir archive exits 0"
check "nul commondir: cleanup ran" test ! -e "$NU/pkg/__pycache__/stale.pyc"
check "nul commondir: unrelated dirs untouched" test -f "$NU/junk1/commondir" -a -f "$NU/junk2/commondir"

NG="$TMP/nestedrepo"
new_repo "$NG"
tag_cache "$NG"
tag_at "$NG/lib"
tag_at "$NG/vendor"
plant_stale "$NG"
git init -q "$NG/.ruff_cache/nested-a"
mkdir -p "$NG/lib/.ruff_cache/altstore"
printf 'sentinel\n' >"$NG/lib/.ruff_cache/altstore/sentinel"
printf '%s\n' "$NG/lib/.ruff_cache/altstore" >"$NG/.ruff_cache/nested-a/.git/objects/info/alternates"
mkdir -p "$NG/.ruff_cache/nested-b" "$NG/vendor/.ruff_cache/gd/objects"
printf 'ref: refs/heads/main\n' >"$NG/vendor/.ruff_cache/gd/HEAD"
printf 'sentinel\n' >"$NG/vendor/.ruff_cache/gd/index"
printf 'gitdir: %s\n' "$NG/vendor/.ruff_cache/gd" >"$NG/.ruff_cache/nested-b/.git"
(cd "$NG" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "nested repo archive exits 0"
check "nested repo: cleanup ran" test ! -e "$NG/pkg/__pycache__/stale.pyc"
check "nested repo: non-bare repo preserved" test -f "$NG/.ruff_cache/nested-a/.git/HEAD"
check "nested repo: alternate store preserved" test -f "$NG/lib/.ruff_cache/altstore/sentinel"
check "nested gitfile: repo preserved" test -f "$NG/.ruff_cache/nested-b/.git"
check "nested gitfile: target gitdir preserved" test -f "$NG/vendor/.ruff_cache/gd/index"

# --- P2: .git symlink to a gitfile, plus a dangling .git symlink ---
# nested-c/.git is a symlink to a regular gitfile in lib's tagged cache; the
# gitdir target is object storage in vendor's tagged cache, and its alternates
# point into a third tagged cache. nested-d/.git dangles.
SG="$TMP/symgitfile"
new_repo "$SG"
tag_cache "$SG"
tag_at "$SG/lib"
tag_at "$SG/vendor"
tag_at "$SG/alt"
plant_stale "$SG"
mkdir -p "$SG/vendor/.ruff_cache/gd/objects/pack" "$SG/vendor/.ruff_cache/gd/objects/info" "$SG/alt/.ruff_cache/astore"
printf 'sentinel\n' >"$SG/vendor/.ruff_cache/gd/objects/pack/p-x.pack"
printf '%s\n' "$SG/alt/.ruff_cache/astore" >"$SG/vendor/.ruff_cache/gd/objects/info/alternates"
printf 'sentinel\n' >"$SG/alt/.ruff_cache/astore/sentinel"
printf 'gitdir: %s\n' "$SG/vendor/.ruff_cache/gd" >"$SG/lib/.ruff_cache/gd.link"
mkdir -p "$SG/.ruff_cache/nested-c" "$SG/.ruff_cache/nested-d"
ln -s "$SG/lib/.ruff_cache/gd.link" "$SG/.ruff_cache/nested-c/.git"
ln -s "$SG/.ruff_cache/no-such-target" "$SG/.ruff_cache/nested-d/.git"
(cd "$SG" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "symlink gitfile archive exits 0"
check "symlink gitfile: cleanup ran" test ! -e "$SG/pkg/__pycache__/stale.pyc"
check "symlink gitfile: symlink .git preserved" test -L "$SG/.ruff_cache/nested-c/.git"
check "symlink gitfile: gitfile preserved" test -f "$SG/lib/.ruff_cache/gd.link"
check "symlink gitfile: target pack preserved" test -f "$SG/vendor/.ruff_cache/gd/objects/pack/p-x.pack"
check "symlink gitfile: alternate store preserved" test -f "$SG/alt/.ruff_cache/astore/sentinel"
check "dangling .git symlink: link preserved" test -L "$SG/.ruff_cache/nested-d/.git"
check "dangling .git symlink: repo dir preserved" test -d "$SG/.ruff_cache/nested-d"

PK="$TMP/packlink"
new_repo "$PK"
tag_cache "$PK"
tag_at "$PK/lib"
plant_stale "$PK"
git init -q --bare "$PK/.ruff_cache/mirror.git"
mkdir -p "$PK/lib/.ruff_cache"
mv "$PK/.ruff_cache/mirror.git/objects/pack" "$PK/lib/.ruff_cache/real-pack"
printf 'sentinel\n' >"$PK/lib/.ruff_cache/real-pack/pack-x.pack"
ln -s "$PK/lib/.ruff_cache/real-pack" "$PK/.ruff_cache/mirror.git/objects/pack"
(cd "$PK" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "pack symlink archive exits 0"
check "pack symlink: cleanup ran" test ! -e "$PK/pkg/__pycache__/stale.pyc"
check "pack symlink: pack file preserved" test -f "$PK/lib/.ruff_cache/real-pack/pack-x.pack"

SH="$TMP/shadow"
new_repo "$SH"
tag_cache "$SH"
plant_stale "$SH"
git init -q --bare "$SH/.ruff_cache/mirror.git"
{ : >"$SH/.ruff_cache/mirror.git/OBJECTS"; } 2>/dev/null || true
sh_n=0
for sh_e in "$SH/.ruff_cache/mirror.git"/[oO][bB][jJ][eE][cC][tT][sS]; do
  [ -e "$sh_e" ] && sh_n=$((sh_n + 1))
done
if [ "$sh_n" = 2 ]; then
  sh_before=$(snap "$SH/.ruff_cache/mirror.git")
  (cd "$SH" && bash "$ARCHIVE") >/dev/null 2>&1 || fail "shadow archive exits 0"
  check "shadow: cleanup ran" test ! -e "$SH/pkg/__pycache__/stale.pyc"
  check "shadow: bare repo preserved" test "$sh_before" = "$(snap "$SH/.ruff_cache/mirror.git")"
else
  pass "shadow fixture needs a case-sensitive filesystem"
fi

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
