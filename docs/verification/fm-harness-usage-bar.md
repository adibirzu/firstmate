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

### What a live Codex row can and cannot carry (verified 2026-09-07)

Read-only follow-up on the finding above, captured with `bin/fm-peek.sh` against
three independently running Codex panes in the reference home
(`firstmate-capacity-disk-r11`, `firstmate-upstream-consolidation-p1`,
`firstmate-pr37-repair-r10`), plus `bin/fm-statusline-quota.sh` on the same targets.

Observed footer, identical in shape on all three (effort varied, `high` and `xhigh`):

```text
> Ask Codex to do anything

  gpt-5.6-terra high - ~/.fm-pools/.../firstmate
```

Two separate conclusions follow, and they differ:

- **model IS available and is now recovered.** Every one of those live tasks recorded
  `model=default` in `state/<id>.meta`, because `bin/fm-spawn.sh` writes
  `model=${MODEL:-default}` when no model was chosen. `default` is a placeholder, not a
  model, so the row no longer prints it. For Codex, `fm_crew_usage_model_from_pane`
  (`bin/fm-crew-usage-lib.sh`) recovers the real model from that native footer. Verified
  end to end on the three panes above: the default supervision path reports the model
  unrecorded and captures nothing, while the opted-in read returns `gpt-5.6-terra`.
- **context percentage is NOT available for Codex, and is not synthesized.**
  `bin/fm-statusline-quota.sh` returns `status=unknown source=none` for these panes, and
  the footer above carries no percentage of any kind. Codex's TUI does not render the
  configured external proxy (finding above), so there is nothing to read. Codex rows
  therefore keep `context_pct:"n/a"`. This is the recorded boundary, not a gap to close
  by inferring a number from token counts printed in the transcript.

Both reads are opt-in (`FM_CREW_USAGE_ENABLE_CONTEXT=1`) and bounded
(`FM_CREW_USAGE_CONTEXT_TIMEOUT`), and only `bin/fm-bearings-snapshot.sh` opts in.

### Why these reads are opt-in: the supervision-path contention regression

An earlier revision of this work read the statusline for every task on every canonical
snapshot. `bin/fm-watch.sh` backgrounds two snapshot consumers on EVERY poll -
`fm-home-summary-refresh.sh` (`--secondmate-home-summary`) and
`fm-secondmate-reconcile.sh process-requests` (`--json`) - so that turned the canonical
snapshot into a second pane reader racing the watcher's own capture.

The watcher proves pane churn by comparing consecutive captures, and uses that proof to
absorb a bare turn-end. A competing capture destroys the evidence, so the watcher
resurfaced a wake it had proof to absorb. Reproduced against
`tests/fm-watch-triage.test.sh`: "pane churn resets prior wedge escalation state before
the stale-path poll". It is a race, so it is frequent but NOT deterministic - 3 of 3 runs
failed during this work and an independent replication measured 3 of 4 - while the same
test passes on `origin/main` and with the snapshot change reverted. Isolated to
`bin/fm-fleet-snapshot.sh` by reverting each changed file in turn, and 5 of 5 after the fix.

A timeout does not fix this - a fast extra capture is still an extra capture - so the
live reads are gated off by default instead. Guarded by
`tests/fm-crew-usage-lib.test.sh` ("never captures a pane by default", "a default usage
row reads meta only", "only the human-facing bearings reader opts into the live context
read").

Two consequences of that opt-in are recorded rather than designed away:

- **Both diagnostics run under `FM_GUARD_READ_ONLY=1`.** `bin/fm-statusline-quota.sh` and
  `bin/fm-peek.sh` each run `bin/fm-guard.sh`, which prints its `WATCHER DOWN` banner once
  per down-episode and CLAIMS that episode with a marker. Both usage reads discard stderr,
  so without read-only mode a `/bearings` run during a supervision lapse would swallow the
  banner and leave the next guarded command reporting it had "already printed" an alarm
  nobody saw. Verified: after an opted-in read the marker is unclaimed and the next guard
  run still prints the full banner. Guarded by the two "guard read-only mode" tests.
- **A residual, accepted race.** `/bearings` is normally run while the watcher IS armed, so
  the opted-in read can still capture a pane concurrently with the watcher. That is
  acceptable for `tmux capture-pane`, which is read-only; an adapter whose capture is not
  read-only would need re-checking before it is added to the supported set.


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
