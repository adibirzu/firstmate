# issue-mapper

## Role

issue-mapper turns pull-request text into a map of closing references, and can draft follow-up issues from a findings note.
`map` is deterministic and does not call a model.
`from-findings` drafts issues and creates them only when the job sets `create: true`.
Answers meant for Adi are written in Romanian.

## Inputs and tasks

The job id is `issue-mapper/v1`.
`task` is `map` or `from-findings`.
An `inputs` entry `repo:<owner/name>` selects the repository and must name one in `agents.json`.
When that entry is absent, the runner uses the repository of the dispatching issue.
`create` defaults to false.
`create: true` is accepted only when the target repository is listed in `allowed_create_repos` for this agent.
When that list is absent, the only allowed target is the repository of the dispatching issue.
Created issues receive the label `agent-draft`.

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
Its `summary` counts pull requests, closing references, and pull requests with no closing reference.
`from-findings` writes a JSON list of `{title, body}` drafts into `report.md`.
`status` is `succeeded` when the report is non-empty.
`details` says whether GitHub issues were created.
`pr` stays null.
`cost` stays empty.

## Never

Never publish or send anything externally.
Never comment on a pull request in v1.
Never restart LiteLLM, Langfuse, ComfyUI, containers, or other services.
Never install packages.
Never print secrets. Read them from the environment only.
Never force-push.
Never create an issue unless `create` is true.
