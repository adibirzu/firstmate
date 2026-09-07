# Fleet-wide usage bar: statusline proxy execution and per-harness JSON adapters

Audience: maintainer verification.

This record contains reusable version-scoped evidence for the fleet-wide usage bar.
Exact task chronology and delivery transcripts remain in private task and PR evidence.

## Slice 0: the Codex statusline proxy executes directly but not in a live pane

Verified 2026-09-06 with codex-cli 0.153.4 on macOS.

Codex's `~/.codex/config.toml` `status_line.command` already points at `~/.codex/statusline.sh`,
a 4-line proxy that execs `~/.claude/LIFEOS/LIFEOS_StatusLine.sh` unmodified.
Codex's `status_line` TUI hook is interactive-only (there is no `codex exec` flag that
exercises it), so this verification runs the exact configured command directly with two
different stdin payloads and confirms the rendered bar responds to the input rather than
falling back to bare "LifeOS" text:

```sh
echo '{}' | ~/.codex/statusline.sh
echo '{"model":{"display_name":"gpt-5.5"},"workspace":{"current_dir":"'"$PWD"'"},"session_id":"test-session"}' \
  | ~/.codex/statusline.sh
```

Observed: both invocations render the full multi-line LifeOS bar (state rings, effort
row, memory line, harness/model/version row, context bar, startup-load breakdown).
The `DEF MODEL` field read `UNKNOWN` with no stdin model field and `GPT-5.5` once one was
supplied; the `CONTEXT` bar's percentage changed from `4%` to `25%` between the two runs.
This confirms that direct proxy execution is input-sensitive, not a static fallback.
The live-pane capture below establishes the separate interactive-TUI result.

### Live-pane interactive verification (captured 2026-09-07)

Captured read-only from active Codex worker pane `w58:p2`
(`/Volumes/ExternalNVME/.fm-pools/firstmate-3730267688/.treehouse/firstmate-92a512/18/firstmate`)
via `herdr agent read`:

```text
› Ask Codex to do anything

 gpt-5.6-terra high · /Volumes/ExternalNVME/.fm-pools/firstmate-3730267688/.treehouse/firstmate-92a512/18/firstmate
```

Comparison with Claude live pane (`w4B:p1` via `herdr agent read`):

```text
  LIFEOS ◉46%
 ◈main 1h │ ✿—→
 ◎ 📁195 ✦30 ⊕0
 ⏵⏵ auto mode on (shift+tab to cycle) · ← 5 agents
```

Finding: Unlike Claude Code (which executes `LIFEOS_StatusLine.sh` and displays the
multi-line  LIFEOS bar live in its TUI), Codex CLI 0.153.4’s interactive TUI renders
only its native statusline footer (model effort · cwd) and does not display the external
statusline proxy output in its live interactive pane. The proxy `~/.codex/statusline.sh`
executes and renders the LifeOS bar when run directly from shell via stdin, but Codex’s
live TUI does not render it.
Therefore, Codex crews rely on Firstmate’s fleet-wide usage row fallback in `/bearings` and `fm-fleet-snapshot.sh` for live task context and provider-quota visibility.

Grok's proxy (`~/.grok/statusline.sh`) is the identical delegate pattern; captain
instruction excluded Grok from Slice 0 verification for this task.

## Slice 2: opencode/pi/cline usage-data confirmation

Per the captain's instruction, an adapter in `bin/fm-crew-usage-lib.sh` is added only
where the harness's own machine-readable output was first confirmed to carry real
token/context data usable for a LIVE task's fleet-wide usage row. Findings, each
reproduced 2026-09-06:

### opencode - confirmed absent for a per-task row; skipped

```sh
opencode stats --days 1
```

`opencode stats` reports cross-session, cross-day aggregate cost/token totals (Sessions,
Messages, Input/Output/Cache tokens). It has no per-live-task or per-pane scoping and no
context-window percentage. There is nothing here to attach to one running crew's row.
No adapter added.

### pi - token data exists, but only from a NEW invocation, not a running task's state

```sh
pi --mode json --print "say hi"
```

Confirmed: pi's JSON-mode output carries a real `usage` object per assistant message
(`{"input":3,"output":6,"cacheRead":0,"cacheWrite":7691,"totalTokens":7700,"cost":{...}}`).
However, this data is only produced by pi actually running a turn in that invocation.
Firstmate observes an already-running interactive pi crew from outside the process (a
pane capture), and has no live channel to that process's accumulated usage without
either re-invoking a brand-new `--print` turn (which reports a new, unrelated
conversation's usage, not the running task's) or parsing pi's own on-disk session
storage. The latter is a materially larger scope than a "light adapter" and was not
attempted here. No adapter added; recorded as a confirmed-but-inapplicable finding.

### cline - same shape and same limitation as pi

```sh
cline --json -p "say hi" --auto-approve true
```

Confirmed: cline's `--json` print mode emits real per-run token counts in its
`run_result`/`done` events (`{"inputTokens":7222,"outputTokens":115,"cacheReadTokens":0,
"cacheWriteTokens":0,"totalCost":0}`). Same limitation as pi: this is only available from
a freshly invoked print-mode turn, not a read of an already-running interactive task's
accumulated usage. No adapter added; recorded as a confirmed-but-inapplicable finding.

### Conclusion

No opencode/pi/cline adapter was added to `bin/fm-crew-usage-lib.sh`. Those three harnesses'
`usage_context_pct` fields remain `"n/a"`; Codex and Claude use the existing read-only
statusline diagnostic where it reports `Context N% left`. A future slice that wants real
numbers for pi/cline would need to parse their
session storage formats (a materially larger, harness-storage-format-dependent piece of
work, and itself a harness-dependent check needing the two-test proof
`firstmate-coding-guidelines` requires) rather than shelling a fresh print-mode turn.
