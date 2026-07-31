# Handoff — FirstMate crew + federated fleet work

**Date:** 2026-07-31
**Fork (this work):** https://github.com/adibirzu/firstmate
**Upstream (do NOT push here yet):** https://github.com/kunchenguid/firstmate
**Specs of record:** `/home/adi/firstmate-setup/docs/` — master design
`2026-07-26-firstmate-crew-design.md`, plans `plans/2026-07-26-plan1..plan3*.md`,
and PRDs `prds/2026-07-28-*-prd.md` (WI-1 … WI-7).

> **Read this first.** Every branch below is on the fork and **finished + tested**.
> The one intentionally-open item across all of it is the **live drained-account
> acceptance for Plan 3 Task 18** (needs a genuinely exhausted subscription — it
> cannot be faked locally). Implementation + hermetic tests for it are done.
> **Publishing gate:** nothing goes upstream until the captain runs **no-mistakes**
> over the branches and explicitly approves. Fork pushes are fine; upstream is not.

---

## 1. Where everything lives

- **Launch dir / live fleet home:** `~/kun-agent-workspace` (aliased `~/firstmate`).
  It is a *live* multi-operator fleet home — three operators are registered in
  `/opt/agents/fleet` and a heartbeat refreshes `seen` from this checkout. **Never
  edit `bin/` in the primary checkout**; work in a `state/worktrees/<name>`
  worktree and never `git stash` in any worktree of this repo (`refs/stash` is
  repo-wide and pops can swap changes between concurrent agents).
- **quota-axi (separate repo, WI-1):** `kunchenguid/quota-axi`, worked via
  no-mistakes; its branch is `feat/cli-credential-sources` on the no-mistakes
  remote `~/.no-mistakes/repos/2e034089dd80.git`.

## 2. Branch → work item → status (all on the fork)

| Branch | Work item | Status | Verify with |
|---|---|---|---|
| `federation` | Plan 2 (federation + multi-account) **+ Plan 3 Task 18** (cross-operator overflow on token drain) | ✅ done — Task 18 commit `0c19493` | `bash tests/federation/test_fleet_drain.sh` (ALL PASS ×3) |
| `fed-quota-pace` | WI-5 — align fleet quota layer with quota-axi 0.1.15 pace model | ✅ done | fleet quota suites |
| `fed-lib-split-reraised` | WI-7 — `test_fleet_ops.sh` hermetic + split quota layer into `fm-fleet-quota-lib.sh` | ✅ done | `bash tests/federation/test_fleet_ops.sh` (ALL PASS) |
| `fed-lib-split` | earlier WI-7 line | ✅ done | as above |
| `fm-pool-relocation-reraised` | WI-2 — fm1142 projected-teardown focus regression | ✅ done | `bash tests/fm-backend-herdr-presentation-e2e.test.sh` (exit 0) |
| `adapters-e2e-fixes` | WI-3/WI-4 copilot+cursor adapters **+ two live-dispatch bug fixes** (cursor trust gate false-failure; cline turn-end never detected on herdr) | ✅ done | `bash tests/fm-cursor-agent-harness.test.sh`, `bash tests/fm-copilot-harness.test.sh`, `bash tests/fm-watch-busy-staleness.test.sh` (all ALL PASS) |
| `local-adapters` | Plan 1/2 — cline + cursor-agent adapters (upstream PR #1104) | ✅ done | adapter harness suites |
| `local-adapters-copilot` | copilot adapter line (== `adapters-e2e-fixes` base) | ✅ done | as above |
| `fm/firstmate-subscription-aware-model-routing` | Plan 3 Task 17 — subscription-aware crew routing | ✅ done | subscription-routing suites |
| `fed-guard-hygiene`, `fleet-ops`, `fleet-integrated`, `fed-lib-split-pr-sync` | supporting fleet/adapter branches | ✅ done | their suites |

`fm/fm-pool-relocation` (local-only, `149b811`) is the **older pre-reraised** WI-2
line; the fork already holds the validated version (`ee0dba7` =
`fm-pool-relocation-reraised`). It was deliberately **not** force-pushed (that
would downgrade validated work). `main` is the base branch and was left alone.

## 3. What "finished" was verified against (2026-07-31)

- adapters suites (cursor / copilot / busy-staleness): ALL PASS
- `test_fleet_ops.sh` (WI-7): ALL PASS
- `test_fleet_drain.sh` + `test_fleet.sh` + `test_fleet_guards.sh`: ALL PASS
- fm1142 Herdr presentation e2e (WI-2): exit 0
- quota-axi `pnpm test` (WI-1): 24 files / 366 tests / exit 0
- `bin/fm-lint.sh` on each branch: exit 0 (pinned ShellCheck 0.11.0)

## 4. The one open item

**Plan 3 Task 18 Step 5 [USER] — live drained-account acceptance.** The dispatch
handoff, per-item handoff cap (`handoffs:N`, cap `FM_FLEET_HANDOFF_CAP` default 3),
and the explicit `status:drained` ("fleet out of tokens") state are all implemented
and hermetically tested. What remains is the real-world check: drain one operator's
surfaces **for real** (a genuinely exhausted subscription) and confirm work lands on
an operator with headroom, with no ping-pong and a loud "out of tokens" when the
whole fleet is drained. This cannot be faked locally and is a captain-gated step.

## 5. Next steps (in order)

1. Run **no-mistakes** over the finished branches (captain's gate before any
   upstream publishing).
2. Captain performs the Task 18 live drained-account acceptance.
3. Only after both: open/refresh upstream PRs against `kunchenguid/firstmate`
   (federation #1103, local-adapters #1104, fm/fm-pool-relocation #1142,
   fed-quota-pace #1187, quota-axi `feat/cli-credential-sources`, plus the new
   adapter fixes and Task 18 work).

## 6. Conventions to respect

- Harness adapters must be verified **empirically against the real harness**, never
  from docs alone (`CONTRIBUTING`).
- Keep custom code on branches; `git pull --ff-only` on the clone must stay clean.
- No cross-uid home writes; the shared KB at `/opt/agents/fleet` is the only
  legitimate cross-operator surface. Credentials stay `0700`.
- Tests are hermetic (no live agents, no network); use the repo's
  function-extraction + eval idiom for behavior tests.
- `bin/fm-lint.sh` must pass (pinned ShellCheck 0.11.0) before committing.
