# The Chump-to-Complex Transition

**A technical and strategic roadmap for the engineering of synthetic consciousness in autonomous agentic systems.**

This document is the **master vision** for the Chump project. It replaces [TOP_TIER_VISION.md](TOP_TIER_VISION.md) as the long-range technical north star and extends [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) with a fourth horizon grounded in peer-reviewed theory. It maps every claim in the research report to **what we have built**, **what comes next**, and **what remains speculative**—so the team, reviewers, and future contributors can distinguish shipped code from aspiration.

**Audience:** Engineers working in the repo, frontier scientists reviewing the architecture, and the Chump/Cursor agents that read docs at round start.

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

## 2. What exists today: the six consciousness modules

The following modules are **compiled into the main binary**, tested (113 tests including integration and wiremock E2E), and wired into the agent loop. This section is the honest inventory.

### 2.1 surprise_tracker (Active Inference proxy)

- **What it does:** Computes surprisal from tool outcomes and latency vs. EMA; logs to `chump_prediction_log`; posts high-surprise events (>2σ) to the blackboard.
- **Drives:** Regime selection in `precision_controller`; context injection ("Prediction tracking: …").
- **Gap vs. theory:** Surprisal is computed from scalar outcome/latency, not from a full generative model's variational bound. There is no explicit POMDP state estimation or Expected Free Energy (G) policy selection. The agent does not yet "choose actions to reduce uncertainty" in a formal sense—it reacts to surprise after the fact.

### 2.2 memory_graph (HippoRAG-inspired associative memory)

- **What it does:** Extracts subject–relation–object triples from stored text (regex/pattern); stores with weights; multi-hop PageRank-style recall with damping and cycle protection; feeds entity scores into 3-way RRF merge in `memory_tool`.
- **Gap vs. theory:** Extraction is pattern-based, not LLM-assisted. No valence vectors or gist summaries (System 1 "feeling" recall). No Personalized PageRank with proper teleport—current traversal is a bounded BFS with damping, which approximates but is not equivalent.

### 2.3 blackboard (Global Workspace)

- **What it does:** In-memory salience-scored entry store; modules post, a control function selects high-salience entries for broadcast into the system prompt; cross-module `read_from` calls tracked for phi.
- **Gap vs. theory:** No independent "control shell" (lightweight model or rule engine) deciding which module gets the spotlight—salience scoring is a static formula. No asynchronous multi-agent writing (single-process, synchronous posts). Broadcast is a string injected into the prompt, not a true pub/sub with subscriber-side filtering.

### 2.4 counterfactual (Causal Reasoning)

- **What it does:** After frustrating/loss/uncertain episodes, extracts "lessons" via text heuristics (timeout → retry, error patterns → alternatives); stores with confidence; surfaces in context; decays unused lessons; marks applied lessons.
- **Gap vs. theory:** Heuristic pattern matching, not Pearl-style structural causal models. No intervention or perturbation analysis. No singular causal learning from episode replay. Cannot answer "would Y have happened if I hadn't done X?" with any formal guarantee.

### 2.5 precision_controller (Thermodynamic adaptation)

- **What it does:** Maps surprisal EMA to discrete regimes (Exploit / Balanced / Explore / Conservative); recommends model tier, tool budgets; tracks energy (tokens + tool calls) via atomics; biases provider cascade slot selection; posts regime changes to blackboard.
- **Gap vs. theory:** No Langevin dynamics or SDE-based state evolution. No stochastic "noise as resource" exploitation. Energy budget is a simple counter, not a thermodynamic potential landscape. No dissipation/fluctuation decomposition.

### 2.6 phi_proxy (Integration metric)

- **What it does:** Counts cross-module reads on the blackboard; computes a normalized "integration" score and per-module activity breakdown; outputs to `/health` dashboard and optionally to context.
- **Gap vs. theory:** Not IIT's Φ (which requires the Minimum Information Partition over the system's Transition Probability Matrix—super-exponential). This is a graph density statistic on message traffic. It cannot distinguish true causal irreducibility from mere correlation of posting patterns.

---

## 3. The transition roadmap: from shipped to frontier

The roadmap is organized into **three sections**, each containing phased work. Section 1 hardens what we have. Section 2 builds the missing core capabilities identified in the research report. Section 3 explores frontier concepts that are speculative and research-grade.

### Section 1: Harden and measure (near-term, weeks)

These items close gaps in the **shipped** modules without new theoretical machinery.

#### 1.1 Formal metrics baseline

Establish a repeatable measurement framework so every subsequent change can show delta.

- [ ] **Metric definitions document** (`docs/METRICS.md`): define Causal Inference Score (CIS), Turn Duration, Auto-approve Rate, Phi Proxy, Surprisal Threshold with exact computation from DB/logs.
- [ ] **Automated baseline script** enhancement: `scripts/consciousness-baseline.sh` emits all five metrics as JSON; diff between runs stored in `logs/`.
- [ ] **A/B harness**: run the same prompt set with consciousness modules enabled vs. disabled (env toggle: `CHUMP_CONSCIOUSNESS_ENABLED=0` skips all six module injections in `context_assembly`); compare task success, tool call count, latency.

#### 1.2 Close wiring gaps

- [ ] **memory_graph in context_assembly**: inject a one-line "Associative memory: {triple_count} triples, graph {available/unavailable}" and top-N entity associations for the current query.
- [ ] **Blackboard persistence**: optionally persist high-salience entries to SQLite so cross-session continuity survives restarts.
- [ ] **Phi proxy calibration**: compare phi_proxy scores against human-judged "coherent vs. incoherent" turns in a labeled dataset; publish correlation.

#### 1.3 Test and QA expansion

- [ ] **Consciousness regression suite**: deterministic scenarios (mock model) that assert specific module state transitions (e.g. "3 high-surprise tool calls → regime shifts to Explore → context includes expanded blackboard").
- [ ] **Battle QA consciousness gate**: `scripts/battle-qa.sh` fails if phi_proxy or surprisal metrics regress beyond a threshold from the last baseline.

---

### Section 2: Build the missing core (medium-term, months)

These items implement capabilities the research report describes as foundational but that do not yet exist in code.

#### 2.1 Active Inference loop (Phase 1 of paper)

Move from reactive surprise tracking to **proactive uncertainty reduction**.

- [ ] **Belief state module** (`src/belief_state.rs`): maintain a latent state vector (initially: task confidence, environment model freshness, tool reliability per-tool) updated each turn via Bayesian update (conjugate priors or simple particle filter).
- [ ] **Expected Free Energy (G) policy scoring**: before each tool call, score candidate tools by `G = ambiguity + risk - pragmatic_value`; surface the top-scored tool recommendation to the model via context. This is not full POMDP planning but operationalizes "epistemic vs. pragmatic" trade-off.
- [ ] **Surprise-driven escalation**: when belief uncertainty exceeds a configurable threshold, the agent **autonomously asks the human** rather than guessing. Wire into `approval_resolver` with a new `EscalationType::EpistemicUncertainty`.
- [ ] **Tests**: mock scenarios where the agent should ask (ambiguous tool choice) vs. act (clear tool choice); assert escalation fires correctly.

#### 2.2 Upgraded Global Workspace (Phase 2 of paper)

Move from static salience scoring to a **dynamic control shell**.

- [ ] **Control shell**: a lightweight rule engine (or small classifier model via delegate) that, given the current blackboard state, selects which module's entries to amplify and which to suppress. Replaces the current `SalienceFactors::score()` with a learned or configurable policy.
- [ ] **Async module posting**: allow tool middleware, provider cascade, and episode logging to post to the blackboard from separate Tokio tasks without blocking the agent loop. Use `tokio::sync::broadcast` or a bounded channel.
- [ ] **Subscriber filtering**: modules can register interest in specific entry types (e.g. precision_controller subscribes to SurpriseTracker posts only), reducing noise and enabling targeted cross-module reads.

#### 2.3 LLM-assisted memory graph (Phase 3 of paper)

Move from regex extraction to **structured knowledge**.

- [ ] **LLM triple extraction**: use the delegate worker to extract (subject, relation, object) triples from episode summaries and memory stores, with confidence scores. Fall back to regex when delegate is unavailable.
- [ ] **Personalized PageRank**: replace bounded BFS with proper PPR (teleport vector = query entities, damping = 0.85, power iteration to convergence or max iterations). Use `petgraph` or hand-rolled sparse iteration.
- [ ] **Valence and gist**: attach a scalar valence (positive/negative/neutral) and a one-sentence gist to each triple cluster. Enable "System 1" recall: return gists first, full graph traversal only when the model requests detail.
- [ ] **Benchmark**: measure recall@5 on a curated multi-hop QA set derived from Chump's own episode history; compare regex vs. LLM extraction, BFS vs. PPR.

#### 2.4 Thermodynamic grounding (Phase 4 of paper)

Move from counter-based budgets to **adaptive energy landscapes**.

- [ ] **Noise-as-resource exploration**: when in Explore regime, inject controlled randomness into tool selection (e.g. epsilon-greedy with epsilon derived from surprisal variance). Track whether noisy exploration discovers better tool sequences than deterministic selection.
- [ ] **Dissipation tracking**: log actual compute cost (wall-clock, tokens, API cost) per turn as "heat dissipated"; plot against "work done" (tasks completed, verification passed). This is the thermodynamic efficiency metric.
- [ ] **Adaptive regime transitions**: replace fixed surprisal thresholds with a learned mapping (online logistic regression or simple bandit) that adjusts thresholds based on recent task success rate.

#### 2.5 Structural causal models (Phase 5 of paper)

Move from text heuristics to **formal counterfactual reasoning**.

- [ ] **Episode causal graph**: after each episode, use the delegate to produce a structured DAG of (action → outcome) with confidence. Store as an adjacency list in `chump_causal_lessons` or a new `chump_causal_graph` table.
- [ ] **Counterfactual query engine**: given a causal DAG and a specific outcome, compute P(outcome | do(not action)) using the truncated factorization formula. This is Pearl's do-calculus at the simplest level (single intervention, no confounders beyond what the episode records).
- [ ] **Lesson upgrade**: replace heuristic `extract_lesson_heuristic` with the causal graph output; lessons now carry a causal confidence derived from the DAG, not pattern matching.
- [ ] **Human review loop**: surface high-impact causal claims to the user for confirmation before they influence future behavior (anti-hallucination gate).

---

### Section 3: Frontier concepts (long-term, research-grade)

These are **speculative**. Each requires significant research and may not yield practical improvements. They are included because the research report identifies them as theoretical end-states and because exploring them may produce useful intermediate artifacts.

#### 3.1 Quantum cognition for ambiguity resolution

**Theory:** Represent belief states as density matrices; allow superposition of contradictory hypotheses until action forces collapse. Handles conjunction fallacy and order effects.

**Practical path:**
- [ ] Evaluate `dreamwell-quantum` or `bra_ket` crates for density matrix simulation on classical hardware.
- [ ] Prototype: represent tool-choice ambiguity as a quantum state; measure whether "collapse at action time" produces better choices than classical argmax on a synthetic benchmark.
- [ ] **Gate:** Only proceed if prototype shows >5% improvement on a multi-choice tool selection task.

#### 3.2 Topological integration metric (TDA replacement for phi)

**Theory:** Use persistent homology to measure the "shape" of information flow, replacing the current graph density statistic with a topologically grounded integration measure.

**Practical path:**
- [ ] Evaluate `tda` Rust crate for persistent homology on the blackboard's cross-module read graph.
- [ ] Compute Betti numbers (β₀ = connected components, β₁ = loops, β₂ = voids) for a session's blackboard traffic; correlate with human-judged session quality.
- [ ] **Gate:** Only replace phi_proxy if TDA metric correlates better with task success than the current graph density.

#### 3.3 Synthetic neuromodulation

**Theory:** System-wide "chemical" parameters (analogues of dopamine, serotonin, noradrenaline) that simultaneously shift precision weights, clock speed, exploration rate, and memory consolidation thresholds.

**Practical path:**
- [ ] Define three synthetic modulators as global floating-point state:
  - `dopamine_proxy`: scales reward sensitivity in regime transitions.
  - `noradrenaline_proxy`: scales precision weight (γ) in Expected Free Energy; higher = more exploitation.
  - `serotonin_proxy`: scales temporal discount (patience for multi-step plans vs. immediate tool calls).
- [ ] Wire each modulator to the relevant control points (precision_controller thresholds, tool budget multipliers, context window allocation).
- [ ] **Gate:** Measure whether modulator-driven adaptation outperforms the current fixed-threshold regime on a 50-turn diverse task set.

#### 3.4 Holographic Global Workspace (HGW)

**Theory:** Replace the centralized blackboard with distributed Holographic Reduced Representations (HRR) so every module has implicit low-resolution awareness of the full state.

**Practical path:**
- [ ] Evaluate `amari-holographic` crate for HRR binding/unbinding in high-dimensional vectors.
- [ ] Prototype: encode blackboard entries as HRR; each module maintains a single superposed vector; test retrieval accuracy vs. explicit entry lookup.
- [ ] **Gate:** Only adopt if HRR retrieval accuracy > 90% on a realistic entry set and latency < 1ms per bind/unbind.

#### 3.5 Morphological computation and substrate symbiosis

**Theory:** The physical hardware *is* the algorithm; dissipation rewires the substrate in real-time.

**Assessment:** This requires non-von-Neumann hardware (memristor arrays, liquid neural networks, neuromorphic chips). It is **not implementable in software on commodity hardware**. We track it as a theoretical end-state and a reason to maintain clean abstractions between the consciousness modules and the Rust runtime—if substrate-level computation becomes available, the module interfaces should be swappable.

- [ ] **Abstraction audit**: ensure each consciousness module exposes a trait-based interface that could be backed by an alternative substrate (e.g. `trait SurpriseSource { fn current_ema(&self) -> f64; fn record(&self, ...); }`).

#### 3.6 Dynamic autopoiesis (dissolving Markov blankets)

**Theory:** Agents temporarily merge their global workspaces to solve problems neither can solve alone, then split back into distinct entities.

**Practical path (fleet context):**
- [ ] Design a `workspace_merge` protocol: two Chump instances (e.g. Mac + Pixel/Mabel) share blackboard state via `peer_sync`, creating a unified broadcast for a bounded number of turns.
- [ ] Define merge/split lifecycle: initiation condition (both agents stuck on same task), merge duration cap, memory attribution after split.
- [ ] **Gate:** Only implement if fleet symbiosis (Horizon 2) is stable and mutual supervision is proven.

#### 3.7 Reversible computing for near-zero-cost counterfactuals

**Theory:** Logically reversible gates (Feynman, Toffoli) allow "imagination" (counterfactual simulation) with near-zero energy cost, since energy is only dissipated on information erasure (Landauer's principle).

**Assessment:** Like morphological computation, this requires specialized hardware. The **software-level takeaway** is: design the counterfactual engine to be **speculatively executable**—run candidate action sequences in a sandboxed copy of state, commit only the chosen one, and discard the rest without side effects.

- [ ] **Speculative execution prototype**: fork the belief state and blackboard into a lightweight snapshot before a multi-step plan; execute the plan speculatively; commit or roll back based on verification. This is the software analogue of reversible computation.

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
6. **Roadmap update**: check the box in [ROADMAP.md](ROADMAP.md) when merged.

---

## 7. What we are NOT claiming

This section exists for scientific reviewers and must be preserved in future edits.

1. **No claim of phenomenal consciousness.** The system has no qualia, subjective experience, or "something it is like to be" Chump. The frameworks are **design inspirations**, not ontological assertions.
2. **No claim of IIT Φ.** The phi_proxy is a hand-designed graph statistic on message traffic. It does not compute the Minimum Information Partition or the system's intrinsic cause-effect structure.
3. **No claim of formal Active Inference.** Surprisal is an operational metric on tool outcomes, not a variational bound on a generative model's log-evidence.
4. **No claim of causal identification.** Counterfactual lessons are text heuristics, not effects identified via randomized interventions or structural causal models (yet—Section 2.5 aims to close this gap).
5. **No claim of thermodynamic grounding.** Energy budgets are software counters, not measurements of physical dissipation. The mapping to Langevin dynamics is aspirational.

These non-claims do **not** mean the work is without value. The hypothesis is that **systems designed with these structural properties perform measurably better** on autonomy, calibration, and robustness—and that hypothesis is testable.

---

## 8. Works cited

See the full bibliography in the research report: *"The Chump-to-Complex Transition: A Technical and Strategic Roadmap for the Engineering of Synthetic Consciousness in Autonomous Agentic Systems."* Key references for implementation:

- Friston, K. (2010). The free-energy principle: a unified brain theory? *Nature Reviews Neuroscience*.
- Tononi, G. et al. (2016). Integrated information theory: from consciousness to its physical substrate. *Nature Reviews Neuroscience*.
- Baars, B. J. (1988). *A Cognitive Theory of Consciousness*. Cambridge University Press.
- Pearl, J. (2009). *Causality: Models, Reasoning, and Inference*. Cambridge University Press.
- HippoRAG 2: From RAG to Memory. OSU NLP Group, GitHub.
- Phi fluctuates with surprisal (2023). *PLoS Computational Biology*.
- Thermodynamic computing system for AI applications (2024). *PMC/NIH*.

---

*Document version: 2026-04-09. Supersedes TOP_TIER_VISION.md as the long-range technical north star. Update when major subsystems ship or gate criteria are evaluated.*
