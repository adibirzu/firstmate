# Fork layer

This fork's target tree tracks upstream Firstmate except for the small set
below. Remaining fork-specific capabilities are planned for separate AXI
plugin work instead of patches to upstream-owned files.

## Carried files

- `.no-mistakes.yaml` runs `bin/fm-commit-identity-check.sh` before the
  canonical lint, so a push is refused when a commit in the pull-request range
  does not use the operator's global Git identity.
- `bin/fm-commit-identity-check.sh` and its test
  `tests/fm-commit-identity-check.test.sh` own that check.
- `.gitignore` adds two local scratch directories.

## Everything else

Capacity admission, duplicate-work gating, fleet views, quota surfaces,
model fallback, runtime handoff, and the other fork capabilities are not
included in this tree. Their AXI plugin implementation and installation
instructions belong to the separate plugin work; do not patch upstream-owned
scripts here.

## Updating

Use the native `/updatefirstmate` flow to refresh the fork from upstream.
