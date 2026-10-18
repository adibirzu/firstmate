# Local agents

This directory is the operator contract for handing a GitHub issue to one local agent.
Grok Bot files the issue.
The dispatcher on the Mini claims it and runs the matching runner on Mini, adi1, or adi2.
Definitions are English.
Answers meant for Adi are Romanian.

## Contract

An eligible issue has exactly one `agent:<name>` label.
It has no `state:running`, `state:done`, `state:failed`, or `state:needs-adi` label, or it has `state:queued`.
The issue author must be listed in [agents.json](agents.json).
Any other author is ignored and the issue is left unchanged.
Grok Bot submits dispatch issues through Adi's GitHub identity, `adibirzu`; that is why the shipped allow-list contains `adibirzu` rather than a separate bot login.
The job is the first fenced `yaml` block whose document has a top-level `job` key.
`job` is `<agent>/v1`.
`id` is a short token.
`task` is one of that agent's tasks.
`host_pref` is an optional list of host names from the registry.
`budget.wall_max` is an optional duration such as `30m` or `2h`, and a value above 6 hours is rejected.

The dispatcher posts one result comment.
A succeeded job is labeled `state:done`.
A failed job is labeled `state:failed`.
A blocked job is labeled `state:needs-adi`.
`state:running` is removed when the result is posted.

````markdown
**Local agent result** — release-watch@mini
```yaml
result:
  job: "rel-watch-01"
  status: "succeeded"
  summary: |
    one short paragraph
```
````

## Hosts

| Host | SSH | Max jobs | Notes |
| --- | --- | --- | --- |
| mini | local | 2 | release-watch and fleet-monitor |
| adi1 | adi1 | 2 | dev-guard; studio-media stays closed until the adi1-media window |
| adi2 | adi2-ts | 2 | dev-guard; default host for studio, review, research, and mapping |

The `adi1-media` window is in [agents.json](agents.json).
studio-media is placed on adi1 only when the clock is at or after `not_before` and `windows/adi1-media.open` exists in the dispatcher state directory (`$FM_AGENT_STATE`, or `$HOME/dev/mini-state/local-agents`).
Touch that file after the textbook OCR finishes.
Nothing removes it automatically.
A job that asks only for a closed host is marked blocked with the window reason.

## Agents

- [studio-media](agents/studio-media.md) probes, checks, and plans local video work.
- [release-watch](agents/release-watch.md) lists recent merges and failing checks.
- [fleet-monitor](agents/fleet-monitor.md) reads disk, tool versions, and host reachability.
- [review-first-pass](agents/review-first-pass.md) reviews a pull request with a different model family.
- [research](agents/research.md) writes a sourced report.
- [ocr-runner](agents/ocr-runner.md) reports OCR progress and never restarts it.
- [issue-mapper](agents/issue-mapper.md) maps pull requests to issues, or returns proposed issue drafts in its result.

The studio model catalogue is [candidates.yaml](studio-media/candidates.yaml).

## Dispatch a job

Open an issue in a registry repo with the label `agent:release-watch` and this body.

````markdown
```yaml
job: release-watch/v1
id: rel-watch-01
task: poll
```
````

Add `state:queued` when you want the queued label recorded before the claim.
The dispatcher also accepts an issue that has the agent label and no state label.

## Start and stop

From a checkout of this repo:

```sh
local-agents/fm-agent-dispatch.tmux.sh start
local-agents/fm-agent-dispatch.tmux.sh status
local-agents/fm-agent-dispatch.tmux.sh stop
```

`start` opens a detached tmux session named `fm-agent-dispatch`.
The session runs `python3 bin/fm-agent-dispatch.py loop` and appends to the state log.
`stop` sends SIGTERM to that session's process only.
State lives in `$FM_AGENT_STATE` or `$HOME/dev/mini-state/local-agents`.
`loop --dry-run` logs the claim and the result comment it would write.
It does not edit the issue, post a comment, or start the runner.

## Data flow

Only issues whose author is listed in `allowed_authors` are processed. Dispatch issue title, URL, body, and YAML job block are staged for the selected runner; PR content is fetched only for a validated review job from a registry repository. Never put secrets in a dispatch issue or its job block.

- `research` sends the staged dispatch brief to Claude, with Gemini/agy as its fallback.
- `issue-mapper` sends the staged dispatch brief to Gemini/agy for `from-findings`; `map` is deterministic and sends no model prompt.
- `studio-media` sends the staged dispatch brief to Claude for `plan`, with Gemini/agy as its fallback; its other tasks do not send a model prompt.
- `review-first-pass` sends the requested PR diff and its local scan report to the selected Gemini/agy, Claude, or Codex reviewer; fetched PR files are scanned locally.
- `release-watch`, `fleet-monitor`, and `ocr-runner` do not send content to a model. Grok is reachable through `llm-run` but is not selected by a shipped runner.

Adi approved these allow-listed issue and PR flows to the listed model families on 2026-10-18 at 12:04; compliance review is deferred until after the MVP under the 2026-10-18 12:16 decision. Before a result is posted back to GitHub, the dispatcher redacts secrets from the result payload.

## Safety

Runners never publish or post to third parties, except that issue-mapper can create issues only for repositories Adi explicitly lists in `allowed_create_repos`.
Approved model submission through `llm-run` is described in [Data flow](#data-flow).
That list is empty in the shipped [agents.json](agents.json), so creation is disabled; `from-findings` returns proposed titles and bodies in the result instead.
They do not comment on pull requests in this version.
They do not restart LiteLLM, Langfuse, ComfyUI, containers, or other services.
They do not install packages.
They do not print secrets.
They do not force-push.
Job text is passed to a runner as a file.
A host that is full is left for the next poll.
A live job is tracked again after a dispatcher restart but is never signalled by the new dispatcher.
When its saved deadline passes, it is finished as `state:needs-adi` with a not-supervised result.
A live PID whose recorded identity no longer matches is treated as reused, never signalled, and finished as failed.
