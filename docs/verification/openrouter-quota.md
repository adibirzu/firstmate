# OpenRouter capacity reader verification

Audience: maintainer verification.

This record supports `bin/fm-openrouter-quota.sh`.
The script header and `--help` own flags, commands, paths, cooldown bounds, and key handling.
This page records live API facts that the reader must keep handling.

Verified 2026-08-23 against `GET https://openrouter.ai/api/v1/key`, `GET https://openrouter.ai/api/v1/models`, and bounded `POST /api/v1/chat/completions` probes of price-zero models.
The working credential was `OPENROUTER_API_KEY_TOKENS` in the process environment.
Its value is redacted here and was not present in stdout, stderr, the state file, or any file under the isolated home after the run.
The reader handed that value to curl on standard input as the Authorization header (`-H @-`); the live completion below proves OpenRouter accepted requests authenticated that way.
The stubbed-HTTP test `tests/fm-openrouter-quota.test.sh` proves the behaviours a single live capture cannot show: no file under the reader's home or temp directory ever contains the key, probes paced by `FM_OPENROUTER_PROBE_INTERVAL_SECONDS`, 404 and 403 verdicts remembered across runs until `clear --model <id>` or `clear --all-verdicts`, `clear --all-verdicts` keeping live 429 cooldowns, unprobed models past `FM_OPENROUTER_PROBE_MAX` reported as `probe-budget-exhausted` in a kept partial report, a `record-failure` that lands during a sweep succeeding and being merged rather than overwritten, `~vendor/model-latest` aliases priced as ordinary rows with tier taken from price, a paid row never published as eligible, and `record-failure --observed 404` on a paid id recording a permanent verdict where `--observed 429` records a short cooldown.

## Commands

An isolated `FM_HOME` is required so cooldown state cannot land in another home.
The key is supplied only as an environment variable.

```sh
export FM_HOME=$(mktemp -d /tmp/fm-openrouter-quota-verify.XXXXXX)
export OPENROUTER_API_KEY_TOKENS='<redacted>'
mkdir -p "$FM_HOME/state"
bin/fm-openrouter-quota.sh report 2>openrouter-quota.err > full.json
jq '{
  schemaVersion,
  generatedAt,
  key,
  modelCount: (.models|length),
  freeCount: ([.models[] | select(.tier=="free")] | length),
  routing: {
    eligibleFree: .routing.eligibleFree,
    unverifiedPaidByCost: .routing.unverifiedPaidByCost[:3]
  },
  free: [.models[] | select(.tier=="free") | {id, eligible, reason}],
  paidSamples: [
    .models[]
    | select(.id=="openai/gpt-oss-20b" or .id=="openai/gpt-oss-120b" or .id=="google/gemma-3-12b-it" or .id=="openrouter/auto" or .id=="~anthropic/claude-haiku-latest")
    | {id, eligible, promptPerMillion, completionPerMillion, reason}
  ]
}' full.json
```

The jq filter is documentation of the bounded evidence, not part of the reader.
The reader itself prints the full model list on stdout.
A sweep of N price-zero models that are not remembered or in cooldown issues N paced chat-completion probes, so at the default 4 second interval a first run over this catalog takes about ninety seconds and later runs probe only the models without a remembered verdict.
After changing the OpenRouter privacy or allowed-provider settings, run `bin/fm-openrouter-quota.sh clear --all-verdicts` so the remembered 404 and 403 models are probed live again; live 429 cooldowns survive that command.

## Sanitized stderr

```text
fm-openrouter-quota: model=stealth/ox-alpha unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=dots-studio/dots-3-note-preview:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=liquid/lfm-2.5-2.6b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-3.5-lightning:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=thinkingmachines/inkling-small:free unavailable: platform-restricted
fm-openrouter-quota: model=poolside/laguna-s-2.1:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=thinkingmachines/inkling:free unavailable: platform-restricted
fm-openrouter-quota: model=poolside/laguna-xs-2.1:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=cohere/north-mini-code:free eligible: live completion succeeded
fm-openrouter-quota: model=z-ai/glm-5.2:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-3.5-content-safety:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-3-ultra-550b-a55b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=google/gemma-4-26b-a4b-it:free unavailable: cooldown until epoch 1787501210
fm-openrouter-quota: model=google/gemma-4-31b-it:free unavailable: cooldown until epoch 1787501210
fm-openrouter-quota: model=google/lyria-3-pro-preview unavailable: http-502
fm-openrouter-quota: model=google/lyria-3-clip-preview unavailable: http-502
fm-openrouter-quota: model=nvidia/nemotron-3-super-120b-a12b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=openrouter/free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-3-nano-30b-a3b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-nano-12b-v2-vl:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-nano-9b-v2:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: report models=422 free=22 probes=22 remembered=0 unprobed=0 skipped=0
```

The summary line reads `report models= free= probes= remembered= unprobed= skipped=`; this run started from an empty state file, so nothing was remembered yet and every price-zero model was probed.
Models with a remembered 404 or 403 verdict are logged with the suffix `(remembered verdict)` and are not probed.

## Bounded stdout

```json
{
  "schemaVersion": 1,
  "generatedAt": 1787499410,
  "key": {
    "usage": 0.00003453,
    "usage_daily": 0.00003453,
    "usage_weekly": 0.00003453,
    "usage_monthly": 0.00003453,
    "limit": null,
    "limit_remaining": null,
    "is_free_tier": false
  },
  "modelCount": 422,
  "freeCount": 22,
  "routing": {
    "eligibleFree": [
      "cohere/north-mini-code:free"
    ],
    "unverifiedPaidByCost": [
      "inclusionai/ling-2.6-flash",
      "mistralai/mistral-nemo",
      "inclusionai/ling-3.0-flash"
    ]
  },
  "free": [
    {
      "id": "cohere/north-mini-code:free",
      "eligible": true,
      "reason": "live completion succeeded"
    },
    {
      "id": "dots-studio/dots-3-note-preview:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "google/gemma-4-26b-a4b-it:free",
      "eligible": false,
      "reason": "cooldown until epoch 1787501210"
    },
    {
      "id": "google/gemma-4-31b-it:free",
      "eligible": false,
      "reason": "cooldown until epoch 1787501210"
    },
    {
      "id": "google/lyria-3-clip-preview",
      "eligible": false,
      "reason": "http-502"
    },
    {
      "id": "google/lyria-3-pro-preview",
      "eligible": false,
      "reason": "http-502"
    },
    {
      "id": "liquid/lfm-2.5-2.6b:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "nvidia/nemotron-3-nano-30b-a3b:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "nvidia/nemotron-3-super-120b-a12b:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "nvidia/nemotron-3-ultra-550b-a55b:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "nvidia/nemotron-3.5-content-safety:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "nvidia/nemotron-3.5-lightning:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "nvidia/nemotron-nano-12b-v2-vl:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "nvidia/nemotron-nano-9b-v2:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "openrouter/free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "poolside/laguna-s-2.1:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "poolside/laguna-xs-2.1:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "stealth/ox-alpha",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "thinkingmachines/inkling-small:free",
      "eligible": false,
      "reason": "platform-restricted"
    },
    {
      "id": "thinkingmachines/inkling:free",
      "eligible": false,
      "reason": "platform-restricted"
    },
    {
      "id": "z-ai/glm-5.2:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    }
  ],
  "paidSamples": [
    {
      "id": "openai/gpt-oss-20b",
      "eligible": false,
      "promptPerMillion": 0.03,
      "completionPerMillion": 0.13,
      "reason": "priced and not in cooldown; reachability unverified"
    },
    {
      "id": "google/gemma-3-12b-it",
      "eligible": false,
      "promptPerMillion": 0.05,
      "completionPerMillion": 0.15,
      "reason": "priced and not in cooldown; reachability unverified"
    },
    {
      "id": "openai/gpt-oss-120b",
      "eligible": false,
      "promptPerMillion": 0.037,
      "completionPerMillion": 0.17,
      "reason": "priced and not in cooldown; reachability unverified"
    },
    {
      "id": "~anthropic/claude-haiku-latest",
      "eligible": false,
      "promptPerMillion": 1,
      "completionPerMillion": 5,
      "reason": "priced and not in cooldown; reachability unverified"
    },
    {
      "id": "openrouter/auto",
      "eligible": false,
      "promptPerMillion": null,
      "completionPerMillion": null,
      "reason": "pricing-missing"
    }
  ]
}
```

## Paid rows are unverified by design

The reader does not probe paid models, so no paid row is ever published as `eligible`; each carries `priced and not in cooldown; reachability unverified`, which a consumer can tell apart from a free row's `live completion succeeded` without guessing.
`routing.unverifiedPaidByCost` is therefore a cheapest-first ordering of priced, non-cooldown paid models with no remembered verdict, not a list dispatch can spend on today.
Reachability is established on first real use: when a launch on one of these ids is rejected, `record-failure --model <id> --observed 404` (or `403`) records a permanent verdict that removes it from the ordering, and `--observed 429` records the short cooldown, so the ordering corrects itself through use instead of costing a probe per paid model on every run.
The head of the ordering on this account is unreachable, as the probe below shows.
Each entry of the ordering was probed in price order with one bounded chat completion until one succeeded.

```sh
for m in $(jq -r '.routing.unverifiedPaidByCost[:40][]' full.json); do
  printf 'Authorization: Bearer %s\n' "$OPENROUTER_API_KEY_TOKENS" \
    | curl -sS --max-time 20 -o probe-body.json -w '%{http_code}' -X POST -H @- \
        -H 'Content-Type: application/json' \
        --data-binary "$(jq -nc --arg id "$m" '{model:$id, messages:[{role:"user", content:"ok"}], max_tokens:1}')" \
        https://openrouter.ai/api/v1/chat/completions
  # stop at the first 200; a 404 body containing "No allowed providers" is the account privacy gate
done
```

```text
model=inclusionai/ling-2.6-flash perMillion=0.01/0.03 http=404 no-allowed-providers
model=mistralai/mistral-nemo perMillion=0.019/0.03 http=404 no-allowed-providers
model=inclusionai/ling-3.0-flash perMillion=0.021/0.063 http=404 no-allowed-providers
model=sao10k/l3-lunaris-8b perMillion=0.04/0.05 http=404 no-allowed-providers
model=gryphe/mythomax-l2-13b perMillion=0.06/0.06 http=404 no-allowed-providers
model=nex-agi/nex-n2-mini perMillion=0.025/0.1 http=404 no-allowed-providers
model=ibm-granite/granite-4.0-h-micro perMillion=0.017/0.112 http=404 no-allowed-providers
model=meta-llama/llama-3.1-8b-instruct perMillion=0.05/0.08 http=404 no-allowed-providers
model=mistralai/mistral-small-24b-instruct-2501 perMillion=0.05/0.08 http=404 no-allowed-providers
model=deepseek/deepseek-v4-flash perMillion=0.04886/0.09772 http=404 no-allowed-providers
model=upstage/solar-pro4 perMillion=0.03/0.12 http=404 no-allowed-providers
model=google/gemma-3-4b-it perMillion=0.05/0.1 http=404 no-allowed-providers
model=ibm-granite/granite-4.1-8b perMillion=0.05/0.1 http=404 no-allowed-providers
model=openai/gpt-oss-20b perMillion=0.03/0.13 http=200
```

The thirteen cheapest entries, from `inclusionai/ling-2.6-flash` at $0.01/M prompt upward, all returned HTTP 404 `No allowed providers` and are not usable by dispatch until the allowed-providers setting admits their providers; recording each with `record-failure --model <id> --observed 404` removes it from the ordering for good.
The cheapest paid model that actually completes on this account is `openai/gpt-oss-20b` at $0.03/M prompt and $0.13/M completion, the fourteenth entry of the ordering.

## Load-bearing facts

- The catalog is live: this run listed 422 models and probed 22 price-zero models, not a hardcoded allow-list.
- Exactly one free model returned a real completion in this run, `cohere/north-mini-code:free`, and the reader reports that single route without assuming a second one exists.
- The catalog carries 12 `~vendor/model-latest` aliases such as `~anthropic/claude-haiku-latest`; they are ordinary paid rows priced from the catalog ($1/M prompt and $5/M completion for that one) and are not probed.
- HTTP 404 bodies containing `No allowed providers` are a stable account privacy gate and are skipped without a cooldown; `openrouter/free` returned that gate in this run.
- HTTP 403 platform restriction is skipped without a cooldown (`thinkingmachines/inkling:free` and `thinkingmachines/inkling-small:free`).
- HTTP 429 is a per-model cooldown (`google/gemma-4-26b-a4b-it:free` and `google/gemma-4-31b-it:free` until epoch 1787501210, which is `generatedAt + 1800`).
- HTTP 502 from an upstream is reported for that run only (`google/lyria-3-pro-preview` and `google/lyria-3-clip-preview`) and is neither a cooldown nor a remembered verdict.
- Tier comes from price alone: a row is `free` when both per-token prices are zero and `paid` otherwise, and `routing.unverifiedPaidByCost` is ordered by prompt plus completion price with no floor or threshold.
- No paid row is published as eligible; the paid ordering is unverified by design and the cheapest paid model that actually completes on this account is `openai/gpt-oss-20b` at $0.03/M prompt and $0.13/M completion.
- Per-million prices are rounded to six decimals, so `google/gemma-3-12b-it` publishes as `0.05` prompt and `openai/gpt-oss-120b` as `0.17` completion with no binary float noise.
- A per-token price of `-1` is OpenRouter's variable-pricing sentinel (`openrouter/auto`) and must not sort as a cheap paid route.
- `limit` null means this key has no spend cap.
- OpenRouter documents a 20 requests per minute limit on free models, which is why the reader paces probes 4 seconds apart by default (15 per minute) and remembers the stable 404 and 403 verdicts instead of re-spending probes on them.
- Key material did not appear in stdout, stderr, or any file under the isolated home, and the key was never written to a file during this run.
