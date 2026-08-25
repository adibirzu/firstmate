# cline adapter — empirical verification evidence

**Harness:** Cline CLI `3.0.46` (2026-07-27) and `3.0.55` (2026-08-16) · **Method:**
live `cline -i --tui` panes driven through `tmux` (`capture-pane -p`/`-e`), plus
cline's own on-disk session records.

This is the "confirm every fact empirically" record the `harness-adapters` skill
requires before an adapter is wired. Every value below is a capture, not a guess.

Refresh it with the drift guard:

```bash
FM_CLINE_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-cline-signals-live-e2e.test.sh
```

## Start mode: the operator's persisted setting wins (3.0.55)

`cline --help` documents the positional prompt as "Default to start in act mode
with auto-approve enabled". The TUI does not do that. Start mode follows
`planActMode` in cline's global settings file, so a firstmate-spawned crewmate
inherited whatever mode the operator last used — measured as 47,000 tokens of
reading and reasoning with no line written.

Controlled A/B on 3.0.55, same binary, same workspace, same credentials, with only
the settings file redirected:

```
$ CLINE_GLOBAL_SETTINGS_PATH=<lab>/plan-settings.json cline -i --tui     # {"planActMode":"plan"}
❯ Plan something...
 kimi-k3 (medium) (0) $0.00                      ● Plan ○ Act (Tab)

$ CLINE_GLOBAL_SETTINGS_PATH=<lab>/act-settings.json cline -i --tui      # {"planActMode":"act"}
❯ What can I do for you?
 kimi-k3 (medium) (0) $0.00                      ○ Plan ● Act (Tab)
```

Three facts this establishes:

- `CLINE_GLOBAL_SETTINGS_PATH` redirects **only** that one file. The status bar
  still showed the account's provider/model, so credentials and provider config
  continued to resolve from the operator's own store. That is what makes the
  redirect usable as the act-mode mechanism without touching `~/.cline`.
- There is **no `--act` flag**. `-p/--plan` only selects Plan, so a launch-time
  flag cannot force Act; the settings redirect is the whole mechanism.
- Plan mode has its **own composer placeholder**, `Plan something...`, previously
  unrecorded. It is now in `FM_COMPOSER_IDLE_RE_DEFAULT` so a plan-mode pane still
  reads as an empty composer.

The legacy `<data-dir>/globalState.json` `mode` key is **not** the authority on
3.0.55. The verification machine carried `"mode": "plan"` with
`"planActSeparateModelsSetting": true` there while
`settings/global-settings.json` carried `"planActMode": "act"`, and the TUI started
in **Act**. Read the settings file.

The structural (non-rendered) proof is cline's own session record, which stores the
mode it actually ran in:

```
$ jq -r '.metadata.mode' ~/.cline/data/sessions/<id>/<id>.json
act
```

## Session records: the structural busy source (3.0.55)

cline persists one record per session at
`<data-dir>/sessions/<session-id>/<session-id>.json`, with the turn log beside it:

```json
{
  "session_id": "1786827656641_r5j4m",
  "pid": 71393,
  "exit_code": null,
  "status": "idle",
  "interactive": true,
  "cwd": "<task worktree>",
  "workspace_root": "<task worktree>",
  "metadata": { "mode": "act" },
  "messages_path": ".../<session-id>.messages.json"
}
```

Observed `status` vocabulary across 29 real sessions: `running`, `idle`,
`completed`, `failed`.

**`pid` is not the pane's.** It is the shared cline hub daemon:

```
$ ps -p 71393 -o args=
.../bin/.cline --cline-hub-daemon --cwd <unrelated worktree> --host 127.0.0.1 --port 25463
```

One pid covered every session on the machine, so binding on it would attach every
task to every other task's turns. Binding is on `workspace_root` plus the
sidecar's pre-existing-session exclusion.

**A clean exit does not close the record.** After a verified clean `Ctrl+C` exit the
record still read `status: idle`, `exit_code: null`. The record answers busy/idle;
only the backend's `fm_backend_agent_state` proves an agent stopped.

**`status` alone cannot see the wedge.** A ClinePass refusal and a completed turn
both leave `status: idle`. The second signal separates them — the turn log's last
message role:

| Case | `status` | last message role | fold |
|---|---|---|---|
| finished turn | `idle` | `assistant` | settled |
| accepted, never processed | `idle` | `user` | **stalled** |
| completed / failed session | `completed`/`failed` | any | settled |
| turn in flight | `running` | any | busy |

Captured verbatim from the quota-refused turn — a user message with no reply:

```
$ jq -r '.messages[-1].role' <id>.messages.json
user
```

versus a normally completed session:

```
$ jq -r '.messages[-1].role' <other-id>.messages.json
assistant
```

## ClinePass quota exhaustion renders as a healthy idle pane (3.0.55)

```
 ❯ Count slowly from 1 to 40, writing one short line per number...
 * ╭──────────────────────────────────────────────────────────────╮
   │ ClinePass limit reached                                      │
   │ You have reached your 5-hour Clinepass limit. The limit      │
   │ resets in 51m, please try again later.                       │
   ╰──────────────────────────────────────────────────────────────╯
───────────────────────────────────────────
❯ Ask anything...
───────────────────────────────────────────
 kimi-k3 (medium) (0) $0.00                      ○ Plan ● Act (Tab)
```

After the panel scrolls, the pane is byte-comparable to one that finished a turn:
no spinner, ordinary idle placeholder, frozen counter. `quota-axi` has no `cline`
provider at all (`--provider <claude,codex,cursor,copilot,grok,kimi>`), so there is
no capacity surface to consult either — which is also why cline is correctly absent
from `bin/fm-dispatch-select.mjs`'s routable providers. The only structural tell is
the stalled fold above.

## Ready / idle composer

```
                 What can I do for you?
   Use / for slash commands, @ for file mentions, Ctrl+P for menu
───────────────────────────────────────────
❯ What can I do for you?
───────────────────────────────────────────
 ClinePass: Kimi K3 (medium)      ○ Plan ● Act (Tab)
 ⏵⏵ Auto-approve all enabled (Shift+Tab)
```

- Agent glyph `❯` (U+276F) — already a verified empty-composer glyph in
  `fm-composer-lib.sh`; no new glyph needed.
- Idle placeholder: `What can I do for you?` (first ready), `Ask anything...`
  (after the first turn).
- **Ghost-stripper gap:** in `capture-pane -e` the placeholder is truecolor
  `\e[38;2;131;137;140m` (grey, luma ≈ 136 > the 128 dark-fg cutoff) AND has a
  bold `\e[1m` copy. Neither is dim/faint (SGR 2), so the shared ghost stripper
  keeps it → it would misread as pending. Fix: the shared idle-placeholder
  default `FM_COMPOSER_IDLE_RE_DEFAULT` (`bin/fm-composer-lib.sh`) lists both
  placeholders and is consumed by the tmux classifier and the herdr/cmux/orca
  backends alike. The composer row has no side borders, so cmux/orca reach it
  via the shared bare agent-glyph promotion (`❯`).

## Busy signature

```
 ⠦ Thinking... (esc to cancel)
 ▶ Thinking: ...ctly single word. Ensure no extra.
 * PONG
───────────────────────────────────────────
❯ Ask anything...
───────────────────────────────────────────
 ClinePass: Kimi K3 (medium)      ██████ (10,062)
```

- Braille spinner (`⠦`/`⠇`/…) + `Thinking... (esc to cancel)`; the token
  **`esc to cancel`** is stable and clears the instant the turn ends → the busy
  anchor (`FM_TMUX_CLINE_BUSY_REGEX_DEFAULT='esc to cancel'`).
- Distinct from claude/codex `esc to interrupt` — no cross-harness borrow.
- Context counter rises during a turn (`(0)` → `(10,062)`), freezes at turn end.

## Interrupt vs exit (they differ — important)

- **Interrupt = `Esc`** ("esc to cancel" cancels the current turn).
- **Exit = single `Ctrl+C`** — re-verified on 3.0.55: the pane returned to `zsh`
  and printed `Continue  cline --id <session-id>`. So Ctrl+C must NEVER be used to
  interrupt a cline turn.
- `Esc` on an **idle** composer does not clear typed text; `C-u` does (3.0.55).
- cline is the exact inverse of grok, which interrupts on `Ctrl+C`. That is why
  `bin/fm-control-lib.sh` tables the interrupt key and the exit mechanism
  separately and never infers one from the other, and why cline is the one
  verified adapter recorded with an exit **key** rather than an exit command.

## Process identity: a bare `node` is not attributable (3.0.55)

cline runs as a bundled Node script, so the pane reports a generic name while
`ps -o comm=` carries the install path — the same shape cursor-agent has:

```
$ tmux display -p '#{pane_current_command}'
node
$ ps -t <tty> -o comm=
.../lib/node_modules/cline/bin/.cline
```

Until `cline` joined the shared exact-executable-name list, a live cline pane
classified `ambiguous`, and every lifecycle verb refused it — a SECOND refusal,
separate from the missing control mechanics:

```
error: task <id>'s endpoint reads 'ambiguous' rather than a positively
classified state; refusing to send a lifecycle key into an unattributed endpoint
```

With the path rule matching an exact `cline` path COMPONENT, `fm-control.sh`
was verified end to end against a real 3.0.55 worker:

```
$ bin/fm-control.sh <id> interrupt
interrupt-delivered <id> harness=cline backend=tmux verified=agent-alive cancel=unconfirmed
$ bin/fm-control.sh <id> exit
stopped <id> harness=cline backend=tmux endpoint=<target> worktree=<path>
```

The composer after `interrupt` read `❯ Ask anything...`, and the pane after
`exit` read `zsh`.

## Known limitation: the idle composer reads `pending`

cline draws its composer as two full-width horizontal rules with **no side
borders**, so the shared screen classifier does not recognise a bordered box and
takes the bare-row path. That path deliberately does not trust an idle
placeholder (it passes position 0 to `fm_composer_classify_content`), so a
genuinely idle cline composer classifies `pending`:

```
$ fm_tmux_composer_state <target>      # composer row is "❯ Ask anything..."
pending
```

Verified pre-existing — the same read on the unmodified baseline also returns
`pending`. Two further facts bound the impact:

- cline's screen first resolves to `need-identity` (it matches the pi separated
  composer shape), then falls through `probe-absent` to the bare-row path, so
  the Cursor-style cursorless reclassification does **not** transfer here.
- A submit that starts a turn is still confirmed, because the submit core's
  busy fallback rescues it. Measured: `fm_backend_send_text_submit` returned
  `empty` (delivered) against a live cline pane.

So the reported "delivery unconfirmed for a message that arrived" is expected to
bite when a submitted message does **not** start a turn — most plausibly a
ClinePass refusal, which returns the pane to idle instantly. Fixing it means
changing the one fleet-wide classifier's conservatism for every harness and
every backend, so it is recorded here rather than changed under this task.

## Launch (mechanics half)

`cline -i --tui "<prompt>"` **seeds and auto-runs** the positional prompt — at
t+8s the pane was already `⠇ Thinking...` on the seeded task. So cline uses the
argv-seed pattern (claude/codex/grok), not kimi's bare-launch+inject.

The full launch line was verified live:
`cline -i --tui --auto-approve true --thinking high "<prompt>"` started cleanly and
the status bar changed to `ClinePass: Kimi K3 (high)`, confirming `--thinking`
takes effect and `--auto-approve true` is accepted. Final template:

```
cline -i --tui --auto-approve true __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"
```

## Recorded in (the six adapter owners)

| Owner | Change |
|---|---|
| `bin/fm-spawn.sh` | `launch_template` cline case; `--model`/`--thinking` mapping; known-adapter allowlists; `__PROVIDERFLAG__`, `__CLINEPROVIDERS__` placeholders; `provider_flag_for_harness()`; openrouter key resolution + armed-read injection; `CLINE_PROVIDER_SETTINGS_PATH` seed file |
| `bin/fm-harness.sh` | `detect_own` ancestry match `*cline*` (comm + args) |
| `bin/fm-tmux-lib.sh` | `FM_TMUX_CLINE_BUSY_REGEX_DEFAULT` + `case` arm |
| `bin/fm-composer-lib.sh` + `bin/backends/{herdr,cmux,orca}.sh` | shared `FM_COMPOSER_IDLE_RE_DEFAULT` covers cline placeholders (tmux + all backends); cmux/orca bare agent-glyph promotion reaches the borderless `❯` row |
| `bin/fm-busy-lib.sh` | `cline-session` pull source: binding, session resolution, and the two-signal fold |
| `bin/fm-control-lib.sh` + `bin/fm-control.sh` | cline control mechanics; the exit-key table and its delivery path |
| `bin/fm-teardown.sh` | cleanup of `state/<id>.cline-providers.json` at teardown |
| `.agents/skills/harness-adapters/SKILL.md` | cline knowledge section with OpenRouter-via-Cline facts |
| `tests/fm-cline-harness.test.sh` | 28 portable behavior checks (all green) |
| `tests/fm-cline-signals-live-e2e.test.sh` | opt-in live drift guard against the real binary (`FM_CLINE_SIGNALS_LIVE=1`) |
| `tests/fm-openrouter-cline-live-e2e.test.sh` | opt-in live drift guard for openrouter path (`FM_OPENROUTER_CLINE_LIVE=1`) |

## Remaining acceptance (live end-to-end)

The facts above are verified against the real binary and covered by both a portable
regression and the opt-in live guard. The closing acceptance is still a **full live
crewmate dispatch through the herdr backend**: `config/crew-harness=cline` (or a
`--harness cline` dispatch), observing the supervisor drive ready-gate →
brief-inject → busy → turn-end on a real cline pane under supervision. Not yet run
here (needs a full firstmate home + a real project). The optional `--hooks-dir`
turn-end Stop-hook (only for cline-as-PRIMARY) is a separate future item.

## OpenRouter-via-Cline — empirical verification (2026-08-24, cline 3.0.57)

This section records the verified facts for the `harness=cline --provider openrouter`
launch path added 2026-08-24. Every value below is a capture, not a guess.

### Provider and model identity

- Provider id: `openrouter` (explicit `-P openrouter` flag).
- Model id: the OpenRouter model id verbatim via `-m <id>` (e.g. `openai/gpt-oss-20b`).
- Default model under `-P openrouter` (no `-m`): cline's shipped default `deepseek/deepseek-v4-flash-vision-exp` — never used by firstmate; an explicit `--model` is required.
- Base URL: `https://openrouter.ai/api/v1` (from cline's built-in provider registry).

### Credential resolution order (established by binary inspection + live probe)

1. `OPENROUTER_API_KEY_TOKENS` (firstmate's preferred, working inference key — matches `fm-openrouter-quota.sh`).
2. `OPENROUTER_API_KEY` (fallback; on this account stale, returns HTTP 401).
3. Request-time fallback: cline's provider client reads `OPENROUTER_API_KEY` from the process environment at API call time (verified by direct `curl` probe: `OPENROUTER_API_KEY_TOKENS` returned HTTP 200 on `openai/gpt-oss-20b`, `OPENROUTER_API_KEY` returned HTTP 401).

### Startup gate (cline 3.0.57)

The TUI and headless paths both enforce a startup auth gate BEFORE any request is made:
- TUI: shows `Connect a model provider` onboarding modal when no resolvable key is found.
- Headless: fails with `No cookie auth credentials found`.
- The gate accepts ONLY:
  - `-k <api-key>` flag (expanded in the pane shell from a silently injected export).
  - A non-empty `apiKey` in the stored providers.json (operator's store or a redirected store via `CLINE_PROVIDER_SETTINGS_PATH`).
- The environment variable `OPENROUTER_API_KEY` is NOT consulted by the gate (verified: env-only launches with a clean store hit the onboarding/headless failure despite the var being exported in the pane).
- Any `-k` value IS persisted by cline into the active provider store (verified: a `-k` run wrote the key into `~/.cline/data/settings/providers.json` under `.providers.openrouter.settings.apiKey`).

### Firstmate's launch construction (Option A design)

1. Seed `state/<id>.cline-providers.json` with a no-secret entry:
   ```json
   {
     "version": 1,
     "lastUsedProvider": "openrouter",
     "providers": {
       "openrouter": {
         "settings": {"provider": "openrouter", "model": "<requested-model>"},
         "updatedAt": "<iso8601>",
         "tokenSource": "manual"
       }
     }
   }
   ```
   No `apiKey` field. This satisfies the gate's "stored entry exists" check while keeping the secret out of the file.

2. Resolve the key from firstmate's env at spawn time (TOKENS-first per repo convention). Fail closed if absent.

3. Silently inject the key into the pane shell via armed read:
   ```
   printf 'FM_OPENROUTER_KEY_ARMED\n'; IFS= read -rs OPENROUTER_API_KEY && export OPENROUTER_API_KEY
   ```
   Poll pane capture for `FM_OPENROUTER_KEY_ARMED` marker, settle 0.3s, send literal key + Enter. The key never renders in scrollback (`read -rs` suppresses echo).

4. Launch: `CLINE_GLOBAL_SETTINGS_PATH=... CLINE_PROVIDER_SETTINGS_PATH=state/<id>.cline-providers.json cline -i --tui --auto-approve true -P openrouter -k "$OPENROUTER_API_KEY" -m <model> "<brief>"`
   The `-k` reference is expanded in the pane shell from the injected export.

### Live completion round-trip (verified 2026-08-24)

- Model used: `openai/gpt-oss-20b` (first candidate from ordered list that answered).
- Assistant reply: `ok` (trimmed).
- Session record: status=idle, provider=openrouter, model=openai/gpt-oss-20b, messages=2 (user + assistant), context tokens 5,378.
- Cost: $0.000164.
- Redirected providers file: NO key material persisted (remained no-secret).
- Exit: Ctrl+C returned pane to shell cleanly.

### Dispatch surface

- `--provider openrouter` accepted only with `--harness cline`; requires explicit non-default `--model`.
- `cline` refuses `--provider claude|codex|grok` (meaningless for cline).
- Other harnesses refuse `--provider openrouter` (not implemented).
- Single-object crew-dispatch profiles with `{harness: cline, provider: openrouter, model: ...}` bypass the subscription-aware selector (BYO-key class) and are allowed by bootstrap validation (provider openrouter on cline requires model; elsewhere refused).
