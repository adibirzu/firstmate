#!/usr/bin/env bash
# fm-marker-lib.sh - single owner of the persistent per-window watcher marker
# key (fm_window_marker_key), and the compatibility entry point for
# from-firstmate routing.
#
# fm_window_marker_key is the one key scheme behind every per-window watcher
# marker family under state/ (.hash-, .count-, .stale-, .stale-since-,
# .paused-*, .wedge-escalations-, .writing-*) and the herdr adapter's
# .herdr-escalated- dedupe marker. bin/fm-watch.sh, bin/fm-supervise-daemon.sh, and
# bin/backends/herdr.sh all source it here so a marker one writer records is
# the marker another writer clears. Pinned by tests/fm-watch-triage.test.sh
# (test_window_marker_keys_are_injective_and_ignore_legacy_state) and
# tests/fm-backend-herdr.test.sh (test_escalation_marker_keys_like_watcher).
#
# bin/fm-operational-input.sh owns current operational-input construction,
# parsing, marker bytes, and the established from-firstmate compatibility
# carrier. Existing callers source this path so they do not need a flag-day
# migration. No side effects on source. set -u / set -e safe.

_FM_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-operational-input.sh
. "$_FM_MARKER_LIB_DIR/fm-operational-input.sh"

# Persistent watcher-marker identity is shared with the away-mode daemon, which
# clears watcher pause and stale state. Encode each endpoint byte so the key is
# injective, filename-safe, and independent of other recorded endpoints.
fm_window_marker_key() {  # <window>
  local LC_ALL=C value=$1 i byte hex
  printf 'v2-'
  for ((i = 0; i < ${#value}; i++)); do
    printf -v byte '%d' "'${value:i:1}"
    printf -v hex '%02x' "$((byte & 0xff))"
    printf '%s' "$hex"
  done
}

unset _FM_MARKER_LIB_DIR
