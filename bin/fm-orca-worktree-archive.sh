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
import collections
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
try:
    _top_st = os.stat(top)
except OSError:
    warn("cannot stat worktree; nothing cleaned")
    sys.exit(0)
top_id = (_top_st.st_dev, _top_st.st_ino)


def protect_inside(path):
    """Protect a directory the raw path walks through, strictly below the top.

    Compared by (st_dev, st_ino), never by spelling, so a path that names the
    worktree in another case or through an alias still counts. The worktree top
    and every ancestor above it are never recorded.
    """
    try:
        st = os.lstat(path)
        if not stat.S_ISDIR(st.st_mode) or (st.st_dev, st.st_ino) == top_id:
            return
        anc = os.path.dirname(os.path.realpath(path))
        while True:
            ast = os.stat(anc)
            if (ast.st_dev, ast.st_ino) == top_id:
                protected_ids.add((st.st_dev, st.st_ino))
                return
            parent = os.path.dirname(anc)
            if parent == anc:
                return
            anc = parent
    except (OSError, ValueError):
        return


def protect_path(path, required=True):
    """Record the inode of every symlink hop, at any component, and the target.

    Walks the raw path component by component with lstat, expanding each
    symlink before any following ".." is applied, at most
    MAX_HOPS symlinks in total. Returns the visited paths (symlinks first,
    resolved target last). A required path that cannot be resolved aborts
    without deleting anything.
    """
    seen = []
    hops = 0
    try:
        # Raw components, never os.path.abspath(): collapsing "link/.." lexically
        # would skip expanding "link" first, which POSIX resolution requires.
        pending = [c for c in path.split(os.sep) if c]
        cur = os.sep if os.path.isabs(path) else os.getcwd()
        pending.reverse()
        while pending:
            comp = pending.pop()
            if comp == ".":
                continue
            if comp == "..":
                cur = os.path.dirname(cur)
                protect_inside(cur)
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
                protect_inside(cur)
        fin = os.lstat(cur)
        protected_ids.add((fin.st_dev, fin.st_ino))
        seen.append(cur)
    except (OSError, ValueError):
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


_CANON = {"head": "HEAD", "objects": "objects", "refs": "refs",
          "reftable": "reftable", "commondir": "commondir",
          "pack": "pack", "info": "info"}


def candidates(entries, key):
    """Exact-case entry first, then every other case-folded match."""
    canon = _CANON[key]
    out = [canon] if canon in entries else []
    out.extend(sorted(e for e in entries if e.lower() == key and e != canon))
    return out


def read_alternates(objdir):
    alt_file = os.path.join(objdir, "info", "alternates")
    protect_path(alt_file, required=False)
    try:
        with open(alt_file, "rb") as fh:
            data = os.fsdecode(fh.read())
    except OSError:
        return []
    found = []
    for line in data.split("\n"):
        if not line or line.startswith("#"):
            continue
        if line.startswith('"'):
            line = cunquote(line)
        if "\0" in line:
            continue
        found.append(line if os.path.isabs(line) else os.path.join(objdir, line))
    return found


def protect_object_subdirs(objdir):
    """Protect objects/pack and objects/info even when symlinked elsewhere."""
    try:
        ents = os.listdir(objdir)
    except (OSError, ValueError):
        return
    for key in ("pack", "info"):
        for name in candidates(ents, key):
            protect_path(os.path.join(objdir, name), required=False)


def protect_alternates(start, start_depth):
    """Breadth-first like Git: file order, shallowest depth wins, max depth 5."""
    best_depth = {}
    work = collections.deque([(start, start_depth)])
    while work:
        objdir, depth = work.popleft()
        if depth > 5:
            continue
        try:
            st = os.stat(objdir)
        except (OSError, ValueError):
            continue
        key = (st.st_dev, st.st_ino)
        if depth >= best_depth.get(key, 99):
            continue
        best_depth[key] = depth
        protect_path(objdir, required=False)
        protect_object_subdirs(objdir)
        for alt in read_alternates(objdir):
            work.append((alt, depth + 1))


for opt in ("--git-dir", "--git-common-dir"):
    protect_path(top_path(git_out("rev-parse", opt)))
env_alts = [
    a if os.path.isabs(a) else os.path.join(top, a)
    for a in split_env_alternates(os.environ.get("GIT_ALTERNATE_OBJECT_DIRECTORIES", ""))
]
# The primary store is not counted; its first alternate is depth 0 and an
# environment entry is itself depth 0 (Git odb.c).
protect_alternates(objects_path, -1)
for alt in env_alts:
    protect_alternates(alt, 0)

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


def has_dir(dfd, entries, *keys):
    for key in keys:
        for name in candidates(entries, key):
            try:
                if stat.S_ISDIR(os.stat(name, dir_fd=dfd).st_mode):
                    return True
            except OSError:
                continue
    return False


def commondir_raws(fd, entries):
    """Yield each usable commondir text of a Git directory, as Git reads it.

    Only CR and LF are stripped (Git setup.c); spaces and tabs belong to the
    path. Empty text and text with an embedded NUL are skipped.
    """
    for name in candidates(entries, "commondir"):
        try:
            tfd = os.open(name, os.O_RDONLY | os.O_NONBLOCK, dir_fd=fd)
        except OSError:
            continue
        try:
            if not stat.S_ISREG(os.fstat(tfd).st_mode):
                continue
            raw = os.read(tfd, 4096).rstrip(b"\r\n")
        except OSError:
            continue
        finally:
            os.close(tfd)
        if not raw or b"\x00" in raw:
            continue
        yield raw


def bare_layout(fd):
    """Return None, or the raw commondir text ("" if none) of a Git directory.

    Mirrors Git setup.c: HEAD plus objects and refs/reftable, either local or
    supplied by the directory a readable commondir file points at. Case-folded
    entries never shadow an exact-case match.
    """
    entries = os.listdir(fd)
    heads = []
    for name in candidates(entries, "head"):
        try:
            heads.append(os.lstat(name, dir_fd=fd).st_mode)
        except OSError:
            pass
    if not any(stat.S_ISREG(m) or stat.S_ISLNK(m) for m in heads):
        return None
    for raw in commondir_raws(fd, entries):
        try:
            cfd = os.open(raw, os.O_RDONLY | os.O_DIRECTORY, dir_fd=fd)
        except (OSError, ValueError):
            continue
        try:
            cents = os.listdir(cfd)
            if has_dir(cfd, cents, "objects") and has_dir(cfd, cents, "refs", "reftable"):
                return os.fsdecode(raw)
        finally:
            os.close(cfd)
    if has_dir(fd, entries, "objects") and has_dir(fd, entries, "refs", "reftable"):
        return ""
    return None


def is_bare_git_dir(fd):
    return bare_layout(fd) is not None


storage_seen = set()


def protect_git_storage(root):
    """Protect a Git directory's HEAD, objects, refs, commondir and alternates.

    Follows commondir (exact text) into the common directory, and protects
    every object directory's pack and info subdirectories, wherever symlinked.
    """
    try:
        st = os.stat(root)
        key = (st.st_dev, st.st_ino)
        if key in storage_seen:
            return
        storage_seen.add(key)
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    except (OSError, ValueError):
        return
    try:
        ents = os.listdir(fd)
        commons = [os.fsdecode(r) for r in commondir_raws(fd, ents)]
    finally:
        os.close(fd)
    for key in ("head", "objects", "refs", "reftable", "commondir"):
        for name in candidates(ents, key):
            full = os.path.join(root, name)
            protect_path(full, required=False)
            if key == "objects":
                protect_alternates(full, -1)
    for common in commons:
        common = common if os.path.isabs(common) else os.path.join(root, common)
        protect_path(common, required=False)
        protect_git_storage(common)


def protect_nested_git(path, entry):
    """Protect a nested repository's .git (directory, symlink or gitfile)."""
    gitpath = os.path.join(path, entry)
    try:
        mode = os.lstat(gitpath).st_mode
    except OSError:
        return
    protect_path(gitpath, required=False)
    if stat.S_ISREG(mode):
        try:
            with open(gitpath, "rb") as fh:
                raw = fh.read(4096).rstrip(b"\r\n")
        except OSError:
            return
        if not raw.startswith(b"gitdir:") or b"\x00" in raw:
            return
        target = os.fsdecode(raw[len(b"gitdir:"):])
        if target.startswith(" "):
            target = target[1:]
        if not target:
            return
        target = target if os.path.isabs(target) else os.path.join(path, target)
        protect_path(target, required=False)
        protect_git_storage(target)
    else:
        protect_git_storage(gitpath)


def protect_bare_repos(path):
    """Protect every bare/commondir/nested repo's storage, wherever symlinked.

    Runs before any cache is cleaned so a repo in one tagged cache keeps the
    objects, refs, commondir, alternates and gitdir stored in another.
    """
    try:
        fd = os.open(path, DIRFLAGS)
    except OSError:
        return
    try:
        names = os.listdir(fd)
        layout = bare_layout(fd)
        subs = []
        gits = []
        for entry in names:
            if entry.lower() == ".git":
                gits.append(entry)
                continue
            try:
                if stat.S_ISDIR(os.lstat(entry, dir_fd=fd).st_mode):
                    subs.append(os.path.join(path, entry))
            except OSError:
                continue
    finally:
        os.close(fd)
    if layout is not None:
        protect_git_storage(path)
    for entry in gits:
        protect_nested_git(path, entry)
    for sub in subs:
        protect_bare_repos(sub)


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


protect_bare_repos(top)
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
