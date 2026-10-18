# ocr-runner

## Role

ocr-runner reports whether the OCR service is running and, when asked, how many files are in a configured progress directory.
It never restarts OCR, Docker, or the GPU job it is watching.
Answers meant for Adi are written in Romanian.

## Inputs and tasks

The job id is `ocr-runner/v1`.
`task` is `status` or `report`.
Both tasks run the same read-only check.
An optional `inputs` entry `path:<dir>` is a progress directory whose files are counted without crossing mounts.
The path must resolve under the current host's configured root: `/Users/adrianb/dev/manuale-ocr` on mini or `/home/adi/ocr-vlm` on adi1.

## Host

The registry order is mini, then adi1.
Its wall clock default is 10 minutes.
No LLM call is made.

## LLM and harness

`llm` in the registry is `none`.
The runner uses the exact `ocr-vlm` Docker container, with `ocr-vlm.service` as its fallback.
GPU process data is informational only.

## Outputs

`summary` says whether the OCR service is up.
`details` lists the exact service evidence, GPU process data, and the file count when a progress path was given.
`status` is `blocked` when neither the exact container nor its systemd fallback is active.
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
