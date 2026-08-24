---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array through subscription-aware routing: fail-closed capacity, spendPriority
  ranking, reserve, cooldown, telemetry age, and deterministic rotation.
  Load when a dispatch rule or default resolves to more than one profile candidate.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is the single owner of the judgment boundary around subscription-aware profile-array selection.
`bin/fm-dispatch-select.mjs` owns the exact telemetry, reserve, cooldown, spendPriority ranking, state, and deterministic rotation mechanics.
`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`quota-axi` remains data-only: it publishes `spendPriority` as a comparable scalar and never recommends, selects, ranks, or infers a route.
Do not add a daemon, opaque composite score, hard-coded model-specific policy, or producer-side route recommendation.

## Collect facts

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

## Authentication is scoped to the selected surface

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the candidate actually uses rather than collapsing a provider to a single status.
A provider can carry a healthy source beside a missing or expired one; the unused source's state is not the candidate's state.
A Pi-hosted family may authenticate through the vendor's own store with no `pi:`-prefixed source at all, which is normal and never evidence against the candidate.
When a credential's local classification is the only thing standing between a candidate and a block, get ground truth before blocking.
`bin/fm-vendor-auth-probe.sh` is the only approved vendor-credential probe; its `--help` owns the registered probes and mechanics.
It takes no harness, model, or provider and returns a fact, not a route: only `authenticated` and `unauthenticated` are ground truth, while `indeterminate`, `timeout`, and `unavailable` establish nothing and must never be read as either outcome.
Never launch a vendor CLI yourself, and never probe a credential store the candidate does not use.
Grok prepaid `credits` are unrelated to paid-window headroom; never read them as exhaustion.

## Fail-closed capacity, then spendPriority

The selector is the mechanical owner of dispatch capacity and of ranking among remaining eligible candidates.
It does not replace reasoning-class fit: keep only candidates that meet the required reasoning class before passing the set, and never use `spendPriority` or remaining quota to silently replace that class.
When every remaining candidate is tight, dispatch inside the strongest-reasoning class if one of those candidates can proceed, or stop and report that the strongest-class choice cannot proceed rather than downgrading it to spend or conserve quota.
That rule governs this selection, which is the initial dispatch decision.
The separate in-run `modelFallback` response to a model that depletes after dispatch (`AGENTS.md` section 4) walks the configured chain for the class already dispatched, so it never re-opens class choice.
An exhausted chain for the required class stops and reports there too, rather than relaunching beneath that class.

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

The exact defaults, bounds, state schema, failure exit, and test seams are owned by `bin/fm-dispatch-select.mjs --help` and the canonical config schema in `docs/configuration.md`.

## Selection order

Apply only among candidates satisfying required fit and strongest reasoning class.

1. Reduce the matched rule or default to comparable candidates after model/provider discovery.
2. Pass that exact object or array to `FM_HOME=<active-home> bin/fm-dispatch-select.mjs select`.
3. Read its sanitized per-provider diagnostics and selected JSON profile.
4. Pass the selected `harness`, `provider`, `model`, and `effort` axes to `fm-spawn.sh`; it records `provider` as routing evidence without forwarding it to the harness CLI.
   Its `--provider` accepts every routable provider, including `cursor` and `agy`, and a native harness refuses any provider but its own; `docs/configuration.md` owns which adapters are native.
   Omitting the field on a native harness is equally safe, because the recorded harness alone establishes that provider for a later `record-failure`.
5. If it exits 3, stop and report that no candidate has current dispatch-capacity evidence rather than choosing manually around the reserve, cooldown, or telemetry refusal.
6. If a running task with recorded routing-provider metadata records provider rate-limit or quota-exhaustion evidence in its status log, run `fm-dispatch-select.mjs record-failure --provider <provider> --task <id>` before retrying the candidate set.
7. Use `clear --provider <provider>` only after the credential or provider condition is known to be corrected; it clears the cooldown, not dispatch history.

The selector accounts for every provider in sanitized diagnostics and rejects duplicate profiles.
Another harness CLI cannot block the selected tuple's authentication check.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
