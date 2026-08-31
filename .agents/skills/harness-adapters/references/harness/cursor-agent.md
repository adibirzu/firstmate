## cursor-agent (VERIFIED 2026-07-27, Cursor CLI 2026.07.16 / 2026.07.23)

cursor-agent runs as a persistent interactive TUI crewmate. A positional prompt seeds AND auto-runs the first turn (after the workspace-trust gate is cleared), so the brief rides the launch command like claude/codex/cline.

| Fact | Value |
|---|---|
| Binary | `cursor-agent` from `PATH` (`~/.local/bin/cursor-agent`, a Node app). Detection matches `cursor` in the process argv. |
| Launch | `cursor-agent --force [--model <id>] "<brief>"`. `--force` (= status-bar "Run Everything") makes the crewmate autonomous. The default `agent` subcommand is the persistent TUI; a positional prompt seeds and auto-runs once trust is cleared. |
| Models | `--model gpt-5 \| sonnet-4-thinking \| 'claude-opus-4-8[context=1m,effort=high,fast=false]'`. Effort is a MODEL bracket parameter, NOT a standalone flag — so fm-spawn passes `--model` only, no effort flag. |
| Busy-pane signature | Braille spinner + `Working` + composer hint `ctrl+c to stop` (present only mid-turn). `ctrl+c to stop` is the anchor (`FM_TMUX_CURSOR_AGENT_BUSY_REGEX_DEFAULT`); bare `Working` is NOT used because pi owns `Working...`. |
| Exit command | `/quit` (slash popup + Enter) — verified to exit cleanly. Ctrl-C and Esc do NOT exit an idle session (Esc only quits the pre-session trust dialog). |
| Interrupt | `Ctrl-C` mid-turn (the busy footer shows `ctrl+c to stop`). |
| Autonomy | `--force` (alias `--yolo`); status bar reads `Run Everything`. `--auto-review` is the softer classifier mode (not used for unattended crew). |
| **Workspace trust (blocking)** | Interactive mode shows a blocking `⚠ Workspace Trust Required` dialog (`[a] Trust / [q] Quit`). **`--trust` does NOT bypass it — it only works with `--print`/headless.** Two verified bypasses: (1) pre-seed `~/.cursor/projects/<path-slug>/.workspace-trusted` = JSON `{"trustedAt":"<iso8601>","workspacePath":"<abs path>"}` before launch (path-slug = abspath, drop leading `/`, `/`→`-`, with a length-cap+hash variant for long paths); (2) send `a` after the readiness gate detects the dialog. A pre-seeded marker was verified to skip the dialog entirely. `fm-spawn` wires both: it pre-seeds the marker before launch and its readiness gate answers a residual dialog with `a`, failing the spawn loudly instead of hanging. |
| Composer | Bare agent glyph `→` (U+2192) with idle placeholder `Plan, search, build anything` (first ready) / `Add a follow-up` (post-turn). `→` is a verified AGENT glyph in the shared classifier and bare-row promotion set (`fm-composer-lib.sh`: `FM_COMPOSER_BARE_PROMPT_RE_DEFAULT`), so the unbordered composer row is structurally recognized on every backend, and the idle placeholders read empty via the shared `FM_COMPOSER_IDLE_RE_DEFAULT` (the glyph-prefixed alternates). A dead shell (`>` `$` `%` `#`) still never promotes. |
| TTY | Interactive mode needs a pty; supervise only through a pane. |
| Auth | `cursor-agent login` (browser/device; set `NO_OPEN_BROWSER=1` on a headless box) or `--api-key`/`CURSOR_API_KEY` (the `api-key-env` account method). Verified logged-in as a Cursor account. |

The trust gate is the one integration a cursor CREWMATE needs beyond the registry facts above, and `fm-spawn` wires it: the spawn pre-seeds `.workspace-trusted` before launch and its post-launch readiness gate answers a residual dialog with `a` (once), failing the spawn instead of hanging when the pane never reaches a ready/working signal. A full live crewmate dispatch through the herdr backend is the remaining acceptance step (needs a full firstmate home). cursor is not wired for secondmate launches, so no `backends/tmux.sh` liveness entry is required yet.

Full empirical capture evidence: `../../../docs/verification/cursor-agent-adapter.md`.
