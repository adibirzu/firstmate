#!/usr/bin/env bash
# Operator walkthrough of the retired `fm-decision-hold` surface after the
# captain-hold collapse: the shim keeps working for one release, captain-hold
# owns the held task, and the fork's safety gates survive the merge.
set -u
ROOT=${1:?repo root}
SHIM="$ROOT/bin/fm-decision-hold.sh"
command -v tasks-axi >/dev/null || { echo "tasks-axi not found"; exit 1; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim-demo.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
HOME_DIR="$LAB/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/fakebin"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
for f in tmux no-mistakes gh gh-axi; do printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/fakebin/$f"; chmod +x "$HOME_DIR/fakebin/$f"; done

ORIGIN=sample-route-review
mkdir -p "$HOME_DIR/data/$ORIGIN"
tsk() { (cd "$HOME_DIR" && tasks-axi "$@"); }
shim() {
  PATH="$HOME_DIR/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$SHIM" "$@"
}
say() { printf '\n--- %s\n' "$*"; }
cmd() { printf '$ fm-decision-hold.sh %s\n' "$*"; }

tsk add "$ORIGIN" "Investigate sample routing" --kind scout --repo sample --start >/dev/null
cat > "$HOME_DIR/state/$ORIGIN.meta" <<EOF
window=firstmate:fm-$ORIGIN
worktree=$HOME_DIR/projects/missing-$ORIGIN
project=$HOME_DIR/projects/sample
harness=codex
kind=scout
mode=scout
EOF
printf 'done: report complete\n' > "$HOME_DIR/state/$ORIGIN.status"
printf '# Sample route review\n\nOne captain choice remains.\n' > "$HOME_DIR/data/$ORIGIN/report.md"

echo "=============================================================="
echo " fm-decision-hold compatibility shim over fm-captain-hold"
echo "=============================================================="

say "1. A pre-collapse brief still registers its decision through the old surface."
cmd "hold $ORIGIN route --title ... --reason ... --repo sample"
HOLD=$(shim hold "$ORIGIN" route --title "Choose north or south" --reason "captain route choice pending" --repo sample) \
  || { echo "hold failed"; exit 1; }
printf 'legacy identity -> %s\n' "$HOLD"
printf 'captain-hold now owns it:\n'
(cd "$HOME_DIR" && tasks-axi show "$HOLD" --full) | sed -n '1,12p' | sed 's/^/  /'

say "2. Follow-up work is durably blocked by the captain-held task."
tsk add ship-route "Ship the chosen route" --kind ship --repo sample >/dev/null
tsk block ship-route --by "$HOLD" >/dev/null
(cd "$HOME_DIR" && tasks-axi show ship-route --full) | grep -E '^ +(state|blocked|blocked_by):' | sed 's/^ */  /' 

say "3. Fork gate kept: decline WILL NOT release routed work."
printf 'Not deciding this now.\n' > "$LAB/decline.txt"
cmd "decline $ORIGIN route --decision-file decline.txt"
shim decline "$ORIGIN" route --decision-file "$LAB/decline.txt" 2>&1 | sed 's/^/  /'
printf '  (exit %s -- hold stays open, ship-route stays blocked)\n' "${PIPESTATUS[0]}"

say "4. Fork resolve order kept: record the captain's body, then unblock, then close."
printf 'Take the north route.\n' > "$LAB/decide.txt"
cmd "resolve $ORIGIN route --decision-file decide.txt --routed-to ship-route"
shim resolve "$ORIGIN" route --decision-file "$LAB/decide.txt" --routed-to ship-route 2>&1 | sed 's/^/  /'
printf '\n  captain-held task after resolve:\n'
(cd "$HOME_DIR" && tasks-axi show "$HOLD" --full) | sed -n '1,20p' | sed 's/^/    /'
printf '\n  routed work released:\n'
(cd "$HOME_DIR" && tasks-axi show ship-route --full) | grep -E '^ +(state|blocked|blocked_by):' | sed 's/^ */    /' 

say "5. Idempotent replay of the same resolve is accepted (no drift)."
cmd "resolve $ORIGIN route --decision-file decide.txt --routed-to ship-route   # replay"
shim resolve "$ORIGIN" route --decision-file "$LAB/decide.txt" --routed-to ship-route 2>&1 | sed 's/^/  /'

say "6. Fork gate kept: a spent identity cannot be reused for a new decision."
cmd "hold $ORIGIN route --title 'A different question' ...   # same key again"
shim hold "$ORIGIN" route --title "A different question" --reason "second captain choice" --repo sample 2>&1 | sed 's/^/  /'
printf '  (exit %s)\n' "${PIPESTATUS[0]}"

say "7. A different key is still available, and drifted routes are refused."
shim hold "$ORIGIN" route-two --title "Second route question" --reason "second captain choice" --repo sample | sed 's/^/  new hold -> /'
tsk add ship-other "Ship something else" --kind ship --repo sample >/dev/null
cmd "resolve $ORIGIN route-two --decision-file decide.txt --routed-to ship-other   # not blocked by the hold"
shim resolve "$ORIGIN" route-two --decision-file "$LAB/decide.txt" --routed-to ship-other 2>&1 | sed 's/^/  /'
printf '  (exit %s)\n' "${PIPESTATUS[0]}"
echo
echo "=============================================================="
