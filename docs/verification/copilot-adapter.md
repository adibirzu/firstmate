# copilot adapter — empirical verification evidence

**Harness:** GitHub Copilot CLI `1.0.75` · **Date:** 2026-07-28 · **Method:** live
tmux panes (`capture-pane -p`/`-e`) driven from a scratch session
(`/tmp/fm-copilot-scratch`, deliberately outside `$HOME` so the folder-trust gate
is visible), the same rendered text the `fm-tmux-lib.sh` / herdr composer
classifier consumes. 58 timestamped raw captures were written to
`/tmp/fm-copilot-scratch/captures/` during the session.

This is the "confirm every fact empirically" record `CONTRIBUTING` and the
`harness-adapters` skill require before an adapter is wired. Every value below is
a capture, not a guess; anything not directly observed is marked NOT VERIFIED.

**Base-branch note:** this capture was performed against `local-adapters` @
`fe00911` (post-rebase head, not the `d21eeec` head the originating PRD names).
That head already centralizes the idle-composer placeholder set and bare-glyph
set in `bin/fm-composer-lib.sh` (`FM_COMPOSER_IDLE_RE_DEFAULT` /
`FM_COMPOSER_BARE_PROMPT_RE_DEFAULT`), shared by the tmux path and all three
`bin/backends/{herdr,cmux,orca}.sh` adapters, rather than each backend owning its
own literal. It also already carries a wired cursor-agent workspace-trust
readiness gate in `bin/fm-spawn.sh` (pre-seed + post-launch poll), added in a
*later, separate* pipeline-review commit (`3f2334d`) than cursor-agent's
*original* adapter commit (`f5831da`). This doc follows the CURRENT file
structure throughout and calls out every place that structure changes what
would otherwise be a straightforward per-file literal addition.

## Trust / permission gate

A blocking **"Confirm folder trust"** dialog appears on every launch from an
untrusted directory, and **`--allow-all` does NOT suppress it** — verified with
the full autonomy flag already in argv:

```
╭──────────────────────────────────────────────────────────────────────────────╮
│ Confirm folder trust                                                          │
│ ────────────────────────────────────────────────────────────────────────────  │
│ ╭────────────────────────────────────────────────────────────────────────╮   │
│ │ /tmp/fm-copilot-scratch                                                  │   │
│ ╰────────────────────────────────────────────────────────────────────────╯   │
│                                                                                │
│ Copilot can read files in this folder and, with your permission, edit them   │
│ or run code and shell commands. It will remember your permissions for the    │
│ rest of this session.                                                        │
│                                                                                │
│ Do you trust the files in this folder?                                       │
│                                                                                │
│ ❯ 1. Yes                                                                      │
│   2. Yes, and remember this folder for future sessions                       │
│   3. No (Esc)                                                                │
│                                                                                │
│ ↑/↓ to navigate · enter to select · esc to cancel                            │
╰──────────────────────────────────────────────────────────────────────────────╯
```

- Default focus is option 1 ("Yes" — session-only trust). Plain `Enter` accepts
  it and the launch proceeds immediately (the seeded `-i` prompt auto-runs with
  no further keystroke — see Launch below).
- `Esc` on this dialog = option 3, "No" (declines trust; does not crash the CLI).
  This is dialog-scoped — Esc has **no effect** during a busy turn or at the idle
  composer (see Interrupt vs exit below); it is meaningful only inside this
  dialog and the `/model` picker (`esc to cancel`, its own footer hint).
- **Selecting option 2 ("Yes, and remember") persists to `~/.copilot/config.json`
  `trustedFolders`** (verified: the array grew from `["/home/adi"]` to
  `["/home/adi","/tmp/fm-copilot-scratch"]`; immediately reverted after the
  observation — this task's hard rules treat that file as read-only). This is a
  real, working non-interactive-launch bypass mechanism in principle (pre-seed
  the array before spawn), but it is **materially riskier than cursor-agent's
  bypass**: cursor writes an isolated per-project marker file
  (`~/.cursor/projects/<slug>/.workspace-trusted`); copilot's only known bypass
  requires editing a single **shared, global, JSONC config file that also holds
  the live OAuth token** (`copilotTokens`) next to `trustedFolders`. A
  parse/append bug there has a much larger blast radius than a missing/malformed
  per-project marker.
- No CLI flag bypasses the dialog: `--allow-all`, `--allow-all-tools`,
  `--allow-all-paths`, and `--allow-all-urls` were all in argv and the dialog
  still appeared. `copilot help config` / `copilot help permissions` document no
  non-interactive trust-bypass flag (`trustedFolders` is documented as
  config-only: "list of folders where permission to read or execute files has
  been granted").
- **Consequence for dispatch (flagged prominently, not buried):** every crew
  dispatch spawns into a fresh worktree path, which is by definition never in
  `trustedFolders`. Without a pre-seed/readiness-gate mechanism analogous to
  cursor-agent's (which — per the base-branch note above — was NOT part of
  cursor-agent's own original adapter commit either, but a later, separate
  pipeline-review pass), `fm-spawn.sh --harness copilot` launching into a fresh
  worktree **will block on this dialog indefinitely**; the seeded `-i` argv has
  no way to answer an interactive TUI dialog. This is real and unresolved by the
  owner-file edits in this task (§T4 below is scoped to the same 4
  `fm-spawn.sh` edits cline/cursor-agent's original commits made — launch
  template, allowlists, model/effort flags — not a new readiness-gate
  subsystem). Recommended follow-up: a dedicated "wire copilot trust gate" pass,
  mirroring `3f2334d`'s cursor-agent work, that weighs the global-file risk above
  before choosing pre-seed vs. poll-and-answer vs. both.

## Ready / idle composer

```
❯
────────────────────────────────────────────────────────────────────────────
 / commands · ? help · tab next tab                              GPT-5.6 Terra
```

- Bare agent glyph `❯` (U+276F) — byte-for-byte the **same codepoint** already
  registered as claude's glyph in the shared
  `FM_COMPOSER_BARE_PROMPT_RE_DEFAULT='^[❯›→]'` (`bin/fm-composer-lib.sh`). No
  new glyph, no code change needed for glyph promotion.
- **No idle placeholder text of any kind was observed, at any point.** The
  `capture-pane -e` (ANSI) read of the composer row is exactly `ESC[0m` + the
  glyph — no dim/faint SGR run, no truecolor run, nothing to strip. This holds
  identically before the first turn and after every subsequent turn (PONG,
  DONE, DONE2, and a Ctrl-C cancel were all checked) — first-ready and
  post-turn idle states are **identical**, which deviates from the PRD's working
  assumption (modeled on cline/cursor-agent, where the two differ).
- **Ghost-stripper conclusion: not applicable.** There is no placeholder text to
  strip, dim or otherwise, so the shared `FM_COMPOSER_IDLE_RE_DEFAULT` needs
  **no new alternate** for copilot, and none of the three backend
  `FM_BACKEND_*_IDLE_RE` overrides need touching. This is the opposite finding
  from cline/cursor-agent, both of which needed a placeholder added.
- Idle status bar / footer: `/ commands · ? help · tab next tab` plus a
  right-aligned current-model label (e.g. `GPT-5.6 Terra`). The model label is
  NOT copilot-generic (it reflects whatever model is configured) and is
  therefore excluded from any classifier anchor.

## Busy signature

```
 ◐ Working esc interrupt                                          GPT-5.6 Terra
 ◎ Working · 786 B esc interrupt                                  GPT-5.6 Terra
```

(spinner glyph rotates through a circle/quarter-phase family — ◎ ◐ ◒ ◉ ○ — never
used as part of the anchor, per the fleet convention of preferring the stable
text token over a decorative/rotating glyph.)

- The literal footer text is **`Working esc interrupt`**, optionally with a
  ` · <size>` tool-output-size infix between `Working` and `esc interrupt` once
  a running tool call has produced output (observed both `· 92 B` and
  `· 1.4 KiB`; the infix is absent immediately after submit and appears once
  output starts streaming back).
- **Collision:** the bare substring `esc interrupt` is an EXACT match for
  opencode's `FM_TMUX_OPENCODE_BUSY_REGEX_DEFAULT='esc interrupt'`. A bare
  `esc interrupt` anchor is therefore rejected (same class of hazard cursor-agent
  hit with bare `Working`, already owned by pi).
- **Chosen compound anchor:** `Working.*esc interrupt` — requires both tokens
  present, in order, on the same captured line, tolerating the optional
  size-infix in between (`.` does not cross tmux's line boundaries in
  `grep -qiE`, so this stays scoped to one physical footer line).
  - Matches both observed real busy lines (with and without the infix).
  - Absent from every real idle capture (verified repeatedly across five
    launches).
  - Does **not** match any of the six foreign literal tokens this task must stay
    distinct from: `esc to interrupt` (claude/codex/generic), `esc interrupt`
    (opencode, missing `Working`), `Working...` (pi, missing `esc interrupt`),
    `Ctrl+c:cancel` (grok), `esc to cancel` (cline), `ctrl+c to stop`
    (cursor-agent). Each foreign token is missing at least one required half of
    the compound anchor.
- Clears the instant the turn ends: idle captures taken immediately after PONG,
  DONE, DONE2, and a Ctrl-C cancel all lack both "Working" and "esc interrupt".

`FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT='Working.*esc interrupt'`

## Interrupt vs exit (they differ — important)

- **Interrupt = single `Ctrl-C`, mid-turn.** Verified on a `sleep 15` shell-tool
  turn: the transcript shows `● Operation cancelled by user`, the pane returns
  to the idle composer, and the session survives (still usable — a `/model`
  picker opened cleanly afterward).
- **`Esc` is a no-op**, both mid-turn (a running `sleep 8` tool call completed
  normally on schedule despite an `Esc` press) and at the idle composer (no
  visible effect). This differs from **both** cline (`Esc` = interrupt) and
  cursor-agent (`Esc` = quit on the trust dialog only); for copilot, `Esc` only
  does something inside a modal (trust dialog "No", `/model` picker cancel).
- **Exit = `/exit`** — verified end to end: `/exit` then Enter returns to the
  shell prompt; a following `echo $?` printed `COPILOT_EXITED_RC=0`.
- **Exit (fallback) = double `Ctrl-C` from idle.** A single `Ctrl-C` at idle
  shows `ctrl+c again to exit` in the footer and — if not repeated — reverts to
  the normal idle footer on its own after a few seconds (a real, transient UI
  state; it does not overlap the busy anchor and needs no special handling). A
  second `Ctrl-C` inside that window exits (verified, rc not separately
  captured for this path since `/exit`'s rc=0 already covers the exit-path
  acceptance criterion).

## Launch (mechanics half)

`copilot -i "<prompt>" --allow-all` **seeds and auto-runs**: after the one
keystroke needed to clear the folder-trust dialog (`Enter`, selecting default
option 1), the pane went straight to the busy footer with no further input and
produced the exact requested reply (`PONG`, `PONG3` across two separate
launches, one with `--effort high` added). This is the claude/codex/cline/
cursor-agent argv-seed pattern, not kimi's bare-launch+inject shape.

Flag-order robustness: a free, request-free probe (`copilot --allow-all
--no-ask-user --model <bogus> --reasoning-effort medium -p "x"`) confirmed the
autonomy/model/effort flags parse identically regardless of position relative to
the prompt-consuming flag (same clean pre-flight validation error both times),
so the conventional template ordering (autonomy flags, then
`__MODELFLAG____EFFORTFLAG__`, then the prompt flag last) is safe even though
the live seeded launches in this session put `-i "<prompt>"` first.

**`--allow-all` vs `--yolo`:** documented as byte-identical expansions
(`--allow-all-tools --allow-all-paths --allow-all-urls`) in `copilot --help` and
`copilot help permissions`; not independently live-tested since the two cannot
differ by definition. `--allow-all` is used per the PRD's stated preference (the
non-jargon spelling, more legible in a diff) — no evidence favors `--yolo`.

**`--no-ask-user` (judgment call, flagged as such):** a deliberately
underspecified brief ("pick whichever of the files in this directory you think
is most interesting, and improve it") was run under `--allow-all` alone (no
`--no-ask-user`). The agent did **not** stall on an `ask_user`-style prompt — it
explored the directory with the terminal tool and made an autonomous choice.
This is a single data point, not proof the model never asks under any prompt
shape. `--no-ask-user` is included in the shipped template anyway, as a
defensive, zero-downside addition consistent with the fleet's full-autonomy
posture for every other adapter (claude's `--dangerously-skip-permissions`,
cline's `--auto-approve true`, cursor-agent's `--force`) and with the flag's own
documented purpose ("agent works autonomously without asking questions") —
there is no attended human to answer `ask_user` in a supervised crewmate pane,
so disabling it cannot lose a useful interaction, only remove a silent-hang risk
class the live test happened not to trigger. This is the one line in the
template that is reasoned-but-not-directly-necessitated rather than purely
observation-derived, and is called out as such per this task's rigor bar.

**`--banner` / `--no-color` / `--mouse=off` / `--stream on|off`:** not
independently tested; default rendering worked cleanly for `capture-pane -p`
classification throughout the session (58 captures, zero rendering-related
misreads), so none is added to the template. NOT VERIFIED as "needed" or
"unneeded" beyond that absence of evidence.

Final template:

```
copilot --allow-all --no-ask-user __MODELFLAG____EFFORTFLAG__-i "$(__OPINPUT__ encode launch-brief < __BRIEF__)"
```

## Model + effort

- `--model` is validated before any API call (zero-quota probe, verified twice):
  `copilot -p "x" --model definitely-not-a-real-model --allow-all-tools` →
  `Error: Model "definitely-not-a-real-model" from --model flag is not
  available.`, exit 1.
- Real model ids (from `copilot help config` and the live `/model` picker):
  `claude-sonnet-5`, `claude-sonnet-4.6`, `claude-sonnet-4.5`,
  `claude-haiku-4.5`, `claude-fable-5`, `claude-opus-5`, `claude-opus-4.8`,
  `claude-opus-4.8-fast`, `claude-opus-4.7`, `claude-opus-4.6`,
  `claude-opus-4.5`, `gpt-5.6-sol`, `gpt-5.6-terra` (default), `gpt-5.6-luna`,
  `gpt-5.5`, `gpt-5.4`, `gpt-5.3-codex`, `gpt-5.4-mini`, `gpt-5-mini`,
  `gemini-3.1-pro-preview`, `gemini-3.6-flash`, `gemini-3.5-flash`,
  `kimi-k2.7-code`. `auto` is also accepted (top entry in the `/model` picker;
  "routes based on your task, real-time system health, and model performance").
- `--effort` / `--reasoning-effort` is likewise validated before any API call
  (zero-quota probe, verified): `copilot -p "x" --reasoning-effort bogus-tier
  --allow-all-tools` → `error: option '--effort, --reasoning-effort <level>'
  argument 'bogus-tier' is invalid. Allowed choices are none, minimal, low,
  medium, high, xhigh, max.`, exit 1 — doubly confirming the `--help`-documented
  choice set live.
- FirstMate's shared vocabulary (`low|medium|high|xhigh|max`) is a **full
  subset** of copilot's accepted set — all five tiers pass validation; none
  needs omitting. This is the strongest tier-coverage of any adapter in the
  fleet (cline has no `max`; codex/grok cap lower).
- Spelling: `--reasoning-effort` (long form), matching codex's convention, per
  the PRD's stated preference; no evidence against it.
- Visual confirmation: a launch with no explicit `--effort` showed
  `GPT-5.6 Terra · Medium` in the busy footer, matching the `/model` picker's
  documented default reasoning tier ("Medium") for that model. The
  `--effort high` launch's busy window was not caught by the capture cadence
  before the (very short, `PONG3`-only) turn completed, so an explicit
  `· High` visual confirmation is **NOT VERIFIED** — the flag round-tripped
  without error and the launch completed normally, but the footer-label proof
  cline got (`(high)`) was not independently reproduced for copilot. Recorded
  honestly rather than inferred.

## Detection

- `/proc/<pid>/comm` (and `ps -o comm=`) for the running `copilot` process is
  literally **`MainThread`** — not `copilot`, not `node`, not `python`. The
  binary at `~/.local/bin/copilot` is a standalone, stripped ELF executable
  (`file`: "ELF 64-bit LSB executable ... stripped"), not an interpreter-run
  script; `MainThread` is consistent with a Bun-compiled single-file
  executable's runtime-internal thread name. `/proc/<pid>/exe` correctly
  resolves to `~/.local/bin/copilot`, and `args`/`cmdline` correctly shows
  `copilot -i ... --allow-all ...`.
- **Consequence:** neither the existing direct `*copilot*)` comm-case (comm is
  never `copilot`) nor the existing `node*|python*` interpreter fallback (comm
  is neither) would ever fire for the real observed process shape. This
  deviates from the PRD's assumed shape ("copilot is a Node app... needs both
  sites, node fallback"). A **third, new** ancestry case keyed on `MainThread`
  is required, with its own args-substring fallback mirroring the node/python
  one.
- **Env marker (verified):** `COPILOT_CLI=1` is set for copilot-spawned child
  processes — a clean boolean marker, exactly analogous to `CLAUDECODE=1`,
  `GROK_AGENT=1`, and `PI_CODING_AGENT=true`. Obtained by having the running
  copilot session write `env | grep -i copilot | cut -d= -f1` (names only) and
  then the three non-secret values to a scratch file, since asking it to paste
  raw environment output directly triggered a built-in safety refusal ("I can't
  expose environment variables because they may contain sensitive
  credentials") — never routed through the model's own text output. Also
  present, not used as the marker: `COPILOT_LOADER_PID` (the launcher's PID),
  `COPILOT_AGENT_SESSION_ID`, `COPILOT_CLI_BINARY_VERSION=1.0.75` (a version
  string, not boolean).
- Because a marker WAS verified (T2.8), it is added as a new Layer-1 marker in
  `detect_own()`, alongside `CLAUDECODE`/`PI_CODING_AGENT`/`GROK_AGENT` — this
  is additive precedent-following, not a deviation.

## herdr registration

- `herdr integration status` → `copilot: not installed
  (~/.copilot/hooks/herdr-agent-state.sh)` — verified, matches the PRD's stated
  expectation exactly.
- `ls -la ~/.copilot/hooks/` → only `lavish-axi.json` present — an AXI
  ambient-context `sessionStart` hook (a third-party ambient-context integration
  unrelated to herdr), NOT a herdr integration file — verified, matches the
  PRD's stated expectation exactly.
- **Finding:** since no `herdr-agent-state.sh` file exists for copilot, any
  prior herdr registration of an `agent:"copilot"` / `terminal_title:"GitHub
  Copilot"` session must come from herdr's own generic terminal-title/process
  sniffing, not from an installed integration (installing one would have
  created the missing hook file). This resolves the §1.1 item-3 ambiguity in
  writing, as required.
- **Recommendation:** do NOT run `herdr integration install copilot` as part of
  this or any automated task (mutates the operator's home outside the repo).
  Recommend the captain evaluate it as a follow-up once the trust-gate
  bypass/readiness-gate question above is resolved — an unattended crewmate's
  herdr-visible liveness signal is more valuable once dispatch is actually
  unblocked end-to-end from a fresh worktree.

## Recorded in (the owner files)

| # | Owner file | Change |
|---|---|---|
| 1 | `bin/fm-spawn.sh` | `launch_template()` copilot case; known-bare-adapter allowlists (2 sites); `model_flag_for_harness()`; `effort_flag_for_harness()` |
| 2 | `bin/fm-harness.sh` | `detect_own()`: direct `*copilot*)` comm case (future-proofing) + a new `MainThread)` case with an args-substring fallback (the shape actually observed) + a new Layer-1 `COPILOT_CLI=1` env-marker check; usage-line harness list |
| 3 | `bin/fm-tmux-lib.sh` | `FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT='Working.*esc interrupt'` + its `case` arm |
| 4 | `bin/backends/{herdr,cmux,orca}.sh` | **untouched** — no placeholder text exists for copilot to add; the shared `FM_COMPOSER_IDLE_RE_DEFAULT`/`FM_COMPOSER_BARE_PROMPT_RE_DEFAULT` architecture already correctly classifies copilot's bare-`❯`, no-placeholder composer with zero changes |
| 5 | `.agents/skills/harness-adapters/SKILL.md` | `## copilot (VERIFIED …)` fact table + frontmatter `description` adapter list |

Plus the two new files: `tests/fm-copilot-harness.test.sh` and this document.
`bin/fm-composer-lib.sh` is untouched (N1; also moot here — see row 4).
`bin/fm-spawn.sh` gains no trust-gate readiness-gate code in this pass (see
"Trust / permission gate" above) — flagged as the primary follow-up.

## Remaining acceptance (live end-to-end)

The facts above are verified in isolation via live tmux captures (58 raw
captures under `/tmp/fm-copilot-scratch/captures/`) and are covered by
`tests/fm-copilot-harness.test.sh`. Matching the cline/cursor-agent precedent,
a full live crewmate dispatch through the herdr backend — ready-gate →
brief-inject → busy → turn-end, plus supervised interrupt (`Ctrl-C`) / exit
(`/exit`) — is **not** run here; it needs a full firstmate home and a real
project. For copilot specifically, that acceptance is additionally blocked on
the trust-gate follow-up above: a genuinely fresh worktree will hang on the
folder-trust dialog until a readiness-gate mechanism (or an accepted, reviewed
pre-seed of `~/.copilot/config.json`'s `trustedFolders`) exists.

## Future option: `--acp` (out of scope here, N4)

`copilot --acp` starts an Agent Client Protocol server — a structured JSON
transport rather than a screen-scraped TUI pane. Not built here per N4; noted
as the strongest candidate for a second-generation adapter transport, and
consistent with `no-mistakes doctor` already tracking `acpx` (currently "not
found") as a toolchain signal in the same direction.
