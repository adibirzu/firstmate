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
  [ -f "$dir/operators.md" ] || printf '# Fleet operators\n\n| operator | scope | home | accounts | status |\n|---|---|---|---|---|\n' > "$dir/operators.md"
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
fm_fleet_route() { # dir scope
  local dir=$1 scope=$2 owner overflow
  owner=$(awk -F'|' -v s="$scope" '
    /^\| *[a-zA-Z0-9_.-]+ *\|/ {
      op=$2; gsub(/^ +| +$/,"",op)
      sc=$3; gsub(/ /,"",sc)
      st=$6; gsub(/ /,"",st)
      if (op=="operator") next
      if (st=="online" && (","sc",") ~ (","s",")) { print op; exit }
    }' "$dir/operators.md")
  if [ -n "$owner" ]; then printf '%s\n' "$owner"; return 0; fi
  overflow=$(awk -F'|' '
    /^\| *[a-zA-Z0-9_.-]+ *\|/ {
      op=$2; gsub(/^ +| +$/,"",op)
      sc=$3; gsub(/ /,"",sc)
      st=$6; gsub(/ /,"",st)
      if (op=="operator") next
      if (st=="online" && (","sc",") ~ /,overflow,/) { print op; exit }
    }' "$dir/operators.md")
  printf '%s\n' "$overflow"
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
