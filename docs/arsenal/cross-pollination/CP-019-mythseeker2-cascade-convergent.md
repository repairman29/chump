# CP-019: mythseeker2's three-tier cascade → convergent evidence for CP-012 (provider chain)

**Target:** Chump's deterministic provider-chain executor (the same target as CP-012). This entry is **corroboration + anti-patterns**, not a second design to vendor.
**Arsenal match:** `repairman29/mythseeker2` at `src/services/aiService.ts` (staged byte-identical in `~/Projects/extractions/mythseeker2/`).
**Recommended route:** Reference only — CP-012 (ai-gm ensemble) is the design to port. This confirms it and adds guardrails.
**Status:** proposed (mined 2026-07-12 via MINE_MANIFEST P1-01).
**Related:** CP-012 (ai-gm provider chain — the canonical version), CP-001 (neural-farm local tier).

## Why a second entry for the same pattern

Two unrelated repos in the portfolio — `ai-gm-service` (CP-012) and `mythseeker2` — independently converged on the **same** never-throw provider cascade. That convergence is the signal: this is the right shape for Chump's Neocortex-tier dispatcher, not a one-off. mythseeker2's version is smaller and adds a few doctrine points CP-012 doesn't spell out, plus a live anti-pattern worth naming so Chump never repeats it.

## The pattern (confirming CP-012)

`generateResponse()` is a single entry point that **never rejects**:

```
try:  tryVertexAI() → AIResponse|null   (return if non-null)
      tryOpenAI()   → AIResponse|null   (return if non-null)
      generateIntelligentFallback() → string   (local, always succeeds)
catch: generateIntelligentFallback()   (emergency — same tier 3)
```

Doctrine points worth carrying into the Rust port:

1. **Each tier is null-on-failure, not throw-on-failure.** A tier catches its own network/parse errors and returns `null`; a missing API key → `null` immediately (a tier disables itself cleanly when unconfigured). The orchestrator only *sequences* tiers — it never handles provider-specific errors.
2. **Tier 3 is code, not a provider.** The local fallback keyword-classifies the input (combat/social/magic/…) and template-fills from context, so degraded mode still produces something contextual instead of an error string. The caller awaits one promise and always renders a reply.
3. **Bounded history + one shared prompt builder.** History is a `Map` truncated to the last 50 messages (no external store); `buildAdvancedSystemPrompt` compresses context to a fixed shape so **providers are interchangeable at the prompt level** — only request/response mapping differs per tier.
4. **Uniform response envelope** `{ content, model, responseTime, confidence }` gives the router a place to hang attribution and quality scoring.

## The anti-patterns to name and never repeat

- **⛔ Client-exposed key design.** As written this runs in the browser bundle and puts `VITE_OPENAI_API_KEY` / `VITE_VERTEX_AI_API_KEY` straight into `fetch()`. Vite ships `VITE_`-prefixed vars into client JS by design — any visitor could pull live keys from dev tools. **A server-side relay holding the keys is mandatory; a key swap is not a fix.** The cascade logic is transport-agnostic and moves server-side intact.
- **The honest-status lesson.** The env plumbing never actually worked: the code reads `process.env.VITE_*` but the build only defines `process.env.NODE_ENV`, so in a real browser build both keys read as absent and **every call dropped straight to tier 3.** The cloud tiers were never exercised in the shipped product — the local fallback *was* the product. A clean reminder that "we have a multi-provider cascade" and "the cascade ran" are different claims; verify which one is true before believing a repo's README.
- Cosmetic bugs not to copy: `responseTime: Date.now()` and `Date.now() - Date.now()` (neither measures latency); a `tryOpenAI` that throws-then-catches-its-own-throw; 2025-era hardcoded model ids (`gemini-pro`, `gpt-4`) — parameterize per tier.
