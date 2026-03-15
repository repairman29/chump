# Provider Cascade — Free-Tier Maximizer

Chump stacks 8 free cloud providers into a priority cascade, giving ~71,936 RPD of 70B-class inference at zero cost. A heartbeat at 5-minute intervals uses ~192 RPD — 0.27% of the total budget.

**Architecture:** Slot 0 = local (Ollama, unlimited). Slots 1–8 = cloud, tried in priority order. On rate limit, daily cap, circuit-open, or transient error, cascade falls to next slot. All slots exhausted → fallback to local.

---

## Provider Budget

| Slot | Provider | Model | RPM | RPD | Context | Privacy |
|------|----------|-------|-----|-----|---------|---------|
| 0 | Ollama (local) | qwen2.5:14b | ∞ | ∞ | 32k | None |
| 1 | **Groq** | llama-3.3-70b-versatile | 30 | 1,000 | 128k | Safe |
| 2 | **Cerebras** | llama-3.3-70b | 30 | 14,400 | 128k | Safe |
| 3 | **Mistral** | mistral-large-latest | 60 | ~86,400 | 128k | **Trains on free** |
| 4 | **OpenRouter** | llama-3.3-70b:free | 20 | 200 (1k w/ $10) | 128k | Model-dependent |
| 5 | **Google Gemini** | gemini-2.5-flash | 5 | 20 | 1M | **Trains on free** |
| 6 | **GitHub Models** | Meta-Llama-3.3-70B | 15 | 150 | 8k/4k | Microsoft DPA |
| 7 | **NVIDIA NIM** | llama-3.3-70b | 40 | — | varies | ToS unclear |
| 8 | **SambaNova** | llama-3.3-70b | — | — | 128k | Low ($5 credit) |

**Total conservative RPD:** ~71,936 across all slots. Heartbeat at 5m/8h = 192 RPD.

---

## 1. Sign up (once, ~20 min)

| Provider | URL | What to grab |
|----------|-----|-------------|
| Groq | https://console.groq.com | API key |
| Cerebras | https://cloud.cerebras.ai | API key |
| Mistral | https://console.mistral.ai/api-keys | API key (needs phone) |
| OpenRouter | https://openrouter.ai/keys | API key (+ optional $10 topup for 5× RPD) |
| Google AI Studio | https://aistudio.google.com/apikey | Gemini API key |
| GitHub Models | https://github.com/marketplace/models | Existing GitHub PAT |
| NVIDIA NIM | https://build.nvidia.com | API key (needs phone) |
| SambaNova | https://cloud.sambanova.ai | API key ($5 free credit) |

---

## 2. Configure .env

Enable cascade and add keys. Copy the relevant blocks from `.env.example`:

```bash
CHUMP_CASCADE_ENABLED=1
CHUMP_CASCADE_STRATEGY=priority
CHUMP_CASCADE_RPM_HEADROOM=80   # use 80% of each limit; prevents tripping the wire

# Slot 1: Groq — fastest, 70B, 1k RPD
CHUMP_PROVIDER_1_ENABLED=1
CHUMP_PROVIDER_1_NAME=groq
CHUMP_PROVIDER_1_BASE=https://api.groq.com/openai/v1
CHUMP_PROVIDER_1_KEY=gsk_YOUR_KEY
CHUMP_PROVIDER_1_MODEL=llama-3.3-70b-versatile
CHUMP_PROVIDER_1_RPM=24
CHUMP_PROVIDER_1_RPD=800
CHUMP_PROVIDER_1_TIER=cloud
CHUMP_PROVIDER_1_PRIORITY=10

# Slot 2: Cerebras — massive RPD (14.4k), fast
CHUMP_PROVIDER_2_ENABLED=1
CHUMP_PROVIDER_2_NAME=cerebras
CHUMP_PROVIDER_2_BASE=https://api.cerebras.ai/v1
CHUMP_PROVIDER_2_KEY=csk-YOUR_KEY
CHUMP_PROVIDER_2_MODEL=llama-3.3-70b
CHUMP_PROVIDER_2_RPM=24
CHUMP_PROVIDER_2_RPD=10000
CHUMP_PROVIDER_2_TIER=cloud
CHUMP_PROVIDER_2_PRIORITY=15

# ... add slots 3–8 from .env.example
```

See `.env.example` for the full 9-slot template (slots 3–8).

### RPD tracking

Each slot tracks calls-per-day in memory (resets every 24 h). Set `CHUMP_PROVIDER_{N}_RPD` to the provider's daily cap; the cascade skips that slot once `calls_today >= RPD * headroom%`. No RPD set = unlimited.

---

## 3. Verify

```bash
./scripts/check-providers.sh
```

Expected output with all slots wired:
```
=== Provider Cascade Health ===
  [0] local       ✓  (http://localhost:11434/v1)
  [1] groq        ✓  (https://api.groq.com/openai/v1)
  [2] cerebras    ✓  (https://api.cerebras.ai/v1)
  [3] mistral     ✓  (https://api.mistral.ai/v1)
  [4] openrouter  ✓  (https://openrouter.ai/api/v1)
  [5] gemini      ✓  (https://generativelanguage.googleapis.com/v1beta/openai)
  [6] github      ✓  (https://models.inference.ai.azure.com)
  [7] nvidia      ✓  (https://integrate.api.nvidia.com/v1)
  [8] sambanova   ✓  (https://api.sambanova.ai/v1)
```

---

## 4. Heartbeat intervals with cascade

With cloud cascade active, you are no longer throttled by local model memory. Recommended intervals:

| Mode | Interval | RPD used | Use case |
|------|----------|----------|---------|
| Always-on 8h | 5m | 192 | Standard autonomous operation |
| Burst sprint | 3m | 320 | Self-improve / cursor_improve sprint |
| Battery saver | 30m | 32 | Mac on battery / overnight |

Set in `.env` or shell: `HEARTBEAT_INTERVAL=5m HEARTBEAT_DURATION=8h ./scripts/heartbeat-learn.sh`

When cascade is enabled (`CHUMP_CASCADE_ENABLED=1`), `heartbeat-learn.sh` automatically uses the 5-minute default instead of the local-model 45m/60m throttle.

---

## 5. Priority routing (what runs where)

| Round type | Best slot | Reason |
|-----------|-----------|--------|
| work (PR, code) | Groq/Cerebras | Speed + quality; no training risk |
| cursor_improve | Groq/Cerebras | Self-modification needs precision |
| battle_qa | Groq/Cerebras | Accurate judgment |
| research | Mistral/OpenRouter | Big TPM; research is ok to train on |
| opportunity | Mistral/OpenRouter | Scan quality doesn't need fastest |
| discovery | Local or Cerebras | Exploratory; fallback fine |
| one-shot large doc | Gemini slot 5 | 1M context; reserve RPD for this |

The cascade handles this automatically via priority order. High-value rounds consume Groq/Cerebras first; Mistral/OpenRouter absorb heartbeat overflow.

---

## 6. Privacy rules

Slots 3 (Mistral) and 5 (Gemini) train on free-tier data. Do **not** send:
- Proprietary source code
- Personal data, credentials
- Anything from `cursor_improve` or `work` rounds

The cascade falls through these slots naturally for research/opportunity/discovery rounds, which is acceptable. Phase 2 will add `CHUMP_PROVIDER_{N}_PRIVACY=safe|caution|trains` env var for hard routing rules.

---

## 7. The $10 play

The single highest-ROI spend: top up OpenRouter with $10 once → RPD goes from 200 → 1,000 (5×). Everything else is signup-and-go at $0.

| Investment | Cost | Effect |
|-----------|------|--------|
| OpenRouter topup | $10 | 5× daily budget on slot 4 |
| SambaNova credit | $0 free | ~months of heartbeat usage |
| Scaleway | $0 | 1M free tokens for Llama 3.3 70B |
| Alibaba Cloud | $0 | 1M tokens per Qwen model |

---

## 8. Disabling cascade

```bash
CHUMP_CASCADE_ENABLED=0
```

Chump falls back to single-provider mode using `OPENAI_API_BASE` / `OPENAI_API_KEY` / `OPENAI_MODEL`.
