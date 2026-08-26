#!/usr/bin/env bash
# Behavior tests for bin/fm-captain-hold-batcher.sh and .mjs.
#
# Guarantees under test:
#   - parses all hold-kind: captain items from backlog.md
#   - groups items by project/repo
#   - renders an interactive Lavish HTML digest with Accept, Reject, Defer buttons
#   - respects --daily gate and records today's run
#   - path and status subcommands report accurately
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BATCHER="$ROOT/bin/fm-captain-hold-batcher.sh"
PARSER="$ROOT/bin/fm-captain-hold-batcher.mjs"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-batcher)
fm_git_identity

SAMPLE_BACKLOG='
# Fleet Backlog

- [ ] firstmate-auto-task - task in progress (repo: firstmate) (kind: ship)
- [ ] proj-a-hold-1 - Choose database schema for proj A (repo: proj-a) (kind: captain) (since 2026-08-01) (hold: Must choose PostgreSQL vs SQLite) (hold-kind: captain)
- [ ] proj-a-hold-2 - Choose API auth mechanism (repo: proj-a) (kind: captain) (since 2026-08-02) (hold: Choose JWT vs sessions) (hold-kind: captain)
- [ ] proj-b-hold-1 - Approve cloud deployment target (repo: proj-b) (kind: captain) (since 2026-08-03) (hold: Choose AWS vs GCP) (hold-kind: captain)
- [ ] ordinary-done - Finished task (repo: proj-b) (kind: ship)
'

# --- Test 1: Parser extracts and groups hold-kind: captain items ---
{
  dir="$TMP_ROOT/test-parser"
  mkdir -p "$dir/data"
  printf '%s\n' "$SAMPLE_BACKLOG" > "$dir/data/backlog.md"

  json=$(node "$PARSER" --backlog "$dir/data/backlog.md" --json)
  total=$(printf '%s\n' "$json" | jq -r '.total')
  [ "$total" -eq 3 ] || fail "expected 3 hold-kind:captain items, got $total"

  proj_a_count=$(printf '%s\n' "$json" | jq -r '.projects["proj-a"] | length')
  [ "$proj_a_count" -eq 2 ] || fail "expected 2 items for proj-a, got $proj_a_count"

  proj_b_count=$(printf '%s\n' "$json" | jq -r '.projects["proj-b"] | length')
  [ "$proj_b_count" -eq 1 ] || fail "expected 1 item for proj-b, got $proj_b_count"

  pass "captain-hold-batcher: parses and groups hold-kind:captain items by project"
}

# --- Test 2: Build generates Lavish HTML digest with Accept/Reject/Defer ---
{
  dir="$TMP_ROOT/test-build"
  mkdir -p "$dir/data" "$dir/state" "$dir/fakebin"
  printf '%s\n' "$SAMPLE_BACKLOG" > "$dir/data/backlog.md"
  fm_fake_exit0 "$dir/fakebin" lavish-axi

  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" "$BATCHER" build --force 2>&1)
  html="$dir/.lavish/captain-hold-digest.html"
  [ -f "$html" ] || fail "digest HTML should exist at $html: $out"

  content=$(cat "$html")
  assert_contains "$content" "Captain Holds Daily Batch" "title exists in HTML"
  assert_contains "$content" "proj-a" "project proj-a exists in HTML"
  assert_contains "$content" "proj-b" "project proj-b exists in HTML"
  assert_contains "$content" "proj-a-hold-1" "item proj-a-hold-1 exists in HTML"
  assert_contains "$content" "Must choose PostgreSQL vs SQLite" "hold reason exists in HTML"
  assert_contains "$content" "btn-accept" "Accept button exists"
  assert_contains "$content" "btn-reject" "Reject button exists"
  assert_contains "$content" "btn-defer" "Defer button exists"

  pass "captain-hold-batcher: generates HTML with Accept/Reject/Defer options"
}

{
  dir="$TMP_ROOT/test-interaction"
  mkdir -p "$dir/data" "$dir/output"
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] quoted-hold - Captain's "approval" </h3><img src=x onerror=evil> & urgent (repo: proj-q) (kind: captain) (hold: Confirm) (hold-kind: captain)
EOF
  node "$PARSER" --backlog "$dir/data/backlog.md" --output "$dir/output/digest.html"
  HTML="$dir/output/digest.html" node <<'EOF'
const { readFileSync } = require("node:fs");
const vm = require("node:vm");

const html = readFileSync(process.env.HTML, "utf8");
const script = html.match(/<script>([\s\S]*)<\/script>/);
const question = html.match(/data-lavish-question="([^"]+)"/);
const title = html.match(/data-lavish-title="([^"]+)"/);
if (!script || !question || !title) throw new Error("digest did not publish an interactive card");
const decode = (value) => value
  .replace(/&quot;/g, '"')
  .replace(/&#39;/g, "'")
  .replace(/&lt;/g, "<")
  .replace(/&gt;/g, ">")
  .replace(/&amp;/g, "&");
const queued = [];
const row = { dataset: { lavishQuestion: decode(question[1]), lavishTitle: decode(title[1]) } };
const card = { classList: { add() {} } };
const status = {};
const buttons = [
  ["Accept", "release"],
  ["Reject", "done"],
  ["Defer", "done"],
].map(([choice, closeMode]) => ({
  dataset: { choice, closeMode },
  parentElement: row,
  addEventListener(type, handler) { if (type === "click") this.click = handler; },
}));
const context = {
  window: { lavish: { queuePrompt(prompt, payload) { queued.push({ prompt, payload }); } } },
  document: {
    getElementById(id) { return id === `card-${row.dataset.lavishQuestion}` ? card : status; },
    querySelectorAll(selector) { return selector === ".btn-row button" ? buttons : []; },
  },
};
vm.runInNewContext(script[1], context);
for (const button of buttons) button.click();
const expectedTitle = 'Captain\'s "approval" </h3><img src=x onerror=evil> & urgent';
const expected = [["Accept", "release"], ["Reject", "done"], ["Defer", "done"]];
if (queued.length !== expected.length) throw new Error("card actions did not queue every choice");
for (const [index, [answer, close]] of expected.entries()) {
  const entry = queued[index];
  if (entry.prompt !== `Captain Hold: ${expectedTitle} -> ${answer}`
    || entry.payload.text !== `${expectedTitle} -> ${answer}`
    || entry.payload.data.question !== "quoted-hold"
    || entry.payload.data.answer !== answer
    || entry.payload.data.close !== close) {
    throw new Error(`queued ${answer} payload was incorrect`);
  }
}
EOF

  pass "captain-hold-batcher: card choices queue keyed Lavish payloads"
}

# --- Test 3: Status reports accurately and --daily gates execution ---
{
  dir="$TMP_ROOT/test-daily-gate"
  mkdir -p "$dir/data" "$dir/state" "$dir/fakebin"
  printf '%s\n' "$SAMPLE_BACKLOG" > "$dir/data/backlog.md"
  fm_fake_exit0 "$dir/fakebin" lavish-axi

  status_out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" "$BATCHER" status)
  assert_contains "$status_out" "status: pending" "initial status is pending"

  # Run build
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" "$BATCHER" build --force >/dev/null

  status_out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" "$BATCHER" status)
  assert_contains "$status_out" "status: ran-today" "status after run is ran-today"

  # Second build with --daily should skip
  daily_out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" "$BATCHER" build --daily)
  assert_contains "$daily_out" "already generated" "--daily skips when already run"

  pass "captain-hold-batcher: respects daily cadence marker and reports status"
}

# --- Test 4: Daily marker is written only after keyed-answer arming succeeds ---
{
  dir="$TMP_ROOT/test-arm-retry"
  mkdir -p "$dir/data" "$dir/state" "$dir/fakebin"
  printf '%s\n' "$SAMPLE_BACKLOG" > "$dir/data/backlog.md"
  cat > "$dir/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/fakebin/lavish-axi"

  if PATH="$dir/fakebin:$PATH" FM_HOME="$dir" "$BATCHER" build --daily >/dev/null 2>&1; then
    fail "batcher should fail when Lavish session setup fails"
  fi
  [ ! -e "$dir/state/.last-captain-hold-digest" ] \
    || fail "failed arming must not record the daily marker"

  fm_fake_exit0 "$dir/fakebin" lavish-axi
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" "$BATCHER" build --daily >/dev/null \
    || fail "batcher should retry and arm after Lavish recovers"
  [ -f "$dir/state/.last-captain-hold-digest" ] \
    || fail "successful arming must record the daily marker"

  pass "captain-hold-batcher: retries daily arming after a failed setup"
}

printf 'All fm-captain-hold-batcher tests passed.\n'
