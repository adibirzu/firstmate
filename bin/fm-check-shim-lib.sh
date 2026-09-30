#!/usr/bin/env bash
# fm-check-shim-lib.sh - the single owner of writing and registering a custom
# watcher check shim (state/<id>.check.sh) and its rollback contract.
#
# Sourced, never executed. Every helper that arms a watcher check goes through
# this one implementation, so the symlink refusal, the same-device private write,
# the byte-for-byte trust binding, and the no-unregistered-shim guarantee cannot
# drift between callers.
#
#   fm_check_shim_install <script-dir> <state> <id> <content>
#       Write <content> to <state>/<id>.check.sh at mode 0700 and bind its bytes
#       with <script-dir>/fm-check-register.sh. Refuses a symlink at the shim
#       path instead of following it; writes by rename so the watcher never reads
#       a half-written shim; and on any failure or interruption leaves NO
#       unregistered shim behind. A shim that was already armed is restored only
#       when its trust binding still covers it, and is otherwise removed so the
#       home is plainly not armed. Prints "armed: state/<id>.check.sh" on
#       success and its own diagnostic on stderr. Returns 0 or 1.
#
#   fm_check_shim_remove <state> <id>
#       Remove the shim and its trust binding. A caller owns any additional
#       record cleanup of its own.
#
# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks until someone deletes it by
# hand. That is the failure the install contract exists to prevent.
set -u

FM_CHECK_SHIM_PATH=
FM_CHECK_SHIM_STATE=
FM_CHECK_SHIM_ID=
FM_CHECK_SHIM_REGISTER=
FM_CHECK_SHIM_WRITE_TMP=
FM_CHECK_SHIM_BACKUP=

# shellcheck source=bin/fm-pr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-check-lib.sh"

# Restore the bytes a home had before this install started, but only while the
# trust binding still covers them; otherwise drop the shim. Either way no
# unregistered shim survives.
fm_check_shim_rollback() {
  [ -z "$FM_CHECK_SHIM_WRITE_TMP" ] || rm -f -- "$FM_CHECK_SHIM_WRITE_TMP"
  FM_CHECK_SHIM_WRITE_TMP=
  if [ -n "$FM_CHECK_SHIM_BACKUP" ]; then
    mv -f -- "$FM_CHECK_SHIM_BACKUP" "$FM_CHECK_SHIM_PATH" 2>/dev/null \
      || rm -f -- "$FM_CHECK_SHIM_BACKUP"
    FM_CHECK_SHIM_BACKUP=
    if fm_custom_check_registered "$FM_CHECK_SHIM_STATE" "$FM_CHECK_SHIM_ID"; then
      return 0
    fi
  fi
  rm -f -- "$FM_CHECK_SHIM_PATH"
}

fm_check_shim_interrupted() {
  fm_check_shim_rollback
  printf 'fm-check-shim: arming was interrupted, so state/%s.check.sh is not armed\n' "$FM_CHECK_SHIM_ID" >&2
  exit 1
}

# A byte copy of a shim already in place, so a failed arm can put back what a
# working home was using rather than an equivalent rewrite. The trust binding is
# over the bytes, so a rewrite would satisfy it too, but a home that was armed
# stays armed with what it had.
fm_check_shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$FM_CHECK_SHIM_STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$FM_CHECK_SHIM_STATE/.fm-check-shim.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$FM_CHECK_SHIM_PATH" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

fm_check_shim_write() {  # <content>
  local want=$1 device tmp
  [ -d "$FM_CHECK_SHIM_STATE" ] && [ ! -L "$FM_CHECK_SHIM_STATE" ] || return 1
  device=$(fm_pr_file_device "$FM_CHECK_SHIM_STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$FM_CHECK_SHIM_PATH" "$device" || return 1
  if [ -e "$FM_CHECK_SHIM_PATH" ] && [ "$(fm_pr_file_mode "$FM_CHECK_SHIM_PATH")" = 700 ] \
    && [ "$(cat "$FM_CHECK_SHIM_PATH" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$FM_CHECK_SHIM_STATE/.fm-check-shim.XXXXXX" 2>/dev/null) || return 1
  FM_CHECK_SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    FM_CHECK_SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$FM_CHECK_SHIM_PATH" "$device" \
    || ! mv -f -- "$tmp" "$FM_CHECK_SHIM_PATH"; then
    rm -f -- "$tmp"
    FM_CHECK_SHIM_WRITE_TMP=
    return 1
  fi
  FM_CHECK_SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$FM_CHECK_SHIM_PATH" 700 "$device"
}

fm_check_shim_install() {  # <script-dir> <state> <id> <content>
  local script_dir=$1 state=$2 id=$3 want=$4
  local device prev_hup prev_int prev_term rc=0
  fm_pr_task_id_valid "$id" || {
    printf 'fm-check-shim: invalid check id: %s\n' "$id" >&2
    return 1
  }
  [ -d "$state" ] && [ ! -L "$state" ] || {
    printf 'fm-check-shim: state directory is unavailable: %s\n' "$state" >&2
    return 1
  }
  FM_CHECK_SHIM_STATE=$state
  FM_CHECK_SHIM_ID=$id
  FM_CHECK_SHIM_PATH="$state/$id.check.sh"
  FM_CHECK_SHIM_REGISTER="$script_dir/fm-check-register.sh"
  FM_CHECK_SHIM_WRITE_TMP=
  FM_CHECK_SHIM_BACKUP=
  if [ ! -f "$FM_CHECK_SHIM_REGISTER" ] || [ -L "$FM_CHECK_SHIM_REGISTER" ] \
    || [ ! -x "$FM_CHECK_SHIM_REGISTER" ]; then
    printf 'fm-check-shim: register helper is unavailable: %s\n' "$FM_CHECK_SHIM_REGISTER" >&2
    return 1
  fi
  device=$(fm_pr_file_device "$state") || {
    printf 'fm-check-shim: state directory is unavailable: %s\n' "$state" >&2
    return 1
  }
  fm_pr_regular_destination_on_device_or_absent "$FM_CHECK_SHIM_PATH" "$device" || {
    printf 'fm-check-shim: shim path is unavailable: %s\n' "$FM_CHECK_SHIM_PATH" >&2
    return 1
  }
  if [ -f "$FM_CHECK_SHIM_PATH" ] && [ ! -L "$FM_CHECK_SHIM_PATH" ]; then
    FM_CHECK_SHIM_BACKUP=$(fm_check_shim_backup) || {
      printf 'fm-check-shim: could not save the existing %s\n' "$FM_CHECK_SHIM_PATH" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  prev_hup=$(trap -p HUP)
  prev_int=$(trap -p INT)
  prev_term=$(trap -p TERM)
  trap fm_check_shim_interrupted HUP INT TERM
  if ! fm_check_shim_write "$want"; then
    rc=1
  elif ! FM_STATE_OVERRIDE="$state" "$FM_CHECK_SHIM_REGISTER" "$id" >/dev/null; then
    rc=1
  fi
  eval "${prev_hup:-trap - HUP}"
  eval "${prev_int:-trap - INT}"
  eval "${prev_term:-trap - TERM}"
  if [ "$rc" -ne 0 ]; then
    fm_check_shim_rollback
    printf 'fm-check-shim: could not arm state/%s.check.sh\n' "$id" >&2
    return 1
  fi
  [ -z "$FM_CHECK_SHIM_BACKUP" ] || rm -f -- "$FM_CHECK_SHIM_BACKUP"
  FM_CHECK_SHIM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$id"
  return 0
}

fm_check_shim_remove() {  # <state> <id>
  local state=$1 id=$2
  fm_pr_task_id_valid "$id" || return 1
  rm -f -- "$state/$id.check.sh" "$state/$id.check-trust"
}
