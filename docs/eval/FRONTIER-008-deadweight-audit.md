# FRONTIER-008 — Dead-weight FRONTIER module audit

**Date:** 2026-04-21  
**Gap:** FRONTIER-008  
**Status:** COMPLETE

## Purpose

Red Letter Issue #1 (2026-04-19) named `src/tda_blackboard.rs` (310 LOC, zero callsites) as dead
weight shipping in every binary. FRONTIER-002 was the parent gap. This audit checks all
FRONTIER-* gaps and their associated code for zero-callsite status, produces a decision table,
and files any removal gaps if needed.

## FRONTIER gap status summary

| Gap | Title | Status | Code artifact | Disposition |
|---|---|---|---|---|
| FRONTIER-001 | Quantum cognition — density matrix tool-choice | done (2026-04-16, gate failed) | `experiments/quantum_tool_choice.rs` | KEEP — in `experiments/`, not compiled into binary |
| FRONTIER-002 | TDA blackboard — persistent homology on blackboard traffic | done (2026-04-16) | `src/tda_blackboard.rs` (removed 2026-04-19, commit 32bc6e1) | REMOVED — already handled |
| FRONTIER-003 | Adaptive regime transitions via learned bandit | done | none | n/a |
| FRONTIER-004 | Dynamic autopoiesis — fleet workspace merge/split | deferred (RFC governance) | none | n/a |
| FRONTIER-005 | goose competitive positioning | done | none | n/a |
| FRONTIER-006 | JEPA / world-models watchpoint | done | none | n/a |
| FRONTIER-007 | Cross-agent benchmarking — goose, Aider, Claude | done | none | n/a |

## Source module callsite audit

### `experiments/quantum_tool_choice.rs` — 405 LOC

- **External callsites in `src/`:** 0 (standalone experiment, not a `mod` in main.rs)
- **Compiled into main binary:** No — lives in `experiments/`, not the workspace crate
- **A/B result:** None; FRONTIER-001 gate (`>5% improvement on multi-choice task`) was never met
- **Decision:** **KEEP** — experiments/ is the appropriate home for prototype code. Not dead weight in
  the binary. Recoverable from git if quantum cognition revisited later.

### `src/holographic_workspace.rs` — 314 LOC

- **External callsites:** 8
  - `src/health_server.rs:193` — `holographic_workspace::metrics_json()` in consciousness dashboard
  - `src/consciousness_traits.rs:326` — `encode_entry()` called in DefaultHolographicSource
  - `src/consciousness_traits.rs:329` — `query_similarity()` in DefaultHolographicSource
  - `src/consciousness_traits.rs:332` — `capacity()` in DefaultHolographicSource
  - `src/consciousness_traits.rs:335` — `sync_from_blackboard()` in DefaultHolographicSource
  - `src/consciousness_traits.rs:387` — named `"holographic_workspace"` in substrate registry
  - `src/consciousness_traits.rs:419` — test assertion that name is present
  - `src/main.rs:70` — `mod holographic_workspace;`
- **A/B result:** None — no formal eval sweep on holographic workspace benefit
- **Decision:** **KEEP** — 8 active callsites; wired into the consciousness substrate. Not dead
  weight. If A/B result is desired, file an EVAL gap (not in scope here).

### `src/tda_blackboard.rs` — REMOVED

- Confirmed removed in commit `32bc6e1` (2026-04-19) per FRONTIER-002 closure note.
- Not present in current `src/` directory.
- FRONTIER-002 notes: "Code removed 2026-04-19 as dead weight in production binary. Recoverable
  from commit a383031 if labeled session data becomes available."

### `src/phi_proxy.rs` — 252 LOC (reference, FRONTIER-002 replacement target)

- **External callsites:** 14 — active in health status, cognitive state, consciousness exercise
- **Decision:** **KEEP** — actively used, not a FRONTIER dead-weight concern

## Verdict

**No new removal gaps needed.** The only zero-callsite module flagged in Red Letter Issue #1
(`src/tda_blackboard.rs`) was already removed before this audit ran. The remaining FRONTIER code:

- `experiments/quantum_tool_choice.rs`: prototype, not in binary, appropriate location
- `src/holographic_workspace.rs`: 8 active callsites, wired in production path

FRONTIER-008 closes as **complete with no new removal actions required**.
