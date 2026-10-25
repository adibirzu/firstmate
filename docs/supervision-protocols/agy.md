Mode: agy (Antigravity CLI) Stop-hook-owned park.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. Routine watcher arm and re-arm are owned by the `Stop` hook (`bin/fm-turnend-guard-agy.sh`), never by you.
   agy runs that hook synchronously at the end of every loop, so every stop while supervision is needed parks on one home-scoped watcher cycle, with no model command and no model tokens spent while parked.
4. An actionable close wakes you as a continuation of the same loop, delivered as a system message carrying the `watcher` operational kind.
   On that wake, run `bin/fm-wake-drain.sh` first and handle it.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next stop parks again automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records, the drain's `OPEN DECISIONS` entries, or a real watcher reason line.
5. A `watcher checkpoint` continuation means the park window elapsed with no wake: drain, handle anything emitted, and end the turn so the next stop parks again.
6. On a `turn-end-guard` continuation, the park could not establish a live cycle.
   Inspect the watcher startup path rather than turning the notice into a repeating manual-arm loop; the nag is bounded by `FM_AGY_TURNEND_BLOCK_BUDGET` (default 3) and then stops on its own.
7. A `CEILING REACHED` notice means agy's forced-continuation chain is spent: automatic wake delivery stops until the captain's next message starts a fresh chain, and queued wakes stay durable, so drain them now.
8. Treat `watcher: started ...` and `watcher: attached ...` inside park output as proof that one live cycle exists.
9. The durable wake queue preserves actionable events between a continuation and the next park.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
10. Waiting on the hook-owned park is silent: do not send idle progress while the watcher is parked.

The hooks load only for a trusted workspace.
agy loads `.agents/hooks.json` after its folder-trust gate, so a primary started in this home for the first time must answer `Yes, I trust this folder`, or have been trusted ahead of launch; a hook set loaded by that answer misses the turn already under way.
`bin/fm-agy-trust.sh` pre-registers a task worktree, but a primary home is trusted by the captain's answer to that dialog.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the `Stop` hook runs as its own tracked child.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

agy ends a forced-continuation chain after ten continuations, so the hook bounds itself below that and [`turnend-guard.md`](../turnend-guard.md) owns the double loop bound, the supersession contract, and the compatibility limits.
`SessionStart` delivers the session-start digest, and `PreToolUse` on `run_command` denies watcher-arm and cwd-change anti-patterns (`bin/fm-arm-pretool-check.sh --agy`, `bin/fm-cd-pretool-check.sh --agy`).
