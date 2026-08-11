# Shared LLM service integration — design (INFRA-3568, INFRA-3462 slice)

## Problem

Prior to INFRA-3457/INFRA-3462, product code hand-rolled LLM calls (raw `curl`
+ `x-api-key` against `api.anthropic.com`/`api.openai.com`) instead of going
through `ProviderCascade`. The canonical failure: the Tier-2 code-reviewer
call in `scripts/coord/code-reviewer-agent.sh` broke for OAuth/subscription
auth because its bespoke `curl` only understood a raw API key — the shared
cascade already handled that auth ladder and the silo simply hadn't been
routed through it (INFRA-3457).

This doc records the shared-service design already in production (the
`ProviderCascade` + `chump llm-complete` gateway), and gives the remaining
bespoke call sites a concrete integration path, so future callers reach for
the shared service by default instead of another silo.

## Shared service architecture (as-built)

```
Rust callers                Shell / external callers
     │                                │
     ▼                                ▼
provider_cascade::build_provider()   `chump llm-complete`
     │                                │  (src/main.rs, INFRA-3461)
     └──────────────┬─────────────────┘
                     ▼
            ProviderCascade (src/provider_cascade.rs)
              - auth ladder: OAuth token → API key → cascade slots
              - 429 / rate-limit backoff
              - slot fallback across configured providers
              - model-class routing (opus/sonnet/haiku aliases)
              - privacy-tier enforcement
```

Two sanctioned entry points, one underlying implementation:

- **Rust:** `provider_cascade::build_provider().complete(...)` — direct
  in-process call for Rust code.
- **Shell / external:** `chump llm-complete [--model <class>] [--system <t>]
  [--max-tokens <n>]`, reading the prompt from `--prompt` or stdin
  (`src/main.rs:1462`). This is the gateway non-Rust callers (bash scripts,
  subagent dispatch scripts) use, and it routes through the exact same
  `ProviderCascade` — no separate auth/retry logic to drift.

This registry-level contract is documented in
[`docs/process/CANONICAL_SERVICES.md`](../process/CANONICAL_SERVICES.md),
which is the source of truth consumed by:
- the **Shared-Service-Bypass gate** (`scripts/git-hooks/pre-commit-shared-service.sh`),
  a warn-by-default pre-commit heuristic that flags new bespoke-call signals
  (`api.anthropic.com`, `api.openai.com`, `x-api-key`, hand-rolled
  `/v1/messages` or `/v1/chat/completions` POSTs) and requires a
  `Shared-Service-Bypass: <reason>` trailer to proceed silently past the
  warning;
- WIRING comprehension organs that steer agents toward the shared service by
  reflex.

## What's already migrated

- **Tier-2 code review** (`scripts/coord/code-reviewer-agent.sh`, the
  Anthropic call): migrated to `chump llm-complete --model opus` in
  INFRA-3462. No `ANTHROPIC_API_KEY` handling in the script any more — the
  gateway owns auth, including OAuth/subscription tokens.

## Remaining bespoke sites (per 2026-07-28 fragmentation audit)

Tracked in `docs/process/CANONICAL_SERVICES.md` "Current debt". Design intent
for each:

| Site | Current shape | Migration path | Notes |
|---|---|---|---|
| `code-reviewer-agent.sh` Tier-1 pre-check (`~L316`, `curl … /chat/completions`) | Direct `curl` to a *specific* cascade slot's base URL (e.g. Groq) with that slot's raw key, read straight from `.env` | Likely **allowlist, not migrate**: Tier-1 exists specifically to hit one free/cheap slot directly as a cost pre-filter before paying for the Tier-2 cascade call. Forcing it through `chump llm-complete` would remove the caller's ability to pin a specific cheap slot. Candidate resolution: either (a) extend `chump llm-complete` with a `--slot <name>` pin so Tier-1 can go through the gateway too and gain retry/backoff for free, or (b) add this call site to the "Legitimately-direct sites" allowlist in `CANONICAL_SERVICES.md` with a `Shared-Service-Bypass` trailer explaining the cost-tiering rationale. **Recommendation: (a)** — a `--slot` pin is a small `provider_cascade.rs` addition and removes a second hand-rolled retry/timeout path. |
| `src/adversary_llm.rs` (`reqwest::Client` + `Authorization: Bearer`) | In-process Rust `reqwest` call, presumably direct to one provider for an adversarial-critique use case | Migrate to `provider_cascade::build_provider().complete(...)` directly — it's already Rust, already in-process, no gateway hop needed. Straightforward swap once the call's model/prompt shape is confirmed compatible with `ProviderCascade`'s `complete()` signature. |
| `src/screen_vision_tool.rs` (`reqwest::Client`, OpenAI-style `/v1/chat/completions` with base64 PNG) | Vision (image) input — `ProviderCascade::complete()` is text-only today | **Not a drop-in migration.** Requires either extending `ProviderCascade`/`Provider` trait with an image-input variant, or explicitly allowlisting this site (vision is a capability class the shared service doesn't yet cover) per the "Legitimately-direct sites" pattern. Recommend filing a follow-up INFRA gap to decide allowlist-now vs. extend-cascade-for-vision, scoped separately from this design doc — it's a capability gap, not a routing bug. |
| `src/main.rs` `gap decompose --verify` | Verification pass on decomposed sub-gaps via a stronger model | Same shape as `adversary_llm.rs` — in-process Rust, text-only. Migrate to `provider_cascade::build_provider().complete(...)`. |

## Recommended slice order

1. `src/adversary_llm.rs` and `gap decompose --verify` — both are Rust,
   text-only, same-signature swaps to `provider_cascade::build_provider()`.
   Lowest risk, ships independently, each as its own `xs`/`s` gap.
2. Tier-1 `code-reviewer-agent.sh` pre-check — add `--slot` pin to `chump
   llm-complete`, then swap the `curl` call. Slightly larger (touches the
   gateway CLI surface), still contained.
3. `screen_vision_tool.rs` — deferred pending a capability decision (extend
   `ProviderCascade` for image input vs. allowlist). File as a separate
   scoped gap; don't block the other three slices on it.

## Non-goals

- This doc does not redesign `ProviderCascade` itself — it is stable,
  in production, and already handles the hard parts (OAuth ladder, 429
  backoff, slot fallback, model-class routing, privacy tiers).
- This doc does not mandate migrating the "Legitimately-direct" allowlisted
  sites in `CANONICAL_SERVICES.md` (credential-validity probes, eval
  harnesses, liveness pings) — those are correctly direct by design.

## Review / approval

Per AC #2, this design is surfaced for team review via the standing A2A
consensus channel rather than a synchronous meeting: broadcast a `FEEDBACK
kind=proposal` referencing this doc and INFRA-3462/INFRA-3463, and let
curator votes (`chump vote <corr_id> +1|-1|0`) stand as the "reviewed and
approved" record, consistent with how routine architecture decisions are
ratified in this codebase (see CLAUDE.md "A2A consensus is always-on").
