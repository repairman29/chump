# Roadmap: remaining gaps (post Phase F closure)

**Purpose:** After [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) Phase F and [ADR-001](ADR-001-transactional-tool-speculation.md), this file tracks **what is still open** and **what shipped**.

**Last updated:** 2026-04-10

---

## Shipped in this pass

| Item | Notes |
|------|--------|
| **E2 baseline** | `sandbox_run` tool ([`src/sandbox_tool.rs`](../src/sandbox_tool.rs)): detached git worktree, one command, teardown; `CHUMP_SANDBOX_ENABLED=1`. Marked **[x]** in pragmatic roadmap. |
| **Speculative observability** | Last multi-tool batch evaluation exposed on `GET /health` under `consciousness_dashboard.speculative_batch` (when a batch has run in-process). |
| **Causal graph dedupe** | `persist_causal_graph_as_lessons` skips rows that already exist for same `episode_id` + `lesson` text. |

---

## Backlog (ordered)

### 1. Transactional speculation (ADR-001 follow-up) — not started

*(Naming note: this is **not** [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) **Phase G — G2**, which is the TDA-on-blackboard experiment.)*

- **Gate:** Product pain from memory-only rollback **and** willingness to route risky tools through sandbox or dry-run.
- **Depends on:** Policy for which tools may run in `sandbox_run` vs host; optional wiring from `agent_loop` to prefer `sandbox_run` for bounded commands (design in ADR-001).
- **Out of scope until go/no-go.**

### 2. Sandbox hardening (incremental)

- Allowlist of commands or patterns beyond `heuristic_risk` High block.
- Max worktree disk budget; document Mac vs CI `git` requirements.
- Optional: integrate sandbox path with **speculative** batch evaluation (mixed-batch rules).

### 3. Adaptive regime / DB pool (optional)

- Extend `record_task_outcome_for_regime` only if new terminal paths are found outside `task_db::task_update_status`.
- Long-term: test isolation via subprocess or per-test `CHUMP_MEMORY_DB_PATH` (large refactor).

### 4. Research frontier (pragmatic Phase G)

- Quantum toy, TDA, workspace merge — see [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) Phase G; do not mix with product backlog above.

---

## How to use

- **Chump / Cursor handoffs:** Cite this file + ADR-001 when discussing “real rollback” vs today’s behavior.
- **Ops:** Enable `sandbox_run` with `CHUMP_SANDBOX_ENABLED=1` only on hosts with a trusted git repo and bounded commands.
