# CP-018: Harvest smugglers' AI-GM context pipeline → Chump's LLM working-set manager

**Target:** Chump's long-session context/memory management — keeping an agent's prompt cheap, bounded, and gracefully degrading over a multi-hour fleet run.
**Arsenal match:** `repairman29/smugglers` at `playsmuggler-deploy/js/aiGM/` (context* modules + promptBuilder + llmClient).
**Recommended route:** Pattern + two directly-liftable primitives (Rust port, cite source).
**Status:** proposed (mined 2026-07-12 via MINE_MANIFEST P1-01; primitives staged in `~/Projects/extractions/smugglers/context-primitives/`).
**Related:** CP-006 (openclaw memory pattern), CP-011 (bicameral router), CP-012 (provider chain — the *downstream* wire this pipeline feeds).

## The Target

A naive agent stuffs the whole transcript into every prompt; cost and latency grow without bound and signal drowns in noise. Chump runs long, multi-agent sessions where that's exactly the failure. This is a complete, deterministic answer to "LLM working-set management" that predates and parallels vector-RAG — weighted heuristics instead of embeddings on the hot path.

## The Arsenal Match — a six-stage pipeline

Every candidate memory runs through a fixed chain before it reaches the model. Each stage is deterministic, tunable by explicit weights/thresholds, and makes **no LLM call of its own**; only the last stage talks to a model, and it's hardened.

```
score → cluster → summarize → expire → promptBuilder → llmClient
(rank)  (group)   (compress)  (evict)  (assemble)      (call + verify + fall back)
```

1. **Score** (`contextRelevanceScorer.js`) — ranks each item 0–100 on five tunable weights (temporal 30, character 25, location 20, thread 15, emotional 10). Two hard budget knobs make the whole thing bounded: `minRelevanceThreshold=10` (drop below) and `maxContextItems=10` (hard cap on what reaches the prompt). *Doctrine: relevance is a weighted sum of cheap signals with an explicit cap; the cap is what keeps prompt cost flat as a session grows.*
2. **Cluster** (`contextClustering.js`) — groups by character/location/theme so the unit of compression is "one storyline," not "one event." *Doctrine: clustering makes summarization lossy-but-coherent instead of lossy-and-disjoint.*
3. **Summarize** (`contextSummarizer.js`) — deterministic, templated text reduction per entity type. *Doctrine: summarize **before** you evict — a 90-day thread becomes two usable sentences instead of bloating the prompt or vanishing.*
4. **Expire** (`contextExpiration.js`) — tiered eviction (`keep`/`summarize`/`archive`/`delete`) by age per entity type, with a `protectedImportance=["critical","high"]` class that never auto-deletes. *Doctrine: a lifecycle policy needs tiered actions (not binary keep/delete) plus a protected opt-out class.*
5. **Assemble** (`promptBuilder.js`) — consumes the pipeline's output (never the raw store), composing sections conditionally so the prompt carries only what exists; every optional subsystem is guarded so a missing one degrades gracefully.
6. **Call, verify, fall back** (`llmClient.js`) — the single hardened wire: 10s timeout, 3 retries (exp backoff), a **quality gate** (score 0–1 on length/markers/lexical variety; auto-fail on `[object Object]`), and deterministic `FALLBACK_TEMPLATES` so a slow/bad model never hard-stops the session. *Doctrine: "success" = response received **and** passed a quality bar, not HTTP 200. Always carry a deterministic fallback so degraded availability degrades output quality, not availability.* A `contextManager.js` maintenance loop runs score→summarize→expire on a timer, enforcing the budget continuously.

## Directly liftable (staged)

`contextRelevanceScorer.js` (weighted scorer + caps) and `contextExpiration.js` (tiered lifecycle policy) are framework-free logic behind a trivial shim — decouple from the game's `narrativeMemory` shape and they're a generic "LLM working-set manager." Port to Rust for the Chump worker's context assembly.

## Honest caveats (verified against the repo — do not repeat the overclaims)

- As committed, `llmClient.js` POSTs to `/api/llm/generate`, **which exists in no server file** — the engine only ever ran in template-fallback mode. The *design* is complete; the live wire is cut. Excellent doctrine, poor copy-paste production code.
- Scoring is heuristic/weighted, **not** embedding-based — the repo's READMEs oversell it as "AI." That's a feature for a doctrine reader (cheap, inspectable); don't repeat the overclaim.
- Uses browser globals as a service registry — replace with explicit DI in any reuse.
