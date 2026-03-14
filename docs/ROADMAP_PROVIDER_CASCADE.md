# Provider Cascade — Multi-Provider Plan

Upgrade Chump from single-provider (Ollama local) to a cascading multi-provider architecture. Local stays primary. Cloud providers fill the model quality gap for tasks that need it.

---

## Providers

Three providers, one optional. One signup each, done in under 5 minutes total.

| Slot | Provider | Why This One | Free Tier | Model | RPM | Context | Signup |
|------|----------|-------------|-----------|-------|-----|---------|--------|
| 0 | **Ollama (local)** | Always available, zero cost, zero latency | Unlimited | qwen2.5:14b | ∞ | 2k-32k | — |
| 1 | **Groq** | Fastest cloud inference (LPU). Best for interactive Discord. | 30 RPM, 14.4k TPM | llama-3.3-70b-versatile | 30 | 128k | https://console.groq.com |
| 2 | **OpenRouter** | Aggregator. One key, many free models. Catches overflow when Groq is rate-limited. | Varies by model | meta-llama/llama-3.3-70b-instruct:free | ~20 | 128k | https://openrouter.ai |
| 3 | **Google Gemini** *(optional)* | 1M token context. Use for long code review, large file analysis. | 15 RPM | gemini-2.0-flash | 15 | 1M | https://aistudio.google.com/apikey |

> Free tiers change without warning. The cascade degrades gracefully — if a cloud provider dies, circuit breaker trips and Chump falls back to local.

---

## Env Vars

See [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) for setup. Summary: `CHUMP_CASCADE_ENABLED=1`, then per-slot `CHUMP_PROVIDER_{N}_ENABLED`, `_BASE`, `_KEY`, `_MODEL`, `_RPM`, `_TIER`, `_PRIORITY`. Slot 0 uses existing `OPENAI_*` vars.

---

## Implementation

- **src/provider_cascade.rs:** ProviderCascade, from_env(), Provider impl, priority routing, per-slot rate limiter, circuit reuse from local_openai.
- **src/local_openai.rs:** Export `record_circuit_failure(base)`, `is_circuit_open(base)`, `is_transient_error(err)` for cascade.
- **discord.rs / main.rs:** Use `provider_cascade::build_provider()` when `CHUMP_CASCADE_ENABLED=1`.

---

## Backward Compatibility

- `CHUMP_CASCADE_ENABLED=0` (or unset) → existing single-provider behavior.
- `CHUMP_CASCADE_ENABLED=1` → cascade mode; slot 0 from `OPENAI_*`.

---

## Future

- TaskAware / RoundRobin strategies; slots 4–9; cost tracking; TPM tracking; provider quality scoring; warm probe.
