#!/usr/bin/env bash
# fm-fleet-lib.sh — FirstMate federated multi-operator KB library.
#
# Cross-uid-safe coordination through a SHARED group-writable git-backed dir only.
# Operators never write each other's private homes; they share this KB and use
# flock advisory locks on the backlog for atomic, no-overlap claims.
#
# KB layout ($dir):
#   operators.md  md table: | operator | scope | home | accounts | status | seen | quota |
#   projects.md   md table: | project | owner | path |
#   backlog.md    sections ## Queued / ## Claimed / ## In-flight / ## Done
#                 item line: - [id:<ID>] scope:<S> | <DESC> | [claimed-by:<op>@<ISO>] status:<st>
#   events.log    append-only TSV: <ISO8601>\t<operator>\t<event>\t<id>\t<detail>
#   locks/        flock targets (backlog.lock)
#
# Every mutating function takes the backlog lock and asserts the target is a
# shared/own dir (never a foreign /home).

fm_fleet_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Built-in last-resort fleet dir. Only reached when neither FM_FLEET_DIR nor
# $FM_HOME/config/fleet-dir is set. It is a *convention*, not a guarantee: on a
# shared host it may already belong to another team, so fm_fleet_assert_initialized
# tells the operator exactly which dir was chosen and how it was chosen.
FM_FLEET_DEFAULT_DIR=${FM_FLEET_DEFAULT_DIR:-/opt/agents/fleet}

fm_fleet_dir() {
  local d="${FM_FLEET_DIR:-}"
  if [ -z "$d" ] && [ -n "${FM_HOME:-}" ] && [ -f "$FM_HOME/config/fleet-dir" ]; then
    d=$(head -n1 "$FM_HOME/config/fleet-dir")
  fi
  [ -n "$d" ] || d=$FM_FLEET_DEFAULT_DIR
  printf '%s\n' "$d"
}

# How the dir was chosen: env|config|default. Deliberately a FUNCTION, not a global
# set inside fm_fleet_dir: callers do `DIR=$(fm_fleet_dir)`, and a variable assigned
# inside command substitution dies with the subshell — a global here would silently
# read as empty and any guard keyed on it would never fire.
fm_fleet_dir_source() {
  if [ -n "${FM_FLEET_DIR:-}" ]; then printf 'env\n'
  elif [ -n "${FM_HOME:-}" ] && [ -f "$FM_HOME/config/fleet-dir" ]; then printf 'config\n'
  else printf 'default\n'; fi
}

# Guard for every verb that READS an existing fleet. Without this, an uninitialized
# or wrong dir surfaces as `awk: fatal: cannot open .../operators.md` with exit 0 —
# a raw internal error that also *looks* like success to a caller. Fail loudly with
# the dir, how it was chosen, and the one command that fixes it.
fm_fleet_assert_initialized() { # dir
  local dir=$1 how; how=$(fm_fleet_dir_source)
  if [ -d "$dir" ] && [ -f "$dir/operators.md" ]; then return 0; fi

  {
    printf 'fm-fleet: no initialized fleet at %s\n' "$dir"
    case "$how" in
      env)     printf '  (chosen by FM_FLEET_DIR)\n' ;;
      config)  printf '  (chosen by %s/config/fleet-dir)\n' "${FM_HOME:-\$FM_HOME}" ;;
      default) printf '  (nothing configured, so the built-in default %s was used)\n' "$FM_FLEET_DEFAULT_DIR" ;;
    esac
    if [ ! -d "$dir" ]; then
      printf '  the directory does not exist.\n'
    else
      printf '  the directory exists but has no operators.md, so it is not a fleet.\n'
    fi
    printf '\nPick one:\n'
    printf '  solo / trying it out   FM_FLEET_DIR=~/.firstmate-fleet bin/fm-fleet.sh init\n'
    printf '  shared, multi-operator sudo bash scripts/fleet-root-prereq.sh   # then: bin/fm-fleet.sh init\n'
    printf '  already have one       export FM_FLEET_DIR=/path/to/fleet   (or write it to %s/config/fleet-dir)\n' "${FM_HOME:-\$FM_HOME}"
    printf '\nSee docs/fleet-quickstart.md.\n'
  } >&2
  return 1
}

# Refuse to silently attach to a fleet the operator never chose.
#
# The built-in default is a shared, conventional path. On a multi-tenant host it may
# already be a DIFFERENT team's fleet, and those dirs are group-writable/world-readable
# by design — so a bare clone that configured nothing could read another team's
# operator table and event log without ever asking. Membership is the opt-in signal:
# if you are already an operator in that fleet it is yours, otherwise say so
# explicitly. Only applies when the dir came from the built-in default; an operator
# who set FM_FLEET_DIR or config/fleet-dir has already chosen.
fm_fleet_assert_owned() { # dir
  local dir=$1 me
  [ "$(fm_fleet_dir_source)" = default ] || return 0
  [ -z "${FM_FLEET_ACCEPT_DEFAULT:-}" ] || return 0
  me=$(id -un)
  grep -qE "^\| *${me} *\|" "$dir/operators.md" 2>/dev/null && return 0

  {
    printf 'fm-fleet: %s is an existing fleet, but you are not one of its operators\n' "$dir"
    printf '  and you have not chosen this fleet — it is only the built-in default.\n\n'
    printf '  On a shared host that path may belong to another team. Refusing to read it.\n\n'
    printf 'If it IS yours:\n'
    printf '  bin/fm-fleet-join.sh %s <scopes-csv>     # become an operator\n' "$me"
    printf '  export FM_FLEET_ACCEPT_DEFAULT=1          # or just acknowledge the default\n\n'
    printf 'If it is NOT yours, choose your own:\n'
    printf '  FM_FLEET_DIR=~/.firstmate-fleet bin/fm-fleet.sh init\n\n'
    printf 'See docs/fleet-quickstart.md.\n'
  } >&2
  return 1
}

# The one guard every entry point that CONSUMES an existing fleet must pass:
# initialized AND chosen/owned. fm-fleet.sh, fm-fleet-wait.sh, and any future
# reader call this right after resolving the dir, so no entry point can reach a
# fleet the operator never set up or never opted into.
fm_fleet_assert_usable() { # dir
  fm_fleet_assert_initialized "$1" && fm_fleet_assert_owned "$1"
}

# Refuse any fleet dir that resolves into ANOTHER operator's home. Own home (dev
# test dir) and /opt/... shared dirs are allowed.
fm_fleet_assert_shared() {
  local dir rp owner me; dir=$1
  rp=$(realpath -m "$dir")
  me=$(id -un)
  case "$rp" in
    /home/*)
      owner=${rp#/home/}; owner=${owner%%/*}
      if [ "$owner" != "$me" ]; then
        echo "fm-fleet: refusing to touch another operator's home: $rp" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

fm_fleet_event() { # dir operator event id detail
  local dir=$1 op=$2 ev=$3 id=$4 detail=${5:-}
  printf '%s\t%s\t%s\t%s\t%s\n' "$(fm_fleet_now)" "$op" "$ev" "$id" "$detail" >> "$dir/events.log"
}

fm_fleet_commit() { # dir message
  local dir=$1 msg=$2
  git -C "$dir" add -A >/dev/null 2>&1 || return 0
  git -C "$dir" commit -q -m "$msg" >/dev/null 2>&1 || true
}

fm_fleet_init() {
  local dir=$1
  fm_fleet_assert_shared "$dir" || return 1
  mkdir -p "$dir/locks"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || git -C "$dir" init -q
  [ -f "$dir/operators.md" ] || printf '# Fleet operators\n\n| operator | scope | home | accounts | status | seen | quota |\n|---|---|---|---|---|---|---|\n' > "$dir/operators.md"
  [ -f "$dir/projects.md" ]  || printf '# Fleet projects\n\n| project | owner | path |\n|---|---|---|\n' > "$dir/projects.md"
  [ -f "$dir/backlog.md" ]   || printf '# Fleet backlog\n\n## Queued\n\n## Claimed\n\n## In-flight\n\n## Done\n' > "$dir/backlog.md"
  [ -f "$dir/events.log" ]   || : > "$dir/events.log"
  fm_fleet_commit "$dir" "fleet: init"
}

# --- backlog mutation (all under flock) ---------------------------------------

# Open fd 9 on the backlog lock and block until held. Caller runs fm_fleet_unlock
# when done. Returns non-zero if the dir is unsafe.
fm_fleet_lock() { # dir
  local dir=$1
  fm_fleet_assert_shared "$dir" || return 1
  mkdir -p "$dir/locks"
  exec 9>"$dir/locks/backlog.lock" || return 1
  flock 9
}
fm_fleet_unlock() { flock -u 9 2>/dev/null || true; }

fm_fleet_queue() { # dir id scope desc
  local dir=$1 id=$2 scope=$3 desc=$4
  fm_fleet_lock "$dir" || return 1
  awk -v line="- [id:$id] scope:$scope | $desc | status:queued" '
    { print }
    /^## Queued$/ { print ""; print line }
  ' "$dir/backlog.md" > "$dir/backlog.md.tmp" && mv "$dir/backlog.md.tmp" "$dir/backlog.md"
  fm_fleet_event "$dir" "-" queue "$id" "scope:$scope"
  fm_fleet_commit "$dir" "fleet: queue $id"
  fm_fleet_unlock
}

# Move a queued item to Claimed, stamp claimed-by + status:claimed. Returns 0 on
# win, 1 if the item is not currently queued (already claimed / absent).
fm_fleet_claim() { # dir id operator
  local dir=$1 id=$2 op=$3 ts rc=1
  ts=$(fm_fleet_now)
  fm_fleet_lock "$dir" || return 1
  if grep -q "\[id:$id\].*status:queued" "$dir/backlog.md"; then
    awk -v id="$id" -v op="$op" -v ts="$ts" '
      $0 ~ ("\\[id:" id "\\].*status:queued") {
        sub(/status:queued/, "claimed-by:" op "@" ts " status:claimed"); held=$0; next
      }
      /^## Claimed$/ { print; if (held != "") { print ""; print held; held="" } ; next }
      { print }
    ' "$dir/backlog.md" > "$dir/backlog.md.tmp" && mv "$dir/backlog.md.tmp" "$dir/backlog.md"
    fm_fleet_event "$dir" "$op" claim "$id" ""
    fm_fleet_commit "$dir" "fleet: claim $id by $op"
    rc=0
  fi
  fm_fleet_unlock
  return $rc
}

# Reassign an item to another operator (handoff): stamp claimed-by:<to>, keep it
# in Claimed. Returns 0 if the item exists.
fm_fleet_handoff() { # dir id to_operator
  local dir=$1 id=$2 to=$3 ts rc=1
  ts=$(fm_fleet_now)
  fm_fleet_lock "$dir" || return 1
  if grep -q "\[id:$id\]" "$dir/backlog.md"; then
    awk -v id="$id" -v to="$to" -v ts="$ts" '
      $0 ~ ("\\[id:" id "\\]") {
        if ($0 ~ /claimed-by:[^ ]+/) sub(/claimed-by:[^ ]+/, "claimed-by:" to "@" ts)
        else sub(/status:/, "claimed-by:" to "@" ts " status:")
        print; next
      }
      { print }
    ' "$dir/backlog.md" > "$dir/backlog.md.tmp" && mv "$dir/backlog.md.tmp" "$dir/backlog.md"
    fm_fleet_event "$dir" "$to" handoff "$id" "assigned"
    fm_fleet_commit "$dir" "fleet: handoff $id to $to"
    rc=0
  fi
  fm_fleet_unlock
  return $rc
}

# Requeue stale claims: items still status:claimed whose claimed-by:@<ts> is older
# than ttl seconds go back to Queued (never-started work from an offline operator).
# status:in-flight items are left alone.
fm_fleet_reap() { # dir ttl_seconds
  local dir=$1 ttl=${2:-86400} now
  now=$(date -u +%s)
  fm_fleet_lock "$dir" || return 1
  # Buffered two-pass: collect stale claimed lines (removing them in place),
  # then re-emit and insert the requeued copies under ## Queued.
  awk -v ttl="$ttl" -v now="$now" '
    function epoch(iso,   c,e) { c="date -u -d \"" iso "\" +%s 2>/dev/null"; c|getline e; close(c); return e }
    { lines[NR]=$0
      if ($0 ~ /status:claimed/ && $0 ~ /claimed-by:[^@]+@[0-9TZ:-]+/) {
        match($0, /@[0-9TZ:-]+/); iso=substr($0, RSTART+1, RLENGTH-1)
        if (now - epoch(iso) > ttl) {
          remove[NR]=1
          r=$0; gsub(/claimed-by:[^ ]+ /, "", r); sub(/status:claimed/, "status:queued", r)
          rn++; req[rn]=r
        }
      }
    }
    END {
      for (i=1;i<=NR;i++) {
        if (i in remove) continue
        print lines[i]
        if (lines[i]=="## Queued") for (j=1;j<=rn;j++) { print ""; print req[j] }
      }
    }
  ' "$dir/backlog.md" > "$dir/backlog.md.tmp" && mv "$dir/backlog.md.tmp" "$dir/backlog.md"
  fm_fleet_event "$dir" "-" reap "-" "ttl=$ttl"
  fm_fleet_commit "$dir" "fleet: reap stale claims (ttl=$ttl)"
  fm_fleet_unlock
}

# --- routing ------------------------------------------------------------------

# Echo the operator who should own a task of the given scope.
# scope-primary: the online operator whose scope column contains the scope.
# overflow: if none online, the operator whose scope contains "overflow".
# Echo the operator who should own a task of the given scope.
# An operator is ELIGIBLE only when all three hold:
#   status:online AND heartbeat fresh (seen within FM_FLEET_HEARTBEAT_TTL, default 90s)
#   AND published quota headroom >= FM_FLEET_QUOTA_MIN (default 5), unless quota is '-'.
# Freshness + quota are self-healing: a crashed firstmate stops heartbeating and a
# low-headroom operator publishes it, so routing skips both without cross-user auth.
# 5-column legacy rows (no seen/quota) skip the freshness/quota checks (back-compat).
# scope-primary first; else the overflow operator. One awk pass over operators.md.
fm_fleet_route() { # dir scope
  local dir=$1 scope=$2 now ttl floor
  now=$(date -u +%s); ttl=${FM_FLEET_HEARTBEAT_TTL:-90}; floor=${FM_FLEET_QUOTA_MIN:-5}
  awk -F'|' -v s="$scope" -v now="$now" -v ttl="$ttl" -v floor="$floor" '
    function trim(x){ gsub(/^ +| +$/,"",x); return x }
    function epoch(iso,   c,e){ if(iso==""||iso=="-")return -1; c="date -u -d \"" iso "\" +%s 2>/dev/null"; c|getline e; close(c); return e+0 }
    function eligible(st,seen,q,   ep){
      if(st!="online") return 0
      ep=epoch(seen); if(ep>0 && (now-ep)>ttl) return 0
      if(q!="" && q!="-" && (q+0)<floor) return 0
      return 1
    }
    /^\| *[a-zA-Z0-9_.-]+ *\|/ {
      op=trim($2); sc=$3; gsub(/ /,"",sc); st=trim($6); seen=trim($7); q=trim($8)
      if(op=="operator") next
      if(!eligible(st,seen,q)) next
      if(owner=="" && (","sc",") ~ (","s",")) owner=op
      if(ov=="" && (","sc",") ~ /,overflow,/) ov=op
    }
    END{ print (owner!=""?owner:ov) }
  ' "$dir/operators.md"
}

# --- visibility ---------------------------------------------------------------

fm_fleet_view() { # dir [--follow]
  local dir=$1 follow=${2:-}
  if [ "$follow" = "--follow" ]; then
    tail -f "$dir/events.log"
  else
    awk -F'\t' '{ printf "%-20s %-10s %-8s %-8s %s\n", $1, $2, $3, $4, $5 }' "$dir/events.log"
  fi
}

fm_fleet_status() { # dir
  local dir=$1 op c inflt last
  echo "operator            claimed  in-flight  last-event"
  while IFS= read -r op; do
    [ -n "$op" ] || continue
    c=$(grep -c "claimed-by:$op@.*status:claimed" "$dir/backlog.md" 2>/dev/null || true)
    inflt=$(grep -c "claimed-by:$op@.*status:in-flight" "$dir/backlog.md" 2>/dev/null || true)
    last=$(awk -F'\t' -v o="$op" '$2==o{t=$1} END{print t}' "$dir/events.log" 2>/dev/null)
    printf "%-20s %-8s %-10s %s\n" "$op" "${c:-0}" "${inflt:-0}" "${last:--}"
  done < <(awk -F'|' '/^\| *[a-zA-Z0-9_.-]+ *\|/{op=$2; gsub(/^ +| +$/,"",op); if(op!="operator" && op !~ /^-+$/) print op}' "$dir/operators.md")
}

# --- operator lifecycle + token economy (each user runs these AS THEMSELVES) ---
# operators.md row: | op | scope | home | accounts | status | seen(iso) | quota(%|-) |
# seen + quota are self-published by that operator's own heartbeat, so routing can
# treat a crashed (stale) or low-headroom peer as unavailable WITHOUT reading that
# peer's home or auth. The recorded home is validated under the caller's own $HOME.

# Min headroom % across providers via quota-axi (current shell's auth); '-' if
# unavailable. Bash-only, zero LLM tokens.
fm_fleet_quota_now() {
  command -v quota-axi >/dev/null 2>&1 || { printf '%s' '-'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '%s' '-'; return 0; }
  local j min
  j=$(quota-axi --json 2>/dev/null) || { printf '%s' '-'; return 0; }
  min=$(printf '%s' "$j" | jq -r '[.providers[]?.windows[]?.percentRemaining] | min // "-"' 2>/dev/null)
  case "$min" in ''|null) printf '%s' '-' ;; *) printf '%s' "$min" ;; esac
}

# Human-readable per-surface headroom for EVERY llm/cli/app quota-axi knows about,
# with each surface's observability status. Read-only, bash+jq, 0 LLM tokens.
# Rationale: each CLI/app subscription is its OWN token pool, so a model reachable via
# more than one surface (e.g. grok via the grok CLI AND via a Cursor subscription) has
# one row per surface. A surface only contributes to routing when status is "fresh";
# "auth_required"/"unavailable"/"error" surfaces are shown but flagged un-observable.
fm_fleet_quota_report() {
  command -v quota-axi >/dev/null 2>&1 || {
    { echo "fm-fleet: quota-axi is not on PATH — per-surface headroom is unavailable."
      echo "  quota-axi reports how much budget each provider has left; the fleet uses it to"
      echo "  route work away from drained accounts. Install it, or skip quota-aware routing."
      echo "  Everything else (queue/claim/route/handoff) works without it."
    } >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || { echo "jq not installed" >&2; return 1; }
  local j; j=$(quota-axi --json 2>/dev/null) || {
    { echo "fm-fleet: quota-axi ran but returned no usable data."
      echo "  Most often this means no provider is signed in yet in THIS shell's environment."
      echo "  Check with:  quota-axi auth      (shows each provider's credential source/status)"
    } >&2
    return 1
  }
  local base="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  # Collect custom-source rows once. A source is authoritative for its surface and
  # SUPERSEDES the quota-axi row of the same name (e.g. an authed `cursor` override
  # replaces quota-axi's blind cursor row; `cline` is added since quota-axi lacks it).
  local -a SRC=(); local f s
  for f in "$base"/bin/quota-sources/*.sh; do
    [ -f "$f" ] || continue; s=$(bash "$f" 2>/dev/null) || continue
    [ -n "$s" ] && SRC+=("$s")
  done
  local ex_json='[]'
  if [ "${#SRC[@]}" -gt 0 ]; then
    ex_json=$(printf '%s\n' "${SRC[@]}" | jq -r '.surface // empty' 2>/dev/null | jq -R . | jq -s . 2>/dev/null)
    [ -n "$ex_json" ] || ex_json='[]'
  fi
  # Pace facts per NATIVE provider (§5.1), independent of custom-source
  # supersession above, so an excluded native row's pace still drives the
  # "masks native pace" advisory below even though it never itself prints.
  declare -A PACE_OF RESERVE_OF
  local psurf ppace preserve
  while IFS=$'\t' read -r psurf _ _ ppace preserve; do
    [ -n "$psurf" ] || continue
    PACE_OF[$psurf]=$ppace
    RESERVE_OF[$psurf]=$preserve
  done < <(fm_fleet_pace_rows "$j")
  {
    printf 'SURFACE\tHEADROOM\tPACE\tRESERVE\tSTATUS\tSOURCE\tNOTE\n'
    printf '%s\n' "$j" | jq -r --argjson ex "$ex_json" '
      .providers[] | select((.provider as $p | $ex | index($p)) | not)
      | ((.quotaSemantics.effectiveAvailability // []
           | map(select(.scope=="all_models").effectivePercentRemaining) | .[0])
         // (.windows // [] | map(.percentRemaining) | min)) as $rem
      | [ .provider,
          (if $rem==null then "—" else ($rem|tostring)+"%" end),
          (.state.status // "?"), (.source // "?"),
          (if (.state.status // "")=="fresh" then "observable"
           else (.state.error // "not reporting") end)
        ] | @tsv' \
    | while IFS=$'\t' read -r nsurf nhr nst nsrc nnote; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$nsurf" "$nhr" "${PACE_OF[$nsurf]:-—}" "$(fm_fleet_render_reserve "${RESERVE_OF[$nsurf]:-}")" \
          "$nst" "$nsrc" "$nnote"
      done
    local row surf note
    for row in "${SRC[@]:-}"; do
      [ -n "$row" ] || continue
      surf=$(printf '%s' "$row" | jq -r '.surface // empty')
      note=$(printf '%s' "$row" | jq -r '.note // ""')
      # A bare-int custom source masking a paced native row is an advisory (R7),
      # ahead of the T10-gated retirement that can remove the custom source.
      if [ -n "${PACE_OF[$surf]:-}" ]; then
        note="${note:+$note; }custom int masks native pace"
      fi
      printf '%s\n' "$row" | jq -r --arg note "$note" '
        [ .surface,
          (if .headroom==null then "—" else (.headroom|tostring)+"%" end),
          "—", "—",
          (.status // "?"), "custom", $note ] | @tsv'
    done
  } | if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
}

# Resolve the model->surfaces map: the operator's gitignored config/model-surfaces.json
# when one exists, else the tracked default shipped at docs/examples/model-surfaces.json
# (config/ must hold no tracked files — repo invariant), so a bare clone still routes.
fm_fleet_model_map() { # base
  local m="$1/config/model-surfaces.json"
  [ -f "$m" ] || m="$1/docs/examples/model-surfaces.json"
  printf '%s\n' "$m"
}

# model family -> surfaces (quota pools) with each surface's live status + headroom.
# Answers "for model X, which pools can serve it and which have tokens?" — the basis
# for grok/kimi failover across surfaces. Reads fm_fleet_model_map. 0 LLM tokens.
fm_fleet_models_report() {
  command -v jq >/dev/null 2>&1 || { echo "jq not installed" >&2; return 1; }
  local base="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local map; map=$(fm_fleet_model_map "$base")
  [ -f "$map" ] || { echo "no model map at $map" >&2; return 1; }
  local j; j=$(quota-axi --json 2>/dev/null || echo '{"providers":[]}')
  declare -A ST HR
  local p st hr
  while IFS=$'\t' read -r p st hr; do ST[$p]=$st; HR[$p]=$hr; done < <(
    printf '%s\n' "$j" | jq -r '.providers[]
      | ((.quotaSemantics.effectiveAvailability // [] | map(select(.scope=="all_models").effectivePercentRemaining) | .[0])
         // (.windows//[]|map(.percentRemaining)|min)) as $r
      | [.provider, (.state.status//"?"), (if $r==null then "—" else ($r|tostring)+"%" end)] | @tsv')
  local f s surf
  for f in "$base"/bin/quota-sources/*.sh; do
    [ -f "$f" ] || continue; s=$(bash "$f" 2>/dev/null) || continue
    surf=$(printf '%s' "$s" | jq -r '.surface // empty' 2>/dev/null); [ -n "$surf" ] || continue
    ST[$surf]=$(printf '%s' "$s" | jq -r '.status//"?"')
    HR[$surf]=$(printf '%s' "$s" | jq -r 'if .headroom==null then "—" else (.headroom|tostring)+"%" end')
  done
  {
    printf 'MODEL\tSURFACES (pool: status headroom)\n'
    local fam surfaces sfx out
    while IFS= read -r fam; do
      surfaces=$(jq -r --arg k "$fam" '.[$k][]?' "$map")
      out=""
      while IFS= read -r sfx; do
        [ -n "$sfx" ] || continue
        out+="${out:+  |  }${sfx}: ${ST[$sfx]:-unconfigured} ${HR[$sfx]:-—}"
      done <<< "$surfaces"
      printf '%s\t%s\n' "$fam" "$out"
    done < <(jq -r 'keys_unsorted[] | select(startswith("_")|not)' "$map")
  } | if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
}

# Failover selector: pick the best surface (quota pool) to serve a model family.
# OPERATOR-FACING DIAGNOSTIC ONLY — answers "which pool has tokens for grok right
# now" for a human running `fm-fleet.sh pick`. NEVER called from `fm-spawn`, crew
# dispatch, or any automated path (anti-goal §4.1) — dispatch's pace-aware
# selection belongs solely to upstream's `quota-array-dispatch` skill. Selects
# among surfaces of ONE model family only (map is keyed by family); must never
# become a cross-family selector — that needs the reasoning-class judgment
# `quota-array-dispatch` owns (R4).
#
#   pass 1: among surfaces with OBSERVABLE headroom >= FM_FLEET_QUOTA_MIN (raw
#           floor, unchanged, still dominant), prefer by pace (§5.5):
#     1a known sustainable (behind/on_pace/mixed-with-no-remaining-ahead-window,
#        i.e. NOT pressured per §5.2) -> first in map order
#     1b unknown pace, or pace absent (v2, custom source, no v3 pace fields)
#        -> first in map order
#     1c pressured (ahead; mixed with a remaining aheadWindowId; or a bounding
#        window itself ahead) -> least-negative worst reserve; ties -> map order
#   pass 2: else first surface configured/online but unobservable (fail-open)
#   pass 3: else the first listed surface (last resort)
# Map order is a documented OPERATOR preference (map's own _comment: "routing/
# failover walks the list left-to-right"), distinct from the array-order bias
# quota-array-dispatch forbids for dispatch ties (that rule targets an
# unordered config array; this map is explicitly ordered).
# R1: only FRESH surfaces' pace is trusted for 1a/1b/1c; a stale surface's pace
# is treated as unavailable (falls to 1b) though its raw headroom (pass 1) and
# `quota` display (T6) are unaffected.
# Echoes the surface name; non-zero (with message) if the family is unknown.
fm_fleet_pick_surface() { # model-family
  command -v jq >/dev/null 2>&1 || return 2
  local fam=$1 base map floor=${FM_FLEET_QUOTA_MIN:-5}
  base="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  map=$(fm_fleet_model_map "$base")
  [ -f "$map" ] || return 2
  local surfaces; surfaces=$(jq -r --arg k "$fam" '.[$k][]?' "$map")
  [ -n "$surfaces" ] || { echo "unknown model family: $fam" >&2; return 1; }
  local j; j=$(quota-axi --json 2>/dev/null || echo '{"providers":[]}')
  declare -A ST HR PACE_OF RESERVE_OF
  local p st hr
  while IFS=$'\t' read -r p st hr; do ST[$p]=$st; HR[$p]=$hr; done < <(
    printf '%s\n' "$j" | jq -r '.providers[]
      | ((.quotaSemantics.effectiveAvailability//[]|map(select(.scope=="all_models").effectivePercentRemaining)|.[0])
         //(.windows//[]|map(.percentRemaining)|min)) as $r
      | [.provider,(.state.status//"?"),(if $r==null then "" else ($r|tostring) end)] | @tsv')
  local psurf pstate ppace preserve
  while IFS=$'\t' read -r psurf pstate ppace preserve; do
    [ -n "$psurf" ] && [ "$pstate" = fresh ] || continue
    PACE_OF[$psurf]=$ppace; RESERVE_OF[$psurf]=$preserve
  done < <(fm_fleet_pace_rows "$j" | awk -F'\t' -v OFS='\t' '{print $1,$3,$4,$5}')
  local f s surf
  for f in "$base"/bin/quota-sources/*.sh; do
    [ -f "$f" ] || continue; s=$(bash "$f" 2>/dev/null) || continue
    surf=$(printf '%s' "$s" | jq -r '.surface//empty' 2>/dev/null); [ -n "$surf" ] || continue
    ST[$surf]=$(printf '%s' "$s" | jq -r '.status//"?"')
    HR[$surf]=$(printf '%s' "$s" | jq -r 'if .headroom==null then "" else (.headroom|tostring) end')
  done
  local sfx h pace reserve first_1a="" first_1b="" best_1c="" best_1c_reserve=""
  while IFS= read -r sfx; do [ -n "$sfx" ] || continue
    h=${HR[$sfx]:-}
    { [ -n "$h" ] && fm_fleet_num_ge "$h" "$floor"; } || continue
    pace=${PACE_OF[$sfx]:-}
    if [ -z "$pace" ] || [ "$pace" = unknown ]; then
      [ -n "$first_1b" ] || first_1b=$sfx
    elif fm_fleet_pressured "$(printf '%s' "$j" | jq -c --arg s "$sfx" '.providers[] | select(.provider==$s)')"; then
      reserve=${RESERVE_OF[$sfx]:-}
      if [ -z "$best_1c" ]; then
        best_1c=$sfx; best_1c_reserve=$reserve
      elif [ -n "$reserve" ] && [ -n "$best_1c_reserve" ] \
           && fm_fleet_reserve_cmp "$reserve" "$best_1c_reserve" \
           && [ "$reserve" != "$best_1c_reserve" ]; then
        best_1c=$sfx; best_1c_reserve=$reserve
      fi
    else
      [ -n "$first_1a" ] || first_1a=$sfx
    fi
  done <<< "$surfaces"
  [ -n "$first_1a" ] && { echo "$first_1a"; return 0; }
  [ -n "$first_1b" ] && { echo "$first_1b"; return 0; }
  [ -n "$best_1c" ] && { echo "$best_1c"; return 0; }
  while IFS= read -r sfx; do [ -n "$sfx" ] || continue
    case "${ST[$sfx]:-}" in fresh|configured|online|logged_in) echo "$sfx"; return 0;; esac
  done <<< "$surfaces"
  printf '%s\n' "$surfaces" | head -1
}

# Float-safe >= (headroom percentages can be fractional, e.g. 90.5, which the
# integer-only [ -ge ] test cannot parse).
fm_fleet_num_ge() { # a b
  awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0)>=(b+0))}'
}

# Float-safe signed >= (reserve is signed points, e.g. -18.0 — distinct from
# fm_fleet_num_ge's headroom-shaped callers so negatives are never a surprise).
fm_fleet_reserve_cmp() { # a b -> exit 0 if a >= b
  awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0)>=(b+0))}'
}

# --- quota-window pace (quota-axi >= 0.1.15, schemaVersion 3) -----------------
# See docs/fleet-addon.md "Per-surface pace" + .agents/skills/federation/SKILL.md.
# Dispatch's pace-aware selection is owned solely by upstream's
# `quota-array-dispatch` skill — these are read-only reporting primitives.

# One quota-axi snapshot -> one TSV row per provider: <surface>\t<headroom>\t
# <state>\t<pace>\t<reserve>. Resolution (PRD §5.1), reusing the SAME headroom
# precedence every other fleet quota reader uses:
#   headroom: effectiveAvailability[scope=all_models].effectivePercentRemaining,
#             else min(windows[].percentRemaining), else absent.
#   pace:     effectiveAvailability[...].pace.status when present (verbatim,
#             including "mixed" — never simplified to a binary flag); else
#             derived from windows[].pace.status ("ahead" if any ahead, else
#             "unknown" if any unknown, else "behind" if any behind, else
#             "on_pace"); else EMPTY (absent) — never fabricated as "on_pace".
#   reserve:  effectiveAvailability[...].pace.worstReservePercentPoints when
#             present (preferred), else min(windows[].pace.reservePercentPoints)
#             across windows that carry one, else absent.
# Absent renders as an EMPTY field; the caller shows "—". A literal "unknown"
# must never collapse into that same field (R3) — stated uncertainty vs. silence.
# Callers fetch quota-axi --json ONCE per command and pass the snapshot in; this
# function makes no subprocess call of its own.
fm_fleet_pace_rows() { # quota-axi-json-snapshot
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$1" | jq -r '
    def eff: (.quotaSemantics.effectiveAvailability // [])
              | map(select(.scope=="all_models")) | .[0];
    .providers[]? as $p
    | ($p | eff) as $eff
    | ($p.windows // []) as $windows
    | ( $eff.effectivePercentRemaining
        // ([$windows[]?.percentRemaining] | map(select(.!=null)) | if length>0 then min else null end)
      ) as $headroom
    | ( if $eff.pace.status != null then $eff.pace.status
        else
          ([$windows[]?.pace.status] | map(select(.!=null))) as $ws
          | if ($ws|length)==0 then null
            elif ($ws|any(.=="ahead")) then "ahead"
            elif ($ws|any(.=="unknown")) then "unknown"
            elif ($ws|any(.=="behind")) then "behind"
            else "on_pace" end
        end
      ) as $pace
    | ( if $eff.pace.worstReservePercentPoints != null then $eff.pace.worstReservePercentPoints
        else
          ([$windows[]?.pace.reservePercentPoints] | map(select(.!=null))) as $wr
          | if ($wr|length)==0 then null else (min) end
        end
      ) as $reserve
    | [ $p.provider, ($headroom // ""), ($p.state.status // ""), ($pace // ""), ($reserve // "") ] | @tsv
  ' 2>/dev/null
}

# Render a signed reserve: explicit "+"/"-", "—" when absent. Separate from
# fm_fleet_pace_rows (bare jq number) since that raw value is still compared
# numerically (fm_fleet_reserve_cmp) before ever being rendered.
fm_fleet_render_reserve() { # reserve
  local r=$1
  [ -n "$r" ] || { printf '%s' '—'; return 0; }
  case "$r" in
    -*) printf '%s' "$r" ;;
    *)  printf '+%s' "$r" ;;
  esac
}

# §5.2 conservation-pressure predicate, verbatim from quota-array-dispatch
# (fa0d85d) — do not simplify to `status == ahead`; that misclassifies `mixed`
# + remaining aheadWindowIds as healthy (R2), which the skill forbids.
#   pressured := status=="ahead" OR (status=="mixed" AND aheadWindowIds non-empty)
#                OR any applicable bounding window has status=="ahead"
# Absent pace ⇒ NOT pressured (merely unclassified; caller's own absent/unknown
# handling applies, R3). Exit 0 when pressured.
fm_fleet_pressured() { # single-provider-json
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$1" | jq -e '
    def eff: (.quotaSemantics.effectiveAvailability // [])
              | map(select(.scope=="all_models")) | .[0];
    (eff) as $eff
    | (($eff.pace.status // "") == "ahead")
      or ((($eff.pace.status // "") == "mixed") and ((($eff.pace.aheadWindowIds // []) | length) > 0))
      or ([(.windows // [])[]?.pace.status] | any(. == "ahead"))
  ' >/dev/null 2>&1
}

# FM_FLEET_RESERVE_MIN — worst tolerated signed reserve, in points, before
# conservation pressure alone holds back work. Default -25 below (resolved
# inline, like every other FM_FLEET_* knob — sourcing this lib never mutates
# the caller's env). -25 = "burned 25 points more than the window's elapsed
# share". Set to -100 to disable the pace floor and restore raw-headroom-only.

# fm-fleet.sh budget prints this after fm_fleet_budget_ok — inspectable facts,
# never a bare verdict. Function-local global since callers only check $?.
# shellcheck disable=SC2034 # Read by bin/fm-fleet.sh's `budget` verb, not this lib.
fm_fleet_budget_reason=""

# 0 if headroom is ok AND not held back by conservation pressure. Truth table
# (§5.4), raw floor DOMINANT:
#   headroom unmeasurable (-)                    -> ok   (fail-open, unchanged)
#   headroom < FM_FLEET_QUOTA_MIN                 -> below floor (unchanged)
#   headroom ok, not pressured                    -> ok
#   headroom ok, pressured, worst reserve >= MIN  -> ok
#   headroom ok, pressured, worst reserve < MIN   -> below pace floor (NEW)
#   headroom ok, pressured, reserve absent        -> ok (can't measure, fail-open)
# R1: only FRESH providers feed pressure/reserve — a stale window's reserve only
# ages toward looking MORE ahead as the clock runs, so it must never refuse
# (still VISIBLE via `quota`, T6). Degradation (G5): when NO provider anywhere
# carries a pace field, this reproduces today's exact static message/exit code.
#
# Callers audited 2026-07-28 (T7): bin/fm-fleet.sh's `budget` verb (prints
# $fm_fleet_budget_reason, same 0/1 exit convention); tests/federation/
# test_fleet_ops.sh (exit code only, v2-shaped stub -> legacy path); docs/
# fleet-token-economy.md + .agents/skills/federation/SKILL.md (prose, T9).
fm_fleet_budget_ok() {
  local floor=${FM_FLEET_QUOTA_MIN:-5} rmin=${FM_FLEET_RESERVE_MIN:--25}
  local reason rc

  if ! command -v quota-axi >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    reason="ok (min headroom >= ${floor}%)"; rc=0
  else
    local j; j=$(quota-axi --json 2>/dev/null)
    local q
    q=$(printf '%s' "${j:-}" | jq -r '[.providers[]?.windows[]?.percentRemaining] | min // "-"' 2>/dev/null)
    case "$q" in ''|null) q='-' ;; esac
    if [ "$q" = '-' ]; then
      reason="ok (min headroom >= ${floor}%)"; rc=0
    elif ! fm_fleet_num_ge "$q" "$floor"; then
      reason="below floor (< ${floor}%)"; rc=1
    else
      # Headroom clears the floor. Fold in pace, restricted to FRESH providers (R1).
      # Track the WORST (most negative / least sustainable) reserve among fresh,
      # KNOWN-class providers (never "unknown" — R3) as the single inspectable
      # pace fact to report, whether or not it happens to be the one that trips
      # `pressured`; `pressured` itself is a separate OR across every fresh
      # provider's §5.2 predicate, since a "mixed" summary can be pressured via
      # its aheadWindowIds even when its own reserve number isn't the worst one.
      local psurf pstate ppace preserve
      local pace_seen=0 pressured=0 have_worst=0 worst_reserve="" worst_pace=""
      while IFS=$'\t' read -r psurf pstate ppace preserve; do
        [ -n "$psurf" ] || continue
        [ -n "$ppace" ] && pace_seen=1
        [ "$pstate" = fresh ] || continue
        [ -n "$ppace" ] && [ "$ppace" != unknown ] || continue
        if fm_fleet_pressured "$(printf '%s' "$j" | jq -c --arg s "$psurf" '.providers[] | select(.provider==$s)')"; then
          pressured=1
        fi
        if [ -n "$preserve" ] && { [ "$have_worst" -eq 0 ] || ! fm_fleet_reserve_cmp "$preserve" "$worst_reserve"; }; then
          worst_reserve=$preserve; worst_pace=$ppace; have_worst=1
        elif [ "$have_worst" -eq 0 ]; then
          worst_pace=$ppace
        fi
      done < <(fm_fleet_pace_rows "$j" | awk -F'\t' -v OFS='\t' '{print $1,$3,$4,$5}')

      if [ "$pace_seen" -eq 0 ]; then
        # True v2/degraded: no provider anywhere carries a pace field. Reproduce
        # today's exact message — never invent pace, never claim on_pace (G5/R3).
        reason="ok (min headroom >= ${floor}%)"; rc=0
      elif [ "$pressured" -eq 0 ]; then
        if [ -n "$worst_pace" ]; then
          reason="ok (headroom ${q}% >= ${floor}%, pace ${worst_pace}, reserve $(fm_fleet_render_reserve "$worst_reserve"))"
        else
          reason="ok (headroom ${q}% >= ${floor}%, no conservation pressure)"
        fi
        rc=0
      elif [ -z "$worst_reserve" ]; then
        reason="ok (headroom ${q}% >= ${floor}%, pace pressured but reserve unmeasurable, fail-open)"; rc=0
      elif fm_fleet_reserve_cmp "$worst_reserve" "$rmin"; then
        reason="ok (headroom ${q}% >= ${floor}%, pace ${worst_pace}, reserve $(fm_fleet_render_reserve "$worst_reserve"))"; rc=0
      else
        reason="below pace floor (headroom ${q}% >= ${floor}% but pace ${worst_pace}, reserve $(fm_fleet_render_reserve "$worst_reserve") < ${rmin})"; rc=1
      fi
    fi
  fi

  # shellcheck disable=SC2034 # Read by bin/fm-fleet.sh's `budget` verb, not this lib.
  fm_fleet_budget_reason=$reason
  return "$rc"
}

# Refuse a recorded home outside the caller's own $HOME (cross-uid safety).
fm_fleet_assert_own_home() { # home
  local home=${1%/}
  case "$home" in
    "$HOME"|"$HOME"/*) return 0 ;;
    *) echo "error: refusing to register a home outside your own \$HOME ($HOME): $1" >&2; return 1 ;;
  esac
}

# Upsert this operator's row (self-onboard / update). Idempotent: an existing row for
# <op> is replaced, not duplicated. Stamps status:online, seen:now, quota:now.
fm_fleet_register() { # dir op scopes home [accounts]
  local dir=$1 op=$2 scopes=$3 home=$4 accounts=${5:-} ts q
  fm_fleet_assert_own_home "$home" || return 1
  ts=$(fm_fleet_now); q=$(fm_fleet_quota_now)
  fm_fleet_lock "$dir" || return 1
  grep -vE "^\| *$op *\|" "$dir/operators.md" > "$dir/operators.md.tmp" && mv "$dir/operators.md.tmp" "$dir/operators.md"
  printf '| %s | %s | %s | %s | online | %s | %s |\n' "$op" "$scopes" "$home" "$accounts" "$ts" "$q" >> "$dir/operators.md"
  fm_fleet_event "$dir" "$op" register "-" "scope:$scopes"
  fm_fleet_commit "$dir" "fleet: register $op"
  fm_fleet_unlock
}

# Refresh this operator's liveness: seen:now + quota:now + status:online. Bash-only,
# meant to run on a cheap timer/daemon (NOT the LLM) so being "online" costs 0 tokens.
fm_fleet_heartbeat() { # dir op
  local dir=$1 op=$2 ts q rc=1
  ts=$(fm_fleet_now); q=$(fm_fleet_quota_now)
  fm_fleet_lock "$dir" || return 1
  if grep -qE "^\| *$op *\|" "$dir/operators.md"; then
    awk -F'|' -v OFS='|' -v op="$op" -v ts=" $ts " -v q=" $q " '
      function trim(x){ gsub(/^ +| +$/,"",x); return x }
      trim($2)==op { $6=" online "; $7=ts; $8=q; NF=(NF<9?9:NF); print; next }
      { print }
    ' "$dir/operators.md" > "$dir/operators.md.tmp" && mv "$dir/operators.md.tmp" "$dir/operators.md"
    # No git commit / event line: heartbeat is transient liveness, not audit history.
    # Committing every beat would bloat the KB log and churn the lock. The seen
    # column IS the liveness record; on a same-machine shared FS the file write is
    # visible to every operator immediately.
    rc=0
  fi
  fm_fleet_unlock
  return $rc
}

# Mark this operator offline (clean shutdown). Routing skips it immediately.
fm_fleet_leave() { # dir op
  local dir=$1 op=$2 rc=1
  fm_fleet_lock "$dir" || return 1
  if grep -qE "^\| *$op *\|" "$dir/operators.md"; then
    awk -F'|' -v OFS='|' -v op="$op" '
      function trim(x){ gsub(/^ +| +$/,"",x); return x }
      trim($2)==op { $6=" offline "; print; next }
      { print }
    ' "$dir/operators.md" > "$dir/operators.md.tmp" && mv "$dir/operators.md.tmp" "$dir/operators.md"
    fm_fleet_event "$dir" "$op" leave "-" ""
    fm_fleet_commit "$dir" "fleet: leave $op"
    rc=0
  fi
  fm_fleet_unlock
  return $rc
}
