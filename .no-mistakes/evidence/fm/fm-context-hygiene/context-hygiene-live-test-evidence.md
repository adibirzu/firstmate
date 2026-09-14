# fm-context-hygiene live test evidence (branch fm/fm-context-hygiene)

## fm-context-report.sh, direct CLI drive (bin/fm-context-report.sh)

Synthetic transcripts: one firstmate-home session with two assistant turns
(150000+149990+10=~300000 tokens, and 10000+9990+10=~20000 tokens), one
non-firstmate session (50000+49990+10=~100000 tokens).

Default (firstmate-only) text report:
```
HOME                                                                TURNS   WAKES/HR  MEAN_TOKENS MEDIAN_TOKENS PCT_GT_150K ACTIVE_H
/home/fm-primary/firstmate                                              2       0.00       160000       160000      50.0%      0.0
TOTAL                                                                   2          -       160000            -      50.0%        -
```
Non-firstmate home correctly excluded by default; --all --json included both
homes as valid JSON; missing --projects-dir printed "no Claude transcript root
... nothing to report" (rc=0); --hours 0 refused with rc=2.

## fm-context-hygiene-lib.sh, direct function calls (bin/fm-context-hygiene-lib.sh)

- config/context-hygiene = "off" (and case-insensitive variants) disables the
  feature; an absent file or garbage value leaves it on (documented default).
- fm_context_hygiene_idle_ready: does not fire before the continuous idle
  window elapses; fires once it has; an in-flight (non-secondmate) task record,
  a non-empty state/.wake-queue, or a pending state/pending-replies/* entry
  each block it indefinitely (no missed-wake risk); a secondmate-only record
  does not block it.
- fm_context_hygiene_command: an unverified harness gets no guessed
  compact/clear command; "claude" gets its verified /compact.
- fm_context_hygiene_mark_compact / clear_marker: durable marker write, content
  round-trip, and removal after confirmed delivery.

## Real entry-script execution (external gh/git/tmux faked, everything else real)

- `tests/fm-context-hygiene.test.sh` (14/14 ok): sources the real
  bin/fm-context-hygiene-lib.sh and bin/fm-watch.sh; watcher delivers the
  compact/clear command only into a provably idle pane, pauses while
  state/.afk exists (away mode), heartbeat backoff doubles/caps/resets on a
  spawned task, and coalesced signal rows dedupe. Only the tmux pane-send
  primitive is stubbed (no live tmux+Claude/Pi pane in this sandbox).
- Isolated single-scenario runs (scratch copies of the real test files, real
  bin/fm-pr-merge.sh and bin/fm-teardown.sh executed as real subprocesses):
  `test_verified_merge_records_pr_and_head` (pr-merge) and
  `test_local_only_merged_to_local_main_allows` (teardown) both confirm
  state/.context-compact-pending is queued at the merge/teardown task
  boundary.
- `tests/fm-session-start.test.sh` targeted assertions: "an unmeasurable
  memory file fails the startup budget safe" and "captain-shared.md counts
  against the startup-memory allowance" both ok (round-1 symlink fail-safe
  fix and its regression test).

## Unrelated pre-existing flake

`test_status_tail_bounding`'s default-5-lines assertion ("missing:
'working: step 3'") fails identically at the target commit
(53dc5beecb428356) and at the base commit (48fb85bd8c14b835), reproduced via
`git archive` of the base commit into a clean checkout. Not a regression from
this branch.
