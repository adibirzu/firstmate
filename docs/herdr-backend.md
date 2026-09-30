# Herdr runtime backend

This page covers running Firstmate workers on the Herdr runtime backend: setup, where tasks appear, how they are cleaned up, how input reaches them, and how their liveness is read.
Operators who choose Herdr, or who verify Firstmate against it, need it.

Herdr is an agent-native terminal backend with native per-pane agent state and push events.
Firstmate requires Herdr protocol 14 or newer.
Broad backend verification covers versions 0.7.1, 0.7.3, 0.7.4, 0.7.5, and 0.8.0.
Protocol-16 features remain gated by availability.
Default-on presentation spaces have a higher floor of Herdr 0.8.0 for the reason given under [Presentation spaces](#presentation-spaces).
Herdr provides the terminal session while Treehouse continues to provide task worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Find a topic

| What you want to know | Start here |
| --- | --- |
| Install Herdr and select it | [Setup](#setup) |
| Why a command ran on a different `herdr` client | [Client selection](#client-selection) |
| Where task tabs appear and how to watch them | [Watching and task containers](#watching-and-task-containers) |
| The one-task workspaces, their setting, and their cleanup | [Presentation spaces](#presentation-spaces) |
| Why a seeded default tab is or is not closed | [Default-tab prune safety](#default-tab-prune-safety) |
| What task metadata records for a Herdr endpoint | [Endpoint metadata](#endpoint-metadata) |
| How text and keys reach a worker and how delivery is confirmed | [Current transport behavior](#current-transport-behavior) and [Composer and injection safety](#composer-and-injection-safety) |
| What happens after a Herdr server restart and how liveness is judged | [Restart and liveness behavior](#restart-and-liveness-behavior) |
| How blocked transitions arrive and what happens without protocol 16 | [Push events and polling fallback](#push-events-and-polling-fallback) |
| Where the away daemon runs and how it stops | [Away-mode supervisor support](#away-mode-supervisor-support) |
| Stopping or deleting Herdr sessions during verification | [Destructive lab safety](#destructive-lab-safety) |
| Known limits and the test suite | [Active limits](#active-limits) and [Regression entry points](#regression-entry-points) |

## Setup

Pick Herdr when you want native busy, idle, and blocked state and accept the [active limits](#active-limits) below.

Prerequisites:

- Herdr protocol 14 or newer, installed from [herdr.dev](https://herdr.dev).
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).
- `python3` only for optional protocol-16 presentation-space ordering and native event subscription.

Herdr is dual-licensed AGPL-3.0-or-later or commercial.
Firstmate invokes its CLI as a separate process.

Select Herdr with local `config/backend` containing `herdr`, `FM_BACKEND=herdr` for one launch, or an explicit request to Firstmate.
A remote development session's named-session continuity, record, and attach command are owned by [`remote-dev-sessions.md`](remote-dev-sessions.md).
A remote second-mate agent is the one case with no choice: it always runs on Herdr, and [`remote-secondmates.md`](remote-secondmates.md) owns that requirement and the readiness its host must meet.

Herdr is also auto-detected when the primary runs natively under `HERDR_ENV=1` and is not inside tmux.
A tmux pane nested inside Herdr resolves to tmux because the innermost multiplexer wins.
An auto-detected Herdr spawn stays silent, matching the verified tmux default path.

### Spawn preflight and CI

Spawn stops before creating a Herdr container or acquiring a task worktree when `herdr`, `jq`, or the protocol floor is unavailable.
No separate first-run provisioning is required.

The required CI lane uses the pinned installers in `bin/fm-install-herdr.sh` and `bin/fm-install-treehouse.sh`.
Those script headers own release assets, checksums, download bounds, and post-install gates.
Real harness credential tests remain opt-in rather than part of default CI.

## Client selection

Each operation routed through the adapter's session-scoped CLI helper starts with the first `herdr` on `PATH` unless that session has already selected another client.
A host can carry more than one client, such as a self-updated copy in `~/.local/bin` beside a package-managed one, and a client older than the running server can receive error code `protocol_mismatch` on operational commands.
On that refusal the adapter reads `status --json --session <name>` from each distinct `herdr` on `PATH` in order, adopts the first one the running server reports compatible, and retries the command on it once.
The choice is reused only for later calls to the same session in that process; another session starts with the `PATH` default, and a later mismatch forces selection again so a changed server can return to that default.
Ordinary adapter operations make no selection read on the happy path, status that supplies neither `.server.compatible` nor both client and server protocols leaves compatibility unknown, and no other failure triggers a reselection.
`fm-remote-doctor.sh` reports the client selected for the remote session.
Removing or upgrading the shadowing client is the durable fix; `bin/backends/herdr.sh` "client selection" owns the mechanics.

## Watching and task containers

The ordinary topology puts one task tab per endpoint in the exact workspace of the Firstmate or secondmate that launches it.
When the launcher has no Herdr workspace to inherit, the adapter maintains one durable home-labeled workspace instead.
The primary home label is `firstmate`.
A primary home running a berthed session labels that workspace `firstmate@<berth>`, so concurrent per-project sessions in one home stay visibly separate (see [configuration](configuration.md#session-berths-configberths)).
The `@` separator keeps a berth distinguishable from the legacy `firstmate-<id>` secondmate workspaces noted below, which are never migrated automatically.
A secondmate home label is `2m-<secondmate-id>`, derived from its validated `.fm-secondmate-home` marker.
Workspaces created before the short label carry the legacy `2ndmate-<secondmate-id>` form; they are never renamed or migrated, and every label matcher keeps accepting them.

| Home | Workspace label |
| --- | --- |
| Primary | `firstmate` |
| Secondmate | `2ndmate-<secondmate-id>`, derived from its validated `.fm-secondmate-home` marker |
A secondmate launched by the primary receives a narrowly scoped home override during container creation.

### Watching tasks

Attach to the selected named Herdr session and switch to the relevant home workspace to watch its task tabs.
Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without attaching.

### Focus

Workspace and tab creation use `--no-focus`.
The first workspace in a completely empty Herdr session must become focused, because no prior target exists.
Later task creation does not intentionally steal focus.

### Placement beside the launcher

Herdr does not enforce workspace or tab label uniqueness, so a label can never decide where a worker goes.

Herdr 0.7.5 exports `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID` into every process it manages a pane for.
A Firstmate or secondmate agent's own commands inherit them.
Older injection shapes are unverified, so a claimed launcher pane without the injected socket identity cannot be trusted.

With presentation spaces disabled, a crewmate or scout is created in the exact workspace that identity currently resolves to.
That workspace is read live from Herdr rather than from the injected snapshot, so the worker always appears beside the agent that launched it.
Duplicate labels elsewhere in the session are irrelevant, and the globally focused workspace is never the target.
A `--secondmate` launch is the deliberate exception: it stands up that secondmate home's own workspace instead of joining the launcher's.

### Unresolvable launcher identity

A claimed parent identity that cannot be resolved exactly stops the spawn before any worker endpoint exists, rather than falling back to a label search.
That covers:

- A missing or unusable socket identity.
- A closed or unreadable launcher pane.
- A pane and tab that disagree about their workspace.
- A workspace missing from the session.
- A pane belonging to another named session or Herdr server.

### Firstmate running outside Herdr

Firstmate running outside Herdr entirely has no launcher workspace to inherit, so its workers use this home's own labeled workspace, created on first use.
That path needs the home label to identify exactly one workspace: two workspaces sharing it are an unresolvable placement and refuse rather than adopting either.
Avoid naming a personal workspace `firstmate`, `2m-<id>`, or legacy `2ndmate-<id>` for that reason, and because the adapter cannot distinguish that label collision from its own container.
An older secondmate workspace using `firstmate-<id>` is not migrated automatically; rename it manually before expecting new tasks or recovery to use it.
Recovery and list-live still scan the first workspace matching the home label, because they address panes they already recorded rather than choosing where new work goes.
The one recovery that does place new work is the control plane's reclaim of a destroyed endpoint.
It mints a replacement tab through this section's ordinary placement rules while pinning the herdr session the task's record names ([`agent-control.md`](agent-control.md) "Reclaiming a task whose endpoint is gone").

Existing task operations use recorded endpoint ids and do not move a live task when labels change.
The per-home workspace is reused while it has task tabs.
Closing its last tab can remove the workspace, and the next spawn recreates it.

## Session naming

Each new task tab Firstmate creates is labelled with the captain-visible display name `<prefix>-[<host>-][<owner>-]<project>-<task-id>`, composed by `bin/fm-herdr-name-lib.sh` so the fleet is readable on any connected machine.
`<owner>` is the launching firstmate home's workspace label (`firstmate`, `2m-<id>`), so one tab names the ship under work, the firstmate running it, and the work itself; an absent owner keeps the legacy owner-less shape byte-identical, and a mate-launched task renders e.g. `adix-adi1-2m-lifeos-adi1-usage-axi-add-quota-window`.
The prefix comes from local gitignored `config/herdr-session-prefix` and defaults to `adix`; it is inherited by secondmate homes so one branding prefix names the whole fleet.
`<host>` is inserted only when the home has an explicit host token: `FM_HERDR_HOST`, or local gitignored `config/herdr-session-host`.
An unconfigured home therefore renders the plain `<prefix>-<project>-<task-id>`, and a host-configured home renders `<prefix>-<host>-<project>-<task-id>`.
`config/herdr-session-host` is local and deliberately not inherited, because which machine a home runs on is a property of that machine.
A remote secondmate's initial launch seeds its own home's `config/herdr-session-host` with the route's registry host token when that file is absent, never clobbering an operator override, so the mate's own tab and every crewmate or scout it later spawns from that home share one host segment.
`<project>` is the registered project name (`firstmate` for a firstmate-repo task, the secondmate id for a secondmate agent), and `<task-id>` is the task id with one leading `fm-` stripped.
An adjacent duplicate segment collapses, so a primary-home firstmate-repo task (owner and project both `firstmate`) renders `<prefix>-firstmate-<task>`, and a secondmate agent (whose project equals its own id) renders `<prefix>-<owner>-<id>` rather than repeating itself.

The name is additive display only.
Identity, endpoint resolution, supervision, teardown, and recovery keep using the recorded `state/<id>.meta` endpoint, so `bin/fm-fleet-view.sh` and `bin/fm-crew-state.sh` are unchanged.
Only a freshly created tab takes the new name: an adopted endpoint keeps the label it was created with, a legacy `fm-<id>` tab is still matched and used as the husk-replacement alias, and an existing presentation journal reuses the label recorded in it, so no live session is renamed or restarted.
The same holds for the short mate workspace label: a live `2ndmate-<id>` workspace keeps serving its recorded tasks (identity stays in `state/<id>.meta`, never in the label) until its tabs drain, and only newly created workspaces take the `2m-<id>` form.

### Label width

Herdr renders each sidebar token with a fixed cell budget and right-truncates the overflow with an ellipsis, so label order is load-bearing: the fixed fleet head (prefix, owner) precedes the variable work tail, and a truncated label still names the fleet and the owning firstmate.
Measured against the real 0.9.0 client in an isolated lab session: the sidebar defaults to 26 columns (`ui.sidebar_width`, 18 minimum, 36 maximum, auto-scaling with workspace names), the default agents row is `state_icon, machine, workspace, tab` with the agent name on its own second row, and the default spaces row is `state_icon, workspace`.
A 19-cell `2ndmate-lifeos-adi1` workspace already rendered as `2ndmate-lifeos-ad…` in the indented agents view while the 14-cell `2m-lifeos-adi1` form fits whole; the tab strip above the panes renders full tab labels with room to spare, which is where the longer `<prefix>-<owner>-<project>-<task>` form reads completely.
`tests/fm-herdr-name-lib.test.sh` pins this degradation order by simulating Herdr's right-truncation at both measured budgets.

### Colour

Herdr exposes no programmatic per-tab colour: a session cannot set its own tab colour, and colour is a local sidebar-config decision (the 0.9.0 socket API schema carries no colour field on any tab, workspace, or pane parameter or result; verified against the 0.9.0 binary's `herdr api schema --json`).
What the label display name buys is a stable, greppable match key, and Herdr's own sidebar rule facility colours exactly the Firstmate tabs by it.
On 0.8.2 the sidebar can only style a token statically, with no conditional rule, so it cannot colour only the Firstmate tabs.
On 0.9.0 and newer, `[ui.sidebar.agents]` and `[ui.sidebar.spaces]` accept ordered per-token `rules` (`equals`, `contains`, `starts_with`, `gt`, `lt`) whose first match overrides the token style, so `starts_with = "<prefix>-"` paints exactly the Firstmate labels green.
So Firstmate sets the label, and a home on 0.9.0 or newer that wants its task tabs green adds this to its own `~/.config/herdr/config.toml`, replacing `<prefix>` with the configured `config/herdr-session-prefix` (default `adix`):

```toml
[ui.sidebar.agents]
rows = [
  ["state_icon", "workspace", { token = "tab", rules = [{ starts_with = "<prefix>-", fg = "#a6e3a1" }] }],
  ["agent"],
]

[ui.sidebar.spaces]
rows = [
  ["state_icon", { token = "workspace", rules = [{ starts_with = "<prefix>-", fg = "#a6e3a1" }] }],
  ["branch", "git_status"],
]
```

Firstmate deliberately does not write this file: the sidebar layout is the operator's own, and rewriting it risks clobbering existing rows.

Full cross-machine listing and shared navigation arrive with `herdr machine` in Herdr 0.9.0, not on the installed 0.8.2 client; upgrading every host is a separate fleet-wide decision rather than something this naming feature bundles.
Until then, inspect another machine directly: `herdr --remote <ssh-host> workspace list` lists that host's sessions and workspaces, `herdr --remote <ssh-host> session list` lists its named sessions, and `herdr --remote <ssh-host>` attaches to it.
Running `herdr` after SSH'ing into the host behaves the same way, and a host-configured task's machine is readable from its display name's `<host>` segment.

## Presentation spaces

Each new crewmate or scout is placed in a disposable one-task workspace by default, on Herdr 0.8.0 and newer.
A home opts out by writing `off` into local gitignored `config/herdr-presentation-spaces`, and forces the projection on by writing `on`.
An absent file leaves the choice to the version floor below, an empty file and the value `on` are both a deliberate opt-in, values are compared with whitespace stripped and case ignored, and an unrecognized value warns and follows the unconfigured default rather than failing a spawn over a purely visual setting.
The empty file is the historical presence-based opt-in form, so every home that had already enabled the projection stays enabled with no migration step, and no previously enabled home can be turned off by the default or by the floor.
A home that never created the file gains the projection at its next Herdr spawn on a supported release; that flip is deliberate, and it reaches only the Herdr backend because no other runtime backend has a projection path.

Projecting each task into its own workspace makes every task cleanup a workspace-emptying removal, which is the only removal shape Herdr's pre-0.8.0 focus defect touches, and the focus-safe removal plan below can only avoid it while the closing pane's shell can be proved lone, childless, and idle.
A persistent child of that shell - a `gitstatusd`, a `zsh-async` worker, or `direnv` - fails that proof permanently and forces the plain explicit close.
For a close that empties its workspace, the restore waits for that workspace to be observably removed before correcting focus, because removal is the transition that can steal focus and an earlier correction does not hold.
Each removal boundary permits 100 polls at 0.1 seconds, roughly ten seconds, then restoration retries the exact prior tab up to three times with up to 20 confirmation polls each, roughly six more seconds after removal is confirmed.
An operation that never moved focus returns immediately, and a removal that already landed resolves on its first read.
An unconfigured home is therefore projected only on a release at or above the 0.8.0 floor, where every workspace-removal primitive preserves focus and that proof stops being load-bearing.
Below the floor an unconfigured home uses the ordinary flat per-home layout instead and warns once per home per detected release, naming the running release and the upgrade that restores the projection.
That one-warning-per-release record is a `state/.herdr-presentation-floor-<release>` marker; deleting it only makes the same warning appear again, and an upgrade or downgrade re-announces itself because the release is part of the key.
The floor reads both the installed client's protocol and version and the selected named session's server signals while that server is running, requires both applicable releases to pass, and uses only the client when status positively reports no running server because that client will start it.
The unconfigured default is rechecked after the server is started or adopted and before any presentation journal or workspace is created, while an unreadable server state or release is treated as unsupported rather than guessed at.
An explicit `on` is honored below the floor, so a home that deliberately opted in is never silently downgraded; it accepts that documented focus move, and the exact prior-tab restore stays its backstop.
The floor has a single owner, the spawn-time gate, so cleanup for a projection that already exists always runs and never strands a workspace, whatever release the home is on now.
Upgrading Herdr to 0.8.0 or newer is the fix; writing `off` is the immediate mitigation for a home that cannot upgrade yet.
The setting is inherited into secondmate homes through the normal configuration-convergence owner, and the default needs no special convergence: the primary's absent file and the secondmate's absent file both mean the same unconfigured default, so leaving it converges a secondmate to that same default rather than turning it off, and only an explicit primary `off` propagates the opt-out.
A secondmate agent itself always stays in its ordinary parent workspace; only children launched by that home are eligible.
An unconverged opt-out keeps the default projection in that home until convergence.

### Presentation journal

Presentation is a best-effort visual projection, never task ownership or lifecycle authority.
A presentation journal is the per-task record in this home's `state/` that binds a task to its projected workspace.

Only a fresh task with neither metadata nor an existing presentation journal is eligible for projected creation.
Creation proceeds in this order:

1. Firstmate atomically publishes a three-field version 1 journal containing a random 128-bit base64url token, before asking Herdr to create anything.
2. After the new workspace converges to one exact task endpoint beneath one exact parent workspace id, the journal advances to a version 2 binding.
   That binding records the physical home, named session, endpoint, parent, and immutable expected labels.

Another parent with the same presentation label does not prevent publication or participate in restart reclaim.

The owning parent is the launcher's own exact workspace, resolved from the same identity the flat path uses, and falls back to a unique home-label lookup only for a Firstmate outside Herdr.
Projected children are never collapsed back into that parent; it is the placement and ordering reference the projection is bound under.
The normal task tab (see [Session naming](#session-naming) for its label) is created in the exact new workspace returned by Herdr.
Only the exact seeded default tab returned by the same workspace-create response can be pruned.
Before and after create, prune, order, abort cleanup, and normal cleanup, Firstmate verifies exact workspace, tab, pane, and active-focus ids.
An ambiguous response grants no mutation or cleanup authority.

### Ordering

Protocol 16 exposes `workspace.move` over the named session socket but no CLI subcommand.
`bin/backends/herdr-workspace-move.py` sends only that whitelisted method and verifies the complete returned workspace order.

Projected children are placed in one contiguous block immediately after their owning home when all of these are verifiable:

- The session layout.
- The protocol.
- The socket.
- `python3`.
- The machine-private per-session lock.

Existing legacy child labels may extend an already adjacent block read-only but are never renamed or migrated.
A foreign, ambiguous, detached, or manually interleaved child makes ordering skip with a warning rather than rewriting the layout.

Ordering failure never fails the task spawn.
Firstmate does not retry, adopt, reuse, close, delete, or rename anything in response to an unavailable method, lock contention, ambiguous socket, lost response, failed move, or verification mismatch.
The worker remains on the ordinary flat or Herdr-current-order path.

### Cleanup and focus safety

Normal task metadata remains the sole endpoint authority after creation.
Cleanup closes only the exact recorded task pane and never calls `workspace close`.
Herdr 0.7.5's explicit close moves focus to a neighbor whenever it empties a non-focused workspace, while its pane-death removal preserves the focused workspace whenever the dying workspace sits behind it or the focused workspace is last; both behaviors are fixed in Herdr 0.8.0, and the exact rules live in the adapter header of `bin/backends/herdr.sh`.
Projected cleanup therefore runs under the same session lock, refuses to delete the tab a live foreground client is viewing, and treats a workspace-emptying close as a focus-safe removal: it verifies the close would empty the workspace, repositions the doomed workspace behind the focused one through the verified `workspace.move` transport when needed, proves the pane holds one lone idle shell, and ends that shell so Herdr removes the emptied workspace through its focus-preserving pane-death path.
The persisted `.focused` pointer is not a live viewer: when `herdr terminal title clear` reports `no_foreground_client`, cleanup proceeds on that tab because no human is attached and skips restoration of the tab it destroys.
Herdr currently has no atomic client-aware mutation, so a fresh target-focus and foreground-client checkpoint runs immediately before each move, signal, or explicit close; when a live viewer has switched to another tab, that fresh tab becomes the restore target.
A client can still attach or switch focus in the residual checkpoint-to-mutation window, and a durable atomic close is deferred until Herdr exposes that primitive.
That exact-pane close and its focus restore run before the task worktree is returned to its pool, in both teardown and spawn-abort cleanup: under leased worktree acquisition the pane's own top-level shell sits in the worktree, so returning first would kill that shell and let Herdr's last-pane cleanup steal focus with no firstmate code left to restore it.
The repositioning move-to-last preserves every surviving workspace's relative order, and removal is confirmed against the exact moved workspace rather than inferred from pane disappearance before an unconfirmed removal makes one verified attempt under the same session lock to roll the doomed workspace back to its exact original position.
If that rollback cannot restore the verified original order, cleanup warns loudly and leaves the retained records for inspection rather than retrying the shared-layout mutation.
The pane-death signals are pid-exact: the escalation re-reads the pane's process information and refuses unless the same shell pid still passes the strict bare-idle ownership proof, so an exited and reused pid is never signaled.
Any ambiguity, unsupported or failed move, or unproved shell falls back to the plain explicit close, and the exact prior-tab restore remains the backstop behind every close.
An unresolved repositioned close can consume the ten-second removal boundary once for its moved-workspace decision and again in the restore before reporting uncertainty, roughly twenty seconds in the worst unresolved case.
Ordinary non-projected task removal serializes through the same session lock, applies the same focus-safe plan when its close would empty a non-focused workspace, keeps the legitimate plain close when the target is the active tab, and refuses an unlocked close if the lock cannot be acquired.
Task cleanup acquires that session lock before the task's isolated copy is returned, so a contended lock refuses up front while the copy, every durable record, and the endpoint are all intact for a plain rerun.
Forced secondmate cleanup recursively preflights every Herdr child endpoint and acquires every affected named-session lock before mutating any child, then retains each child's durable identity unless that exact pane returns structured not-found after its close.
Durable task records are erased only once the exact pane is confirmed gone through its structured presence: after every close path, only a structured not-found response counts as gone, while a present or unknown result retains every record with a visible, retryable error.
Missing or malformed endpoint identity and missing confirmation machinery are ambiguity, never proof of a gone pane, and refuse record removal the same way.
If lock, snapshot, pane identity, or restoration is ambiguous, cleanup warns and preserves the journal for manual inspection.
Once the exact pane is confirmed gone, teardown retires the task's own journal when it binds that same pane, or when it is a version 1 attempt whose token-bearing projected workspace is itself confirmed gone, because nothing then remains for the session-start sweep to correlate; a journal bound to any other pane, or a version 1 attempt whose workspace is still present or unreadable, stays for that sweep.

### Restart recovery

Recovery is deliberately conservative and presentation-only.
An existing journal suppresses another projected create.
Before any recovery mutation, Firstmate holds both the task spawn lock and the named-session presentation lock.

A same-identity version 2 binding may replace one exact agent-free restart husk in place.
A husk is a restored same-labeled tab with a missing pane or no registered agent, as [Restart and liveness behavior](#restart-and-liveness-behavior) describes.
The replacement is allowed only when all of these agree:

- The physical home.
- The session.
- The metadata endpoint.
- The unique token match.
- The workspace shape and labels.
- The parent identity and placement.
- The non-target focus snapshot.

The replacement tab and pane are created and verified before the old pane is rechecked and closed.
Then the journal advances atomically to the replacement endpoint before metadata publication.
The reclaim path never moves, closes, deletes, or renames a workspace and never touches a parent, sibling, captain, or foreign pane.
A failed replacement rolls back only the exact response-derived new pane when focus-safe verification permits it.

These cases fall back flat without mutating the old projection when duplicate-agent risk is positively absent:

- Version 1 journals.
- Dead or missing panes.
- Duplicate or absent tokens.
- Renamed or detached spaces.
- Cross-home mismatches.
- Inconsistent endpoint bindings.
- Active target tabs.
- Ambiguous identity or focus.

A live or unknown recorded or token-matched endpoint refuses duplicate launch.

### Startup cleanup of restored projections

Locked session start has one narrower cleanup for a restored projected child that is no longer current task state.
It runs only when the current home has at least one ordinary presentation journal, and it considers only that home.
A primary never recursively sweeps a secondmate home.

Discovery starts from the exact current `└ <concise-task> · p:<22-character-token>` grammar, but a title or token alone is never mutation authority.
A candidate must meet all of these conditions:

- The title must contain exactly one token occurrence across the named-session snapshot.
- The title must equal the title derived from exactly one valid presentation journal in this home's own `state/`.
- A version 2 journal additionally must bind this exact physical home, named session, workspace, tab, and pane.
- The task's ordinary metadata must be absent.
- The candidate must have exactly one tab and exactly one pane.

Firstmate then cleans up the candidate in this order:

1. Acquire the existing task-id spawn lock, and then the shared named-session presentation lock.
2. Inside both locks, take one exact snapshot.
3. Require one unambiguous non-target focus and the exact title, token, tab, and pane shape.
4. Positively confirm no registered agent.
5. Read Herdr's process information for the exact named-session pane and apply the process proof below.
6. Immediately revalidate the same journal, metadata absence, workspace title and token uniqueness, one-tab and one-pane topology, exact pane relationship, absent agent, process proof, and non-target focus.
7. Call the existing exact-pane focus-preserving close helper.
   It closes only that pane, never a workspace.
8. Retire the matching journal only after the exact pane is positively confirmed gone.

The process proof requires all of these:

- One recognized idle shell as both the shell process and the sole foreground process-group member.
- An operating-system process-table row for that shell.
- No child process.
- A sleeping or idle shell state.

The proof retries strict single samples for a bounded settle window, because an idle interactive shell transiently hosts short-lived prompt helpers.
A genuinely busy pane fails every sample.
Any foreground command, child process, active shell job, unknown shell, unreadable process table, missing field, or API error preserves the pane.

An unconfirmed close retains the journal.
A confirmed close may retire it even when focus restoration reported an error after the close.
A second run finds no matching title or journal and is a no-op.

Any of these preserves the candidate and lets session startup continue with at most a concise warning:

- A malformed or missing title or token.
- A duplicate token.
- Zero or multiple journal matches.
- A cross-home version 2 binding.
- Current metadata.
- A registered or unknown agent.
- An extra tab or pane.
- An active target.
- A busy lock.
- A changed revalidation.
- An unreadable check.
- Any error.

### Operational compromises

- Grouping is best-effort; only an exact same-identity version 2 binding survives a Herdr restart in place.
- A failed journal publication or projected workspace create stops that spawn instead of falling back flat.
  So a Herdr create failure surfaces as a spawn failure in every Herdr home, rather than only in homes that opted in.
  Every earlier degradation on the fresh projected-create path (no session server, contended presentation lock, absent or ambiguous parent) still warns and continues flat.
- Recovery of an existing presentation journal deliberately refuses the spawn when the shared presentation lock is contended, rather than falling back flat.
  Default-on makes that refusal reachable in any Herdr home.
- Existing layouts are not force-renamed or rearranged.
- Missing or ambiguous restart bindings fall back to the ordinary home workspace while the old projection remains untouched.
- Crashes, lost responses, failed exact-pane cleanup, or human renames can leave quarantined spaces.
  Session start removes only the exact home-local, uniquely journal-correlated, childless idle-shell shape above.
- Spaces have no cross-home cleanup path, and a secondmate child can clean up only from its exact home.
- Every stale-looking space outside that narrow startup proof still requires manual cleanup in Herdr's UI after human inspection.
- Regaining a dedicated space after degradation requires stopping the flat task, manually checking the stale projection, and clearing its journal before a genuinely fresh launch.
- The visible token is only a restart-stable correlator and never substitutes for the exact binding.

`tests/fm-backend-herdr-presentation-e2e.test.sh` covers multi-home ordering, concurrency, lock contention, legacy coexistence, focus preservation, exact same-identity restart replacement, ambiguous bindings and tokens, and exact-pane cleanup through the guarded lab path.
`tests/fm-herdr-session-cleanup.test.sh` covers every discovery, ownership, topology, process, locking, revalidation, focus, retirement, and continue-on-error boundary.
`tests/fm-herdr-session-cleanup-e2e.test.sh` covers the restored-shell cleanup in a guarded non-default named lab.
`tests/fm-backend-herdr-focus-flash-e2e.test.sh` reproduces the raw explicit-close focus steal on the installed release and proves the focus-safe emptying-close plan removes a doomed workspace with no wrong-focus interval; [`verification/runtime-backends.md`](verification/runtime-backends.md#workspace-removal-focus-safety) owns the active versioned evidence.
`tests/fm-backend-herdr-stale-active-tab-e2e.test.sh` proves a persisted-focused tab still closes when no foreground client is attached.

## Default-tab prune safety

`herdr workspace create` seeds one default tab.
Firstmate prunes it only after a real task tab exists and only when the same create response supplied the seeded tab id.
An adopted workspace never supplies that id and can never enter the prune path, regardless of labels or tab count.
Immediately before close, Firstmate rechecks the exact tab, expected seed label, and native agent state.
A working seed pane is never closed.

This created-versus-adopted gate is a destructive safety boundary.
A prior label heuristic could adopt a captain-owned workspace named `firstmate` and close its live seed-shaped tab.
The current structural gate removes label inference from cleanup authority.
`tests/fm-backend-herdr-prune-safety-e2e.test.sh` reproduces the collision in an isolated named session and proves the adopted pane remains untouched.

## Stale default-workspace reap

Herdr 0.8.2 seeds every fresh session with exactly one workspace labeled `~` before Firstmate ever calls `workspace create` (verified empirically against the real client).
`fm_backend_herdr_stale_default_workspace_id` identifies that scaffold only when the session has exactly one workspace and its label is that literal sentinel - but label and count alone cannot tell an untouched scaffold from a captain's own real, actively-used workspace that merely still carries the unrenamed default label, so two further guards are required:
- `HERDR_SESSION` must be explicitly set by the caller. When it is unset, `fm_backend_herdr_session` falls back to herdr's own ambient `default` session - the same session an operator's own interactive herdr usage lives in - and the reap never runs there, regardless of the candidate workspace's shape.
- The candidate workspace must have zero panes of any kind, checked by listing its panes directly rather than inferred from agent status - a live pane a captain is using manually, or one hosting an idle/finished agent, is still live work and would not be flagged as "working" by herdr's agent tracker. Any pane at all means a captain has actually used the workspace, and it is never reaped.

`fm_backend_herdr_workspace_ensure` reaps it, best-effort, right after creating this home's own workspace.
A failed reap never fails the spawn.

## Endpoint metadata

```text
backend=herdr
window=<session>:<pane-id>
herdr_session=<session>
herdr_workspace_id=<workspace-id>
herdr_tab_id=<tab-id>
herdr_pane_id=<pane-id>
```

A Herdr pane id contains a colon, so the adapter splits `window=` on the first colon only.
The recorded pane is the operational fast path.
Workspace and tab ids support verification and cleanup but are not inferred from mutable labels during normal operation.

## Current transport behavior

The adapter starts and polls a named server before operational workspace, tab, pane, or agent calls.
Passive supervision observations are the exception; [Launch-argv replay](#launch-argv-replay) owns that no-autostart contract.
### Named server and session routing

The adapter starts and polls a named server before workspace, tab, pane, or agent calls.
Every Herdr invocation goes through `fm_backend_herdr_cli`, which sets the environment and passes an explicit trailing `--session <name>`.
An environment variable alone is not reliable when another Herdr server is running.

When the selected named server is not running, the adapter launches it without these inherited values:

- Firstmate home and directory overrides.
- Harness identity markers.
- The supervision-model override.

Herdr passes its server startup environment to every later pane, so retaining those values could misroute panes for another Firstmate home or harness.
An already-running server is reused without restart or environment changes.
Explicit named-session routing and unrelated launch environment remain intact.

### Sending text and keys

Literal text and Enter are separate operations on `fm-send.sh`'s typed plane.
Ordinary local text steers instead use the durable steering inbox and send only its best-effort constant doorbell through this adapter.
Spawn-time fixed commands may use Herdr's atomic run primitive.
Enter, Escape, and Ctrl-C are supported.

Typed-plane slash input, and dollar-prefixed skill input for Codex, uses the shared harness-aware settle before the first Enter, so a completion popup cannot consume it.
Typed-plane text is typed once; only Enter is retried.

### Claude composer proof

When native `agent get` identity is Claude, the adapter types only into an empty composer.
A Claude composer that already holds text, or cannot be read, before the send is refused with nothing typed.
Before that Enter, the adapter continues only when the selected composer shows the typed payload, or only Claude paste placeholders with no literal remainder.
Every herdr adapter composer read (`fm_backend_herdr_composer_state`, `fm_backend_herdr_composer_content`) captures the full visible viewport, never a bounded tail, while the shared inbox pending-line confirmation read (bin/fm-task-inbox-lib.sh) stays a bounded tail on every backend: an overlay Claude renders between the composer and the pane bottom - the slash-command popup is the verified shape - pushes the composer outside a tail window, and the composer is by definition inside the viewport.
Dated measurement: docs/verification/runtime-backends.md "Claude exit behind the slash-command popup".

That comparison ignores whitespace and U+2063, the invisible mark that starts operational inputs and ends the from-firstmate label.
It ignores U+2063 because Claude's Herdr read-back never shows it.

A composer that holds a shorter suffix, or a placeholder plus a literal remainder, does not receive Enter.
Instead:

1. The adapter presses Ctrl+U until the shared classifier reads the composer as empty.
2. It then reports `send-failed`, so a resend starts from a clean composer.

Ctrl+C is not used for this, because Claude documents it as interrupting a running operation.
If the composer cannot be verified empty again, the submit reports `unknown` instead, because text may still be in the composer.

Other harnesses, and panes with no native identity, skip this proof and keep the type-then-Enter path.
They skip it because their paste placeholders and composer shapes are not live-verified.

### Submit confirmation

On an idle or done native baseline, submit confirmation proceeds in this order:

1. Wait for `working` or `blocked` across a bounded polling window.
2. If native status stays idle, use the shared composer verdict as the next positive signal.
   A cleared composer is delivery, and proven pending text retries Enter.
3. After the retry budget, `fm_composer_queued_enter_verdict` treats proven pending text plus a generating busy signal as a queued delivered Enter.
   It keeps an idle pending composer as a genuine swallow.

On an already active or unreadable baseline, the adapter falls back to conservative composer clearance.
That fallback adds a pre-Enter rendered-footer transition when the baseline is unavailable.
A fully unreadable target stops retrying and reports unknown.

`blocked` is not treated as a queued-Enter busy signal, so a Cursor pane that reports blocked in every state does not receive that conversion.

### Harnesses with no idle baseline

Some harnesses never present a legibly idle native baseline at all, so the composer fallback is their only path.

Cursor is one such harness:

- Herdr reports a Cursor pane `blocked` in every state.
- Cursor's mid-turn composer renders its placeholder beside a right-aligned busy token.
  That token is composer content, and therefore `pending` on a composer that holds no user text.

That fallback alone reported every delivered steer as unconfirmed.
So it is paired with a rendered-footer transition.
The pane's verified busy footer is read once before the first Enter, and an idle-to-busy transition across that Enter confirms the submit.
It is the same semantic signal the native path uses and the same one the tmux submit core reads.

A pane already mid-turn cannot borrow a rendered-footer transition as proof of this delivery.
After retries, only proven pending text plus native `working` can establish that its Enter was accepted and queued.

The composer verdict itself is deliberately unchanged.
A right-aligned status token on the composer row stays content for every other caller, including the away-mode pre-injection guard.

The poll density bounds the residual possibility of an extremely fast complete turn.
A missed native transition falls through to the composer verdict rather than reporting a false swallow.

### Capture size

`pane read --lines N` can return empty output when N is below the viewport height.
The capture owner requests at least 200 lines from Herdr and trims locally to the caller's bound.
This generous floor is required for the small bounded reads that remain: peek and watch tails, the rendered busy-footer read, and the shared steering-inbox pending-line read.
The adapter's own composer reads are exempt because they read the visible viewport instead, which takes no line count (see [Claude composer proof](#claude-composer-proof)).

### Native idle state

Herdr's native agent state can read idle while a harness waits on its own long foreground tool.
The shared crew-state path therefore accepts a native `busy` as evidence of activity.
It never accepts a native `idle` as evidence that a worker has stopped; the task's own semantic busy state (`bin/fm-busy-lib.sh`) decides that.
A human-blocked permission dialog has no busy banner and still surfaces.

## Composer and injection safety

Herdr has no direct cursor-row primitive.
The adapter is a thin capture.
It hands the visible pane's ANSI viewport plus Herdr's capability facts to the fleet-wide classifier in `bin/fm-composer-lib.sh`, which owns every shape:

- Bordered boxes.
- Bare agent-glyph rows, including muse's `⟩`, which the adapter's retired local pattern silently omitted.
- opencode's left bar.
- The Pi separator region this adapter pioneered, admitted only when native `agent get` identity is exactly Pi and state is idle or done.

### Pi composer states

A blocked Pi is parked on an interactive prompt, so its blank composer region is a menu's and not a free composer's.
That state defers instead of proving emptiness.
A working Pi, pending middle row, missing identity, incomplete separator pair, or over-tall candidate remains unknown or pending.
Identity stays a lazy second read, consulted only when a separator pair could change the verdict.

### Placeholder and ghost text

ANSI capture preserves de-emphasized placeholder style.
`bin/fm-composer-lib.sh` is the fleet-wide owner that strips dim or faint runs and dark truecolor placeholders while retaining bright typed input.

If the ANSI capture ever fails, the plain fallback declares itself unstyled.
The classifier then degrades a glyph row carrying trailing text to `unknown` instead of misreading ghost suggestions as typed input.
That safely defers injection and eventually raises the wedge alarm.

### Away-mode injection

A bare shell prompt is never an empty agent composer.
Away-mode injection proceeds only on an affirmative `empty` result, never on unknown.
This prevents a dead agent pane from receiving and possibly executing an escalation as shell input.

### Operational input markers

The current operational envelope starts with U+2063 and `FIRSTMATE_OP: `.
The separate routed-request carrier uses `[fm-from-firstmate]` plus U+2063.
U+2063 survives Herdr terminal input as text, unlike the legacy ASCII control separator that could erase the visible routing label.
Claude Code itself then removes it from the submitted prompt, so a Claude Code primary receives away-mode escalations as the owner's record-backed doorbell instead.
`bin/fm-operational-input.sh` owns current operational construction and parsing, and the AFK skill owns legacy away-input compatibility.
No Herdr-specific copy of that protocol exists.

## Restart and liveness behavior

### Husks after a server restart

Stopping and restarting a named Herdr server preserves workspace, tab, pane, and label ids.
The underlying harness processes and live agent registrations do not survive.
A restored same-labeled tab with a missing pane or no registered agent is a husk.

Create replaces only a confidently dead or no-agent husk, creates the replacement before closing the old tab, and refuses live or unknown states.
This prevents closing the workspace's last tab before a replacement exists.

The generic Herdr agent-liveness probe reuses the same pane classifier, then applies one recovery-only exception.
A structurally gone pane or a pane read from a session positively reported as having no running server becomes `missing`, a restored agent-less shell becomes `dead`, a registered agent becomes `alive`, and every other unexpected read becomes `unreadable`.
The stopped-server exception does not widen husk detection or any close authority; those paths still refuse an unreadable pane.
Unlike tmux process-name inspection, native registration can classify Pi without guessing from a generic interpreter name.

Native registration still identifies Pi by name where tmux would see a generic interpreter.
The process-level proof only decides whether that registration is backed by a running process.
`tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh` pins the live-Pi versus leftover-shell distinction.
[`verification/runtime-backends.md`](verification/runtime-backends.md#agent-lifecycle-control) owns the versioned evidence.

The session-start sweep and the watcher's dedicated secondmate liveness tick use this probe.
Idle secondmates remain exempt from stale-pane escalation.
[Secondmate endpoint recovery](architecture.md) owns the shared supervision mechanism.

## Agent status authority and relaunch

A pane has ONE status authority, and for Pi with the integration installed that authority is the lifecycle hooks - Herdr then skips screen detection for the pane, which is the `full_lifecycle_hook_authority` reason `herdr agent explain` prints for it.
That authority is bound to a session identity, and in the crew shape the registration outliving its process ([above](#restart-and-liveness-behavior)) is that same binding: the record stays, the agent it named is gone.

An agent started FRESH in such a pane reports a new session and Herdr ignores its reports, so the pane stays frozen at whatever the previous agent last reported - a crewmate running its pipeline reads `idle` until its task ends, and nothing from outside repairs it (measured 2026-09-21 on Herdr 0.9.1 against a real Pi; `pane report-agent-session` and `pane report-agent` for `herdr:pi` are accepted without being applied unless the reporter is the registered pane agent, and `pane release-agent` on the stale record changes nothing).
A fresh spawn never meets this: it gets a new pane with nothing bound.

So a **relaunch** preserves the binding instead of fighting it: before the Pi-family launch line is composed, `bin/fm-spawn.sh` reads the pane's recorded session reference through `fm_backend_herdr_pane_agent_session_ref` and passes it back as Pi's own `--session <path-or-id>` (`relaunch_resume_args`; `bin/fm-control-lib.sh`'s `fm_control_relaunch_resume_flag` owns which adapters and which registration labels qualify).
The replacement therefore starts on the exact identity the authority is bound to, and its `working`/`idle`/`blocked` reports land again.
The reference is the endpoint's own record, never a guess about which session is recent, and only a `pi` label may supply it: a registration belonging to another adapter is ignored, as is an unreadable, missing, or malformed one, in which case the relaunch is the ordinary fresh session it always was.
A relaunch that changes harness AWAY from Pi is not repaired by this and keeps the pre-existing behavior; only the adapter the authority belongs to can resume its session.

The session file may not exist any more: Pi creates it at exactly that path, so the identity survives either way.
The read grants no send, close, or lifecycle authority of its own - it is a read of Herdr's record.
The portable halves are pinned by `tests/fm-backend-herdr.test.sh` (the read, against a canned CLI) and `tests/fm-control.test.sh` (the per-adapter rule), and `tests/fm-control-herdr-smoke.test.sh` exercises the relaunch path against the real binary; the versioned live measurement, including the reproduction and the resume that lifts it, is [`verification/runtime-backends.md`](verification/runtime-backends.md) "Pane status authority across a relaunch".

### Launch-argv replay

Herdr does not replay a worker's launch command, and from 0.8.0 it records none at all.
A restored pane therefore comes back with no way to reconstruct the flags its agent was started with.

Earlier releases persisted a `launch_argv` field for a pane created through `agent start <name> --cwd <dir> --workspace <id>`, and that record survived a real server restart.
Protocol 20 removes both halves.
`agent.start` now takes `name`, `kind`, and `pane_id` and attaches an agent to an existing pane at a shell prompt, so it accepts neither a cwd nor a workspace, and `--kind` is a fixed enum that does not cover every harness Firstmate dispatches.
Its `argv` is a response field only.
The persisted pane record carries `cwd` alone, and the schema's only other `argv` belongs to `pane.process_info`, which reads the live process rather than restore state.

The working directory is the one axis Herdr does restore, and it tracks the pane's live cwd rather than freezing the creation value, so a worker that has `cd`ed into its task worktree persists that worktree.
That makes the recorded cwd correct in the steady state, but it is not a guarantee: it depends on the `cd` having landed, and the workspace's own seeded pane still sits in the project checkout.

Because no supported backend replays a launch, firstmate detects the loss instead of preventing it.
`bin/fm-spawn.sh` records the resolved command as the task record's `launch_argv=`, and `bin/fm-crew-state.sh` compares it, and the recorded `worktree=`, against what a local endpoint is live running on every state read.
`bin/fm-launch-drift-lib.sh` owns that verdict policy, including which divergences are severe.
`fm_backend_herdr_pane_argv` supplies the live side here through `pane.process_info`.
Herdr alone covers the argv axis because `pane.process_info` returns one atomic argv array.
Tmux reports argv unknown because it exposes no atomic boundary-preserving argv source.
The cwd axis covers tmux and Herdr through their passive readers.
Zellij and cmux's cwd probes are active and remain limited to fm-spawn.sh before a harness launches, while Orca has no cwd reader, so those backends report unknown on the cwd axis.
These supervision reads never start a Herdr server, revive a pane, or type into it.
A stopped or unreadable server leaves the affected axis unknown rather than causing a state read to change the workspace.

## Push events and polling fallback

Protocol 16 can subscribe to `pane.agent_status_changed` over one bounded Unix-socket reader.
`bin/fm-transition-lib.sh` owns the backend-neutral transition vocabulary and policy.
The Herdr adapter subscribes before reconciling current levels, buffers edges during reconciliation, and returns fresh blocked transitions for this home's panes.
The watcher maps the pane back to the task and skips secondmate endpoints, declared `paused:` waits, and verified `captain-held` transfers, because a declared wait already names the human the fast escalation would report and is left to the watcher's own bounded pause cadence; a captain-held transfer remains silent without rechecks while the away-posture record exists.

The push path only shortens latency.
Polling runs every cycle and remains the permanent fallback when any of these is unavailable:

- Protocol 16.
- The event schema.
- Python.
- The connection.
- The subscription.
- Repeated reader execution.

There is still one watcher process; the event reader is a bounded child of that watcher.

`tests/fm-backend-herdr-eventwait-smoke.test.sh`, `tests/fm-transition-lib.test.sh`, and `tests/fm-supervision-events.test.sh` cover capability, subscribe-then-reconcile ordering, dedupe, exemptions, and polling fallback.

## Away-mode supervisor support

The away daemon supports tmux and Herdr supervisor panes only.
It refuses Zellij, Orca, and cmux as supervisor backends rather than applying the wrong transport.
For Herdr, target existence, native state, capture, composer state, and verified submit all route through the shared backend dispatcher and the explicit named-session CLI owner.
The pane-independent max-defer alert is configured in [`wedge-alarm.md`](wedge-alarm.md).

Harnesses with native tracked background execution can run the daemon in their terminal.
Pi and pi-signed no longer launch the away daemon; their ordinary supervision session continues under the posture record.
For another harness without native tracked background execution, `bin/fm-afk-launch.sh` creates a dedicated unfocused Herdr workspace, runs the daemon there with an explicit supervisor target and backend, records the exact daemon pane, and closes only that pane on stop.
It never splits the captain's active tab and never uses shell `&`.
Recovery reconciles only the recorded exact id.

### Stopping the daemon

On stop:

1. The daemon receives termination while `state/.afk` still exists, so its final flush can run.
2. The recorded terminal is closed.
3. The AFK flag is removed last.

A fresh entry clears stale transient escalation caches, while durable queue and task records remain authoritative.

## Destructive lab safety

Never use ambient `herdr server stop` for Firstmate verification.
An environment-only session selection can silently reach a different running server.
The ambient stop command has no explicit target.

`bin/fm-herdr-lab.sh` is the sole supported lifecycle helper for isolated verification.
The helper:

- Provisions only non-default names beginning with `fm-lab-`.
- Supplies an explicit `--session` Herdr option before any `--` delimiter in allowed task commands.
- Refuses caller-supplied session flags and server/session lifecycle subcommands.
- Performs destructive stop/delete only through its guarded lifecycle actions.

Immediately before every destructive call it re-queries the named session and refuses empty, missing, literal `default`, or `default:true` identities.
Its before/after tripwire requires the live default-session snapshot to remain byte-identical.

The helper's header and `--help` own exact commands.
Tests use thin compatibility wrappers in `tests/herdr-test-safety.sh` and never duplicate the destructive policy.

## Active limits

- Presentation ordering needs protocol 16 and Python and is best-effort only.
- Mutable labels can collide; they are never placement or destructive authority.
- A Firstmate outside Herdr cannot resolve a launcher workspace, so a colliding home label refuses new spawns until the collision is cleared.
- Ghost and placeholder recognition uses ANSI de-emphasis when available; an unstyled glyph row carrying trailing non-idle text fails safely to `unknown`.
- Only tmux and Herdr can host the away-mode supervisor terminal.
- No launch command is persisted from 0.8.0, so a restored worker's flags cannot be replayed and are only detected as drift.

## Fleet live view

`bin/fm-fleet-live.sh` surfaces the human fleet view as a live Herdr tab in a named session.
It ensures one dedicated workspace and tab labeled `<prefix>-fleet-view` (the prefix from [Session naming](#session-naming)) and runs `bin/fm-fleet-view.sh` in that tab's pane, so the local home and every local or remote secondmate home plus their child agents are readable in the current session.
The view itself is a pure renderer over `fm-fleet-snapshot.sh --json` and the `fm-secondmate-home-summary.v1` contract; it never computes a summary and never invents a second state source.
Missing data renders `-` (not carried) or `unknown` (not known), never a blank cell, and branch and production are never inferred from a branch.

Verbs are `open`, `refresh`, `close`, and `status`.
`open` is idempotent: it refreshes a live recorded tab in place, replaces a stale record or a pane-less husk, and prunes only the exact seeded tab returned by its own `workspace create`.
If the recorded tab belongs to a different session than the one `open` was given, `open` best-effort closes only that exact recorded tab, in the session that recorded it, before creating the new tab in the requested session.
`close` clears the record and removes only the recorded tab; since that tab is the sole tab of its own dedicated workspace and Herdr refuses an explicit `tab close` of a workspace's last tab, `close` removes it by closing that exclusively-owned workspace, never any other workspace, tab, or label it did not record.
Session targeting is always explicit: `--session`, then `FM_FLEET_VIEW_SESSION`, then local gitignored `config/fleet-view-session`, then the real `default` session.
Every verb touches only its own recorded tab, in the session that recorded it, and the surface never calls a server-global or session-lifecycle operation.

Regeneration happens in two places, both riding work that is already happening and neither adding a daemon, service, poll loop, or state source.
The supervision heartbeat in `bin/fm-watch.sh` calls `refresh --best-effort` once per due heartbeat, and the successful task-completion path in `bin/fm-teardown.sh` calls it once after its backlog transition.
Both go through the same non-disruptive `refresh --best-effort` form, owned by `bin/fm-fleet-live.sh`'s header: it refreshes only an already-recorded tab, in the session that recorded it, under `FM_FLEET_LIVE_TIMEOUT` (default 5 seconds), and every failure or absence - no record, no Herdr or jq, a mismatched session, a dead pane, or a hung refresh - is a silent no-op that prints nothing and returns zero.
It never opens a tab the captain did not ask for, never writes a wake or status line, and never delays or fails the supervision cycle that carries it.
An operator can still re-run `open` or `refresh` directly, and the lab smoke test drives the real binary through the same verbs.
Production and convergence stay display-only, and an optional release manifest is consumed through the documented, schema-agnostic seam described in `bin/fm-fleet-view.sh`'s header.

## Regression entry points

```sh
tests/fm-herdr-name-lib.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-composer-lib.test.sh
tests/fm-herdr-submit-confirm-live-e2e.test.sh
tests/fm-backend-herdr-smoke.test.sh
tests/fm-backend-herdr-prune-safety-e2e.test.sh
tests/fm-backend-herdr-respawn-idem-e2e.test.sh
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
tests/fm-backend-herdr-launch-argv-e2e.test.sh
tests/fm-backend-herdr-presentation-e2e.test.sh
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh
tests/fm-backend-herdr-eventwait-smoke.test.sh
tests/fm-control-herdr-smoke.test.sh
tests/fm-herdr-session-cleanup.test.sh
tests/fm-herdr-session-cleanup-e2e.test.sh
tests/fm-herdr-attached-viewer-live-e2e.test.sh
tests/fm-afk-inject-herdr-e2e.test.sh
tests/fm-afk-pi-herdr-return-e2e.test.sh
tests/fm-fleet-snapshot-view.test.sh
tests/fm-fleet-live.test.sh
tests/fm-fleet-live-herdr-smoke.test.sh
```

Real Herdr tests use the named lab helper and default-session tripwire.
[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) records the active version, CLI, launch-replay, projection, event, and lifecycle evidence without task-specific chronology.
