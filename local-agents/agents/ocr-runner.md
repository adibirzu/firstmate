# ocr-runner

## Role

ocr-runner reports whether an OCR container or GPU process is running and, when asked, how many files are in a progress directory.
It never restarts OCR, Docker, or the GPU job it is watching.
Answers meant for Adi are written in Romanian.

## Inputs and tasks

The job id is `ocr-runner/v1`.
`task` is `status` or `report`.
Both tasks run the same read-only check.
An optional `inputs` entry `path:<dir>` is a progress directory whose files are counted.

## Host

The registry order is adi1, then adi2.
Its wall clock default is 10 minutes.
No LLM call is made.

## LLM and harness

`llm` in the registry is `none`.
The runner uses `docker ps` and `nvidia-smi --query-compute-apps` only.

## Outputs

`summary` says whether an OCR container is up and whether a compute app is visible.
`details` lists matching container lines and the file count when a progress path was given.
`status` is `blocked` when no OCR container is running and no compute app is listed.
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
Never start, stop, or restart the OCR container.
