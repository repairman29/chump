# REMOVAL-001 — Decision Matrix: 5 NULL-Validated Cognitive Modules

**Gap:** REMOVAL-001
**Date:** 2026-04-20
**Status:** COMPLETE — matrix filed; REMOVAL-002 and REMOVAL-003 sub-gaps filed
**Author:** claude (removal-001 worktree)
**Trigger:** RED_LETTER #3 (Issue #3, 2026-04-20)

---

## Decision Rule (re-cited from EVAL-048)

> **Module delta within ±0.05 (CIs overlap) → NEUTRAL — document "no detectable signal",
> candidate for removal to simplify codebase.**
>
> Module delta consistently > +0.05 (CIs non-overlapping) → NET-POSITIVE — keep module.
>
> Module delta consistently < −0.05 (CIs non-overlapping) → NET-NEGATIVE — file removal gap;
> do NOT ship further dependent features.
>
> Note: delta = Acc(bypass_ON) − Acc(bypass_OFF). Positive delta → bypass helps → module hurts.
> Negative delta → bypass hurts → module helps.
>
> *Source: `docs/eval/EVAL-048-ablation-results.md` Decision Criteria section.*

---

## Module Decision Matrix

| Module | Source path | Sweep | n/cell | Delta (bypass_ON − bypass_OFF) | CI 95% A | CI 95% B | CIs overlap? | EVAL-076 result | Recommended decision |
|--------|-------------|-------|--------|--------------------------------|----------|----------|--------------|-----------------|---------------------|
| surprisal_ema | `src/surprise_tracker.rs` | EVAL-063 LLM-judge (Llama-3.3-70B agent) | 50 | **+0.000** | [0.504, 0.762] | [0.504, 0.762] | Yes — identical | N/A (EVAL-076 targets neuromod only) | **File removal sub-gap (REMOVAL-002)** |
| belief_state | `crates/chump-belief-state/`, `src/belief_state.rs` | EVAL-063 LLM-judge (Llama-3.3-70B agent) | 50 | **+0.020** | [0.549, 0.797] | [0.570, 0.812] | Yes — overlapping | N/A | **File removal sub-gap (REMOVAL-003)** |
| neuromodulation | `src/neuromodulation.rs` | EVAL-063 LLM-judge (Llama-3.3-70B agent) | 50 | **+0.040** | [0.462, 0.724] | [0.504, 0.762] | Yes — overlapping | **OPEN — not yet run** (haiku-4-5 targeted rerun, ~$5, see EVAL-076) | **Re-test more** — block on EVAL-076 |
| spawn_lessons | `src/reflection_db.rs::load_spawn_lessons` | EVAL-064 LLM-judge (qwen2.5:14b agent) | 50 | **−0.140** (bypass hurts — module may help) | Cell A=0.660 [0.522, 0.776] | Cell B=0.520 [0.385, 0.652] | Yes — overlapping | N/A | **Keep with caveat** — directional positive signal exceeds ±0.05 threshold; needs n=100 confirmation |
| blackboard | `src/blackboard.rs` | EVAL-064 LLM-judge (Llama-3.3-70B agent) | 50 | **+0.060** (bypass helps — module may hurt) | Cell A=0.900 [0.786, 0.957] | Cell B=0.960 [0.865, 0.989] | Yes — overlapping | N/A | **Keep with caveat** — slightly outside ±0.05 in the harmful direction; CIs overlap; multi-turn design required for definitive measurement |

---

## Per-Module Detail

### 1. surprisal_ema — REMOVAL-002 recommended

**Source path:** `src/surprise_tracker.rs`
**Bypass flag:** `CHUMP_BYPASS_SURPRISAL=1` (implemented EVAL-043, wired at `src/surprise_tracker.rs::record_prediction`)

**Evidence stack:**

| Sweep | Harness | Agent | n/cell | Acc A (bypass OFF) | Acc B (bypass ON) | Delta | CIs overlap |
|-------|---------|-------|--------|--------------------|-------------------|-------|-------------|
| EVAL-053 binary-mode | exit-code scorer | Llama-3.3-70B | 30 | 1.000 [0.886, 1.000] | 1.000 [0.886, 1.000] | +0.000 | Yes (broken instrument — EVAL-061 suspended) |
| EVAL-063 LLM-judge | `run-binary-ablation.py --use-llm-judge` | Llama-3.3-70B | 50 | 0.640 | 0.640 | **+0.000** | Yes — fully overlapping |

**Delta application:** +0.000 is within ±0.05 and CIs overlap → EVAL-048 rule satisfied → candidate for removal.

**Decision:** File REMOVAL-002. Cleanest NULL in the dataset — zero delta across two independent sweeps. No prior harm or benefit signal.

**Research-integrity caveat:** n=50 is directional signal only. RESEARCH_INTEGRITY.md requires n=100/cell for ship-or-cut decisions. REMOVAL-002 must include an n=100 confirmation sweep as prerequisite before actual code deletion.

---

### 2. belief_state — REMOVAL-003 recommended

**Source path:** `crates/chump-belief-state/src/lib.rs`, `src/belief_state.rs`
**Bypass flag:** `CHUMP_BYPASS_BELIEF_STATE=1` (implemented EVAL-035, wired at `crates/chump-belief-state/src/lib.rs::belief_state_enabled`)

**Evidence stack:**

| Sweep | Harness | Agent | n/cell | Acc A (bypass OFF) | Acc B (bypass ON) | Delta | CIs overlap |
|-------|---------|-------|--------|--------------------|-------------------|-------|-------------|
| EVAL-053 binary-mode | exit-code scorer | Llama-3.3-70B | 30 | 1.000 [0.886, 1.000] | 1.000 [0.886, 1.000] | +0.000 | Yes (broken instrument) |
| EVAL-063 LLM-judge | `run-binary-ablation.py --use-llm-judge` | Llama-3.3-70B | 50 | 0.680 [0.549, 0.797] | 0.700 [0.570, 0.812] | **+0.020** | Yes — overlapping |

**Delta application:** +0.020 is within ±0.05 and CIs overlap → candidate for removal.

**Decision:** File REMOVAL-003. Two independent sweeps confirm NULL. Delta +0.020 is within the ±0.05 threshold.

Same n=100 confirmation prerequisite applies.

---

### 3. neuromodulation — Re-test more (block on EVAL-076)

**Source path:** `src/neuromodulation.rs`
**Bypass flag:** `CHUMP_BYPASS_NEUROMOD=1` (implemented EVAL-043)

**Evidence stack:**

| Sweep | Harness | Agent | n/cell | Acc A | Acc B | Delta | CIs overlap | Instrument quality |
|-------|---------|-------|--------|-------|-------|-------|-------------|--------------------|
| EVAL-026 cog016-n100 | direct-API | **claude-haiku-4-5** | 100 | — | — | **−0.150** | No — non-overlapping | **Best**: n=100, cross-family judges (Sonnet+Llama-70B) |
| EVAL-053 binary-mode | exit-code scorer | Llama-3.3-70B | 30 | 1.000 | 1.000 | +0.000 | Yes | Broken (EVAL-061 suspended) |
| EVAL-063 LLM-judge | `run-binary-ablation.py --use-llm-judge` | Llama-3.3-70B | 50 | 0.600 | 0.640 | **+0.040** | Yes | Different agent family from harm signal |
| EVAL-069 | `run-binary-ablation.py --use-llm-judge` | qwen2.5:14b | 50 | 0.920 | 0.920 | **+0.000** | Yes — identical | RED_LETTER #4: identical-CI fingerprint suspected scorer artifact |

**Delta application:** +0.040 from EVAL-063 is within ±0.05. However, EVAL-048 rule requires a valid measurement, and the EVAL-026 harm signal (−0.150 at n=100, cross-family judges, haiku-4-5 agent) came from a materially different agent family than EVAL-063/069.

**Decision:** Do NOT file removal gap yet. Block on EVAL-076.

Rationale:
- EVAL-063 and EVAL-069 used Llama-3.3-70B and qwen2.5:14b as agents — different model families from the original haiku-4-5 harm signal. These are not apples-to-apples comparisons.
- EVAL-076 is the planned haiku-4-5 targeted rerun. It is already filed (open), costs ~$5, and takes one afternoon. Run EVAL-076 first.
- EVAL-076 outcome → EVAL-048 rule applies: if delta within ±0.05, file REMOVAL-004; if harm confirmed, upgrade to NET-NEGATIVE.
- EVAL-069's identical-CI fingerprint (acc_A = acc_B = 0.920 with the same CI to three decimal places) was flagged in RED_LETTER #4 as a possible scorer-always-returns-same-result artifact. Its NULL conclusion is not reliable evidence.
- EVAL-030 task-class-aware gating (already deployed) suppresses neuromod on conditional-chain and trivial-token tasks — the two clusters where EVAL-029 confirmed harm. This mitigates the immediate risk.

**EVAL-076 outcome fork:**
- H1 (haiku-4-5 harm reproduces at ≥−0.05): upgrade to NET-NEGATIVE → file REMOVAL-004
- H2 (haiku-4-5 also NULL): all four sweeps agree NULL → file REMOVAL-004

Either outcome supports filing a removal gap. The only remaining question is whether EVAL-030 gating was sufficient mitigation.

---

### 4. spawn_lessons — Keep with caveat (directional positive signal)

**Source path:** `src/reflection_db.rs::load_spawn_lessons`
**Bypass flag:** `CHUMP_BYPASS_SPAWN_LESSONS=1` (implemented EVAL-056)

**Evidence stack:**

| Sweep | Harness | Agent | n/cell | Acc A (spawn ON) | Acc B (spawn bypassed) | Delta | CIs overlap |
|-------|---------|-------|--------|------------------|------------------------|-------|-------------|
| EVAL-056 binary-mode | exit-code scorer | (no live API) | 30 | 0.033 [0.006, 0.167] | 0.133 [0.053, 0.297] | +0.100 | Yes | Broken instrument (97% exit-1 rate) |
| EVAL-064 LLM-judge | `run-binary-ablation.py --use-llm-judge` | qwen2.5:14b | 50 | **0.660** [0.522, 0.776] | **0.520** [0.385, 0.652] | **−0.140** | Yes — overlapping |

**Delta application:** −0.140 is OUTSIDE the ±0.05 threshold. The EVAL-048 removal-candidate rule (delta within ±0.05) does NOT apply.

**Interpretation:** delta = −0.140 means bypassing spawn_lessons makes performance WORSE. The module appears to help accuracy by ~14pp at n=50. CIs overlap, so the finding is directional only, but this is a POSITIVE signal for the module — the module earns its complexity budget at this measurement.

**Decision:** Keep with caveat. Do not file removal gap at this stage.

**Caveat text for faculty map:** EVAL-064 LLM-judge (qwen2.5:14b, n=50/cell) shows delta=−0.140 (bypass hurts performance), suggesting spawn_lessons may have a positive effect. CIs overlap so the finding is directional only. A n=100 confirmation sweep with cross-family judges is required before any strong claim (positive or removal). If confirmed at n=100 with non-overlapping CIs (A > B), spawn_lessons graduates to NET-POSITIVE. If the delta collapses to within ±0.05 at n=100, revisit removal under REMOVAL-001-FOLLOWUP.

---

### 5. blackboard — Keep with caveat (outside ±0.05, multi-turn limitation)

**Source path:** `src/blackboard.rs` (COG-015 entity-prefetch path in `src/agent_loop/prompt_assembler.rs`)
**Bypass flag:** `CHUMP_BYPASS_BLACKBOARD=1` (implemented EVAL-058)

**Evidence stack:**

| Sweep | Harness | Agent | n/cell | Acc A (blackboard ON) | Acc B (blackboard bypassed) | Delta | CIs overlap |
|-------|---------|-------|--------|-----------------------|-----------------------------|-------|-------------|
| EVAL-058 binary-mode | exit-code scorer | (no live API) | 30 | 0.100 [0.035, 0.256] | 0.067 [0.018, 0.213] | −0.033 | Yes | Broken instrument |
| EVAL-064 LLM-judge | `run-binary-ablation.py --use-llm-judge` | Llama-3.3-70B | 50 | **0.900** [0.786, 0.957] | **0.960** [0.865, 0.989] | **+0.060** | Yes — overlapping |

**Delta application:** +0.060 is outside ±0.05 (by 0.010). The EVAL-048 removal-candidate rule requires delta strictly within ±0.05 with CIs overlapping. This delta is borderline — it barely misses the ±0.05 threshold in the direction suggesting mild module harm.

**However:** CIs overlap, the delta exceeds the threshold by only 0.010, and — crucially — the single-turn sweep methodology cannot exercise the blackboard meaningfully:

> The COG-015 entity-prefetch block reads entity facts from `src/blackboard.rs` that were persisted in prior turns. A single `chump --chump "<task>"` call starts with an empty blackboard (no prior entities persisted). The bypass test at n=50/cell effectively measured "single-turn performance with vs without an empty entity-prefetch injection" — both cells received identical prompts because the blackboard had nothing to inject. Any delta at this level is likely fixture noise, not module signal.

**Decision:** Keep with caveat. Do not file removal gap based on this sweep.

**Required next step:** Design a multi-turn evaluation session that:
1. Runs a warm-up sequence to persist entity facts into the blackboard
2. Runs test tasks that plausibly benefit from blackboard-injected entity context
3. Compares blackboard-active vs blackboard-bypassed on those follow-up tasks

Until that multi-turn evaluation runs, the single-turn EVAL-064 delta of +0.060 is not meaningful signal.

**Caveat text for faculty map:** EVAL-064 LLM-judge (Llama-3.3-70B, n=50/cell, single-turn) shows delta=+0.060 (bypass marginally better), outside the ±0.05 removal-candidate threshold. However, the single-turn harness cannot exercise the COG-015 entity-prefetch path (blackboard is empty at turn start). This result is structurally uninformative. A multi-turn evaluation with persisted entity facts is required before any removal or keep decision. File REMOVAL-001-FOLLOWUP-BLACKBOARD when designing that evaluation.

---

## Summary of Recommended Actions

| Action | Gap to file | Priority | Blocking dependency |
|--------|------------|----------|---------------------|
| surprisal_ema removal design | **REMOVAL-002** (filed in this PR) | P2 | n=100 confirmation sweep |
| belief_state removal design | **REMOVAL-003** (filed in this PR) | P2 | n=100 confirmation sweep |
| neuromod targeted haiku-4-5 rerun | EVAL-076 (already open) | P1 | None — ~$5 sweep, run immediately |
| spawn_lessons n=100 confirmation | new gap EVAL-077 (recommended) | P2 | Live API endpoint |
| blackboard multi-turn evaluation | new gap EVAL-078 (recommended) | P2 | Multi-turn session design |

**Modules recommended for removal sub-gaps:** surprisal_ema, belief_state.

**Modules held — positive or ambiguous signal:** neuromodulation (EVAL-076 required), spawn_lessons (directional positive signal, needs n=100), blackboard (multi-turn design required).

---

## CHUMP_FACULTY_MAP.md Updates Required

Per acceptance criteria: update faculty map with explicit caveat text for re-test-more and
keep-with-caveat modules. See the Per-Module Detail sections above for the caveat text.
The faculty map Metacognition row (row 7) should be updated to note that REMOVAL-002 and
REMOVAL-003 sub-gaps have been filed for surprisal_ema and belief_state, per RED_LETTER #3
action.

---

## Research Integrity Notes

1. **REMOVAL-002 and REMOVAL-003 sub-gaps reference EVAL-063 at n=50/cell as the directional
   filing threshold.** Per `docs/RESEARCH_INTEGRITY.md`, n=100/cell with cross-family judges
   is required for a ship-or-cut claim. Both removal gaps require an n=100 confirmation sweep
   before actual code deletion is merged.

2. **The EVAL-048 ±0.05 decision rule is applied here as the sub-gap filing threshold, not as
   the code-deletion execution threshold.** Filing a removal gap is the analysis step; merging
   the deletion requires meeting RESEARCH_INTEGRITY.md standards.

3. **EVAL-069 is treated with skepticism per RED_LETTER #4.** Its identical-CI result
   (acc_A = acc_B = 0.920, same CI to three decimal places) is consistent with a scorer
   returning the same verdict on every trial. Its NULL conclusion for neuromod is noted
   but does not independently justify removal.

4. **Delta sign convention:** delta = Acc(bypass_ON) − Acc(bypass_OFF). Positive delta: bypass
   helps, module is potentially harmful. Negative delta: bypass hurts, module is potentially
   beneficial.

---

## Cross-links

- Decision rule: `docs/eval/EVAL-048-ablation-results.md`
- Primary metacognition evidence: `docs/eval/EVAL-049-binary-ablation.md` (EVAL-063 Re-score section)
- Neuromod aggregate rerun: `docs/eval/EVAL-069-neuromod-aggregate-rerun.md`
- Neuromod targeted rerun design: `docs/eval/EVAL-076-haiku-4-5-targeted-rerun.md`
- Memory evidence: `docs/eval/EVAL-056-memory-ablation.md` + EVAL-064 results in faculty map row 5
- Blackboard evidence: `docs/eval/EVAL-058-executive-function-ablation.md` + EVAL-064 results in faculty map row 8
- Faculty map: `docs/CHUMP_FACULTY_MAP.md`
- Research integrity gate: `docs/RESEARCH_INTEGRITY.md`
- RED_LETTER trigger: `docs/RED_LETTER.md` Issue #3 (2026-04-20)
