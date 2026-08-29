#!/usr/bin/env bash
# End-user demo: does a secondmate home running OpenCode arm its own watcher?
#
# Builds the production topology reported broken on 2026-08-28 (tms-captain /
# hosp-captain): a treehouse-leased LINKED git worktree carrying a valid
# .fm-secondmate-home marker, plus a markerless crewmate task worktree as the
# control. Loads the real OpenCode plugin exactly as OpenCode loads it, fires a
# real session.idle event, and reports what the operator observes: whether the
# watcher arm actually launched.
#
# usage: opencode-secondmate-arm-demo.sh <firstmate-tree> <label>
set -u
TREE=$1; LABEL=$2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-arm-demo-XXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=fmdemo GIT_AUTHOR_EMAIL=fmdemo@example.invalid
export GIT_COMMITTER_NAME=fmdemo GIT_COMMITTER_EMAIL=fmdemo@example.invalid

base="$WORK/captain-repo"
git init -q "$base"; git -C "$base" commit -q --allow-empty -m init

make_worktree() { # <dir> <branch>
  git -C "$base" worktree add -q -b "$2" "$1" >/dev/null 2>&1
  mkdir -p "$1/bin" "$1/state" "$1/config"; : > "$1/AGENTS.md"; : > "$1/state/task.meta"
  cat > "$1/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'ARMED root=%s\n' "${FM_ROOT_OVERRIDE:-}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=%s (beacon 0s)\n' "$$"
SH
  chmod +x "$1/bin/fm-watch-arm.sh"
}

sm="$WORK/tms-captain";  make_worktree "$sm" demo/secondmate-home
printf 'tms-captain\n' > "$sm/.fm-secondmate-home"
crew="$WORK/crew-task";  make_worktree "$crew" demo/crewmate-task

drive() { # <dir> <log>
  PLUGIN="$TREE/.opencode/plugins/fm-primary-watch-arm.js" WT="$1" FM_ARM_LOG="$2" \
  node - <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimaryWatchArm({
  client: { session: { promptAsync: async () => {} } },
  directory: process.env.WT, worktree: process.env.WT,
});
writeFileSync(`${process.env.WT}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "demo-session" } } });
for (let i = 0; i < 150 && !existsSync(process.env.FM_ARM_LOG); i += 1)
  await new Promise((s) => setTimeout(s, 20));
EOF
}

report() { # <label> <dir> <log> <expected>
  local shellverdict plugverdict
  if ( . "$TREE/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$2" "$2/state" ); then
    shellverdict="IN  (every shell hook supervises this root)"
  else
    shellverdict="OUT (shell hooks scope this root out)"
  fi
  if [ -s "$3" ]; then plugverdict="watcher ARMED   -> $(head -1 "$3")"
  else plugverdict="NO WATCHER ARMED -> supervision silently off"; fi
  printf '  %-22s shell owner: %s\n' "$1" "$shellverdict"
  printf '  %-22s opencode   : %s\n' "" "$plugverdict"
  printf '  %-22s expected   : %s\n\n' "" "$4"
}

echo "=== $LABEL ==="
echo "firstmate tree: $TREE"
echo
drive "$sm"   "$WORK/sm.log"
drive "$crew" "$WORK/crew.log"
echo "secondmate home (treehouse-leased LINKED worktree + valid marker)"
report "tms-captain" "$sm" "$WORK/sm.log" "watcher ARMED (it runs its own primary session)"
echo "crewmate task worktree (markerless LINKED worktree) - control"
report "crew-task" "$crew" "$WORK/crew.log" "NO WATCHER ARMED (child worktrees stay silent)"
