# EVAL-031 — Search-Augmented Reasoning: AutoRefine + Policy Trajectories Evaluation

**Gap:** EVAL-031  
**Date:** 2026-04-20  
**Status:** Complete — recommendation: no implementation gap needed at current scale  
**Confidence:** Medium  
**Research integrity:** All estimates labelled as estimates. No A/B data was collected for this eval — it is a qualitative analysis and scale estimate, not a measured result.

---

## Summary

AutoRefine-style multi-step retrieval is architecturally interesting but does not solve a problem Chump currently has. Chump's memory store is small (estimated median: single digits to low tens of rows in active sessions), the context window is 200K tokens, and the retrieval pipeline already uses a three-way RRF fusion (FTS5 keyword + semantic embedding + graph associative recall) with BM25 reranking and MMR diversification. The missing element — iterative refinement — is unnecessary when you can cheaply load the entire candidate pool in one shot and the context window can hold it. This eval closes EVAL-031 as "not needed at our scale" with a recommendation to revisit if memory row counts exceed ~500 per session.

---

## 1. Current State: How Chump's Retrieval Works

### 1.1 Storage

`src/memory_db.rs` implements an SQLite backend (`sessions/chump_memory.db`) with:
- A `chump_memory` table holding rows with: `id`, `content`, `ts`, `source`, `confidence`, `verified`, `sensitivity`, `expires_at`, `memory_type`.
- A FTS5 virtual table (`memory_fts`) kept in sync via INSERT/UPDATE/DELETE triggers.
- Memory types include `semantic_fact`, `episodic_event`, `episodic_memory`.
- A curation pipeline: expiry, exact deduplication, confidence decay (0.01/day for unverified), and LLM-based episodic→semantic summarization for clusters ≥ 5 rows older than 30 days.

A JSON fallback (`sessions/chump_memory.json`) is used when the SQLite DB is unavailable.

### 1.2 Retrieval Pipeline (single-turn, single-pass)

When `recall_for_context(query, limit)` is called in `src/memory_tool.rs`, the pipeline is:

1. **Query expansion** via `memory_graph::associative_recall` — entity names extracted from the query are expanded with graph-associated entities (up to `CHUMP_GRAPH_MAX_HOPS=2` hops, default).
2. **FTS5 keyword search** (`memory_db::keyword_search`) — tokens are OR-joined as FTS5 MATCH phrases on the expanded query. Returns up to `limit * 2` rows ordered by recency (`id DESC`).
3. **Semantic search** — query is embedded via the local embed server or in-process model; cosine similarity is computed against stored embeddings; top `limit * 2` by similarity.
4. **Graph associative recall** — entity nodes from the query are traversed in the memory graph; linked memory IDs are ranked.
5. **RRF merge** (Reciprocal Rank Fusion, k=60) over the three ranked lists, with freshness decay (0.01/day) and confidence weighting applied per row.
6. **Optional BM25 reranking** (`CHUMP_MEMORY_RERANK=1`, default off) — blends BM25 term-overlap scores at alpha=0.4 with the RRF score.
7. **MMR diversification** (`CHUMP_MEMORY_MMR_LAMBDA=0.7`) — Maximal Marginal Relevance selects the final `limit` results, penalizing redundant Jaccard-similar memories.
8. **Context budget truncation** — output is capped at `MEMORY_CONTEXT_CHAR_BUDGET = 4000` characters.
9. **MAX_RECALL cap** — hard ceiling of 20 rows regardless of `limit` argument.

This is issued **once per turn** as a preprocessing step before the prompt is assembled. There is no mechanism for the model to issue follow-up retrieval queries based on what it received.

### 1.3 How Retrieved Memories Feed Into Prompts

The `src/agent_loop/prompt_assembler.rs` assembles the system prompt by stacking blocks in this order:
1. Spawn-time lessons (MEM-006, if enabled)
2. User-provided base system prompt
3. Task planner block (if active)
4. Reflection lessons block (COG-007/009/011/016)
5. Entity-keyed blackboard facts (COG-015)
6. Perception context summary (COG-027 gated)

Memory recall from `memory_tool::recall_for_context` is **not** directly called from the prompt assembler — it is invoked by the agent loop caller. The retrieved memories are formatted as a numbered list (`1. <content>\n2. <content>\n...`) and injected as a user-visible context block.

### 1.4 Approximate Scale

No production session data is available to measure directly. The following are **estimates** based on the codebase's design:

- **MAX_RECALL = 20 rows** per call — this is the hard upper bound on injected memories.
- **MEMORY_CONTEXT_CHAR_BUDGET = 4000 chars** — roughly 1,000 tokens at ~4 chars/token. At a 200K token context window, memory occupies approximately **0.5% of the available context**.
- **Typical session row count (estimate):** The curation config defaults are `min_cluster_size=5`, `min_age_days=30`, `max_clusters_per_pass=3`. A new session starts with whatever was in the DB before the session. For Chump dogfood use (single developer, moderate frequency), a few dozen to low hundreds of total rows is a plausible estimate. Batch episodic summarization would compress older material.
- **No measured data is available** for how many rows exist in real deployments or what fraction of rows are relevant to any given query. These estimates are plausible but unvalidated.

---

## 2. SAR Pattern Overview: What AutoRefine-Style Retrieval Looks Like

Search-Augmented Reasoning (SAR), as described in AutoRefine (Xu et al., NeurIPS 2024 / OpenReview rBlWKIUQey) and related work, replaces single-shot retrieval preprocessing with a reasoning-integrated retrieval loop:

1. **Initial retrieval:** Issue a search query based on the current question.
2. **Relevance assessment:** The model reads retrieved documents and decides whether they are sufficient to answer the question, or whether gaps exist.
3. **Query refinement:** If gaps exist, the model generates a refined query targeting the specific missing information.
4. **Iterative search:** Steps 1–3 repeat until the model is satisfied or a step budget is exhausted.
5. **Answer synthesis:** The model answers using the accumulated retrieved context.

**Policy-Driven Trajectories** (from related work on ReAct, FLARE, Self-RAG, and similar) extend this by training or prompting a policy that decides: when to search, how to scope the query (broad vs. narrow), whether to switch retrieval granularity (document vs. sentence vs. entity), and when to stop.

The key property that makes SAR useful: **the model can discover that its initial retrieval was insufficient and correct course**. This is most valuable when:
- The corpus is large relative to the context window (can't load everything).
- Queries are multi-hop: answering Q requires finding fact A, then using A to construct a query for fact B.
- Term mismatch is common: the query term doesn't match the document's vocabulary.

---

## 3. Applicability Analysis

### 3.1 Context window vs. corpus size

Chump's current architecture loads up to 20 rows (hard cap) at 4,000 characters per call. With a 200K token context window, there is approximately **50× slack** between the current memory injection budget and the available window. This slack means Chump could trivially increase `MAX_RECALL` to 200+ rows and still have headroom, provided the DB has that many relevant rows — which, per the scale estimates above, it typically does not.

When the full corpus fits in the context window without exceeding budget, iterative refinement adds latency and complexity with no retrieval benefit. The only benefit would be **LLM-directed relevance filtering** — but that is partially addressed by the existing MMR diversification and BM25 reranking.

**Estimate: at Chump's scale, the full working set of relevant memories is retrievable in a single pass.** This estimate has medium confidence and no measured validation backing it.

### 3.2 Multi-hop query requirement

SAR is most valuable for multi-hop queries: "Who is the person Jeff calls 'the watcher' and what is their on-call Slack channel?" This requires resolving the alias, then fetching the Slack channel — two distinct retrieval steps.

Chump's graph associative recall (step 4 in the pipeline above) partially addresses this within a single retrieval call: entity extraction + graph traversal can bridge alias→canonical name hops (up to `CHUMP_GRAPH_MAX_HOPS=2` hops). The MEM-010 entity resolution evaluation confirms 100% accuracy on the 30-pair test set for normalized string matches, though it documents two known limitations: underscore/space form variants and semantic alias resolution (e.g., "the watcher" ≠ "chump-heartbeat" without an alias table).

**The multi-hop gap that exists today is in entity alias resolution (MEM-010b), not in retrieval iteration.** AutoRefine wouldn't fix this — a second retrieval pass with a keyword query for "chump-heartbeat" still wouldn't retrieve it if the only alias is "the watcher" in the DB, unless the model happened to discover the correct term.

### 3.3 Term mismatch

FTS5 keyword search requires surface-form overlap between the query and document. The semantic embedding path in Chump's hybrid retrieval is intended to address this. When the embed server is available, RRF combines semantic and keyword signals.

AutoRefine's iterative query reformulation is a complementary mitigation for term mismatch — but it requires the model to know that a reformulation is needed, which requires it to have some prior knowledge about the target concept. For a personal memory assistant, this is often not true: the user is the oracle, not the model.

**Estimate: term mismatch is more likely to be solved by improving embedding coverage (ensuring the embed server is reliably available) than by iterative refinement.** No evidence of retrieval-miss failures due to term mismatch has been observed in eval artifacts reviewed.

### 3.4 Evidence of retrieval misses in existing evals

The evaluated documents reviewed (EVAL-010, EVAL-029, MEM-008, MEM-010, EVAL-032, EVAL-033) do not contain evidence of memory retrieval misses as a failure mode. The primary failure modes documented are:
- Lessons block causing hallucination on sonnet-4-5 (EVAL-027c)
- Neuromodulation harm on conditional-chain tasks (EVAL-029)
- Entity alias resolution gaps for semantic aliases (MEM-010, known limitation)

No eval has specifically measured memory hit-rate against a ground-truth relevance set. The absence of documented retrieval-miss failures does not confirm retrieval is working perfectly — it may reflect that memory retrieval hasn't been the focus of evals. This is a gap in the evidence, not a positive result.

---

## 4. Multi-Hop QA Fixture Design (Hypothetical)

If AutoRefine-style iterative retrieval were to be tested against Chump's current pipeline, the following three task types would specifically exercise the multi-step capability:

### Task 4.1 — Alias chain, single vocabulary bridge

**Setup:** Load into memory:
- Entry A: "The component Jeff calls 'the gateway' maps to the chump-router service."
- Entry B: "chump-router exposes port 8080 by default."
- Entry C: "The authentication layer for port 8080 services uses JWT with 24-hour expiry."

**Query:** "What authentication scheme does the gateway use?"

**Why this tests SAR:** Entry A is the only one that mentions "gateway". Single-shot retrieval keyed on "gateway" returns Entry A, which tells the model to look for "chump-router". A second retrieval keyed on "chump-router" + "authentication" or "port" would be needed to find Entry C. Current graph associative recall would handle Entry A → Entry B (2 hops), but connecting "port 8080" in Entry B to Entry C requires a third bridge not explicitly encoded as an entity edge.

### Task 4.2 — Temporal chain with implicit date arithmetic

**Setup:** Load into memory:
- Entry A: "Project Alpha entered beta on 2026-03-01."
- Entry B: "Chump's SLA for beta projects is 90 days from entry."
- Entry C: "If SLA deadline is missed, the project auto-escalates to the P0 oncall queue."

**Query:** "Has Project Alpha triggered the auto-escalation yet? (today is 2026-04-20)"

**Why this tests SAR:** The answer requires: (1) finding the beta start date, (2) finding the SLA rule, (3) doing date arithmetic (2026-03-01 + 90 days = 2026-05-30 > today, so no escalation yet), (4) applying the escalation rule. Single-shot retrieval with "Project Alpha" returns Entry A; entries B and C are not surface-linked to "Project Alpha" and may be missed.

### Task 4.3 — Causal chain with no shared surface terms

**Setup:** Load into memory:
- Entry A: "EVAL-027c found that lessons injection on sonnet-4-5 increases hallucination rate by +0.33."
- Entry B: "High hallucination rate on sonnet-4-5 caused the team to set CHUMP_LESSONS_MIN_TIER=capable as default."
- Entry C: "CHUMP_LESSONS_MIN_TIER=capable means lessons are only injected on haiku-class models by default."

**Query:** "Why does sonnet-4-5 not receive lessons injection by default?"

**Why this tests SAR:** Entry C directly answers the question but doesn't mention "sonnet-4-5". Entry B mentions "sonnet-4-5" and the config change but not the reason. Entry A has the root cause. Single-shot retrieval for "sonnet-4-5 lessons" may miss Entry C entirely because "capable" and "haiku-class" are not related surface terms.

---

## 5. Recommendation

**Close EVAL-031 as "not needed at Chump's current scale."**

Rationale:

1. **Scale mismatch:** SAR is designed for large corpora where the full candidate set cannot fit in the context window. Chump's estimated working set is small (estimate: low tens to low hundreds of rows), and the 200K token window provides ~50× slack over current memory injection budget. This mismatch is the primary disqualifier.

2. **Existing pipeline is already non-trivial:** The current retrieval is three-way RRF (FTS5 + semantic + graph), with BM25 reranking and MMR diversification. This is not "single-shot keyword filter" as characterized in the gap description — it is a meaningful hybrid pipeline.

3. **The real gap is alias resolution, not iteration:** The multi-hop failure mode documented in MEM-010 is semantic alias resolution (colloquial → formal name), not retrieval insufficiency. AutoRefine does not fix this without an alias table or embedding-based resolution. Filing MEM-010b (semantic alias resolution) would address more real failures than filing an AutoRefine implementation gap.

4. **No evidence of retrieval-miss failures:** Existing evals do not document memory retrieval misses as a failure mode. SAR would be solving an unmeasured problem.

5. **Implementation cost vs. benefit:** SAR requires the model to be in a retrieval-aware reasoning loop, which adds latency (multiple round-trips), complexity (policy or prompt to gate re-search), and inference cost. At Chump's scale, this investment is unlikely to yield measurable improvement.

**Revisit trigger:** If any of the following occur, revisit this recommendation:
- Memory row counts in production sessions regularly exceed ~500 rows per session.
- A measured eval (e.g., EVAL-034) shows retrieval misses on the MEM-008 multi-hop fixture at > 30% failure rate on causal-chain tasks (D2 chain traversal failures).
- Chump is deployed in a domain with a large external knowledge base (not just personal session memory) where corpus size would justify iterative retrieval.

---

## 6. Confidence Assessment

**Overall confidence: Medium**

| Claim | Confidence | Basis |
|---|---|---|
| Corpus is small at current scale | Medium | Estimate from codebase design; no production DB size data |
| Context window slack exists | High | 4,000 char budget vs. 200K token window is a direct calculation |
| Real gap is alias resolution, not iteration | High | Documented in MEM-010 with test evidence |
| No retrieval-miss failures observed | Low-Medium | Absence of evidence in reviewed evals; retrieval hit-rate has not been measured |
| SAR implementation would not help | Medium | Deductive reasoning from scale mismatch; no A/B comparison run |

**What would raise confidence to High:** An EVAL-034 run using the MEM-008 fixture measuring D2 (chain traversal) pass-rate on the current pipeline. If D2 pass-rate is ≥ 80% on entity-chain and causal-chain categories, the "not needed" recommendation would be well-supported. If D2 pass-rate is < 50%, the recommendation should be reversed.

---

## 7. References

- AutoRefine paper: https://openreview.net/forum?id=rBlWKIUQey (cited in gaps.yaml notes)
- `src/memory_db.rs` — FTS5 keyword search, curation pipeline
- `src/memory_tool.rs` — RRF merge, BM25 reranking, MMR diversification, context budget
- `docs/eval/MEM-008-fixture-spec.md` — multi-hop QA fixture definitions
- `docs/eval/MEM-010-results.md` — entity resolution precision/recall
- `docs/RESEARCH_INTEGRITY.md` — methodology standards (this document follows them)
