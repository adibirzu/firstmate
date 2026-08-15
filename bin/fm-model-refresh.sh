#!/usr/bin/env bash
# fm-model-refresh.sh - refresh this home's record of which models each
# INSTALLED harness currently offers, and name what changed since last time.
#
# Model catalogs drift under us. A vendor adds a whole effort ladder, renames an
# id, or retires a free tier upstream mid-day, and nothing in firstmate notices
# until a dispatch fails or a written-down claim quietly becomes false. This
# script turns that drift into an observation: it asks each installed harness
# its own authoritative listing surface, writes a dated machine-readable
# catalog, and reports every id that is NEW since the previous run.
#
# It renders no dispatch verdict and maps nothing. A listing is evidence about
# what a harness offers, not a decision about what to spawn; the dispatch
# judgment stays with .agents/skills/quota-array-dispatch/SKILL.md and the
# per-harness facts stay in .agents/skills/harness-adapters/SKILL.md, whose
# model rows this command is what keeps current.
#
# Two facts it reports rather than hides:
#   - An absent harness is reported explicitly as `absent`, never skipped
#     silently, because "nothing to report" and "never asked" are different.
#   - A run where no harness produced a listing at all exits non-zero. A pass
#     that checked nothing must not read as a clean catalog.
#
# Listing surfaces are the ones recorded in harness-adapters. claude, codex,
# copilot, and cline expose their catalogs only through an interactive picker or
# a TTY-bound command, so they are reported as `no-listing` rather than guessed
# at. Parsing is per harness rather than a single heuristic: an unrecognized
# shape yields zero ids, which is reported as an `error`, so a changed output
# format surfaces as a failure instead of a silently empty catalog.
#
# PROBING IS OPT-IN AND NEVER RUNS BY DEFAULT. A listing says a model is
# offered; only a real one-token prompt says it is usable, and those differ in
# practice. That call spends real quota, so it happens only behind an explicit
# --probe, only for the harnesses whose non-interactive single-turn form is
# verified, and only up to a bounded count that is refused rather than silently
# truncated. A --probe naming a harness that is not installed is reported as
# skipped, not as a failure.
#
# Usage:
#   fm-model-refresh.sh [--catalog <path>] [--json]
#   fm-model-refresh.sh --probe <harness>[=<model>] ...
#   fm-model-refresh.sh --list-harnesses
#   fm-model-refresh.sh --help
#
# Options:
#   --catalog <path>   catalog file to read and rewrite; defaults to
#                      $FM_HOME/data/model-catalog.json, and FM_HOME must be
#                      explicit so a catalog can never land in another home
#   --json             also print the written catalog to stdout
#   --probe <spec>     repeatable, opt-in. `<harness>` probes that harness's
#                      models that are new in THIS run; `<harness>=<model>`
#                      probes exactly that one id
#   --list-harnesses   print the registry and exit without running anything
#
# Exit status: 0 when the catalog was written, 2 on a usage error, 3 when no
# harness produced a listing, 4 when a requested probe set exceeds its bound.
#
# Environment:
#   FM_MODEL_REFRESH_TIMEOUT     hard bound per listing command (default 60)
#   FM_MODEL_PROBE_TIMEOUT       hard bound per probe (default 180)
#   FM_MODEL_PROBE_MAX           probes allowed in one run (default 10)
#   FM_MODEL_REFRESH_HARNESSES   test-only seam: space-separated subset of the
#                                registry to consider this run
set -u

SELF=fm-model-refresh
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$BIN_DIR/fm-timeout-lib.sh"

# harness|binary|parse-mode|listing args...
#
# parse modes: pairs (id then " - " or a tab then a label), bullets (a "*"/"-"
# bullet then the id), bare (one bare id per line), kimi-json (a JSON provider
# document), auto (try pairs, then bullets, then bare), none (no non-interactive
# listing surface exists).
#
# pairs/bullets/kimi-json are pinned to a surface whose real output was read
# first-hand. `auto` marks a documented listing surface whose exact shape was
# not reachable here; it still fails loudly on zero ids rather than guessing.
registry() {
  cat <<'EOF'
cursor|cursor-agent|pairs|--list-models
grok|grok|bullets|models
agy|agy|pairs|models
opencode|opencode|auto|models
pi|pi|auto|--list-models
kimi|kimi|kimi-json|provider list --json
claude||none|
codex||none|
copilot||none|
cline||none|
EOF
}

# harness|binary|single-turn flag - the verified non-interactive single-turn form
# for each probe-capable harness. A harness absent from this table is reported as
# probe-unsupported rather than probed on a guessed invocation; probe_run below
# owns each one's exact argv and its containment.
probe_form() {
  case "$1" in
    cursor) printf 'cursor-agent|-p\n' ;;
    grok) printf 'grok|-p\n' ;;
    agy) printf 'agy|-p\n' ;;
    *) return 1 ;;
  esac
}

# The header above is the help text, printed up to the first line of code, so
# editing one can never leave the other stale.
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

die() {
  printf '%s: %s\n' "$SELF" "$1" >&2
  exit "${2:-2}"
}

note() {
  printf '%s: %s\n' "$SELF" "$1" >&2
}

CATALOG=
PRINT_JSON=0
LIST_ONLY=0
PROBE_SPECS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-harnesses) LIST_ONLY=1; shift ;;
    --json) PRINT_JSON=1; shift ;;
    --catalog)
      [ $# -ge 2 ] || die "--catalog requires a value"
      CATALOG=$2; shift 2 ;;
    --probe)
      [ $# -ge 2 ] || die "--probe requires <harness>[=<model>]"
      PROBE_SPECS+=("$2"); shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required to write the catalog"

if [ "$LIST_ONLY" = 1 ]; then
  printf 'harness\tbinary\tlisting\n'
  while IFS='|' read -r harness binary mode args; do
    [ -n "$harness" ] || continue
    if [ "$mode" = none ]; then
      printf '%s\t-\t(no non-interactive listing surface)\n' "$harness"
    else
      printf '%s\t%s\t%s %s\n' "$harness" "$binary" "$binary" "$args"
    fi
  done < <(registry)
  exit 0
fi

if [ -z "$CATALOG" ]; then
  [ -n "${FM_HOME:-}" ] || die "FM_HOME must be explicit, or pass --catalog"
  [ -d "$FM_HOME" ] || die "FM_HOME is not a readable directory: $FM_HOME"
  CATALOG="$FM_HOME/data/model-catalog.json"
fi

LIST_TIMEOUT=${FM_MODEL_REFRESH_TIMEOUT:-60}
case "$LIST_TIMEOUT" in ''|*[!0-9]*|0*) LIST_TIMEOUT=60 ;; esac
PROBE_TIMEOUT=${FM_MODEL_PROBE_TIMEOUT:-180}
case "$PROBE_TIMEOUT" in ''|*[!0-9]*|0*) PROBE_TIMEOUT=180 ;; esac
PROBE_MAX=${FM_MODEL_PROBE_MAX:-10}
case "$PROBE_MAX" in ''|*[!0-9]*) PROBE_MAX=10 ;; esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-refresh.XXXXXX") || die "could not create a work directory"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=${STAMP%%T*}

if [ -f "$CATALOG" ] && jq -e . "$CATALOG" >/dev/null 2>&1; then
  cp "$CATALOG" "$WORK/previous.json"
else
  printf '{"schemaVersion":1,"harnesses":[]}\n' > "$WORK/previous.json"
fi

# Vendor CLIs colorize and box their output; strip escapes before any parse so a
# styled listing does not read as an unrecognized shape.
strip_ansi() {
  sed -e 's/'$'\033''\[[0-9;?]*[a-zA-Z]//g' -e 's/'$'\r''//g'
}

parse_pairs() {
  awk '
    match($0, /^[A-Za-z0-9][^ \t]*( - |\t)/) {
      id = substr($0, 1, RLENGTH)
      sub(/( - |\t)$/, "", id)
      print id
    }'
}

parse_bullets() {
  awk '/^[ \t]*[*-][ \t]+[A-Za-z0-9]/ { print $2 }'
}

parse_bare() {
  awk 'NF == 1 { print $1 }'
}

parse_kimi_json() {
  jq -r '[.. | objects | select(has("models")) | .models[]?
          | if type == "string" then . else (.id // .model // .name // empty) end]
         | .[]?' 2>/dev/null
}

# One shared id-shape gate over every mode, so a header line, prose, or a boxed
# border can never enter the catalog as a model id.
keep_ids() {
  awk '$0 ~ /^[A-Za-z0-9][A-Za-z0-9._\/:@+-]*$/ && !seen[$0]++ { print }'
}

parse_listing() { # <mode> <raw-file> <out-file>
  local mode=$1 raw=$2 out=$3
  case "$mode" in
    pairs) parse_pairs < "$raw" ;;
    bullets) parse_bullets < "$raw" ;;
    bare) parse_bare < "$raw" ;;
    kimi-json) parse_kimi_json < "$raw" ;;
    auto)
      parse_pairs < "$raw" | keep_ids > "$out.try"
      if [ ! -s "$out.try" ]; then parse_bullets < "$raw" | keep_ids > "$out.try"; fi
      if [ ! -s "$out.try" ]; then parse_bare < "$raw" | keep_ids > "$out.try"; fi
      cat "$out.try"
      ;;
  esac | keep_ids > "$out"
}

json_string_array() { # reads ids on stdin
  jq -R -s 'split("\n") | map(select(length > 0))'
}

LISTED=0
ABSENT=0
NOLISTING=0
ERRORED=0
printf '[]' > "$WORK/entries.json"

harness_selected() { # <harness>
  local wanted=${FM_MODEL_REFRESH_HARNESSES:-} item
  [ -n "$wanted" ] || return 0
  for item in $wanted; do
    [ "$item" = "$1" ] && return 0
  done
  return 1
}

append_entry() { # <entry-json-file>
  jq -s '.[0] + [.[1]]' "$WORK/entries.json" "$1" > "$WORK/entries.next" \
    && mv "$WORK/entries.next" "$WORK/entries.json"
}

while IFS='|' read -r harness binary mode args; do
  [ -n "$harness" ] || continue
  harness_selected "$harness" || continue

  ids_file="$WORK/$harness.ids"
  : > "$ids_file"
  status=
  command_line=
  reason=

  if [ "$mode" = none ]; then
    status=no-listing
    reason="no non-interactive model listing surface exists for this harness"
    NOLISTING=$((NOLISTING + 1))
  elif ! command -v "$binary" >/dev/null 2>&1; then
    status=absent
    reason="$binary is not on PATH"
    ABSENT=$((ABSENT + 1))
  else
    command_line="$binary $args"
    rc=0
    # shellcheck disable=SC2086
    fm_run_timed "$LIST_TIMEOUT" "$binary" $args </dev/null > "$WORK/$harness.raw" 2>/dev/null || rc=$?
    strip_ansi < "$WORK/$harness.raw" > "$WORK/$harness.clean"
    parse_listing "$mode" "$WORK/$harness.clean" "$ids_file"
    if [ "$rc" = 124 ]; then
      status=error
      reason="the listing command did not finish within ${LIST_TIMEOUT}s"
      ERRORED=$((ERRORED + 1))
    elif [ ! -s "$ids_file" ]; then
      status=error
      # Zero ids is deliberately not treated as an empty catalog: from the ids
      # alone a changed output format and an account that genuinely offers no
      # model are indistinguishable, and both need a human to look.
      reason="the listing produced no recognizable model ids; read its output directly to tell a changed format from an account with no models"
      ERRORED=$((ERRORED + 1))
    else
      status=listed
      LISTED=$((LISTED + 1))
    fi
  fi

  json_string_array < "$ids_file" > "$WORK/$harness.ids.json"
  jq -n \
    --arg harness "$harness" \
    --arg status "$status" \
    --arg command "$command_line" \
    --arg reason "$reason" \
    --arg today "$TODAY" \
    --slurpfile ids "$WORK/$harness.ids.json" \
    --slurpfile previous "$WORK/previous.json" '
    ($previous[0].harnesses // [] | map(select(.harness == $harness)) | .[0]) as $prior
    | ($prior.models // []) as $priorModels
    | ($priorModels | map(.id)) as $priorIds
    | $ids[0] as $current
    | {
        harness: $harness,
        status: $status,
        command: (if $command == "" then null else $command end),
        reason: (if $reason == "" then null else $reason end),
        models: [$current[] | . as $id | {
          id: $id,
          firstSeen: (($priorModels | map(select(.id == $id)) | .[0].firstSeen) // $today),
          probe: (($priorModels | map(select(.id == $id)) | .[0].probe) // null)
        }],
        new: [$current[] | select(. as $id | ($priorIds | index($id)) == null)],
        removed: [$priorIds[]? | select(. as $id | ($current | index($id)) == null)]
      }
    | if $status != "listed" and ($prior != null) then
        .models = $priorModels
        | .new = []
        | .removed = []
        | .carriedForward = true
      else . end
  ' > "$WORK/$harness.entry.json"
  append_entry "$WORK/$harness.entry.json"
done < <(registry)

if [ "$LISTED" = 0 ]; then
  note "no harness produced a model listing (absent=$ABSENT no-listing=$NOLISTING error=$ERRORED)"
  die "refusing to record a catalog from a run that checked nothing" 3
fi

# --- opt-in probing ---------------------------------------------------------

probe_targets_file="$WORK/probe-targets"
: > "$probe_targets_file"

for spec in ${PROBE_SPECS+"${PROBE_SPECS[@]}"}; do
  probe_harness=${spec%%=*}
  probe_model=
  case "$spec" in *=*) probe_model=${spec#*=} ;; esac
  [ -n "$probe_harness" ] || die "--probe needs a harness name"

  if ! registry | grep -q "^$probe_harness|"; then
    die "--probe names an unregistered harness: $probe_harness"
  fi
  if ! probe_binary_form=$(probe_form "$probe_harness"); then
    note "probe skipped: $probe_harness has no verified non-interactive single-turn form"
    continue
  fi
  probe_binary=${probe_binary_form%%|*}
  if ! command -v "$probe_binary" >/dev/null 2>&1; then
    note "probe skipped: $probe_harness is not installed"
    continue
  fi
  if [ -n "$probe_model" ]; then
    printf '%s\t%s\n' "$probe_harness" "$probe_model" >> "$probe_targets_file"
  else
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      printf '%s\t%s\n' "$probe_harness" "$id" >> "$probe_targets_file"
    done < <(jq -r --arg h "$probe_harness" '.[] | select(.harness == $h) | .new[]?' "$WORK/entries.json")
  fi
done

probe_count=$(grep -c . "$probe_targets_file" 2>/dev/null || true)
probe_count=${probe_count:-0}
if [ "${#PROBE_SPECS[@]}" -gt 0 ] && [ "$probe_count" = 0 ]; then
  note "no probe targets: every named harness was skipped, or it listed nothing new to probe"
fi
if [ "$probe_count" -gt "$PROBE_MAX" ]; then
  note "requested $probe_count probes, which exceeds the FM_MODEL_PROBE_MAX bound of $PROBE_MAX"
  die "refusing to probe a truncated subset; narrow the request or raise the bound" 4
fi

# Every probe runs from a fresh empty directory, never the caller's working
# directory, so an agent CLI that is willing to touch its workspace has an empty
# one to touch. Cursor additionally needs `--trust` (its workspace-trust dialog
# otherwise refuses a headless run outright) and is held to its read-only `ask`
# mode, so the grant it needs to answer at all cannot become a write.
probe_run() { # <harness> <model> -> prints usable|unusable|error
  local harness=$1 model=$2 form binary flag sandbox rc=0
  form=$(probe_form "$harness") || { printf 'error\n'; return 0; }
  binary=${form%%|*}
  flag=${form#*|}
  sandbox="$WORK/probe-cwd"
  rm -rf "$sandbox"
  mkdir -p "$sandbox"
  case "$harness" in
    cursor) (cd "$sandbox" && fm_run_timed "$PROBE_TIMEOUT" "$binary" "$flag" --trust --mode ask --model "$model" hi </dev/null) > "$WORK/probe.out" 2>/dev/null || rc=$? ;;
    grok) (cd "$sandbox" && fm_run_timed "$PROBE_TIMEOUT" "$binary" "$flag" hi -m "$model" </dev/null) > "$WORK/probe.out" 2>/dev/null || rc=$? ;;
    agy) (cd "$sandbox" && fm_run_timed "$PROBE_TIMEOUT" "$binary" "$flag" hi --model "$model" </dev/null) > "$WORK/probe.out" 2>/dev/null || rc=$? ;;
    *) printf 'error\n'; return 0 ;;
  esac
  if [ "$rc" = 124 ]; then
    printf 'error\n'
  elif [ "$rc" != 0 ] || [ ! -s "$WORK/probe.out" ]; then
    printf 'unusable\n'
  else
    printf 'usable\n'
  fi
}

while IFS=$'\t' read -r probe_harness probe_model; do
  [ -n "$probe_harness" ] || continue
  verdict=$(probe_run "$probe_harness" "$probe_model")
  note "probe harness=$probe_harness model=$probe_model result=$verdict"
  jq --arg h "$probe_harness" --arg m "$probe_model" --arg v "$verdict" --arg at "$TODAY" '
    map(if .harness == $h then
          .models = [.models[]? | if .id == $m then .probe = {status: $v, checkedAt: $at} else . end]
        else . end)
  ' "$WORK/entries.json" > "$WORK/entries.next" && mv "$WORK/entries.next" "$WORK/entries.json"
done < "$probe_targets_file"

# --- publish ----------------------------------------------------------------

jq -n --arg generatedAt "$STAMP" --slurpfile entries "$WORK/entries.json" \
  '{schemaVersion: 1, generatedAt: $generatedAt, harnesses: $entries[0]}' > "$WORK/catalog.json" \
  || die "could not build the catalog document" 1

mkdir -p "$(dirname "$CATALOG")" || die "could not create the catalog directory" 1
cp "$WORK/catalog.json" "$CATALOG.tmp.$$" || die "could not stage the catalog" 1
mv "$CATALOG.tmp.$$" "$CATALOG" || die "could not publish the catalog" 1

printf '%s: catalog %s generated %s\n' "$SELF" "$CATALOG" "$STAMP"
jq -r '.harnesses[]
  | "harness=\(.harness) status=\(.status)"
    + (if .status == "listed" then " models=\(.models | length) new=\(.new | length) removed=\(.removed | length)" else "" end)
    + (if .status != "listed" and .reason != null then " - \(.reason)" else "" end)
    + (if (.new | length) > 0 then "\n  new since last run: " + (.new | join(", ")) else "" end)
    + (if (.removed | length) > 0 then "\n  gone since last run: " + (.removed | join(", ")) else "" end)
  ' "$CATALOG"
printf '%s: listed=%s absent=%s no-listing=%s error=%s\n' "$SELF" "$LISTED" "$ABSENT" "$NOLISTING" "$ERRORED"

if [ "$PRINT_JSON" = 1 ]; then
  cat "$CATALOG"
fi
