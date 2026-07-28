#!/usr/bin/env bash
# fm-fleet-lib.sh — FirstMate federated multi-operator KB library.
#
# Cross-uid-safe coordination through a SHARED group-writable git-backed dir only.
# Operators never write each other's private homes; they share this KB and use
# flock advisory locks on the backlog for atomic, no-overlap claims.
#
# KB layout ($dir):
#   operators.md  md table: | operator | scope | home | accounts | status |
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
  {
    printf 'SURFACE\tHEADROOM\tSTATUS\tSOURCE\tNOTE\n'
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
        ] | @tsv'
    local row
    for row in "${SRC[@]:-}"; do
      [ -n "$row" ] || continue
      printf '%s\n' "$row" | jq -r '
        [ .surface,
          (if .headroom==null then "—" else (.headroom|tostring)+"%" end),
          (.status // "?"), "custom", (.note // "") ] | @tsv'
    done
  } | if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
}

# model family -> surfaces (quota pools) with each surface's live status + headroom.
# Answers "for model X, which pools can serve it and which have tokens?" — the basis
# for grok/kimi failover across surfaces. Reads config/model-surfaces.json. 0 LLM tokens.
fm_fleet_models_report() {
  command -v jq >/dev/null 2>&1 || { echo "jq not installed" >&2; return 1; }
  local base="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local map="$base/config/model-surfaces.json"
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
#   pass 1: first surface with OBSERVABLE headroom >= FM_FLEET_QUOTA_MIN (has tokens)
#   pass 2: else first surface configured/online but unobservable (fail-open target)
#   pass 3: else the first listed surface (last resort)
# Echoes the surface name; non-zero (with message) if the family is unknown. 0 tokens.
# This is the "grok from whichever pool has tokens / kimi3 via cline" decision.
fm_fleet_pick_surface() { # model-family
  command -v jq >/dev/null 2>&1 || return 2
  local fam=$1 base map floor=${FM_FLEET_QUOTA_MIN:-5}
  base="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  map="$base/config/model-surfaces.json"
  [ -f "$map" ] || return 2
  local surfaces; surfaces=$(jq -r --arg k "$fam" '.[$k][]?' "$map")
  [ -n "$surfaces" ] || { echo "unknown model family: $fam" >&2; return 1; }
  local j; j=$(quota-axi --json 2>/dev/null || echo '{"providers":[]}')
  declare -A ST HR
  local p st hr
  while IFS=$'\t' read -r p st hr; do ST[$p]=$st; HR[$p]=$hr; done < <(
    printf '%s\n' "$j" | jq -r '.providers[]
      | ((.quotaSemantics.effectiveAvailability//[]|map(select(.scope=="all_models").effectivePercentRemaining)|.[0])
         //(.windows//[]|map(.percentRemaining)|min)) as $r
      | [.provider,(.state.status//"?"),(if $r==null then "" else ($r|tostring) end)] | @tsv')
  local f s surf
  for f in "$base"/bin/quota-sources/*.sh; do
    [ -f "$f" ] || continue; s=$(bash "$f" 2>/dev/null) || continue
    surf=$(printf '%s' "$s" | jq -r '.surface//empty' 2>/dev/null); [ -n "$surf" ] || continue
    ST[$surf]=$(printf '%s' "$s" | jq -r '.status//"?"')
    HR[$surf]=$(printf '%s' "$s" | jq -r 'if .headroom==null then "" else (.headroom|tostring) end')
  done
  local sfx h
  while IFS= read -r sfx; do [ -n "$sfx" ] || continue
    h=${HR[$sfx]:-}
    if [ -n "$h" ] && [ "$h" -ge "$floor" ] 2>/dev/null; then echo "$sfx"; return 0; fi
  done <<< "$surfaces"
  while IFS= read -r sfx; do [ -n "$sfx" ] || continue
    case "${ST[$sfx]:-}" in fresh|configured|online|logged_in) echo "$sfx"; return 0;; esac
  done <<< "$surfaces"
  printf '%s\n' "$surfaces" | head -1
}

# 0 if this operator has enough headroom to take work (min% >= FM_FLEET_QUOTA_MIN,
# default 5). Fail-OPEN when quota is unmeasurable ('-') so a missing quota-axi never
# blocks work; the guard only holds back a MEASURABLY-drained account.
fm_fleet_budget_ok() {
  local floor=${FM_FLEET_QUOTA_MIN:-5} q
  q=$(fm_fleet_quota_now)
  [ "$q" = '-' ] && return 0
  [ "$q" -ge "$floor" ] 2>/dev/null
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
