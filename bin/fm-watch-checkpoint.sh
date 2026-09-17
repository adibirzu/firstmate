#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
#
# An internal continuity wake (`check: rearm-resurface`) is absorbed, not
# passed through: it announces durable queue content from a watcher-down gap,
# which the post-checkpoint drain already surfaces, so ending the bounded run
# on it would trade the full supervision budget for an instant exit and leave
# the turn-end guard with no live watcher. Absorbed runs retry until the
# budget expires or a genuine external wake arrives.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
An internal `check: rearm-resurface` continuity wake is absorbed and retried
until the budget expires: the durable queue it announces is preserved for the
post-checkpoint drain.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

run_with_perl_timeout() {  # <seconds>
  perl -e '
    my $seconds = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      my $grace = $ENV{FM_SIGNAL_GRACE} || 5;
      local $SIG{ALRM} = sub {
        kill "KILL", -$pid;
        waitpid $pid, 0;
        exit 124;
      };
      alarm $grace;
      waitpid $pid, 0;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    alarm 0;
    exit($? >> 8);
  ' "$1" "$SCRIPT_DIR/fm-watch.sh"
}

run_watcher_once() {  # <seconds>
  if command -v timeout >/dev/null 2>&1; then
    timeout "$1" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$1" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  else
    run_with_perl_timeout "$1" >"$OUT" 2>"$ERR"
  fi
}

out_has_external_wake() {
  grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null \
    | grep -v -x 'check: rearm-resurface' | grep -q .
}

out_has_rearm_only() {
  grep -qx 'check: rearm-resurface' "$OUT" 2>/dev/null
}

quiet_exit() {
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  if [ "$REARM_ABSORBED" -gt 0 ]; then
    printf 'checkpoint: absorbed %s internal rearm-resurface event(s); durable queue preserved for drain\n' "$REARM_ABSORBED" >&2
  fi
  local state="${FM_STATE_OVERRIDE:-${FM_HOME:-$PWD}/state}"
  local lock_pid
  if [ -f "$state/.watch.lock/pid" ]; then
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      rm -rf "$state/.watch.lock" 2>/dev/null || true
    fi
  fi
  exit 124
}

# Wall-clock seconds for the retry budget. $EPOCHSECONDS is a bash-builtin
# clock, so a PATH shim over date(1) - the wake-queue suites freeze time that
# way - cannot freeze this budget and trap the retry loop.
now_s() {
  if [ -n "${EPOCHSECONDS:-}" ]; then
    printf '%s\n' "$EPOCHSECONDS"
  else
    date +%s
  fi
}

DEADLINE=$(( $(now_s) + SECONDS_ARG ))
REARM_ABSORBED=0
RETRY_SLEEP=${FM_POLL:-15}
case "$RETRY_SLEEP" in ''|*[!0-9]*) RETRY_SLEEP=15 ;; esac
[ "$RETRY_SLEEP" -gt 0 ] || RETRY_SLEEP=15

while :; do
  NOW=$(now_s)
  REMAINING=$(( DEADLINE - NOW ))
  if [ "$REMAINING" -le 0 ]; then
    quiet_exit
  fi

  set +e
  run_watcher_once "$REMAINING"
  RC=$?
  set -e

  if out_has_external_wake; then
    cat "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit 0
  fi

  if out_has_rearm_only; then
    REARM_ABSORBED=$((REARM_ABSORBED + 1))
    NOW=$(now_s)
    REMAINING=$(( DEADLINE - NOW ))
    if [ "$REMAINING" -gt 0 ]; then
      if [ "$RETRY_SLEEP" -gt "$REMAINING" ]; then
        sleep "$REMAINING" || true
      else
        sleep "$RETRY_SLEEP" || true
      fi
    fi
    continue
  fi

  if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
    [ ! -s "$OUT" ] || cat "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
    exit 1
  fi

  if [ "$RC" -eq 124 ]; then
    quiet_exit
  fi

  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit "$RC"
done
