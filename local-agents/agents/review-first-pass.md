# review-first-pass

## Role

review-first-pass reads one pull request and returns a first-pass review from a different model family than the pull request author.
It does not approve, merge, or comment on the pull request.
Answers meant for Adi are written in Romanian.

## Inputs and tasks

The job id is `review-first-pass/v1`.
`task` is `review`.
`inputs` must include `pr:<owner/repo>#N`.
`author_family` is the author's model family when the submitter knows it.
`reviewer` overrides the reviewer and defaults to `agy/gemini-3.8-flash-high`.
The runner refuses the job when `author_family` equals the reviewer family.

## Host

This agent runs only on adi2.
Its wall clock default is 30 minutes.

## LLM and harness

Static checks run first: `semgrep` with `p/owasp-top-ten` on a temp tree of the changed files, then `gitleaks detect --no-git --redact`.
The model call is `llm-run <harness> --task <job-id> --agent local-review-first-pass --role scout`.
The default harness is agy and the default model is `gemini-3.8-flash-high`.
More than 200 changed files skips the per-file fetch and says so in the summary.

## Outputs

`summary` lists the semgrep count, the gitleaks count, and the top findings.
`status` is `failed` when the reviewer family matches `author_family` or the pull request input is missing.
A completed review uses `succeeded`.
`pr` is the pull request URL when GitHub returns one, otherwise null.
`details` carries the short finding list.
`cost` stays empty unless the model wrapper reports a cost, which v1 does not parse.

## Never

Never publish or send anything externally.
Never comment on a pull request in v1.
Never restart LiteLLM, Langfuse, ComfyUI, containers, or other services.
Never install packages.
Never print secrets. Read them from the environment only.
Never force-push.
Never review with the same model family as `author_family`.
