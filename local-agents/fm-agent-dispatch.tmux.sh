#!/usr/bin/env bash
# fm-agent-dispatch.tmux.sh - start, stop, or status the dispatcher session.
# stop sends SIGTERM to that session's pane process only.
set -euo pipefail

session=fm-agent-dispatch
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
repo=$(cd "$script_dir/.." && pwd) || exit 1
state_dir=${FM_AGENT_STATE:-$HOME/dev/mini-state/local-agents}

usage() {
  printf '%s\n' "usage: fm-agent-dispatch.tmux.sh start|stop|status" >&2
  exit 2
}

session_up() {
  tmux has-session -t "$session" 2>/dev/null
}

cmd=${1:-}
case "$cmd" in
  start)
    mkdir -p "$state_dir"
    if session_up; then
      printf '%s\n' "running"
      exit 0
    fi
    repo_q=$(printf '%q' "$repo")
    log_q=$(printf '%q' "$state_dir/dispatch.log")
    tmux new-session -d -s "$session" "cd ${repo_q} && exec python3 bin/fm-agent-dispatch.py loop >> ${log_q} 2>&1"
    printf '%s\n' "started"
    ;;
  stop)
    if ! session_up; then
      printf '%s\n' "stopped"
      exit 0
    fi
    while IFS= read -r pane_pid; do
      if [ -n "$pane_pid" ]; then
        kill -TERM "$pane_pid" 2>/dev/null || true
      fi
    done < <(tmux list-panes -t "$session" -F '#{pane_pid}')
    printf '%s\n' "stopped"
    ;;
  status)
    if session_up; then
      printf '%s\n' "running"
      exit 0
    fi
    printf '%s\n' "stopped"
    exit 1
    ;;
  *)
    usage
    ;;
esac
