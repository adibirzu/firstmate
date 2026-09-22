#!/usr/bin/env bash
# fm-nm-update-window.sh - bring one host's no-mistakes install to a target
# version through the beta channel, waiting for a genuinely quiet moment first.
#
# Usage:
#   fm-nm-update-window.sh [local|<route>] [--max-wait <seconds>] [--target <version>] [--interval <seconds>]
#   fm-nm-update-window.sh --help
#
# With no route, or the literal route `local`, this updates the host it runs
# on. With any other route it re-execs itself on that host through this
# checkout's existing remote-command path (bin/fm-on.sh, which resolves the
# route from data/secondmates.md), stripping the route so the remote copy runs
# its local path; no second SSH-wrapping mechanism lives here.
#
# The wait loop never polls run state itself. `no-mistakes update` without
# --force already refuses while pipeline runs are active (its --help describes
# --force as "update and restart the daemon even when pipeline runs are
# active", and the installed binary's strings confirm the update path restarts
# the daemon itself: "update and restart the daemon even when pipeline runs
# are active"). So this loop simply attempts `no-mistakes update --beta` on a
# bounded backoff until it succeeds or --max-wait is exceeded, and surfaces
# the command's own refusal message verbatim instead of re-deriving it.
#
# On success there is deliberately no separate `no-mistakes daemon restart`:
# update already resets the daemon, and a redundant restart would re-hit the
# active-runs guard (whose --force twin is equally forbidden here) if a new
# run landed in between. Verification is `no-mistakes --version` (must reach
# the target), `no-mistakes daemon status`, and `no-mistakes doctor`.
#
# --force is never passed, to any command, under any condition. The mutating
# argv in this file is the fixed literal `update --beta`; no variable is ever
# interpolated into a no-mistakes mutating command, so no flag can smuggle
# --force in. An earlier force-restart while runs were active was a real
# disruptive incident, and this script exists specifically to avoid repeating
# it.
#
# The script is idempotent: when the installed version already meets the
# target it reports "already current" and changes nothing.
#
# A single update attempt is not time-boxed here (a download can legitimately
# take minutes), so --max-wait bounds the wait between attempts, not one hung
# attempt. Test seams are NO_MISTAKES_BIN (default no-mistakes) and
# FM_NM_UPDATE_WINDOW_FM_ON (default bin/fm-on.sh beside this script).
#
# What stays untested pending a real supervised run: the live update itself
# (unsafe against a real daemon in CI or casually), the exact refusal text a
# busy daemon returns, and the remote path against a real secondmate host.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NM_BIN="${NO_MISTAKES_BIN:-no-mistakes}"
FM_ON_BIN="${FM_NM_UPDATE_WINDOW_FM_ON:-$SCRIPT_DIR/fm-on.sh}"
TARGET_DEFAULT="1.80.1"
MAX_WAIT_DEFAULT=1800
INTERVAL_DEFAULT=60

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; }

ROUTE=""
MAX_WAIT=$MAX_WAIT_DEFAULT
TARGET=$TARGET_DEFAULT
INTERVAL=$INTERVAL_DEFAULT

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --max-wait) [ $# -ge 2 ] || { usage >&2; die "missing value for --max-wait" 2; }; MAX_WAIT=$2; shift 2 ;;
    --target) [ $# -ge 2 ] || { usage >&2; die "missing value for --target" 2; }; TARGET=$2; shift 2 ;;
    --interval) [ $# -ge 2 ] || { usage >&2; die "missing value for --interval" 2; }; INTERVAL=$2; shift 2 ;;
    --*) usage >&2; die "unknown flag: $1" 2 ;;
    *) [ -z "$ROUTE" ] || { usage >&2; die "only one host route is accepted: $ROUTE and $1" 2; }; ROUTE=$1; shift ;;
  esac
done

case "$MAX_WAIT" in ''|*[!0-9]*) usage >&2; die "--max-wait must be a non-negative integer in seconds: $MAX_WAIT" 2 ;; esac
case "$INTERVAL" in ''|*[!0-9]*|0) usage >&2; die "--interval must be a positive integer in seconds: $INTERVAL" 2 ;; esac
case "$TARGET" in
  [0-9]*.*) ;;
  *) usage >&2; die "--target must be a dotted version such as 1.80.1: $TARGET" 2 ;;
esac
case "$TARGET" in *[!0-9.]*) usage >&2; die "--target must be a dotted version such as 1.80.1: $TARGET" 2 ;; esac

# --- remote delegation -------------------------------------------------------
# A named route re-runs this same tracked script on that host; the remote copy
# gets the flags but no route, so it takes the local path below. stdin is
# /dev/null so a remote prompt can never hang on an open caller stream.
if [ -n "$ROUTE" ] && [ "$ROUTE" != "local" ]; then
  exec "$FM_ON_BIN" "$ROUTE" fm-nm-update-window.sh \
    --max-wait "$MAX_WAIT" --target "$TARGET" --interval "$INTERVAL" < /dev/null
fi

# --- local path --------------------------------------------------------------
case "$NM_BIN" in
  */*) [ -x "$NM_BIN" ] || die "no-mistakes binary is not executable: $NM_BIN" ;;
  *) command -v "$NM_BIN" >/dev/null 2>&1 || die "no-mistakes is not on PATH" ;;
esac

# Extract the first dotted numeric version from `no-mistakes --version`, whose
# shape is "no-mistakes version v1.79.0 (fc540ac) 2026-09-19T09:34:44Z".
installed_version() {
  "$NM_BIN" --version 2>/dev/null | grep -o -E '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -n 1 || true
}

# vercmp <a> <b>: prints -1, 0, or 1 comparing dotted numeric versions.
vercmp() {
  local a=$1 b=$2 af bf
  while [ -n "$a" ] || [ -n "$b" ]; do
    case "$a" in *.*) af=${a%%.*}; a=${a#*.} ;; *) af=$a; a="" ;; esac
    case "$b" in *.*) bf=${b%%.*}; b=${b#*.} ;; *) bf=$b; b="" ;; esac
    af=${af:-0}
    bf=${bf:-0}
    [ "$af" -gt "$bf" ] 2>/dev/null && { printf '1\n'; return 0; }
    [ "$af" -lt "$bf" ] 2>/dev/null && { printf '-1\n'; return 0; }
  done
  printf '0\n'
}

CURRENT=$(installed_version)
if [ -n "$CURRENT" ]; then
  if [ "$(vercmp "$CURRENT" "$TARGET")" -ge 0 ]; then
    printf 'already current: no-mistakes %s meets target %s, nothing to do\n' "$CURRENT" "$TARGET"
    exit 0
  fi
  printf 'installed: %s, target: %s; waiting for a quiet window\n' "$CURRENT" "$TARGET"
else
  printf 'warning: could not parse installed version; attempting update to %s anyway\n' "$TARGET" >&2
fi

DEADLINE=$(( $(date +%s) + MAX_WAIT ))
ATTEMPT=0
LAST_REFUSAL=""
while true; do
  ATTEMPT=$((ATTEMPT + 1))
  if UPDATE_OUT=$("$NM_BIN" update --beta < /dev/null 2>&1); then
    printf 'update accepted on attempt %d\n' "$ATTEMPT"
    printf '%s\n' "$UPDATE_OUT"
    break
  else
    LAST_REFUSAL=$UPDATE_OUT
    printf 'attempt %d refused:\n%s\n' "$ATTEMPT" "$UPDATE_OUT"
  fi
  NOW=$(date +%s)
  if [ "$NOW" -ge "$DEADLINE" ]; then
    printf 'error: max-wait %ss exceeded after %d attempt(s); last refusal was:\n%s\n' \
      "$MAX_WAIT" "$ATTEMPT" "$LAST_REFUSAL" >&2
    exit 1
  fi
  REMAINING=$((DEADLINE - NOW))
  WAIT=$INTERVAL
  [ "$WAIT" -le "$REMAINING" ] || WAIT=$REMAINING
  printf 'waiting %ss for a quiet window (max-wait %ss)\n' "$WAIT" "$MAX_WAIT"
  sleep "$WAIT"
done

# --- verification --------------------------------------------------------------
NEW=$(installed_version)
if [ -z "$NEW" ]; then
  die "update ran but the installed version is unreadable; verify by hand with no-mistakes --version"
fi
[ "$(vercmp "$NEW" "$TARGET")" -ge 0 ] \
  || die "update ran but installed version $NEW is still below target $TARGET"
printf 'updated: %s -> %s\n' "${CURRENT:-unknown}" "$NEW"

DAEMON_OUT=$("$NM_BIN" daemon status < /dev/null 2>&1) \
  || die "update applied ($NEW) but the daemon is not healthy: $DAEMON_OUT"
printf 'daemon: %s\n' "$DAEMON_OUT"

DOCTOR_OUT=$("$NM_BIN" doctor < /dev/null 2>&1) \
  || { printf '%s\n' "$DOCTOR_OUT" >&2; die "update applied ($NEW) but no-mistakes doctor is not all-green"; }
printf 'doctor: ok\n'
printf 'done: no-mistakes %s via --beta (from %s), daemon healthy, doctor green\n' "$NEW" "${CURRENT:-unknown}"
