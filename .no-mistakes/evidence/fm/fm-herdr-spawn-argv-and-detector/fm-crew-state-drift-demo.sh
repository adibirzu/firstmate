#!/usr/bin/env bash
# Isolated demonstration of the user-visible state-line annotation.
set -eu

ROOT=/Users/adrianb/.no-mistakes/worktrees/80e4cf1781af/01M26AEKRAD3ET60XP5JJKD2JQ
. "$ROOT/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-state-drift-demo)
trap 'fm_test_cleanup' EXIT

PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/pool/task-worktree"
STATE_DIR="$TMP_ROOT/state"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$PROJECT/src" "$WORKTREE" "$STATE_DIR" "$FAKEBIN"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  case "$arg" in
    '#{pane_current_path}') printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
    '#{pane_tty}') printf '/dev/pts/fm-launch-drift\n'; exit 0 ;;
    '#{pane_id}') printf '%%0\n'; exit 0 ;;
  esac
done
if [ "${1:-}" = list-panes ] && [ "${2:-}" = -a ]; then
  printf 'firstmate\tfm-healthy\t@1\t%%0\t1\t%s\t/dev/pts/fm-launch-drift\n' "$FM_FAKE_PANE_PATH"
fi
SH
chmod +x "$FAKEBIN/tmux"

REAL_PS=$(command -v ps)
export REAL_PS
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' -t pts/fm-launch-drift '*) printf '4242 4242 4242 claude\n' ;;
  *' -p 4242 '*) printf 'claude --dangerously-skip-permissions --model opus\n' ;;
  *) exec "$REAL_PS" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/ps"

PATH="$FAKEBIN:$PATH"
export PATH
FM_FAKE_PANE_PATH="$PROJECT/src"
export FM_FAKE_PANE_PATH

fm_write_meta "$STATE_DIR/healthy.meta" \
  'window=%0' \
  'endpoint_task_id=healthy' \
  "worktree=$WORKTREE" \
  "project=$PROJECT" \
  'harness=claude' \
  'kind=scout' \
  'backend=tmux'
printf 'launch_argv=claude --dangerously-skip-permissions --model opus\n' >> "$STATE_DIR/healthy.meta"

FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-crew-state.sh" healthy
