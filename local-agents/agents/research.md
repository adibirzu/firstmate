# research

## Role

research writes a sourced Markdown report for one question and stops there.
It does not open issues, send mail, or change a repository.
Answers meant for Adi are written in Romanian.

## Inputs and tasks

The job id is `research/v1`.
`task` is `research`.
The question is the issue title and body, staged as `brief.md`.
`budget.wall_max` overrides the 45 minute default and is capped at 6 hours by the dispatcher.

## Host

This agent runs only on adi2.
Its wall clock default is 45 minutes.

## LLM and harness

The runner calls `llm-run claude --task <job-id> --agent local-research --role scout` with only WebSearch, WebFetch, and Read.
The prompt is `agent.md`, `brief.md`, and the instruction to write `report.md` with a `## Summary` section of at most 10 lines.
If Claude fails, it retries once through `LLM_RUN_BIN=agy llm-run gemini --task <job-id> --agent local-research --role scout --model gemini-3.8-flash-high`.
All LLM calls go through `llm-run <harness> --task <job-id> --agent local-research --role scout`.

## Outputs

`report.md` is the report.
`summary` is the `## Summary` section, truncated to 10 lines, or the first 10 non-empty lines when that section is absent.
`status` is `succeeded` when the report is non-empty, otherwise `failed`.
`artifacts` lists `report.md` when it exists.
`pr` stays null.
`cost` stays empty.

## Never

Never publish or send anything externally.
Never comment on a pull request in v1.
Never restart LiteLLM, Langfuse, ComfyUI, containers, or other services.
Never install packages.
Never print secrets. Read them from the environment only.
Never force-push.
Never enable Bash, Edit, or Write on the Claude tool list.
