#!/usr/bin/env bash
# bin/fm-orca-worktree-setup.sh - Orca worktree setup for firstmate.
# Adds local-only git excludes for scratch artifacts and checks the core
# runtime binaries. Never installs packages, never touches data/, state/,
# config/ or projects/, never modifies tracked files, makes no network calls.
#
# Scope: `git rev-parse --git-common-dir` is the clone-local common git
# directory, so the excludes land in its info/exclude, which is shared by every
# linked worktree of this clone (never by other clones). The walk to that file
# never follows symlinks, holds an exclusive flock while appending, and refuses
# (warning, exit 0) when `info` or `exclude` is a symlink.
set -euo pipefail

warn() { printf 'orca-worktree-setup: warning: %s\n' "$*" >&2; }

add_excludes() {
  local top common
  if ! top=$(git rev-parse --show-toplevel 2>/dev/null); then
    warn 'not inside a git worktree; skipping excludes'
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn 'python3 missing; skipping excludes'
    return 0
  fi
  if ! common=$(git -C "$top" rev-parse --git-common-dir 2>/dev/null); then
    warn 'cannot resolve git common dir; skipping excludes'
    return 0
  fi
  case "$common" in
    /*) ;;
    *) common="$top/$common" ;;
  esac
  python3 -B -I - "$common" '__pycache__/' '*.pyc' '.ruff_cache/' 'firebase-debug.log' <<'PY'
import fcntl
import os
import sys

common, patterns = sys.argv[1], sys.argv[2:]


def warn(msg):
    sys.stderr.write("orca-worktree-setup: warning: %s\n" % msg)


DIRFLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
try:
    cfd = os.open(common, os.O_RDONLY | os.O_DIRECTORY)
except OSError as exc:
    warn("cannot open git common dir (%s); skipping excludes" % exc)
    sys.exit(0)
try:
    try:
        ifd = os.open("info", DIRFLAGS, dir_fd=cfd)
    except FileNotFoundError:
        os.mkdir("info", 0o755, dir_fd=cfd)
        ifd = os.open("info", DIRFLAGS, dir_fd=cfd)
except OSError as exc:
    warn("refusing info dir (%s); skipping excludes" % exc)
    sys.exit(0)
try:
    efd = os.open(
        "exclude", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644, dir_fd=ifd
    )
except OSError as exc:
    warn("refusing info/exclude (%s); skipping excludes" % exc)
    sys.exit(0)
try:
    fcntl.flock(efd, fcntl.LOCK_EX)
    data = b""
    while True:
        chunk = os.read(efd, 65536)
        if not chunk:
            break
        data += chunk
    lines = set(data.split(b"\n"))
    out = b""
    if data and not data.endswith(b"\n"):
        out += b"\n"
    for pat in patterns:
        raw = pat.encode()
        if raw not in lines:
            out += raw + b"\n"
    if out:
        os.lseek(efd, 0, os.SEEK_END)
        os.write(efd, out)
finally:
    os.close(efd)
PY
}

add_excludes

ok=""
missing=""
for tool in bash git jq python3; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok="$ok $tool"
  else
    missing="$missing $tool"
  fi
done

if [ -n "$missing" ]; then
  printf 'orca-worktree-setup: runtime ok:%s; missing:%s (install manually)\n' "${ok:- none}" "$missing"
else
  printf 'orca-worktree-setup: runtime ok:%s; excludes ready\n' "$ok"
fi
