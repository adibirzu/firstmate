# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.
That refusal is correct but late: it costs a full CI cycle across every shard before it says so.
`tests/fm-test-run.test.sh` therefore parses the workflow and asserts the matrix length equals the runner's configured count, that the matrix is `1..n` in order, and that every lane name the matrix would build is one the runner accepts.
It asserts the 20-minute job cap is unchanged in the same test, because a shard cancelled at its cap has an easy wrong fix: capacity belongs to the shard count, and the timeout stays a hang tripwire.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The 175 current hints cover all but eight scripts in the lane.
The 171 measured from CI are the slowest values retained from the `fm-test-timing-portable-serial-*` artifacts of six green runs: three on `kunchenguid/firstmate` main on 2026-09-04, [33862577219](https://github.com/kunchenguid/firstmate/actions/runs/33862577219), [33846795055](https://github.com/kunchenguid/firstmate/actions/runs/33846795055), and [33845785209](https://github.com/kunchenguid/firstmate/actions/runs/33845785209), plus three on `adibirzu/firstmate` main on 2026-08-30 and 2026-08-31, [33366802354](https://github.com/adibirzu/firstmate/actions/runs/33366802354), [33358754618](https://github.com/adibirzu/firstmate/actions/runs/33358754618), and [33334002105](https://github.com/adibirzu/firstmate/actions/runs/33334002105).
Both sources are needed because the fork-only suites - federation, harness adapters, quota, and OpenCode - never run on upstream's CI and so appear only in the fork's artifacts.
The one remaining hint, `tests/fm-opencode-secondmate-arm.test.sh` at 23074 ms, is a local measurement: that suite grew from 459 to 1625 lines on this branch, so its 1016 ms fork-CI value predates the growth by more than twenty times and the next green run's artifact should replace it.
Those per-script maxima total 4772756 ms of conservative balance weight.
Taking the slowest of several runs rather than a single run keeps the balance honest on a slow runner: the shared scripts' maxima run about 15% above any single one of those runs.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default; the current 183-script lane has eight such scripts, bringing its assignment weight to 5042756 ms.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of8` | 20 | 630349 ms (~10.51 min) |
| `portable-serial-2of8` | 22 | 630339 ms (~10.51 min) |
| `portable-serial-3of8` | 23 | 630342 ms (~10.51 min) |
| `portable-serial-4of8` | 22 | 630345 ms (~10.51 min) |
| `portable-serial-5of8` | 24 | 630342 ms (~10.51 min) |
| `portable-serial-6of8` | 24 | 630342 ms (~10.51 min) |
| `portable-serial-7of8` | 24 | 630347 ms (~10.51 min) |
| `portable-serial-8of8` | 24 | 630350 ms (~10.51 min) |
| imbalance | | 11 ms |

The current table is generated from the runner's retained maxima plus its default for the eight scripts that arrived with the 2026-09-08 upstream sync and are still unhinted.
Those eight have since appeared in CI timing artifacts; folding them and the drifted values below into the hint table is the separate refresh described at the end of this section.

### The 2026-09-08 capacity regression

`n` was raised from 5 to 8 on 2026-09-08 because the 5-shard partition was being cancelled at its cap.
The lane's own timing artifacts are the evidence; replaying a partition against them measures it in real runner seconds rather than in assignment weight, which is what the estimated-duration table above reports.
Four fork runs are available; three recorded a complete set of five serial shards and so can be replayed against, and shard 4 was cancelled at the 20-minute boundary on two of them:

| run | shard 1 | shard 2 | shard 3 | shard 4 | shard 5 |
|---|---:|---:|---:|---:|---:|
| [34187972666](https://github.com/adibirzu/firstmate/actions/runs/34187972666) (PR 38) | 18m19s | 14m25s | 16m06s | **20m05s cancelled** | 15m16s |
| [34197679695](https://github.com/adibirzu/firstmate/actions/runs/34197679695) (PR 39) | 17m51s | 15m21s | 13m48s | **19m38s** | 17m17s |
| [34199327612](https://github.com/adibirzu/firstmate/actions/runs/34199327612) (main) | 17m52s | 12m33s | 16m15s | **20m17s cancelled** | 19m02s |

Job overhead measures about 25 seconds, so a shard's real budget is roughly 19.5 minutes of script time.

Replaying the partition the current hints produce against the three complete runs, for each candidate shard count:

| `n` | worst shard by assignment weight | worst shard replayed | share of the 20-minute cap |
|---:|---:|---:|---:|
| 5 | 16.81 min | 18.1-19.7 min | 90-99% |
| 6 | 14.01 min | 15.1-16.2 min | 75-81% |
| 7 | 12.01 min | 15.1-17.2 min | 75-86% |
| 8 | 10.51 min | 13.7-14.3 min | 68-72% |
| 9 | 9.34 min | 11.7-12.1 min | 59-61% |

Replayed makespan is not monotone in `n`: 7 is worse than 6.
That is a symptom, not a packing bug.
Longest-processing-time packing is only as good as the weights it is given, and several hints below have drifted badly since they were measured, so adding a bin can move an underweighted script into a bin that then overruns.
8 is the smallest count whose heaviest shard clears the cap on every measured run, and it holds without touching a single hint.

Refreshing the hints is tracked separately and is the change that makes the packing trustworthy again rather than merely over-provisioned.
Measured against the same three runs, the drifted values include `tests/fm-watch-triage.test.sh` at 486694 ms against a 358232 ms hint, `tests/fm-decision-hold-lifecycle.test.sh` at 212012 against 57130, `tests/fm-procevent.test.sh` at 167293 against 71783, `tests/fm-bearings-board.test.sh` at 60423 against 4684, and `tests/fm-calm-pi-extension.test.sh` at 50743 against 810.
With those refreshed, the same 8 shards replay at 57-61% of the cap.

Note what the `serial_unhinted=` bound could and could not see here: every script in the overloaded shard was hinted, so the unmeasured share stayed at eight of 183 and the guard passed throughout.
The bound catches a lane that has grown past its measurements; it does not catch measurements that have gone stale in place.

The single longest script, `tests/fm-watch-triage.test.sh` at 358232 ms, is the floor for any shard count.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the table above:

```sh
for run in <upstream-run-id> <upstream-run-id> <upstream-run-id>; do
  gh run download "$run" -R kunchenguid/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
for run in <fork-run-id> <fork-run-id> <fork-run-id>; do
  gh run download "$run" -R adibirzu/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-8 | job `timeout-minutes: 20` | Each balanced shard carries about 10.51 minutes of conservative assignment weight and replays at 13.7-14.3 minutes, leaving roughly 1.4x hang-tripwire margin for job setup and runner-speed spread. The cap is deliberately unchanged across the 5 -> 8 shard increase: capacity comes from the shard count, and `tests/fm-test-run.test.sh` asserts it stays 20. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
