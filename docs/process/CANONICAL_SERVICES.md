---
doc_tag: canonical
owner_gap: INFRA-3463
last_audited: 2026-11-27
---

# Shared Services Registry

**Prefer canonical shared services over hand-rolled silos.** When a capability already has a shared implementation in Chump, new modules and scripts route through it rather than duplicating HTTP clients, authentication ladders, retry backoff, and circuit breakers.

---

## Canonical Service Table

| Capability Class | Canonical Shared Service | Sanctioned Entry Points | Bespoke Signals Watched by Pre-Commit Gate |
|------------------|--------------------------|-------------------------|--------------------------------------------|
| **LLM Completion** | `ProviderCascade` (`src/provider_cascade.rs`) — subscription OAuth ladder, 40-slot failover, HTTP 429 RPM headroom, model-tier routing, and privacy boundaries | **Rust:** `provider_cascade::build_provider().complete(...)`<br>**Shell / CLI:** `chump llm-complete [--model <class>] [--system <t>] [--max-tokens <n>]` | Raw HTTP calls to `api.anthropic.com` / `api.openai.com`, `x-api-key` headers, or bespoke `/v1/messages` and `/v1/chat/completions` POSTs |

---

## Why This Matters

Routing every completion through `ProviderCascade` guarantees that:

1. **Subscription OAuth works everywhere:** Users running on OAuth tokens (`[auth] mode = "auto"`) never hit unexpected `x-api-key missing` failures in auxiliary tools such as automated diff review or task decomposition.
2. **Rate-limit and circuit state is shared:** When one slot returns HTTP `429` or `503`, every caller immediately fails over to the next healthy slot in `~/.chump/config.toml`.
3. **Privacy boundaries hold:** Repositories or sessions marked local-only (`tier = "local"` or `CHUMP_AIR_GAP_MODE=1`) never leak prompts through a side-channel script.

---

## Legitimate Direct Call Sites (Allowlisted)

A small set of low-level modules intentionally talk to raw endpoints and are allowlisted in `scripts/git-hooks/pre-commit-shared-service.sh`:

- **The cascade transport layer itself:** `src/provider_cascade.rs` and `src/local_openai.rs`.
- **Per-credential health probes** (which must test a specific slot or key directly): `src/model_probe.rs`, `src/routes/health.rs`, `src/web_server.rs` (`probe_secret`), and `scripts/ci/check-providers.sh`.
- **Isolated benchmark harnesses:** `scripts/ab-harness/**` and `scripts/eval/cross-judge.sh`.
- **Specialized multimodal / adversarial paths:** `src/screen_vision_tool.rs` (image-input payloads) and `src/adversary_llm.rs` (isolated critique client).

---

## Audited Bypass Trailer

If a new integration has a genuine architectural reason to call a provider endpoint directly, record the rationale in the git commit trailer so it remains auditable:

```text
Shared-Service-Bypass: <one-sentence architectural reason>
```

By default `pre-commit-shared-service.sh` emits a warning nudge in local development and can be configured to hard-enforce in strict CI environments.

---

## Related Guides

- [Provider Cascade & OAuth](../architecture/PROVIDER_CASCADE.md)
- [File Leases & Worktrees](AGENT_COORDINATION.md)
