# Verification: the agy (Antigravity CLI) adapter

Active empirical facts for firstmate's agy adapter as a crewmate, scout, secondmate, and primary harness; the crewmate sections were measured on agy 1.2.0 and the final section on agy 1.4.7.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/agy.md`](../../.agents/skills/harness-adapters/references/harness/agy.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `agy 1.2.0`; the send-confirmation timing below was re-measured on `agy 1.2.1` (2026-09-12) |
| Verified | 2026-09-10 |
| Binary | `/home/andpod/.local/bin/agy`, an ELF 64-bit Go-compiled single executable |
| Platform | Linux x64 (Arch, kernel 7.2.3) |
| Backend | Herdr, in an isolated non-`default` lab session (`fm-lab-firstmate-agy-ad-*` via `bin/fm-herdr-lab.sh`); the live `default` session was unchanged throughout |

Every command below ran inside the disposable firstmate task worktree or the named Herdr lab session.
No captain fleet state was touched.

## Detection: ancestry only, no marker

```
$ agy --version
1.2.0
```

A live TUI's `/proc/<pid>/environ` carries no `AGY_*` or `ANTIGRAVITY_*` variable.
It does carry `AGENT=1` and `CLAUDECODE=1`, both inherited from the launching environment, so neither is an agy identity and neither is promoted to a marker.
Herdr's `pane process-info` for the same pane reports the foreground process as `name=agy` with `argv=["agy", ...]`, and `ps -o comm=` reports `agy`.
`bin/fm-harness.sh` therefore matches the anchored process name `agy` alone, and the spawn clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` at the launch boundary.
`tests/fm-agy-harness.test.sh` pins the anchored match, the rejection of unrelated names containing the fragment, and that an inherited `CLAUDECODE` never outranks a real `agy` ancestor once the spawn clears it.

## Launch: positional prompt-interactive with auto-submit

```
$ agy --prompt-interactive "Reply with exactly AGY_LIVE_PROBE_OK and nothing else" --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions
```

The brief submitted itself with no extra Enter, the turn ran, and the reply rendered in the pane.
A second launch into the same directory answered a fresh prompt the same way, so the shape is repeatable, not a first-run accident.
The footer rendered `Gemini 3.8 Flash · low`, proving both flags were accepted together.

## Trust dialog: pre-registered before launch, gated on a busy turn as the backstop

A first launch in a fresh worktree shows this dialog:

```
Accessing workspace:

/home/andpod/.treehouse/firstmate-7bab20/1/firstmate/agy-probe-tmp

Do you trust the contents of this project?

Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit
```
`agy --help` (1.2.0) lists no trust flag or pre-registration command, but agy honours a `trustedWorkspaces` entry written to `~/.gemini/antigravity-cli/settings.json` ahead of launch.
Verified under a throwaway `HOME` holding a copy of `~/.gemini` (the real settings file was never written): a folder appended to that array by hand launched `--prompt-interactive` straight into its turn and rendered the reply with no dialog, while an unregistered sibling folder launched the same way parked on the dialog.
agy compares the pane's logical working directory, not its resolved path: a symlinked cwd whose real path alone was registered still parked on the dialog, so `bin/fm-agy-trust.sh` records both the logical path and its resolved form when they differ.
`bin/fm-spawn.sh` runs that helper before launch at the same point it pre-registers claude trust; the helper applies the same structural scope test (a linked worktree of the spawning project, never a primary checkout, a subdirectory, a plain directory, or the home directory), preserves every other key in the store, and writes atomically with a fingerprint check.
A failed registration is a stderr warning rather than a refusal, because agy's dialog preselects the safe answer and the gate below can answer it.
Two supervised Herdr runs in treehouse worktrees completed file-writing turns while the dialog was still unanswered at observation time (worker file and `done:` status line both verified on disk before Enter was ever sent to those panes).
Isolated runs in untrusted `/tmp` directories never reached the workspace until Enter: the turn spun through exploratory tool calls in agy's own scratch directory instead, and only the queued prompt ran after the answer.
One run left unanswered for several minutes wrote its file to agy's scratch directory instead of the workspace once finally answered.
The mechanism behind the difference was not established; path, backend, and latency were all varied across runs without isolating a single cause.
The spawn therefore does not depend on it: after pre-registration, `bin/fm-spawn.sh` runs a post-launch readiness gate (`agy_wait_for_working`) in the rovo/kimi launch-then-confirm shape as the backstop.
It polls the pane capture, answers the dialog with a single Enter the first time the `Do you trust the contents of this project?` text renders, and reports success only once `fm_busy_classify` returns a busy verdict for the pane (Herdr's native `working` status or the pinned `esc to cancel` status row).
Because Herdr's native `working` verdict is known to coexist with an unanswered dialog, the gate is strict about order: a busy verdict counts as ready only when the worktree was pre-registered before launch or the dialog has already been seen and answered; on an unregistered path it keeps polling for the dialog instead of accepting the early busy verdict.
When the brief cannot be confirmed to run within the window (an answered dialog never turns busy, a pre-trusted pane never turns busy, or an unregistered pane never shows the dialog), the spawn fails, records `failed:` in the task status, and closes the endpoint so no orphan worker survives outside task control.
`tests/fm-agy-harness.test.sh` covers the helper's registration and scope refusals against a throwaway store, and drives a fake pane whose dialog decision reads the store the spawn just wrote: the pre-trusted launch with no dialog, a dialog that renders anyway answered exactly once, the premature busy verdict on an unregistered path waiting for the dialog, and both fail-and-close paths.

## Model and effort

```
$ agy models
Fetching available models...
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
...
```

`agy --help` documents `--effort` as `low|medium|high` and `--model` as the model for the session.
The bare `gemini-3.8-flash` id from this home's previous config is not listed; only the suffixed `-high`, `-medium`, and `-low` variants are.
`bin/fm-spawn.sh`'s `agy_model_validate` refuses a requested id a reachable `agy models` listing omits, and launches unvalidated with a stderr notice when the listing is unreachable.
The listing is a remote fetch (`Fetching available models...`), so the probe runs with stdin detached under the shared hard bound from `bin/fm-timeout-lib.sh` (15 seconds by default, `FM_AGY_MODELS_TIMEOUT`; a non-positive or non-numeric value clamps back to that default, because a non-positive bound is not a bound); a stalled fetch or a sign-in prompt is cut off and falls through to the unvalidated launch instead of blocking the spawn before any pane exists.
Print mode (`agy -p "Reply with exactly: AGY_PRINT_PROBE_OK" --model gemini-3.8-flash-low`) returned the exact reply with exit 0 in about 8 seconds, proving the credential path without a pane.

## Busy state: the pinned status row, unknown on absence

Mid-turn the pane rendered the status row and a spinner line at once:

```
⣯  Generating...
└ Tip: When reviewing a file edit, press f to see the full diff.
...
esc to cancel                                                           Gemini 3.8 Flash · low
```

The completed turn showed the reply, then the idle composer:

```
>
──────────────────────────────────────────────────────────────────────────────
? for shortcuts                                                         Gemini 3.8 Flash · low
```

`fm_busy_agy_tail_busy` and the delivery guard in `bin/fm-composer-lib.sh` match the `esc to cancel` token alone: the TUI pins that status row to the bottom of the pane for the whole turn, and the idle row replaces it with `? for shortcuts`.
The `Generating...` spinner word is deliberately not a signal: it is a free-floating output line, so ordinary worker output such as `Generating report...` would otherwise classify an idle worker as busy or acknowledge a submit that did not land.
No busy phase without the status row was observed live; every captured mid-turn frame carried it.
`fm_busy_classify` reports `unknown agy-regex` when the token is absent, because a long turn can scroll the marker out of the captured tail.
The signature is hardcoded with no environment override, so a stray variable can never change worker-state classification.
Herdr's own registry agreed throughout: `agent get` reported `agent_status=working` mid-turn and `idle` after, so on Herdr the native verdict carries busy with no new code.

## Interrupt and exit

A single `Escape` sent mid-turn through `herdr pane send-keys` cancelled it and printed this row, with the composer back at idle and no repolluted text:

```
  ⎿  Interrupted · What should Antigravity CLI do instead?
```

Sending `/quit` plus Enter exited the process; the pane closed under the `exec` launch, and Herdr reported the pane gone.
`bin/fm-control-lib.sh` records `Escape` once, no clear key, no ack source, and `/quit` for agy.

## Backend liveness: Herdr recognizes agy, tmux names it

```
$ herdr agent get w2:p1 --session fm-lab-firstmate-agy-ad-1599574-8823
{"result":{"agent":{"agent":"agy","agent_status":"idle",...,"agent_session":{"agent":"agy","kind":"id","source":"herdr:antigravity_cli",...}}}}
```

Herdr tracks agy natively (`antigravity-cli` integration, detected as `agent=agy`), so `fm_backend_herdr_pane_agent_state` returns `live` for every registered agy status and no exit-detection hardening was needed.
The tmux adapter classifies the anchored process name `agy` as `agent` through the shared name vocabulary in `bin/fm-agent-process-lib.sh`, the muse/omp precedent for short bare-word names.
agy stays out of the session-lock name vocabulary in `bin/fm-session-lock-lib.sh`, where the other crewmate-only adapters are also absent.

## Composer: unknown by design

Byte-level capture of the idle pane shows a bare unstyled `>` between two full-width `─` rules, with an unstyled `? for shortcuts` cell and a dim (`SGR 2`) model cell in the status row below.
The shared classifier reads that bare `>` as `unknown` under the dead-shell rule, never `empty`.
Steering still confirms delivery: the Herdr submit core leads with the native `idle`-to-`working` transition, which agy performs, and the delivery footer regex covers the tmux path.
agy renders the busy footer late for that confirm loop - about 1.5 s after Enter for a short steer and 4-5 s for a realistic longer brief, measured live on `agy 1.2.1` (2026-09-12) against the shared budget's 3 x 0.4 s - so `bin/fm-send.sh` gives agy typed targets a longer default submit-confirm budget (20 retries, about 8 s at the default cadence); an explicit `FM_SEND_RETRIES` still wins and every other harness keeps the shared 3-retry default.
`tests/fm-send-agy-confirm.test.sh` pins the raised default and `tests/fm-agy-harness.test.sh` pins the Herdr transition path.
This is the cursor precedent, not a gap to patch in shared code.

## Supervised task: spawn, steer, relaunch, and exit through the new path

A trivial scout ran end to end through `bin/fm-spawn.sh --harness agy` against the same isolated lab session: `spawned agy-e2e1 harness=agy kind=scout` with a treehouse-provisioned worktree, `--model gemini-3.8-flash-low`, and `--effort low` all recorded in task metadata.
The worker wrote its worktree file and appended `done: agy e2e turn complete` to its status file, which lives outside the worktree, proving prompt processing, tool execution, outside-workspace file access, and a new completion event.
Durable steering held: a `bin/fm-send.sh` message landed in the task inbox, the worker appended the steered lines to both files, and its inbox record moved to `handled/`.
Same-copy relaunch held: `bin/fm-control.sh relaunch --note` replaced the worker in place on the identical worktree, model, and effort, the replacement verified both prior lines intact and appended `relaunched: done`.
Exit held: `bin/fm-control.sh exit` stopped the worker, the registry returned `agent_not_found`, and the pane remained a lone shell in the worktree with all work intact.
No automatic quota failover was exercised or claimed; every handoff above was an explicit supervised relaunch.

## What is still unproven

The unauthenticated failure mode was never observed; this host's agy runs signed in, so any auth prompt is a fail-loud credential blocker, not a handled dialog.
No slash-skill invocation form was verified, so skill invocation stays natural language.
`--continue` and `--conversation` resume were never exercised; recovery uses deterministic relaunch from the brief on disk.
No primary or secondmate behavior was built or tested, and none is claimed.

## Refreshing this record

Run the portable suite and the live guard after any agy upgrade, because the process name, marker set, trust dialog text, and rendered busy/interrupt text are all vendor-controlled surfaces that the spawn gate and the busy fallback match verbatim:

```
bin/fm-test-run.sh tests/fm-agy-harness.test.sh
FM_AGY_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh
```

## Primary and secondmate hooks (agy 1.4.7)

Measured 2026-10-25 on macOS arm64 with `agy 1.4.7`, in a scratch git repository under the task scratchpad whose `.agents/hooks.json` registered probe hooks, driven in a detached tmux session with `gemini-3.8-flash-low`.
agy's own customization guide (`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`) documents the contract, and every claim below was confirmed live rather than taken from it.
The captain's global `~/.gemini/config/hooks.json` already registers Herdr and Orca hooks on `PreInvocation`, `PostInvocation`, and `Stop`, which is why Herdr's native agy status tracking works.

```
$ agy plugin validate <plugin with Stop,SessionStart,UserPromptSubmit,Notification,SessionEnd,AfterAgent,PostResponse>
hook "hooks": unknown event "UserPromptSubmit" is ignored (events: SessionStart, PreInvocation, PostInvocation, Stop, PreToolUse, PostToolUse)
```

That is the complete event vocabulary: there is no user-prompt, notification, or session-end event.
Hooks are read from `<root>/.agents/hooks.json` as a map of hook names to events, run through `sh -c` with the directory holding `hooks.json` as cwd, receive camelCase JSON on stdin, and carry `ANTIGRAVITY_CONVERSATION_ID` in their environment.
A hook's parent process is the live `agy` TUI process (`ps -o comm=` reports `agy`), which is what the session-lock ancestry walk keys on.

### Loading and trust

- A workspace is loaded only after its folder-trust gate: the log reads `loaded 2 named hooks from 1 hooks.json file(s)` (the global set) before the dialog is answered and `loaded 3 named hooks from 2 hooks.json file(s)` after.
- The hook set loaded by answering the dialog missed the turn already under way: the first turn after the dialog produced no hook output, and the next turn produced `PreInvocation`, `PostInvocation`, and `Stop`.
- With the folder already trusted, a fresh session ran `SessionStart` before its first `PreInvocation`.
- `agy -p` (print mode) in the same scratch repository wrote no hook output and hung past 120 seconds while the captain's MCP servers were still connecting, so print mode is not an evidenced hook surface and a primary must run the TUI.

### Stop continuation, park, and timeout

Stop payload from a normal completion: `{"conversationId":...,"executionNum":0,"fullyIdle":true,"lastUserInput":...,"modelName":...,"terminationReason":"NO_TOOL_CALL","transcriptPath":...,"workspacePaths":[...]}`.

- A Stop hook that printed `{"decision":"continue","reason":"... reply with exactly CONTINUED_OK ..."}` once blocked the stop: the next `PreInvocation` followed within the same second and the pane printed `CONTINUED_OK`.
- With the hook registered at `timeout: 120`, a 45 second sleep before the same `continue` returned normally (`PARK_START 1792915339`, `PARK_END 1792915384`) and the pane then printed `PARKED_OK`, so a Stop hook can hold the boundary open far past agy's 30 second default.
- With the hook registered at `timeout: 20` and a 40 second sleep, the hook was killed (no `STOP_END` was ever written) and the turn ended with no continuation, so a timed-out hook fails open.
- `agy plugin validate` accepted `"timeout": 28800`; a park longer than 120 seconds was not run, which is why the guard bounds its own park at 3300 seconds inside a 3600 second registration.
- An always-continue Stop hook produced `executionNum` 0 through 10 (eleven Stop calls), then agy stopped the chain; a second chain started with `executionNum` 0 and ran to 10 again, and then no further calls were made for the remaining seven minutes of observation.
  The guard therefore bounds itself at 8, and how often a fresh chain starts without a captain message was not established.

### SessionStart injection and PreToolUse deny

- A `SessionStart` hook that printed `{"injectSteps":[{"systemMessage":{"systemMessage":"SESSIONSTART_MARK: ... say SESSIONSTART_SEEN."}}]}` reached the model: asked for the marker, it answered `SESSIONSTART_SEEN`.
- A `PreToolUse` hook (matcher `*`) received `{"toolCall":{"args":{"CommandLine":"echo DENYME","WaitMsBeforeAsync":5000,"toolSummary":"Run echo DENYME"},"name":"run_command"},"stepIdx":...}` and its `{"decision":"deny","reason":...}` blocked the command, with the reason relayed to the model.
- Both arm and cd seatbelts therefore read `toolCall.args.CommandLine` and render the same decision object (`tests/fm-agy-primary.test.sh`).

### Side effects of the probes

Answering the folder-trust dialog appended the scratch directory to `trustedWorkspaces` in the captain's `~/.gemini/antigravity-cli/settings.json`; the probe removed exactly those entries afterwards.
No hook, plugin, or setting was installed in the captain's agy configuration, and the tracked `.agents/hooks.json` is the only registration this adapter ships.

### Still unproven

- A Stop hook parked longer than 120 seconds, and the hook timeout ceiling.
- What a user message or `Escape` does to a parked Stop hook, and whether a cancelled turn calls the hook with `USER_CANCELED` as the guide says.
- `SessionStart` on a resumed or continued conversation, and whether a fresh chain restarts without a captain message after the continuation limit.
- Herdr and tmux submit confirmation for a primary-side typed message, and the supervision host and away daemon, which are not wired for agy.
- The live end-to-end of the shipped hooks against a real firstmate home: `tests/fm-agy-primary.test.sh` drives the shipped scripts with synthetic payloads in the recorded shapes, and the probes above used probe scripts.
