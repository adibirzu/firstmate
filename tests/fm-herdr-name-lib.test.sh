#!/usr/bin/env bash
# tests/fm-herdr-name-lib.test.sh - unit tests for the Herdr session display
# name (bin/fm-herdr-name-lib.sh).
#
# The display name is <prefix>-[<host>-][<owner>-]<project>-<task-id>, with the prefix
# from config/herdr-session-prefix (default adix), the host segment present
# only when the home has an explicit host token, and the owner naming the
# launching firstmate home (empty keeps the legacy owner-less shape). It is additive and never an
# identity (AGENTS.md task fm-herdr-session-naming). These tests exercise the
# library's public functions only; the end-to-end wiring (fm-spawn applying the
# label to a real tab, the adapter's legacy-alias husk handling, the remote
# launch seeding config/herdr-session-host) is covered behaviorally by
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

long=$(printf 'x%.0s' $(seq 1 200))
out=$(fm_herdr_name_sanitize "$long")
[ "${#out}" -le 48 ] || fail "a segment must be capped at 48 chars, got ${#out}"
pass "fm_herdr_name_sanitize caps a segment length"

# --- prefix ------------------------------------------------------------------

cfg="$TMP_ROOT/cfg"; mkdir -p "$cfg"
[ "$(fm_herdr_name_prefix "$cfg")" = 'adix' ] || fail "an absent prefix config must default to adix, got '$(fm_herdr_name_prefix "$cfg")'"
pass "fm_herdr_name_prefix defaults to adix"

printf 'acme\n' > "$cfg/$FM_HERDR_NAME_PREFIX_CONFIG"
[ "$(fm_herdr_name_prefix "$cfg")" = 'acme' ] || fail "the configured prefix must be read"
pass "fm_herdr_name_prefix reads config/herdr-session-prefix"

printf '  \n' > "$cfg/$FM_HERDR_NAME_PREFIX_CONFIG"
[ "$(fm_herdr_name_prefix "$cfg")" = 'adix' ] || fail "an empty prefix must fall back to adix, got '$(fm_herdr_name_prefix "$cfg")'"
pass "fm_herdr_name_prefix falls back to adix on an empty config"

printf 'Acme/Brand\n' > "$cfg/$FM_HERDR_NAME_PREFIX_CONFIG"
[ "$(fm_herdr_name_prefix "$cfg")" = 'Acme-Brand' ] || fail "the configured prefix must be sanitized, got '$(fm_herdr_name_prefix "$cfg")'"
pass "fm_herdr_name_prefix sanitizes the configured value"
rm -f "$cfg/$FM_HERDR_NAME_PREFIX_CONFIG"

# --- optional host -----------------------------------------------------------

[ -z "$(fm_herdr_name_host_optional "$cfg")" ] || fail "an unconfigured home must have NO host segment, got '$(fm_herdr_name_host_optional "$cfg")'"
pass "fm_herdr_name_host_optional is empty when this home has no host token"

printf ' adi1 \n' > "$cfg/$FM_HERDR_NAME_HOST_CONFIG"
[ "$(fm_herdr_name_host_optional "$cfg")" = 'adi1' ] || fail "config/herdr-session-host must supply and trim the host token"
pass "fm_herdr_name_host_optional reads and trims config/herdr-session-host"

[ "$(FM_HERDR_HOST='adi2-ts' fm_herdr_name_host_optional "$cfg")" = 'adi2-ts' ] || fail "FM_HERDR_HOST must win over the config file"
pass "fm_herdr_name_host_optional prefers an explicit FM_HERDR_HOST"

[ -z "$(FM_HERDR_HOST='' fm_herdr_name_host_optional "$TMP_ROOT/no-such-config")" ] || fail "an absent host config and no FM_HERDR_HOST must be empty, never the machine hostname"
pass "fm_herdr_name_host_optional never falls back to the machine hostname"
rm -f "$cfg/$FM_HERDR_NAME_HOST_CONFIG"

# --- task segment ------------------------------------------------------------

[ "$(fm_herdr_name_task_segment 'fm-herdr-session-naming')" = 'herdr-session-naming' ] || fail "one leading fm- must be stripped"
pass "fm_herdr_name_task_segment strips one leading fm-"

[ "$(fm_herdr_name_task_segment 'herdr-sm-spaces-k4')" = 'herdr-sm-spaces-k4' ] || fail "an id without fm- must be untouched"
pass "fm_herdr_name_task_segment leaves an id without the fm- prefix untouched"

# --- label composition -------------------------------------------------------

[ "$(fm_herdr_name_label adix '' firstmate fm-herdr-session-naming)" = 'adix-firstmate-herdr-session-naming' ] || fail "plain label composition"
pass "fm_herdr_name_label composes <prefix>-<project>-<task> with no host"

[ "$(fm_herdr_name_label adix adi1 firstmate fm-herdr-session-naming)" = 'adix-adi1-firstmate-herdr-session-naming' ] || fail "host must sit after the prefix, got '$(fm_herdr_name_label adix adi1 firstmate fm-herdr-session-naming)'"
pass "fm_herdr_name_label inserts the host after the prefix"

[ "$(fm_herdr_name_label adix adi1 lifeos-adi1 lifeos-adi1)" = 'adix-adi1-lifeos-adi1' ] || fail "an adjacent duplicate segment (secondmate) must collapse, got '$(fm_herdr_name_label adix adi1 lifeos-adi1 lifeos-adi1)'"
pass "fm_herdr_name_label collapses an adjacent duplicate segment"

[ "$(fm_herdr_name_label '' '' firstmate fm-a)" = 'adix-firstmate-a' ] || fail "an empty prefix must fall back to adix"
pass "fm_herdr_name_label falls back to the adix prefix"

[ "$(fm_herdr_name_label acme '' usage-axi add-quota-window)" = 'acme-usage-axi-add-quota-window' ] || fail "a custom prefix must be honored"
pass "fm_herdr_name_label honors a custom prefix"

# --- label_for: the one-call composer fm-spawn uses --------------------------

[ "$(fm_herdr_name_label_for "$cfg" ship add-quota-window /x/projects/usage-axi)" = 'adix-usage-axi-add-quota-window' ] || fail "ship label_for uses the project directory basename"
pass "fm_herdr_name_label_for uses the project directory name for a ship"

[ "$(fm_herdr_name_label_for "$cfg" ship herdr-session-naming /Volumes/ExternalNVME/GitHub/firstmate)" = 'adix-firstmate-herdr-session-naming' ] || fail "a firstmate-repo task must use the 'firstmate' project name"
pass "fm_herdr_name_label_for names a firstmate-repo task's project 'firstmate'"

[ "$(fm_herdr_name_label_for "$cfg" secondmate lifeos-adi1 /home/adi/.firstmate-lifeos)" = 'adix-lifeos-adi1' ] || fail "a secondmate agent must use its own id as the project"
pass "fm_herdr_name_label_for names a secondmate agent by its own id"

printf 'adi1\n' > "$cfg/$FM_HERDR_NAME_HOST_CONFIG"
[ "$(fm_herdr_name_label_for "$cfg" secondmate lifeos-adi1 /home/adi/.firstmate-lifeos)" = 'adix-adi1-lifeos-adi1' ] || fail "a host-configured home must add the host segment"
pass "fm_herdr_name_label_for adds the host segment only for a host-configured home"
rm -f "$cfg/$FM_HERDR_NAME_HOST_CONFIG"

printf 'acme\n' > "$cfg/$FM_HERDR_NAME_PREFIX_CONFIG"
[ "$(fm_herdr_name_label_for "$cfg" ship fm-herdr-session-naming /x/projects/firstmate)" = 'acme-firstmate-herdr-session-naming' ] || fail "a configured prefix must flow through label_for"
pass "fm_herdr_name_label_for honors the configured prefix"

# --- seed host config --------------------------------------------------------

seedhome="$TMP_ROOT/seedhome"; mkdir -p "$seedhome/config"
fm_herdr_name_seed_host_config "$seedhome" ' adi1 '
[ "$(cat "$seedhome/config/$FM_HERDR_NAME_HOST_CONFIG" 2>/dev/null)" = 'adi1' ] || fail "an absent host config must be seeded with the sanitized token"
pass "fm_herdr_name_seed_host_config writes config/herdr-session-host when absent"

printf 'manual\n' > "$seedhome/config/$FM_HERDR_NAME_HOST_CONFIG"
fm_herdr_name_seed_host_config "$seedhome" 'adi2'
[ "$(cat "$seedhome/config/$FM_HERDR_NAME_HOST_CONFIG")" = 'manual' ] || fail "an existing host config must never be overwritten"
pass "fm_herdr_name_seed_host_config never clobbers an existing operator override"

noconfighome="$TMP_ROOT/noconfighome"; mkdir -p "$noconfighome"
fm_herdr_name_seed_host_config "$noconfighome" 'adi3'
[ ! -e "$noconfighome/config" ] || fail "seeding must not create a missing config directory"
pass "fm_herdr_name_seed_host_config is a no-op without a config directory"

[ "$(fm_herdr_name_seed_host_config "$seedhome" '')" = '' ] || fail "an empty token is a no-op"
pass "fm_herdr_name_seed_host_config ignores an empty token"

# --- owner segment -----------------------------------------------------------

[ "$(fm_herdr_name_label adix '' firstmate fm-a)" = 'adix-firstmate-a' ] || fail "a 4-arg call must stay byte-identical without an owner, got '$(fm_herdr_name_label adix '' firstmate fm-a)'"
pass "fm_herdr_name_label keeps the legacy owner-less shape for 4-arg callers"

[ "$(fm_herdr_name_label adix '' firstmate fm-herdr-session-naming firstmate)" = 'adix-firstmate-herdr-session-naming' ] || fail "an owner equal to the project must collapse, got '$(fm_herdr_name_label adix '' firstmate fm-herdr-session-naming firstmate)'"
pass "fm_herdr_name_label collapses an owner that duplicates the project"

[ "$(fm_herdr_name_label adix adi1 usage-axi fm-add-quota-window '2m-lifeos-adi1')" = 'adix-adi1-2m-lifeos-adi1-usage-axi-add-quota-window' ] || fail "the owner must sit after the host, got '$(fm_herdr_name_label adix adi1 usage-axi fm-add-quota-window '2m-lifeos-adi1')'"
pass "fm_herdr_name_label inserts the owner after the host"

[ "$(fm_herdr_name_label adix '' usage-axi fm-add-quota-window '2m-lifeos-adi1')" = 'adix-2m-lifeos-adi1-usage-axi-add-quota-window' ] || fail "the owner must be present without a host, got '$(fm_herdr_name_label adix '' usage-axi fm-add-quota-window '2m-lifeos-adi1')'"
pass "fm_herdr_name_label carries the owner with no host configured"

[ "$(fm_herdr_name_label adix '' lifeos-adi1 lifeos-adi1 firstmate)" = 'adix-firstmate-lifeos-adi1' ] || fail "a secondmate agent tab must name its launcher, got '$(fm_herdr_name_label adix '' lifeos-adi1 lifeos-adi1 firstmate)'"
pass "fm_herdr_name_label names a secondmate agent's launcher while the duplicate project collapses"

rm -f "$cfg/$FM_HERDR_NAME_PREFIX_CONFIG"
[ "$(fm_herdr_name_label_for "$cfg" ship fm-herdr-session-naming /x/projects/firstmate firstmate)" = 'adix-firstmate-herdr-session-naming' ] || fail "a primary-home firstmate-repo task must not repeat firstmate, got '$(fm_herdr_name_label_for "$cfg" ship fm-herdr-session-naming /x/projects/firstmate firstmate)'"
pass "fm_herdr_name_label_for collapses a primary owner against the firstmate project"

[ "$(fm_herdr_name_label_for "$cfg" secondmate lifeos-adi1 /home/adi/.firstmate-lifeos firstmate)" = 'adix-firstmate-lifeos-adi1' ] || fail "a launched secondmate agent must carry its launcher, got '$(fm_herdr_name_label_for "$cfg" secondmate lifeos-adi1 /home/adi/.firstmate-lifeos firstmate)'"
pass "fm_herdr_name_label_for names the launcher on a secondmate agent tab"

# --- truncation rule ---------------------------------------------------------
# Herdr right-truncates each sidebar token with U+2026 when it exceeds the
# visible cells (measured against the real 0.9.0 client: a 26-column default
# sidebar leaves ~22 cells for a spaces-row label after the leading marker,
# and ~18 cells for an indented agents/grouped-row label). The composer never
# pre-truncates - the tab strip renders full labels - so this helper simulates
# Herdr's own renderer to pin the degradation order: the fixed fleet head
# (prefix, owner) must survive while only the work tail is eaten.

herdr_sidebar_truncate() {  # <budget-cells> <text>
  local budget=$1 text=$2
  if [ "${#text}" -gt "$budget" ]; then
    printf '%s…' "${text:0:$((budget - 1))}"
  else
    printf '%s' "$text"
  fi
}

new_tab=$(fm_herdr_name_label adix adi1 usage-axi fm-add-quota-window '2m-lifeos-adi1')
[ "$(herdr_sidebar_truncate 22 "$new_tab")" = 'adix-adi1-2m-lifeos-a…' ] || fail "the 22-cell spaces budget must keep prefix, host, and owner head, got '$(herdr_sidebar_truncate 22 "$new_tab")'"
pass "a truncated tab still names the fleet and the owning firstmate at the spaces budget"

case "$(herdr_sidebar_truncate 18 "$new_tab")" in
  adix-adi1-2m-*) pass "a truncated tab still names the fleet and the owning firstmate at the grouped budget" ;;
  *) fail "the 18-cell grouped budget ate the owner head: '$(herdr_sidebar_truncate 18 "$new_tab")'" ;;
esac

old_tab=$(fm_herdr_name_label adix adi1 usage-axi fm-add-quota-window)
case "$(herdr_sidebar_truncate 22 "$old_tab")" in
  *2m-lifeos-adi1*) fail "the legacy owner-less shape must not name an owner" ;;
  *) pass "the legacy owner-less shape loses the owning firstmate under truncation" ;;
esac

[ "$(herdr_sidebar_truncate 18 '2m-lifeos-adi1')" = '2m-lifeos-adi1' ] || fail "the short mate workspace label must survive the grouped budget whole, got '$(herdr_sidebar_truncate 18 '2m-lifeos-adi1')'"
pass "the 2m-<id> workspace label survives the grouped budget whole"

[ "$(herdr_sidebar_truncate 18 '2ndmate-lifeos-adi1')" = '2ndmate-lifeos-ad…' ] || fail "the legacy mate workspace label must truncate its distinguishing tail first, got '$(herdr_sidebar_truncate 18 '2ndmate-lifeos-adi1')'"
pass "the legacy 2ndmate-<id> workspace label truncates its distinguishing tail at the grouped budget"
