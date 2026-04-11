# HRR / blackboard retrieval — eval harness notes (WP-6.3)

**Purpose:** Document **honest** evaluation boundaries for holographic workspace (`src/holographic_workspace.rs`) and blackboard (`src/blackboard.rs`). Automated checks live next to the implementation.

## What we test in-tree

| Area | Location | What is asserted |
|------|----------|------------------|
| Encode / capacity | `holographic_workspace` `#[cfg(test)]` | Entries increase `items_encoded`; capacity metadata present. |
| Retrieve by key | same | Known `(source, id)` returns **high** confidence; unknown key returns `None`. |
| Vector determinism | same | Same string → same algebra embedding; different strings → low similarity. |
| Blackboard → HRR sync | `sync_from_blackboard()`, `sync_from_broadcast_entries()` | Rebuilds HRR from **broadcast** blackboard entries (salience / turn filters apply). |
| Pipeline fixture | `holographic_workspace::tests::wp63_blackboard_broadcast_to_hrr_pipeline` | Local `Blackboard` → `broadcast_entries` → HRR → `query_similarity` (deterministic harness). |

## Honest limitations (do not oversell)

- **`module_awareness`** is **deprecated** — module vectors are not aligned with entry keys; confidences are not semantically meaningful (see rustdoc).  
- **HRR retrieval** is **approximate**; do not treat similarity scores as calibrated probabilities.  
- **Blackboard** broadcast filters depend on **salience**, **age**, and **agent turn** — tests that need entries visible to `sync_from_blackboard` must satisfy those invariants.

## Adding a new fixture-style test

1. Prefer **`encode_entry` + `retrieve_by_key` / `query_similarity`** in `holographic_workspace` tests for deterministic harnesses.  
2. For end-to-end blackboard paths, use **`blackboard::post`** with **high salience** and run from a context where **`agent_turn`** is consistent with `broadcast_entries()` filters — or test **`sync_from_blackboard`** only with mocked/guaranteed broadcast list (future refactor if needed).

## Changelog

| Date | Change |
|------|--------|
| 2026-04-09 | Initial harness doc for WP-6.3. |
