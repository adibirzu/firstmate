#!/usr/bin/env bash
# bin/fm-orca-worktree-archive.sh - Orca worktree archive cleanup for firstmate.
# Removes only regenerable Python bytecode (*.pyc, *.pyo inside __pycache__)
# and ruff caches (.ruff_cache carrying a valid CACHEDIR.TAG). Never removes a
# path tracked in the git index, never descends into top-level .git, data,
# state, config or projects (matched case-insensitively by name and by the
# (st_dev, st_ino) of --git-dir and --git-common-dir, no globbing), never
# traverses a nested git repository (any .git entry, any case), never follows
# symlinks, and never removes source files. If the index is missing or cannot
# be read, or a git index.lock is present, it warns and deletes nothing.
# Makes no network calls.
#
# Contract: this Orca archive lifecycle hook is designed for quiescent
# worktrees. It assumes no concurrent writer mutates cache directories while it
# runs, because POSIX unlinkat/rmdirat resolve directory entry names rather
# than open file descriptors, so a racing rename cannot be fully excluded. The
# lstat/open_dir identity re-checks and the index.lock guard are best-effort
# hardening, not a substitute for quiescence.
set -euo pipefail

warn() { printf 'orca-worktree-archive: warning: %s\n' "$*" >&2; }

if ! command -v python3 >/dev/null 2>&1; then
  warn 'python3 missing; nothing cleaned'
  exit 0
fi

python3 -B -I - <<'PY'
import os
import stat
import subprocess
import sys

def warn(msg):
    sys.stderr.write("orca-worktree-archive: warning: %s\n" % msg)


# Read the toplevel as raw bytes and strip exactly one trailing LF: shell
# command substitution would strip every trailing newline of a worktree name.
try:
    _res = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
except OSError:
    _res = None
if _res is None or _res.returncode != 0:
    warn("not inside a git worktree; nothing cleaned")
    sys.exit(0)
_raw = _res.stdout
top = os.fsdecode(_raw[:-1] if _raw.endswith(b"\n") else _raw)
TAG = b"Signature: 8a477f597d28d172789f06886806bc55"
PROTECTED = (".git", "data", "state", "config", "projects")
protected_ids = set()
DIRFLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def git_out(*args):
    try:
        res = subprocess.run(
            ["git", "-C", top] + list(args),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        warn("cannot run git (%s); nothing cleaned" % exc)
        sys.exit(0)
    if res.returncode != 0:
        warn("git index unreadable; nothing cleaned")
        sys.exit(0)
    return res.stdout


def top_path(raw):
    p = os.fsdecode(raw[:-1] if raw.endswith(b"\n") else raw)
    return p if os.path.isabs(p) else os.path.join(top, p)


MAX_HOPS = 32


def protect_path(path, required=True):
    """Record the inode of every symlink hop, at any component, and the target.

    Walks the path component by component with lstat, expanding at most
    MAX_HOPS symlinks in total. Returns the visited paths (symlinks first,
    resolved target last). A required path that cannot be resolved aborts
    without deleting anything.
    """
    seen = []
    hops = 0
    try:
        pending = [c for c in os.path.abspath(path).split(os.sep) if c]
        cur = os.sep
        pending.reverse()
        while pending:
            comp = pending.pop()
            if comp == ".":
                continue
            if comp == "..":
                cur = os.path.dirname(cur)
                continue
            nxt = os.path.join(cur, comp)
            st = os.lstat(nxt)
            if stat.S_ISLNK(st.st_mode):
                hops += 1
                if hops > MAX_HOPS:
                    raise OSError("too many symlink hops")
                protected_ids.add((st.st_dev, st.st_ino))
                seen.append(nxt)
                tgt = os.readlink(nxt)
                if os.path.isabs(tgt):
                    cur = os.sep
                parts = [c for c in tgt.split(os.sep) if c]
                pending.extend(reversed(parts))
            else:
                cur = nxt
        fin = os.lstat(cur)
        protected_ids.add((fin.st_dev, fin.st_ino))
        seen.append(cur)
    except OSError:
        if required:
            warn("cannot resolve %s; nothing cleaned" % path)
            sys.exit(0)
        return seen
    return seen


index_path = top_path(git_out("rev-parse", "--git-path", "index"))
index_hops = protect_path(index_path)
if not stat.S_ISREG(os.stat(index_path).st_mode):
    warn("git index missing; nothing cleaned")
    sys.exit(0)
lock_cands = set(index_hops) | {index_path, os.path.realpath(index_path)}
lock_cands.add(os.path.join(os.path.realpath(os.path.dirname(index_path)), os.path.basename(index_path)))
if any(os.path.lexists(c + ".lock") for c in lock_cands):
    warn("git index lock present; worktree busy, nothing cleaned")
    sys.exit(0)
objects_path = top_path(git_out("rev-parse", "--git-path", "objects"))
protect_path(objects_path)
if not stat.S_ISDIR(os.stat(objects_path).st_mode):
    warn("git objects dir missing; nothing cleaned")
    sys.exit(0)
_UNQ = {"n": "\n", "r": "\r", "t": "\t", "a": "\a", "b": "\b", "f": "\f", "v": "\v"}


def cunquote(text):
    """Unquote a Git C-quoted string (double quotes, backslash escapes)."""
    out = bytearray()
    i = 1
    raw = os.fsencode(text)
    text = raw.decode("latin-1")
    while i < len(text):
        ch = text[i]
        if ch == '"':
            break
        if ch == "\\" and i + 1 < len(text):
            i += 1
            ch = text[i]
            if ch in "01234567":
                j = i
                while j < len(text) and j < i + 3 and text[j] in "01234567":
                    j += 1
                out.append(int(text[i:j], 8) & 0xFF)
                i = j
                continue
            out += _UNQ.get(ch, ch).encode("latin-1")
        else:
            out += ch.encode("latin-1")
        i += 1
    return os.fsdecode(bytes(out))


def split_env_alternates(value):
    """Split GIT_ALTERNATE_OBJECT_DIRECTORIES on os.pathsep, honouring quotes."""
    entries, cur, i, n = [], "", 0, len(value)
    while i <= n:
        if i == n or value[i] == os.pathsep:
            if cur:
                entries.append(cur)
            cur = ""
            i += 1
        elif value[i] == '"' and cur == "":
            j = i + 1
            while j < n and value[j] != '"':
                j += 2 if value[j] == "\\" else 1
            entries.append(cunquote(value[i:j + 1]))
            i = j + 1
        else:
            cur += value[i]
            i += 1
    return entries


def read_alternates(objdir):
    try:
        with open(os.path.join(objdir, "info", "alternates"), "rb") as fh:
            data = os.fsdecode(fh.read())
    except OSError:
        return []
    found = []
    for line in data.split("\n"):
        line = line.strip("\r")
        if not line or line.startswith("#"):
            continue
        if line.startswith('"'):
            line = cunquote(line)
        found.append(line if os.path.isabs(line) else os.path.join(objdir, line))
    return found


def protect_alternates(start):
    visited = set()
    work = [(start, 0)]
    while work:
        objdir, depth = work.pop()
        try:
            st = os.stat(objdir)
        except OSError:
            continue
        key = (st.st_dev, st.st_ino)
        if key in visited or depth > 5:
            continue
        visited.add(key)
        protect_path(objdir, required=False)
        for alt in read_alternates(objdir):
            work.append((alt, depth + 1))


for opt in ("--git-dir", "--git-common-dir"):
    protect_path(top_path(git_out("rev-parse", opt)))
env_alts = [
    a if os.path.isabs(a) else os.path.join(top, a)
    for a in split_env_alternates(os.environ.get("GIT_ALTERNATE_OBJECT_DIRECTORIES", ""))
]
protect_alternates(objects_path)
for alt in env_alts:
    protect_alternates(alt)

listed = git_out("ls-files", "-z")

tracked = set()
for raw in listed.split(b"\0"):
    if not raw:
        continue
    try:
        st = os.lstat(os.path.join(os.fsencode(top), raw))
    except OSError:
        continue
    tracked.add((st.st_dev, st.st_ino))


def open_dir(name, parent_fd):
    """Open a real (non-symlink) directory entry, or return None."""
    try:
        before = os.lstat(name, dir_fd=parent_fd)
        if not stat.S_ISDIR(before.st_mode):
            return None
        fd = os.open(name, DIRFLAGS, dir_fd=parent_fd)
    except OSError:
        return None
    after = os.fstat(fd)
    if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
        os.close(fd)
        return None
    return fd


def is_protected(st):
    """True for a tracked path or an active git dir / common dir inode."""
    return (st.st_dev, st.st_ino) in tracked or (st.st_dev, st.st_ino) in protected_ids


def is_tracked_fd(fd):
    """True when the open directory is itself tracked or active git metadata."""
    return is_protected(os.fstat(fd))


def clean_pycache(fd, name, parent_fd):
    if is_tracked_fd(fd):
        return
    for entry in os.listdir(fd):
        if not entry.endswith((".pyc", ".pyo")):
            continue
        try:
            st = os.lstat(entry, dir_fd=fd)
            if not stat.S_ISREG(st.st_mode):
                continue
            if is_protected(st):
                continue
            os.unlink(entry, dir_fd=fd)
        except OSError:
            continue
    try:
        os.rmdir(name, dir_fd=parent_fd)
    except OSError:
        pass


def has_tag(fd):
    try:
        tfd = os.open("CACHEDIR.TAG", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    except OSError:
        return False
    try:
        if not stat.S_ISREG(os.fstat(tfd).st_mode):
            return False
        return os.read(tfd, len(TAG)) == TAG
    finally:
        os.close(tfd)


def is_bare_git_dir(fd):
    """True for a bare Git repository layout (HEAD, objects/commondir, refs)."""
    names = {}
    for e in os.listdir(fd):
        names[e.lower()] = e

    def kind(key):
        if key not in names:
            return None
        try:
            return os.lstat(names[key], dir_fd=fd).st_mode
        except OSError:
            return None

    head = kind("head")
    if head is None or not (stat.S_ISREG(head) or stat.S_ISLNK(head)):
        return False
    has_store = any(
        m is not None and stat.S_ISDIR(m) for m in (kind("objects"), kind("commondir"))
    ) or "commondir" in names
    has_refs = any(
        m is not None and stat.S_ISDIR(m) for m in (kind("refs"), kind("reftable"))
    )
    return has_store and has_refs


def has_git_entry(fd):
    return any(e.lower() == ".git" for e in os.listdir(fd)) or is_bare_git_dir(fd)


def contains_nested_git(fd):
    if is_bare_git_dir(fd):
        return True
    for entry in os.listdir(fd):
        if entry.lower() == ".git":
            return True
        sub = open_dir(entry, fd)
        if sub is None:
            continue
        try:
            if contains_nested_git(sub):
                return True
        finally:
            os.close(sub)
    return False


def contains_tracked(fd):
    for entry in os.listdir(fd):
        try:
            st = os.lstat(entry, dir_fd=fd)
        except OSError:
            continue
        if is_protected(st):
            return True
        if stat.S_ISDIR(st.st_mode):
            sub = open_dir(entry, fd)
            if sub is None:
                continue
            try:
                if is_tracked_fd(sub) or contains_tracked(sub):
                    return True
            finally:
                os.close(sub)
    return False


def purge(fd):
    for entry in os.listdir(fd):
        try:
            st = os.lstat(entry, dir_fd=fd)
            if is_protected(st):
                continue
            if stat.S_ISDIR(st.st_mode):
                sub = open_dir(entry, fd)
                if sub is None:
                    continue
                try:
                    if is_tracked_fd(sub):
                        continue
                    purge(sub)
                finally:
                    os.close(sub)
                os.rmdir(entry, dir_fd=fd)
            else:
                os.unlink(entry, dir_fd=fd)
        except OSError:
            continue


def clean_ruff(fd, name, parent_fd):
    if is_tracked_fd(fd) or not has_tag(fd):
        return
    if contains_nested_git(fd) or contains_tracked(fd):
        return
    purge(fd)
    try:
        os.rmdir(name, dir_fd=parent_fd)
    except OSError:
        pass


def walk(fd, is_top):
    for entry in os.listdir(fd):
        if entry.lower() in PROTECTED and (is_top or entry.lower() == ".git"):
            continue
        sub = open_dir(entry, fd)
        if sub is None:
            continue
        try:
            st = os.fstat(sub)
            if is_protected(st):
                continue
            if has_git_entry(sub):
                continue
            if entry == "__pycache__":
                clean_pycache(sub, entry, fd)
            elif entry == ".ruff_cache":
                clean_ruff(sub, entry, fd)
            else:
                walk(sub, False)
        finally:
            os.close(sub)


try:
    root = os.open(top, os.O_RDONLY | os.O_DIRECTORY)
except OSError as exc:
    warn("cannot open worktree (%s); nothing cleaned" % exc)
    sys.exit(0)
try:
    walk(root, True)
finally:
    os.close(root)
PY

printf 'orca-worktree-archive: cleaned local caches\n'
