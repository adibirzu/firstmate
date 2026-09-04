Mode: OpenCode TUI plugin background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: let `.opencode/plugins/fm-primary-watch-arm.js` arm supervision after the OpenCode session goes idle.
3. The plugin listens for `session.idle`, spawns `bin/fm-watch-arm.sh --restart` without awaiting it in the idle handler, and owns every later successor launch.
4. After an actionable child close, the plugin rechecks session-lock ownership and verifies one singleton successor before it calls `client.session.promptAsync`; its bounded fallback is defined in `docs/watcher-continuity.md`.
5. Ordinary wake: do not ask the model to re-arm because continuity is plugin-owned.
   An empty cycle or another healthy watcher is attach/idle, not a model repair turn.
6. A failed child close (a real `watcher: FAILED` line, a signal, or a nonzero arm exit) enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
   An empty or healthy close re-arms through its own bounded silent retry.
   A watcher that established itself and outlived the cycle-lifetime floor (`FM_WATCH_ARM_ESTABLISHED_MS`, 60s) is a completed cycle: its close replenishes both retry budgets, so a long-running home keeps re-arming, while an instantly-empty watcher stays bounded.
   Idle cycles and failed closes are counted separately, and only a completed cycle resets the failure count, so empty closes between real failures cannot hide the failure.
   When the silent bound is exhausted the plugin stops without a model turn and appends one durable `check` record (`opencode-arm:idle-exhausted`) to `state/.wake-queue`; it is not repeated while unacknowledged, and `bin/fm-wake-drain.sh` is the only surfacing owner of that record - no arm cycle presents it.
   A retry that relaunches into a home that no longer needs a watcher, or that this session no longer owns, is benign and never prompts.
   The plugin arms on the same need as `bin/fm-supervision-lib.sh` (task metadata, an X-mode relay poll, or a registered process-event source); when it declines because it sees no need or this session does not own the lock, the turn-end guard plugin still runs the shell guard as the backstop.
7. Failure or missing cycle only: if the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `bin/fm-watch-arm.sh` manually only as a short recovery probe.
8. Never use shell `&` for watcher supervision.
   The arm mechanism above is plugin-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/fm-primary-pretool-check.js`, `bin/fm-arm-pretool-check.sh`).
9. Do not rely on this plugin in headless `opencode run`; firstmate primary supervision targets persistent OpenCode TUI sessions.

OpenCode's persistent TUI plugin runtime is the wake mechanism.
The plugin applies in the main primary checkout and a secondmate's own home, and stays silent only in child crewmate and scout worktrees.
That scope decision is `isArmEligibleRoot` in `.opencode/plugins/lib/fm-watch-arm-eligibility.js`, which mirrors the shell owner `bin/fm-primary-scope-lib.sh`; `docs/turnend-guard.md` owns the shared scope rules.
