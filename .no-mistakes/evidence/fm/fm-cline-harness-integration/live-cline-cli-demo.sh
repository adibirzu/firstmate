#!/usr/bin/env bash
# Manual end-to-end verification of the user intent, driven through the REAL
# user-facing CLIs against a REAL cline crewmate:
#   Gap 1  fm-spawn.sh launches a cline crewmate that starts in Act mode and
#          actually implements (writes a file), without touching ~/.cline.
#   Gap 2  fm-control.sh <task> interrupt|relaunch|exit acts on that worker.
#   Gap 3  fm-crew-state.sh <task> reports a real busy/idle state for it.
set -u
ROOT=${1:?repo root}
EV=${2:?evidence dir}
REAL_TMUX=$(command -v tmux)
CLINE_BIN=$(command -v cline)
SOCKET="fm-cli-demo-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cline-cli-demo.XXXXXX")
ID=cline-act-demo
HOME_DIR="$LAB/home"; PROJ="$LAB/project"; WT="$LAB/wt"

cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
say() { printf '\n=== %s ===\n' "$*"; }
capture() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "firstmate:fm-$ID" 2>/dev/null || true; }

OPERATOR_SETTINGS="$HOME/.cline/data/settings/global-settings.json"
OP_BEFORE=$(cksum < "$OPERATOR_SETTINGS")
say "operator's own cline settings BEFORE (cksum) and its recorded planActMode"
printf '%s\n' "$OP_BEFORE"
jq -c '{planActMode, telemetrySetting: (.telemetrySetting // null)}' "$OPERATOR_SETTINGS"

# tmux shim: every firstmate CLI below talks to this isolated lab server.
mkdir -p "$LAB/bin"
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"

mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$PROJ"
git -C "$PROJ" init -q; git -C "$PROJ" commit -q --allow-empty -m init
git -C "$PROJ" worktree add --quiet -b "fm/$ID" "$WT"
touch "$HOME_DIR/state/.last-watcher-beat"
cat > "$HOME_DIR/data/$ID/brief.md" <<'BRIEF'
Create a file named ACT_PROOF.txt in the repository root whose only content is
the single line ACT-MODE-OK. Do not ask any questions. Do not plan. Just make
the change, then stop.

Delivery contract: mode=local-only yolo=off
BRIEF

export PATH="$LAB/bin:$PATH"
unset TMUX
FM_ENV=(FM_ROOT_OVERRIDE="" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state"
        FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects"
        FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1
        FM_GATE_REFUSE_BYPASS=1)

say "\$ fm-spawn.sh $ID <project> cline --mode local-only --yolo off"
env "${FM_ENV[@]}" "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" cline --mode local-only --yolo off 2>&1
SPAWN_RC=$?
echo "spawn exit=$SPAWN_RC"
[ "$SPAWN_RC" = 0 ] || { echo "SPAWN FAILED"; exit 1; }

say "firstmate-owned settings copy the launch redirects CLINE_GLOBAL_SETTINGS_PATH at"
jq -c . "$HOME_DIR/state/$ID.cline-settings.json"

say "waiting for the real cline TUI to render its mode footer"
for _ in $(seq 1 200); do capture | grep -qE '(●|○) Plan' && break; sleep 0.3; done
capture | grep -aE 'Plan .*Act' | tail -2

say "\$ fm-crew-state.sh $ID   (while the crewmate works)"
for _ in $(seq 1 300); do
  OUT=$(env "${FM_ENV[@]}" "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1)
  case "$OUT" in *"state: working"*) break ;; esac
  sleep 0.3
done
printf '%s\n' "$OUT"

say "waiting for the crewmate to actually IMPLEMENT (Act mode writes the file)"
for _ in $(seq 1 400); do [ -f "$WT/ACT_PROOF.txt" ] && break; sleep 0.5; done
if [ -f "$WT/ACT_PROOF.txt" ]; then
  echo "ACT_PROOF.txt written by the crewmate:"; cat "$WT/ACT_PROOF.txt"
  git -C "$WT" status --porcelain
else
  echo "NO FILE WRITTEN"
fi

say "structural mode cline itself recorded for this pane's session"
SESS=$(grep '^sessions_root=' "$HOME_DIR/state/$ID.cline-session" | cut -d= -f2-)
REC=$(grep -rl "$WT" "$SESS"/*/ 2>/dev/null | grep -v messages | tail -1)
jq -c '{session_id, status, mode: .metadata.mode}' "$REC" 2>/dev/null

say "\$ fm-crew-state.sh $ID   (after the turn finishes)"
for _ in $(seq 1 200); do
  OUT=$(env "${FM_ENV[@]}" "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1)
  case "$OUT" in *"state: working"*) sleep 0.5 ;; *) break ;; esac
done
printf '%s\n' "$OUT"

say "submitting a long second turn, then interrupting it through the control plane"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$ID" \
  "Count slowly from 1 to 60, writing one short line per number. Do not use tools." 
sleep 1
"$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$ID" Enter
for _ in $(seq 1 300); do
  OUT=$(env "${FM_ENV[@]}" "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1)
  case "$OUT" in *"state: working"*) break ;; esac
  sleep 0.3
done
echo "\$ fm-crew-state.sh $ID"; printf '%s\n' "$OUT"

say "\$ fm-control.sh $ID interrupt"
env "${FM_ENV[@]}" "$ROOT/bin/fm-control.sh" "$ID" interrupt 2>&1; echo "interrupt exit=$?"

say "\$ fm-crew-state.sh $ID   (after interrupt)"
for _ in $(seq 1 100); do
  OUT=$(env "${FM_ENV[@]}" "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1)
  case "$OUT" in *"state: working"*) sleep 0.5 ;; *) break ;; esac
done
printf '%s\n' "$OUT"
echo "--- pane composer row after interrupt ---"
capture | grep -a '❯' | tail -1

say "\$ fm-control.sh $ID relaunch --note ..."
env "${FM_ENV[@]}" "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "live re-verification of the cline adapter" 2>&1
echo "relaunch exit=$?"
sleep 5
capture | grep -aE 'Plan .*Act' | tail -1

say "\$ fm-control.sh $ID exit"
env "${FM_ENV[@]}" "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1; echo "exit verb exit=$?"
echo "--- pane command after exit ---"
"$REAL_TMUX" -L "$SOCKET" display -p -t "firstmate:fm-$ID" '#{pane_current_command}' 2>&1 || echo "(window gone)"

say "the operator's own ~/.cline settings after the whole run"
AFTER=$(cksum < "$OPERATOR_SETTINGS")
printf 'before=%s\nafter =%s\n' "$OP_BEFORE" "$AFTER"
[ "$OP_BEFORE" = "$AFTER" ] && echo "UNCHANGED (byte-identical)" || echo "CHANGED"
jq -c '{planActMode}' "$OPERATOR_SETTINGS"
