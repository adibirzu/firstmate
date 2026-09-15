---
name: router-dispatch
description: >-
  Agent-only dispatch procedure that turns a task descriptor into one
  harness/model/effort decision through llm-router-axi, resolves a matched
  subscription-aware profile array, passes its flags to fm-spawn, records
  outcomes with llm-router-axi record, and covers per-account launches. Load
  before choosing a worker or reviewer runtime, before resolving a
  subscription-aware profile array, or before launching under a chosen
  provider account.
user-invocable: false
metadata:
  internal: true
---

# router-dispatch

This skill is the single owner of the dispatch judgment boundary for a fleet with the axi router tools installed.
It routes a task descriptor through `llm-router-axi`, resolves a matched subscription-aware profile array, folds the per-account launch procedure into the same place, and points at the kept in-repo paths for the capabilities the tools do not yet cover.

`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`llm-router-axi select` is the mechanical owner of arbitrary-profile selection, `llm-router-axi route chain` owns in-run step-down, `llm-router-axi classify-evidence` owns the subscription-exhaustion vocabulary, and `bin/fm-model-fallback.sh` owns the hosted-region opt-in refusal signature.
`bin/fm-dispatch-select.mjs` is a thin forwarding shim over those verbs, kept only so existing callers keep their command line.
`quota-axi` remains data-only: it publishes `spendPriority` as a comparable scalar and never recommends, selects, ranks, or infers a route.
Do not add a daemon, opaque composite score, hard-coded model-specific policy, or producer-side route recommendation.
`quota-array-dispatch` is retained for one release as a pointer back to this skill; this skill now owns the selection judgment boundary that file used to hold.

## Preferred path: route the descriptor

The routing doctrine is the human-editable policy file `~/.config/llm-router-axi/policy.json`, not code in this repo.
`llm-router-axi policy init` writes the bundled default, `policy show --full` expands every lane, and `policy validate` checks a file.

For a task described by kind, difficulty, and surface, ask the router for the decision and hand its flags to `fm-spawn.sh`:

```sh
llm-router-axi route --kind ship --difficulty medium --surface backend --flags
# -> --harness opencode --model opencode-go/deepseek-v4.1-flash --effort medium
```

- `--kind` is `ship`, `scout`, `review`, `architecture`, or `admin`.
- `--difficulty` is `easy`, `medium`, or `hard`.
- `--surface` is `backend`, `frontend`, `docs`, `infra`, or `mixed`.
- `--json` emits the decision with `provider`, `pool`, `reason`, ordered `fallbacks[]`, and `capacity{ok,measured}`; `--usage-json <path>` routes from a fixture.
- The router reads telemetry from `usage-axi --json --full`, resolves provider identity including `opencode` pools, and refuses a route the machine-capacity thresholds reject.
- The router refuses when no candidate has current dispatch capacity; stop and report that rather than choosing around the refusal.

After a worker reaches a rate-limit or quota outcome, feed it back so the router's cooldown and least-recent-use ledger stay current:

```sh
llm-router-axi record --provider <usage-axi provider> --outcome rate_limit --task <id>
llm-router-axi record --provider <usage-axi provider> --outcome ok --task <id>
```

`reason` and every `fallbacks[]` entry reuse the in-repo selector's frozen rejection vocabulary, so the two paths agree on why a candidate was dropped.

## Matched profile array

Apply this procedure only among candidates satisfying required fit and the strongest reasoning class.

### Worker-side quota helper

The canonical shell helper for a worker that has already performed its model-selection reasoning and now needs to pick the first viable candidate is `bin/fm-quota-choose.sh`.
Pass it the intake's already-captured default TOON or permitted JSON fallback through stdin or `--snapshot`; it never takes another quota snapshot, so it selects from the same quota state as the intake.
Pass each candidate as `harness:model`, with earlier candidates preferred.
The helper maps each harness to its primary provider family and applies the provider-wide scopes plus the exact model or product scopes for the model.
An `exhausted_now` runway vetoes the candidate.
The helper selects a candidate only when its applicable quota has a known `effectivePercentRemaining` greater than zero.
This is an optional narrow helper with a known limitation: it maps each harness to one primary provider family only, so a candidate whose established provider differs from that primary family is checked against the wrong quota row.
omp has no primary family, so the helper keys an `omp:` candidate on its model prefix, mapping only `openai-codex/` and `claude-bridge/` and refusing every other prefix; the helper's header owns that mapping.
Authoritative multi-provider routing - including provider discovery from the harness catalog and quota matching by that explicit provider - stays owned by this skill's matched-array procedure and `AGENTS.md` section 4, not by the helper.
Use it only when the brief already fixed the candidate order and every candidate's provider is the harness's primary family.
It does not replace the reasoning-class, runway-feasibility, or authentication gates below.
Firstmate can optionally arm `bin/fm-procevent-quota.sh` for a recurring mid-task check that wakes when the tracked provider drops below its configured threshold or its runway becomes `exhausted_now`.

### Read the default TOON

Start each intake by running `quota-axi` once with no `--json`, and reuse that one default TOON snapshot for every candidate.
Its `quota[]` row carries the `spendPriority`, `effectivePercentRemaining`, `runway`, `confidence`, `limitedBy`, and `resetsAt` this procedure judges on, and sparse `exhaustion[]` carries finite runway seconds only for `projected_exhaustion` and `exhausted_now`.
Fall back to a single `quota-axi --json` call only when that snapshot is genuinely ambiguous for the decision or the installed build predates the `spendPriority` floor, then reuse that result and take no further quota snapshots.

Establish model support and provider identity through the discovery surface owned by `harness-adapters` before selection.
An adapter that is native to a subscription provider establishes that same-named provider without a redundant profile field; `docs/configuration.md` owns which adapters those are.
Every other adapter needs an explicit `provider` field when it enters subscription-aware selection, because model spelling never proves provider identity.
For each candidate, preserve explicit `harness`, `model`, and `provider` where present, then account for:

- task/profile fit and required reasoning class
- whether it belongs to the task's required fit and strongest acceptable reasoning class
- whether the native or explicitly declared provider relationship is established
- whether the candidate may be handed to the selector without silently changing model, harness, or effort

Do not pass a weaker reasoning class merely because it has more quota.
Do not pass a candidate whose provider relationship or current model support remains unresolved.

Confirm the catalog lists the candidate's model and record the provider family it reports.
A model the catalog does not list is concrete contradictory evidence: block that candidate and quote the catalog result.
Malformed configuration is an actionable error, not a candidate to rank around.

### Authentication is scoped to the selected surface

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the candidate actually uses rather than collapsing a provider to a single status.
A provider can carry a healthy source beside a missing or expired one; the unused source's state is not the candidate's state.
A Pi-hosted family may authenticate through the vendor's own store with no `pi:`-prefixed source at all, which is normal and never evidence against the candidate.
When a credential's local classification is the only thing standing between a candidate and a block, get ground truth before blocking.
`bin/fm-vendor-auth-probe.sh` is the only approved vendor-credential probe; its `--help` owns the registered probes and mechanics.
It takes no harness, model, or provider and returns a fact, not a route: only `authenticated` and `unauthenticated` are ground truth, while `indeterminate`, `timeout`, and `unavailable` establish nothing and must never be read as either outcome.
Never launch a vendor CLI yourself, and never probe a credential store the candidate does not use.
Grok prepaid `credits` are unrelated to paid-window headroom; never read them as exhaustion.

### Fail-closed capacity, then spendPriority

The selector is the mechanical owner of dispatch capacity and of ranking among remaining eligible candidates.
It does not replace reasoning-class fit: keep only candidates that meet the required reasoning class before passing the set, and never use `spendPriority` or remaining quota to silently replace that class.
When every remaining candidate is tight, dispatch inside the strongest-reasoning class if one of those candidates can proceed, or stop and report that the strongest-class choice cannot proceed rather than downgrading it to spend or conserve quota.
That rule governs this selection, which is the initial dispatch decision.
The separate in-run `modelFallback` response to a model that depletes after dispatch (`AGENTS.md` section 4) walks the configured chain for the class already dispatched through `bin/fm-model-fallback.sh apply`, so it never re-opens class choice; under the standing auto-step-down rule it proceeds down that chain automatically even past the strongest entry, logging each switch.
When every dispatch-side candidate for the required class is spent, stop and report that the strongest-class choice cannot proceed - that is a selection decision, not a depletion response.

Providers exposed by quota-axi, including Claude, Codex, Grok, Cursor, and agy, require fresh telemetry within the configured maximum age and a tightest live percentage strictly above `reservePercent`.
Stale, unavailable, malformed, or windowless telemetry makes that provider ineligible for a new dispatch.
A provider whose pools are billed separately would be priced by its worst pool under that rule, so a profile may declare the one window it draws on with `quotaWindow`; `docs/configuration.md` owns that field's semantics.
Confirm the declared window against the provider's live telemetry before relying on it, because a declared window the telemetry does not carry blocks that candidate rather than repricing it.
Kimi is excluded from subscription-aware selection because its 0.29.1 lifecycle exit was not deterministic after interrupt in the guarded Herdr lab.
Do not pass a Kimi profile to the selector or substitute another Moonshot route.

When quota-axi's default TOON (floor owned by `bin/fm-quota-axi-lib.sh`) publishes a known `spendPriority`, that scalar is the quota-perspective ranker among candidates that already passed fail-closed capacity and reasoning-class fit.
A higher known scalar is better: positive means paid allowance is on track to reach reset unused, `0` is exact utilization, and negative means overdrawn against the reset clock.
Never treat absent, `unknown`, or unmeasurable `spendPriority` as zero or as healthy, and never recompute it from headroom, pace, reserve, or window-id lists.
Drop a candidate whose known runway will not last until the inspectable likely-completion horizon before passing the set, even when it has the highest `spendPriority`; `through_reset` passes because the window reaches its refill without exhausting, and unknown runway stays eligible with that uncertainty disclosed.
When every remaining eligible candidate lacks a known `spendPriority`, or when known scalars tie, the selector distributes by persisted least-recent use and breaks an initial never-used tie with a home-stable hash independent of candidate array order.
Do not replace that choice with static array order, harness-name order, randomness, or an unexplained "best quota" label.

The exact defaults, bounds, state schema, failure exit, and test seams are owned by `llm-router-axi select --help` and the router policy at `~/.config/llm-router-axi/policy.json`.

### Selection order

1. Reduce the matched rule or default to comparable candidates after model/provider discovery.
2. Pass that exact object or array to `llm-router-axi select`.
3. Read its sanitized per-provider diagnostics and selected JSON profile.
4. Pass the selected `harness`, `provider`, `model`, and `effort` axes to `fm-spawn.sh`; it records `provider` as routing evidence without forwarding it to the harness CLI.
   Its `--provider` accepts every routable provider, including `cursor` and `agy`, and a native harness refuses any provider but its own; `docs/configuration.md` owns which adapters are native.
   Omitting the field on a native harness is equally safe, because the recorded harness alone establishes that provider for a later `record-failure`.
5. If it exits 3, stop and report that no candidate has current dispatch-capacity evidence rather than choosing manually around the reserve, cooldown, or telemetry refusal.
6. If a running task with recorded routing-provider metadata records provider rate-limit or quota-exhaustion evidence in its status log, run `llm-router-axi record --provider <provider> --outcome rate_limit --task <id>` before retrying the candidate set.
7. Run `llm-router-axi record --provider <provider> --outcome ok --task <id>` only after the credential or provider condition is known to be corrected; it clears the cooldown, not dispatch history.

The selector accounts for every provider in sanitized diagnostics and rejects duplicate profiles.
Another harness CLI cannot block the selected tuple's authentication check.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.

## When the tools are absent

`bin/fm-router-lib.sh` owns tool resolution and the install hint.
Both tools are now required for the dispatch path: `llm-router-axi` owns selection, the step-down chain, the subscription-exhaustion vocabulary of the depletion classifier, and the machine-capacity verdict, and there is no in-repo fallback left.
When either is not on `PATH`, stop and report the missing tool rather than dispatching by hand.
Both are unpublished on npm, so build and install each from its GitHub main clone: `git clone https://github.com/adibirzu/llm-router-axi && cd llm-router-axi && npm ci && npm run build && npm install -g --prefix ~/.local .`, then the same for `https://github.com/adibirzu/usage-axi`; `bin/fm-router-lib.sh`'s `fm_router_axi_install_hint` owns the exact hint.
`bin/fm-capacity-lib.sh` declines a spawn rather than running unguarded when the router is absent.

## Per-account launches

One operator can hold several accounts of a provider, each its own auth, selected per spawn so quota is spread and credentials never bleed.
Registry: `config/accounts.json` (gitignored).
Libs: `bin/fm-accounts-lib.sh` (registry) plus `bin/fm-account-env.sh` (isolation).
Full reference: `docs/fleet-addon.md`.

Isolation is verified, never guessed: each account declares an `isolation` method that must match its harness per the matrix in `docs/fleet-addon.md` (`config-dir-env`, `config-dir-flag`, or `api-key-env`), enforced by `bin/fm-accounts-lib.sh`.

Secrets never touch argv or the registry: an api-key account stores a `key_file` path (a `0600` file in the operator's own home), and the key is read into the child's environment at launch, never onto the command line, a log, or git.
A `config_dir` or `key_file` under a foreign home is refused.

Procedure:

1. Prereq once, on demand: `bin/fm-accounts-prereq.sh` checks the CLIs are installed (`install` adds missing ones), then the operator logs in each account into its own config dir or key file, because auth is user-only.
2. Register: copy `docs/examples/accounts.json` to `config/accounts.json`, one entry per account, and validate with `fm_account_validate <name>`.
3. Pick by quota when useful: `fm_account_pick <harness>` returns the account with the most `quota-axi` headroom, ties going to the first registered, and no quota data going to the first registered.
4. Supervised spawn for config-dir accounts: `bin/fm-spawn-acct.sh <id> <dir> --account <name> [--model M] [--effort E]` composes an isolated launch command through `fm-spawn`'s raw-launch hatch, so no secret reaches argv and `fm-spawn` needs no edit.
5. Direct isolated launch for api-key accounts or non-supervised work: `bin/fm-account-exec.sh <name> <cli> [args]` reads the key into the child's environment, then execs.

Limits, from `docs/fleet-addon.md`: cursor OAuth mode is not per-spawn isolatable, so use API-key mode; api-key accounts cannot use the supervised `--account` path because it would put the key on argv; and `quota-axi` is per-provider on the current auth, so real two-account quota discrimination needs each account separately authed with credentials quota-axi reads.
