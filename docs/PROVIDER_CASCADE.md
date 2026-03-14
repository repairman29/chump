# Provider Cascade Setup

Chump can use multiple OpenAI-compatible APIs in a cascade: try cloud providers (Groq, OpenRouter, Gemini) in priority order; if rate-limited or down, fall back to the next, then to local (Ollama). See [ROADMAP_PROVIDER_CASCADE.md](ROADMAP_PROVIDER_CASCADE.md) for architecture.

## 1. Sign up and get API keys

| Provider | Signup | Get key |
|----------|--------|---------|
| **Groq** | https://console.groq.com | API Keys → Create API Key |
| **OpenRouter** | https://openrouter.ai | Keys → Create Key |
| **Google Gemini** | https://aistudio.google.com/apikey | Get API key |
| **xAI (Grok)** | https://console.x.ai | API key |
| **Mistral** | https://console.mistral.ai | API key |

## 2. Configure .env

Set `CHUMP_CASCADE_ENABLED=1`. Add per-provider vars for each slot you want (slots 1–3 = Groq, OpenRouter, Gemini). Slot 0 is always local from existing `OPENAI_API_BASE` / `OPENAI_API_KEY` / `OPENAI_MODEL`.

Example (Groq + OpenRouter; Gemini optional):

```bash
CHUMP_CASCADE_ENABLED=1
CHUMP_CASCADE_STRATEGY=priority
CHUMP_CASCADE_RPM_HEADROOM=80

# Slot 1: Groq
CHUMP_PROVIDER_1_ENABLED=1
CHUMP_PROVIDER_1_NAME=groq
CHUMP_PROVIDER_1_BASE=https://api.groq.com/openai/v1
CHUMP_PROVIDER_1_KEY=gsk_your_key_here
CHUMP_PROVIDER_1_MODEL=llama-3.3-70b-versatile
CHUMP_PROVIDER_1_RPM=30
CHUMP_PROVIDER_1_TIER=cloud
CHUMP_PROVIDER_1_PRIORITY=10

# Slot 2: OpenRouter
CHUMP_PROVIDER_2_ENABLED=1
CHUMP_PROVIDER_2_NAME=openrouter
CHUMP_PROVIDER_2_BASE=https://openrouter.ai/api/v1
CHUMP_PROVIDER_2_KEY=sk-or-your_key_here
CHUMP_PROVIDER_2_MODEL=meta-llama/llama-3.3-70b-instruct:free
CHUMP_PROVIDER_2_RPM=20
CHUMP_PROVIDER_2_TIER=cloud
CHUMP_PROVIDER_2_PRIORITY=20

# Slot 3: Gemini (optional)
# CHUMP_PROVIDER_3_ENABLED=1
# CHUMP_PROVIDER_3_NAME=gemini
# CHUMP_PROVIDER_3_BASE=https://generativelanguage.googleapis.com/v1beta/openai
# CHUMP_PROVIDER_3_KEY=AIzaSy...
# CHUMP_PROVIDER_3_MODEL=gemini-2.0-flash
# CHUMP_PROVIDER_3_RPM=15
# CHUMP_PROVIDER_3_TIER=cloud
# CHUMP_PROVIDER_3_PRIORITY=30
```

## 3. Verify

From the Chump repo root:

```bash
./scripts/check-providers.sh
```

You should see `[0] local ✓` and `[1] groq ✓`, `[2] openrouter ✓` for each enabled provider.

## 4. Test

```bash
./run-local.sh --chump "What model are you?"
```

With cascade enabled, the reply will come from the first available cloud provider (e.g. Groq) or local if all cloud slots are down/rate-limited.

## Turning cascade off

Set `CHUMP_CASCADE_ENABLED=0` or remove it. Chump then uses only `OPENAI_API_BASE` / `OPENAI_API_KEY` / `OPENAI_MODEL` as before.
