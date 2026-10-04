# Upstream synchronization verification - 2026-09-23

## Scope

- The fork tip before synchronization was `78ea0158efb74a2e214f129cc4322b624cb21deb`.
- The upstream tip merged into the fork was `9296f9b9d2566797b9a9aecaa5956bb8e471d2cd`.
- The common merge base was `b84e0e362face25f3dd8945297a3df1320d7668c`.
- `git rev-list --left-right --count origin/main...upstream/main` printed `374 150` before the merge.
- The rollback tag `keep/pre-upstream-sync-20260923` was pushed to `origin` before the merge began.
- The synchronization uses a merge commit on `fm/fm-upstream-sync-20260923`; it does not rewrite fork history.

## Resolution record

### Upstream-owned rewritten snapshots

- The AFK contract, launch, return, and matching regression surfaces were resolved from upstream because the fork side contained only earlier synchronized snapshots, while upstream added durable away-posture, Pi parking, live-head merge gates, and cleanup fixes.
- The mail-check implementation and tests were resolved from upstream because the fork side contained only an earlier synchronized snapshot, while upstream added hardening and full-coverage CI fixes.
- The captain-hold implementation and lifecycle test were resolved from upstream because the fork side contained only earlier synchronized snapshots, while upstream added current status folding, due-field compatibility, self-wake suppression, and public-follow-up handling.
- The pending-reply, remote-backlog-handoff, supervision-protocol, Herdr client-pair fixture, and AFK Herdr return surfaces were resolved from upstream because the fork side contained only earlier synchronized snapshots and upstream carried the active fixes.
- The backlog-handoff and no-mistakes run helpers were based on upstream, with the fork's earlier merged-PR outcome repairs checked separately against the newer upstream outcome model.
- The local-merge helper and windowless Orca fixture were resolved from upstream because upstream superseded the fork snapshots with the active outcome and endpoint-cleanup models.

## Validation evidence

Validation commands and their exact results are added here as each required check completes.

### Backlog atomicity merge-regression investigation (open)

- The rollback parent, `keep/pre-upstream-sync-20260923`, passed `bin/fm-test-run.sh tests/fm-backlog-atomicity.test.sh` (93 checks; exit 0; 413407 ms).
- `upstream/main` also passed the same suite (exit 0; 367982 ms) when run with the compatible `tasks-axi` 0.2.6 binary.  Its first attempt correctly failed before the suite for an incompatible host `tasks-axi` 0.2.5, not for a test assertion.
- The merged worktree fails before the first spawn assertion with `error: treehouse returned no usable worktree path for .../dispatch-ok/project (got '')`.  It is therefore merge-introduced, not a pre-existing or flaky parent failure.
- The incompatible pieces are precise: the current merged `bin/fm-spawn.sh` uses the newer lease contract, `WT=$( ... treehouse get --lease ... )`, and requires that command to emit the worktree path on stdout.  `tests/lib.sh`'s default `fm_fakebin` correctly provides `fm_fake_treehouse`, which emits `${FM_FAKE_TREEHOUSE_WT:-${FM_FAKE_PANE_PATH:-...}}`; `run_spawn` sets `FM_FAKE_PANE_PATH="$case_dir/wt"`.
- The merged test fixture had overwritten that default stub with `fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes`.  Its `treehouse` replacement exits successfully without stdout, yielding the observed empty `WT`.  The fork parent contains the compatible fixture resolution: `fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes`, with a comment explaining why the worktree-emitting treehouse stub must remain.  The synchronization restores that one-line fork resolution, preserving the real worktree path through the lease mock.
- A second assertion reached after that repair exposed the same class of conflict-resolution mismatch: the fork's `fm-teardown.sh` deliberately permits a pre-`spawn_gen` record only after its recorded endpoint is confirmed dead or agent-less, while the merged test had retained upstream's older assertion that every no-`spawn_gen` record is rejected immediately.  The fork fixture replaces `tmux list-windows` with an unreadable endpoint probe and asserts the specific `not confidently dead or agent-less` refusal; restoring that fixture preserves the fork safety semantics and verifies that ambiguity still refuses teardown.
- After both fixture resolutions, `PATH="$PWD/.no-mistakes/upstream-sync-tools/node_modules/.bin:$PATH" bin/fm-test-run.sh tests/fm-backlog-atomicity.test.sh` passed all 93 checks (exit 0; 367912 ms) on the merged worktree.
