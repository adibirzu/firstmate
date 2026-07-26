---
name: federation
description: >-
  Procedure for federated multi-operator coordination. Use when more than one OS
  operator (each their own first mate, own accounts) shares work through the fleet
  KB. Owns fleet init, routing, claim/lock, handoff, TTL reap, and cross-uid safety.
metadata:
  internal: true
---

# federation

Multiple operators (e.g. adi/royce/barf-ai), each running their **own** first mate
as themselves, coordinate through one **shared, group-writable, git-backed KB** so
work is routed by domain, never overlaps, and is visible in realtime. This skill
owns that procedure. The CLI is `bin/fm-fleet.sh` (lib: `bin/fm-fleet-lib.sh`).

## Cross-uid safety (non-negotiable)

Operators share **only** the fleet dir. **Never** read or write another operator's
private home (`~/.claude`, credentials, their `kun-agent-workspace`). Every
mutating fleet function calls `fm_fleet_assert_shared`, which refuses any path
resolving into a foreign `/home/<other>`. Credentials stay `0700`, read only by
their owner's own processes. This replaces FirstMate's single-uid filesystem-copy
propagation, which cannot work across uids.

## Fleet dir resolution

`--fleet <dir>` → `FM_FLEET_DIR` → `$FM_HOME/config/fleet-dir` → `/opt/agents/fleet`.
The real shared dir needs the one-time root prereq (`docs/ROOT-PREREQ.md`): an
`agents` group + `/opt/agents/fleet` mode `2775` (setgid) + each operator's
`umask 002`. Until then it runs against a local dev dir (single-uid), which
exercises every code path.

## KB files (at `$FLEET`)

- `operators.md` — `| operator | scope | home | accounts | status |`; `scope` is a
  comma list; `status` is `online`/`offline`.
- `backlog.md` — `## Queued / ## Claimed / ## In-flight / ## Done`; item line:
  `- [id:<ID>] scope:<S> | <desc> | [claimed-by:<op>@<ISO8601>] status:<st>`.
- `events.log` — append-only TSV `<ISO8601>\t<op>\t<event>\t<id>\t<detail>`.
- `locks/backlog.lock` — the `flock` target for atomic claims.

## Procedure

1. **Session start:** `fm-fleet.sh reap [ttl]` to requeue stale never-started
   claims from offline operators (default ttl 86400s; only `status:claimed`,
   never `status:in-flight`).
2. **Intake a task:** resolve owner by domain — `fm-fleet.sh route <scope>`
   (scope-primary: the online operator whose `scope` contains it; on
   miss/offline/quota-saturation → the `overflow` operator; a human `--operator`
   override always wins).
3. **Take work meant for you:** `fm-fleet.sh claim <id> <you>` — atomic under
   `flock`; returns non-zero if already claimed, so two operators can never grab
   the same item.
4. **Give work to its owner:** `fm-fleet.sh handoff <id> <owner>` — reassigns; the
   owner's first mate then `claim`s it.
5. **Dispatch:** run the crewmate (fm-spawn) in your own Treehouse worktree under
   your own account; mark the item in-flight (integration point) and `done` on land.
6. **Visibility:** `fm-fleet.sh status` (per-operator counts) and
   `fm-fleet.sh view [--follow]` (the live cross-operator event stream).

## Notes

- Every KB mutation is git-committed in the shared dir → durable "who did what
  when" audit; optionally mirror to a private GitHub repo for offsite/cross-box.
- Quota-secondary routing consults `quota-axi` headroom across operators AND (with
  the multi-account layer) accounts; guard for `quota-axi` absent by routing on
  scope alone.
