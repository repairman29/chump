---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Inference Stability & Failover Recovery

Operational runbook when a local model server (`Ollama` on `:11434`, `vLLM` on `:8000`, `llama-server` on `:8080`) or upstream cloud API experiences timeouts, OOM crashes, or HTTP `429` rate limits.

---

## 1. Fast Triage Checklist

1. **Probe the model endpoint directly:**
   ```bash
   # Ollama default:
   curl -fsS -m 5 http://127.0.0.1:11434/v1/models
   # vLLM / custom OPENAI_API_BASE:
   curl -fsS -m 5 "${OPENAI_API_BASE%/v1}/v1/models"
   ```
   If `curl` fails or times out, restart the model server first—Chump's HTTP client will automatically reconnect once `/v1/models` is healthy.
2. **Inspect Chump's live view of the stack:**
   ```bash
   curl -fsS http://127.0.0.1:3847/api/stack-status
   curl -fsS http://127.0.0.1:3847/api/cascade-status
   ```
   Check `inference.models_reachable`, `inference.error`, and per-slot `circuit_state`.
3. **Validate configuration schema:**
   ```bash
   chump config validate
   ```

---

## 2. Preventing Local OOM & Swap Thrashing

Symptoms of memory exhaustion:
- Local replies jump from `3s` to `>90s` while disk swap climbs.
- `vLLM` or `Ollama` exits unexpectedly right after loading weights.
- Parallel `cargo test` + LLM inference wedges an 8–16 GB laptop.

Mitigations:
- **Step down one quantization or parameter tier:** e.g. `qwen2.5-coder:14b` → `qwen2.5-coder:7b` (`Q4_K_M`). See [Hardware & RAM Profiles](INFERENCE_PROFILES.md).
- **Bound server sequence parallelism:** set `OLLAMA_NUM_PARALLEL=1` (or `vLLM` `--max-num-seqs 1`) on `≤ 16 GB` machines.
- **Cap Rust compile concurrency:** set `CARGO_BUILD_JOBS = 2` under `[settings]` in `~/.chump/config.toml` so compiler linker spikes never compete with GPU/unified memory.

---

## 3. Built-In HTTP Retry & Circuit-Breaker Behavior (`local_openai.rs`)

Chump's OpenAI-compatible client wraps every completion request in deterministic resilience guards:

| Mechanism | Default | Tuning Knob | Behavior |
|-----------|---------|-------------|----------|
| **Transient Retries** | `0s, 1s, 2s, 5s` | `CHUMP_LLM_RETRY_DELAYS_MS` | Retries HTTP `429`, `502`, `503`, `504`, and transient stream resets; adds one `15s` warm-up retry if the server reports `"model loading"`. |
| **Circuit Breaker** | `3` failures → `30s` open | `CHUMP_CIRCUIT_FAILURE_THRESHOLD`, `CHUMP_CIRCUIT_COOLDOWN_SECS` | Opens the slot circuit so subsequent turns fail over immediately to the next `[[providers]]` slot instead of stalling. |
| **Request Timeout** | `300s` (`45s` connect) | `CHUMP_MODEL_REQUEST_TIMEOUT_SECS`, `CHUMP_OPENAI_CONNECT_TIMEOUT_SECS` | Prevents hung TCP sockets from wedging background workers. |
| **Fallback Base URL** | _(optional)_ | `CHUMP_FALLBACK_API_BASE` | Secondary OpenAI-compatible endpoint tried automatically when the primary base exhausts retries. |

---

## 4. Web Cockpit Degraded-Mode Signals

When `chump --web` detects an inference issue, the cockpit surfaces actionable diagnostics immediately without requiring log inspection:

| Condition | Cockpit Signal | Recommended Action |
|-----------|----------------|--------------------|
| `OPENAI_API_BASE` unset and no cascade slots configured | Setup banner in **Providers** view | Run `chump config init` and follow [5-Minute Clean Setup](../process/EXTERNAL_GOLDEN_PATH.md) |
| Local `/v1/models` unreachable (`models_reachable: false`) | Warning badge + `inference.error` detail | Start `ollama serve` / `vLLM`, or enable a cloud fallback slot in `~/.chump/config.toml` |
| Primary backend is `mistralrs` (`§2b`) | `probe: "mistralrs_in_process"` | Normal for in-process `mistral.rs`; see [Hardware & RAM Profiles](INFERENCE_PROFILES.md) |
| Upstream `401` / `429` / circuit open during chat | SSE `turn_error` with remediation hint | Check API key env var, raise `CHUMP_CASCADE_RPM_HEADROOM` safety margin, or add a local fallback slot |

---

## 5. Recovery Drill (Verifying Zero-Restart Failover)

To verify your setup recovers cleanly from a local server restart:

1. Start `ollama serve` and `chump --web --port 3847`; confirm `curl -fsS http://127.0.0.1:3847/api/health` returns `status: "ok"`.
2. Stop `ollama` (`pkill -f "ollama serve"` or stop the service) and trigger one prompt—confirm Chump either fails over to your cloud slot or returns a clear, bounded error (no infinite hang).
3. Restart `ollama serve` and send another prompt—confirm normal responses resume automatically without restarting `chump` or editing `config.toml`.

---

## Related Guides

- [Hardware & RAM Profiles](INFERENCE_PROFILES.md)
- [Provider Cascade & OAuth](../architecture/PROVIDER_CASCADE.md)
- [Daemon & Service Operations](OPERATIONS.md)
