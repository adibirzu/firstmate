# issue-mapper

## Role

issue-mapper turns pull-request text into a map of closing references, and can draft follow-up issues from a findings note.
`map` is deterministic and does not call a model.
`from-findings` returns proposed issues in its result block.
Answers meant for Adi are written in Romanian.

## Inputs and tasks

The job id is `issue-mapper/v1`.
`task` is `map` or `from-findings`.
An `inputs` entry `repo:<owner/name>` selects the repository and must name one in `agents.json`.
When that entry is absent, the runner uses the repository of the dispatching issue.
`create` defaults to false.
`create: true` is accepted only when the target repository is listed in `allowed_create_repos` for this agent.
The list defaults to empty, including when it is absent; it is empty in the shipped registry, so creation is disabled until Adi explicitly lists approved repositories.

## Host

This agent runs only on adi2.
Its wall clock default is 20 minutes.

## LLM and harness

`map` does not call a model.
`from-findings` calls `llm-run agy --task <job-id> --agent local-issue-mapper --role scout`.
All LLM calls go through `llm-run <harness> --task <job-id> --agent local-issue-mapper --role scout`.
The default model is `gemini-3.8-flash-high`.

## Outputs

`map` writes `report.md` as a table of pull requests and `(Closes|Fixes|Resolves) #N` references.
Its `summary` counts scanned pull requests and closing references.
`from-findings` returns a JSON list of `{title, body}` proposals in `details` of the result block.
Both tasks use `succeeded` after their report or draft result is written.
`pr` stays null.
`cost` stays empty.

## Never

Never publish or send anything externally.
Never comment on a pull request in v1.
Never restart LiteLLM, Langfuse, ComfyUI, containers, or other services.
Never install packages.
Never print secrets. Read them from the environment only.
Never force-push.
Never create an issue unless `create` is true and the dispatcher has accepted its repository against `allowed_create_repos`.
