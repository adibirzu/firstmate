# Fork layer on upstream firstmate

This repository is `adibirzu/firstmate`, a modular layer on top of [`kunchenguid/firstmate`](https://github.com/kunchenguid/firstmate) `main`.
Upstream history is an ancestor of this branch, so GitHub reports 0 commits behind once this branch is the default.
Future upstream syncs must use a merge commit, never a squash merge, so that ancestor relationship stays intact.

This file is the owner of the fork-layer layout: which components are fork-only, where they live, and which upstream files they may touch.
It does not restate each component's contract.
Each script header, skill, or docs page named below remains that contract's owner.

## Layout

Fork-only behavior lives in dedicated scripts, skills, plugins, docs, and tests.
Shared upstream files keep only the smallest call sites needed to invoke those components.

| Component | Owner paths | Role |
|---|---|---|
| Self-hosted runner health | `bin/fm-gha-runner-axi-lib.sh` | Resolve `gha-runner-axi` and its version floor before relying on self-hosted CI. |
| Stale-base / duplicate-work gates | `bin/fm-base-check.sh`, `bin/fm-duplicate-check.sh` | Refuse a fresh ship on a stale default-branch base or duplicate in-flight work. |
| Commit-identity push refusal | `bin/fm-commit-identity-check.sh` | Refuse a push whose author or committer does not match the operator identity. |
| Pulse fleet view | `bin/fm-fleet-pulse.sh` | Publish a consolidated fleet snapshot to a Pulse dashboard. |
| Remote spawn overflow | `bin/fm-remote-overflow-lib.sh` | Route a capacity-refused spawn to a remote secondmate home with headroom. |
| No-mistakes quiet updater | `bin/fm-nm-update-window.sh` | Apply beta-channel host upgrades inside a quiet window, never with `--force`. |
| commandopc WSL SSH | `bin/fm-commandopc-wsl-portproxy-refresh.sh`, `docs/commandopc-wsl-ssh.md` | Refresh WSL SSH portproxy for commandopc hosts. |
| Station bootstrap / idle | `bin/fm-station-bootstrap.sh`, `bin/fm-station-idle.sh` | Idempotent Linux SSH station seed, plus idle-window update gates. |
| Jev shadow / router-dispatch | `bin/fm-router-lib.sh`, `.agents/skills/router-dispatch/` | Feed task text into `llm-router-axi` and optional Jev shadow mode. |
| Herdr live fleet and tab names | `bin/fm-fleet-live.sh`, `bin/fm-herdr-name-lib.sh` | Auto-refresh a live Herdr fleet view and name tabs `adix-[host-]project-task`. |
| Model fallback | `bin/fm-model-fallback.sh` | Walk `llm-router-axi route chain` when a worker model depletes. |
| Remote-dev session continuity | `bin/fm-remote-dev-session.sh`, `docs/remote-dev-sessions.md` | Resume a remote development session on the same station. |
| Federation / multi-account | `bin/fm-fleet.sh`, `bin/fm-accounts-lib.sh`, `docs/fleet-addon.md` | Multi-operator accounts, quota surfaces, and fleet join. |
| Graphify | `bin/fm-graphify.sh`, `.agents/skills/graphify-orientation/` | Graph-first orientation of an unfamiliar tree. |
| Berths | `bin/fm-berth.sh` | One concurrent session per project in a home that opts in. |
| Cline / Copilot / Cursor Agent | `.agents/skills/harness-adapters/references/harness/{cline,copilot,cursor-agent}.md` | Extra crewmate/scout harnesses not in upstream's verified set. |
| Harness creator | `.agents/skills/harness-creator/` | Scaffold a new harness adapter from the verified pattern. |
| Context hygiene | `bin/fm-context-hygiene-lib.sh` | Clear a primary's own context after a configured idle. |
| Machine capacity | `bin/fm-capacity.sh`, `bin/fm-capacity-lib.sh` | Admit or refuse a spawn from measured machine headroom. |
| Two-stage code review | `bin/fm-review.sh`, `docs/code-review.md` | Deterministic-first OCR review on top of upstream `bin/fm-review-diff.sh`. |
| Runtime handoff | `bin/fm-runtime-handoff.sh` | Relaunch a live ship or scout onto another harness in place. |
| Model catalog refresh | `bin/fm-model-refresh.sh` | Record models each installed harness currently lists. |
| Crew names | `bin/fm-name.sh` | Derive a readable crew name from a task id. |
| Launch-drift | `bin/fm-launch-drift-lib.sh` | Compare recorded launch argv against the live process. |
| Direct-PR attestation | `bin/fm-direct-pr-attestation.sh` | Two-stage review attestation for `direct-PR` delivery. |
| Worker isolation check | `bin/fm-worker-isolation-check.sh` | Assert a ship is not running in the primary checkout. |
| OpenCode watch-arm helpers | `.opencode/plugins/lib/fm-watch-arm-close.js`, `.opencode/plugins/lib/fm-watch-arm-eligibility.js` | Extracted close and eligibility helpers for the primary OpenCode plugin. |

## Touch-points in upstream files

These shared files still carry small fork call sites.
Keep them minimal.
When upstream grows an equivalent extension point, move the fork logic out and drop the call site.

- `bin/fm-spawn.sh` - capacity, duplicate/stale-base, overflow, cursor ready-composer, extra harnesses, isolation.
- `bin/fm-watch.sh` / `bin/fm-watch-checkpoint.sh` - rearm-resurface absorb, fleet live refresh.
- `bin/fm-wake-drain.sh` - wider open-decisions byte bound.
- `bin/fm-procevent-lib.sh` - parser-depth / cmdsub nest guard.
- `bin/fm-session-lock-lib.sh` - current-session ownership re-admit.
- `bin/fm-config-inherit-lib.sh` - inherit `herdr-session-prefix`, `spawn-capacity`, and upstream `supervision-host-off`.
- `bin/fm-fleet-snapshot.sh` / `bin/fm-fleet-ledger.sh` - remote endpoint re-probe and self-describing invalid ledgers.
- `bin/backends/herdr.sh` - live tab names.
- `bin/fm-test-run.sh` - family membership and serial weights for fork-only tests.
- `.github/workflows/ci.yml` - install `llm-router-axi` / `usage-axi` for fork dispatch tests.
- `.github/workflows/no-mistakes-required.yml` - direct-PR two-stage attestation.
- `AGENTS.md` - load triggers for fork skills and the gha-runner-axi doctor pointer.

## Syncing upstream

1. Fetch `kunchenguid/firstmate` `main`.
2. Merge it with a merge commit (`git merge --no-ff`), never squash.
3. Re-run fork-only tests and `bin/fm-test-run.sh --check-coverage`.
4. If upstream added equivalent behavior, delete the fork copy and shrink the touch-point instead of keeping both.

Do not force-push `main` from an agent.
Replacing `main` is an owner operation after this branch is green.
