---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Neuromodulation ↔ precision (WP-6.2)

**Scope:** `src/neuromodulation.rs` and `src/precision_controller.rs` implement **heuristic** meta-parameters (dopamine / noradrenaline / serotonin proxies). They **nudge** tool budgets and regimes; they are **not** biophysical models and **not** claims of biological fidelity.

## What is wired today

- **`tool_budget_multiplier()`** — scales **`recommended_max_tool_calls()`** (see `precision_controller.rs`).  
- **`context_exploration_multiplier()`** — scales **`context_exploration_budget()`** (fraction of context for exploratory vs fixed content).  
- **`effective_tool_timeout_secs(base)`** — scales per-call tool timeout in **`tool_middleware::ToolTimeoutWrapper`** from the wrapper’s base duration (default 30s).  
- **Regime selection** — driven primarily by **surprisal EMA** and optional **`CHUMP_ADAPTIVE_REGIME`**.  
- **Health JSON** — `neuromodulation` metrics on **`GET /health`** include `effective_tool_timeout_secs_30base` when `CHUMP_HEALTH_PORT` is set.

## Heuristic interpretation

| Proxy | Rough meaning in code | Operator takeaway |
|-------|----------------------|-------------------|
| **Dopamine** | Streak-based reward sensitivity | Success/failure streaks shift exploration appetite slightly. |
| **Noradrenaline** | Exploitation pressure | Higher → tighter focus (fewer exploratory tool rounds in budget math). |
| **Serotonin** | Patience / multi-step tolerance | Higher → slightly **more** tool calls allowed per turn via multiplier. |

## What is *not* promised

- No guaranteed optimality, safety, or alignment properties.  
- No replacement for **`CHUMP_TOOLS_ASK`**, allowlists, or air-gap registration.  
- **Temperature / sampling** for the LLM provider is **not** automatically tied to neuromodulation in all code paths; any future coupling should be documented per provider.

## Related

- [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) — research framing.  
- [METRICS.md](METRICS.md) — observability.  

## Changelog

| Date | Change |
|------|--------|
| 2026-04-09 | Initial doc for WP-6.2. |
| 2026-04-09 | Documented context exploration + tool timeout wiring. |
