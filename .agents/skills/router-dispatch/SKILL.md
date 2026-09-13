---
name: router-dispatch
description: >-
  Agent-only dispatch procedure that turns a task descriptor into one
  harness/model/effort decision through llm-router-axi, passes its flags to
  fm-spawn, records outcomes with llm-router-axi record, and covers per-account
  launches. Load before choosing a worker or reviewer runtime, before resolving
  a subscription-aware profile array, or before launching under a chosen
  provider account.
user-invocable: false
metadata:
  internal: true
---

# router-dispatch

This skill is the single owner of the dispatch judgment boundary for a fleet with the axi router tools installed.
It routes a task descriptor through `llm-router-axi`, folds the per-account launch procedure into the same place, and points at the kept in-repo paths for the capabilities the tools do not yet cover.

`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`llm-router-axi select` is the mechanical owner of arbitrary-profile selection, `llm-router-axi route chain` owns in-run step-down, and `llm-router-axi classify-evidence` owns the depletion classifier.
`bin/fm-dispatch-select.mjs` is a thin forwarding shim over those verbs, kept only so existing callers keep their command line.
`quota-array-dispatch` stays the judgment owner for a matched in-repo profile array.

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

## When the tools are absent

`bin/fm-router-lib.sh` owns tool resolution and the install hint.
Both tools are now required for the dispatch path: `llm-router-axi` owns selection, the step-down chain, the depletion classifier, and the machine-capacity verdict, and there is no in-repo fallback left.
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
