#!/usr/bin/env bash
# Project skill profile + validation phase contracts.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

# shellcheck source=bin/fm-project-skills-lib.sh
. "$ROOT/bin/fm-project-skills-lib.sh"
# shellcheck source=bin/fm-validation-lib.sh
. "$ROOT/bin/fm-validation-lib.sh"

test_slug_and_always() {
  [ "$(fm_project_skills_slug /tmp/Foo-Bar.git)" = "foo-bar" ] || fail "slug"
  out=$(fm_project_skills_always)
  printf '%s\n' "$out" | grep -qx 'no-mistakes' || fail "always includes no-mistakes"
  pass "slug and always-set"
}

test_resolve_merges_config_and_learned() {
  local home skills
  home=$(mktemp -d "${TMPDIR:-/tmp}/fm-pskills.XXXXXX")
  export FM_HOME="$home"
  mkdir -p "$home/config" "$home/data/project-skills"
  cat >"$home/config/project-skills.json" <<'EOF'
{"version":1,"defaults":["diagnostic-reasoning"],"projects":{"demo":{"skills":["graphify-orientation"]}}}
EOF
  printf '%s\n' '{"version":1,"hits":{"harness-adapters":3,"graphify-orientation":1}}' \
    >"$home/data/project-skills/demo.json"
  skills=$(fm_project_skills_resolve demo | tr '\n' ' ')
  printf '%s' "$skills" | grep -q 'no-mistakes' || fail "missing always"
  printf '%s' "$skills" | grep -q 'diagnostic-reasoning' || fail "missing default"
  printf '%s' "$skills" | grep -q 'graphify-orientation' || fail "missing configured"
  printf '%s' "$skills" | grep -q 'harness-adapters' || fail "missing learned"
  perm=$(fm_project_skills_opencode_permission_json demo)
  printf '%s' "$perm" | grep -q '"\*":"deny"' || fail "deny all"
  printf '%s' "$perm" | grep -q '"no-mistakes":"allow"' || fail "allow no-mistakes"
  printf '%s' "$perm" | grep -q '"harness-adapters":"allow"' || fail "allow learned"
  rm -rf "$home"
  pass "resolve merges config+learned into OpenCode overlay"
}

test_observe_increments_hits() {
  local home
  home=$(mktemp -d "${TMPDIR:-/tmp}/fm-pskills.XXXXXX")
  export FM_HOME="$home"
  fm_project_skills_observe demo-app diagnostic-reasoning
  fm_project_skills_observe demo-app diagnostic-reasoning
  hits=$(jq -r '.hits["diagnostic-reasoning"]' "$home/data/project-skills/demo-app.json")
  [ "$hits" = 2 ] || fail "hits=$hits"
  rm -rf "$home"
  pass "observe increments hits"
}

test_validation_phases() {
  [ "$(fm_validation_normalize '')" = feature ] || fail "default feature"
  [ "$(fm_validation_normalize prd-finish)" = prd-finish ] || fail "prd-finish"
  fm_validation_normalize bogus >/dev/null 2>&1 && fail "bogus should fail" || true
  add=$(fm_validation_dod_addendum feature)
  printf '%s' "$add" | grep -q 'fm-test-run.sh --changed' || fail "feature mentions --changed"
  add=$(fm_validation_dod_addendum prd-finish)
  printf '%s' "$add" | grep -q 'fm-test-run.sh --all' || fail "prd-finish mentions --all"
  printf '%s' "$add" | grep -q 'high-thinking' || fail "prd-finish mentions high-thinking"
  pass "validation phases"
}

test_dod_records_validation_token() {
  # shellcheck source=bin/fm-dod-lib.sh
  . "$ROOT/bin/fm-dod-lib.sh"
  block=$(fm_dod_block direct-PR demo-task feature)
  printf '%s' "$block" | grep -q 'Delivery contract: mode=direct-PR validation=feature' || fail "feature token"
  printf '%s' "$block" | grep -q 'Validation phase: feature' || fail "feature section"
  block=$(fm_dod_block no-mistakes demo-task prd-finish)
  printf '%s' "$block" | grep -q 'validation=prd-finish' || fail "prd token"
  printf '%s' "$block" | grep -q 'Validation phase: prd-finish' || fail "prd section"
  pass "DoD records validation token and addendum"
}

test_slug_and_always
test_resolve_merges_config_and_learned
test_observe_increments_hits
test_validation_phases
test_dod_records_validation_token
