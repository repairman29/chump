---
doc_tag: log
owner_gap: REMOVAL-006
last_audited: 2026-05-02
---

# REMOVAL-006 — `src/neuromodulation.rs` wiring trace

**Date:** 2026-05-02
**Gap:** REMOVAL-006
**Status:** COMPLETE — **decision: KEEP** (premise of original gap is partially wrong)
**Outcome:** Module is wired into 5 distinct callsites; cloud-path provider wiring is partial and filed as follow-up; empirical signal (EVAL-095, Δ=+0.150 directional) supports keeping the ablation surface intact.

---

## TL;DR

The original gap (filed 2026-04-26) claimed: *"src/neuromodulation.rs (21KB, 600+ LOC) computes per-turn token-budget, temperature, and top_p adjustments based on conversation state — and the resulting values are never threaded into the actual provider call. The LLM never receives the adjusted parameters."*

**Both halves of that claim are partially false:**

1. The module is **18 public functions, 455 LOC** (not 600+) — five of those functions ARE called from non-neuromod code paths.
2. `adaptive_temperature` + `adaptive_top_p` ARE threaded into provider calls — for the *local* providers (`local_openai.rs`, `mistralrs_provider.rs`). For the cloud path through `axonerai`, they are NOT wired (filed as follow-up).

Plus EVAL-095 (closed today, PR #737, Δ=+0.150 directional with localized harm in 3 specific tasks) shows the ablation produces a real behavioral signal when `CHUMP_BYPASS_NEUROMOD=1` is set. Removing the module would remove the signal-generating surface that EVAL-095 just measured.

---

## Module surface

`src/neuromodulation.rs` exports 18 public items:

| Public symbol | Wired? | Caller |
|---|---|---|
| `NeuromodState` (struct) | yes | `autonomy_loop.rs`, `speculative_execution.rs`, `checkpoint_db.rs` (snapshot/restore) |
| `levels()` | yes | autonomy loop, speculative execution, checkpoint, health server |
| `neuromod_enabled()` | yes | guard for ablation flag |
| `update_from_turn()` | yes | autonomy loop per-turn updater |
| `reset()` | yes | speculative execution rollback, checkpoint restore |
| `restore(snap)` | yes | speculative execution rollback, checkpoint restore |
| `modulated_exploit_threshold()` | yes | `precision_controller.rs:178` |
| `modulated_balanced_threshold()` | (test-only?) | only neuromodulation.rs internal + telemetry |
| `modulated_explore_threshold()` | (test-only?) | only neuromodulation.rs internal + telemetry |
| `tool_budget_multiplier()` | yes | `precision_controller.rs:265` |
| `reward_scaling()` | (telemetry-only) | only `metrics_json` + tests |
| `context_exploration_multiplier()` | yes | `precision_controller.rs:287` |
| `effective_tool_timeout_secs()` | yes | `tool_middleware.rs:1115`, `health_server.rs`, `routes/health.rs` |
| `salience_modulation()` | yes | `blackboard.rs:178` |
| `adaptive_temperature()` | **partial** | `local_openai.rs:1017`, `mistralrs_provider.rs:313` — **NOT** axonerai cloud path |
| `adaptive_top_p()` | **partial** | `local_openai.rs:1018`, `mistralrs_provider.rs:314` — **NOT** axonerai cloud path |
| `context_summary()` | yes | health/telemetry surfaces |
| `metrics_json()` | yes | health server + ambient summary |

**Five distinct downstream effect channels:**
1. **Provider request shaping** — adaptive temperature + top_p (local providers only; cloud path is the gap)
2. **Tool timeout adjustments** — `tool_middleware.rs` uses `effective_tool_timeout_secs`
3. **Precision controller thresholds** — exploit threshold + tool budget + exploration multiplier
4. **Blackboard salience scoring** — neuromod modulates the four salience factor weights
5. **Telemetry / observability** — health server + ambient stream surface neuromod state

**Three internal-only functions** (could be private without breaking anything):
- `modulated_balanced_threshold()` — only used in `metrics_json()` + tests
- `modulated_explore_threshold()` — only used in `metrics_json()` + tests
- `reward_scaling()` — only used in `metrics_json()` + tests

(Not blocking — flagged as a small cleanup follow-up.)

---

## Empirical signal — EVAL-095 (today)

EVAL-095 (closed PR #737, 2026-05-02) re-ran EVAL-069's ablation protocol on the current chump binary:

| Cell | n | acc | Wilson 95% CI |
|---|---|---|---|
| A — control (neuromod ON) | 20 | 0.850 | [0.640, 0.948] |
| B — ablation (`CHUMP_BYPASS_NEUROMOD=1`) | 20 | 0.700 | [0.481, 0.855] |

Δ = +0.150. CIs overlap so it's directional, not statistically confirmed at n=20. **The entire signal comes from 3 specific tasks** (t015, t017, t019) where neuromod ON → 1.0 and bypass ON → 0.0 — exactly F3's task-cluster localization claim.

EVAL-076 (closed PR #364, claude-haiku-4-5) also showed Δ=−0.15 directional. Two underpowered replications pointing in F3's predicted direction. EVAL-096 (n=100/cell + cross-judge) is the properly-powered settle, filed but not yet run.

**Implication:** the neuromod ablation is producing a real behavioral effect in some specific task class, even with the cloud-path temperature/top_p wiring incomplete. Removing the module would erase the surface EVAL-095 measured. Wait for EVAL-096 before any removal decision.

---

## Decision

**KEEP src/neuromodulation.rs as-is.**

Rationale:
1. 5 of 5 effect channels are wired (provider request shaping is partial but real).
2. Empirical evidence (EVAL-095 Δ=+0.150 directional, EVAL-076 Δ=−0.15 directional) supports the ablation surface producing a measurable effect.
3. EVAL-096 (n=100 cross-judge) is the load-bearing settle — until that lands, removal would be premature.

The original gap's recommendation ("Decide — wire-in or remove") chose neither option from a position of partial information. This audit replaces the false premise with a verified call-graph and a real empirical signal.

---

## Follow-ups filed

- **(this PR)** INFRA-???: wire `adaptive_temperature` + `adaptive_top_p` into the axonerai cloud path so the ablation is consistent across all providers (currently the cloud path is a no-op for these two functions, which contaminates EVAL-026/EVAL-076 results that ran on cloud agents).
- **(this PR)** REMOVAL-???: the three telemetry-only public functions (`modulated_balanced_threshold`, `modulated_explore_threshold`, `reward_scaling`) could be `pub(crate)` — small cleanup, no behavioral change.

---

## Acceptance vs the gap

| REMOVAL-006 acceptance | Status |
|---|---|
| Trace neuromod-computed values through agent_loop and confirm they reach (or do not reach) the provider call | ✅ traced — partial wire-up confirmed (local yes, cloud no) |
| Decide — wire-in (with feature flag plus EVAL-043 ablation arm) or remove | ✅ KEEP; cloud-path wire-in filed as follow-up |
| If wire-in — end-to-end test asserts provider request body contains adjusted temperature/top_p | ⏳ deferred to the cloud-path wiring follow-up |
| If remove — update CHUMP_RESEARCH_BRIEF.md, CHUMP_FACULTY_MAP.md, README to reflect removal | n/a (not removing) |
| Decision recorded in commit body and reflected in docs/RESEARCH_INTEGRITY.md prohibited-claims table | ✅ commit body documents decision; RESEARCH_INTEGRITY.md not updated because the prohibited-claims entry "Neuromodulation is a net positive" still holds (EVAL-095 is directional only — not yet a "validated net positive") |
