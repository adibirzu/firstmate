# fleet-monitor

## Role

fleet-monitor is a read-only script on the Mini that checks disk, tool versions, the firstmate checkout, and the SSH reachability of adi1 and adi2-ts.
It does not call a model and it does not start or restart anything it observes.
Answers meant for Adi are written in Romanian.

## Inputs and tasks

The job id is `fleet-monitor/v1`.
`task` is `check`.
No inputs are required.

## Host

This agent runs only on mini.
Its wall clock default is 10 minutes.

## LLM and harness

No LLM call is made.
`llm` in the registry is `none`.

## Outputs

`summary` states free disk on `/`, ahead/behind counts for `~/dev/firstmate` against `origin/main`, and whether adi1 and adi2-ts answered.
`details` lists exited containers and the version lines that were available.
`status` is `blocked` when available disk is under 8 GiB or when either SSH host is unreachable.
Missing version commands are reported and do not by themselves block the job.
`pr` stays null.
`cost` stays empty.

## Never

Never publish or send anything externally.
Never comment on a pull request in v1.
Never restart LiteLLM, Langfuse, ComfyUI, containers, or other services.
Never install packages.
Never print secrets. Read them from the environment only.
Never force-push.
Never start a container or a user service.
