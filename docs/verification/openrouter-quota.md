# OpenRouter capacity reader verification

Audience: maintainer verification.

This record supports `bin/fm-openrouter-quota.sh`.
The script header and `--help` own flags, commands, paths, cooldown bounds, and key handling.
This page records live API facts that the reader must keep handling.

Verified 2026-08-23 against `GET https://openrouter.ai/api/v1/key`, `GET https://openrouter.ai/api/v1/models`, and bounded `POST /api/v1/chat/completions` probes of price-zero models.
The working credential was `OPENROUTER_API_KEY_TOKENS` in the process environment.
Its value is redacted here and was not present in stdout, stderr, the state file, or any file under the isolated home after the run.
The reader handed that value to curl on standard input as the Authorization header (`-H @-`); the two live completions below prove OpenRouter accepted requests authenticated that way.
The stubbed-HTTP test `tests/fm-openrouter-quota.test.sh` proves the behaviours a single live capture cannot show: no file under the reader's home or temp directory ever contains the key, probes paced by `FM_OPENROUTER_PROBE_INTERVAL_SECONDS`, 404 and 403 verdicts remembered across runs until `clear --model <id>` or `clear --all-verdicts`, `clear --all-verdicts` keeping live 429 cooldowns, unprobed models past `FM_OPENROUTER_PROBE_MAX` reported as `probe-budget-exhausted` in a kept partial report, and a `record-failure` that lands during a sweep succeeding and being merged rather than overwritten.

## Commands

An isolated `FM_HOME` is required so cooldown state cannot land in another home.
The key is supplied only as an environment variable.

```sh
export FM_HOME=$(mktemp -d /tmp/fm-openrouter-quota-verify.XXXXXX)
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
fm-openrouter-quota: model=~z-ai/glm-latest skipped: unsupported id shape
fm-openrouter-quota: model=dots-studio/dots-3-note-preview:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=liquid/lfm-2.5-2.6b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-3.5-lightning:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=~deepseek/deepseek-v4-flash-latest skipped: unsupported id shape
fm-openrouter-quota: model=thinkingmachines/inkling-small:free unavailable: platform-restricted
fm-openrouter-quota: model=poolside/laguna-s-2.1:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=thinkingmachines/inkling:free unavailable: platform-restricted
fm-openrouter-quota: model=~x-ai/grok-latest skipped: unsupported id shape
fm-openrouter-quota: model=poolside/laguna-xs-2.1:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=cohere/north-mini-code:free eligible: live completion succeeded
fm-openrouter-quota: model=z-ai/glm-5.2:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=~anthropic/claude-fable-latest skipped: unsupported id shape
fm-openrouter-quota: model=nvidia/nemotron-3.5-content-safety:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-3-ultra-550b-a55b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=~anthropic/claude-haiku-latest skipped: unsupported id shape
fm-openrouter-quota: model=~openai/gpt-mini-latest skipped: unsupported id shape
fm-openrouter-quota: model=~google/gemini-pro-latest skipped: unsupported id shape
fm-openrouter-quota: model=~moonshotai/kimi-latest skipped: unsupported id shape
fm-openrouter-quota: model=~google/gemini-flash-latest skipped: unsupported id shape
fm-openrouter-quota: model=~anthropic/claude-sonnet-latest skipped: unsupported id shape
fm-openrouter-quota: model=~openai/gpt-latest skipped: unsupported id shape
fm-openrouter-quota: model=~anthropic/claude-opus-latest skipped: unsupported id shape
fm-openrouter-quota: model=google/gemma-4-26b-a4b-it:free eligible: live completion succeeded
fm-openrouter-quota: model=google/gemma-4-31b-it:free unavailable: cooldown until epoch 1787499238
fm-openrouter-quota: model=google/lyria-3-pro-preview unavailable: http-502
fm-openrouter-quota: model=google/lyria-3-clip-preview unavailable: http-502
fm-openrouter-quota: model=nvidia/nemotron-3-super-120b-a12b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=openrouter/free unavailable: cooldown until epoch 1787499238
fm-openrouter-quota: model=nvidia/nemotron-3-nano-30b-a3b:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-nano-12b-v2-vl:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: model=nvidia/nemotron-nano-9b-v2:free unavailable: account privacy gate: no allowed providers
fm-openrouter-quota: report models=410 free=22 probes=22 remembered=0 unprobed=0 skipped=12
```

The summary line reads `report models= free= probes= remembered= unprobed= skipped=`; this run started from an empty state file, so nothing was remembered yet and every price-zero model was probed.
Models with a remembered 404 or 403 verdict are logged with the suffix `(remembered verdict)` and are not probed.

## Bounded stdout

```json
{
  "schemaVersion": 1,
  "generatedAt": 1787497438,
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
      "google/gemma-4-26b-a4b-it:free"
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
      "id": "google/gemma-4-26b-a4b-it:free",
      "eligible": true,
      "reason": "live completion succeeded"
    },
    {
      "id": "dots-studio/dots-3-note-preview:free",
      "eligible": false,
      "reason": "account privacy gate: no allowed providers"
    },
    {
      "id": "google/gemma-4-31b-it:free",
      "eligible": false,
      "reason": "cooldown until epoch 1787499238"
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
      "reason": "cooldown until epoch 1787499238"
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
      "promptPerMillion": 0.05,
      "completionPerMillion": 0.15,
      "reason": "priced and not in cooldown"
    },
    {
      "id": "openai/gpt-oss-120b",
      "eligible": true,
      "promptPerMillion": 0.037,
      "completionPerMillion": 0.17,
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
- The catalog also carries 12 `~`-prefixed alias ids such as `~anthropic/claude-sonnet-latest`; their shape is outside `[A-Za-z0-9._:/-]`, so the reader names each on stderr as `skipped: unsupported id shape` and leaves them out of the output instead of dropping them silently.
- Exactly the models that returned a real completion were eligible free routes: `cohere/north-mini-code:free` and `google/gemma-4-26b-a4b-it:free`.
- HTTP 404 bodies containing `No allowed providers` are a stable account privacy gate and are skipped without a cooldown.
- HTTP 403 platform restriction is skipped without a cooldown (`thinkingmachines/inkling:free` and `thinkingmachines/inkling-small:free`).
- HTTP 429 is a per-model cooldown (`google/gemma-4-31b-it:free` and `openrouter/free` until epoch 1787499238, which is `generatedAt + 1800`).
- HTTP 502 from an upstream is reported for that run only (`google/lyria-3-pro-preview` and `google/lyria-3-clip-preview`) and is neither a cooldown nor a remembered verdict.
- Paid models are priced from the catalog and not probed: `openai/gpt-oss-20b` is $0.03/M prompt and $0.13/M completion.
- Per-million prices are rounded to six decimals, so `google/gemma-3-12b-it` publishes as `0.05` prompt and `openai/gpt-oss-120b` as `0.17` completion with no binary float noise.
- A per-token price of `-1` is OpenRouter's variable-pricing sentinel (`openrouter/auto`) and must not sort as a cheap paid route.
- `limit` null means this key has no spend cap.
- OpenRouter documents a 20 requests per minute limit on free models, which is why the reader paces probes 4 seconds apart by default (15 per minute) and remembers the stable 404 and 403 verdicts instead of re-spending probes on them.
- Key material did not appear in stdout, stderr, or any file under the isolated home, and the key was never written to a file during this run.
