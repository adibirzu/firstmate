#!/usr/bin/env bash
# fm-fleet-pulse.sh - publish the consolidated fleet view as Pulse page data.
#
# Builds one self-contained page payload from the two stable structured
# contracts this repo already owns - fm-fleet-snapshot.v1 (fresh remote
# convergence and self-describing invalid states, per the task-1 fix) and
# fm-fleet-herdr.v1 (every Herdr session/agent on every host, managed and
# unmanaged) - and writes it where the captain can open it. It invents no
# second data-collection path: the snapshot and the Herdr collector stay the
# only readers, and this command only merges and renders.
#
# Output: <dest>/fleet.json (the merged payload) and <dest>/fleet.html (a
# self-contained page with the payload inlined, grouped by station with
# in-flight work first, plus the Jev shadow summary). The page tries to
# re-fetch fleet.json every 60 seconds and falls back to a meta refresh, so a
# viewer left open tracks the heartbeat cadence without a manual re-run; the
# publisher itself is re-run on that same cadence (see below), which is what
# keeps the files fresh.
#
# Destinations: the home's state/fleet-pulse/ directory always, plus the local
# Pulse dashboard static directory (default
# ~/.claude/LIFEOS/PULSE/Observability/out, where Pulse's observability module
# serves fleet.html with no rebuild and no-cache headers) unless
# FM_FLEET_PULSE_PUBLISH=0. The dashboard copy is generated content only; it
# installs no code into Pulse and needs no Pulse restart. Every supervising
# home publishes the same dashboard filenames, so the freshest heartbeat wins;
# each copy is self-describing (generated stamp and home inside).
#
# Refresh wiring: `publish --best-effort` is the silent automatic-trigger form
# for the supervision heartbeat (bin/fm-watch.sh) and the successful
# task-completion path (bin/fm-teardown.sh), next to the existing live-view
# refresh calls. It never prints, never fails, and never opens anything.
#
# Lane column: local tasks render "routed" when their meta carries provider= or
# account= (dispatched under a provider account through the router) and
# "subscription" otherwise; remote children and anything without that evidence
# render "unknown" rather than a guess.
#
# Usage:
#   fm-fleet-pulse.sh publish [--best-effort] [--out <dir>] [--timeout <seconds>]
#   fm-fleet-pulse.sh --help
#
# Environment:
#   FM_HOME                    operational home
#   FM_FLEET_PULSE_PUBLISH     1 (default) writes the dashboard copy, 0 skips it
#   FM_FLEET_PULSE_DASHBOARD_DIR
#                              dashboard static dir override
#   FM_FLEET_SNAPSHOT_BIN      snapshot override (tests point at fixtures)
#   FM_FLEET_HERDR_BIN         collector override (tests point at fixtures)
#   FM_FLEET_PULSE_HERDR_TIMEOUT
#                              bound for the collector fan-out (default 90)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SNAPSHOT_BIN="${FM_FLEET_SNAPSHOT_BIN:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
HERDR_BIN_COLLECT="${FM_FLEET_HERDR_BIN:-$SCRIPT_DIR/fm-fleet-herdr-collect.sh}"
HERDR_TIMEOUT=${FM_FLEET_PULSE_HERDR_TIMEOUT:-90}
case "$HERDR_TIMEOUT" in ''|*[!0-9]*|0) HERDR_TIMEOUT=90 ;; esac
PUBLISH_DASHBOARD=${FM_FLEET_PULSE_PUBLISH:-1}
DASHBOARD_DIR=${FM_FLEET_PULSE_DASHBOARD_DIR:-$HOME/.claude/LIFEOS/PULSE/Observability/out}

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-pulse.sh publish [--best-effort] [--out <dir>] [--timeout <seconds>]

Merge fm-fleet-snapshot.v1 and fm-fleet-herdr.v1 into fleet.json plus a
self-contained fleet.html, written to state/fleet-pulse/ and (unless
FM_FLEET_PULSE_PUBLISH=0) the local Pulse dashboard static directory.
publish --best-effort is the silent heartbeat/teardown form: it never prints
and never returns non-zero.
EOF
}

BEST_EFFORT=0
OUT_ARG=
CMD=${1:-}
case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  publish) shift ;;
  *) usage >&2; exit 2 ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --best-effort) BEST_EFFORT=1; shift ;;
    --out)
      [ "$#" -ge 2 ] || { echo "fm-fleet-pulse: --out requires a value" >&2; exit 2; }
      OUT_ARG=$2; shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { echo "fm-fleet-pulse: --timeout requires a value" >&2; exit 2; }
      HERDR_TIMEOUT=$2
      case "$HERDR_TIMEOUT" in ''|*[!0-9]*|0) echo "fm-fleet-pulse: invalid --timeout '$2'" >&2; exit 2 ;; esac
      shift 2
      ;;
    *) echo "fm-fleet-pulse: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  [ "$BEST_EFFORT" -eq 1 ] || echo "fm-fleet-pulse: jq not found" >&2
  if [ "$BEST_EFFORT" -eq 1 ]; then exit 0; else exit 1; fi
}

pulse_fail() {  # <message>
  if [ "$BEST_EFFORT" -eq 1 ]; then exit 0; fi
  echo "fm-fleet-pulse: $1" >&2
  exit 1
}

SNAPSHOT=$(fm_run_timed 300 "$SNAPSHOT_BIN" --json 2>/dev/null) || SNAPSHOT=''
[ -n "$SNAPSHOT" ] || pulse_fail "fleet snapshot failed"
printf '%s' "$SNAPSHOT" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null 2>&1 \
  || pulse_fail "fleet snapshot returned an unexpected schema"

# The Herdr collector degrades, never fails the page: an unreachable station
# becomes an ok:false host record inside its own contract, and a total
# collector failure still leaves the managed fleet renderable.
HERDR=$(fm_run_timed "$HERDR_TIMEOUT" "$HERDR_BIN_COLLECT" --json 2>/dev/null) || HERDR=''
if [ -z "$HERDR" ] || ! printf '%s' "$HERDR" | jq -e '.schema == "fm-fleet-herdr.v1"' >/dev/null 2>&1; then
  HERDR='{"schema":"fm-fleet-herdr.v1","generated":null,"host":"local","hosts":[],"error":"herdr collection unavailable"}'
fi

# Lane evidence from local task metas: provider= or account= means the task
# was dispatched under a provider account through the router.
LANES=$(for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  case "$id" in ''|.*) continue ;; esac
  if grep -Eq '^(provider|account)=' "$meta" 2>/dev/null; then lane=routed; else lane=subscription; fi
  printf '%s\t%s\n' "$id" "$lane"
done | jq -R -s '
  [ split("\n")[] | select(test("\t")) | split("\t") | {(.[0]): .[1]} ] | add // {}')

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MERGED=$(jq -n \
  --arg generated "$NOW" \
  --argjson snapshot "$SNAPSHOT" \
  --argjson herdr "$HERDR" \
  --argjson lanes "$LANES" \
  '{schema:"fm-fleet-pulse.v1",generated:$generated,snapshot:$snapshot,herdr:$herdr,lanes:$lanes}') \
  || pulse_fail "payload merge failed"

# Inline the payload inside a script tag: escape "</" so a task title can
# never break out of the tag.
INLINED=$(printf '%s' "$MERGED" | jq -c '.' | sed 's|</|<\\/|g') || pulse_fail "payload compact failed"

pulse_head() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="120">
<title>Fleet - every worker on every station</title>
<style>
body{font-family:-apple-system,system-ui,sans-serif;margin:0;padding:16px 20px;background:#0e1116;color:#d7dce2}
h1{font-size:20px;margin:0 0 4px}.sub{color:#8b93a1;font-size:12px;margin-bottom:16px}
h2{font-size:15px;margin:22px 0 8px;color:#fff}.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;margin-left:8px}
.ok{background:#123f22;color:#7ee2a8}.warn{background:#4a2f10;color:#f5b96b}.bad{background:#4d1717;color:#f28b8b}
table{border-collapse:collapse;width:100%;font-size:12px;margin-bottom:6px}
th,td{border:1px solid #26303d;padding:5px 8px;text-align:left;vertical-align:top}
th{background:#161c25;color:#9aa4b2}td.mono,th.mono{font-family:ui-monospace,monospace;font-size:11px}
a{color:#6cb8f0}.note{color:#8b93a1;font-size:11px}.jev{background:#141b25;border:1px solid #26303d;border-radius:8px;padding:10px 12px;font-size:12px;margin-bottom:8px}
.station{margin-top:18px;border-top:2px solid #26303d;padding-top:6px}
</style>
</head>
<body>
<h1>Fleet - every worker on every station <span class="pill ok" id="fresh">heartbeat-fed</span></h1>
<div class="sub" id="meta">loading…</div>
<div class="jev" id="jev"></div>
<div id="fleet"></div>
<script id="fleet-data" type="application/json">
HTML
}

pulse_tail() {
  cat <<'HTML'
</script>
<script>
(function(){
var el=function(t,c,h){var e=document.createElement(t);if(c)e.className=c;if(h!=null)e.innerHTML=h;return e;};
var esc=function(s){return String(s==null?"-":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");};
var dash=function(v){return (v==null||v==="")?"-":esc(v);};
var data=null;
try{data=JSON.parse(document.getElementById("fleet-data").textContent);}catch(e){return;}
function laneOf(id){return (data.lanes&&data.lanes[id])||"unknown";}
function stateRank(s){s=String(s||"");if(/done|landed|passed|green/i.test(s))return 2;if(/fail|blocked|invalid|unknown/i.test(s))return 1;return 0;}
function render(d){
document.getElementById("meta").textContent="Generated "+d.generated+" - home "+(d.snapshot.fm_home||"-")+" - schema "+d.schema;
var j=d.snapshot.jev_shadow;
document.getElementById("jev").innerHTML = j ? ("<b>Jev shadow</b> - samples "+dash(j.samples)+" - recorded "+dash(j.recorded)+" - fields agree "+dash(j.allFieldsAgree)+" - route agree "+dash(j.routeAgree)) : "<b>Jev shadow</b> - no report (shadow disabled or tool absent)";
var root=el("div");var snap=d.snapshot;var rows=(snap.secondmate_current&&snap.secondmate_current.records)||[];
var st=el("div");st.appendChild(el("h2",null,"Stations"));
var t=el("table");t.innerHTML="<tr><th>Station</th><th>Home</th><th>State</th><th>Endpoint</th><th>Convergence</th><th class='mono'>Children</th><th class='mono'>Decisions</th><th class='mono'>Queued</th><th>Note</th></tr>";
var tr=el("tr");
tr.innerHTML="<td>local</td><td>main</td><td>"+dash(snap.main_inventory&&snap.main_inventory.valid?"ok":"inventory-invalid")+"</td><td>-</td><td>local-backlog</td><td class='mono'>"+((snap.tasks||[]).filter(function(x){return x.kind!=="secondmate";}).length)+"</td><td class='mono'>"+((snap.backlog.records||[]).filter(function(x){return x.captain_actionable;}).length)+"</td><td class='mono'>"+((snap.backlog.records||[]).filter(function(x){return x.state==="queued";}).length)+"</td><td>"+dash(snap.main_inventory&&snap.main_inventory.reason)+"</td>";
t.appendChild(tr);
rows.forEach(function(r){var s=(r.host&&r.host!=="")?r.host:"local";var q=el("tr");
q.innerHTML="<td>"+dash(s)+"</td><td class='mono'>"+dash(r.id)+"</td><td>"+dash((r.current&&r.current.state)||"unknown")+((r.current&&r.current.reason)?" ("+esc(String(r.current.reason)).slice(0,70)+")":"")+"</td><td class='mono'>"+dash(r.station_endpoint)+"</td><td class='mono'>"+dash(r.provenance&&r.provenance.summary_source)+"/"+dash(r.freshness&&r.freshness.status)+"</td><td class='mono'>"+dash(r.counts&&r.counts.active_children)+"</td><td class='mono'>"+dash(r.counts&&r.counts.decisions_open)+"</td><td class='mono'>"+dash(r.counts&&r.counts.queued)+"</td><td>"+(r.invalidity&&r.invalidity.kind?("invalid: "+esc(r.invalidity.kind)):"-")+"</td>";t.appendChild(q);});
st.appendChild(t);root.appendChild(st);
var byStation={};
function push(station,row){(byStation[station]=byStation[station]||[]).push(row);}
(snap.tasks||[]).filter(function(x){return x.kind!=="secondmate";}).forEach(function(x){push("local",{home:"main",task:x.id,state:(x.current_state&&x.current_state.state)||"unknown",model:(x.usage&&x.usage.model)||"-",lane:laneOf(x.id),pr:(x.pr&&x.pr.url)||null,origin:"managed"});});
rows.forEach(function(r){var s=(r.host&&r.host!=="")?r.host:"local";((r.active_children)||[]).forEach(function(c){push(s,{home:r.id,task:c.id||"-",state:c.state||"unknown",model:(c.usage&&c.usage.model)||"-",lane:"unknown",pr:null,origin:"managed"});});});
var w=el("div");w.appendChild(el("h2",null,"Workers (in-flight first within each station)"));
Object.keys(byStation).sort().forEach(function(s){var box=el("div","station");box.appendChild(el("h2",null,"Station: "+esc(s)));
var wt=el("table");wt.innerHTML="<tr><th>Home</th><th>Task</th><th>State</th><th>Model</th><th>Lane</th><th>PR</th><th>Origin</th></tr>";
byStation[s].sort(function(a,b){return stateRank(a.state)-stateRank(b.state);}).forEach(function(r){var q=el("tr");
q.innerHTML="<td class='mono'>"+dash(r.home)+"</td><td class='mono'>"+dash(r.task)+"</td><td>"+dash(r.state)+"</td><td class='mono'>"+dash(r.model)+"</td><td>"+dash(r.lane)+"</td><td>"+(r.pr?("<a href='"+esc(r.pr)+"'>PR</a>"):"-")+"</td><td>"+dash(r.origin)+"</td>";wt.appendChild(q);});
box.appendChild(wt);w.appendChild(box);});
root.appendChild(w);
var u=el("div");u.appendChild(el("h2",null,"Unmanaged Herdr sessions (seen on host, not tracked by firstmate)"));
var ut=el("table");ut.innerHTML="<tr><th>Host</th><th>Session</th><th>Agent</th><th>Status</th><th class='mono'>Pane</th><th class='mono'>Cwd</th><th>Title</th></tr>";
var any=false;
((d.herdr&&d.herdr.hosts)||[]).forEach(function(h){((h.sessions)||[]).forEach(function(s){((s.agents)||[]).filter(function(a){return !a.managed;}).forEach(function(a){any=true;var q=el("tr");
q.innerHTML="<td>"+dash(h.host)+"</td><td class='mono'>"+dash(s.name)+"</td><td class='mono'>"+dash(a.agent)+"</td><td>"+dash(a.status)+"</td><td class='mono'>"+dash(a.pane_id)+"</td><td class='mono'>"+esc(a.cwd||"").slice(0,80)+"</td><td>"+dash(a.title)+"</td>";ut.appendChild(q);});
((s.plain_panes)||[]).forEach(function(p){any=true;var q2=el("tr");
q2.innerHTML="<td>"+dash(h.host)+"</td><td class='mono'>"+dash(s.name)+"</td><td class='mono'>shell</td><td>unknown</td><td class='mono'>"+dash(p.pane_id)+"</td><td class='mono'>"+esc(p.cwd||"").slice(0,80)+"</td><td>"+dash(p.title)+"</td>";ut.appendChild(q2);});});});
if(!any){var q3=el("tr");q3.innerHTML="<td colspan='7'>No unmanaged sessions reported."+(((d.herdr&&d.herdr.hosts)||[]).length?"":" Herdr collection unavailable.")+"</td>";ut.appendChild(q3);}
u.appendChild(ut);
var herr=((d.herdr&&d.herdr.hosts)||[]).filter(function(h){return !h.ok;});
if(herr.length){var hn=el("div","note");hn.textContent="Unreachable stations: "+herr.map(function(h){return h.host+" ("+(h.error||"unknown")+")";}).join("; ");u.appendChild(hn);}
root.appendChild(u);
var f=document.getElementById("fleet");f.innerHTML="";f.appendChild(root);
}
render(data);
fetch("fleet.json?ts="+Date.now(),{cache:"no-store"}).then(function(r){return r.ok?r.json():null;}).then(function(fresh){if(fresh&&fresh.generated&&fresh.generated!==data.generated){render(fresh);document.getElementById("fresh").textContent="live-refreshed";}}).catch(function(){});
setInterval(function(){fetch("fleet.json?ts="+Date.now(),{cache:"no-store"}).then(function(r){return r.ok?r.json():null;}).then(function(fresh){if(fresh&&fresh.generated){render(fresh);}}).catch(function(){});},60000);
})();
</script>
</body>
</html>
HTML
}

write_dest() {  # <dir>
  local dir=$1
  mkdir -p "$dir" 2>/dev/null || pulse_fail "cannot create $dir"
  printf '%s' "$MERGED" > "$dir/fleet.json.tmp.$$" 2>/dev/null || pulse_fail "cannot write $dir/fleet.json"
  mv -f -- "$dir/fleet.json.tmp.$$" "$dir/fleet.json" || pulse_fail "cannot publish $dir/fleet.json"
  {
    pulse_head
    printf '%s\n' "$INLINED"
    pulse_tail
  } > "$dir/fleet.html.tmp.$$" 2>/dev/null || pulse_fail "cannot write $dir/fleet.html"
  mv -f -- "$dir/fleet.html.tmp.$$" "$dir/fleet.html" || pulse_fail "cannot publish $dir/fleet.html"
  chmod 0644 "$dir/fleet.json" "$dir/fleet.html" 2>/dev/null || true
}

LOCAL_DEST=${OUT_ARG:-$STATE/fleet-pulse}
write_dest "$LOCAL_DEST"

if [ "$PUBLISH_DASHBOARD" != "0" ]; then
  if [ -d "$DASHBOARD_DIR" ]; then
    if ! { write_dest "$DASHBOARD_DIR"; } 2>/dev/null; then
      [ "$BEST_EFFORT" -eq 1 ] || echo "fm-fleet-pulse: dashboard copy skipped (cannot write $DASHBOARD_DIR)" >&2
    fi
  elif [ "$BEST_EFFORT" -eq 0 ]; then
    echo "fm-fleet-pulse: dashboard dir $DASHBOARD_DIR not present; local copy at $LOCAL_DEST only" >&2
  fi
fi

if [ "$BEST_EFFORT" -eq 0 ]; then
  printf 'published fleet page: %s/fleet.html (%s/fleet.json)\n' "$LOCAL_DEST" "$LOCAL_DEST"
fi
exit 0
