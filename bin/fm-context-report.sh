#!/usr/bin/env bash
# fm-context-report.sh - measure supervising-agent context growth per wake.
#
# The primary firstmate and its Claude secondmates are long-lived sessions: each
# supervision wake is another full-context turn. This is a read-only diagnostic
# that quantifies that cost from the harness's OWN session transcripts, so a
# context-hygiene change can be measured before and after rather than argued.
#
# Claude-only first cut: it reads ~/.claude/projects/<encoded-cwd>/*.jsonl and
# sums each assistant record's input + cache-read + cache-creation tokens, which
# is the context the model had to carry for that turn. A "wake-handling turn" is
# approximated as each assistant turn: the transcripts do not label a turn as
# wake-driven, and every supervision wake produces exactly one such turn, so the
# per-turn distribution is the honest proxy. Wakes/hour is therefore turns per
# active hour of the session.
#
# Usage: fm-context-report.sh [--hours N] [--projects-dir DIR] [--all] [--json]
#   --hours N        look back N hours (default 24)
#   --projects-dir   transcript root (default ~/.claude/projects)
#   --all            include every Claude session, not only firstmate homes
#   --json           emit one JSON object instead of the text report
#
# Only sessions whose working directory is a firstmate home are reported by
# default, because the fleet's own homes are the long-lived sessions this
# measures. A missing transcript root is reported, never treated as an error.
set -u

HOURS=24
PROJECTS_DIR="$HOME/.claude/projects"
FIRSTMATE_ONLY=1
AS_JSON=0

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hours)
      [ "$#" -ge 2 ] || { echo "error: --hours requires a value" >&2; exit 2; }
      HOURS=$2
      shift 2
      ;;
    --hours=*)
      HOURS=${1#--hours=}
      shift
      ;;
    --projects-dir)
      [ "$#" -ge 2 ] || { echo "error: --projects-dir requires a value" >&2; exit 2; }
      PROJECTS_DIR=$2
      shift 2
      ;;
    --projects-dir=*)
      PROJECTS_DIR=${1#--projects-dir=}
      shift
      ;;
    --all)
      FIRSTMATE_ONLY=0
      shift
      ;;
    --json)
      AS_JSON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$HOURS" in
  ''|*[!0-9]*|0) echo "error: --hours must be a positive integer" >&2; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "error: fm-context-report.sh requires jq" >&2
  exit 1
fi
if [ ! -d "$PROJECTS_DIR" ]; then
  echo "no Claude transcript root at $PROJECTS_DIR; nothing to report"
  exit 0
fi

NOW=$(date +%s)
CUTOFF=$(( NOW - HOURS * 3600 ))
THRESHOLD=150000

# jq program: one TSV row per assistant turn inside the window:
#   cwd <TAB> epoch <TAB> tokens-in-context
# A record without a message.usage is not a turn and is skipped. A fractional
# seconds field is normalized to whole seconds before fromdateiso8601, and an
# unparseable timestamp is dropped rather than counted at epoch 0.
# shellcheck disable=SC2016 # jq program: $cutoff/$cwd/$t are jq variables, not shell.
JQ_PROGRAM='
  def tsec:
    try (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null;
  select(.message != null and .message.usage != null)
  | (.cwd // "") as $cwd
  | (tsec) as $t
  | select($t != null and $t >= $cutoff)
  | [ $cwd, $t,
      ((.message.usage.input_tokens // 0)
       + (.message.usage.cache_creation_input_tokens // 0)
       + (.message.usage.cache_read_input_tokens // 0)) ]
  | @tsv
'

ROWS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-context-report.XXXXXX") || exit 1
trap 'rm -f -- "$ROWS_FILE"' EXIT

# Only transcripts touched within the window can hold a turn inside it.
while IFS= read -r transcript; do
  [ -n "$transcript" ] || continue
  jq -r --argjson cutoff "$CUTOFF" "$JQ_PROGRAM" "$transcript" 2>/dev/null \
    >> "$ROWS_FILE" || true
done < <(find "$PROJECTS_DIR" -name '*.jsonl' -type f -mmin "-$(( HOURS * 60 ))" 2>/dev/null)

if [ ! -s "$ROWS_FILE" ]; then
  echo "no Claude turns in the last ${HOURS}h under $PROJECTS_DIR"
  exit 0
fi

# Aggregate per home (the session's recorded cwd). awk computes counts, means,
# medians, the >150k share, and active-window hours; a firstmate home is a cwd
# whose last path segment is "firstmate".
AGG_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-context-aggregate.XXXXXX") || exit 1
trap 'rm -f -- "$ROWS_FILE" "$AGG_FILE"' EXIT

awk -F '\t' -v firstmate_only="$FIRSTMATE_ONLY" -v threshold="$THRESHOLD" '
  function median(home, n,    i, j, t) {
    for (i = 1; i <= n; i++) scratch[i] = vals[home, i]
    for (i = 2; i <= n; i++) {
      t = scratch[i]
      for (j = i - 1; j >= 1 && scratch[j] > t; j--) scratch[j+1] = scratch[j]
      scratch[j+1] = t
    }
    if (n == 0) return 0
    if (n % 2) return scratch[(n+1)/2]
    return (scratch[n/2] + scratch[n/2+1]) / 2
  }
  {
    home = $1
    if (home == "") home = "(unknown)"
    if (firstmate_only) {
      n = split(home, parts, "/")
      if (parts[n] != "firstmate") next
    }
    if (!(home in seen)) { seen[home] = 1; homes[++nh] = home }
    tokens = $3 + 0
    count[home]++
    sum[home] += tokens
    vals[home, count[home]] = tokens
    if (tokens > threshold) above[home]++
    t = $2 + 0
    if (!(home in min) || t < min[home]) min[home] = t
    if (!(home in max) || t > max[home]) max[home] = t
    total_turns++
    total_sum += tokens
    if (tokens > threshold) total_above++
  }
  END {
    for (i = 1; i <= nh; i++) {
      h = homes[i]
      c = count[h]
      mean = (c ? sum[h] / c : 0)
      span = max[h] - min[h]
      hours = (span > 0 ? span / 3600 : 0)
      wph = (hours > 0 ? c / hours : 0)
      share = (c ? 100 * above[h] / c : 0)
      med = median(h, c)
      printf "%s\t%d\t%.2f\t%.0f\t%.0f\t%.1f\t%.1f\n", h, c, wph, mean, med, share, hours
    }
    tmean = (total_turns ? total_sum / total_turns : 0)
    tshare = (total_turns ? 100 * total_above / total_turns : 0)
    printf "TOTAL\t%d\t0\t%.0f\t0\t%.1f\t0\n", total_turns, tmean, tshare
  }
' "$ROWS_FILE" > "$AGG_FILE"

if [ "$AS_JSON" -eq 1 ]; then
  jq -Rn --argjson thr "$THRESHOLD" --argjson hours "$HOURS" '
    [ inputs | split("\t") | select(.[0] != "TOTAL")
      | { home: .[0],
          turns: (.[1] | tonumber),
          wakes_per_hour: (.[2] | tonumber),
          mean_tokens: (.[3] | tonumber),
          median_tokens: (.[4] | tonumber),
          share_above_threshold: (.[5] | tonumber),
          active_hours: (.[6] | tonumber) } ] as $homes
    | { hours: $hours, threshold: $thr, homes: $homes }
  ' "$AGG_FILE"
  exit 0
fi

printf 'Claude supervising-agent context report - last %sh, threshold %s tokens\n' "$HOURS" "$THRESHOLD"
printf 'wake-handling turn is approximated as each assistant turn; wakes/hour is turns per active hour\n\n'
printf '%-64s %8s %10s %12s %12s %10s %8s\n' HOME TURNS WAKES/HR MEAN_TOKENS MEDIAN_TOKENS PCT_GT_150K ACTIVE_H
awk -F '\t' '$1 != "TOTAL" { printf "%-64s %8s %10s %12s %12s %9s%% %8s\n", $1, $2, $3, $4, $5, $6, $7 }' "$AGG_FILE"
awk -F '\t' '$1 == "TOTAL" { printf "%-64s %8s %10s %12s %12s %9s%% %8s\n", "TOTAL", $2, "-", $4, "-", $6, "-" }' "$AGG_FILE"
