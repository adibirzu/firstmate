# Stale-PR triage: 2026-08-29

Triage of four PRs opened against the fork (`adibirzu/firstmate`) while `origin/main` was broken
for ~21h on three `Behavior portable serial N` shards (a dropped handoff plus a test fixture with
an expired hardcoded date). Main is now repaired and green at `1a92f9e` (all 12 checks pass).
This record explains why none of the four were rebased and pushed, contrary to the original plan
of "rebase every still-wanted PR" — closer inspection surfaced a genuine blocker on each one.

## Method

For each PR: read its own producing task's `state/<id>.status` and `state/<id>.meta` under the
`fm-infra` secondmate home (`.../firstmate-8bf1b0/2/firstmate`), checked `no-mistakes axi status`
in that task's worktree for pipeline custody, diffed the PR branch against `origin/main`, attempted
a rebase in an isolated temp branch inside this triage worktree (never in the owning task's
worktree), and ran the relevant test file where a rebase succeeded cleanly.

## PR 21 — fix: bind session locks to session identities (issue 2883)

**Verdict: NEEDS-WORK.**

Content is not on `main` (`bin/fm-session-lock-lib.sh` on main has no session-identity-binding
logic) and is not duplicated by any other open PR or live task, so it is still wanted. The branch
rebases cleanly onto current `main` with zero conflicts (5 commits, all preserved).

But `tests/fm-lock-ownership.test.sh` fails on **both** the original branch and the rebased tree:

```
not ok - an unidentifiable session fell through to legacy compatibility: lock acquired: harness pid ...
```

This is not a rebase artifact or a flake — it is the exact fail-closed guarantee issue 2883 exists
to establish (an unidentifiable Claude session must refuse to acquire the lock rather than falling
back to legacy compatibility), and it does not hold on the PR's own un-rebased commits either. The
PR's own task (`fm-lock-ownership-2883`) went idle 2026-08-25 with `no-mistakes` run
`01M0SRHBZ304M2KYPX33DXK0HY` reporting terminal outcome `failed` / `error: daemon shutting down`
(not a live custody hold — safe to touch, just needs the actual fix). Recommend: return to
`fm-lock-ownership-2883` (or a fresh task) to fix the fail-closed regression before any rebase.

## PR 18 — fix(watch): make per-window marker keys injective via shared v2 byte encoder (issue 2878)

**Verdict: NEEDS-WORK.**

Content is not on `main` (`window_key()` in `bin/fm-watch.sh` still folds `:`, `/`, `.` all to `_`,
non-injective, exactly as issue 2878 describes) and is not duplicated:

- The "issue 2878 worker" the launch brief warned about **is this PR's own producing task**
  (`fm-window-key-injective-2878`), not a separate competitor. No other task or open PR anywhere in
  this fleet or on the upstream tracker (`kunchenguid/firstmate#2878`, last comment 2026-08-23,
  "no open covering PR found") touches this defect. That task's `herdr` pane is idle and its last
  `no-mistakes` run (`01M0R7M4HE00750V3JK92D8241`) reached terminal `failed`/`refresh_required` —
  fully published (`push`/`pr` steps completed), not custody-held.
- PR 23 (`fm/fm-secondmate-watch-arm`) is a **different, disjoint** defect: OpenCode secondmate
  supervision arm-eligibility (`.opencode/plugins/fm-watch-arm-eligibility.js`), not marker-key
  encoding. Its file list has zero overlap with PR 18's (`bin/fm-marker-lib.sh`, `bin/fm-watch.sh`,
  `bin/fm-supervise-daemon.sh`, `bin/backends/herdr.sh`). PR 23's task (`fm-secondmate-watch-arm`)
  is the one genuinely live/active task in this whole batch (herdr `agent_status: working` at
  triage time, mid CI-checks wait) — it is unrelated to PR 18 and should proceed untouched.

Rebasing PR 18 onto current `main` produces **4 real content conflicts** in `bin/fm-watch.sh`, not
mechanical ones: `main` independently grew a steering-inbox-loss-detection call
(`inbox_steer_check`) inside the same stale-pane loop PR 18's key-encoder migration touches, and
independently changed `clear_pause_state`/`clear_pause_tracking` to take a pre-computed `key`
instead of a raw `win` (PR 18's commit still computes `key=$(window_key "$win")` internally at
those call sites). A correct merge means re-deriving PR 18's `fm_window_marker_key` migration
against `main`'s new call-site shapes, not picking one side — this is real work on the watcher's
wedge-detection backbone, not a safe blind auto-merge for a triage pass to attempt. Recommend:
resume `fm-window-key-injective-2878` (or a fresh task) to redo the migration against current
`main`, then push fresh.

## PR 17 — test: loosen fm-pi-watch-extension timeouts to fix loaded-runner flake

**Verdict: REDUNDANT — recommend closing.**

`origin/main` already carries this exact fix, landed under a different hash via
`db5dd6da sync: bring fork main to upstream/main, preserving all fork-only work (#22)`:
`tests/fm-pi-watch-extension.test.sh` on `main` sets `ARM_READY_TIMEOUT_MS=2000` (was 250) and
references it via variable at every call site PR 17 touches; the effective wait budget is already
raised. `git log -S "1.18.20"`-style verification confirms PR 17's literal diff (250→2000,
500→3000) is a strict subset of what upstream already shipped. No action needed — the flake this
PR targeted is already fixed on `main`. The PR's own task (`fm-pi-watch-timeout-flake`) independently
arrived at "admiral superseded fix framing" before stalling on a no-mistakes rebase-conflict run
that failed on Codex credit exhaustion; that stall is moot now that the fix is redundant.

## PR 15 — docs(verification): record OpenCode 1.18.20 verification and OpenRouter env-based model discovery

**Verdict: NEEDS-WORK (blocked on pipeline custody) — do not rebase from outside.**

Content is not on `main`: `docs/verification/runtime-backends.md` still shows `opencode | 1.18.11`
with no `## OpenCode` OpenRouter-discovery section, and `.agents/skills/harness-adapters/SKILL.md`'s
opencode heading is still dated `v1.15.7-1.17.6` / `1.18.4 busy-queue`. Not duplicated elsewhere.

However the producing task (`fm-opencode-routing`) is in `no-mistakes axi status`'s
`blocked_pipeline_owned_recoverable` state: its local pipeline sandbox holds an **unpublished**,
further-refined commit (`af2098e2 no-mistakes(review): Scope opencode 1.18.20 qualifier, fix repro
placeholder`) that is one round ahead of what's actually pushed to the PR (`d1e947cc`), and the
task's own last status line is an open `blocked [key=opencode-pipeline-test]` (no-mistakes test
worker went silent holding branch custody), never resolved. Per the custody contract, only that
task's own continuation (or an explicit `no-mistakes axi sync --recover` inside its worktree) should
touch this branch next — an outside rebase+force-push would blindly discard the already-refined,
unpublished round sitting in that sandbox. Recommend: resume `fm-opencode-routing` to recover
custody, publish the better commit, and push from there.

## Summary

| PR | Verdict | Action taken |
|----|---------|--------------|
| 21 | NEEDS-WORK | None — pre-existing fail-closed test failure, unrelated to rebase |
| 18 | NEEDS-WORK | None — genuine merge conflicts with main's independent watcher changes |
| 17 | REDUNDANT | None — recommend closing, `main` already has this fix |
| 15 | NEEDS-WORK (custody-blocked) | None — do not rebase outside the owning task's pipeline sandbox |

No PR was rebased or pushed. No PR was closed or merged (captain's call per the launch brief).
