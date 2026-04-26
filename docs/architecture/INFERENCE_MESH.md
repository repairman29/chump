---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Inference Mesh

How Chump distributes inference work across the Mac + Pixel (Mabel) + cloud cascade fleet.

## Current topology

```
Mac (M4 24 GB)
  └─ vLLM-MLX :8000   — primary, 14B 4-bit (or 7B on :8001)
  └─ Ollama :11434     — dev fallback
  └─ cascade slots 1–8 — cloud providers (Groq, Cerebras, Mistral, …)

Pixel (Mabel, Termux)
  └─ small local model — 1B–3B via Ollama (resource-constrained)
  └─ Mac web API probe  — health monitoring via /api/dashboard
```

The Mac is the primary inference node. Mabel (Pixel) can run small models locally but is primarily used for monitoring, watchlist rounds, and brief research tasks that don't require heavy inference.

## Provider cascade

When local inference is unavailable or slow, Chump falls through a priority-ordered stack of cloud providers. See [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) for the full provider table (~72k free RPD across 8 providers).

Key cascade env vars:
- `CHUMP_CASCADE_ENABLED=1` — enables fallthrough
- `CHUMP_CASCADE_STRATEGY=priority` — tries slots in priority order
- Per-slot: `CHUMP_PROVIDER_N_ENABLED`, `_BASE`, `_KEY`, `_MODEL`, `_RPM`, `_RPD`, `_PRIORITY`

## Fleet transport (current vs planned)

**Current (inbound SSH from Mac):** The Mac SSHes into Mabel's Termux to restart the bot and query status. This works on home networks but is awkward on strict networks and sleeping Macs.

**Planned (outbound push from Pixel):** A WebSocket or MQTT channel from Pixel → Mac over Tailscale so Mabel can push status and task hints without the Mac needing to initiate. See [FLEET_ROLES.md](FLEET_ROLES.md#fleet-transport-spike-design).

## Model splitting by capability tier

| Node | Model tier | Use case |
|------|-----------|---------|
| Mac (primary) | 14B 4-bit | Full Chump agent: tool use, code, research |
| Mac (fallback) | 7B 4-bit on :8001 | Lower memory, faster turns, reduced quality |
| Pixel (Mabel) | 1B–3B | Brief summaries, watchlist digests, low-latency checks |
| Cloud slots 1–8 | 70B-class | When local is down or overloaded; heartbeat overflow |

## Routing logic

1. **Primary:** `OPENAI_API_BASE` (vLLM-MLX :8000 or Ollama :11434)
2. **In-process:** If `CHUMP_INFERENCE_BACKEND=mistralrs` + `CHUMP_MISTRALRS_MODEL` set, bypasses HTTP entirely
3. **Cascade:** If primary fails (rate limit, OOM crash, circuit open), falls to next enabled slot
4. **Fallback URL:** `CHUMP_FALLBACK_API_BASE` — single explicit fallback before cascade kicks in

## Pi mesh (future)

The long-term vision is a Pi mesh where inference is split across multiple small nodes — 1B models on edge devices, 7B on mid-tier nodes, 14B on the Mac. This requires the inference mesh routing layer described in `docs/architecture/FLEET_ROLES.md` fleet transport spike. Not yet implemented.

## Latency characteristics

On a 24 GB M4 with 14B 4-bit:
- First token: ~1–3s (KV cache warm), ~3–8s (cold)
- Tokens/sec: ~25–40 tok/s with `VLLM_MAX_NUM_SEQS=1`
- Cognitive loop overhead: <1ms per tool call (EFE, belief updates, surprise tracking)

See [PERFORMANCE.md](PERFORMANCE.md) for detailed benchmarks.

## See Also

- [Fleet Roles](FLEET_ROLES.md)
- [Inference Profiles](INFERENCE_PROFILES.md)
- [Provider Cascade](PROVIDER_CASCADE.md)
- [Inference Stability](INFERENCE_STABILITY.md)
- [Android Companion](ANDROID_COMPANION.md)
