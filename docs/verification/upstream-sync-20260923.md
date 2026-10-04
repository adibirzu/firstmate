# Upstream synchronization verification - 2026-09-23

## Scope

- The fork tip before synchronization was `78ea0158efb74a2e214f129cc4322b624cb21deb`.
- The upstream tip merged into the fork was `9296f9b9d2566797b9a9aecaa5956bb8e471d2cd`.
- The common merge base was `b84e0e362face25f3dd8945297a3df1320d7668c`.
- `git rev-list --left-right --count origin/main...upstream/main` printed `374 150` before the merge.
- The rollback tag `keep/pre-upstream-sync-20260923` was pushed to `origin` before the merge began.
- The synchronization uses a merge commit on `fm/fm-upstream-sync-20260923`; it does not rewrite fork history.
- The completed union history from `origin/fm/fm-upstream-merge-0929` at `3670778effb86e8cd19ab06cc84ee5a857e7c10b` was merged as a second parent after the interrupted lane was recovered. That history contains both original tips and the conflict-resolution repair commits from the merged synchronization pull request, so no upstream or fork ancestry was flattened or discarded.

## Resolution record

### Upstream-owned rewritten snapshots

- The AFK contract, launch, return, and matching regression surfaces were resolved from upstream because the fork side contained only earlier synchronized snapshots, while upstream added durable away-posture, Pi parking, live-head merge gates, and cleanup fixes.
- The mail-check implementation and tests were resolved from upstream because the fork side contained only an earlier synchronized snapshot, while upstream added hardening and full-coverage CI fixes.
- The captain-hold implementation and lifecycle test were resolved from upstream because the fork side contained only earlier synchronized snapshots, while upstream added current status folding, due-field compatibility, self-wake suppression, and public-follow-up handling.
- The pending-reply, remote-backlog-handoff, supervision-protocol, Herdr client-pair fixture, and AFK Herdr return surfaces were resolved from upstream because the fork side contained only earlier synchronized snapshots and upstream carried the active fixes.
- The backlog-handoff and no-mistakes run helpers were based on upstream, with the fork's earlier merged-PR outcome repairs checked separately against the newer upstream outcome model.
- The local-merge helper and windowless Orca fixture were resolved from upstream because upstream superseded the fork snapshots with the active outcome and endpoint-cleanup models.

### Reconciliation against the completed union branch

- `bin/fm-crew-state.sh`, `bin/fm-supervise-daemon.sh`, and the AFK supervision contract retain the union branch's pause-governing fold. A later unrelated `resolved:` event cannot silently cancel a standing `paused:` or `captain-held:` declaration.
- `bin/fm-nm-run-lib.sh` retains live-over-terminal selection for a run bound to the same worktree. A newer terminal inventory row cannot hide an older still-live validation run, while a genuinely newer failure still wins.
- `bin/fm-pr-merge.sh` retains the union branch's pre/post forge read-back. A failed command stays failed unless the pre-read proved the PR was open and the post-read proves that exact attempt landed it; an already-merged pre-state never manufactures success.
- `bin/fm-teardown.sh` retains the union branch's windowless-record validation and fail-closed endpoint cleanup. The conflicting assertion that forced cleanup must always reap a window was discarded because the close adapter may have failed and the surviving endpoint must remain explicitly reported.
- `bin/fm-claude-trust.sh` keeps upstream's lab-home, secondmate-home, linked-worktree, and consent checks, but moves its 127-line Node writer to `bin/fm-claude-trust-write.js`. This avoids a macOS Bash pipe-buffer deadlock before Node starts without weakening the atomic replacement or consent rules.
- The fork's current AGY 1.2.x behavior survives: `/exit`, exact standalone `Running...` / `Running command...` busy rows, effort-tier model suffixes, and base-model `xhigh`/`max` clamping to `high`. Free-form prose mentioning Running is not accepted as a busy signal.
- The fork's Cline and Copilot effort mappings survive. Copilot's own marker is evaluated before an inherited Claude marker, while structural ancestry still resolves contradictory evidence; the tests blind the invoking harness's ancestry rather than depending on which harness runs the suite.
- The fork's session-lock compatibility retry, contribution merge-authority import, GitHub URL port parsing, process-event Bash 3.2 empty-array guard, and quota-router documentation pointer survive. Each is additive to the union branch rather than a wholesale side choice.
- Fixture-only repairs preserve isolation: staged pane exports are decoded without counting submit keys, Orca temp roots tolerate an unavailable numeric uid, OMP/Copilot marker tests cannot inherit the suite harness, Pi fleet reports carry their claimed wake row, and scout Lavish wording follows the supported binary floor.

## Validation evidence

Validation commands and their exact results are added here as each required check completes.

### Backlog atomicity merge-regression investigation (resolved)

- The rollback parent, `keep/pre-upstream-sync-20260923`, passed `bin/fm-test-run.sh tests/fm-backlog-atomicity.test.sh` (93 checks; exit 0; 413407 ms).
- `upstream/main` also passed the same suite (exit 0; 367982 ms) when run with the compatible `tasks-axi` 0.2.6 binary.  Its first attempt correctly failed before the suite for an incompatible host `tasks-axi` 0.2.5, not for a test assertion.
- The merged worktree fails before the first spawn assertion with `error: treehouse returned no usable worktree path for .../dispatch-ok/project (got '')`.  It is therefore merge-introduced, not a pre-existing or flaky parent failure.
- The incompatible pieces are precise: the current merged `bin/fm-spawn.sh` uses the newer lease contract, `WT=$( ... treehouse get --lease ... )`, and requires that command to emit the worktree path on stdout.  `tests/lib.sh`'s default `fm_fakebin` correctly provides `fm_fake_treehouse`, which emits `${FM_FAKE_TREEHOUSE_WT:-${FM_FAKE_PANE_PATH:-...}}`; `run_spawn` sets `FM_FAKE_PANE_PATH="$case_dir/wt"`.
- The merged test fixture had overwritten that default stub with `fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes`.  Its `treehouse` replacement exits successfully without stdout, yielding the observed empty `WT`.  The fork parent contains the compatible fixture resolution: `fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes`, with a comment explaining why the worktree-emitting treehouse stub must remain.  The synchronization restores that one-line fork resolution, preserving the real worktree path through the lease mock.
- A second assertion reached after that repair exposed the same class of conflict-resolution mismatch: the fork's `fm-teardown.sh` deliberately permits a pre-`spawn_gen` record only after its recorded endpoint is confirmed dead or agent-less, while the merged test had retained upstream's older assertion that every no-`spawn_gen` record is rejected immediately.  The fork fixture replaces `tmux list-windows` with an unreadable endpoint probe and asserts the specific `not confidently dead or agent-less` refusal; restoring that fixture preserves the fork safety semantics and verifies that ambiguity still refuses teardown.
- After both fixture resolutions, `PATH="$PWD/.no-mistakes/upstream-sync-tools/node_modules/.bin:$PATH" bin/fm-test-run.sh tests/fm-backlog-atomicity.test.sh` passed all 93 checks (exit 0; 367912 ms) on the merged worktree.

### Reconciled-tree targeted suites

All commands below ran serially with the task-local `tasks-axi` 0.2.6 compatibility path prepended; no live Firstmate home was used.

- `tests/fm-claude-trust.test.sh`: exit 0, 65,902 ms.
- `tests/fm-agy-harness.test.sh`: exit 0, 92,092 ms.
- `tests/fm-procevent.test.sh`: exit 0, 499,449 ms.
- `tests/fm-session-lock-ancestry.test.sh`: exit 0, 55,676 ms.
- `tests/fm-crew-state.test.sh`: exit 0, 474,615 ms.
- `tests/fm-pr-merge.test.sh`: exit 0, 975,049 ms.
- `tests/fm-teardown-endpoint-safety.test.sh`: exit 0, 111,604 ms.
- `tests/fm-bootstrap.test.sh`: exit 0, 330,920 ms.
- `tests/fm-fleet-snapshot-view.test.sh`: exit 0, 186,049 ms.
- `tests/fm-backend-orca.test.sh`: exit 0, 66,859 ms.
- `tests/fm-brief.test.sh`: exit 0, 21,766 ms.
- `tests/fm-copilot-harness.test.sh`: exit 0, 17,067 ms.
- `tests/fm-omp-harness.test.sh`: exit 0, 81,596 ms.
- `tests/fm-pi-branch-extension.test.sh`: exit 0, 198,238 ms; two optional installed-package checks gate-skipped because `@earendil-works/pi-coding-agent` is not installed, while the branch behavior suite passed.
- `tests/fm-backlog-atomicity.test.sh`: exit 0, 484,645 ms.
- `tests/fm-pr-fork-repo.test.sh`: exit 0, 2,766 ms.
