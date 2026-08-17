#!/usr/bin/env bash
# Build or query a per-project Graphify orientation index stored outside the
# repo.
#
# Graphify is a fleet-only, disposable orientation index. This helper never
# writes into the target project, never talks to DevVisualization, and never
# treats a scheduled rebuild as authoritative. docs/graphify.md owns install,
# the fleet-only boundary, the triggered consult rule, and the freshness
# policy. .agents/skills/graphify-orientation/SKILL.md owns the agent
# procedure. This header owns the commands, flags, index path, and stamp.
#
# Usage:
#   fm-graphify.sh build <repo>                 rebuild the index for <repo>
#   fm-graphify.sh query <repo> <question>      validate or rebuild, then query
#   fm-graphify.sh query <repo> <question> --budget N
#   fm-graphify.sh --help
#
# <repo> is any path inside a git work tree; the index key is that tree's
# toplevel real path, so two worktrees of the same repo do not share a cache.
# --budget is a positive integer token cap forwarded to `graphify query`
# (default 2000).
#
# Index path: $FM_HOME/data/graphify/<slug>-<id>/graphify-out/graph.json
#   FM_HOME defaults to this repo's tracked root; FM_DATA_OVERRIDE replaces
#   $FM_HOME/data. <slug> is the sanitized toplevel basename; <id> is a cksum
#   of the toplevel real path.
# Stamp file: $FM_HOME/data/graphify/<slug>-<id>/.fm-freshness
#   source=<toplevel real path>
#   rev=<git HEAD sha>
#   dirty=<cksum of porcelain + git diff HEAD + hashes of untracked files>
# A query rebuilds when graph.json is missing, or when the stamp is absent,
# unreadable, from another source, or does not match the tree's current
# revision and dirty-tree digest. The stamp is captured before extract runs,
# so a tree change during a rebuild mismatches on the next query.
# Rebuilds run `graphify extract <repo> --out <index-dir> --no-cluster
# --code-only` so the graph is AST-only and needs no API key.
#
# Exit 0 on a successful build or query.
# Exit 1 on usage errors.
# Exit 2 when the caller must fall back to reading source: graphify missing,
# not a git work tree, stamp unknown, extract/query failed, or extract wrote
# inside the project. Those paths print GRAPHIFY_FALLBACK=source.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DEFAULT_BUDGET=2000

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fallback() {
  printf '%s\n' "fm-graphify: $1" >&2
  printf 'GRAPHIFY_FALLBACK=source\n' >&2
  exit 2
}

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
    *) return 0 ;;
  esac
}

sanitize_slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

require_graphify() {
  if ! command -v graphify >/dev/null 2>&1; then
    fallback "graphify is not on PATH; install it (docs/graphify.md) and read source"
  fi
}

repo_toplevel() {
  local repo=$1 top
  if [ ! -e "$repo" ]; then
    fallback "repo path does not exist: $repo"
  fi
  if ! top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null); then
    fallback "not a git work tree; cannot validate revision or dirty-tree state"
  fi
  if [ -z "$top" ]; then
    fallback "not a git work tree; cannot validate revision or dirty-tree state"
  fi
  (cd "$top" && pwd -P)
}

index_dir_for() {
  local top=$1 slug id
  slug=$(sanitize_slug "$(basename "$top")")
  id=$(printf '%s' "$top" | cksum | awk '{print $1}')
  case "$id" in
    ''|*[!0-9]*) fallback "could not derive an index id for $top" ;;
  esac
  printf '%s/graphify/%s-%s\n' "$DATA" "$slug" "$id"
}

current_stamp() {
  local top=$1 rev dirty
  if ! rev=$(git -C "$top" rev-parse HEAD 2>/dev/null); then
    fallback "could not read HEAD for $top"
  fi
  case "$rev" in
    ''|*[!0-9a-fA-F]*) fallback "unreadable HEAD revision for $top" ;;
  esac
  dirty=$(
    {
      git -C "$top" status --porcelain=v1
      git -C "$top" diff HEAD
      git -C "$top" ls-files --others --exclude-standard -z |
        sort -z |
        while IFS= read -r -d '' f; do
          cksum "$top/$f"
        done
    } | cksum | awk '{print $1}'
  )
  case "$dirty" in
    ''|*[!0-9]*) fallback "could not digest dirty-tree state for $top" ;;
  esac
  printf 'source=%s\nrev=%s\ndirty=%s\n' "$top" "$rev" "$dirty"
}

stamp_matches() {
  local file=$1 expected=$2
  [ -f "$file" ] || return 1
  [ "$(cat "$file")" = "$expected" ]
}

extract_wrote_in_project() {
  local top=$1 existed=$2
  [ "$existed" = 0 ] && [ -e "$top/graphify-out" ]
}

rebuild_index() {
  local top=$1 index=$2 stamp=$3 existed=0
  require_graphify
  [ -e "$top/graphify-out" ] && existed=1
  mkdir -p "$index"
  if ! graphify extract "$top" --out "$index" --no-cluster --code-only; then
    fallback "graphify extract failed for $top"
  fi
  if extract_wrote_in_project "$top" "$existed"; then
    fallback "graphify extract wrote inside the project; refusing that index"
  fi
  if [ ! -f "$index/graphify-out/graph.json" ]; then
    fallback "graphify extract produced no graph.json under $index"
  fi
  printf '%s\n' "$stamp" > "$index/.fm-freshness"
}

CMD=
REPO=
QUESTION=
BUDGET=$DEFAULT_BUDGET

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  build|query)
    CMD=$1
    shift
    ;;
  *)
    printf 'fm-graphify: expected build or query\n' >&2
    usage >&2
    exit 1
    ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --budget)
      [ $# -ge 2 ] || { printf 'fm-graphify: --budget needs a positive integer\n' >&2; exit 1; }
      BUDGET=$2
      shift 2
      ;;
    --budget=*)
      BUDGET=${1#--budget=}
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-graphify: unknown flag %s\n' "$1" >&2
      exit 1
      ;;
    *)
      if [ -z "$REPO" ]; then
        REPO=$1
      elif [ "$CMD" = query ] && [ -z "$QUESTION" ]; then
        QUESTION=$1
      else
        printf 'fm-graphify: unexpected argument %s\n' "$1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ $# -gt 0 ]; then
  printf 'fm-graphify: unexpected argument %s\n' "$1" >&2
  exit 1
fi

if ! is_positive_int "$BUDGET"; then
  printf 'fm-graphify: --budget must be a positive integer\n' >&2
  exit 1
fi

[ -n "$REPO" ] || { printf 'fm-graphify: repo path required\n' >&2; exit 1; }
if [ "$CMD" = query ] && [ -z "$QUESTION" ]; then
  printf 'fm-graphify: query needs a question\n' >&2
  exit 1
fi

TOP=$(repo_toplevel "$REPO")
INDEX=$(index_dir_for "$TOP")
STAMP=$(current_stamp "$TOP")

if [ "$CMD" = build ]; then
  rebuild_index "$TOP" "$INDEX" "$STAMP"
  printf 'fm-graphify: built %s\n' "$INDEX/graphify-out/graph.json"
  exit 0
fi

if [ ! -f "$INDEX/graphify-out/graph.json" ] || ! stamp_matches "$INDEX/.fm-freshness" "$STAMP"; then
  printf 'fm-graphify: rebuilding index for %s (missing or stale)\n' "$TOP" >&2
  rebuild_index "$TOP" "$INDEX" "$STAMP"
fi

require_graphify
if ! graphify query "$QUESTION" --budget "$BUDGET" --graph "$INDEX/graphify-out/graph.json"; then
  fallback "graphify query failed"
fi
