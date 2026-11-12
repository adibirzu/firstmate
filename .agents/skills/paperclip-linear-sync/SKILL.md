---
name: paperclip-linear-sync
description: >-
  Agent-only procedure for Paperclip, Linear, GitHub PR, and cross-Mac custody synchronization.
  Load when the captain asks to sync or refresh development tasks (in chat, via an inbox or voice-handover note, or over Relay), on a `procevent` wake from a Paperclip event source, before dispatching a synced `[CYB-xxx]` task on `adi0`, or when reporting a `[CYB-xxx]` PR back to Paperclip.
user-invocable: false
metadata:
  internal: true
---

# paperclip-linear-sync

Synchronize external backlog and PR state across Paperclip (`adi5`/`adi4`), Linear (`CYB` initiatives `I-3`..`I-8` and `ReviewForge` `P-OCD-70`), GitHub PRs, and cross-Mac custody (`rf-mac-sync`) into this home's local queue while preserving every boundary in `AGENTS.md`.
`bin/fm-task-sync.sh` owns exact CLI flags, lock handling, state files, and fallback mechanics; consult `bin/fm-task-sync.sh --help` rather than duplicating flag lists.

## Non-negotiable invariants

- **Hard Rule 1 preserved:** Firstmate never edits project code directly; `bin/fm-task-sync.sh` only reads external authorities, writes gitignored operational state under `state/paperclip-sync/`, refreshes clean clones via `bin/fm-fleet-sync.sh`, and queues unblocked `[CYB-xxx]` items through `bin/fm-tasks-axi.sh` without `--start`.
- **Hard Rule 2 preserved:** PR merges never happen automatically unless standing `yolo` applies; hold every review-ready PR for the captain's explicit merge word.
- **`adi0`-only coding plane:** Control-plane servers `adi4` and `adi5` never run coding workers or hold coding clones; every coding spawn executes strictly on `adi0` in an isolated task worktree via `bin/fm-spawn.sh`.
- **Custody and model guardrails:** Items fenced to `adrians-macbook-pro` (`OCD-*` and `wip/adrians-macbook-pro/*`) remain visibility-only in the `fenced` summary and are never queued or dispatched on `adi0`.
- **AetherOps harness policy:** On `aetherops`, `agy` and `cursor` are blocked while `grok`, `codex`, and `claude` are eligible.

## Procedure

1. **Reconcile and queue (`sync-and-queue` default):**
   Run `bin/fm-task-sync.sh --apply` (scoped by `--project`, `--initiative`, or `--limit` when the captain's request names a subset).
   When handling a sync-only `inbox` `check:` wake, pass `--inbox-note <id>` so the durable reply and acknowledgement are recorded together; when the note also asks to dispatch work, defer the inbox reply and `--ack <id>` until after step 2 so dispatch outcomes are included in the single durable reply.
   Do not spawn workers after synchronization unless the captain's message explicitly asks to start or dispatch work.
   If Paperclip over Tailscale is temporarily unreachable, `bin/fm-task-sync.sh` emits `PAPERCLIP_UNAVAILABLE:` and reconciles Linear and `rf-mac-sync` directly so task intake is not lost.

2. **Dispatch requested `adi0` tasks (only when the captain asked to start `N` or named `[CYB-xxx]` items):**
   Resolve the concrete harness and model profile through `router-dispatch` (`llm-router-axi` and `hl-station` cross-family routing where configured), then verify dispatch eligibility via `paperclip-cyb guard-dispatch --project <slug> --host adi0 --harness <harness> --issue <CYB-ID> --json` when `paperclip-cyb` is installed.
   Prepare the task brief under `AGENTS.md` section 11 and spawn strictly on `adi0` through `bin/fm-spawn.sh` after loading `harness-adapters`.
   Once `bin/fm-spawn.sh` succeeds, record the claim in Paperclip via `paperclip-cyb claim <CYB-ID> --fm-task <task-id> --worktree <worktree-path> --harness <harness> --json` when `paperclip-cyb` is reachable.

3. **Report review-ready PRs and hold for merge authority:**
   When a `[CYB-xxx]` ship worker reports a review-ready PR, load `ship-landing`, record the PR receipt in Paperclip via `paperclip-cyb report-pr <CYB-ID> --pr <https-pr-url> --ci <state> --json` when `paperclip-cyb` is reachable, and present the full `https://...` PR URL to the captain awaiting explicit merge approval.

4. **Handle `procevent` wakes from Paperclip:**
   Home-local `paperclip-events` runs as a `process-event-adapter/1` extension bound through `bin/fm-extension.sh` and armed via `bin/fm-procevent.sh register-extension paperclip-events paperclip-events --config-ref paperclip:adi5`.
   When `paperclip-events` delivers a `procevent` `check:` wake, load `process-event-sources`, classify the captured result with `bin/fm-procevent.sh classify <result-file>`, run `bin/fm-task-sync.sh --apply` to refresh local queue visibility without spawning workers (or `--dry-run` when external tracker writes are unwanted), acknowledge via `bin/fm-procevent.sh handled paperclip-events <sequence>`, and never run `paperclip-cyb watch-events` directly inside a conversational turn.

5. **Send a standalone captain digest (`AGENTS.md` section 9):**
   Summarize the outcome in plain English: synchronized project scope, newly queued `[CYB-xxx]` items, refreshed local project copies, open PRs with full `https://...` URLs awaiting merge decisions, any items fenced to `adrians-macbook-pro`, and any dispatch outcomes or capacity blockers.
   Translate internal mechanics before sending so raw lock names, wake rows, metadata paths, and internal safety labels never appear in chat.
