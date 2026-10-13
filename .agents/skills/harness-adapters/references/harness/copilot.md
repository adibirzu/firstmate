## copilot (VERIFIED 2026-07-28, GitHub Copilot CLI 1.0.75)

GitHub Copilot CLI runs as a persistent interactive TUI crewmate. A positional
prompt (via `-i`) seeds AND auto-runs the first turn once the folder-trust
dialog is cleared, so the brief rides the launch command like claude/codex/
cline/cursor-agent.

| Fact | Value |
|---|---|
| Binary | `copilot` from `PATH` (`~/.local/bin/copilot`), a standalone stripped ELF executable, NOT a node/python script. `/proc/<pid>/comm` reports the runtime-internal thread name `MainThread` (consistent with a Bun-compiled single-file binary), never `copilot`/`node`/`python`; detection matches `copilot` in the process argv via a dedicated `MainThread` ancestry case. |
| Launch | `copilot --allow-all --no-ask-user [--model <id>] [--reasoning-effort <tier>] -i "<brief>"`. `-i, --interactive <prompt>` seeds and auto-runs once the trust dialog clears (verified via tmux capture). |
| Models | Enumerated live via `/model` or `copilot help config`: `claude-sonnet-5`, `claude-sonnet-4.6`, `claude-sonnet-4.5`, `claude-haiku-4.5`, `claude-fable-5`, `claude-opus-5`, `claude-opus-4.8[-fast]`, `claude-opus-4.7`, `claude-opus-4.6`, `claude-opus-4.5`, `gpt-5.6-sol`, `gpt-5.6-terra` (default), `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4`, `gpt-5.3-codex`, `gpt-5.4-mini`, `gpt-5-mini`, `gemini-3.1-pro-preview`, `gemini-3.6-flash`, `gemini-3.5-flash`, `kimi-k2.7-code`, plus `auto`. `--model` is validated before any API call (verified: a bogus id errors cleanly with exit 1). |
| Busy-pane signature | Rotating circle/quarter-phase spinner + literal `Working esc interrupt` (optionally with a ` · <size>` tool-output-size infix between the two words). Bare `esc interrupt` alone collides with opencode's own anchor, so the busy regex is the compound `Working.*esc interrupt` (`FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT`). |
| Exit command | `/exit` (verified rc 0). Double `Ctrl-C` from idle also exits (footer shows `ctrl+c again to exit`, reverting on its own if not repeated). |
| Interrupt | Single `Ctrl-C` mid-turn (`● Operation cancelled by user`; session survives). `Esc` is a no-op both mid-turn and idle — unlike cline (interrupt) or cursor-agent (dialog-quit) — it only does something inside a modal (trust dialog "No", `/model` picker cancel). |
| Autonomy | `--allow-all` (alias `--yolo`; identical, `--allow-all-tools --allow-all-paths --allow-all-urls`) is the targeted equivalent of claude's `--dangerously-skip-permissions`. `--no-ask-user` additionally disables the `ask_user` tool; a live underspecified-brief test did not stall without it, but it is shipped anyway as a zero-downside defensive addition (no attended human to answer it in a supervised pane). |
| **Trust dialog (blocking, GATED)** | Interactive mode on an untrusted directory shows a blocking `Confirm folder trust` dialog (`1. Yes` / `2. Yes, and remember` / `3. No (Esc)`). **`--allow-all` does NOT bypass it** (verified with the flag already in argv), and the untested `--add-dir` flag was probed (WI-4 T0) and also does NOT bypass it. `fm-spawn` wires a post-launch readiness gate (`copilot_wait_for_trust_clear`, invoked right after the launch `Enter`): while the dialog is present, send one default-focus `Enter` (session-scoped trust, option 1, "Yes"); once the pane reaches the busy footer or the idle status bar, proceed; on budget exhaustion (`FM_COPILOT_TRUST_POLLS`/`FM_COPILOT_POLL_INTERVAL`), fail the spawn loudly via `copilot_spawn_fail`. Deliberately **no pre-seed** of copilot's persistent trust allow-list, unlike cursor-agent's isolated per-project marker — copilot's only pre-seed target is a single shared, global, credential-bearing JSONC config file with no delegated writer and no config-dir override, so the keystroke-only mechanism gets the same guarantee with zero writes to the operator's home. See `docs/verification/copilot-adapter.md` § *Trust / permission gate* for the full options analysis and the S4 reversal procedure (trivial: nothing is ever written). |
| Submission | A seeded `-i` prompt auto-submits once trust clears; typing then Enter can require a second Enter in practice (observed intermittently when injecting text into an already-running session — not yet root-caused, possibly bracketed-paste/debounce related). |
| Environment marker | `COPILOT_CLI=1`, set for copilot-spawned child processes (verified) — the harness-detection Layer-1 marker, alongside `CLAUDECODE`/`PI_CODING_AGENT`/`GROK_AGENT`. |
| Composer | Bare agent glyph `❯` (U+276F) — the exact same codepoint already verified for claude in the shared classifier; no new glyph needed. **No idle placeholder text of any kind was observed** (first-ready and post-turn composer rows are byte-identical: just the glyph, nothing else) — unlike cline/cursor-agent, so no `FM_COMPOSER_IDLE_RE_DEFAULT` addition was needed. |
| Effort | Maps to `--reasoning-effort <none\|minimal\|low\|medium\|high\|xhigh\|max>` — the fullest vocabulary of any adapter (verified via `--help` AND a zero-quota pre-flight validation probe). firstmate's shared `low\|medium\|high\|xhigh\|max` axis is a full subset; no tier is omitted. |
| TTY | Interactive mode needs a pty; supervise only through a pane. |

Turn-end is observed from the pane, not a hook: the `Working.*esc interrupt`
spinner/footer clears and the composer returns to its bare `❯` idle glyph.
copilot is not wired for secondmate launches, so no `backends/tmux.sh`
agent-process liveness entry is required yet, matching cline/cursor-agent
precedent. The folder-trust readiness gate (WI-4) is now wired, so a spawn
into a genuinely fresh worktree at any path reaches a ready/working pane
without human interaction, or fails loudly within the poll budget instead of
hanging — a live end-to-end dispatch through the herdr backend is still
deferred (matching the cline/cursor-agent precedent) but is no longer
blocked on this gate.

Full empirical capture evidence: `../../../docs/verification/copilot-adapter.md`.
