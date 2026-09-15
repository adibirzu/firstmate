# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The parallel lanes are balanced on CI-measured per-script maxima, not on the local concurrent proof.
The 2026-08-20 proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) still owns the *membership* of the proven-isolated set; it is a poor balance source because a hosted runner is far slower than the proof machine.
Several of its durations are low by 3-16x: `tests/fm-lint.test.sh` measured 9766 ms there and up to 160345 ms in CI, `tests/fm-pr-merge.test.sh` 6290 ms against 118197 ms, and `tests/fm-captain-hold-lifecycle.test.sh` 35095 ms against 302454 ms.

These are the slowest `duration_ms` per script across the `fm-test-timing-portable-parallel-*` artifacts of four green `adibirzu/firstmate` main runs on 2026-09-14 and 2026-09-15 - [34862039579](https://github.com/adibirzu/firstmate/actions/runs/34862039579), [34864676099](https://github.com/adibirzu/firstmate/actions/runs/34864676099), [34891809040](https://github.com/adibirzu/firstmate/actions/runs/34891809040), and [34931366868](https://github.com/adibirzu/firstmate/actions/runs/34931366868) - plus [34962817564](https://github.com/adibirzu/firstmate/actions/runs/34962817564), whose shard 1 was cancelled at its job cap.
That cancelled shard uploaded no artifact, so its per-script values are read from the job log's `FM_TEST_END` lines; it is the slow-runner case the balance has to survive, so its maxima are kept.

| duration_ms | script |
|---:|---|
| 302454 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 160345 | `tests/fm-lint.test.sh` |
| 118197 | `tests/fm-pr-merge.test.sh` |
| 113352 | `tests/fm-test-run.test.sh` |
| 51012 | `tests/fm-backend-herdr.test.sh` |
| 31953 | `tests/fm-arm-pretool-check.test.sh` |
| 28468 | `tests/fm-x-mode.test.sh` |
| 19879 | `tests/fm-grok-harness.test.sh` |
| 17306 | `tests/fm-cd-pretool-check.test.sh` |
| 16263 | `tests/fm-crew-state.test.sh` |
| 7655 | `tests/fm-herdr-lab.test.sh` |
| 5620 | `tests/fm-send-popup-settle.test.sh` |
| 4919 | `tests/fm-composer-lib.test.sh` |
| 4124 | `tests/fm-send-strict.test.sh` |
| 3980 | `tests/fm-pi-primary-types.test.sh` |
| 2974 | `tests/fm-review-diff.test.sh` |
| 2765 | `tests/fm-composer-ghost.test.sh` |
| 2586 | `tests/fm-spawn-batch.test.sh` |
| 2529 | `tests/fm-tmux-submit-busy.test.sh` |
| 2176 | `tests/fm-send-settle.test.sh` |
| 1918 | `tests/fm-brief.test.sh` |
| 904 | `tests/fm-ensure-agents-md.test.sh` |
| 306 | `tests/fm-supervision-instructions.test.sh` |
| 100 | `tests/fm-transition-lib.test.sh` |

Refresh these the same way as the serial hints, against the parallel artifact names:

```sh
for run in <fork-run-id> <fork-run-id> <fork-run-id>; do
  gh run download "$run" -R adibirzu/firstmate --pattern 'fm-test-timing-portable-parallel-*' -D "/tmp/fm-par/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-par/*/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort -k2 -rn
bin/fm-test-run.sh --check-coverage
```

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured maxima.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 13 | 450741 ms (~7.51 min) |
| `portable-parallel-2` | 11 | 451044 ms (~7.52 min) |
| imbalance | | 303 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

`tests/fm-pi-primary-types.test.sh` must stay in shard 1.
Only the shard 1 CI job installs `@earendil-works/pi-coding-agent` and passes `--fail-on-gate-skip 'Pi extension typecheck prerequisite not found'`, so in shard 2 that script would gate-skip silently instead of running.
Any future rebalance either keeps it in shard 1 or moves the install and the gate-skip flag with it.

Balancing on the proof's local durations was not a cosmetic error.
Against the maxima above, the previous partition put 653541 ms (~10.89 min) on shard 1 and 248244 ms (~4.14 min) on shard 2: shard 1 exceeded its own 10-minute job cap while shard 2's runner finished in about four minutes and sat idle.
That shard ran 9m10s on [34931366868](https://github.com/adibirzu/firstmate/actions/runs/34931366868) and was cancelled at the cap on [34962817564](https://github.com/adibirzu/firstmate/actions/runs/34962817564) partway through `tests/fm-lint.test.sh`, after a branch added shell files for that script's ShellCheck sweep to cover.
Rebalancing restores roughly 1.3x tripwire margin on both runners without changing which scripts run.

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

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The merged hint table combines the fork's refreshed maxima with the upstream-only scripts' retained measurements; 11 of the lane's 199 scripts remain unhinted, within the guard's bound, so the coverage guard reports `serial_unhinted=11`.
They are the slowest values retained from the `fm-test-timing-portable-serial-*` artifacts of eleven runs: three on `kunchenguid/firstmate` main on 2026-09-04, [33862577219](https://github.com/kunchenguid/firstmate/actions/runs/33862577219), [33846795055](https://github.com/kunchenguid/firstmate/actions/runs/33846795055), and [33845785209](https://github.com/kunchenguid/firstmate/actions/runs/33845785209); three on `adibirzu/firstmate` main on 2026-08-30 and 2026-08-31, [33366802354](https://github.com/adibirzu/firstmate/actions/runs/33366802354), [33358754618](https://github.com/adibirzu/firstmate/actions/runs/33358754618), and [33334002105](https://github.com/adibirzu/firstmate/actions/runs/33334002105); and five 2026-09-13 `adibirzu/firstmate` runs, [34748548020](https://github.com/adibirzu/firstmate/actions/runs/34748548020), [34745812326](https://github.com/adibirzu/firstmate/actions/runs/34745812326), [34745484347](https://github.com/adibirzu/firstmate/actions/runs/34745484347), [34743623243](https://github.com/adibirzu/firstmate/actions/runs/34743623243), and [34749381814](https://github.com/adibirzu/firstmate/actions/runs/34749381814).
The last of those was cancelled, but its test step still finished all 37 scripts and uploaded a complete artifact, so it is the slow-runner case the balance must survive.
Both upstream and fork sources are needed because the fork-only suites - federation, harness adapters, quota, and OpenCode - never run on upstream's CI and so appear only in the fork's artifacts.
Those per-script maxima total 6278578 ms of conservative balance weight.
Taking the slowest of several runs rather than a single run keeps the balance honest on a slow runner: the shared scripts' maxima run well above any single one of those runs.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default; the current 199-script lane's 11 unhinted scripts add that default, for a total assignment weight of 6278578 ms.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of6` | 31 | 1046418 ms (~17.44 min) |
| `portable-serial-2of6` | 34 | 1046450 ms (~17.44 min) |
| `portable-serial-3of6` | 34 | 1046439 ms (~17.44 min) |
| `portable-serial-4of6` | 34 | 1046438 ms (~17.44 min) |
| `portable-serial-5of6` | 33 | 1046416 ms (~17.44 min) |
| `portable-serial-6of6` | 33 | 1046417 ms (~17.44 min) |
| imbalance | | 34 ms |

The table is a conservative ceiling packed from the merged per-script maxima.
Replaying the fork's partition against its 2026-09-13 runs put the worst shard well under the 20-minute job cap before the upstream-only scripts were added; the added scripts are largely live-harness and harness-adapter cases that gate-skip on a portable runner.
Five shards were not enough: the same lane's five-shard split put its worst shard at up to 19.9 min of measured wall against the 20-minute cap, with no hang, and every script in the cancelled shard finished with its timing artifact complete.
The `Behavior portable serial 5` job was cancelled by the job cap on four runs in a row, [34730945031](https://github.com/adibirzu/firstmate/actions/runs/34730945031), [34735985103](https://github.com/adibirzu/firstmate/actions/runs/34735985103), [34745993360](https://github.com/adibirzu/firstmate/actions/runs/34745993360), and [34749381814](https://github.com/adibirzu/firstmate/actions/runs/34749381814), while shard 4 was cancelled on [34735985103](https://github.com/adibirzu/firstmate/actions/runs/34735985103) and [34718537004](https://github.com/adibirzu/firstmate/actions/runs/34718537004).
The lane had grown to about 90 minutes of measured script time, so five roughly even shards could not hold the tripwire once hosted-runner speed varied by the 10-15% this lane already shows.
Six shards restore real margin and are the shard count both the CI matrix and `PORTABLE_SERIAL_SHARDS` must carry.

The single longest script, `tests/fm-watch-triage.test.sh` at 503378 ms, is the floor for any shard count.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs on both repositories, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the table above:

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

A shard killed before its test step finishes uploads no artifact, so prefer green runs or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
A job that was cancelled after its test step completed still uploaded a full artifact, so it counts as a source and captures the slow-runner case.
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
| portable parallel 1/2 | job `timeout-minutes: 10` | Each balanced shard carries about 7.5 minutes of conservative CI-measured weight, leaving roughly 1.3x hang-tripwire margin. Balancing these on the local isolation proof instead put shard 1 at ~10.9 minutes and cancelled it at the cap, so refresh the maxima above from CI artifacts whenever the proven-isolated set changes. |
| portable serial 1-6 | job `timeout-minutes: 20` | Each balanced shard carries about 16.6 minutes of conservative assignment weight and the recent worst observed shard is about 15.5 minutes, leaving roughly 1.2-1.4x hang-tripwire margin for job setup and runner-speed spread. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
