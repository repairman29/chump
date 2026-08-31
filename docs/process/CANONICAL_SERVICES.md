# Canonical services registry (INFRA-3463)

**Prefer the shared substrate over building in silos.** When a capability already
has a canonical shared service in this codebase, new code should route through it
rather than hand-rolling its own client, auth, retries, and fallback. Silos
duplicate logic, drift, and reproduce bugs the shared service already solved — the
canonical example being the OAuth-only reviewer bug (INFRA-3457): a hand-rolled
`curl` + `x-api-key` that broke for subscription/OAuth-only users because it
bypassed the shared LLM service that already handled the auth ladder.

This file is the **source of truth** consumed by:
- the **Shared-Service-Bypass gate** (`scripts/git-hooks/pre-commit-shared-service.sh`),
  which surfaces new bespoke calls at commit time; and
- the **comprehension organs** (WIRING), which steer agents toward the shared
  service by reflex (INFRA-3458/3459).

Steer (comprehension) + prevent (gate) = the contract.

## Registry

| Capability class | Canonical shared service | Sanctioned entry points | Bespoke-call signals the gate watches |
|---|---|---|---|
| **LLM completion** | `ProviderCascade` (`src/provider_cascade.rs`) — auth ladder incl. OAuth, 429 backoff, slot cascade/fallback, model-class routing, privacy tiers | **Rust:** `provider_cascade::build_provider().complete(...)`. **Shell / external:** `chump llm-complete [--model <class>] [--system <t>] [--max-tokens <n>]` (INFRA-3461/3462), which routes through the same cascade | `api.anthropic.com`, `api.openai.com`, `x-api-key`, hand-rolled `/v1/messages` or `/v1/chat/completions` POSTs |

_Add a row per capability class as canonical services are established (e.g.
GitHub reads → the local cache; canonical state → the gap store)._

## Legitimately-direct sites (NOT silos)

Some direct calls are correct and must not be flagged. The gate allowlists them by
path; keep this list and the gate's allowlist in sync:

- **The shared layer itself:** `src/provider_cascade.rs`, `src/local_openai.rs`.
- **Credential-validity probes** (must hit the raw endpoint to test *that* key):
  `scripts/coord/auth-status.sh`, `src/web_server.rs` (`probe_secret`),
  `src/model_probe.rs`, `src/routes/health.rs`.
- **Standalone research / eval harnesses** whose whole point is to hit providers
  directly: `scripts/ab-harness/**`, `scripts/eval/cross-judge.sh`.
- **Liveness/readiness probes:** `scripts/ci/check-providers.sh`,
  `scripts/ci/check-heartbeat-preflight.sh`, and similar `/models` pings.
- **Audited intentional-direct call sites** (INFRA-3465, resolved by the
  2026-07-28 fragmentation audit as allowlist-not-migrate — see
  [`SHARED_LLM_SERVICE_INTEGRATION.md`](../design/SHARED_LLM_SERVICE_INTEGRATION.md)):
  `src/adversary_llm.rs` (adversarial-critique use case; a same-signature
  swap to `provider_cascade::build_provider()` was considered and rejected
  as unnecessary churn — the direct call is already scoped and audited) and
  `src/screen_vision_tool.rs` (vision/image input — `ProviderCascade::complete()`
  is text-only today, so this is a capability gap, not a routing bug; direct
  is correct until an image-input variant exists).

## Adding a new bespoke call anyway

If you have a genuine reason to bypass the shared service, add a commit trailer so
it is **audited**, not silent (mirrors `Rust-First-Bypass`):

```
Shared-Service-Bypass: <one-sentence reason>
```

## Enforcement level

The gate **warns by default** (per the anti-friction doctrine that softened the
rust-first gate, INFRA-2522 / `docs/strategy/COMMIT_MERGE_AUDIT_2026-06-03.md`) —
a heuristic nudge, not a hard wall. To hard-enforce (block unless the bypass
trailer is present), set `CHUMP_SHARED_SERVICE_BLOCK=1`. Disable entirely with
`CHUMP_SHARED_SERVICE_CHECK=0`.

## Current debt (migrate through the shared service over time)

Per the 2026-07-28 audit (memory `llm-service-fragmentation-audit`), 5 product-path
bespoke LLM calls exist; the reviewer (#1) is migrated (INFRA-3462), and
`src/adversary_llm.rs` + `src/screen_vision_tool.rs` are resolved as audited
allowlist entries (INFRA-3465, see "Legitimately-direct sites" above — not
migration debt). Remaining: `code-reviewer-agent.sh:288` (Tier-1),
`src/main.rs` (`gap decompose --verify`).
