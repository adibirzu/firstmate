# Code review: deterministic-first policy

`bin/fm-review.sh` wraps Alibaba's Open Code Review (`ocr`, https://github.com/alibaba/open-code-review) into a two-stage review that keeps most PRs on a zero-LLM-token path.

## How it works

**Stage 1 (always runs, zero LLM tokens).**
`ocr delegate preview` selects the reviewable file set for the diff and reports its size.
The target repo's own already-configured linter then runs against exactly that OCR-selected file set: `bin/fm-lint.sh` when the target repo is firstmate itself (invoked with the OCR-selected files that fall in its own canonical set - `bin/*.sh`, `bin/backends/*.sh`, `tests/*.sh` - so lint findings always correspond to the reviewed diff, even in `pr` mode or with a custom `--from`/`--to`), otherwise a `package.json` `"lint"` script when one exists (which lints the whole repo, per that script's own convention).
No other linter is auto-detected; a repo with neither simply skips this step.

**Stage 2 (only when Stage 1 gives a reason).**
Escalation triggers on any of:

- the changeset exceeds the configured size threshold,
- a changed file matches a configured high-risk pattern,
- the linter reported findings.

Stage 2 has two modes:

- `delegate` (default) - no LLM call.
  `ocr delegate rule` prints the deterministic rule text for exactly the OCR-selected files, and the calling agent's own harness reviews them directly.
  This is the default because it never depends on a separate metered call succeeding.
- `litellm` - a real LLM pass via `ocr review --provider litellm --model <model>`, scoped to the same OCR-selected diff, through the gateway documented in `LIFEOS/DOCUMENTATION/Services/Gb10Fleet.md`.
  Requires a working LiteLLM virtual key registered on that gateway; see Known limitations below.

## Usage

```sh
bin/fm-review.sh worktree --from main --to HEAD
bin/fm-review.sh worktree --dir /path/to/other/repo --from main --to feature-branch
bin/fm-review.sh pr https://github.com/owner/repo/pull/123
bin/fm-review.sh worktree --format json --output verdict.json
bin/fm-review.sh worktree --stage1-only
```

`worktree` mode reviews a local ref range (default `--from`: merge-base with `origin/main` or `main`; default `--to`: `HEAD`).
`pr` mode resolves the PR's base ref via `gh` and reviews base..HEAD in the current checkout.

## Exit codes

- `0` - Stage 1 clean, no escalation (or a `litellm` Stage 2 pass completed; its own findings are in the verdict body, not the exit code).
- `1` - the linter found findings with no other escalation reason, or a required tool failed (missing `ocr`/`jq`/`gh`, or a failed `litellm` call).
- `2` - escalated in `delegate` mode: a host-agent review is still owed before this PR is ready.

## Configuration

`config/code-review` at the target repo's root, JSON, all keys optional (this file is local per-repo config, matching `config/`'s normal gitignored convention - see `AGENTS.md` section 2):

```json
{
  "sizeThreshold": 1000,
  "riskPatterns": ["auth/**", "payment/**"],
  "stage2Mode": "delegate",
  "stage2Provider": "litellm",
  "stage2Model": "anthropic/claude-haiku-4-5"
}
```

Built-in defaults when the file is absent: `sizeThreshold` 1000, no risk patterns, `stage2Mode` `delegate`.
`riskPatterns` are bash glob patterns matched against each reviewable file's repo-relative path.
`FM_REVIEW_SIZE_THRESHOLD`, `FM_REVIEW_STAGE1_ONLY`, and `FM_REVIEW_STAGE2_MODE` override the config file for one-off runs.

A secondmate home inherits this repo's own `config/code-review` the same way it inherits every other `config/` file per `AGENTS.md` section 2; a project this wrapper reviews (via `--dir`) reads its own `config/code-review`, not firstmate's.

## Integration

- **direct-PR briefs** run Stage 1 before opening the PR and paste the verdict into the PR body (`bin/fm-brief.sh`, `bin/fm-dod-lib.sh`).
- **no-mistakes briefs** run Stage 1 first so the pipeline's own reviewer sees a cleaner diff; the no-mistakes pipeline itself is unchanged (`bin/fm-dod-lib.sh`).
- Point a project's code-review skill or step at `bin/fm-review.sh` instead of an unconditional full-diff LLM review.

## Known limitations

- The GB10 LiteLLM gateway's registered virtual key for this Mac did not authenticate against `http://100.85.233.75:4000` when this wrapper was built (`token_not_found_in_db`) - a gateway-side key registration issue, not something this wrapper can fix.
  Until it is resolved, `stage2Mode: "litellm"` fails Stage 2 with exit `1`; `delegate` (the default) is unaffected since it makes no gateway call.
- Auto-detected linters are intentionally narrow (firstmate's own `bin/fm-lint.sh`, or a `package.json` `lint` script).
  A repo using another toolchain (`ruff`, `golangci-lint`, etc.) gets Stage 1 file-selection and sizing but no linter findings until it adds a `package.json` lint script or this detection list is extended.

## See also

- `bin/fm-review.sh` - wrapper implementation and `--help`.
- `tests/fm-review.test.sh` - test suite (fake `ocr`/`gh` binaries, no network).
- https://github.com/alibaba/open-code-review - OCR documentation and the AACR-bench dataset.
