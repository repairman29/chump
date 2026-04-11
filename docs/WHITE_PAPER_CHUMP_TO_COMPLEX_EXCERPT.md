# Chump-to-Complex (excerpt for PDF)

**Source:** `docs/CHUMP_TO_COMPLEX.md` (master vision — full document remains in the repository).

This excerpt captures the **thesis**, **theoretical map**, and **inventory of shipped “consciousness modules”** without the full frontier roadmap (Section 3 in the source).

---

## Core thesis (from §0)

A standard LLM agent is framed as a **“chump”**: reactive and without a durable model of uncertainty and causal history. A **“complex”** is the target architecture: integrated beliefs, salience-broadcast across modules, counterfactual reasoning, and resource governance, grounded in physical (thermodynamic) constraints. The transition is **phased and measurable**, not a single feature flag.

## Theoretical foundations (from §1, compressed)

| Framework | Engineering proxy in Chump | Notes |
|-----------|-----------------------------|--------|
| Active Inference / FEP | `surprise_tracker` | Surprisal EMA, blackboard on spikes |
| IIT 4.0 (informal) | `phi_proxy` | Graph statistic on cross-module traffic — **not** formal Φ |
| Global Workspace | `blackboard` | Salience, broadcast into context |
| Thermodynamic AI | `precision_controller` | Regimes, energy budgets, tier hints |
| Causal reasoning | `counterfactual` | Heuristic lessons — not SCM-level Pearl |
| Associative memory | `memory_graph` | Triples, PageRank-style recall, RRF |

## Shipped modules (from §2, headline only)

The source document lists **gaps vs theory** for each of: `surprise_tracker`, `memory_graph`, `blackboard`, `counterfactual`, `precision_controller`, `phi_proxy`. The PDF defers those paragraphs to the repo to save space.

---

**Read next in repo:** `CHUMP_TO_COMPLEX.md` §3 (frontier / speculative), metrics scripts, and evaluation plans.
