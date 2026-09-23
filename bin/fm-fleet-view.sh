#!/usr/bin/env bash
# fm-fleet-view.sh - human renderer over fm-fleet-snapshot.sh.
#
# This command intentionally does not parse fleet state itself.
# It shells out to fm-fleet-snapshot.sh --json and renders that stable
# structured contract for humans.
#
# The view covers the whole registered fleet: the local home and every local or
# remote secondmate home, plus every child agent each home reports, plus every
# Herdr session/agent on every host from the read-only fm-fleet-herdr-collect.sh
# contract (schema fm-fleet-herdr.v1) - including sessions firstmate did not
# dispatch or no longer tracks, labeled unmanaged rather than omitted. It reads
# only fields the snapshot already carries (schema fm-fleet-snapshot.v1) and the
# remote home-summary contract (fm-secondmate-home-summary.v1); it never
# computes a summary and never invents a second state source. The Herdr section
# is best-effort and bounded (FM_FLEET_VIEW_HERDR_TIMEOUT, default 60s); when
# collection fails it renders an explicit unavailable line.
#
# Every rendered row keeps missing data explicit: a field the contract does not
# carry renders "-" and an unknown value renders "unknown", never a blank cell.
# The Stations Endpoint column prefers the snapshot's live station_endpoint
# (probed mate endpoint, else parent endpoint, else ledger endpoint evidence)
# and falls back to the parent-side child endpoint only when the record carries
# no station endpoint at all. The Stations Note column carries the record's
# own reason verbatim (invalidity detail, read failure, or main-inventory
# inconsistency) or "-" when there is none; it never replaces the row's data.
# Branch is not carried by the snapshot contract, so it renders "-". Production
# is display-only and is never inferred from a branch; it renders "unknown"
# unless a release manifest supplies it (see the Release Manifest section and
# FM_FLEET_VIEW_MANIFEST below).
#
# A release manifest is the documented seam the remote consolidation owner will
# fill later. This renderer does not assume its schema: it reports the file's
# presence, its own schema id and generated stamp when present, and its
# top-level entry count. Mapping its fields into the fleet tables is deferred
# until that owner publishes the manifest schema.
#
# Usage:
#   fm-fleet-view.sh            # render the fleet view
#   fm-fleet-view.sh --json     # print the underlying snapshot JSON
#   fm-fleet-view.sh --release-manifest <path>   # override the manifest path
#   fm-fleet-view.sh --help
#
# Environment:
#   FM_FLEET_VIEW_MANIFEST   optional release-manifest path (see above)
#   FM_HOME                  operational home (resolved by fm-fleet-snapshot.sh)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-fleet-view.sh [--json] [--release-manifest <path>]

Render a human fleet view from fm-fleet-snapshot.sh covering the local home and
every local or remote secondmate home plus their child agents.

Options:
  --json                    Print the underlying fm-fleet-snapshot.v1 JSON.
  --release-manifest <path> Read the optional release manifest from <path>
                            instead of FM_HOME/data/fleet-release-manifest.json.
  -h, --help                Show this help.

Missing data renders as "-" (not carried) or "unknown" (not known); branch and
production are never inferred from a branch.
EOF
}

MANIFEST_ARG=
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; exit $? ;;
  "") ;;
  --release-manifest)
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    MANIFEST_ARG=$2
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-view: jq not found" >&2; exit 1; }

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || exit $?

# Every Herdr session/agent on every host, managed and unmanaged, from the
# read-only fm-fleet-herdr-collect.sh contract. Best-effort and bounded so a
# dark station cannot stall the terminal view; absence renders as an explicit
# unavailable line, never a silent omission.
FM_VIEW_HERDR_TIMEOUT=${FM_FLEET_VIEW_HERDR_TIMEOUT:-60}
case "$FM_VIEW_HERDR_TIMEOUT" in ''|*[!0-9]*|0) FM_VIEW_HERDR_TIMEOUT=60 ;; esac
HERDR_JSON=$(fm_run_timed "$FM_VIEW_HERDR_TIMEOUT" "${FM_FLEET_VIEW_HERDR_BIN:-$SCRIPT_DIR/fm-fleet-herdr-collect.sh}" --json 2>/dev/null) || HERDR_JSON=''
case "$HERDR_JSON" in
  *'"schema":"fm-fleet-herdr.v1"'*|*'"schema": "fm-fleet-herdr.v1"'*) ;;
  *) HERDR_JSON=null ;;
esac

FM_VIEW_HOME=$(printf '%s\n' "$SNAPSHOT" | jq -r '.fm_home // empty' 2>/dev/null)
DATA_DIR="${FM_DATA_OVERRIDE:-${FM_VIEW_HOME:+$FM_VIEW_HOME/data}}"
MANIFEST_PATH=${MANIFEST_ARG:-${FM_FLEET_VIEW_MANIFEST:-${DATA_DIR:+$DATA_DIR/fleet-release-manifest.json}}}

# fm_view_manifest_json: a small, schema-agnostic summary of the optional
# release manifest. Prints a JSON object or null. Never guesses the manifest's
# own field meaning beyond the near-universal schema/generated stamps.
fm_view_manifest_json() {  # <path>
  local path=$1
  [ -n "$path" ] || { printf 'null\n'; return 0; }
  [ -f "$path" ] && [ ! -L "$path" ] || { printf 'null\n'; return 0; }
  jq -c '
    if type != "object" then null
    else {
      schema: ((.schema // null) | if . == null then null else tostring end),
      generated: ((.generated // null) | if . == null then null else tostring end),
      entries: (to_entries | length)
    } end
  ' "$path" 2>/dev/null || printf 'null\n'
}

MANIFEST_JSON=$(fm_view_manifest_json "$MANIFEST_PATH")
case "$MANIFEST_JSON" in
  *[![:space:]]*) ;;
  *) MANIFEST_JSON=null ;;
esac

printf '%s\n' "$SNAPSHOT" | jq -r --arg manifest_path "$MANIFEST_PATH" --argjson manifest "$MANIFEST_JSON" --argjson herdr "$HERDR_JSON" '
  (.secondmate_current.records // []) as $rows
  | (.backlog.records // []) as $brecs
  | (.tasks // []) as $tasks
  | ($herdr // null) as $herdr
  | def dash($v): if $v == null or ($v | tostring) == "" then "-" else ($v | tostring) end;
  def base($p): if $p == null or ($p | tostring) == "" then "-" else (($p | tostring) | sub("/+$"; "") | split("/") | last) end;
  def short($v; $n): if $v == null then "-" else (($v | tostring) | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end) end;
  def merge_of($id): ( [ $brecs[] | select(.id == $id) | (.completion.verb // empty) ] | .[0] // "-" );
  def nm_of($state; $source): if $source == "run-step" then dash($state) else "-" end;
  def station_of($r): ( ($r.host // "") | if . == "" then "local" else . end );
  def registered_ids: [ $rows[].id ];
  def endpoint_cell($t):
    "\(if $t.endpoint.exists == null then "unknown" elif $t.endpoint.exists then "present" else "absent" end)/\(dash($t.endpoint.agent_alive))";
  def endpoint_of_id($id): ( [ $tasks[] | select(.id == $id) | endpoint_cell(.) ] | .[0] // "unknown" );
  def station_endpoint_of($r; $id):
    if (($r.station_endpoint // null) == null
        or ((($r.station_endpoint.exists // null) == null)
            and ((($r.station_endpoint.agent_alive // "unknown") | tostring) == "unknown")))
    then endpoint_of_id($id)
    else endpoint_cell({endpoint: $r.station_endpoint}) end;
  def note_of($r):
    if ((($r.current.reason // "") | tostring) != "") then short($r.current.reason; 120)
    elif $r.invalidity.kind != null then "invalid: \($r.invalidity.kind)"
    else "-" end;
  def station_state($r):
    if ($r.current.reason // "") == "" then dash($r.current.state)
    else "\(dash($r.current.state)) (\(short($r.current.reason; 70)))" end;
  def convergence($r): "\($r.provenance.summary_source // "unknown")/\($r.freshness.status // "unknown") \(($r.freshness.age_seconds // 0))s";
  def child_row($station; $project; $task; $state; $model; $nomistakes; $pr; $merge):
    "| \(dash($station)) | \(dash($project)) | \(dash($task)) | \(dash($state)) | \(dash($model)) | - | \($nomistakes) | \($pr) | \($merge) |";

  "# Fleet View",
  "",
  "Generated: \(.generated)",
  "Schema: \(.schema)",
  "Home: \(.fm_home)",
  "",
  "Readable station/project/task/state/model and the PR, run and merge status",
  "come from the existing fleet snapshot and remote home-summary contracts.",
  "Branch and production are not carried there and are never inferred from a",
  "branch; they render as \"-\"/\"unknown\".",
  "",
  "## Stations",
  "| Station | Home | State | Endpoint | Convergence | Children | Decisions | Holds | Queued | Landed | Production | Note |",
  "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  ("| local | main | \(if .main_inventory.valid then "ok" else "inventory-invalid" end) | - | local-backlog \(.generated) | "
    + "\([ $tasks[] | select(.kind != "secondmate") ] | length) | "
    + "\([ $brecs[] | select(.captain_actionable == true) ] | length) | "
    + "\([ $brecs[] | select(.hold_kind == "captain") ] | length) | "
    + "\([ $brecs[] | select(.state == "queued") ] | length) | "
    + "\([ $brecs[] | select(.state == "done") ] | length) | unknown | "
    + "\(if ((.main_inventory.reason // "") | tostring) == "" then "-" else short(.main_inventory.reason; 120) end) |"),
  ( $rows[]
    | "| \(station_of(.)) | \(dash(.id)) | \(station_state(.)) | \(station_endpoint_of(.; .id)) | \(convergence(.)) | "
    + "\(.counts.active_children // 0) | \(.counts.decisions_open // 0) | \(.counts.holds // 0) | "
    + "\(.counts.queued // 0) | \(.counts.landed // 0) | unknown | \(note_of(.)) |" ),
  ( $tasks[]
    | select(.kind == "secondmate")
    | select(.id as $i | (registered_ids | index($i)) == null)
    | "| local | \(dash(.id)) | \(dash(.current_state.state)) | \(endpoint_cell(.)) | unregistered-local | - | - | - | - | - | unknown | - |" ),
  "",
  "## Child Agents",
  "| Station | Project | Task | State | Model | Branch | No-mistakes | PR | Merge |",
  "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  ( ( [ .tasks[]? | select(.kind != "secondmate")
        | child_row("local"; base(.backlog.repo // .project); .id; .current_state.state; .usage.model;
                    nm_of(.current_state.state; .current_state.source); dash(.pr.url); merge_of(.id)) ]
      + [ $rows[] as $r | ($r.active_children // [])[]
          | child_row(station_of($r); base(.repo // $r.id); .id; .state; .usage.model;
                      nm_of(.state; .source); "-"; "-") ] )
    | (if length == 0 then ["| - | - | - | - | - | - | - | - | - |"] else . end)[]
  ),
  "",
  "## Unmanaged Herdr Sessions",
  "Seen on-host by the read-only Herdr collector, including sessions firstmate",
  "did not dispatch or no longer tracks. Managed rows name their tracked task;",
  "unmanaged rows are observed only, never touched.",
  "| Host | Session | Agent | Status | Pane | Task | Managed | Cwd |",
  "| --- | --- | --- | --- | --- | --- | --- | --- |",
  def herdr_row($hh; $sn; $agent; $status; $pane; $task; $mgmt; $cwd):
    "| \(dash($hh)) | \(dash($sn)) | \(dash($agent)) | \(dash($status)) | "
    + "\(dash($pane)) | \(dash($task)) | \($mgmt) | \(short($cwd; 60)) |";
  def herdr_rows:
    [ ($herdr.hosts // [])[]
      | .host as $hh
      | if .ok != true then
          "| \(dash($hh)) | - | - | - | - | - | - | \(short(.error // "unreachable"; 60)) |"
        else
          (.sessions[]?
           | .name as $sn
           | ([ ((.agents // [])[] | select(.managed != true)
                  | herdr_row($hh; $sn; .agent; .status; .pane_id; .matched_task_id; "unmanaged"; .cwd)),
                 ((.agents // [])[] | select(.managed == true)
                  | herdr_row($hh; $sn; .agent; .status; .pane_id; .matched_task_id; "managed"; .cwd)),
                 ((.plain_panes // [])[]
                  | herdr_row($hh; $sn; "shell"; "unknown"; .pane_id; "-"; "unmanaged"; .cwd)) ]
              | .[]))
        end ];
  ( if $herdr == null or (($herdr.hosts // []) | length) == 0 then
      ["| - | - | - | - | - | - | - | Herdr session collection unavailable |"]
    else
      (herdr_rows
       | if length == 0 then ["| - | - | - | - | - | - | - | No unmanaged sessions reported |"] else . end)[]
    end ),
  "",
  "## Remote Development Sessions",
  "| Station | Backend | Session | Workspace/Window | Tab/Pane | Task | Project | Branch | Attach |",
  "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  ( (.remote_dev_sessions // []) as $rd
    | (if ($rd | length) == 0 then ["| - | - | - | - | - | - | - | - | - |"]
       else [ $rd[]
         | "| \(dash(.station)) | \(dash(.backend)) | \(dash(.session)) | "
           + "\(dash(if (.workspace // "") != "" then .workspace else .window end)) | "
           + "\(dash(if (.tab // "") != "" then "\(.tab)/\(.pane)" else .pane end)) | "
           + "\(dash(.task_id)) | \(dash(.project)) | \(dash(.branch)) | \(dash(.attach_command)) |"
         ] end)[] ),
  "",
  "## Queued",
  (if ([.backlog.records[]? | select(.state == "queued")] | length) == 0 then
    "No queued backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "queued")
      | "| \(.id // "-") | \(dash(.title // .raw)) | \(dash(.repo)) | \(dash(.kind)) | "
        + "\(if (.blocked_by // "") == "" then "-" elif (.blocked_reason // "") == "" then .blocked_by else "\(.blocked_by) - \(.blocked_reason)" end) | "
        + "\(dash(.pr_url // .report_path // .local_note)) |")
   end),
  "",
  "## Done",
  (if ([.backlog.records[]? | select(.state == "done")] | length) == 0 then
    "No done backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "done")
      | "| \(.id // "-") | \(dash(.title // .raw)) | \(dash(.repo)) | \(dash(.kind)) | "
        + "\(if (.blocked_by // "") == "" then "-" elif (.blocked_reason // "") == "" then .blocked_by else "\(.blocked_by) - \(.blocked_reason)" end) | "
        + "\(dash(.pr_url // .report_path // .local_note)) |")
   end),
  "",
  "## Release Manifest",
  (if $manifest == null then
    "Source: \($manifest_path // "-") (not present)",
    "No release manifest available; convergence and production stay display-only."
   else
    "Source: \($manifest_path)",
    "Schema: \(dash($manifest.schema))",
    "Generated: \(dash($manifest.generated))",
    "Top-level entries: \($manifest.entries)",
    "Field mapping into the fleet tables is deferred until the consolidation owner publishes its schema."
   end)
'
