#!/usr/bin/env bash
# Behavior tests for .opencode/plugins/fm-primary-watch-arm.js supervision arm
# eligibility (docs/supervision-protocols/opencode.md).
#
# The OpenCode watch-arm plugin must arm a watcher in a genuine primary home -
# the main checkout OR a marked secondmate home (which runs its own primary
# session) - and stay silent in child crewmate/scout task worktrees. The
# eligibility predicate is exported as the testable public contract. These tests
# drive that predicate against hermetic git fixtures over temp dirs; no real
# agent session or OpenCode client is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-secondmate-arm)
fm_git_identity fmtest fmtest@example.invalid

PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
[ -f "$PLUGIN" ] || fail "watch-arm plugin missing: $PLUGIN"
# The predicate is imported by a node driver below. Resolve the interpreter up
# front, like the sibling node-driven suites do, so a shard without node fails
# as a missing prerequisite instead of reporting every case as an eligibility
# regression (node absent => 127 => each `run_predicate || fail` fires).
NODE_BIN=$(command -v node) || fail "test needs node"

# --- fixtures ---------------------------------------------------------------

# A primary-shaped checkout: a plain (non-worktree) git repo with AGENTS.md and
# bin/ - the shapes bin/fm-primary-scope-lib.sh requires of a primary root.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

# A treehouse-leased secondmate HOME: a genuine linked `git worktree` (git-dir
# != git-common-dir) that carries a valid .fm-secondmate-home marker. This is
# the production topology the old code wrongly exempted: it must arm its own
# supervision here, exactly like the main primary.
make_secondmate_linked_home_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/opencode-secondmate-linked-home
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf 'sm-oc-test-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A crewmate/scout task worktree on firstmate itself: a genuine linked git
# worktree with AGENTS.md and bin/ but NO marker - it must stay silent.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/opencode-crewmate-worktree
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

# Anti-spoof: a linked worktree with a stray/empty marker must NOT be treated as
# a secondmate home; it must fall through the marker check and stay exempt via
# the linked-worktree git-dir test, mirroring fm_root_is_secondmate_home.
make_stray_marker_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/opencode-stray-marker-worktree
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  : > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# Marker fidelity: fm_root_is_secondmate_home validates only the FIRST line of
# the marker, so a home whose marker carries a valid id plus a trailing
# annotation line is still a genuine secondmate home to every shell hook - the
# plugin must agree, or the home silently loses its watcher again.
make_annotated_marker_home_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/opencode-annotated-marker-home
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf 'sm-oc-test-2\n# leased 2026-08\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# Anti-spoof: only the first line counts, so a marker whose first line is blank
# has an empty id and must not force-include, even though a later line looks
# like a valid id.
make_blank_first_line_marker_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/opencode-blank-first-line-marker
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf '\nsm-oc-test-3\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# Mirror fidelity: fm_root_is_secondmate_home reads the first line with
# `IFS= read -r`, which reports failure at EOF when that line carries no
# trailing newline - so the shell owner scopes such a home OUT. The plugin must
# reach the same verdict, or OpenCode would arm a watcher in a root every shell
# hook treats as non-primary.
make_unterminated_marker_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/opencode-unterminated-marker
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf 'sm-oc-test-4' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# Mirror fidelity: fm_root_is_secondmate_home strips whitespace under LC_ALL=C,
# so only ASCII blanks are removed and a non-breaking space survives to fail the
# [A-Za-z0-9._-] charset test - the shell owner scopes such a home OUT. A JS
# mirror stripping the wider Unicode class instead would normalise the id into a
# valid one and arm a watcher in a root every shell hook treats as non-primary.
make_nbsp_marker_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/opencode-nbsp-marker
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf 'sm-oc\302\240test-5\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# Run the shared shell owner over the same fixture so the plugin is pinned to
# it rather than to a hand-picked expectation.
shell_owner_scopes_in() {
  local dir=$1
  (
    # shellcheck source=bin/fm-primary-scope-lib.sh
    . "$ROOT/bin/fm-primary-scope-lib.sh"
    fm_primary_scope_matches "$dir" "$dir/state"
  )
}

# shell_owner_agrees <dir> <true|false> pins a fixture's expected verdict to the
# shared shell owner before the plugin is asserted against the same expectation.
# The plugin mirrors a predicate written in another language in another file, so
# a case pinned only to a hand-picked boolean would keep passing while the two
# implementations silently diverged. Every fixture therefore carries the state/
# dir fm_primary_scope_matches requires, so both predicates are comparable.
shell_owner_agrees() {
  local dir=$1 expected=$2
  if shell_owner_scopes_in "$dir"; then
    [ "$expected" = true ] \
      || fail "fixture assumption broken: fm_primary_scope_matches scopes IN $dir, expected it scoped out"
  else
    [ "$expected" = false ] \
      || fail "fixture assumption broken: fm_primary_scope_matches scopes OUT $dir, expected it scoped in"
  fi
}

is_linked_worktree() {
  local dir=$1 gd gcd
  gd=$(git -C "$dir" rev-parse --git-dir 2>/dev/null) || return 1
  gcd=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$gd" != "$gcd" ]
}

# --- driver ---------------------------------------------------------------

# run_predicate <plugin> <path>:<expected>... imports the plugin's exported
# isArmEligibleRoot and asserts each path resolves to the expected boolean.
run_predicate() {
  local plugin=$1
  shift
  DRIVER="$TMP_ROOT/driver.mjs"
  cat > "$DRIVER" <<EOF
import { pathToFileURL } from "node:url";
const plugin = process.argv[2];
const mod = await import(pathToFileURL(plugin));
const fn = mod.isArmEligibleRoot;
if (typeof fn !== "function") {
  console.error("exported isArmEligibleRoot is not a function");
  process.exit(2);
}
const cases = process.argv.slice(3);
let failures = 0;
for (const c of cases) {
  const sep = c.lastIndexOf(":");
  const path = c.slice(0, sep);
  const expected = c.slice(sep + 1) === "true";
  const actual = await fn(path);
  if (actual !== expected) {
    console.error(\`FAIL \${path}: expected \${expected}, got \${actual}\`);
    failures += 1;
  } else {
    console.log(\`ok \${path} -> \${actual}\`);
  }
}
process.exit(failures ? 1 : 0);
EOF
  local out status
  out=$("$NODE_BIN" "$DRIVER" "$plugin" "$@" 2>&1); status=$?
  printf '%s\n' "$out" >&2
  return "$status"
}

# --- tests -----------------------------------------------------------------

test_primary_checkout_arms() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/primary")
  # Pin the positive control's shape, exactly as every linked-worktree case
  # below pins its own. This case is the only evidence that the markerless
  # plain-checkout branch still arms; it carries no marker, so if the fixture
  # ever drifted into a linked worktree the assertion would have to go red
  # rather than keep passing through some other branch of the predicate.
  if is_linked_worktree "$dir"; then
    fail "primary fixture must be a plain checkout (git-dir == git-common-dir), got a linked worktree"
  fi
  shell_owner_agrees "$dir" true
  run_predicate "$PLUGIN" "$dir:true" \
    || fail "primary (plain non-worktree) checkout must be arm-eligible"
  pass "watch-arm: arms the plain primary checkout"
}

test_secondmate_linked_home_arms() {
  local base dir
  base="$TMP_ROOT/secondmate-base"
  dir="$TMP_ROOT/secondmate-linked-home"
  make_secondmate_linked_home_dir "$base" "$dir" >/dev/null
  is_linked_worktree "$dir" \
    || fail "secondmate-home fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" true
  run_predicate "$PLUGIN" "$dir:true" \
    || fail "a marked secondmate home must arm its own supervision even when treehouse-leased as a linked worktree"
  pass "watch-arm: arms a treehouse-leased LINKED secondmate home via its marker (regression)"
}

test_crewmate_worktree_stays_silent() {
  local base dir
  base="$TMP_ROOT/crewmate-base"
  dir="$TMP_ROOT/crewmate-worktree"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  is_linked_worktree "$dir" \
    || fail "crewmate-worktree fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" false
  run_predicate "$PLUGIN" "$dir:false" \
    || fail "a markerless linked task worktree must stay silent"
  pass "watch-arm: stays silent in a crewmate/scout linked task worktree"
}

test_stray_marker_cannot_spoof() {
  local base dir
  base="$TMP_ROOT/stray-base"
  dir="$TMP_ROOT/stray-marker-worktree"
  make_stray_marker_worktree_dir "$base" "$dir" >/dev/null
  is_linked_worktree "$dir" \
    || fail "stray-marker fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" false
  run_predicate "$PLUGIN" "$dir:false" \
    || fail "an empty/invalid marker must not spoof force-inclusion in a linked worktree"
  pass "watch-arm: an empty marker cannot spoof inclusion; linked worktree stays exempt"
}

test_annotated_marker_home_arms() {
  local base dir
  base="$TMP_ROOT/annotated-base"
  dir="$TMP_ROOT/annotated-marker-home"
  make_annotated_marker_home_dir "$base" "$dir" >/dev/null
  is_linked_worktree "$dir" \
    || fail "annotated-marker fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" true
  run_predicate "$PLUGIN" "$dir:true" \
    || fail "a marker with a valid first-line id plus a trailing annotation must arm, matching fm_root_is_secondmate_home"
  pass "watch-arm: honours the first-line marker contract when the marker has extra lines"
}

test_blank_first_line_marker_cannot_spoof() {
  local base dir
  base="$TMP_ROOT/blank-first-base"
  dir="$TMP_ROOT/blank-first-line-marker-worktree"
  make_blank_first_line_marker_worktree_dir "$base" "$dir" >/dev/null
  is_linked_worktree "$dir" \
    || fail "blank-first-line fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" false
  run_predicate "$PLUGIN" "$dir:false" \
    || fail "a marker whose first line is blank must not spoof force-inclusion in a linked worktree"
  pass "watch-arm: a blank first line cannot spoof inclusion via a later line"
}

test_unterminated_marker_matches_shell_owner() {
  local base dir
  base="$TMP_ROOT/unterminated-base"
  dir="$TMP_ROOT/unterminated-marker-worktree"
  make_unterminated_marker_worktree_dir "$base" "$dir" >/dev/null
  is_linked_worktree "$dir" \
    || fail "unterminated-marker fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" false
  run_predicate "$PLUGIN" "$dir:false" \
    || fail "an unterminated marker must not force-include where fm_primary_scope_matches scopes the home out"
  pass "watch-arm: an unterminated marker is rejected exactly as the shell owner rejects it"
}

test_nbsp_marker_matches_shell_owner() {
  local base dir
  base="$TMP_ROOT/nbsp-base"
  dir="$TMP_ROOT/nbsp-marker-worktree"
  make_nbsp_marker_worktree_dir "$base" "$dir" >/dev/null
  is_linked_worktree "$dir" \
    || fail "nbsp-marker fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" false
  run_predicate "$PLUGIN" "$dir:false" \
    || fail "a non-breaking space in the marker id must not be stripped into a valid id where fm_root_is_secondmate_home keeps it and rejects the home"
  pass "watch-arm: strips only ASCII blanks, matching the shell owner under LC_ALL=C"
}

test_primary_checkout_arms
test_secondmate_linked_home_arms
test_crewmate_worktree_stays_silent
test_stray_marker_cannot_spoof
test_annotated_marker_home_arms
test_blank_first_line_marker_cannot_spoof
test_unterminated_marker_matches_shell_owner
test_nbsp_marker_matches_shell_owner
