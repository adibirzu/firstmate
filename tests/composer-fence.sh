#!/usr/bin/env bash
# Shared composer-classification fence for the per-harness adapter suites.
#
# Every backend now reaches its composer verdict through the one shared owner
# (bin/fm-composer-lib.sh, fm_composer_classify_screen), so a per-backend idle or
# bare-prompt override no longer exists to grep for - and could not take effect
# if it did.
# What still needs a fence is the guarantee those greps were protecting: a
# composer row that is genuinely empty must read `empty` under EVERY backend's
# declared capabilities, so a newly verified harness is taught once in the shared
# defaults and every backend picks it up.
#
# The capability descriptors come from each backend's OWN composer_caps function
# rather than a hand-written copy, so a backend whose declared capabilities drift
# is still exercised here.
#
# Scope is the plain (styled=0) capture shape, which is where the shared idle and
# bare-prompt defaults are what recognize an empty composer.
# Under a styled capture it is the shared ghost-stripper that does, because an
# undimmed placeholder is genuinely indistinguishable from typed input; that path
# has its own coverage in tests/fm-composer-ghost.test.sh.
#
# Sourced after tests/lib.sh (for ROOT and fail) by the suites that need it.

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

# The backends that publish a static plain-capture capability descriptor.
FM_TEST_COMPOSER_PLAIN_BACKENDS="orca cmux"

# fm_test_composer_reads_empty: assert <screen> classifies as `empty` under every
# plain-capture backend's own declared capabilities.
fm_test_composer_reads_empty() {  # <screen> <description>
  local screen=$1 what=$2 name caps verdict checked=0
  for name in $FM_TEST_COMPOSER_PLAIN_BACKENDS; do
    fm_backend_source "$name" >/dev/null 2>&1 \
      || fail "could not source the $name adapter to read its own composer capabilities"
    caps=$("fm_backend_${name}_composer_caps") \
      || fail "$name publishes no composer capability descriptor for this fence to use"
    case "$caps" in
      *styled=0*) ;;
      *) fail "$name no longer declares a plain (styled=0) capture; this fence governs the plain path" ;;
    esac
    checked=$((checked + 1))
    verdict=$(fm_composer_classify_screen "$caps" "$screen")
    [ "$verdict" = empty ] \
      || fail "$what read '$verdict' instead of empty under $name's own declared capabilities"
  done
  [ "$checked" -gt 0 ] \
    || fail "no backend capability descriptor was exercised for $what"
}

# fm_test_composer_bordered_row: the bordered composer box every adapter sees,
# drawn around <content>.
fm_test_composer_bordered_row() {  # <content>
  printf '%s\n%s\n%s\n' \
    '╭──────────────────────────────╮' \
    "$(printf '│ %-28s │' "$1")" \
    '╰──────────────────────────────╯'
}
