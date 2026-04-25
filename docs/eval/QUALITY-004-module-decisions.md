# QUALITY-004 — Module removal decisions: Memory, Executive Function, Metacognition

**Filed:** 2026-04-25
**Closes:** QUALITY-004
**Source plan:** [`docs/EVALUATION_PLAN_2026Q2.md`](../EVALUATION_PLAN_2026Q2.md) §QUALITY-001
**Builds on:** [`REMOVAL-001-decision-matrix.md`](./REMOVAL-001-decision-matrix.md)

## Why this gap exists

The Q2 plan called out three faculties with VALIDATED(NULL) eval results — Memory,
Executive Function, Metacognition — and asked: dead code, under-tested, or
intentionally kept? REMOVAL-001 (2026-04-21) ran the decision matrix across
five candidate modules and shipped REMOVAL-002/003. This document closes
QUALITY-004 by mapping the three faculty names to the modules they refer to,
recording the per-faculty decision against the EVAL-048 criterion, and
confirming that no further REMOVAL-005+ gaps are needed today.

## Faculty → module mapping

| Faculty (Q2 plan) | Module(s) | Bypass flag | Best eval |
|---|---|---|---|
| Memory | `src/reflection_db.rs::load_spawn_lessons` (spawn-time lesson injection, MEM-006) | `CHUMP_BYPASS_SPAWN_LESSONS` | [EVAL-056](./EVAL-056-memory-ablation.md) (n=30, binary) + [EVAL-064](./EVAL-064-llm-judge-ablation.md) (n=50, LLM judge) |
| Executive Function | `src/blackboard.rs` + COG-015 entity-prefetch in `src/agent_loop/prompt_assembler.rs` | `CHUMP_BYPASS_BLACKBOARD` | [EVAL-058](./EVAL-058-executive-function-ablation.md) (n=30, binary) + [EVAL-064](./EVAL-064-llm-judge-ablation.md) (n=50, LLM judge) |
| Metacognition | `src/belief_state.rs` (formerly `crates/chump-belief-state/`) | `CHUMP_BYPASS_BELIEF_STATE` | [EVAL-063](./EVAL-063-llm-judge-ablation.md) (n=50, LLM judge) |

This mapping is implicit in the eval document titles — EVAL-056 is titled
"Memory ablation" and gates `load_spawn_lessons`; EVAL-058 is titled
"Executive Function ablation" and gates the blackboard entity-prefetch path;
the REMOVAL-001 matrix lists belief_state under the Metacognition slot.

## Per-faculty decision

### Memory — `load_spawn_lessons` (spawn-time MEM-006)

- **Used in production?** Yes. Wired into `src/agent_loop/prompt_assembler.rs`
  (assembled prompt prefix when `CHUMP_LESSONS_AT_SPAWN_N > 0`),
  `src/reflection_db.rs` (DB query path), `src/briefing.rs` (per-gap briefing
  surface, MEM-007). Default is OFF per COG-024 safe-by-default.
- **Tests?** Yes — `src/env_flags.rs` has a unit test for the bypass flag,
  and the harness `scripts/ab-harness/run-binary-ablation.py` exercises the
  module gate in n=30 binary sweeps.
- **Evidence:** EVAL-056 binary (delta=+0.100, CIs overlap), EVAL-064 LLM-judge
  (delta=−0.140 on qwen14B, CIs overlap), EVAL-076 (haiku, inference-time
  lessons, delta=−0.150 directional harm — separate feature, convergent concern).
- **EVAL-048 verdict:** NEUTRAL with directional concern.
- **Decision: KEEP (default=OFF) — no removal gap.**
  Rationale: REMOVAL-001 §4 already concluded this. The default is OFF;
  INFRA-016 deny-list further guards untested architectures. The opt-in
  surface (`CHUMP_LESSONS_OPT_IN_MODELS`) is the production stance. Removing
  the spawn-time path would also remove MEM-007's per-gap briefing surface,
  which has independent value beyond raw accuracy.
- **Removal effort if revisited later:** S (delete `load_spawn_lessons`
  body, drop one prompt-assembler block, drop ~3 env-flag callsites).

### Executive Function — `blackboard` + COG-015 entity-prefetch

- **Used in production?** Yes — two paths. (a) COG-015 entity-prefetch in
  `src/agent_loop/prompt_assembler.rs::assemble_with_hint` calls
  `crate::blackboard::query_persist_for_entities(...)` and is the path
  exercised by `--chump` CLI binary sweeps. (b) Global Workspace broadcast
  at `src/context_assembly.rs::broadcast_context` (lines ~662–686) on
  heartbeat turns. The bypass flag only gates (a).
- **Tests?** Yes — `src/env_flags.rs` unit test, plus extensive coverage in
  `src/consciousness_tests.rs` (GW broadcast invariants) and
  `src/blackboard.rs` (storage + entity query).
- **Evidence:** EVAL-058 binary (delta=−0.033, noisy), EVAL-064 LLM-judge
  Llama-70B (delta=+0.060, CIs overlap, only directional positive in the set).
- **EVAL-048 verdict:** NEUTRAL (directional positive).
- **Decision: KEEP — no removal gap.**
  Rationale: REMOVAL-001 §5 already concluded this. The +0.060 directional
  positive is the only positive trend in the NULL-faculty set, and the
  blackboard provides cross-turn entity state that single-turn fixtures
  cannot measure well. Multi-turn entity-rich eval (INFRA-008) is the
  correct instrument before any removal decision; that gap is filed and
  open.
- **Removal effort if revisited later:** L (blackboard is referenced by
  ~8 modules incl. `consciousness_traits`, `consciousness_tests`,
  `consciousness_exercise`, `speculative_execution`, `context_assembly`,
  `prompt_assembler`; would also delete the GW broadcast path).

### Metacognition — `belief_state`

- **Used in production?** No — already removed.
  REMOVAL-003 shipped 2026-04-25 (PR #465). The `crates/chump-belief-state/`
  crate (666 LOC) was deleted; `src/belief_state.rs` is now an inert stub
  preserving the public call surface as no-ops. ~47 callsites still
  reference the stub but their behavior is dead.
- **Tests?** Stub has minimal smoke tests; the deleted crate's tests were
  removed with it.
- **Evidence:** EVAL-063 LLM-judge Llama-70B (delta=+0.020, CIs overlap).
- **EVAL-048 verdict:** NEUTRAL.
- **Decision: ALREADY REMOVED (REMOVAL-003 shipped). Follow-up:
  mechanical callsite sweep — see below.**
- **Follow-up gap filed: REMOVAL-005** — mechanical sweep of the ~47
  belief_state callsites. Effort S, P3, doc-only. The stub keeps current
  behavior correct so this is pure cleanup, no behavior change.

## Summary matrix

| Faculty | Module | Verdict | Removal gap | Effort to remove |
|---|---|---|---|---|
| Memory | `load_spawn_lessons` | KEEP (default=OFF) | — | S |
| Executive Function | `blackboard` + COG-015 prefetch | KEEP | — (multi-turn eval first via INFRA-008) | L |
| Metacognition | `belief_state` | ALREADY REMOVED (REMOVAL-003) | REMOVAL-005 (callsite sweep, P3, S) | S |

## Acceptance criteria check

- [x] Reviewed each module's source code and call sites (mapping table above).
- [x] Documented evidence (used vs unused, test coverage) — per-faculty sections.
- [x] Estimated removal effort (S/M/L) — summary matrix.
- [x] Decision recommendation with rationale — per-faculty decisions.
- [x] If remove: created REMOVAL-005 (callsite sweep) — see entry in `docs/gaps.yaml`.

## Q2 roadmap impact

REMOVAL-001 already filed REMOVAL-002 (surprisal, shipped) and REMOVAL-003
(belief_state, shipped). QUALITY-004 adds REMOVAL-005 only — a small
doc-only callsite sweep. The plan doc estimated "2–3 weeks if removals
needed"; actual cost is ≤1 day since the substantive removal already
happened. Q2 scope unchanged — pivot to better instrument (INFRA-008
multi-turn eval) is the open question, not module removal.
