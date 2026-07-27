#!/usr/bin/env bash
# fm-fleet.sh — FirstMate federation CLI. Coordinates multiple operators through a
# shared, cross-uid-safe, git-backed KB. See docs/federation.md and
# .agents/skills/federation/SKILL.md.
#
# Usage:
#   fm-fleet.sh init
#   fm-fleet.sh queue   <id> <scope> <desc...>
#   fm-fleet.sh claim   <id> <operator>
#   fm-fleet.sh handoff <id> <to-operator>
#   fm-fleet.sh reap    [ttl-seconds]        (default 86400)
#   fm-fleet.sh route   <scope>              (echoes owning operator)
#   fm-fleet.sh status
#   fm-fleet.sh view    [--follow]
#
# Fleet dir resolves from: FM_FLEET_DIR -> $FM_HOME/config/fleet-dir -> /opt/agents/fleet
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-fleet-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-fleet-lib.sh"
DIR=$(fm_fleet_dir)

cmd=${1:-}; shift || true
case "$cmd" in
  init)    fm_fleet_init "$DIR"; echo "fleet initialized at $DIR" ;;
  queue)   id=$1; scope=$2; shift 2; fm_fleet_queue "$DIR" "$id" "$scope" "$*" ;;
  claim)   fm_fleet_claim "$DIR" "$1" "$2" ;;
  handoff) fm_fleet_handoff "$DIR" "$1" "$2" ;;
  reap)    fm_fleet_reap "$DIR" "${1:-86400}" ;;
  route)   fm_fleet_route "$DIR" "$1" ;;
  status)  fm_fleet_status "$DIR" ;;
  view)    fm_fleet_view "$DIR" "${1:-}" ;;
  register)  op=$1; scopes=$2; home=$3; shift 3; fm_fleet_register "$DIR" "$op" "$scopes" "$home" "${1:-}" ;;
  heartbeat) fm_fleet_heartbeat "$DIR" "$1" ;;
  leave)     fm_fleet_leave "$DIR" "$1" ;;
  budget)    fm_fleet_budget_ok && echo "ok (min headroom >= ${FM_FLEET_QUOTA_MIN:-5}%)" || { echo "below floor (< ${FM_FLEET_QUOTA_MIN:-5}%)"; exit 1; } ;;
  quota)     fm_fleet_quota_report ;;
  models)    fm_fleet_models_report ;;
  pick)      fm_fleet_pick_surface "${1:?usage: fm-fleet.sh pick <model-family>}" ;;
  *) echo "usage: fm-fleet.sh init|register|heartbeat|leave|queue|claim|handoff|reap|route|budget|quota|models|pick|status|view" >&2; exit 1 ;;
esac
