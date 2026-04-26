---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Provider Cascade — Free-Tier Maximizer

Chump stacks 8 free cloud providers into a priority cascade, giving ~71,936 RPD of 70B-class inference at zero cost. A heartbeat at 5-minute intervals uses ~192 RPD — 0.27% of the total budget.

**Architecture:** Slot 0 = local (Ollama, unlimited). Slots 1–9+ = cloud, tried in priority order. On rate limit, daily cap, circuit-open, or transient error, cascade falls to next slot. All slots exhausted → fallback to local. **All configured providers stay wired;** the cascade uses them by need: priority order, privacy (safe vs trains), rate limits, and optional large-context preference.

### In-process mistral.rs vs cascade

When the binary is built with **`mistralrs-infer`** or **`mistralrs-metal`** and **`CHUMP_INFERENCE_BACKEND=mistralrs`** with a non-empty **`CHUMP_MISTRALRS_MODEL`**, the **primary completion path** is **in-process mistral.rs**, not the HTTP cascade — even with **`CHUMP_CASCADE_ENABLED=1`** and **`OPENAI_API_BASE`** / provider slots configured. To drive completions through the cascade again, clear mistral backend selection (unset those vars or stop using the mistralrs feature build). Details: [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b. **Shell note:** with mistral primary, **`run-web.sh`** / **`keep-chump-online.sh`** no longer auto-start vLLM-MLX when **`OPENAI_API_BASE`** still points at :8000/:8001 — see **`scripts/setup/inference-primary-mistralrs.sh`**.

---

## Provider Budget

| Slot | Provider | Model | RPM | RPD | Context | Privacy |
|------|----------|-------|-----|-----|---------|---------|
| 0 | Ollama (local) | qwen2.5:14b | ∞ | ∞ | 32k | None |
| 1 | **Groq** | llama-3.3-70b-versatile | 30 | 1,000 | 128k | Safe |
| 2 | **Cerebras** | llama-3.3-70b / qwen-3-235b | 30 | 14,400 | 128k / 65k | Safe |
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
| Cerebras | https://cloud.cerebras.ai | API key (see Limits — Personal for RPM/RPD) |
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

# Slot 2: Cerebras — Limits (Personal): 30 RPM, 14,400 RPD; 128k or 65k context
CHUMP_PROVIDER_2_ENABLED=1
CHUMP_PROVIDER_2_NAME=cerebras
CHUMP_PROVIDER_2_BASE=https://api.cerebras.ai/v1
CHUMP_PROVIDER_2_KEY=csk-YOUR_KEY
CHUMP_PROVIDER_2_MODEL=llama-3.3-70b
CHUMP_PROVIDER_2_RPM=30
CHUMP_PROVIDER_2_RPD=14400
# CHUMP_PROVIDER_2_CONTEXT_K=128
CHUMP_PROVIDER_2_TIER=cloud
CHUMP_PROVIDER_2_PRIORITY=15

# ... add slots 3–9 from .env.example (Gemini slot 5: set CONTEXT_K=1000 for 1M routing)
```

See `.env.example` for the full 9-slot template (slots 3–8).

### 401 / models permission

- **401 Unauthorized** or "models permission required": API key is invalid or missing the required scope. The cascade falls through to the next slot automatically.
- **Web chat returns 401 / "models permission required":** Same cause; the PWA shows a hint. Run `./scripts/ci/check-providers.sh` from the Chump repo to see which slot returns 401.
- **GitHub Models (slot 6):** PAT must have `models:read` scope. Fine-grained PATs need it explicitly; coarse-grained tokens work without changes. See [GitHub Changelog](https://github.blog/changelog/2025-05-15-modelsread-now-required-for-github-models-access).
- Run `./scripts/ci/check-providers.sh` to see which slots return 401 and get remediation hints.

### Cerebras limits (Personal tier)

From Cerebras cloud **Limits — Personal** (see Analytics / Limits in the console):

| Quota | Limit |
|-------|--------|
| **Requests** | 30/min, 900/hour, 14,400/day |
| **Tokens** (e.g. qwen-3-235b) | 30,000/min, 1,000,000/hour, 1,000,000/day |
| **Context** | 8,192 (llama3.1-8b); 65,536 (qwen-3-235b-a22b-instruct-2507, Preview) |

Set `CHUMP_PROVIDER_2_RPM=30` and `CHUMP_PROVIDER_2_RPD=14400` to match. Optional: use `qwen-3-235b-a22b-instruct-2507` for 65k context (Preview). Note: limits may be enforced over shorter intervals (e.g. 30 RPM as ~1 request every 2 seconds); `CHUMP_CASCADE_RPM_HEADROOM=80` keeps usage under the wire. For routing by context size, set `CHUMP_PROVIDER_2_CONTEXT_K=65` (qwen-3-235b) or `128` (llama-3.3-70b) so `CHUMP_PREFER_LARGE_CONTEXT=1` can order slots correctly.

### Context window and routing by need

Context can look small if no provider has `CONTEXT_K` set — the cascade then can't prefer large-context slots. Set **context in thousands** so routing and trim logic use the right window:

| Env var | Purpose |
|--------|--------|
| `CHUMP_PROVIDER_{N}_CONTEXT_K` | Context size in thousands (e.g. `128` = 128k, `1000` = 1M). Used when `CHUMP_PREFER_LARGE_CONTEXT=1` to prefer larger-context slots; also sets `CHUMP_CURRENT_SLOT_CONTEXT_K` for summarization threshold. |
| `CHUMP_PREFER_LARGE_CONTEXT=1` | Sort slots by context size (largest first), then priority. Use for one-shot large doc, codebase digest, or long code review so Gemini (1M) or 128k slots get tried first. |

**Suggested CONTEXT_K (optional):** Slot 1 Groq `128`, Slot 2 Cerebras `128` or `65` (qwen-3-235b), Slot 3 Mistral `128`, Slot 4 OpenRouter `128`, **Slot 5 Gemini `1000`** (1M). Slot 6 GitHub `8`. With these set, `CHUMP_PREFER_LARGE_CONTEXT=1` will prefer Gemini for large-context tasks; without them, all slots are treated as 0 and priority order alone applies.

### RPD tracking

Each slot tracks calls-per-day in memory (resets every 24 h). Set `CHUMP_PROVIDER_{N}_RPD` to the provider's daily cap; the cascade skips that slot once `calls_today >= RPD * headroom%`. No RPD set = unlimited.

---

## 3. Verify

```bash
./scripts/ci/check-providers.sh
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

Set in `.env` or shell: `HEARTBEAT_INTERVAL=5m HEARTBEAT_DURATION=8h ./scripts/dev/heartbeat-learn.sh`

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

The cascade handles this automatically: **all wired providers are used according to need** — priority first, then by rate limits (RPM/RPD), privacy (safe for work/code, trains for research), and optionally by context size when `CHUMP_PREFER_LARGE_CONTEXT=1`. High-value rounds consume Groq/Cerebras first; Mistral/OpenRouter absorb overflow; Gemini (slot 5) is reserved for large-context when CONTEXT_K=1000 is set.

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

## 8. Mabel on Pixel

Mabel uses the same binary and cascade logic as Chump. Cascade is **injected on the Pixel** when [apply-mabel-badass-env.sh](../scripts/setup/apply-mabel-badass-env.sh) runs and finds provider keys. The script reads keys from `MAC_ENV` (default on Mac: `$HOME/Projects/Chump/.env`). On the Pixel that path does not exist; the script falls back to `~/chump/.env.mac` when present (pushed by [deploy-all-to-pixel.sh](../scripts/setup/deploy-all-to-pixel.sh)). So: run **deploy-all-to-pixel** from the Mac (which SCPs keys to `~/chump/.env.mac` and runs apply with `MAC_ENV=$HOME/chump/.env.mac`), or manually SCP provider key lines to Pixel as `~/chump/.env.mac` and run `apply-mabel-badass-env.sh` there (it will use the fallback). After that, Mabel's `.env` has `CHUMP_CASCADE_ENABLED=1` and cloud slots; she responds much faster than local-only.

---

## 9. Disabling cascade

```bash
CHUMP_CASCADE_ENABLED=0
```

Chump falls back to single-provider mode using `OPENAI_API_BASE` / `OPENAI_API_KEY` / `OPENAI_MODEL`.
