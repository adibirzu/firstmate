# FirstMate Fleet add-on — federated multi-operator + multi-account

Two general, reusable capabilities FirstMate does not ship today, built as a
**drop-in add-on that requires ZERO edits to FirstMate core**:

1. **Federated / multi-operator mode** — several OS operators (each their own
   first mate, own accounts), coordinating through a shared, cross-uid-safe,
   git-backed KB with atomic claim/lock, scope routing, cross-operator handoff,
   TTL reap, and a realtime `fleet view`.
2. **Per-spawn multi-account** — a `--account` axis that launches a crewmate under
   a chosen account with isolated auth, plus quota-aware account selection.

Everything lives in new `bin/fm-fleet*.sh`, `bin/fm-account*.sh`,
`bin/fm-accounts*.sh`, `bin/quota-*`, `scripts/fleet-root-prereq.sh`,
`.agents/skills/{federation,multi-account}/`, and `tests/federation/*.sh`.
No existing FirstMate script is modified — the `--account`
axis rides on `fm-spawn`'s existing raw-launch escape hatch. That is what makes
this shippable as an additive PR (or a standalone overlay).

---

## Part A — Federated multi-operator

### Why a new model
FirstMate today propagates prefs by **filesystem copy from main into secondmate
homes**. That breaks across uids (it would require writing another user's home).
The add-on uses a **shared-dir + read/claim** model instead: operators share only
a group-writable, git-backed KB and **never write each other's private homes**.

### Shared KB (`$FM_FLEET_DIR`, default `/opt/agents/fleet`)
- `operators.md` — `| operator | scope | home | accounts | status | seen | quota |`
- `projects.md`  — `| project | owner | path |`
- `backlog.md`   — `## Queued / ## Claimed / ## In-flight / ## Done`; item line:
  `- [id:<ID>] scope:<S> | <desc> | [claimed-by:<op>@<ISO8601>] status:<st>`
- `events.log`   — append-only TSV `<ISO8601>\t<op>\t<event>\t<id>\t<detail>`
- `locks/backlog.lock` — the `flock` target for atomic claims

Fleet dir resolves from: `FM_FLEET_DIR` → `$FM_HOME/config/fleet-dir` →
`/opt/agents/fleet`. During development it points at a local dir so every code
path is exercised single-uid; `flock` semantics are identical across uids.

### CLI (`bin/fm-fleet.sh`, lib `bin/fm-fleet-lib.sh`)
`init | register | heartbeat | leave | queue | claim | handoff | reap | route |
budget | quota | models | pick | status | view`, plus `bin/fm-fleet-join.sh`
(operator onboarding) and `bin/fm-fleet-wait.sh` (token-free wait-for-work).

- **Atomic claim** — under `flock`, verify item is `queued`, stamp
  `claimed-by:<op>@<ts> status:claimed`, move to `## Claimed`, log, commit. Two
  operators can never grab the same item (proven by a concurrent race test).
- **Routing** — `route <scope>`: scope-primary (the online operator whose scope
  contains it), overflow fallback (the `overflow`-scoped operator) if the owner
  is offline; a human `--operator` override always wins.
- **Reap** — requeue stale `status:claimed` items older than a TTL (offline
  operators' never-started work); `status:in-flight` is left alone.
- **Visibility** — `status` (per-operator counts) + `view [--follow]` (the live
  cross-operator event stream).

### Cross-uid safety (non-negotiable)
Every mutating fleet function calls `fm_fleet_assert_shared`, which refuses any
path resolving into a foreign `/home/<other>`. Credentials stay `0700`, read only
by their owner's own processes. See `.agents/skills/federation/SKILL.md`.

### One privileged step (root, once)
Run the reviewable, idempotent `scripts/fleet-root-prereq.sh` (walkthrough:
[fleet-quickstart.md](fleet-quickstart.md), Tier C). It creates the shared
group, enrols the operators, and creates the setgid fleet dir; each operator
then sets `umask 002`. Nothing else needs root.

---

## Part B — Per-spawn multi-account

### Three isolation methods (verified per CLI — never guessed)
The matrix below records how each CLI isolates auth, probed from its own
`--help` (claude confirmed empirically); `bin/fm-accounts-lib.sh` validates
every registered account against it:

| harness | method | env / flag |
|---|---|---|
| claude | `config-dir-env` | `CLAUDE_CONFIG_DIR` |
| codex  | `config-dir-env` | `CODEX_HOME` |
| pi     | `config-dir-env` | `PI_CODING_AGENT_DIR` |
| cline  | `config-dir-flag` | `--config <dir>` |
| grok   | `api-key-env` | `GROK_API_KEY` |
| cursor-agent | `api-key-env` | `CURSOR_API_KEY` (OAuth mode not per-spawn isolatable) |

### Account registry (`config/accounts.json`, gitignored)
```json
{
  "<name>": {
    "provider": "...", "harness": "...", "isolation": "config-dir-env|config-dir-flag|api-key-env",
    "env": "<ENV>", "flag": "<flag>", "config_dir": "<path>", "key_file": "<path>",
    "scopes": ["..."]
  }
}
```
`bin/fm-accounts-lib.sh` resolves + **validates** each account against the matrix
(harness known, isolation matches the harness's method + env/flag, required
fields present, and — reusing the federation guard — paths never in a foreign
home). Copy `docs/examples/accounts.json` to start.

**Secrets never live in the registry.** api-key accounts store a `key_file` path
(a `0600` file in the operator's own home); the key is read at launch into the
child's environment — never onto argv, never into a log.

### The `--account` axis (`bin/fm-spawn-acct.sh`)
Adds `--account <name>` **without editing `fm-spawn.sh`**. It composes an
account-isolated launch command and hands it to `fm-spawn`'s raw-launch escape
hatch (which skips leading `ENV=val` tokens when detecting the harness):

- `config-dir-env`  → `CLAUDE_CONFIG_DIR=/path claude [--model … --effort …]`
- `config-dir-flag` → `cline --config /path [--model …]`

The env prefix / flag rides **in the command string**, so isolation survives the
Herdr/tmux pane boundary. Config-dir isolation puts **no secret on argv**.

api-key accounts are **refused** here (a key on argv would leak) → use
`bin/fm-account-exec.sh <account> <cli> [args]` for a direct, non-supervised
isolated launch (reads the key_file into the child's env). Live-verified: a claude
crewmate launched under an isolated account writes to its own config dir and sees
a different MCP set than the default account.

### Quota-aware selection (`fm_account_pick <harness>`)
`quota-axi` reports headroom **per provider for the currently-authed account**, so
per-account headroom is obtained by running `quota-axi` **under each account's
isolation**; the binding constraint is `min(percentRemaining)` across windows.
Pick the account with the most headroom; ties → first registered. Guards:
unsupported provider (pi/cline) or `quota-axi` absent → first registered.

### Prereq installer (`bin/fm-accounts-prereq.sh`)
On-demand, **user-scoped, no sudo**. `detect` (default) shows installed / MISSING
+ the install command; `install [--yes] [harness…]` installs missing CLIs
(`npm i -g @anthropic-ai/claude-code|@openai/codex|@vibe-kit/grok-cli|cline`,
`curl https://cursor.com/install`). `pi` is system-managed → detect-only. Run this
first on a box that is missing, e.g., cursor.

---

## Install (drop-in overlay onto a FirstMate clone)
1. Copy `bin/fm-fleet*.sh`, `bin/fm-account*.sh`, `bin/fm-accounts*.sh`,
   `bin/fm-spawn-acct.sh`, `bin/quota-*.sh`, `bin/quota-sources/`,
   `scripts/fleet-root-prereq.sh`, `tests/federation/`,
   `.agents/skills/{federation,multi-account}/`,
   `docs/examples/{model-surfaces,accounts,quota-overrides}.json`, and
   `docs/fleet-*.md`.
2. `bin/fm-accounts-prereq.sh` — install any missing CLIs; then log in per account.
3. `cp docs/examples/accounts.json config/accounts.json` and edit; gitignore it.
4. Federation only: run the root prereq, then `bin/fm-fleet.sh init`.

## Tests
```
bash tests/federation/test_fleet.sh          # federation: claim race, reap, route, handoff, view, safety
bash tests/federation/test_fleet_ops.sh      # operator lifecycle: register/heartbeat/leave, TTL, quota routing
bash tests/federation/test_fleet_guards.sh   # init/ownership guards on every fleet-consuming entry point
bash tests/federation/test_quota_surfaces.sh # per-surface quota report, models table, failover pick
bash tests/federation/test_accounts.sh       # registry resolve/validate (+ cross-uid path guard)
bash tests/federation/test_spawn_account.sh  # --account compose + wrapper + api-key refusal + apply_env
bash tests/federation/test_account_quota.sh  # quota pick (isolate-then-query; tie/absent/no-provider)
```

## Known limitations (honest)
- **cursor-agent OAuth is not per-spawn isolatable** (creds in `~/.cursor`, no
  relocation env). Multi-account for cursor uses API-key mode only.
- **grok** is API-key isolatable but stays out of the Herdr crew rotation (no
  `GROK_AGENT` autonomy marker + no Herdr integration).
- **quota-axi is per-provider, not per-account** — on this box both claude config
  dirs reported identical headroom because `quota-axi --provider claude` reads a
  shared credential source regardless of `CLAUDE_CONFIG_DIR`. Genuine two-account
  discrimination requires each account separately authed with creds quota-axi
  reads (verify on a real second account); codex quota (in `$CODEX_HOME/auth.json`)
  is expected to discriminate. `pi`/`cline` have no quota-axi coverage.
- The raw-launch path bypasses `fm-spawn`'s per-harness model/effort mapping; the
  wrapper folds `--model` and (for claude/codex/pi) `--effort` into the command.

## Packaging options
1. **Upstream PR to `kunchenguid/firstmate` (recommended).** All additive files,
   no core edits → small, reviewable diff. Consent-gated (outward-facing).
2. **Standalone add-on repo** overlaid onto a FirstMate clone (same files).
3. **axi-style tool** — possible but *not* simpler: the bash scripts would need
   npm-bin repackaging + a SessionStart hook, and federation needs a shared
   git-backed dir that doesn't fit the per-user axi model. Recommend #1/#2.
