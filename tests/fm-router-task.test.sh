#!/usr/bin/env bash
# Behavior tests for the `--task` passthrough helpers in bin/fm-router-lib.sh:
# fm_router_captain_intent and fm_router_route_task_arg. These feed the
# llm-router-axi Jev shadow hook with the brief's captain's intent (docs/configuration.md
# "Jev shadow mode"), so the tests pin what firstmate owns:
#   - only the `## Captain's intent` section is extracted, never the Firstmate
#     spec or any later heading
#   - the compose helper writes a mode-0600 temp file and prints `--task <file>`,
#     and nothing at all when the brief or section is missing or a symlink
#   - routing is byte-identical with the flag against a fake router that only
#     appends shadow rows when LLM_ROUTER_JEV_SHADOW is enabled (mirroring the
#     real router's shadowKilled behavior)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTER_LIB="$ROOT/bin/fm-router-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-router-task)

# write_router <dir>: a fake llm-router-axi that records argv to <dir>/route.calls
# and appends one shadow row to $FM_FAKE_LEDGER only when the kill switch is not
# off (mirroring src/jev/shadow.ts's shadowKilled). Ledger, calls log, and the
# task file are resolved from env so the script body is a quoted heredoc with no
# write-time interpolation.
write_router() { # <dir>
  local dir=$1
  cat > "$dir/llm-router-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_ROUTE_CALLS:?}"
task=
args=("$@")
for idx in "${!args[@]}"; do
  if [ "${args[$idx]}" = --task ]; then task=${args[$((idx+1))]}; fi
done
case "${LLM_ROUTER_JEV_SHADOW:-}" in
  off|0|false|no) ;;
  *)
    if [ -n "$task" ] && [ -f "$task" ]; then
      sample=$(sed -n '/[^[:space:]]/p' "$task" | head -n 1)
      printf 'shadow-row\t%s\n' "$sample" >> "${FM_FAKE_LEDGER:?}"
    fi
    ;;
esac
printf -- '--harness claude --model claude-sonnet --effort medium\n'
SH
  chmod +x "$dir/llm-router-axi"
}

run_lib_route() { # <dir> <task-file-or-empty> <shadow> -> the fake router's stdout
  local dir=$1 task_file=$2 shadow=$3
  local -a task_flag=()
  [ -z "$task_file" ] || task_flag=(--task "$task_file")
  FM_FAKE_ROUTE_CALLS="$dir/route.calls" FM_FAKE_LEDGER="$dir/ledger" \
    LLM_ROUTER_JEV_SHADOW="$shadow" \
    "$dir/llm-router-axi" route --kind ship --difficulty easy --surface backend "${task_flag[@]}" --flags 2>/dev/null
}

{
  local_dir="$TMP_ROOT/extract"; mkdir -p "$local_dir"
  brief="$local_dir/brief.md"
  cat > "$brief" <<'MD'
# Task t-77

## Captain's intent

Dispatch the inventory reader as a ship.
Use the backend surface at medium difficulty.
Never touch the Firstmate spec below.

## Firstmate spec

Use mode=direct-PR with yolo off.
Record the pr= identity in the task meta.

## Notes

Anything after the spec is also excluded.
MD

# shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1 and $2.
  out=$(env -u FM_LLM_ROUTER_AXI bash -c '. "$1"; fm_router_captain_intent "$2"' _ "$ROUTER_LIB" "$brief")
  assert_contains "$out" "Dispatch the inventory reader as a ship." "captain intent body is extracted"
  assert_contains "$out" "Use the backend surface at medium difficulty." "second intent line is extracted"
  assert_not_contains "$out" "Use mode=direct-PR" "Firstmate spec must never be extracted as routing text"
  assert_not_contains "$out" "## Firstmate spec" "the spec heading itself is excluded"
  assert_not_contains "$out" "Anything after the spec" "a later-section body is excluded"
  pass "fm_router_captain_intent extracts only the '## Captain's intent' body"
}

{
  local_dir="$TMP_ROOT/compose"; mkdir -p "$local_dir"
  brief="$local_dir/brief.md"
  cat > "$brief" <<'MD'
# Task t-99

## Captain's intent

Audit the fallback chain on harness agy.

## Firstmate spec

Relaunch in place.
MD

# shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1 and $2.
  out=$(env -u FM_LLM_ROUTER_AXI bash -c '. "$1"; fm_router_route_task_arg "$2"' _ "$ROUTER_LIB" "$brief")
  case "$out" in
    --task\ *) : ;;
    *) fail "compose must print '--task <file>', got: $out" ;;
  esac
  task_file=${out#--task }
  assert_present "$task_file" "the composed temp file exists"
  perms=$(stat -c '%a' "$task_file" 2>/dev/null || stat -f '%Lp' "$task_file")
  [ "$perms" = 600 ] || fail "the task temp file must be mode 0600, got $perms"
  body=$(cat "$task_file")
  assert_contains "$body" "Audit the fallback chain on harness agy." "the temp file carries the captain's intent"
  assert_not_contains "$body" "Relaunch in place" "the Firstmate spec never reaches the task file"
  rm -f "$task_file"
  pass "fm_router_route_task_arg composes a mode-0600 '--task <file>' from the captain's intent"
}

{
  local_dir="$TMP_ROOT/missing"; mkdir -p "$local_dir"
  brief="$local_dir/brief.md"
  cat > "$brief" <<'MD'
# Task t-1

## Firstmate spec

Only a spec; no captain intent.
MD
# shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1 and $2.
  out=$(env -u FM_LLM_ROUTER_AXI bash -c '. "$1"; fm_router_route_task_arg "$2"' _ "$ROUTER_LIB" "$brief")
  assert_equals "" "$out" "no captain's intent means no --task flag"
# shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1 and $2.
  out=$(env -u FM_LLM_ROUTER_AXI bash -c '. "$1"; fm_router_route_task_arg "$2"' _ "$ROUTER_LIB" "$local_dir/no-such-brief.md")
  assert_equals "" "$out" "a missing brief means no --task flag"
  ln -sf "$brief" "$local_dir/link.md"
# shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1 and $2.
  out=$(env -u FM_LLM_ROUTER_AXI bash -c '. "$1"; fm_router_route_task_arg "$2"' _ "$ROUTER_LIB" "$local_dir/link.md")
  assert_equals "" "$out" "a symlinked brief is never read for routing text"
  pass "missing, sectionless, and symlinked briefs silently omit the --task flag"
}

{
  local_dir="$TMP_ROOT/byteid"; mkdir -p "$local_dir"
  : > "$local_dir/ledger"
  write_router "$local_dir"
  brief="$local_dir/brief.md"
  cat > "$brief" <<'MD'
## Captain's intent

Byte-identical routing must hold with shadow off.
MD
# shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1 and $2.
  task_file=$(env -u FM_LLM_ROUTER_AXI bash -c '. "$1"; fm_router_route_task_arg "$2"' _ "$ROUTER_LIB" "$brief")
  task_file=${task_file#--task }
  no_task_out=$(run_lib_route "$local_dir" "" off)
  with_task_out=$(run_lib_route "$local_dir" "$task_file" off)
  assert_equals "$no_task_out" "$with_task_out" "routing output is byte-identical with the --task flag when shadow is off"
  [ -s "$local_dir/ledger" ] && fail "shadow off must append no ledger row"
  pass "with shadow off, the --task flag changes neither the routing output nor the ledger"
}

{
  local_dir="$TMP_ROOT/shadowon"; mkdir -p "$local_dir"
  : > "$local_dir/ledger"
  write_router "$local_dir"
  brief="$local_dir/brief.md"
  cat > "$brief" <<'MD'
## Captain's intent

When shadow is on the row is recorded, the decision is unchanged.
MD
# shellcheck disable=SC2016 # The inner bash, not this test shell, expands $1 and $2.
  task_file=$(env -u FM_LLM_ROUTER_AXI bash -c '. "$1"; fm_router_route_task_arg "$2"' _ "$ROUTER_LIB" "$brief")
  task_file=${task_file#--task }
  out=$(run_lib_route "$local_dir" "$task_file" on)
  case "$out" in
    --harness\ claude*) : ;;
    *) fail "shadow-on routing must keep the same decision surface, got: $out" ;;
  esac
  [ -s "$local_dir/ledger" ] || fail "shadow on must append a ledger row"
  assert_contains "$(cat "$local_dir/ledger")" "shadow-row" "the recorded row carries the shadow marker"
  assert_contains "$(cat "$local_dir/ledger")" "When shadow is on the row is recorded" "the recorded row carries the captain's intent"
  pass "with shadow on, the captain's intent is recorded without changing the decision"
}

echo "# all fm-router-task tests passed"