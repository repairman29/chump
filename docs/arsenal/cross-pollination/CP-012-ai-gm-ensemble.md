# CP-012: Vendor ai-gm-service multi-model ensemble → Chump provider chain

**Target:** Chump's Neocortex-tier LLM dispatcher (paired with CP-011 bicameral router + CP-001 neural-farm)
**Arsenal match:** `repairman29/ai-gm-service` at `src/services/aiGMMultiModelEnsembleService.js` + `src/services/togetherAIService.js` + `src/services/npcAgentCostOptimized.js` + `src/aiGMAPI.js` (rate-limit retry helper)
**Recommended route:** Vendoring (Rust port, cite source)
**Status:** proposed (Harvester v0, 2026-05-23, INFRA-1844)
**Source SHA:** `ae59750d39cef0daa15a88131db9de914dfa0b4b` (ai-gm-service @ main, 2026-05-23)

## The Target

Chump needs a **deterministic provider-chain executor** — one async call site that walks an
ordered list of providers (Anthropic → OpenAI → Together.ai → Ollama → neural-farm) and
returns the first usable completion. Today the worker has only a single fallback between
API-key and OAUTH (INFRA-622); when Anthropic rate-limits mid-PR, the fleet wedges; when
the OAUTH token expires on a plane, no local inference takes over. ai-gm-service has
shipped the chain primitive — we vendor the design, port to Rust, make it the Neocortex-tier
dispatcher for CP-011.

## The Arsenal Match — ai-gm ensemble

### Fallback chain construction

The chain is **declarative**: a `modelPriority` array iterated in order, with the first
provider that has a valid API key winning the call. From
`aiGMMultiModelEnsembleService.js:85-93`:

```js
// RESEARCH-BASED: Model priority order — Fine-tuned Mistral first!
this.modelPriority = [
  { provider: "mistral", model: "ft:mistral-small-latest:.../smuggler-narrator:..." },
  { provider: "openai",  model: "gpt-4o-mini" },
  { provider: "together", model: "meta-llama/Llama-3-70b-chat-hf" },
];
```

Note: the ensemble service runs all three in **parallel** for best-of-N selection (CSAT
prediction), not sequential first-success. The sequential first-success pattern we want
lives in `npcAgentCostOptimized.js:178-195`:

```js
for (const modelConfig of this.modelTier) {
  try {
    const apiKey = await getApiKey(userId, modelConfig.provider);
    if (apiKey && apiKey.length > 20) { return modelConfig; }
  } catch (error) {
    continue;  // try next
  }
}
```

That file also shows the **tier-stratified** variant — four cost tiers (`ultra_cheap` →
`cheap` → `medium` → `premium`), each its own ordered chain; fall through to a hard-coded
OpenAI default if all fail. We port the sequential iteration + tier stratification; the
parallel-best-of-N ensemble is out of scope for CP-012 (separate primitive, future brief).

Per-provider config in `togetherAIService.js`: `baseURL = 'https://api.together.xyz/v1'`,
default model `Qwen/Qwen2.5-72B-Instruct-Turbo`, named aliases
`moonshotai/Kimi-K2-Instruct-0905` (256K context) and a fine-tuned variant; key from
`TOGETHER_API_KEY`.

### Per-provider config

| Provider | Env var | Base URL | Default model |
|---|---|---|---|
| `anthropic` | `ANTHROPIC_API_KEY` | (SDK) | `claude-opus-4-5-20251101` |
| `openai` | `OPENAI_API_KEY` | (SDK) | `gpt-4o` / `gpt-4o-mini` |
| `mistral` | `MISTRAL_API_KEY` | (SDK) | `mistral-large-latest` |
| `together` | `TOGETHER_API_KEY` | `https://api.together.xyz/v1` | `Qwen/Qwen2.5-72B-Instruct-Turbo` (or `moonshotai/Kimi-K2-Instruct-0905` for long-context) |
| `gemini` | `GEMINI_API_KEY` / `GOOGLE_AI_API_KEY` / `GOOGLE_API_KEY` | (SDK) | `gemini-2.0-flash-exp` |
| `groq` | `GROQ_API_KEY` | (SDK) | `llama-3.1-8b-instant` |
| `ollama` | (none, local) | `http://localhost:11434/v1` | configurable |
| `neural-farm` (CP-001) | (none, local) | `http://localhost:<port>/v1` | configurable |

**Quality-vs-cost heuristic** (from `npcAgentCostOptimized.js` cost tiers): cheap models
serve background traffic, premium reserved for "critical" calls. Translates directly to
Chump's bicameral split — Reflexive (low-stakes, fast, local) vs. Neocortex (high-stakes,
expensive, remote). The ProviderChain is configured per tier; CP-011's router decides
which tier to invoke.

## Error-class handling

The JS code has two **separate** mechanisms that combine: rate-limit retry on the same
provider (`aiGMAPI.js:268-283`) and fallthrough to the next provider on auth/missing-key
failures (the `for...catch...continue` loop in `npcAgentCostOptimized.js`). The Together.ai
client itself never retries — it throws on any non-200 (`togetherAIService.js:370-374`)
and lets the caller's chain handle dispatch. We collapse these into a single Rust state
machine:

| Error class | Action | Backoff |
|---|---|---|
| **401 / 403 auth** (invalid key) | immediate fallback to next provider | — |
| **404 model-not-found** | immediate fallback to next provider | — |
| **429 rate-limit** (`Retry-After` ≤ ceiling) | retry same provider up to 3 times | exponential: 2s → 4s → 8s; cap 30s |
| **429 rate-limit** (`Retry-After` > ceiling, or 3 retries exhausted) | fallback to next provider | — |
| **5xx transient** (502/503/504) | retry same provider up to 2 times | linear 1s, 2s |
| **5xx persistent** (after retries) | fallback to next provider | — |
| **network / timeout** (>30s) | fallback to next provider | — |
| **content policy refusal** (200 but empty/refused) | fallback to next provider | — |
| **invalid prompt** (4xx other than 401/404/429) | **fatal** — return `ChainError::InvalidPrompt` to caller | — |
| **all providers exhausted** | **fatal** — return `ChainError::AllProvidersFailed { attempts }` | — |

The JS `rateLimitRetry` (`aiGMAPI.js:268`) sniffs error messages for the strings
`'429'` or `'rate limit'`. The Rust port matches on `reqwest::StatusCode` and parses
`Retry-After` headers, which is materially better.

**Content-policy refusal** (200 OK but empty/refused completion) is a new category — the JS
catches it lazily via length checks downstream (`unifiedDialogueService.js:144`). The Rust
port treats it as a first-class fallback trigger inside `execute()`.

## Rate-limit handling

The JS has no per-provider sliding window — each 429 triggers local exponential backoff
then fallthrough. Chump's `chump_gh` sliding-window throttle is the better pattern. The
Rust port adds:

- **Per-provider sliding window** keyed by `(provider, env_var)`, default 60 rpm, override
  via `CHUMP_PROVIDER_<PROVIDER>_MAX_RPM=N`.
- **Fleet-shared budget** via the SQLite counter `chump_gh` already uses in `.chump/state.db`,
  so N workers don't collectively burn one provider's bucket.
- **Predictive throttle**: when a window is ≥90% full, skip the provider on the next call
  (no round-trip needed) and emit `kind=provider_predictive_skip`.
- **Per-call criticality** (`CHUMP_PROVIDER_CALL_CRITICALITY=background` vs default
  `critical`); background calls yield when remaining_quota < 10%.

## Rust port — `src/inference_provider.rs`

### ProviderChain struct

```rust
// Vendored from repairman29/ai-gm-service at commit
// ae59750d39cef0daa15a88131db9de914dfa0b4b
// (original: src/services/aiGMMultiModelEnsembleService.js, CP-012).

pub struct ProviderChain {
    providers: Vec<Provider>,           // ordered, lowest-cost first
    retry_policy: RetryPolicy,
    rate_limit_windows: RateLimitWindows,  // per-provider sliding window
    metrics_sink: AmbientEmitter,
    criticality: Criticality,             // Critical | Background
}

pub struct RetryPolicy {
    rate_limit_max_retries: u8,    // default 3
    transient_max_retries:  u8,    // default 2
    rate_limit_backoff:     BackoffSchedule,  // Exponential { base: 2s, cap: 30s }
    transient_backoff:      BackoffSchedule,  // Linear { step: 1s, max: 2s }
    request_timeout:        Duration,         // default 30s
}
```

### Provider enum

```rust
pub enum Provider {
    Anthropic    { model: String, api_key_env: String },  // default "ANTHROPIC_API_KEY"
    OpenAI       { model: String, api_key_env: String },
    Together     { model: String, api_key_env: String, base_url: String },
    Mistral      { model: String, api_key_env: String },
    Gemini       { model: String, api_key_envs: Vec<String> },  // multi-env lookup
    Groq         { model: String, api_key_env: String },
    Ollama       { model: String, base_url: String },           // local, no key
    NeuralFarm   { model: String, base_url: String },           // CP-001, no key
}
```

### `execute()` signature

```rust
impl ProviderChain {
    pub async fn execute(&self, prompt: Prompt) -> Result<Completion, ChainError> {
        for (idx, provider) in self.providers.iter().enumerate() {
            match self.try_provider(provider, &prompt).await {
                Ok(c) => return Ok(c),
                Err(e) if e.is_fatal() => return Err(e.into()),     // invalid prompt
                Err(e) => {
                    self.emit_fallback(idx, provider, &e);
                    continue;
                }
            }
        }
        Err(ChainError::AllProvidersFailed { attempts: self.providers.len() })
    }
}

pub enum ChainError {
    InvalidPrompt(String),
    AllProvidersFailed { attempts: usize },
    Config(String),
}
```

`try_provider` internally handles per-provider retries (rate-limit + transient) before
returning a fallback-class error.

### Env config

```bash
# Chain order, comma-separated. Empty/unset → built-in default.
CHUMP_PROVIDER_CHAIN=anthropic,openai,together,ollama,neural-farm

# Per-provider model override (otherwise use Provider::default_model())
CHUMP_PROVIDER_ANTHROPIC_MODEL=claude-opus-4-5-20251101
CHUMP_PROVIDER_TOGETHER_MODEL=moonshotai/Kimi-K2-Instruct-0905
CHUMP_PROVIDER_OLLAMA_BASE_URL=http://localhost:11434/v1
CHUMP_PROVIDER_NEURAL_FARM_BASE_URL=http://localhost:8080/v1

# Per-provider rate-limit override (req/min)
CHUMP_PROVIDER_ANTHROPIC_MAX_RPM=120

# Call criticality (per-call, set by caller; default critical)
CHUMP_PROVIDER_CALL_CRITICALITY=background
```

Parsing: `CHUMP_PROVIDER_CHAIN` is split on comma, whitespace-trimmed, lowercased; unknown
provider names emit `kind=provider_chain_unknown` and are dropped (not fatal). Empty chain
falls back to compile-time default `[anthropic, openai, ollama]`.

## Ambient event spec

Register in `docs/observability/EVENT_REGISTRY.yaml` (this brief does **not** edit the
registry — that's a code change in the implementing PR):

```yaml
- kind: provider_fallback
  description: ProviderChain advanced from one provider to the next after non-fatal failure
  fields:
    from_provider: string    # e.g. "anthropic"
    to_provider:   string    # e.g. "openai"
    reason:        string    # "rate_limit_exhausted" | "auth_failed" | "5xx_persistent" | "timeout" | "content_refusal" | "model_not_found"
    attempt_count: integer   # 1-indexed position in chain (1 = first provider)
    elapsed_ms:    integer   # time spent on from_provider before giving up
  emitters: [src/inference_provider.rs]
```

Companion events (subset of same registration PR):

- `kind=provider_predictive_skip` — `{provider, remaining_quota_pct, reason="rate_limit_window_near_full"}`
- `kind=provider_chain_exhausted` — `{providers_tried: [...], total_elapsed_ms}` (paired with `ChainError::AllProvidersFailed`)
- `kind=provider_chain_unknown` — `{name}` (config-parse warning)

## Smoke test spec — `scripts/ci/test-provider-chain.sh`

Depends on **CP-009 mock-services**. Each scenario sets `CHUMP_PROVIDER_CHAIN=mock_a,mock_b`
and points each provider's base URL at the mock simulating the failure mode.

| Scenario | Mock behavior | Expected | Expected ambient |
|---|---|---|---|
| Happy path | mock_a → 200 OK | `Ok` from a | none |
| Auth fail | mock_a → 401 | `Ok` from b | `provider_fallback{reason=auth_failed}` |
| 429 retry-then-recover | mock_a → 429 (Retry-After: 1) ×2 then 200 | `Ok` from a | none |
| 429 retry-exhausted | mock_a → 429 (Retry-After: 600) | `Ok` from b | `provider_fallback{reason=rate_limit_exhausted}` |
| 5xx persistent | mock_a → 503 always | `Ok` from b | `provider_fallback{reason=5xx_persistent}` |
| Timeout | mock_a → sleep 60s | `Ok` from b | `provider_fallback{reason=timeout}` |
| Content refusal | mock_a → 200 empty | `Ok` from b | `provider_fallback{reason=content_refusal}` |
| Invalid prompt | mock_a → 400 (not 401/404/429) | `Err(InvalidPrompt)` | none (fatal) |
| Chain exhausted | every mock → 503 | `Err(AllProvidersFailed)` | one `provider_fallback` per hop + `provider_chain_exhausted` |
| Predictive skip | mock_a window at 95% | `Ok` from b, no round-trip to a | `provider_predictive_skip{provider=mock_a}` |

Asserts: (1) `Result` matches, (2) `ambient.jsonl` tail has expected event sequence in
order, (3) wall-clock ≤ retry-policy budget.

## Convergence with CP-011 (bicameral router)

CP-011 splits inference into **Reflexive** (local, fast, cheap) and **Neocortex** (remote,
slow, expensive) tiers; the router picks the tier. ProviderChain is the executor *within*
a tier:

- `ReflexiveChain` = `ProviderChain([Ollama, NeuralFarm, Groq])`
- `NeocortexChain` = `ProviderChain([Anthropic, OpenAI, Together])`
- `EmergencyChain` = `ProviderChain([Ollama])` (offline fallback)

CP-011 is `enum Tier { Reflexive, Neocortex, Emergency }` + dispatch fn; each arm holds a
ProviderChain. Tier-selection (CP-011) and intra-tier resilience (CP-012) stay separable.
A `ChainError::AllProvidersFailed` from Neocortex is observable to CP-011, which can then
escalate to Emergency.

## Vendoring lineage

Source comment at top of `src/inference_provider.rs`:

```rust
// Vendored from repairman29/ai-gm-service at commit
// ae59750d39cef0daa15a88131db9de914dfa0b4b (2026-05-23).
//
// Original source:
//   src/services/aiGMMultiModelEnsembleService.js (model priority + dispatch)
//   src/services/togetherAIService.js              (Together.ai client shape)
//   src/services/npcAgentCostOptimized.js          (tier + iteration pattern)
//   src/aiGMAPI.js:268-283                         (rate-limit retry helper)
//
// Cross-pollination brief: docs/arsenal/cross-pollination/CP-012-ai-gm-ensemble.md
// INFRA-1844 (implementing gap).
```

Re-harvest cadence: review at next major ai-gm-service release tag, or every 90 days,
whichever first.

## Lineage / Risk

- **ai-gm-service is a personal project**, no semver tags; treat the harvest as design
  lineage, not API contract. Rust port owns its types.
- **Together.ai model drift** — Together deprecates models on short notice. Mitigation:
  model strings are env-var overrideable, not compile-time constants.
- **Provider-shape divergence** — Anthropic SDK and OpenAI SDK have different call
  surfaces. Rust port uses a thin trait `ProviderClient::call(&Prompt) -> Result<Completion, ProviderError>`
  with one impl per provider; no shape translation in the chain itself.
- **Layering with INFRA-622 auth fallback** — auth fallback (API-key ⇄ OAUTH) operates
  *within* `Provider::Anthropic`; ProviderChain operates *across* providers. Auth fallback
  is internal to `Provider::Anthropic::call`; ProviderChain is unaware.
- **CP-001 neural-farm dormancy** (last push 2026-02-28) — ProviderChain treats
  `NeuralFarm` as optional; unreachable base URL hops to next provider like any
  503-persistent.

## What this brief does *not* do

It does not write Rust code, it does not edit `EVENT_REGISTRY.yaml`, it does not modify
`src/`, and it does not commit. It specifies the contract. Execution lives in INFRA-1844.
