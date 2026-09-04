#!/usr/bin/env bash
# Behavior tests for .opencode/plugins/fm-primary-watch-arm.js supervision arm
# eligibility (docs/supervision-protocols/opencode.md).
#
# The OpenCode watch-arm plugin must arm a watcher in a genuine primary home -
# the main checkout OR a marked secondmate home (which runs its own primary
# session) - and stay silent in child crewmate/scout task worktrees. The
# eligibility predicate is the testable public contract of
# .opencode/plugins/lib/fm-watch-arm-eligibility.js. These tests drive that
# predicate against hermetic git fixtures over temp dirs, and additionally drive
# the real plugin factory through a session.idle event so the regression is
# proven at the arm path that actually failed in production, not only at the
# predicate. No live agent session or OpenCode client is involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-secondmate-arm)
fm_git_identity fmtest fmtest@example.invalid

PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
[ -f "$PLUGIN" ] || fail "watch-arm plugin missing: $PLUGIN"
TURNEND_PLUGIN="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
[ -f "$TURNEND_PLUGIN" ] || fail "turnend-guard plugin missing: $TURNEND_PLUGIN"
# The predicate lives in lib/ rather than in the plugin module: OpenCode treats
# every export of a plugin file as a plugin factory, and lib/ is not scanned.
ELIGIBILITY="$ROOT/.opencode/plugins/lib/fm-watch-arm-eligibility.js"
[ -f "$ELIGIBILITY" ] || fail "watch-arm eligibility module missing: $ELIGIBILITY"
CLOSE="$ROOT/.opencode/plugins/lib/fm-watch-arm-close.js"
[ -f "$CLOSE" ] || fail "watch-arm close classifier missing: $CLOSE"
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

# Shape fidelity: fm_primary_scope_matches requires `[ -f AGENTS.md ]` and
# `[ -d bin ]`, so a root whose `bin` is a plain file - not the bin/ directory a
# provisioned home carries - is scoped OUT by every shell hook. Its git shape is
# otherwise that of an armable plain checkout, so a plugin gate testing mere path
# existence would arm a watcher exactly where the shell owner refuses to.
make_bin_not_a_dir_checkout_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/bin"
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

# Anti-spoof: fm_root_is_secondmate_home rejects a symlinked marker outright
# (`[ -L "$marker" ] && return 1`) before it ever reads an id, so a marker
# pointed at a file outside the home cannot lease supervision to a linked task
# worktree. A JS mirror stating the file with statSync instead of lstatSync
# would follow the link, read a perfectly valid id, and arm a watcher in a root
# every shell hook treats as non-primary.
make_symlinked_marker_worktree_dir() {
  local base=$1 dir=$2 target=$3
  fm_git_worktree "$base" "$dir" fm/opencode-symlinked-marker
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf 'sm-oc-test-7\n' > "$target"
  ln -s "$target" "$dir/.fm-secondmate-home" \
    || fail "cannot create the symlinked marker fixture at $dir/.fm-secondmate-home"
  [ -L "$dir/.fm-secondmate-home" ] \
    || fail "symlinked-marker fixture must be a symlink, got a regular path"
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

# run_predicate <module> <path>:<expected>... imports the eligibility module's
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
  run_predicate "$ELIGIBILITY" "$dir:true" \
    || fail "primary (plain non-worktree) checkout must be arm-eligible"
  pass "watch-arm: arms the plain primary checkout"
}

test_bin_not_a_dir_stays_silent() {
  local dir
  dir=$(make_bin_not_a_dir_checkout_dir "$TMP_ROOT/bin-not-a-dir-checkout")
  # A plain checkout, so the git-shape branch alone would scope this root IN;
  # only the AGENTS.md/bin shape gate can keep it out, which is what this pins.
  if is_linked_worktree "$dir"; then
    fail "bin-not-a-dir fixture must be a plain checkout (git-dir == git-common-dir), got a linked worktree"
  fi
  shell_owner_agrees "$dir" false
  run_predicate "$ELIGIBILITY" "$dir:false" \
    || fail "a root whose bin is a plain file must stay silent, matching fm_primary_scope_matches"
  pass "watch-arm: a root failing the AGENTS.md/bin shape gate stays silent, as the shell owner requires"
}

test_secondmate_linked_home_arms() {
  local base dir
  base="$TMP_ROOT/secondmate-base"
  dir="$TMP_ROOT/secondmate-linked-home"
  make_secondmate_linked_home_dir "$base" "$dir" >/dev/null
  is_linked_worktree "$dir" \
    || fail "secondmate-home fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" true
  run_predicate "$ELIGIBILITY" "$dir:true" \
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
  run_predicate "$ELIGIBILITY" "$dir:false" \
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
  run_predicate "$ELIGIBILITY" "$dir:false" \
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
  run_predicate "$ELIGIBILITY" "$dir:true" \
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
  run_predicate "$ELIGIBILITY" "$dir:false" \
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
  run_predicate "$ELIGIBILITY" "$dir:false" \
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
  run_predicate "$ELIGIBILITY" "$dir:false" \
    || fail "a non-breaking space in the marker id must not be stripped into a valid id where fm_root_is_secondmate_home keeps it and rejects the home"
  pass "watch-arm: strips only ASCII blanks, matching the shell owner under LC_ALL=C"
}

test_symlinked_marker_cannot_spoof() {
  local base dir
  base="$TMP_ROOT/symlinked-base"
  dir="$TMP_ROOT/symlinked-marker-worktree"
  make_symlinked_marker_worktree_dir "$base" "$dir" "$TMP_ROOT/symlinked-marker-target" >/dev/null
  is_linked_worktree "$dir" \
    || fail "symlinked-marker fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" false
  run_predicate "$ELIGIBILITY" "$dir:false" \
    || fail "a symlinked marker must not spoof force-inclusion where fm_root_is_secondmate_home rejects the link outright"
  pass "watch-arm: a symlinked marker cannot spoof inclusion, matching the shell owner's [ -L ] rejection"
}

# The predicate cases above prove eligibility in isolation. This one reproduces
# the reported production failure end to end: in tms-captain/hosp-captain the
# TUI warned that supervision was off because beginArm turned a marked
# secondmate home into status not-primary and never spawned an arm child. Drive
# the real FmPrimaryWatchArm factory through session.idle over such a home and
# require that bin/fm-watch-arm.sh actually ran.
test_secondmate_home_spawns_an_arm_child() {
  local base dir log out status
  base="$TMP_ROOT/arm-path-base"
  dir="$TMP_ROOT/arm-path-secondmate-home"
  log="$TMP_ROOT/arm-path-arm.log"
  fm_git_worktree "$base" "$dir" fm/opencode-arm-path
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  : > "$dir/AGENTS.md"
  printf 'sm-oc-test-6\n' > "$dir/.fm-secondmate-home"
  : > "$dir/state/task.meta"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'root=%s home=%s\n' "${FM_ROOT_OVERRIDE:-}" "${FM_HOME:-}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  is_linked_worktree "$dir" \
    || fail "arm-path fixture must be a linked worktree (git-dir != git-common-dir), got equal"
  shell_owner_agrees "$dir" true
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$log" "$NODE_BIN" 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
if (typeof mod.FmPrimaryWatchArm !== "function") {
  console.error("plugin does not export the FmPrimaryWatchArm factory");
  process.exit(2);
}
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-arm-path" } } });
const expectedRoot = realpathSync(process.env.WORKTREE);
// The arm child creates the log by `>>` redirection before it writes its line,
// so polling on mere existence can observe the empty file and misreport a live
// arm as an arm against the wrong root. Poll on the line itself instead.
const readLog = () =>
  (existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8") : "");
let text = readLog();
for (let i = 0; i < 250 && !text.includes("root="); i += 1) {
  await new Promise((settle) => setTimeout(settle, 20));
  text = readLog();
}
if (!text.includes("root=")) {
  console.error("no arm child ran: the marked secondmate home was scoped out of supervision");
  process.exit(1);
}
if (!text.includes(`root=${expectedRoot}`)) {
  console.error(`arm child ran against the wrong root:\n${text}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "a marked secondmate home must spawn an arm child on session.idle"
  [ -z "$out" ] || fail "secondmate arm-path test printed output: $out"
  pass "watch-arm: a marked secondmate home spawns a real arm child on session.idle (regression)"
}

# run_close_classifier <stdout> <stderr> <code> <signal> <expected-kind>
# Drives the public classifyArmClose export. These cases are the regression for
# empty-cycle-as-failure: healthy, empty, and the shell's unexplained-cycle
# FAILED line must be idle (no model turn), while a real FAILED and an
# actionable wake keep their kinds.
run_close_classifier() {
  local stdout=$1 stderr=$2 code=$3 signal=$4 expected=$5 out status
  out=$(CLOSE="$CLOSE" FM_CLOSE_STDOUT="$stdout" FM_CLOSE_STDERR="$stderr" \
    EXPECTED="$expected" CODE="$code" SIGNAL="$signal" \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.CLOSE));
const signal = process.env.SIGNAL === "" ? null : process.env.SIGNAL;
const result = mod.classifyArmClose(
  process.env.FM_CLOSE_STDOUT ?? "",
  process.env.FM_CLOSE_STDERR ?? "",
  Number(process.env.CODE),
  signal,
);
if (result.kind !== process.env.EXPECTED) {
  console.error(`kind=${result.kind} expected=${process.env.EXPECTED} message=${result.message}`);
  process.exit(1);
}
EOF
)
  status=$?
  printf '%s\n' "$out" >&2
  return "$status"
}

test_empty_and_healthy_closes_are_idle_not_failure() {
  local status
  run_close_classifier 'watcher: healthy pid=1 (beacon 0s)' '' 0 '' idle
  status=$?
  expect_code 0 "$status" "watcher: healthy must classify as idle, not failure"

  run_close_classifier '' '' 0 '' idle
  status=$?
  expect_code 0 "$status" "an empty clean close must classify as idle, not failure"

  run_close_classifier 'watcher: FAILED - cycle ended without an actionable reason' '' 1 '' idle
  status=$?
  expect_code 0 "$status" "the shell unexplained-cycle FAILED line must classify as idle"

  run_close_classifier 'watcher: FAILED - cycle reason could not be read' '' 1 '' failure
  status=$?
  expect_code 0 "$status" "an unreadable delivery ledger must stay failure, not a benign empty cycle"

  run_close_classifier 'watcher: FAILED - watcher cycle exited 1 without an actionable reason' '' 1 '' failure
  status=$?
  expect_code 0 "$status" "a nonzero watcher exit reported by the arm must stay failure"

  run_close_classifier 'watcher: attached pid=9 (beacon 0s)' '' 0 '' idle
  status=$?
  expect_code 0 "$status" "an attached clean close must classify as idle"

  run_close_classifier 'signal: demo.status' '' 0 '' actionable
  status=$?
  expect_code 0 "$status" "an actionable wake line must stay actionable"

  run_close_classifier 'watcher: FAILED - no live watcher with a fresh beacon' '' 1 '' failure
  status=$?
  expect_code 0 "$status" "a real no-watcher FAILED line must stay failure"

  pass "watch-arm: empty/healthy/unexplained-cycle closes are idle; real FAILED and wakes keep their kinds"
}

# Drive the real plugin through session.idle over a marked secondmate home whose
# stub arm prints $FM_ARM_STUB_LINE and exits $FM_ARM_STUB_CODE. Echoes the
# promptAsync count. The old classifier treated healthy/empty as failure and
# then promptAsync'd; this is the production loop.
count_idle_prompts() {  # <dir> <arm-output> <arm-code>
  local dir=$1 output=$2 code=$3
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_ARM_STUB_LINE:-}" ] && printf '%s\n' "$FM_ARM_STUB_LINE"
exit "${FM_ARM_STUB_CODE:-0}"
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" \
    FM_ARM_STUB_LINE="$output" FM_ARM_STUB_CODE="$code" \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    FM_WATCH_REARM_RETRY_LIMIT=2 "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-idle-loop" } } });
for (let i = 0; i < 40; i += 1) {
  await new Promise((settle) => setTimeout(settle, 25));
}
process.stdout.write(String(prompts));
EOF
}

prepare_arm_home() {  # <name>
  local base dir
  base="$TMP_ROOT/$1-base"
  dir="$TMP_ROOT/$1-home"
  fm_git_worktree "$base" "$dir" "fm/opencode-$1"
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  : > "$dir/AGENTS.md"
  printf 'sm-oc-idle-1\n' > "$dir/.fm-secondmate-home"
  : > "$dir/state/task.meta"
  printf '%s\n' "$dir"
}

test_healthy_close_does_not_prompt() {
  local dir count
  dir=$(prepare_arm_home healthy-close)
  count=$(count_idle_prompts "$dir" "watcher: healthy pid=1 (beacon 0s)" 0) || \
    fail "healthy-close plugin drive failed"
  [ "$count" = 0 ] || fail "watcher: healthy idle close must not promptAsync, got $count"
  pass "watch-arm: a healthy-watcher close does not start a model turn"
}

test_empty_cycle_close_does_not_prompt() {
  local dir count
  dir=$(prepare_arm_home empty-close)
  count=$(count_idle_prompts "$dir" "watcher: FAILED - cycle ended without an actionable reason" 1) || \
    fail "empty-cycle plugin drive failed"
  [ "$count" = 0 ] || fail "empty-cycle FAILED close must not promptAsync, got $count"
  dir=$(prepare_arm_home blank-close)
  count=$(count_idle_prompts "$dir" "" 0) || fail "blank-close plugin drive failed"
  [ "$count" = 0 ] || fail "empty clean close must not promptAsync, got $count"
  pass "watch-arm: an empty cycle close does not start a model turn"
}

test_actionable_close_still_prompts() {
  local dir count
  dir=$(prepare_arm_home wake-close)
  count=$(count_idle_prompts "$dir" "signal: demo.status" 0) || \
    fail "actionable-close plugin drive failed"
  [ "$count" -ge 1 ] || fail "an actionable wake close must promptAsync, got $count"
  pass "watch-arm: an actionable wake still delivers a model turn"
}

test_turnend_guard_stays_silent_when_watch_arm_loaded() {
  local dir out status
  dir=$(prepare_arm_home guard-fallthrough)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard-fired\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-watch-arm.sh" "$dir/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$PLUGIN" TURNEND="$TURNEND_PLUGIN" WORKTREE="$dir" FM_HOME="$dir" \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

const arm = await import(pathToFileURL(process.env.PLUGIN).href);
const guard = await import(pathToFileURL(process.env.TURNEND).href);
let prompts = 0;
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const armHooks = await arm.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guard.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await armHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-guard" } } });
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-guard" } } });
for (let i = 0; i < 20; i += 1) {
  await new Promise((settle) => setTimeout(settle, 25));
}
if (prompts !== 0) {
  console.error(`watch-arm plus turnend-guard prompted ${prompts} times on a healthy idle`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "turnend-guard must not prompt when watch-arm is loaded"
  [ -z "$out" ] || fail "turnend-guard fallthrough test printed output: $out"
  pass "turnend-guard: a loaded watch-arm coordinator suppresses the idle repair turn"
}

# A registered process-event source needs supervision without any task.meta
# (bin/fm-supervision-lib.sh counts state/procevent/*.source). The plugin's arm
# predicate must agree with that shell owner, or a procevent-only home ends its
# idle with neither a watcher nor a surfaced warning.
test_procevent_source_home_arms_without_task_meta() {
  local dir out status
  dir=$(prepare_arm_home procevent-need)
  rm -f "$dir/state/task.meta"
  mkdir -p "$dir/state/procevent"
  : > "$dir/state/procevent/proc-1.source"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm-ran\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/procevent-need-arm.log" \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-procevent" } } });
const armed = () =>
  existsSync(process.env.FM_ARM_LOG) && readFileSync(process.env.FM_ARM_LOG, "utf8").includes("arm-ran");
for (let i = 0; i < 100 && !armed(); i += 1) {
  await new Promise((settle) => setTimeout(settle, 20));
}
if (!armed()) {
  console.error("a home with a registered process-event source and no task.meta was left unarmed");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "a procevent-source home must arm without task.meta"
  [ -z "$out" ] || fail "procevent-need test printed output: $out"
  pass "watch-arm: a registered process-event source arms supervision without task.meta"
}

# When the coordinator declines to arm because this session does not own the
# lock, the shell guard still runs and its verdict is delivered: silence here
# would leave a home whose previous lock holder died without a watcher blind.
test_turnend_guard_runs_when_coordinator_declines_read_only() {
  local dir out status
  dir=$(prepare_arm_home guard-read-only)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm-ran\n' >> "${FM_ARM_LOG:?}"
SH
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard-ran\n' >> "${FM_GUARD_LOG:?}"
printf 'guard verdict: no live watcher\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-watch-arm.sh" "$dir/bin/fm-turnend-guard.sh"
  out=$(PLUGIN="$PLUGIN" TURNEND="$TURNEND_PLUGIN" WORKTREE="$dir" FM_HOME="$dir" \
    FM_ARM_LOG="$TMP_ROOT/guard-read-only-arm.log" FM_GUARD_LOG="$TMP_ROOT/guard-read-only-guard.log" \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const arm = await import(pathToFileURL(process.env.PLUGIN).href);
const guard = await import(pathToFileURL(process.env.TURNEND).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
await arm.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
const guardHooks = await guard.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "999999999\n");
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-read-only" } } });
await new Promise((settle) => setTimeout(settle, 200));
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("a session that does not own the lock spawned an arm child");
  process.exit(1);
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("the shell guard did not run after the coordinator declined (read-only)");
  process.exit(1);
}
if (prompts.length !== 1 || !prompts[0].includes("TURN WOULD END BLIND") || !prompts[0].includes("guard verdict")) {
  console.error(`guard verdict was not delivered once: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "the shell guard must run and deliver its verdict when the coordinator declines"
  [ -z "$out" ] || fail "guard read-only fallback test printed output: $out"
  pass "turnend-guard: a coordinator that declines (read-only) hands the idle to the shell guard"
}

# Benign empty cycles are counted apart from failures: after the idle budget has
# been spent on empties, a real FAILED close must still get its full bounded
# retry before anything is surfaced.
test_idle_cycles_do_not_consume_the_failure_retry_budget() {
  local dir out status
  dir=$(prepare_arm_home retry-budget)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
[ "$count" -le 2 ] && exit 0
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/retry-budget-arm.log" \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-retry-budget" } } });
for (let i = 0; i < 200 && prompts.length === 0; i += 1) {
  await new Promise((settle) => setTimeout(settle, 10));
}
await new Promise((settle) => setTimeout(settle, 100));
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 5) {
  console.error(`expected 2 idle cycles plus 1 failure and 2 failure retries, got ${rows.length} arm cycles`);
  process.exit(1);
}
if (prompts.length !== 1 || !prompts[0].includes("after 2 retries")) {
  console.error(`failure exhaustion was not surfaced exactly once: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "empty cycles must not spend the failure retry budget"
  [ -z "$out" ] || fail "retry-budget test printed output: $out"
  pass "watch-arm: benign idle cycles leave the failure retry budget intact"
}

# During actionable-wake restoration the successor arm can itself close on the
# shell's empty-cycle line. A closed arm is not a ready successor: restoration
# must retry silently and leave a live arm behind the delivered wake instead of
# reporting continuity intact over a home with no watcher.
test_restoration_retries_an_idle_successor_close() {
  local dir out status
  dir=$(prepare_arm_home restore-idle)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
case "$count" in
  1) printf 'signal: demo.status\n'; exit 0 ;;
  2) printf 'watcher: FAILED - cycle ended without an actionable reason\n'; exit 1 ;;
esac
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/restore-idle-arm.log" \
    FM_STOP_FILE="$TMP_ROOT/restore-idle.stop" \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-restore-idle" } } });
for (let i = 0; i < 300 && prompts.length === 0; i += 1) {
  await new Promise((settle) => setTimeout(settle, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
if (prompts.length !== 1) {
  console.error(`expected exactly one delivered wake, got ${JSON.stringify(prompts)}`);
  process.exit(1);
}
if (rows.length !== 3) {
  console.error(`the idle successor close was accepted as a ready successor: ${rows.length} arm cycles ran`);
  process.exit(1);
}
if (prompts[0].includes("FAILED")) {
  console.error(`a silently restored successor surfaced a failure: ${prompts[0]}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "restoration must retry an idle successor close silently and deliver the wake over a live arm"
  [ -z "$out" ] || fail "restoration idle-close test printed output: $out"
  pass "watch-arm: an idle successor close during restoration is retried silently, not accepted as armed"
}

# The plugin appends its exhaustion notice through the real bin/fm-wake-lib.sh
# of the root it arms, so a fixture that exercises that path carries the real
# library alongside its stubbed arm script.
link_real_bin_scripts() {  # <dir>
  local f
  for f in "$ROOT"/bin/*.sh; do
    [ -e "$1/bin/$(basename "$f")" ] || ln -s "$f" "$1/bin/$(basename "$f")"
  done
}

# A watcher that established itself and outlived the cycle-lifetime floor is a
# completed cycle: its empty close replenishes the silent re-arm budget, so a
# long-running home whose cycles end empty keeps re-arming instead of going
# silent after a lifetime count of benign closes.
test_established_cycles_replenish_the_idle_budget() {
  local dir out status
  dir=$(prepare_arm_home established-cycle)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 0.1
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/established-cycle-arm.log" \
    FM_WATCH_ARM_ESTABLISHED_MS=50 \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
const rows = () =>
  existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length : 0;
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-established" } } });
for (let i = 0; i < 300 && rows() < 6; i += 1) {
  await new Promise((settle) => setTimeout(settle, 20));
}
if (rows() < 6) {
  console.error(`established cycles stopped re-arming after ${rows()} cycles (lifetime budget exhausted)`);
  process.exit(1);
}
if (prompts !== 0) {
  console.error(`established empty cycles spent ${prompts} model turns`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "established watcher cycles must replenish the silent re-arm budget"
  [ -z "$out" ] || fail "established-cycle test printed output: $out"
  pass "watch-arm: a watcher that outlived the cycle floor replenishes the idle re-arm budget"
}

# Exhausting the silent budget on instantly-empty cycles is terminal for the
# plugin's own re-arm, so it must leave exactly one durable notice behind and
# never a model turn: state/.wake-queue is the owned durable wake protocol
# (<epoch>\t<seq>\t<kind>\t<key>\t<payload>), read here as that contract.
test_idle_exhaustion_queues_one_durable_check_without_a_prompt() {
  local dir out status
  dir=$(prepare_arm_home idle-exhaustion)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  link_real_bin_scripts "$dir"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/idle-exhaustion-arm.log" \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
const queue = `${process.env.FM_HOME}/state/.wake-queue`;
const rows = () =>
  existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length : 0;
const notices = () =>
  existsSync(queue)
    ? readFileSync(queue, "utf8").split("\n").filter((line) => line.split("\t")[2] === "check" && line.split("\t")[3] === "opencode-arm:idle-exhausted")
    : [];
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-exhaustion" } } });
for (let i = 0; i < 200 && notices().length === 0; i += 1) {
  await new Promise((settle) => setTimeout(settle, 10));
}
await new Promise((settle) => setTimeout(settle, 150));
if (rows() !== 3) {
  console.error(`expected the initial arm plus 2 silent retries, got ${rows()} cycles`);
  process.exit(1);
}
if (notices().length !== 1) {
  console.error(`expected exactly one durable exhaustion notice, got ${notices().length}: ${existsSync(queue) ? readFileSync(queue, "utf8") : "(no queue)"}`);
  process.exit(1);
}
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-exhaustion" } } });
for (let i = 0; i < 200 && rows() < 6; i += 1) {
  await new Promise((settle) => setTimeout(settle, 10));
}
await new Promise((settle) => setTimeout(settle, 150));
if (notices().length !== 1) {
  console.error(`an unacknowledged exhaustion notice was repeated: ${notices().length} records`);
  process.exit(1);
}
if (prompts !== 0) {
  console.error(`idle exhaustion spent ${prompts} model turns`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "idle exhaustion must leave one durable check record and no model turn"
  [ -z "$out" ] || fail "idle-exhaustion test printed output: $out"
  pass "watch-arm: exhausted silent re-arm queues one durable check and never prompts"
}

# An instantly-empty close is not a completed cycle, so it must not wipe the
# failure count: a watcher that alternates real FAILED closes with empty ones
# still reaches the failure bound and surfaces once.
test_alternating_failure_and_empty_closes_still_surface() {
  local dir out status
  dir=$(prepare_arm_home alternating-close)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
[ $((count % 2)) -eq 0 ] && exit 0
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/alternating-close-arm.log" \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = { session: { promptAsync: async (request) => { prompts.push(request.body.parts[0].text); } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-alternating" } } });
for (let i = 0; i < 300 && prompts.length === 0; i += 1) {
  await new Promise((settle) => setTimeout(settle, 10));
}
await new Promise((settle) => setTimeout(settle, 150));
const rows = existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length : 0;
if (prompts.length !== 1 || !prompts[0].includes("after 2 retries")) {
  console.error(`alternating failures did not surface exactly once: ${JSON.stringify(prompts)} (${rows} cycles)`);
  process.exit(1);
}
if (rows !== 5) {
  console.error(`expected 3 failures interleaved with 2 empty closes, got ${rows} cycles`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "alternating real failures must still reach the failure bound and surface once"
  [ -z "$out" ] || fail "alternating-close test printed output: $out"
  pass "watch-arm: empty closes between real failures do not hide the failure"
}

# A home whose watcher can never establish exhausts the failure budget once and
# surfaces once. The budget is only replenished by a completed cycle, so every
# later failing close finds it already spent: the plugin must keep re-arming on
# session.idle without spending another model turn. Before the exhaustion latch
# the second idle prompted again - with the same "after N retries" text although
# no retry ran that round - which is one paid model turn per idle forever.
test_exhausted_failure_budget_surfaces_once_across_idles() {
  local dir out status
  dir=$(prepare_arm_home exhausted-failure)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/exhausted-failure-arm.log" \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = { session: { promptAsync: async (request) => { prompts.push(request.body.parts[0].text); } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const cycles = () =>
  existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length
    : 0;
const settle = (ms) => new Promise((done) => setTimeout(done, ms));

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-exhausted" } } });
for (let i = 0; i < 300 && prompts.length === 0; i += 1) await settle(10);
await settle(100);
if (prompts.length !== 1 || !prompts[0].includes("after 2 retries")) {
  console.error(`the first exhaustion did not surface exactly once: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
const armedBeforeSecondIdle = cycles();
if (armedBeforeSecondIdle !== 3) {
  console.error(`expected 1 failure plus 2 retries before the second idle, got ${armedBeforeSecondIdle}`);
  process.exit(1);
}

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-exhausted" } } });
for (let i = 0; i < 300 && cycles() === armedBeforeSecondIdle; i += 1) await settle(10);
await settle(150);
if (cycles() <= armedBeforeSecondIdle) {
  console.error("the second idle did not re-arm: an exhausted budget must not stop supervision attempts");
  process.exit(1);
}
if (prompts.length !== 1) {
  console.error(`an exhausted failure budget prompted again on the next idle: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "an exhausted failure budget must surface once, not once per idle"
  [ -z "$out" ] || fail "exhausted-failure test printed output: $out"
  pass "watch-arm: an unestablishable home re-arms every idle but spends only one model turn"
}

# The exhaustion notice is fire-and-forget, so an undelivered one must not
# retire the attempt. A home that can never establish supervision has no path
# back to a replenished budget, so latching over a rejected promptAsync leaves
# it permanently unsupervised with nothing surfaced anywhere - the same
# swallow-before-confirm shape the durable idle notice already closed.
test_undelivered_exhaustion_notice_stays_retryable() {
  local dir out status
  dir=$(prepare_arm_home undelivered-exhaustion)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/undelivered-exhaustion-arm.log" \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let attempts = 0;
// The real client rejects when the session was replaced mid-delivery; the
// plugin's surfaceFailure swallows that rejection by design.
const client = { session: { promptAsync: async () => { attempts += 1; throw new Error("session gone"); } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const cycles = () =>
  existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length
    : 0;
const settle = (ms) => new Promise((done) => setTimeout(done, ms));

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-undelivered" } } });
for (let i = 0; i < 300 && attempts === 0; i += 1) await settle(10);
await settle(100);
if (attempts !== 1) {
  console.error(`expected one undelivered exhaustion notice, got ${attempts}`);
  process.exit(1);
}
const armedBeforeSecondIdle = cycles();

// Same session: the budget is still exhausted, so only the failed delivery can
// make this close surface again.
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-undelivered" } } });
for (let i = 0; i < 300 && attempts < 2; i += 1) await settle(10);
await settle(100);
if (cycles() <= armedBeforeSecondIdle) {
  console.error("the second idle did not re-arm, so the notice retry was never reachable");
  process.exit(1);
}
if (attempts !== 2) {
  console.error(`an undelivered exhaustion notice was never retried: attempts=${attempts}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "an undelivered exhaustion notice must stay retryable"
  [ -z "$out" ] || fail "undelivered-exhaustion test printed output: $out"
  pass "watch-arm: an exhaustion notice that was not delivered does not retire the attempt"
}

# The failure budget is module state and outlives a session replacement, but a
# replaced session (/new, /resume) is a fresh context that cannot see the notice
# the previous one received, so it surfaces once on its own account. The budget
# itself stays spent - only a completed cycle replenishes it - so the replaced
# session re-arms without re-spending the retries.
test_replaced_session_gets_its_own_failure_budget() {
  local dir out status
  dir=$(prepare_arm_home replaced-session)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/replaced-session-arm.log" \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = { session: { promptAsync: async (request) => { prompts.push(request.path.id); } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const cycles = () =>
  existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length
    : 0;
const settle = (ms) => new Promise((done) => setTimeout(done, ms));

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-first" } } });
for (let i = 0; i < 300 && prompts.length === 0; i += 1) await settle(10);
await settle(100);
if (prompts.length !== 1 || prompts[0] !== "session-first") {
  console.error(`the first session did not surface exactly once: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
const armedByFirstSession = cycles();
if (armedByFirstSession !== 3) {
  console.error(`expected 1 failure plus 2 retries in the first session, got ${armedByFirstSession}`);
  process.exit(1);
}

// Session replacement in the same OpenCode process.
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-second" } } });
for (let i = 0; i < 300 && prompts.length < 2; i += 1) await settle(10);
await settle(100);
if (prompts.length !== 2 || prompts[1] !== "session-second") {
  console.error(`the replaced session never surfaced its own notice: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
if (cycles() !== armedByFirstSession + 1) {
  console.error(`the replaced session re-spent the failure retry budget: ${cycles()} cycles total`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "a replaced session must surface its own notice without a fresh retry budget"
  [ -z "$out" ] || fail "replaced-session test printed output: $out"
  pass "watch-arm: a replaced session surfaces once on a budget only a completed cycle replenishes"
}

# Nothing in the plugin distinguishes a replaced session from a concurrent or
# child one: both arrive as a different sessionID on session.idle. Keying the
# exhaustion notice to the session rather than replenishing the whole budget on
# every sessionID change is what stops two alternating sessions from ping-ponging
# a fresh budget - and one paid model turn - through an unestablishable home.
test_alternating_sessions_do_not_repay_the_exhaustion_notice() {
  local dir out status
  dir=$(prepare_arm_home alternating-sessions)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/alternating-sessions-arm.log" \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = { session: { promptAsync: async (request) => { prompts.push(request.path.id); } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const cycles = () =>
  existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length
    : 0;
const settle = (ms) => new Promise((done) => setTimeout(done, ms));

// Two sessions alternating idles on the same home, as a second client or a
// child session produces.
for (const sessionID of ["session-a", "session-b", "session-a", "session-b"]) {
  const before = cycles();
  await hooks.event({ event: { type: "session.idle", properties: { sessionID } } });
  for (let i = 0; i < 300 && cycles() === before; i += 1) await settle(10);
  await settle(120);
}

if (prompts.length !== 2) {
  console.error(`alternating sessions re-spent the exhaustion notice: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
if (prompts[0] !== "session-a" || prompts[1] !== "session-b") {
  console.error(`each session must surface exactly once, in order: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
if (cycles() < 4) {
  console.error(`alternating idles stopped re-arming after ${cycles()} cycles`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "alternating sessions must not ping-pong a fresh failure budget"
  [ -z "$out" ] || fail "alternating-sessions test printed output: $out"
  pass "watch-arm: alternating sessions each surface once and never repay the failure budget"
}

# A failure retry that relaunches into a home which no longer needs a watcher
# is benign: no failure prompt for supervision that is simply no longer owed.
test_retry_launch_into_a_no_longer_needed_home_is_silent() {
  local dir out status
  dir=$(prepare_arm_home retry-not-needed)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
rm -f "$FM_HOME/state/task.meta"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/retry-not-needed-arm.log" \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = { session: { promptAsync: async (request) => { prompts.push(request.body.parts[0].text); } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-not-needed" } } });
await new Promise((settle) => setTimeout(settle, 400));
const rows = existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length : 0;
if (rows !== 1) {
  console.error(`expected one arm before the need cleared, got ${rows} cycles`);
  process.exit(1);
}
if (prompts.length !== 0) {
  console.error(`a retry into a no-longer-needed home spent a model turn: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "a retry launch into a no-longer-needed home must stay silent"
  [ -z "$out" ] || fail "retry-not-needed test printed output: $out"
  pass "watch-arm: a failure retry that finds no remaining need does not prompt"
}

# A relaunched arm that is slow to confirm readiness is still a successful
# launch: the readiness budget can expire while the child is alive and about to
# print `watcher: started`. Reporting that as a launch failure spends a model
# turn on a home that is in fact supervised.
test_slow_confirming_retry_launch_does_not_prompt() {
  local dir out status
  dir=$(prepare_arm_home slow-retry)
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" = 1 ]; then
  printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
  exit 1
fi
sleep 0.3
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 0.3
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$PLUGIN" WORKTREE="$dir" FM_HOME="$dir" FM_ARM_LOG="$TMP_ROOT/slow-retry-arm.log" \
    FM_OPENCODE_ARM_READY_TIMEOUT_MS=50 \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const client = { session: { promptAsync: async (request) => { prompts.push(request.body.parts[0].text); } } };
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const rows = () =>
  existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length : 0;
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-slow-retry" } } });
for (let i = 0; i < 600 && rows() < 2; i += 1) {
  await new Promise((settle) => setTimeout(settle, 10));
}
if (rows() < 2) {
  console.error(`the failed cycle never produced a retry launch, got ${rows()} cycles`);
  process.exit(1);
}
// Past the readiness budget of the slow retry: this is where a launch mislabeled
// as a failure would have prompted.
await new Promise((settle) => setTimeout(settle, 250));
if (prompts.length !== 0) {
  console.error(`a slow-confirming retry launch spent a model turn: ${JSON.stringify(prompts)}`);
  process.exit(1);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "a retry launch that confirms readiness late must not prompt: $out"
  [ -z "$out" ] || fail "slow-retry test printed output: $out"
  pass "watch-arm: a slow-confirming retry launch is a success, not a watcher failure"
}

test_crewmate_idle_stays_silent() {
  local base dir out status
  base="$TMP_ROOT/crewmate-idle-base"
  dir="$TMP_ROOT/crewmate-idle-worktree"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  mkdir -p "$dir/config"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm-ran\n' >> "${FM_ARM_LOG:?}"
SH
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard-fired\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-watch-arm.sh" "$dir/bin/fm-turnend-guard.sh"
  : > "$dir/state/task.meta"
  out=$(PLUGIN="$PLUGIN" TURNEND="$TURNEND_PLUGIN" WORKTREE="$dir" FM_HOME="$dir" \
    FM_ARM_LOG="$TMP_ROOT/crewmate-idle-arm.log" "$NODE_BIN" --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const arm = await import(pathToFileURL(process.env.PLUGIN).href);
const guard = await import(pathToFileURL(process.env.TURNEND).href);
let prompts = 0;
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const armHooks = await arm.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guard.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await armHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-crewmate" } } });
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-crewmate" } } });
await new Promise((settle) => setTimeout(settle, 200));
if (existsSync(process.env.FM_ARM_LOG) && readFileSync(process.env.FM_ARM_LOG, "utf8").includes("arm-ran")) {
  console.error("crewmate worktree spawned an arm child");
  process.exit(1);
}
if (prompts !== 0) {
  console.error(`crewmate idle prompted ${prompts} times`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "a crewmate worktree must stay silent on idle"
  [ -z "$out" ] || fail "crewmate idle test printed output: $out"
  pass "watch-arm: a crewmate/scout worktree stays silent on idle (no arm, no model turn)"
}

test_primary_checkout_arms
test_bin_not_a_dir_stays_silent
test_secondmate_linked_home_arms
test_crewmate_worktree_stays_silent
test_stray_marker_cannot_spoof
test_annotated_marker_home_arms
test_blank_first_line_marker_cannot_spoof
test_unterminated_marker_matches_shell_owner
test_nbsp_marker_matches_shell_owner
test_symlinked_marker_cannot_spoof
test_secondmate_home_spawns_an_arm_child
test_empty_and_healthy_closes_are_idle_not_failure
test_healthy_close_does_not_prompt
test_empty_cycle_close_does_not_prompt
test_actionable_close_still_prompts
test_turnend_guard_stays_silent_when_watch_arm_loaded
test_procevent_source_home_arms_without_task_meta
test_turnend_guard_runs_when_coordinator_declines_read_only
test_idle_cycles_do_not_consume_the_failure_retry_budget
test_restoration_retries_an_idle_successor_close
test_established_cycles_replenish_the_idle_budget
test_idle_exhaustion_queues_one_durable_check_without_a_prompt
test_alternating_failure_and_empty_closes_still_surface
test_exhausted_failure_budget_surfaces_once_across_idles
test_undelivered_exhaustion_notice_stays_retryable
test_replaced_session_gets_its_own_failure_budget
test_alternating_sessions_do_not_repay_the_exhaustion_notice
test_retry_launch_into_a_no_longer_needed_home_is_silent
test_slow_confirming_retry_launch_does_not_prompt
test_crewmate_idle_stays_silent
