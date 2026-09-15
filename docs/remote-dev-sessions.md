# Remote development sessions

A remote development session is a Firstmate task or second mate running on a registered station, watched from the primary.
This doc owns the continuity contract: the guarded command, the durable record, backend selection, the pre-launch gate, and the exact attach/reconnect commands.
[`bin/fm-remote-dev-session.sh`](../bin/fm-remote-dev-session.sh)`'s header and `--help` own the exact flags and mechanics; this doc states the behavior.

The command never launches a raw process.
It reattaches a live recorded endpoint, or relaunches one through the ordinary record paths - `bin/fm-spawn.sh <id> --secondmate` for a mate and `bin/fm-control.sh <id> relaunch` for a task.
A task relaunch carries a deterministic continuation note with the task id, the intended branch and its head SHA, the handoff path the replacement continues in, and an explicit fetch/sync-before-edit instruction.
An unresolvable note refuses the relaunch instead of sending a worker in with no context.
It never forces, stashes, or discards anything.

## Command

Verbs are `open`, `recover`, `attach`, `status`, `list`, and `check`.
Run the command from the primary home; `FM_HOME` and the config/state/data/projects roots resolve exactly as they do for the other `bin/fm-*.sh` commands.

```sh
bin/fm-remote-dev-session.sh check   <station> (--secondmate <id> | --task <id>)
bin/fm-remote-dev-session.sh open    <station> (--secondmate <id> | --task <id>)
bin/fm-remote-dev-session.sh recover <station>
bin/fm-remote-dev-session.sh attach  <station> [--exec]
bin/fm-remote-dev-session.sh status  <station>
bin/fm-remote-dev-session.sh list [--json]
```

`open` runs the readiness gate and the pre-launch gate, reattaches or relaunches, then writes the continuity record and prints the attach command.
`recover` is the idempotent reconnect: it inherits the recorded target and repeats `open` without needing the flags again.
`attach` prints the recorded attach command, or runs it with `--exec`.
`status` prints one station's record; `list` prints every record.
`check` runs the gates and prints the verdict without launching or writing a record.

A station is one SSH host or the local host, resolved from `data/secondmates.md` exactly as `bin/fm-station-idle.sh` resolves it: a remote route whose host is `<station>` or `<station>-<suffix>`.
A remote station's readiness and launch go over the existing SSH/`bin/fm-on.sh` route; no new remote write surface exists.

A remote station is normally targeted with `--secondmate`, because an individual worker is never placed remotely ([remote-secondmates.md](remote-secondmates.md)).
A `--task` target reads this home's task record and resolves its endpoint through `bin/fm-crew-state.sh`; a live endpoint is attached, and a dead one is relaunched only through `bin/fm-control.sh`, which refuses an endpoint it cannot prove local rather than starting a raw process.

## Backend selection

herdr is the default and the only backend a remote second mate uses ([remote-secondmates.md](remote-secondmates.md)).
tmux is the explicit fallback and is selected only by `--backend tmux` or a local gitignored `config/remote-dev-backend` containing `tmux`.
tmux is never auto-detected here and a herdr failure is never silently retried on tmux: the command reports the gap and stops, so the operator chooses the fallback.
An unknown backend value, in a flag or in the config file, refuses rather than selecting one.
Both backends expose the same stable reference fields, so a reconnect is the same shape either way.

## Readiness gate

A remote herdr station is gated on `bin/fm-remote-doctor.sh`, the single owner of remote second-mate readiness, run through `bin/fm-on.sh`.
A red doctor refuses with the doctor's own gap and `action:` lines.
`--repair` runs the doctor's repair once and then re-checks read-only; a repair is never trusted on its own word.
A local station only proves the selected backend binary resolves, because the remote doctor owns a remote host's herdr readiness.
A remote tmux station proves tmux resolves over a bounded SSH probe.

## Pre-launch convergence and equivalence

Before a task session launches, the command converges the default branch and refuses duplicate or stale work.
Convergence is fetch-only: it moves remote-tracking refs and never checks out, resets, or stashes.
The equivalence verdict refuses with exit 3 for a duplicate and exit 4 for stale work:

- duplicate: an existing branch for the work, or an open or merged pull request recorded on the task.
- stale: the task's own branch is already contained in the default branch, every one of its patches is already there, or its base is behind the default branch.

An unreadable forge probe is reported but never refuses a launch, because it is not evidence of duplicate work.
The gate is read-only and never rewrites a branch.
`--repo` and `--branch` override the task worktree and branch the gate reads.

## Continuity record

Each station's references persist at `state/remote-dev-sessions/<station>.session`, schema `fm-remote-dev-session.v1`, one `key=value` per line:
`station`, `local`, `host`, `backend`, `session`, `workspace`, `window`, `tab`, `pane`, `task_id`, `project`, `branch`, `worktree`, `spawn_gen`, `return_channel`, `attach_command`, and `updated`.
The record is a cached projection for reconnect; `state/<id>.meta` remains the endpoint authority that `bin/fm-spawn.sh` owns.
A malformed or wrong-schema record refuses instead of being half-trusted.
The record is rewritten on every `open` and `recover`, so a restart or reconnect always reads current references.

## Attach and reconnect

The record's `attach_command` is the exact command shape for the selected backend and host.
For a remote station:

```sh
herdr --remote <host> --session fm-remote
ssh -t <host> tmux attach -t fm-remote
```

For a local station:

```sh
herdr --session fm-remote
tmux attach -t fm-remote
```

A remote named Herdr session survives disconnection because its server belongs to the host's own login session, and a tmux session survives because it is detached on the host.
So a reconnect is `bin/fm-remote-dev-session.sh attach <station>`, or `recover <station>` to re-run the gates and refresh the record first.

## Fleet surfacing

The durable records are visible through the existing fleet contracts.
`bin/fm-fleet-snapshot.sh --json` exposes them as the top-level `remote_dev_sessions` array, and `bin/fm-fleet-view.sh` renders a `Remote Development Sessions` table.
Both read the same record files; neither invents a second state source.

## Idempotency and safety

`open`, `recover`, and `check` are safe to re-run: a live endpoint is only attached, the record is rewritten atomically, and nothing is launched when the gates refuse.
The command never stops, restarts, or discards a session; retirement and teardown stay with `bin/fm-teardown.sh`.

## Verification

```sh
bin/fm-test-run.sh tests/fm-remote-dev-session.test.sh
FM_RDS_LIVE=1 FM_RDS_LIVE_STATION=<station> FM_RDS_LIVE_SECONDMATE=<id> \
  bin/fm-test-run.sh tests/fm-remote-dev-session-live-e2e.test.sh
```

The portable suite drives every boundary with stubs and real local git fixtures.
The live guard runs only the read-only `check` verb against a real station and skips cleanly when not opted in.
