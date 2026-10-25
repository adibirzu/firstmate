# release-watch

## Role

release-watch is a script on the Mini that reports merged and failing pull requests for one repository.
It does not call a model and it does not merge or comment on those pull requests.
Answers meant for Adi are written in Romanian.

## Inputs and tasks

The job id is `release-watch/v1`.
`task` is `poll` or `digest`.
Both tasks run the same read-only report.
The default repository is `Pentforge-io/cyber-bot.ro`.
An `inputs` entry `repo:<owner/name>` overrides that repository.

## Host

This agent runs only on mini.
Its wall clock default is 10 minutes.

## LLM and harness

No LLM call is made.
`llm` in the registry is `none`.

## Outputs

The runner writes `$FM_AGENT_STATE/digest.md` (default `$HOME/dev/mini-state/local-agents/digest.md`) and `report.md`.
`summary` counts merged pull requests and open pull requests with a failing check.
`status` is `blocked` when any open pull request targeting `main` or `prelive` has a check conclusion or state of `FAILURE`.
Otherwise `status` is `succeeded`.
`pr` stays null.
`cost` stays empty.

## Never

Never publish or send anything externally.
Never comment on a pull request in v1.
Never restart LiteLLM, Langfuse, ComfyUI, containers, or other services.
Never install packages.
Never print secrets. Read them from the environment only.
Never force-push.
Never merge a pull request.
