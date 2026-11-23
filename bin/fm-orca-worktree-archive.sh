#!/usr/bin/env bash
# bin/fm-orca-worktree-archive.sh - Orca worktree archive cleanup for firstmate.
# Removes only regenerable Python bytecode (*.pyc, *.pyo inside __pycache__)
# and ruff caches (.ruff_cache carrying a valid CACHEDIR.TAG). Never removes a
# path tracked in the git index, never descends into top-level .git, data,
# state, config or projects (matched case-insensitively by name and by the
# (st_dev, st_ino) of --git-dir and --git-common-dir, no globbing), never
# traverses a nested git repository (any .git entry, any case), never follows
# symlinks, and never removes source files. If the index is missing or cannot
# be read it warns and deletes nothing. Makes no network calls.
set -euo pipefail

warn() { printf 'orca-worktree-archive: warning: %s\n' "$*" >&2; }

if ! top=$(git rev-parse --show-toplevel 2>/dev/null); then
  warn 'not inside a git worktree; nothing cleaned'
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  warn 'python3 missing; nothing cleaned'
  exit 0
fi

python3 -B -I - "$top" <<'PY'
import os
import stat
import subprocess
import sys

top = sys.argv[1]
TAG = b"Signature: 8a477f597d28d172789f06886806bc55"
PROTECTED = (".git", "data", "state", "config", "projects")
protected_ids = set()
DIRFLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def warn(msg):
    sys.stderr.write("orca-worktree-archive: warning: %s\n" % msg)


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
    p = os.fsdecode(raw).rstrip("\n")
    return p if os.path.isabs(p) else os.path.join(top, p)


index_path = top_path(git_out("rev-parse", "--git-path", "index"))
try:
    if not stat.S_ISREG(os.stat(index_path).st_mode):
        raise OSError("not a regular file")
except OSError:
    warn("git index missing; nothing cleaned")
    sys.exit(0)
for opt in ("--git-dir", "--git-common-dir"):
    try:
        gst = os.stat(top_path(git_out("rev-parse", opt)))
    except OSError:
        warn("cannot resolve %s; nothing cleaned" % opt)
        sys.exit(0)
    protected_ids.add((gst.st_dev, gst.st_ino))

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


def has_git_entry(fd):
    return any(e.lower() == ".git" for e in os.listdir(fd))


def contains_nested_git(fd):
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
                if contains_tracked(sub):
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
