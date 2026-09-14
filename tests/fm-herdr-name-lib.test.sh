#!/usr/bin/env bash
# tests/fm-herdr-name-lib.test.sh - unit tests for the Herdr session display
# name (bin/fm-herdr-name-lib.sh).
#
# The display name is fm-<host>-<project>-<task-id>; it is additive and never
# an identity (AGENTS.md task fm-herdr-session-naming). These tests exercise
# the library's public functions only. The end-to-end wiring (fm-spawn applying
# the label to a real tab, the adapter's legacy-alias husk handling, the remote
# launch threading the host token) is covered behaviorally by
# tests/fm-backend-herdr.test.sh, tests/fm-backend-herdr-smoke.test.sh, and
# tests/fm-remote-secondmate-lifecycle-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-name-lib-tests)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-name-lib.sh"

# --- sanitize ----------------------------------------------------------------

[ "$(fm_herdr_name_sanitize 'Adrians-Mini')" = 'Adrians-Mini' ] || fail "case and hyphens must be preserved"
pass "fm_herdr_name_sanitize preserves case and its own alphabet"

[ "$(fm_herdr_name_sanitize 'TMS Update drivers')" = 'TMS-Update-drivers' ] || fail "spaces must fold to single hyphens"
pass "fm_herdr_name_sanitize folds spaces to single hyphens"

[ "$(fm_herdr_name_sanitize '  a__b..c--d  ')" = 'a__b..c-d' ] || fail "leading/trailing separators must trim and interior hyphen runs must collapse, got '$(fm_herdr_name_sanitize '  a__b..c--d  ')'"
pass "fm_herdr_name_sanitize trims leading/trailing separators"

[ "$(fm_herdr_name_sanitize 'a/b:c*d')" = 'a-b-c-d' ] || fail "unsafe characters must fold to '-'"
pass "fm_herdr_name_sanitize folds unsafe characters"

[ "$(fm_herdr_name_sanitize '')" = '' ] || fail "an empty segment must stay empty"
pass "fm_herdr_name_sanitize maps an empty value to an empty segment"

# A segment is length-bounded so a runaway host or project name cannot produce
# an unbounded label.
long=$(printf 'x%.0s' $(seq 1 200))
out=$(fm_herdr_name_sanitize "$long")
[ "${#out}" -le 48 ] || fail "a segment must be capped at 48 chars, got ${#out}"
pass "fm_herdr_name_sanitize caps a segment length"

# --- task segment ------------------------------------------------------------

[ "$(fm_herdr_name_task_segment 'fm-herdr-session-naming')" = 'herdr-session-naming' ] || fail "one leading fm- must be stripped"
pass "fm_herdr_name_task_segment strips one leading fm-"

[ "$(fm_herdr_name_task_segment 'herdr-sm-spaces-k4')" = 'herdr-sm-spaces-k4' ] || fail "an id without fm- must be untouched"
pass "fm_herdr_name_task_segment leaves an id without the fm- prefix untouched"

[ "$(fm_herdr_name_task_segment 'fmmate')" = 'fmmate' ] || fail "only the exact fm- prefix is stripped"
pass "fm_herdr_name_task_segment strips only the exact fm- prefix"

# --- host precedence ---------------------------------------------------------

cfg="$TMP_ROOT/cfg"; mkdir -p "$cfg"
printf ' mini \n' > "$cfg/$FM_HERDR_NAME_HOST_CONFIG"
[ "$(fm_herdr_name_host "$cfg")" = 'mini' ] || fail "config/herdr-session-host must win over the hostname, got '$(fm_herdr_name_host "$cfg")'"
pass "fm_herdr_name_host reads and trims local config/herdr-session-host"

[ "$(FM_HERDR_HOST='adi1' fm_herdr_name_host "$cfg")" = 'adi1' ] || fail "FM_HERDR_HOST must win over the config file"
pass "fm_herdr_name_host prefers an explicit FM_HERDR_HOST"

# A missing, symlinked, or empty host config falls through to the hostname.
rm -f "$cfg/$FM_HERDR_NAME_HOST_CONFIG"
fakebin=$(fm_fakebin "$TMP_ROOT/hostfake")
cat > "$fakebin/hostname" <<'SH'
#!/usr/bin/env bash
printf 'Fallback-Box\n'
SH
chmod +x "$fakebin/hostname"
[ "$(PATH="$fakebin:$PATH" fm_herdr_name_host "$cfg")" = 'Fallback-Box' ] || fail "an absent host config must fall through to the short hostname"
pass "fm_herdr_name_host falls back to the machine hostname"

# --- label composition -------------------------------------------------------

[ "$(fm_herdr_name_label adi1 firstmate fm-herdr-session-naming)" = 'fm-adi1-firstmate-herdr-session-naming' ] || fail "crewmate label composition"
pass "fm_herdr_name_label composes fm-<host>-<project>-<task>"

[ "$(fm_herdr_name_label adi1 lifeos-adi1 lifeos-adi1)" = 'fm-adi1-lifeos-adi1' ] || fail "an adjacent duplicate segment (secondmate) must collapse, got '$(fm_herdr_name_label adi1 lifeos-adi1 lifeos-adi1)'"
pass "fm_herdr_name_label collapses an adjacent duplicate segment"

[ "$(fm_herdr_name_label '' 'firstmate' 'fm-a')" = 'fm-firstmate-a' ] || fail "an empty host segment must be omitted"
pass "fm_herdr_name_label omits an empty host segment"

# --- label_for: the one-call composer fm-spawn uses --------------------------

[ "$(FM_HERDR_HOST=adi2-ts fm_herdr_name_label_for /nonexistent ship add-quota-window /x/projects/usage-axi)" = 'fm-adi2-ts-usage-axi-add-quota-window' ] || fail "ship label_for uses the project directory basename"
pass "fm_herdr_name_label_for uses the project directory name for a ship"

[ "$(FM_HERDR_HOST=adi1 fm_herdr_name_label_for /nonexistent ship herdr-session-naming /Volumes/ExternalNVME/GitHub/firstmate)" = 'fm-adi1-firstmate-herdr-session-naming' ] || fail "a firstmate-repo task must use the 'firstmate' project name"
pass "fm_herdr_name_label_for names a firstmate-repo task's project 'firstmate'"

[ "$(FM_HERDR_HOST=adi1 fm_herdr_name_label_for /nonexistent secondmate lifeos-adi1 /home/adi/.firstmate-lifeos)" = 'fm-adi1-lifeos-adi1' ] || fail "a secondmate agent must use its own id as the project"
pass "fm_herdr_name_label_for names a secondmate agent by its own id"

[ "$(FM_HERDR_HOST=mini fm_herdr_name_label_for "$cfg" scout fm-herdr-session-naming /x/projects/firstmate)" = 'fm-mini-firstmate-herdr-session-naming' ] || fail "a scout uses the same composition"
pass "fm_herdr_name_label_for composes a scout label the same way"
