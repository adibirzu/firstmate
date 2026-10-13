# Fork layer on upstream firstmate

This repository is `adibirzu/firstmate`, a layer on top of [`kunchenguid/firstmate`](https://github.com/kunchenguid/firstmate) `main`.
Upstream history is an ancestor of this branch, so GitHub reports 0 commits behind once this branch is the default.
Future upstream syncs must use a merge commit, never a squash merge, so that ancestor relationship stays intact.

This file is the owner of the fork-layer boundary: what the fork adds, what it deliberately does not carry, and how to sync.
It does not restate any component's contract.
Each script header, skill, or docs page named below remains that contract's owner.

## Boundary

Upstream owns the lifecycle, task identity, approval and admission, watcher, wake acknowledgement, teardown, and merge authority.
Every file that `kunchenguid/firstmate` tracks is identical to upstream `main`, except the four repo-local policy files below and the carried patch to `bin/fm-spawn.sh`.
The fork adds files and edits no other upstream-owned script, test, or document to call them.

| Repo-local file | Why it differs from upstream |
|---|---|
| `.no-mistakes.yaml` | Runs the commit-identity check before the canonical lint, so a push with an unexpected author or committer identity is refused. |
| `.gitignore` | Ignores the Graphify cache and the review scratch directory. |
| `docs/documentation-audiences.json` | Classifies the fork-only documents so `bin/fm-doc-audience-check.sh` stays green. |
| `bin/fm-test-run.sh` | Carries serial duration hints for fork-only tests so the unhinted-script guard keeps its upstream threshold. |

To audit the boundary, compare the tree to upstream: `git diff --stat upstream/main -- . ':(exclude).no-mistakes.yaml' ':(exclude).gitignore' ':(exclude)docs/documentation-audiences.json' ':(exclude)bin/fm-test-run.sh' ':(exclude)bin/fm-spawn.sh'` lists fork-only additions and nothing else.

## Fork-only components

These are standalone: an operator or a skill runs them directly, and no file upstream owns calls them.
They are the reusable operator features intended to ship as AXI packages.
Until a published package exists, they stay here, and each moves out as its package lands.
Components whose call sites are not carried are listed under Dormant components below.

| Component | Owner paths | Role |
|---|---|---|
| Multi-account registry | `bin/fm-accounts-lib.sh`, `bin/fm-account-env.sh`, `bin/fm-account-exec.sh`, `bin/fm-accounts-prereq.sh`, `bin/fm-spawn-acct.sh` | Per-operator accounts with isolated auth and per-spawn account selection. |
| Federation | `bin/fm-fleet.sh`, `bin/fm-fleet-lib.sh`, `bin/fm-fleet-join.sh`, `bin/fm-fleet-preflight.sh`, `bin/fm-fleet-quota-lib.sh`, `bin/fm-fleet-wait.sh`, `bin/fm-handoff-doc.sh`, `.agents/skills/federation/` | Shared multi-operator KB, quota surfaces, and handoff documents. |
| Fleet views | `bin/fm-fleet-pulse.sh`, `bin/fm-fleet-live.sh`, `bin/fm-fleet-herdr-collect.sh`, `bin/fm-herdr-name-lib.sh` | Pulse page data, a live Herdr fleet tab, and the tab name prefix it uses. |
| Graphify | `bin/fm-graphify.sh`, `.agents/skills/graphify-orientation/` | Graph-first orientation of an unfamiliar tree. |
| Router consumer | `bin/fm-router-lib.sh`, `bin/fm-dispatch-select.mjs`, `bin/fm-install-router-axi-tools.sh`, `.agents/skills/router-dispatch/` | Resolves the installed `usage-axi` and `llm-router-axi` and documents the dispatch call site. |
| Runner health | `bin/fm-gha-runner-axi-lib.sh` | Resolves `gha-runner-axi` and its version floor. |
| Model catalog | `bin/fm-model-refresh.sh`, `bin/fm-openrouter-quota.sh` | Records the models each installed harness lists and reads OpenRouter capacity. |
| Stations and remote development | `bin/fm-station-bootstrap.sh`, `bin/fm-station-idle.sh`, `bin/fm-check-shim-lib.sh`, `bin/fm-remote-dev-session.sh`, `bin/fm-nm-update-window.sh` | Station seed, idle-window gate, remote session continuity, and a quiet-window no-mistakes updater. |
| Commit identity | `bin/fm-commit-identity-check.sh` | Refuses a push whose author or committer is not the operator identity. |
| Context report | `bin/fm-context-report.sh` | Measures supervising-agent context growth per wake. |
| Harness creator | `.agents/skills/harness-creator/` | Scaffolds a harness adapter from the verified pattern. |

## Supported integration surfaces

Upstream supports exactly two ways to attach external behavior without editing its scripts.
A trusted external package can provide a long-polling process-event adapter, bound per home under `config/extensions.d/` ([extension-bindings.md](extension-bindings.md)).
A deterministic condition and action pair can be registered as a watch with `bin/fm-procevent-when.sh`.
Both are detectors that wake firstmate; neither can refuse a spawn, replace an agent, or change a lifecycle step.
Every capability in the next section needs more than detection, so none of them fits either surface today.

## Carried patch

One fork edit to an upstream-owned script is carried, because upstream has no extension point for it.
`bin/fm-spawn.sh` sources `bin/fm-capacity-lib.sh` and `bin/fm-remote-overflow-lib.sh`, runs the machine-capacity guard (with remote overflow of a refused fresh ship or scout) after the state-directory check, and runs `bin/fm-duplicate-check.sh` for a fresh ship after the worktree base is freshened, with `--duplicate-ok` as the explicit override.
Both blocks are delimited and self-contained, so an upstream merge re-applies them as an insertion.
Delete them when upstream gains an admission hook.

## Dormant components

These fork components are still in the tree, but the edits that called them from files upstream owns are not carried, so nothing invokes them.
They are not migrated and not verified against the upstream core; each stays until a tested package implementation or an upstream extension point replaces it.
Running one by hand can work, but the integrated behavior it once had does not exist.

| Capability | Dormant files | What upstream would need |
|---|---|---|
| Stale-base gate | `bin/fm-base-check.sh` | Brief and promote steps that name a command rather than a fork script. |
| Restored-worker launch drift | `bin/fm-launch-drift-lib.sh`, `bin/fm-launch-drift-identity-lib.sh` | Launch identity recorded in task metadata and a read-only drift verb. |
| Herdr task-tab names and per-project berths | `bin/fm-herdr-name-lib.sh` (also used by the fleet tab), `bin/fm-berth.sh` | A label template setting in the Herdr backend and state-slice support. |
| In-run model fallback and in-place runtime handoff | `bin/fm-model-fallback.sh`, `bin/fm-runtime-handoff.sh` | A documented in-place relaunch verb on `fm-control.sh` and a watcher status-event callback. |
| Own-agent context hygiene, file-configured wake-coalescing window and idle-heartbeat backoff | `bin/fm-context-hygiene-lib.sh` | A watcher-side idle callback and a setting for each window; upstream reads only the matching environment variables. |
| Extra crewmate adapters (cline, copilot, cursor-agent) | the three harness reference documents, their verification documents and tests | A per-adapter registry that `fm-spawn.sh` and `fm-control.sh` read. |
| Two-stage code review and the direct-PR attestation bypass | `bin/fm-review.sh`, `bin/fm-install-ocr.sh`, `bin/fm-direct-pr-attestation.sh`, `docs/code-review.md` | Review belongs to the no-mistakes pipeline; the attestation bypass is not wired into the required-pipeline workflow. |
| Per-crew usage row | `bin/fm-crew-usage-lib.sh`, `bin/fm-statusline-quota.sh`, `bin/fm-statusline-quota-lib.sh` | A renderer hook in the fleet snapshot; `usage-axi` owns the data. |
| Worker isolation assertion and treehouse user config | `bin/fm-worker-isolation-check.sh`, `bin/fm-treehouse-lib.sh` | Upstream already asserts isolation in its own brief and spawn; the lease config needs an upstream decision. |
| Crew names | `bin/fm-name.sh` | A name-resolver setting read by the session-start digest. |
| Fork fixes to upstream-owned scripts | the tests that pin each fix | Upstream pull requests; each fix is recorded with its original commit in the maintainer's private disposition. |

The full pre-merge history, including the original call sites, remains reachable from this repository's history.

## Syncing upstream

1. Fetch `kunchenguid/firstmate` `main`.
2. Merge it with a merge commit (`git merge --no-ff`), never squash.
3. Resolve any conflict in an upstream-owned file by taking upstream's version.
4. Re-run the fork-only tests and `bin/fm-test-run.sh --check-coverage`.
5. If upstream added equivalent behavior to a fork-only component, delete the fork copy.

Do not force-push `main` from an agent.
Replacing `main` is an owner operation after this branch is green.
