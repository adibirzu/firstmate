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

fm_fleet_dir() {
  local d="${FM_FLEET_DIR:-}"
  if [ -z "$d" ] && [ -n "${FM_HOME:-}" ] && [ -f "$FM_HOME/config/fleet-dir" ]; then
    d=$(head -n1 "$FM_HOME/config/fleet-dir")
  fi
  [ -n "$d" ] || d=/opt/agents/fleet
  printf '%s\n' "$d"
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
