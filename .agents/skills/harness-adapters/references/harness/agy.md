## agy (VERIFIED 2026-08-01, Antigravity CLI 1.1.9)

agy runs as a persistent interactive TUI crewmate (product name: Antigravity CLI).
A `-i` / `--prompt-interactive` prompt seeds AND auto-runs the first turn once the project-trust dialog is cleared, so the brief rides the launch command like claude/codex/grok rather than needing kimi's bare launch plus injected pointer.

| Fact | Value |
|---|---|
| Binary | `agy` from `PATH` (`~/.local/bin/agy`, standalone Mach-O). Detection matches `agy` in process ancestry and the env marker below. |
| Launch | `agy --dangerously-skip-permissions [--model <id>] [--effort <low\|medium\|high>] -i "<brief>"`. `-i` seeds and auto-runs once trust clears (verified via tmux capture). |
| Models | `agy models` lists effort-baked ids such as `gemini-3.6-flash-{low,medium,high}`, `gemini-3.5-flash-*`, `gemini-3.1-pro-{high,low}`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium`. |
| Model / effort interaction | Base model (e.g. `gemini-3.6-flash`) **requires** `--effort`. Baked suffix alone works. Matching baked + `--effort` works. Conflicting baked + `--effort` fails closed (`conflicts with --effort=...`). Preferred firstmate form: base model + `--effort`. Ceiling is `high`. firstmate resolves its shared `xhigh`/`max` tiers against the model id: a BASE id clamps to `--effort high`, because a base id with no `--effort` refuses to launch and the spawn would only surface that as a trust-gate timeout; an id that already bakes `-low`/`-medium`/`-high` gets NO effort flag, because it launches alone and a non-matching `--effort` fails closed. |
| Busy-pane signature | Braille spinner + `Generating...` / `Running...` mid-turn; stable footer token `esc to cancel` (clears the instant the turn ends). Idle footer is `? for shortcuts`. agy owns its own constant and harness-scoped matcher case (`FM_TMUX_AGY_BUSY_REGEX_DEFAULT`) and never borrows another harness's signature. No semantic task-state writer is wired yet, so this is delivery busy only and task-state classification stays `unknown` until a lifecycle source is credited. |
| Exit command | `/exit` (verified rc 0). Prints `Resume with -c (or command below):` and `agy --conversation=<uuid>`. |
| Interrupt | Single `Esc` mid-turn; body shows `Interrupted · What should Antigravity CLI do instead?`; session survives. |
| Autonomy | `--dangerously-skip-permissions` auto-approves tool permission prompts (does **not** bypass project trust). |
| **Trust dialog (blocking, GATED)** | Interactive mode on an untrusted directory shows `Do you trust the contents of this project?` (`Yes, I trust this folder` / `No, exit`). Default focus is Yes; one `Enter` accepts it and **persists** the path into `~/.gemini/antigravity-cli/settings.json` `trustedWorkspaces` (verified). `fm-spawn` wires a post-launch readiness gate only (no pre-seed of that operator-global settings file): while the dialog is present, send one Enter; once `esc to cancel` or `? for shortcuts` appears, proceed; on budget exhaustion, fail the spawn loudly. Past-trust deliberately does **not** use the substring `Antigravity CLI` because that text also appears inside the dialog body. |
| Submission | Seeded `-i` prompt auto-submits once trust clears; typing then Enter submits follow-ups. |
| Environment marker | `ANTIGRAVITY_AGENT=1` on child/tool processes (verified with clean `env -i` launch). Checked **before** `CLAUDECODE` in `fm-harness.sh` so an agy worker is never misread as claude. |
| Composer | Bordered box with bare `>` prompt glyph; **no idle placeholder text** observed. Bordered `>` already reads empty in the shared classifier; no `FM_COMPOSER_IDLE_RE_DEFAULT` addition. |
| Resume | `agy --conversation <id>` or `agy -c` / `--continue` (most recent for cwd). |
| TTY | Interactive mode needs a pty; supervise only through a pane. |
| Skill invocation | Not separately verified beyond natural language; use natural language if the exact slash skill form is uncertain. |

Turn-end is observed from the pane, not a hook: the `esc to cancel` footer clears and the composer returns to `? for shortcuts`.
agy is not wired for secondmate launches, so it carries no `backends/tmux.sh` agent-process liveness entry; a live agy secondmate would classify `ambiguous` on every session start, which is why the combination is refused rather than left readable-in-name-only.
`fm-spawn.sh` enforces that: a `--secondmate` spawn resolving to `agy` (bare name, `--harness=`, or the `config/secondmate-harness` chain) refuses before endpoint creation, and `fm-bootstrap.sh`'s secondmate liveness sweep does not treat agy's `dead`/`missing` readings as recovery-grade.

Full empirical capture evidence: `../../../docs/verification/agy-adapter.md`.
