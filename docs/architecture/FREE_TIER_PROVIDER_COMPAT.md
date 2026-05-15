# Free-tier provider compatibility matrix

Empirical findings from dispatch testing across free-tier OpenAI-compatible
providers. Last verified 2026-05-08.

Canonical rate data: [`docs/dispatch/provider_rates.yaml`](../dispatch/provider_rates.yaml).

## Provider matrix

| Provider | Model | Class | RPM | RPD | Context | Privacy | Tool calls | Status |
|----------|-------|-------|----:|----:|--------:|---------|------------|--------|
| Cerebras | qwen-3-235b-a22b | sonnet | 30 | 14400 | 128K | safe | native | active |
| Groq | llama-3.3-70b | sonnet | 30 | 1000 | 128K | safe | native | active |
| NVIDIA NIM | meta/llama-3.3-70b | sonnet | 32 | 5000 | 128K | caution | native | active |
| Hyperbolic | Qwen3-Coder-480B | sonnet | 60 | 2000 | 128K | caution | native | active |
| OpenRouter | qwen3-coder:free | haiku | 16 | 800 | 128K | caution | partial | active |
| GitHub Models | Llama-3.3-70B | haiku | 12 | 120 | 8K | safe | native | active |
| Gemini 2.5 Flash | gemini-2.5-flash | sonnet | 10 | 1500 | 1M | trains | native | active |
| Gemini 2.0 Flash Lite | gemini-2.0-flash-lite | haiku | 15 | 1500 | 1M | trains | native | deprecated? |
| Gemini 2.5 Pro | gemini-2.5-pro | opus | 5 | 50 | 2M | trains | native | active |
| Together.ai | Llama-3.3-70B-Turbo | haiku | 60 | 2000 | 128K | safe | native | credit exhausted |

## Model-class routing

Gaps route to model tiers via `docs/dispatch/routing.yaml`:

- **haiku** (xs tasks): GitHub Models, OpenRouter, Gemini 2.0 Flash Lite
- **sonnet** (s/m tasks): Cerebras, Groq, NVIDIA, Hyperbolic, Gemini 2.5 Flash
- **opus** (verify/decompose): Gemini 2.5 Pro only (50 RPD — reserve carefully)

The cascade sorts matching-class slots first, then falls back to any available
slot. Set `CHUMP_PREFERRED_MODEL_CLASS` to bias routing.

## Behavioral quirks by model family

### Llama 3.3 70B (Groq, NVIDIA, GitHub, Together)

- **Multi-tool batching**: sometimes emits 2-3 tool_calls in one response. The
  dispatch loop handles this but some tools have ordering dependencies (read
  before write). See EFFECTIVE-004.
- **write_file destruction**: tends to overwrite entire files when asked to edit
  a few lines. Mitigation: prompt for `patch_file` / `Edit` instead of
  `write_file` / `Write`. See EFFECTIVE-005.
- **Plan-doc generation**: frequently creates unsolicited markdown planning docs
  instead of editing code. Mitigation: system prompt guard "NEVER write
  documentation files unless explicitly asked."

### Qwen 3 / Qwen3-Coder (Cerebras, Hyperbolic, OpenRouter)

- **XML tool tags**: some Qwen variants emit `<tool_call>...</tool_call>` XML
  instead of OpenAI-native `tool_calls` in the response. The
  `LocalOpenAIProvider` doesn't parse these. See EFFECTIVE-003 for the adapter.
- **Thinking tokens**: Qwen3 may emit `<think>...</think>` blocks before the
  tool call. The cascade strips these but they consume output tokens.
- **Strongest free-tier reasoning**: Qwen3-Coder-480B (Hyperbolic) and
  qwen-3-235b (Cerebras) are the most capable free models for complex tasks.

### Gemini 2.x (Google)

- **OpenAI compatibility**: works via `generativelanguage.googleapis.com/v1beta/openai`
  with `LocalOpenAIProvider` — no special adapter needed.
- **1.5 models gone**: as of 2026-05-08, Gemini 1.5 Flash and 1.5 Pro return
  404. Only 2.0+ models available.
- **Privacy**: free-tier data may be used for training. Flip
  `CHUMP_ROUND_PRIVACY=safe` to exclude Gemini slots when processing
  third-party content.
- **Gemini 2.0 Flash Lite**: may be deprecated (retired date 2026-03-03 per
  Google docs). Replacement: gemini-2.5-flash-lite when available.

## Known failure modes

| Failure | Provider(s) | Symptom | Mitigation |
|---------|------------|---------|------------|
| 429 rate limit | All | HTTP 429, cascade burns through slots | Per-slot cooldown (INFRA-776), Retry-After parsing |
| 402 credit exhausted | Hyperbolic, Together | HTTP 402 | Disable slot (`enabled: false`), treat as rate limit |
| 413 prompt too large | Groq (20K TPM) | Request rejected | Cascade skips, falls to next slot |
| XML tool calls | Qwen3 variants | Tool loop stalls | EFFECTIVE-003 adapter (not yet shipped) |
| File destruction | Llama 3.3 70B | Entire file overwritten | Prompt for patch_file, EFFECTIVE-005 |
| Planning instead of coding | All free models | Creates .md files | System prompt guard |
| Context overflow | GitHub Models (8K) | Truncated or refused | Cascade skips low-context slots for large prompts |

## Provider selection decision tree

```
Is the task xs (trivial)?
  → haiku tier: Gemini 2.0 Flash Lite > GitHub Models > OpenRouter
Is the task s/m (standard)?
  → sonnet tier: Cerebras > Groq > NVIDIA > Hyperbolic > Gemini 2.5 Flash
Is the task verification or decomposition?
  → opus tier: Gemini 2.5 Pro (50 RPD budget)
Is privacy required (third-party content)?
  → safe only: Cerebras > Groq > GitHub Models
  → exclude: Gemini (trains), NVIDIA/Hyperbolic/OpenRouter (caution)
Is the prompt >20K tokens?
  → exclude Groq (TPM limit), GitHub Models (8K context)
  → prefer Gemini (1M+ context) or Cerebras/NVIDIA (128K)
```

## Related gaps

- EFFECTIVE-001: end-to-end free-tier ship test
- EFFECTIVE-002: free-tier provider rotation within a session
- EFFECTIVE-003: XML-to-tool-call adapter for Qwen models
- EFFECTIVE-004: sequential tool execution for multi-tool responses
- INFRA-775: wire provider_rates.yaml into ProviderCascade::from_env()
- INFRA-776: cascade 429 cooldown intelligence
