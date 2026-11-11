#!/usr/bin/env bash
# shellcheck shell=bash
# fm-project-skills-lib.sh - resolve and learn which skills a project usually needs.
#
# One owner of the project skill-profile contract:
#   config/project-skills.json  (optional home-local profile)
#   data/project-skills/<slug>.json  (learned hit counts; private under data/)
#
# Callers:
#   bin/fm-brief.sh   - emit "# Skills to load" for ship/scout scaffolds
#   bin/fm-spawn.sh   - build the OpenCode skill allowlist overlay
#
# Doctrine: never refuse a spawn because the profile is missing; fall back to
# always-set. Unreadable config never invents project-specific skills.

fm_project_skills_config() {
  printf '%s\n' "${FM_HOME:-$HOME/.firstmate}/config/project-skills.json"
}

fm_project_skills_learned_path() {  # <project-slug>
  local slug=$1
  printf '%s\n' "${FM_HOME:-$HOME/.firstmate}/data/project-skills/${slug}.json"
}

fm_project_skills_slug() {  # <repo-or-path>
  local raw=$1 base
  base=$(basename "$raw")
  base=${base%.git}
  printf '%s\n' "$base" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-//;s/-$//'
}

fm_project_skills_always() {
  if [ -n "${FM_PROJECT_SKILLS_ALWAYS:-}" ]; then
    # shellcheck disable=SC2086
    printf '%s\n' ${FM_PROJECT_SKILLS_ALWAYS}
    return 0
  fi
  printf '%s\n' no-mistakes
}

fm_project_skills_baseline() {
  if [ -n "${FM_PROJECT_SKILLS_BASELINE:-}" ]; then
    # shellcheck disable=SC2086
    printf '%s\n' ${FM_PROJECT_SKILLS_BASELINE}
    return 0
  fi
  return 0
}

fm_project_skills_configured() {  # <slug>
  local slug=$1 cfg
  cfg=$(fm_project_skills_config)
  [ -f "$cfg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg s "$slug" '
    (.projects[$s].skills // [])
    + (.defaults // [])
    | .[]?
  ' "$cfg" 2>/dev/null || true
}

fm_project_skills_learned() {  # <slug>
  local slug=$1 path
  path=$(fm_project_skills_learned_path "$slug")
  [ -f "$path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    (.hits // {})
    | to_entries
    | sort_by(-.value)
    | .[].key
  ' "$path" 2>/dev/null || true
}

fm_project_skills_detect_text() {  # <file-or-stdin>
  local input=${1:--}
  local catalog
  catalog=$(ls "${FM_TRACKED_ROOT:-${FM_ROOT:-.}}/.agents/skills" 2>/dev/null || true)
  [ -n "$catalog" ] || return 0
  if [ "$input" = - ]; then
    input=/dev/stdin
  else
    [ -f "$input" ] || return 0
  fi
  awk -v catalog="$catalog" '
    BEGIN {
      n = split(catalog, names, /\n/)
      for (i = 1; i <= n; i++) if (names[i] != "") want[names[i]] = 1
    }
    {
      line = $0
      for (name in want) {
        if (index(line, name) == 0) continue
        if (line ~ ("(^|[^A-Za-z0-9_-])" name "([^A-Za-z0-9_-]|$)")) seen[name] = 1
      }
    }
    END { for (name in seen) print name }
  ' "$input"
}

fm_project_skills_resolve() {  # <repo-or-path> [<brief-file>]
  local repo=$1 brief=${2:-} slug
  slug=$(fm_project_skills_slug "$repo")
  {
    fm_project_skills_always
    fm_project_skills_baseline
    fm_project_skills_configured "$slug"
    fm_project_skills_learned "$slug"
    if [ -n "$brief" ] && [ -f "$brief" ]; then
      fm_project_skills_detect_text "$brief"
    fi
  } | awk 'NF && !seen[$0]++'
}

fm_project_skills_observe() {  # <repo-or-path> <skill>
  local repo=$1 skill=$2 slug path dir tmp
  [ -n "$skill" ] || return 0
  slug=$(fm_project_skills_slug "$repo")
  path=$(fm_project_skills_learned_path "$slug")
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if [ ! -f "$path" ]; then
    printf '%s\n' '{"version":1,"hits":{}}' >"$path" || return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-project-skills.XXXXXX") || return 0
  if jq --arg s "$skill" '
      .version = (.version // 1)
      | .hits = (.hits // {})
      | .hits[$s] = ((.hits[$s] // 0) + 1)
    ' "$path" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
  fi
}

fm_project_skills_brief_section() {  # <repo-or-path> [<brief-file>]
  local repo=$1 brief=${2:-} skills
  skills=$(fm_project_skills_resolve "$repo" "$brief" | tr '\n' ' ')
  skills=$(printf '%s' "$skills" | sed 's/[[:space:]]*$//')
  cat <<EOF
# Skills to load
Load only the skills listed here for this project; do not preload the full firstmate skill catalog.
Project profile: ${skills:-"(baseline only - load a skill when its AGENTS.md trigger fires)"}
After you load an extra skill that proved necessary, tell firstmate so it can record it with fm_project_skills_observe.
EOF
}

fm_project_skills_opencode_permission_json() {  # <repo-or-path> [<brief-file>]
  local repo=$1 brief=${2:-} skill
  printf '{'
  printf '"*":"deny"'
  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    printf ',"%s":"allow"' "$skill"
  done < <(fm_project_skills_resolve "$repo" "$brief")
  printf '}'
}
