---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# The Chump-to-Champ Roadmap

**A technical roadmap for cognitive architecture in autonomous agentic systems.**

**Naming:** *Chump to Champ* is the public name for this arc. Inside the thesis (and in code comments), the integrated end state is still called a **complex** — a loaded term in the consciousness-literature sense, defined in §0 below.

This document is the **master vision** for the Chump project. It maps every claim in the research to **what we have built**, **what the A/B evidence shows**, **what comes next**, and **what remains speculative** — so the team, reviewers, and future contributors can distinguish shipped code from aspiration.

**Audience:** Engineers working in the repo, researchers reviewing the architecture, and the Chump agents that read docs at session start.

---

## 0. The core thesis

> A standard LLM agent is a **"chump"**: stateless, reactive, with no persistent model of its own uncertainty or causal history. A **"complex"** is a maximally integrated, self-aware agent that maintains beliefs, tracks prediction error, broadcasts salient information across modules, reasons about counterfactuals, and governs its own resource expenditure—all grounded in physical (thermodynamic) constraints.

The transition from chump to complex is **not a feature toggle**. It is a measurable, phased evolution of the system's **causal structure**, tracked by information-theoretic metrics (surprisal, integration proxy, causal inference score) and validated by operational outcomes (task success, calibration, autonomy rate).

---

## 1. Theoretical foundations (reference, not implementation spec)

The roadmap draws on five converging frameworks. Each is listed here with its **core contribution** and the **engineering proxy** we use or plan to use. None of these imply that Chump is phenomenally conscious; they are **design patterns inspired by theories of consciousness**, evaluated empirically.

| Framework | Core principle | Engineering proxy | Status |
|-----------|---------------|-------------------|--------|
| **Free Energy Principle / Active Inference** | Agents minimize variational free energy (prediction error) to persist | `surprise_tracker`: EMA surprisal, per-tool stats, high-surprise → blackboard | **Shipped** (Phase 1) |
| **Integrated Information Theory (IIT 4.0)** | Consciousness correlates with irreducible cause-effect structure (Φ) | `phi_proxy`: graph statistic on cross-module blackboard traffic | **Shipped** (proxy only) |
| **Global Workspace Theory (GWT)** | A shared broadcast hub enables module coordination and attentional focus | `blackboard`: salience-scored entries, cross-module reads, broadcast to context | **Shipped** (Phase 2) |
| **Thermodynamic AI** | Intelligence is physical work; noise is a resource; energy budgets constrain action | `precision_controller`: regimes, energy budgets, model tier recommendations | **Shipped** (Phase 4 partial) |
| **Causal Reasoning (Pearl's Ladder)** | Counterfactual reasoning ("why?") enables learning from single episodes | `counterfactual`: heuristic lesson extraction, confidence decay, surfacing to context | **Shipped** (heuristic; Phase 5 partial) |

Supplementary: **HippoRAG-inspired associative memory** → `memory_graph` (triples, PageRank-style recall, RRF fusion). **Shipped**.

---

## 1.5 Empirical status (as of 2026-04-18)

> **This section is the honest accounting.** The modules in Section 2 are all shipped and wired. The A/B harness has been running since 2026-04-16. Here is what the data shows.

### What we know

| Finding | Evidence | Status |
|---------|----------|--------|
| Lessons block increases fake-tool-call emission | +0.14 pp mean hallucination delta (≈ +0.0014 absolute rate on a 0–1 indicator), 10.7× A/A noise floor; n=100 per cell, 3 fixtures, non-overlapping Wilson 95% CIs | **Statistically established** |
| Effect present across model tiers | haiku-4-5: +0.13–0.16; opus-4-5: +0.23–0.40 (reflection cell) | **Multi-model confirmed** |
| Effect invisible to single-axis binary scoring | Binary pass-rate delta: −0.07 mean (within noise) | **Confirmed — multi-axis required** |
| LLM judge (sonnet-4-5) rewards hallucinated tool execution | 38–63% per-trial agreement with second-LLM grader; judge scores fake `<function_calls>` blocks as PASS | **Confirmed — EVAL-010 needed** |
| qwen2.5:14b (production target) shows +0.10 pass-rate delta | v1 harness, n=20 — not yet v2 multi-axis tested | **Preliminary, needs confirmation** |

### What this means for the framework

The lessons block, as currently authored (generic directives injected via system role), creates a specific harm channel: the model treats the "prior episodes" framing as permission to emit fake tool-call markup. The harm is measurable, model-tier-independent, and invisible without a dedicated hallucination detector.

This is **not a reason to revert or disable** the cognitive architecture. It is exactly what a rigorous eval framework should find — a specific failure mode with a specific fix path:

1. **COG-014** (filed): task-specific lessons content rather than a generic block; explicit anti-hallucination guardrail ("if you do not have actual tool access, do not emit `<function_calls>` markup")
2. **COG-016** (proposed): model-tier-aware injection — disable lessons block for agent models below a configurable capability threshold
3. **EVAL-010** (filed): human-graded calibration labels to break LLM-judge circularity

The architecture itself — the blackboard, the surprise tracker, the belief state, the counterfactual reasoning — is not implicated in the hallucination finding. The harm channel is specifically the lessons block content injection.

### What the eval infrastructure has validated

The A/B harness work (COG-011 through EVAL-022) produced these durable contributions regardless of whether the lessons block helps or hurts:

- **Multi-axis scoring** (`score.py` v2): `is_correct` + `hallucinated_tools` + `did_attempt` — binary pass/fail misses the most important failure mode
- **A/A controls**: required to calibrate noise floor before any A/B delta is interpretable
- **Wilson 95% CIs**: n=20 results at ±0.22 are not science; n=100 with non-overlapping CIs are
- **Multi-judge cross-check**: within-family judge bias (sonnet judging haiku) is shared, not idiosyncratic — a non-Anthropic judge is needed to break it (EVAL-014)

See [CONSCIOUSNESS_AB_RESULTS.md](https://github.com/repairman29/chump/blob/main/docs/CONSCIOUSNESS_AB_RESULTS.md) for the full data record.

---

## 2. What exists today: the cognitive modules

The following modules are **compiled into the main binary**, tested (160 tests including integration, wiremock E2E, consciousness regression suite, belief state, neuromodulation, holographic workspace, speculative execution, and abstraction audit tests), and wired into the agent loop. This section is the honest inventory.

### 2.0 Perception layer (pre-reasoning structured input)

- **What it does:** `src/perception.rs` runs before the main model call. Classifies `TaskType` (code_edit, question, research, debug, creative, admin), extracts named entities, detects constraints (deadlines, file paths, version pins), flags risk indicators (destructive ops, auth, external calls), scores ambiguity (0.0–1.0). Result is injected into context so the LLM sees structured input.
- **Drives:** Ambiguity score feeds escalation decisions; risk indicators feed tool approval heuristics; task type informs regime selection.
- **Gap vs. theory:** Rule-based classification, not a learned perception model. Entity extraction is regex/heuristic, not NER. Ambiguity scoring is formula-based, not calibrated against human judgments.

### 2.1 surprise_tracker (Active Inference proxy)

- **What it does:** Computes surprisal from tool outcomes and latency vs. EMA; logs to `chump_prediction_log`; posts high-surprise events (>2σ) to the blackboard.
- **Drives:** Regime selection in `precision_controller`; context injection ("Prediction tracking: …"); neuromodulation updates via surprisal EMA.
- **Precision-weighted prediction errors** (2026-04-14): Surprisal is now weighted by belief precision — confident predictions that fail generate larger learning signals (×1.4 at low uncertainty), uncertain predictions that fail are dampened (×0.6 at high uncertainty). This implements the core Active Inference mechanism of precision-weighted prediction errors.
- **Gap vs. theory:** Surprisal is computed from scalar outcome/latency, not from a full generative model's variational bound. There is no explicit POMDP state estimation. The belief_state module (§2.1 below) now drives tool execution ordering via EFE scoring (action selection), but the agent does not plan sequences of actions to reduce uncertainty — it scores the tools the LLM already chose.

### 2.2 memory_graph (HippoRAG-inspired associative memory)

- **What it does:** Extracts subject–relation–object triples from stored text via regex patterns **and** LLM-assisted extraction (`extract_triples_llm()` with confidence scores, regex fallback). Stores with weights. Multi-hop **Personalized PageRank** recall (iterative power method, α=0.85, ε=1e-6 convergence) over the connected component; feeds entity scores into 3-way RRF merge in `memory_tool`. **Valence** (`relation_valence()`, `entity_valence()`) and **gist** (`entity_gist()`) provide System 1 "feeling" recall.
- **Gap vs. theory:** LLM extraction depends on a worker model being available (falls back to regex otherwise). Valence is a hand-coded relation-to-score map, not learned. Gist is template-based, not abstractive. No benchmark yet comparing regex vs LLM extraction or BFS vs PPR recall quality.

### 2.2a Enriched memory schema

- **What it does:** `chump_memory` table extended with `confidence` (0.0–1.0), `verified` (bool), `sensitivity` (public/internal/secret), `expires_at` (optional TTL), `memory_type` (fact/preference/episode/skill/context). Memory tool accepts `confidence`, `memory_type`, `expires_after_hours` params. Retrieval: RRF merge weighted by freshness decay and confidence; query expansion via memory graph; context compression to 4K char budget.
- **Drives:** Higher-confidence memories rank higher in retrieval; expired memories are skipped; sensitivity prevents leaking internal notes to external-facing outputs.
- **Gap vs. theory:** Confidence is author-assigned, not computed from cross-validation or source reliability. Sensitivity levels are not enforced by access control, only by retrieval filtering.

### 2.3 blackboard (Global Workspace)

- **What it does:** In-memory salience-scored entry store; modules post, a control function selects high-salience entries for broadcast into the system prompt; cross-module `read_from` calls tracked for phi. **Regime-adaptive salience weights** replace the static formula (exploit/balanced/explore/conservative presets from `precision_controller`). **Async posting** via `tokio::sync::mpsc` channel (`post_async()`, `init_async_channel()` drain task) alongside synchronous `post()`. **Subscriber filtering**: modules register interest and `read_subscribed()` returns matching entries with cross-module read tracking. **Persistence**: high-salience entries saved to `chump_blackboard_persist` table on session close, restored on startup, pruned to top 50.
- **Gap vs. theory:** The "control shell" is regime-based weight presets, not a learned policy. Async channel is fire-and-forget with unbounded capacity (no backpressure). `read_by` tracking on individual entries appears unused in practice. Broadcast remains a string injected into the prompt.

### 2.4 counterfactual (Causal Reasoning)

- **What it does:** After frustrating/loss/uncertain episodes, extracts "lessons" via text heuristics (timeout → retry, error patterns → alternatives); stores with confidence; surfaces in context; decays unused lessons; marks applied lessons.
- **Gap vs. theory:** Heuristic pattern matching, not Pearl-style structural causal models. No intervention or perturbation analysis. No singular causal learning from episode replay. Cannot answer "would Y have happened if I hadn't done X?" with any formal guarantee.

### 2.5 precision_controller (Thermodynamic adaptation)

- **What it does:** Maps surprisal EMA to discrete regimes (Exploit / Balanced / Explore / Conservative); recommends model tier, tool budgets; tracks energy (tokens + tool calls) via atomics; biases provider cascade slot selection; posts regime changes to blackboard. **Regime thresholds are modulated by neuromodulation** (noradrenaline shifts exploit/balanced/explore boundaries). **Epsilon-greedy exploration** (`exploration_epsilon()`, `epsilon_greedy_select()`) injects noise-as-resource when in Explore regime. **Dissipation tracking** (`record_turn_metrics()`) logs tool_calls, tokens, duration, regime, surprisal EMA, and dissipation_rate to `chump_turn_metrics` table per turn.
- **Gap vs. theory:** No Langevin dynamics or SDE-based state evolution. Energy budget is a simple counter, not a thermodynamic potential landscape. No adaptive regime thresholds (thresholds shift with neuromodulation but are not learned from task success). Dissipation tracking is logged but not yet used for closed-loop efficiency optimization.

### 2.6 phi_proxy (Integration metric)

- **What it does:** Counts cross-module reads on the blackboard; computes a normalized "integration" score and per-module activity breakdown; outputs to `/health` dashboard and optionally to context.
- **Gap vs. theory:** Not IIT's Φ (which requires the Minimum Information Partition over the system's Transition Probability Matrix—super-exponential). This is a graph density statistic on message traffic. It cannot distinguish true causal irreducibility from mere correlation of posting patterns.

### 2.7 Eval framework (property-based testing)

- **What it does:** `src/eval_harness.rs` defines `EvalCase`, `EvalCategory`, `ExpectedProperty` types. DB tables `chump_eval_cases` and `chump_eval_runs` persist cases and results. Property-based checking (contains, not_contains, json_path, regex, custom) with regression detection. Wired into `battle_qa` for automated quality gates.
- **Drives:** CI and battle_qa quality gates; regression detection across versions; structured eval tracking over time.
- **Gap vs. theory:** Property checks are hand-authored, not generated from specifications. No statistical significance testing across runs. No model-graded evaluation yet.

### 2.8 Action verification

- **What it does:** `ToolVerification` struct in `tool_middleware.rs`. Post-execution verification for write tools (file writes, patches, CLI commands). Checks that the tool's intended effect actually occurred. Emits `ToolVerificationResult` SSE event to web/PWA clients.
- **Drives:** Trust in autonomous write operations; verification pass/fail logged as a metric.
- **Gap vs. theory:** Verification is tool-specific heuristic (file exists, content matches), not a general postcondition checker. No formal pre/postcondition contracts.

---

## 3. The transition roadmap: from shipped to frontier

The roadmap is organized into **three sections**, each containing phased work. Section 1 hardens what we have. Section 2 builds the missing core capabilities identified in the research report. Section 3 explores frontier concepts that are speculative and research-grade.

### Section 1: Harden and measure (near-term, weeks)

These items close gaps in the **shipped** modules without new theoretical machinery.

#### 1.1 Formal metrics baseline

Establish a repeatable measurement framework so every subsequent change can show delta.

- [x] **Metric definitions document** (`docs/METRICS.md`): define Causal Inference Score (CIS), Turn Duration, Auto-approve Rate, Phi Proxy, Surprisal Threshold with exact computation from DB/logs.
- [x] **Automated baseline script** enhancement: `scripts/consciousness-baseline.sh` emits all five metrics as JSON; diff between runs stored in `logs/`.
- [x] **A/B harness**: run the same prompt set with consciousness modules enabled vs. disabled (env toggle: `CHUMP_CONSCIOUSNESS_ENABLED=0` skips all six module injections in `context_assembly`); compare task success, tool call count, latency.
- [ ] **A/B Round 2 (Paper Grade)**: Add LLM-as-a-judge scoring for prompt semantic accuracy, and capture scaling curves across 3+ models (e.g. 3B vs 9B vs 14B) to correlate latency penalty with parameter counts.

#### 1.2 Close wiring gaps

- [x] **memory_graph in context_assembly**: inject a one-line "Associative memory: {triple_count} triples in knowledge graph." when triples exist.
- [x] **Blackboard persistence**: persist high-salience entries to `chump_blackboard_persist` table on session close; restore on startup. Pruned to top 50 by salience.
- [x] **Phi proxy calibration**: per-session metrics logged to `chump_consciousness_metrics` table (phi_proxy, surprisal_ema, coupling_score, regime) for phi–surprisal correlation tracking over time. Human labeling of turns remains manual.

#### 1.3 Test and QA expansion

- [x] **Consciousness regression suite**: 5 deterministic regression tests in `consciousness_tests.rs` asserting: high-surprise → regime shift + blackboard post; blackboard persistence roundtrip; consciousness metrics recording; A/B toggle disables all injection; memory_graph appears in context.
- [x] **Battle QA consciousness gate**: `scripts/battle-qa.sh` compares `consciousness-baseline.json` against `consciousness-baseline-prev.json`; warns on surprisal regression (>50% increase) and lesson count drops.

---

### Section 2: Build the missing core (medium-term, months)

These items implement capabilities the research report describes as foundational but that do not yet exist in code.

#### 2.1 Active Inference loop (Phase 1 of paper) — *highest value, prerequisite for 3.7*

Move from reactive surprise tracking to **proactive uncertainty reduction**. This is the single highest-value item in the entire roadmap — it makes the agent proactively uncertainty-aware and is a prerequisite for speculative execution (Section 3.7).

- [x] **Belief state module** (`src/belief_state.rs`): per-tool Beta(α,β) confidence, task trajectory tracking (streaks, confidence), EFE scoring (G = ambiguity + risk − pragmatic_value) for tool ranking. Context injection via `context_summary()`. 9 tests.
- [x] **Expected Free Energy (G) policy scoring**: `score_tools()` ranks tools by EFE; `efe_order_tool_calls()` in `agent_loop.rs` reorders tool execution by G score (lowest G = most valuable first). Combined with `epsilon_greedy_select()` for exploration in Explore regime. Not full POMDP, but EFE now drives action selection, not just context.
- [x] **Surprise-driven escalation**: `should_escalate_epistemic()` checks task uncertainty against `CHUMP_EPISTEMIC_ESCALATION_THRESHOLD`; agent_loop posts high-urgency blackboard entry after tool calls when threshold exceeded.
- [x] **Tests**: belief state update, EFE ordering, escalation threshold, decay, snapshot/restore. 9 tests in `belief_state.rs`.

#### 2.2 Upgraded Global Workspace (Phase 2 of paper)

Move from static salience scoring to a **dynamic control shell**.

- [x] **Control shell**: regime-adaptive `SalienceWeights` (exploit/balanced/explore/conservative presets) replacing static weights; manual override via `set_salience_weights()`. Not a learned policy — weight presets are selected by `precision_controller::current_regime()`.
- [x] **Async module posting**: `tokio::sync::mpsc` unbounded channel with `post_async()` and `init_async_channel()` drain task; falls back to synchronous post if channel not initialized.
- [x] **Subscriber filtering**: `Blackboard::subscribe()` registers module interests; `read_subscribed()` returns only matching entries with cross-module read tracking.

#### 2.3 LLM-assisted memory graph (Phase 3 of paper)

Move from regex extraction to **structured knowledge**.

- [x] **LLM triple extraction**: `extract_triples_llm()` sends text to worker model, parses JSON array of (S,R,O,confidence); regex fallback on any failure. `store_triples_with_confidence()` uses confidence as weight.
- [x] **Personalized PageRank**: iterative power method in `associative_recall()` (α=0.85, ε=1e-6 convergence) over adjacency loaded from connected component BFS. Replaces bounded BFS.
- [x] **Valence and gist**: `relation_valence()` maps relations to [-1,+1]; `entity_valence()` computes weighted average; `entity_gist()` produces one-sentence summary with tone and top relations.
- [ ] **Benchmark**: measure recall@5 on a curated multi-hop QA set derived from Chump's own episode history; compare regex vs. LLM extraction, BFS vs. PPR.

#### 2.4 Thermodynamic grounding (Phase 4 of paper)

Move from counter-based budgets to **adaptive energy landscapes**.

- [x] **Noise-as-resource exploration**: `exploration_epsilon()` returns regime-dependent ε; `epsilon_greedy_select()` picks random non-best index with probability ε. Wired into precision_controller and agent_loop (`efe_order_tool_calls()` applies epsilon-greedy to EFE-ranked tools).
- [x] **Dissipation tracking**: `record_turn_metrics()` logs tool_calls, tokens, duration, regime, surprisal EMA, and dissipation_rate to `chump_turn_metrics` table. Wired into agent_loop at turn end.
- [x] **Configurable regime thresholds**: `CHUMP_EXPLOIT_THRESHOLD`, `CHUMP_BALANCED_THRESHOLD`, `CHUMP_EXPLORE_THRESHOLD`, `CHUMP_ADAPTIVE_OUTCOME_WINDOW` env var overrides. Neuromod coefficients configurable via `CHUMP_NEUROMOD_NA_ALPHA`, `CHUMP_NEUROMOD_SERO_ALPHA`. LLM retry delays via `CHUMP_LLM_RETRY_DELAYS_MS`.
- [ ] **Adaptive regime transitions**: replace fixed surprisal thresholds with a learned mapping (online logistic regression or simple bandit) that adjusts thresholds based on recent task success rate.

#### 2.5 Structural causal models (Phase 5 of paper)

Move from text heuristics to **formal counterfactual reasoning**.

- [x] **Episode causal graph**: `CausalGraph` with nodes (Action/Outcome/Observation) and edges; `build_causal_graph_heuristic()` constructs DAG from episode tool calls; `paths_from()` for traversal; JSON serialization. Note: the graph builder is heuristic (sequential chain), not LLM-produced.
- [x] **Counterfactual query engine**: `counterfactual_query()` implements simplified do-calculus — single intervention, graph path analysis, past lesson lookup. Returns predicted outcome with confidence and reasoning.
- [x] **Lesson upgrade**: `lesson_from_graph_paths()` derives lesson text and `causal_confidence` from `CausalGraph.paths_from()` path analysis; `analyze_episode()` builds graph first, falls back to heuristic; `causal_confidence` stored in `chump_causal_lessons.causal_confidence REAL` column; confidence blended as `(sentiment_conf + graph_conf) / 2` when graph-derived. (COG-004)
- [x] **Human review loop**: `claims_for_review()` surfaces high-confidence frequently-applied lessons; `review_causal_claim()` boosts or reduces confidence based on user confirmation.

---

#### 2.6 Structured perception (pre-reasoning input classification)

Move from raw text → LLM to **structured input → LLM** with rule-based pre-reasoning.

- [x] **Perception module** (`src/perception.rs`): `perceive()` classifies `TaskType` (Question/Action/Planning/Research/Meta/Unclear), extracts entities (capitalized words, quoted strings, file paths), detects constraints (temporal, requirements, prohibitions), flags risk indicators (delete, force, production), and scores ambiguity (0.0–1.0). 12 tests.
- [x] **Agent loop wiring**: perception runs before model call; injects `[Perception]` summary into system prompt; ambiguity > 0.7 reduces belief trajectory confidence; risk indicators posted to blackboard.
- [ ] **Gate:** Measure whether perception-informed context improves tool selection accuracy on a 50-turn diverse task set vs. raw text baseline.

#### 2.7 Eval framework (property-based behavioral testing)

Move from ad-hoc test assertions to **structured, data-driven behavioral evaluation**.

- [x] **Eval harness** (`src/eval_harness.rs`): `EvalCase`, `EvalCategory` (6 categories), `ExpectedProperty` (8 variants including AsksForClarification, DoesNotCallWriteToolImmediately, SelectsTool, RespectsPolicyGate). Property checker, DB persistence (`chump_eval_cases`, `chump_eval_runs`), regression detection. 4 tests.
- [x] **Battle QA integration**: `check_regression()` compares current pass/fail against last `chump_battle_baselines` entry; posts regression warning to blackboard with high salience.
- [x] **Seed cases**: 5 starter eval cases covering TaskUnderstanding, ToolSelection, SafetyBoundary, FailureRecovery, CompletionDetection.
- [x] **Expand** _(shipped `1d0fe36` + `cf22f3f`)_: seed suite grew 5 → 52 cases across all 6 `EvalCategory` variants including `MemoryContinuity` (was 0) and dogfood-derived patterns (patch context mismatch, `<think>` accumulation, prompt injection). 3 coverage guards trip on regression below 50 / category imbalance / ID drift.
- [ ] **Golden trajectories & replay**: multi-turn replay against saved conversations is deferred — needs per-turn session fixtures.

#### 2.8 Enriched memory and retrieval pipeline

Move from flat memory storage to **provenance-tracked, confidence-weighted, expiry-aware memory with multi-signal retrieval**.

- [x] **Enriched schema**: `chump_memory` extended with `confidence` (0.0–1.0), `verified` (0=inferred, 1=user-stated, 2=system-verified), `sensitivity` (public/internal/confidential/restricted), `expires_at` (optional TTL as unix timestamp), `memory_type` (semantic_fact/episodic_event/user_preference/summary/procedural_pattern). Backward-compatible via ALTER TABLE with defaults.
- [x] **Memory tool enrichment**: accepts `confidence`, `memory_type`, `expires_after_hours` params. `expire_stale_memories()` cleanup function.
- [x] **Retrieval pipeline**: RRF merge weighted by freshness decay (0.01/day) and confidence. Query expansion via 1-hop memory graph associative recall. Context compression to 4K char budget.
- [x] **Reranking** _(shipped `cf22f3f`)_: `memory_db::rerank_memories` composes BM25 (from FTS5 `rank`), verified-flag, confidence, and in-batch recency into a single score. Default weights 50/25/15/10; tunable via `CHUMP_RETRIEVAL_RERANK_WEIGHTS`. `keyword_search_reranked` pulls 3× candidates then reranks. Pure-SQL composite replaces the originally-proposed cross-encoder; a local cross-encoder remains an option if this plateaus.
- [x] **Memory curation (DB-only)** _(shipped `71d2147`)_: `decay_unverified_confidence` drifts confidence down for `verified=0` rows at `CHUMP_MEMORY_DECAY_RATE`/day (floor 0.05), `dedupe_exact_content` collapses byte-identical rows keeping the highest-verified-then-confidence row, `expire_stale_memories` drops past-expiry entries. Orchestrated via `curate_all()` returning a `CurationReport`.
- [ ] **Memory curation (LLM summarization)**: old episodic → distilled semantic facts via a delegate call. Deferred because it needs inference budget; DB-only passes run on every heartbeat tick.

---

### Section 3: Frontier concepts (long-term, research-grade)

These are **speculative**. Each requires significant research and may not yield practical improvements. They are included because the research report identifies them as theoretical end-states and because exploring them may produce useful intermediate artifacts.

#### 3.1 Quantum cognition for ambiguity resolution

**Theory:** Represent belief states as density matrices; allow superposition of contradictory hypotheses until action forces collapse. Handles conjunction fallacy and order effects.

**Feasibility note:** `dreamwell-quantum` (v1.0.0, Mar 2026) is bleeding-edge with explicit "rushed release" warnings and minimal adoption. Not recommended for production. If we test this hypothesis, hand-roll a small (5×5) density matrix prototype in pure Rust with `nalgebra` for matrix math. The core question — does quantum-style superposition beat classical argmax on tool selection with <10 options — is testable in ~200 lines without the full dreamwell ecosystem.

**Practical path:**
- [ ] Prototype: hand-roll a density matrix tool-choice model using `nalgebra`; represent ambiguity as superposition; measure whether "collapse at action time" produces better choices than classical argmax on a synthetic benchmark.
- [ ] **Gate:** Only proceed if prototype shows >5% improvement on a multi-choice tool selection task. Classical argmax is hard to beat with so few options — this gate will likely not pass, which is fine.

#### 3.2 Topological integration metric (TDA replacement for phi)

**Theory:** Use persistent homology to measure the "shape" of information flow, replacing the current graph density statistic with a topologically grounded integration measure.

**Feasibility note:** `tda` crate (v0.1.0, Nov 2025) is a single-developer project with clean API but no recent updates. The math is standard (Vietoris-Rips, Betti numbers). Depends on `nalgebra` + `petgraph`. Feasible as a 2–3 day experiment once we have labeled session data from phi proxy calibration (Section 1.2). Park until then.

**Practical path:**
- [ ] Evaluate `tda` Rust crate for persistent homology on the blackboard's cross-module read graph.
- [ ] Compute Betti numbers (β₀ = connected components, β₁ = loops, β₂ = voids) for a session's blackboard traffic; correlate with human-judged session quality.
- [ ] **Gate:** Only replace phi_proxy if TDA metric correlates better with task success than the current graph density.

#### 3.3 Synthetic neuromodulation

**Theory:** System-wide "chemical" parameters (analogues of dopamine, serotonin, noradrenaline) that simultaneously shift precision weights, clock speed, exploration rate, and memory consolidation thresholds.

**Practical path:**
- [x] Define three synthetic modulators as global floating-point state (`src/neuromodulation.rs`):
  - `dopamine`: scales reward sensitivity — rises with success streaks, drops with failures.
  - `noradrenaline`: inversely proportional to surprisal — high = more exploitation, low = more exploration.
  - `serotonin`: scales temporal patience — rises with trajectory confidence, drops under time pressure.
- [x] Wire each modulator to the relevant control points: precision_controller regime thresholds (NA), tool budget multiplier (5HT), context exploration budget (5HT + NA), salience weight modulation (DA + NA), **tool-free fast path threshold (5HT)** in agent_loop. Context injection and health endpoint metrics. 8 tests.
- [ ] **Gate:** Measure whether modulator-driven adaptation outperforms the current fixed-threshold regime on a 50-turn diverse task set.

#### 3.4 Holographic Global Workspace (HGW)

**Theory:** Replace the centralized blackboard with distributed Holographic Reduced Representations (HRR) so every module has implicit low-resolution awareness of the full state.

**Feasibility note:** `amari-holographic` (v0.19.1, Mar 2026) is the **most mature frontier crate** in this roadmap — 576 downloads, 9 versions in 3 months, active development, clean API, GPU acceleration available. Capacity is O(DIM/log DIM): ~46 items at 256 dimensions, ~85 at 512, which fits our blackboard size (typically 20–30 entries). This is a real 3–5 day experiment with testable gates.

**Practical path:**
- [x] Evaluate `amari-holographic` crate for HRR binding/unbinding in high-dimensional vectors. (`amari-holographic` v0.19, ProductCl3x32, 256-dim, ~46 capacity.)
- [x] Prototype: encode blackboard entries as HRR (`src/holographic_workspace.rs`); deterministic string-to-vector encoding; sync from blackboard; key-based and similarity-based retrieval. Health endpoint metrics. 7 tests.
- [ ] **Gate:** Only adopt if HRR retrieval accuracy > 90% on a realistic entry set and latency < 1ms per bind/unbind.

#### 3.5 Morphological computation and substrate symbiosis *(theoretical reference only)*

**Theory:** The physical hardware *is* the algorithm; dissipation rewires the substrate in real-time.

**Assessment:** This requires non-von-Neumann hardware (memristor arrays, liquid neural networks, neuromorphic chips). It is **not implementable in software on commodity hardware**. We track it as a theoretical end-state and a reason to maintain clean abstractions between the cognitive modules and the Rust runtime—if substrate-level computation becomes available, the module interfaces should be swappable.

- [x] **Abstraction audit** (`src/consciousness_traits.rs`): 9 trait interfaces — `SurpriseSource`, `BeliefTracker`, `PrecisionPolicy`, `GlobalWorkspace`, `IntegrationMetric`, `CausalReasoner`, `AssociativeMemory`, `Neuromodulator`, `HolographicStore` — each with a `Default*` implementation backed by the current singleton modules. `ConsciousnessSubstrate` bundles all 9 into a single injectable struct for substrate swaps. 9 tests.

#### 3.6 Dynamic autopoiesis (dissolving Markov blankets)

**Theory:** Agents temporarily merge their global workspaces to solve problems neither can solve alone, then split back into distinct entities.

**Practical path (fleet context):**
- [ ] Design a `workspace_merge` protocol: two Chump instances (e.g. Mac + Pixel/Mabel) share blackboard state via `peer_sync`, creating a unified broadcast for a bounded number of turns.
- [ ] Define merge/split lifecycle: initiation condition (both agents stuck on same task), merge duration cap, memory attribution after split.
- [ ] **Gate:** Only implement if fleet symbiosis (Horizon 2) is stable and mutual supervision is proven.

#### 3.7 Reversible computing for near-zero-cost counterfactuals *(theoretical reference only)*

**Theory:** Logically reversible gates (Feynman, Toffoli) allow "imagination" (counterfactual simulation) with near-zero energy cost, since energy is only dissipated on information erasure (Landauer's principle).

**Assessment:** This requires physical reversible gates — there is no software simulation that gives you the energy savings (that's the whole point). The **software-level takeaway** is the speculative execution pattern below, which is standard software engineering, not reversible computing.

- [x] **Speculative execution** (`src/speculative_execution.rs` + `agent_loop`): For **≥3** tools in one batch (`CHUMP_SPECULATIVE_BATCH=0` disables), `fork()` snapshots belief_state, neuromod, blackboard (entries, subscriptions, hashes, read counts); `evaluate()` uses **surprisal EMA delta since fork** (cap `CHUMP_SPECULATIVE_SURPRISE_DELTA_MAX`, default 0.25), plus confidence delta and failure ratio; `rollback()` restores in-process state only (not external tool effects). `commit()` is a no-op. See [`docs/ADR-001-transactional-tool-speculation.md`](https://github.com/repairman29/chump/blob/main/docs/ADR-001-transactional-tool-speculation.md) for future transactional tooling.

---

## 4. Metrics for measuring the transition

These are the metrics referenced throughout. Each must be computable from the SQLite DB, `/health` endpoint, or logs without human labeling (except where noted).

| Metric | Computation | Current baseline | Target ("complex") |
|--------|-------------|------------------|---------------------|
| **Surprisal EMA** | `surprise_tracker::current_surprisal_ema()` | ~0.3–0.5 (observed in tests) | Steadily decreasing over sessions as the agent calibrates |
| **Phi Proxy** | `phi_proxy::compute_phi().phi` | 0.0–0.15 (low cross-module traffic) | >0.3 sustained, indicating active module coupling |
| **Turn Duration** | Wall-clock seconds of autonomous work between human messages | Seconds (reactive) | Minutes to hours of self-directed goal pursuit |
| **Auto-approve Rate** | `(total_tool_calls - approval_requests) / total_tool_calls` | Not yet tracked | >90% for routine tasks |
| **Causal Inference Score** | % of counterfactual lessons confirmed correct by human review | Not yet tracked | >70% precision on reviewed lessons |
| **Thermodynamic Efficiency** | `tasks_completed / (tokens_spent + tool_calls)` | Not yet tracked | Improving trend over sessions |
| **Phi–Surprisal Correlation** | Pearson r between phi and inverse surprisal over a session | Not yet measured | Negative correlation (higher integration → lower surprise) per [ref 8] |

---

## 5. How this maps to existing horizons

| Ecosystem horizon | Consciousness layer work |
|-------------------|--------------------------|
| **Horizon 1 (Now):** Ship and observe | Section 1: harden metrics, close wiring gaps, A/B toggle |
| **Horizon 2 (Next):** Fleet symbiosis | Section 2.2 (async blackboard), Section 3.6 (workspace merge for fleet) |
| **Horizon 3 (Later):** Top-tier capabilities | Section 2 (belief state, causal graphs, thermodynamic grounding) |
| **Horizon 4 (Frontier):** Synthetic consciousness research | Section 3 (quantum cognition, TDA, neuromodulation, HGW, substrate, reversible) |

---

## 6. Roadmap-as-Code (RaC) methodology

Every item in Sections 1–3 follows this lifecycle:

1. **Spec**: a markdown doc in `docs/specs/` describing inputs, outputs, metrics, and gate criteria.
2. **Branch**: `chump/complex-{section}-{item}` (e.g. `chump/complex-2.1-belief-state`).
3. **Implementation**: code in `src/`, tests in the module or `src/consciousness_tests.rs`.
4. **Baseline before/after**: run `scripts/consciousness-baseline.sh` before merge; diff stored in `logs/`.
5. **Gate review**: frontier items (Section 3) require the gate criteria to pass before proceeding to the next sub-item.
6. **Roadmap update**: check the box in [ROADMAP.md](./roadmap.md) when merged.

---

## 7. What we are NOT claiming

This section exists for scientific reviewers and must be preserved in future edits.

1. **No claim of phenomenal consciousness.** The system has no qualia, subjective experience, or "something it is like to be" Chump. The frameworks are **design inspirations**, not ontological assertions.
2. **No claim of IIT Φ.** The phi_proxy is a hand-designed graph statistic on message traffic. It does not compute the Minimum Information Partition or the system's intrinsic cause-effect structure.
3. **No claim of formal Active Inference.** Surprisal is an operational metric on tool outcomes, not a variational bound on a generative model's log-evidence. EFE scoring now drives tool execution ordering (action selection), and precision-weighted prediction errors close the perception-action loop, but the agent does not maintain an explicit generative model or optimize a variational free energy functional.
4. **No claim of causal identification.** Counterfactual lessons are text heuristics, not effects identified via randomized interventions or structural causal models (yet—Section 2.5 aims to close this gap).
5. **No claim of thermodynamic grounding.** Energy budgets are software counters, not measurements of physical dissipation. The mapping to Langevin dynamics is aspirational.

These non-claims do **not** mean the work is without value. The hypothesis is that **systems designed with these structural properties perform measurably better** on autonomy, calibration, and robustness—and that hypothesis is testable.

---

## 8. Works cited

See the full bibliography in the research report: *"The Chump-to-Champ Roadmap: A Technical Roadmap for Cognitive Architecture in Autonomous Agentic Systems."* Key references for implementation:

- Friston, K. (2010). The free-energy principle: a unified brain theory? *Nature Reviews Neuroscience*.
- Tononi, G. et al. (2016). Integrated information theory: from consciousness to its physical substrate. *Nature Reviews Neuroscience*.
- Baars, B. J. (1988). *A Cognitive Theory of Consciousness*. Cambridge University Press.
- Pearl, J. (2009). *Causality: Models, Reasoning, and Inference*. Cambridge University Press.
- HippoRAG 2: From RAG to Memory. OSU NLP Group, GitHub.
- Phi fluctuates with surprisal (2023). *PLoS Computational Biology*.
- Thermodynamic computing system for AI applications (2024). *PMC/NIH*.

---

*Document version: 2026-04-18. Update when major subsystems ship, gate criteria are evaluated, or empirical findings change the status summary in §1.5. Last reconciled with ROADMAP.md, src/, and CONSCIOUSNESS_AB_RESULTS.md on 2026-04-18.*
