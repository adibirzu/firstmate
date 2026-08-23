# OpenRouter capacity reader verification

Audience: maintainer verification.

This record supports `bin/fm-openrouter-quota.sh`.
The script header and `--help` own flags, commands, paths, cooldown bounds, and key handling.
This page records live API facts that the reader must keep handling.

Verified 2026-08-23 against `GET https://openrouter.ai/api/v1/key`, `GET https://openrouter.ai/api/v1/models`, and bounded `POST /api/v1/chat/completions` probes of price-zero models.
The working credential was `OPENROUTER_API_KEY_TOKENS` in the process environment.
Its value is redacted here and was not present in stdout or stderr.
The reader hands that value to curl on standard input as the Authorization header and never writes it to a file; the stubbed-HTTP test `tests/fm-openrouter-quota.test.sh` proves that no file under the reader's home or temp directory contains the key while a request is in flight or after the run.
The same offline suite proves the behaviours that a single live capture cannot show: per-million prices rounded to six decimals, probes paced by `FM_OPENROUTER_PROBE_INTERVAL_SECONDS`, 404 and 403 verdicts remembered across runs until `clear --model <id>` or `clear --all-verdicts`, `clear --all-verdicts` keeping live 429 cooldowns, unprobed models past `FM_OPENROUTER_PROBE_MAX` reported as `probe-budget-exhausted` in a kept partial report, and a `record-failure` that lands during a sweep succeeding and being merged rather than overwritten.
The captured stdout and stderr blocks below were produced by the reader revision that passed the Authorization header through a temporary file; the stdin transport that replaced it has not yet been captured live and the blocks are kept because they are the only live evidence on record.

## Commands

An isolated `FM_HOME` is required so cooldown state cannot land in another home.
The key is supplied only as an environment variable.

```sh
export FM_HOME=/tmp/fm-openrouter-quota-verify
export OPENROUTER_API_KEY_TOKENS='<redacted>'
mkdir -p "$FM_HOME/state"
bin/fm-openrouter-quota.sh report 2>openrouter-quota.err | jq '{
  schemaVersion,
  generatedAt,
  key,
  modelCount: (.models|length),
  freeCount: ([.models[] | select(.tier=="free")] | length),
  routing: {
    eligibleFree: .routing.eligibleFree,
    cheapestPricedPaid: .routing.eligiblePaidByCost[:3]
  },
  free: [.models[] | select(.tier=="free") | {id, eligible, reason}],
  paidSamples: [
    .models[]
    | select(.id=="openai/gpt-oss-20b" or .id=="openai/gpt-oss-120b" or .id=="google/gemma-3-12b-it" or .id=="openrouter/auto")
    | {id, eligible, promptPerMillion, completionPerMillion, reason}
  ]
}'
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
fm-openrouter-quota: model=google/gemma-4-26b-a4b-it:free unavailable: cooldown until epoch 1787495349
fm-openrouter-quota: model=google/gemma-4-31b-it:free unavailable: cooldown until epoch 1787495349
fm-openrouter-quota: model=google/lyria-3-pro-preview unavailable: http-502
fm-openrouter-quota: model=google/lyria-3-clip-preview unavailable: http-502
fm-openrouter-quota: model=nvidia/nemotron-3-super-120b-a12b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=openrouter/free eligible: live completion succeeded
fm-openrouter-quota: model=nvidia/nemotron-3-nano-30b-a3b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-nano-12b-v2-vl:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-nano-9b-v2:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: report models=410 free=22 probes=22
```

The summary line of the current reader reads `report models= free= probes= remembered= unprobed= skipped=`.
Models with a remembered 404 or 403 verdict are logged with the suffix `(remembered verdict)` and are not probed.

## Bounded stdout

The current reader publishes the two `paidSamples` figures `0.049999999999999996` and `0.16999999999999998` as `0.05` and `0.17`, because per-million prices are rounded to six decimals.

```json
{
  "schemaVersion": 1,
  "generatedAt": 1787493549,
  "key": {
    "usage": 0.00002952,
    "usage_daily": 0.00002952,
    "usage_weekly": 0.00002952,
    "usage_monthly": 0.00002952,
    "limit": null,
    "limit_remaining": null,
    "is_free_tier": false
  },
  "modelCount": 410,
  "freeCount": 22,
  "routing": {
    "eligibleFree": [
      "cohere/north-mini-code:free",
      "openrouter/free"
    ],
    "cheapestPricedPaid": [
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
      "id": "openrouter/free",
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
      "reason": "cooldown until epoch 1787495349"
    },
    {
      "id": "google/gemma-4-31b-it:free",
      "eligible": false,
      "reason": "cooldown until epoch 1787495349"
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
      "eligible": true,
      "promptPerMillion": 0.03,
      "completionPerMillion": 0.13,
      "reason": "priced and not in cooldown"
    },
    {
      "id": "google/gemma-3-12b-it",
      "eligible": true,
      "promptPerMillion": 0.049999999999999996,
      "completionPerMillion": 0.15,
      "reason": "priced and not in cooldown"
    },
    {
      "id": "openai/gpt-oss-120b",
      "eligible": true,
      "promptPerMillion": 0.037,
      "completionPerMillion": 0.16999999999999998,
      "reason": "priced and not in cooldown"
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

## Load-bearing facts

- The catalog is live: this run listed 410 models and probed 22 price-zero models, not a hardcoded allow-list.
- Exactly the models that returned a real completion were eligible free routes: `cohere/north-mini-code:free` and `openrouter/free`.
- HTTP 404 bodies containing `No allowed providers` are a stable account privacy gate and are skipped without a cooldown.
- HTTP 403 platform restriction is skipped without a cooldown (`thinkingmachines/inkling:free` and `thinkingmachines/inkling-small:free`).
- HTTP 429 is a per-model cooldown (`google/gemma-4-31b-it:free` and `google/gemma-4-26b-a4b-it:free` until epoch 1787495349, which is `now + 1800`).
- Paid models are priced from the catalog and not probed: `openai/gpt-oss-20b` is $0.03/M prompt and $0.13/M completion.
- Catalog per-token strings such as `0.00000005` and `0.00000017` multiply to binary float noise; the reader rounds per-million prices to six decimals so `google/gemma-3-12b-it` publishes as `0.05` prompt and `openai/gpt-oss-120b` as `0.17` completion.
- A per-token price of `-1` is OpenRouter's variable-pricing sentinel (`openrouter/auto`) and must not sort as a cheap paid route.
- `limit` null means this key has no spend cap.
- OpenRouter documents a 20 requests per minute limit on free models, which is why the reader paces probes 4 seconds apart by default (15 per minute) and remembers the stable 404 and 403 verdicts instead of re-spending probes on them.
- Key material did not appear in stdout or stderr, and the key is never written to a file.
