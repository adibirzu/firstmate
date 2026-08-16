# Local test evidence - fm/fm-restore-main-ci

Machine: macOS (arm64), bash 5.3 for the suites, /bin/bash 3.2.57 for the stock-Bash job,
herdr 0.7.4 / protocol 16 (the exact CI pin), treehouse installed.

## CI jobs reproduced locally

| CI job | Local reproduction | Result |
|---|---|---|
| Stock macOS Bash snapshot compatibility | job script replayed verbatim under `/bin/bash` 3.2.57 on macOS | PASS (`macos-stock-bash-job.txt`) |
| Test coverage guard | `bin/fm-test-run.sh --check-coverage` | PASS - `total=168 parallel=24 serial=133 serial_shards=4 herdr=11` |
| Behavior portable serial/parallel (changed scripts + their consumers) | 16 scripts through `bin/fm-test-run.sh` | PASS, 0 failed (`targeted-serial-run.txt`, `muse-harness.txt`, `watch-triage.txt`) |
| Behavior tests (Herdr) | `tests/fm-backend-herdr-presentation-e2e.test.sh` against real pinned herdr | FAIL at one late case, twice, identically (`herdr-presentation-e2e.txt`, `-run2.txt`) |
| Lint shell scripts | not run here - owned by the pipeline's lint phase | n/a |

## Regression reproductions (fail before the fix, pass after)

1. Intake failure 1 - `muse spawn from a marked backend should succeed`
   (`regression-base-muse-harness.txt`): the current test run against the merge-base tree gives
   `not ok - muse spawn from a marked backend should succeed: error: unknown harness 'muse'`.
   Against this branch the same script is 25/25 ok.

2. Captain's report - `bin/fm-control.sh:814` passes `--relaunch` to `fm-spawn.sh`
   (`relaunch-flag-before-after.txt`, `regression-base-control-relaunch.txt`): at the merge-base
   the flag falls through into the positional list and `PROJ` becomes the literal `--relaunch`
   (`cd: --: invalid option`); on this branch the same command line reaches the record-driven
   relaunch path. `tests/fm-control-relaunch.test.sh` (48 cases) fails on the first case at the
   merge-base and is fully green here.

## Remaining red

`tests/fm-backend-herdr-presentation-e2e.test.sh` reaches a later case than it could before this
branch (the merge-base run aborts earlier, at the abort-cleanup case this branch fixed) and then
fails deterministically:

    not ok - projected teardown changed active workspace/tab from w3/w3:t1 to w8/w8:t2

Both runs failed identically. This case is untouched by the branch and the branch's `bin/backends/herdr.sh`
edits are confined to capture/composer classification, not the teardown/close/focus path - so it reads as a
pre-existing behaviour newly unmasked, in the same shape as the three exclusions already accepted in the PR,
except that this one sits inside the required Herdr lane. Whether it also fails on the Linux runner that
actually runs that job could not be determined from this machine.
