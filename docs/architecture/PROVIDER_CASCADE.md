---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Provider Cascade & Subscription OAuth

Chump routes LLM requests across **four mix-and-match lanes** configured once in `~/.chump/config.toml` (`%USERPROFILE%\.chump\config.toml` on Windows) with optional environment variable overrides:

1. **Connected Subscriptions / OAuth (`[auth]`)** — reuses existing signed-in CLI credentials (`Claude Code` OAuth tokens, macOS Keychain, `~/.claude/.credentials.json`) with automatic 5-minute token sync via `chumpd`.
2. **40-Slot API-Key Cascade (`[[providers]]`)** — priority-ordered OpenAI-compatible and native cloud slots (Gemini, Anthropic, OpenAI, Mistral Codestral, Groq, Cerebras, Together, DeepSeek, OpenRouter) with RPM headroom throttling, daily RPD budgets, circuit breakers, and Thompson-sampling latency/quality routing (`BanditRouter`).
3. **Bring-Your-Own Coding Harnesses (`[fleet] harness`)** — dispatches worker tasks through `claude`, `opencode`, `codex`, `aider`, or `goose` while enforcing Chump's file leases and ship firewall.
4. **Zero-Key Local Endpoints (`tier = "local"`)** — routes to `Ollama`, `LM Studio`, `llama.cpp`, or `vLLM` on localhost or your LAN with `$0` marginal token cost.

---

## 1. Declarative Configuration (`~/.chump/config.toml`)

Scaffold and validate your configuration with:

```bash
chump config init
chump config validate
chump config show
```

### Multi-Tier Example

```toml
[auth]
mode = "auto"                # "auto" | "oauth" | "api-key"

[fleet]
mode = "grind"
desired_workers = 4
harness = "claude"
disk_floor_gb = 5.0
auto_merge = false

[[providers]]
name = "gemini-frontier"
enabled = true
tier = "cloud"
base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
api_key_env = "GEMINI_API_KEY"
model = "gemini-2.5-pro"
priority = 5
rpm_limit = 120

[[providers]]
name = "gemini-fast"
enabled = true
tier = "cloud"
base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
api_key_env = "GEMINI_API_KEY"
model = "gemini-2.5-flash"
priority = 10
rpm_limit = 360

[[providers]]
name = "codestral-paid"
enabled = true
tier = "paid"
base_url = "https://api.mistral.ai/v1"
api_key_env = "MISTRAL_API_KEY"
model = "codestral-latest"
priority = 15

[[providers]]
name = "ollama-local-floor"
enabled = true
tier = "local"
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5-coder:14b"
priority = 20
```

> **Security:** Never paste raw API keys into `config.toml`. Reference environment variable names via `api_key_env = "GEMINI_API_KEY"` so secrets remain in your OS keychain, `.env` (gitignored), or secret manager.

---

## 2. Subscription OAuth Discovery & Auto-Refresh

When `[auth] mode = "auto"` (default) or `"oauth"`, Chump resolves credentials in deterministic order:

1. `CLAUDE_CODE_OAUTH_TOKEN` environment variable (`sk-ant-oat*`).
2. `~/.chump/oauth-token.json` (`0600` permissions, refreshed every 5 minutes by `chumpd`).
3. OS credential store (`Claude Code-credentials` in macOS Keychain or `~/.claude/.credentials.json` / `%USERPROFILE%\.claude\.credentials.json`).
4. Fallback to `ANTHROPIC_API_KEY` when `[auth] mode = "auto"` and an OAuth token is absent or returns HTTP `401` (emitting `kind=fleet_auth_fallback` to `ambient.jsonl`).

---

## 3. Failover, RPM Headroom & Circuit Breakers

For every completion call (`ProviderCascade` in `src/provider_cascade.rs` or `chump llm-complete`):

- **Priority ordering:** Enabled slots are sorted by ascending `priority` (`1` = highest priority, `40` = lowest fallback floor).
- **Proactive RPM headroom:** Set `CHUMP_CASCADE_RPM_HEADROOM=80` (percentage of `rpm_limit`, default `80`) so high-concurrency worker pools step down to the next slot *before* triggering upstream HTTP `429` bans.
- **Per-slot circuit breaker:** Three consecutive HTTP `5xx` or rate-limit errors open that slot's circuit for `CHUMP_CIRCUIT_COOLDOWN_SECS` (default `30s`), routing traffic immediately to the next healthy slot.
- **Context-size guard:** Slots with smaller context windows are skipped automatically when prompt token estimates exceed the slot's configured context ceiling.
- **Privacy & air-gap enforcement:** Setting `CHUMP_AIR_GAP_MODE=1` or marking a task local-only restricts selection strictly to `tier = "local"` endpoints (`127.0.0.1` / `localhost`).

---

## 4. Environment Variable Slot Overrides (`CHUMP_PROVIDER_{1..40}_*`)

For CI runners, containers, or `.env`-driven setups, any of the 40 cascade slots can also be defined or overridden via environment variables:

```bash
CHUMP_CASCADE_ENABLED=1
CHUMP_CASCADE_STRATEGY=priority          # "priority" | "bandit"

CHUMP_PROVIDER_1_ENABLED=1
CHUMP_PROVIDER_1_NAME=groq-fast
CHUMP_PROVIDER_1_BASE=https://api.groq.com/openai/v1
CHUMP_PROVIDER_1_KEY=$GROQ_API_KEY
CHUMP_PROVIDER_1_MODEL=llama-3.3-70b-versatile
CHUMP_PROVIDER_1_PRIORITY=10
CHUMP_PROVIDER_1_RPM=30
CHUMP_PROVIDER_1_RPD=1000
CHUMP_PROVIDER_1_TIER=cloud
```

---

## 5. Inspecting Live Cascade Health

- **CLI one-shot completion test:**
  ```bash
  chump llm-complete --model sonnet "Return OK"
  chump --once --why "Check active model routing"
  ```
- **Web Cockpit API:** `GET http://127.0.0.1:3847/api/cascade-status` returns live per-slot circuit state, RPM/RPD counters, and latency percentiles.
- **Interactive Browser Tool:** Model failover cascades and token budgets visually in the [Config & Failover Doctor](https://repairman29.github.io/chump/tools/config-doctor/).

---

## Related Guides

- [Hardware & RAM Profiles](../operations/INFERENCE_PROFILES.md)
- [Inference Stability](../operations/INFERENCE_STABILITY.md)
- [Shared Services](../process/CANONICAL_SERVICES.md)
