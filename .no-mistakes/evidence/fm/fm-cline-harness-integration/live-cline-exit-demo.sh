#!/usr/bin/env bash
# Part 2: fm-control.sh exit against a LIVE cline worker (part 1's exit landed on
# an agent the broken relaunch had already stopped), plus the busy->interrupt->
# exit path fm-control drives for a busy agent.
set -u
ROOT=${1:?repo root}
LABHOME=${2:?sandbox home}
ID=cline-act-demo
REAL_TMUX=$(command -v tmux)
CLINE_BIN=$(command -v cline)
SOCKET="fm-cline-exit-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cline-exit.XXXXXX")
WT=$(grep '^worktree=' "$LABHOME/state/$ID.meta" | cut -d= -f2-)
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
say() { printf '\n=== %s ===\n' "$*"; }
capture() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "firstmate:fm-$ID" 2>/dev/null || true; }

mkdir -p "$LAB/bin"
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH"; unset TMUX
FM_ENV=(FM_ROOT_OVERRIDE="" FM_HOME="$LABHOME" FM_STATE_OVERRIDE="$LABHOME/state"
        FM_DATA_OVERRIDE="$LABHOME/data" FM_CONFIG_OVERRIDE="$LABHOME/config"
        FM_GATE_REFUSE_BYPASS=1)

"$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -n control -c "$WT" -x 200 -y 50
"$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n "fm-$ID" -c "$WT"

say "relaunching the recorded worker command by hand (fm-control relaunch is broken pre-existing)"
echo "\$ CLINE_GLOBAL_SETTINGS_PATH=$LABHOME/state/$ID.cline-settings.json cline -i --tui --auto-approve true"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$ID" \
  "CLINE_GLOBAL_SETTINGS_PATH='$LABHOME/state/$ID.cline-settings.json' '$CLINE_BIN' -i --tui --auto-approve true" Enter
for _ in $(seq 1 200); do capture | grep -qE '(●|○) Plan' && break; sleep 0.3; done
capture | grep -aE 'Plan .*Act' | tail -1

say "\$ fm-crew-state.sh $ID   (idle worker, no turn in flight)"
env "${FM_ENV[@]}" "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1

say "submitting a long turn so exit has to interrupt a BUSY agent first"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$ID" \
  "Count slowly from 1 to 80, writing one short line per number. Do not use tools."
sleep 1
"$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$ID" Enter
for _ in $(seq 1 300); do
  OUT=$(env "${FM_ENV[@]}" "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1)
  case "$OUT" in *"state: working"*) break ;; esac
  sleep 0.3
done
echo "\$ fm-crew-state.sh $ID"; printf '%s\n' "$OUT"

say "\$ fm-control.sh $ID exit   (against the live, busy agent)"
env "${FM_ENV[@]}" "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1; echo "exit verb rc=$?"

say "endpoint after exit: the worktree and its work are preserved, the agent is gone"
echo -n "pane command: "; "$REAL_TMUX" -L "$SOCKET" display -p -t "firstmate:fm-$ID" '#{pane_current_command}' 2>&1
echo "worktree still holds the crewmate's work:"; ls "$WT"; cat "$WT/ACT_PROOF.txt"

say "\$ fm-crew-state.sh $ID   (after exit)"
env "${FM_ENV[@]}" "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1
