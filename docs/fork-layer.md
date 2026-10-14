# Fork layer

This fork tracks upstream Firstmate exactly. Every tracked file equals upstream
except the small set below, and every fork-specific behavior ships as an
installable AXI plugin instead of a patch to upstream-owned files.

## Carried files

- `.no-mistakes.yaml` runs `bin/fm-commit-identity-check.sh` before the
  canonical lint, so a push is refused when a commit in the pull-request range
  does not use the operator's global Git identity.
- `bin/fm-commit-identity-check.sh` and its test
  `tests/fm-commit-identity-check.test.sh` own that check.
- `.gitignore` adds two local scratch directories.

## Everything else

Capacity admission, duplicate-work gating, fleet views, quota surfaces,
model fallback, runtime handoff, and the other fork capabilities are delivered
by the AXI plugin packages, not by files in this repository. Install and update
them with the plugin installer; do not patch upstream-owned scripts here.

## Updating

Use the native `/updatefirstmate` flow. The fork's default branch is a
fast-forward descendant of upstream's tree, so the updater needs no special
handling.
