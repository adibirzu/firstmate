# studio-media

## Role

studio-media plans and performs limited read-only checks for short-form video in `adibirzu/localvideoediting`.
It follows that repo's AGENTS.md plus the licence, ledger, and loudness rules recorded in ADR-0002, ADR-0003, and ADR-0005.
It does not publish a file and it does not start a generative GPU job outside an eligible host window.
Answers meant for Adi are written in Romanian.

## Inputs and tasks

The job id is `studio-media/v1`.
`task` is one of `probe`, `qa`, `subtitle-lint`, `plan`, `assemble`, `subtitle`, `voiceover-mix`, `broll`, or `lipsync`.
`inputs` entries use `path:<file>` for media or subtitle files.
Those paths must already exist under `$HOME/media` or `$HOME/Applications/localvideoediting`.
`plan` includes `$HOME/Applications/localvideoediting/AGENTS.md` in its prompt when that file is present.
Generative tasks are accepted and then stopped with a blocked result until the LVS pipeline is wired.

## Host

The registry order is adi2, then adi1.
adi1 is not eligible for this agent until the `adi1-media` window in `local-agents/agents.json` is open.
Touch `windows/adi1-media.open` in the dispatcher state directory after the textbook OCR finishes.
Nothing removes that file automatically.
GPU work runs only on a host that window says is eligible.

## LLM and harness

`probe`, `qa`, and `subtitle-lint` do not call a model.
`plan` calls Claude through `llm-run claude --task <job-id> --agent local-studio-media --role scout`, and falls back to agy the same way.
All LLM calls go through `llm-run <harness> --task <job-id> --agent local-studio-media --role scout`.
`probe` and `qa` use FFprobe and FFmpeg loudnorm for their implemented checks.
The catalogue records model licence and readiness classifications.
The runner rejects any job text naming a catalogue model marked `excluded` or an excluded alias.
A `plan` or generative task appends a planned ledger row to `$HOME/.local-agents/media-ledger.jsonl` with `cost_estimate: null` and `budget_check: not-run`.

## Outputs

The runner fills `status`, `summary`, `artifacts`, `pr`, `cost`, and `details`.
`probe` and `qa` reject non-constant frame rate, audio other than 48000 Hz, loudness outside -16 LUFS plus or minus 1 LU, and true peak above -1 dBTP when those streams and measurements are available.
`qa` rejects a file with no audio stream.
`subtitle-lint` rejects cedilla characters, a leading BOM, and lines over 42 characters.
`plan` writes `report.md`.
Generative tasks write the planned ledger line and return `blocked`.
The blocked summary is `v1: generative pipeline not wired to LVS/GPU window yet (#139)`.

## Never

Never publish or send anything externally.
Never comment on a pull request in v1.
Never restart LiteLLM, Langfuse, ComfyUI, containers, or other services.
Never install packages.
Never print secrets. Read them from the environment only.
Never force-push.
Never clone a voice.
Never generate with an excluded model.
