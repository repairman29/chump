# REMOVAL-001 — NULL-Module Decision Matrix

**Filed:** 2026-04-21
**Closes:** REMOVAL-001
**Decision criterion source:** [EVAL-048](./EVAL-048-ablation-results.md) §Decision Rules

## Decision criterion (EVAL-048)

| Signal pattern | Label | Action |
|---|---|---|
| delta > +0.05, non-overlapping CIs, 2+ fixtures/models | NET-POSITIVE | Cite as validated; update faculty map |
| delta within ±0.05, CIs overlap | NEUTRAL | Document "no detectable signal"; candidate for removal |
| delta < −0.05 consistently | NET-NEGATIVE | File removal gap; do not ship further dependent features |

**Note:** CIs overlapping zero is the binding criterion — point estimate alone does not
determine the verdict. A delta of −0.140 with overlapping CIs is still formally NEUTRAL
under EVAL-048.

---

## Per-module evidence table

| Module | File(s) | Best eval | n/cell | delta (B−A) | CIs overlap? | EVAL-048 verdict |
|---|---|---|---|---|---|---|
| surprisal_ema | `src/surprise_tracker.rs` | EVAL-063 (LLM judge, Llama-70B agent) | 50 | +0.000 | ✅ | NEUTRAL |
| belief_state | `src/belief_state.rs`, `crates/chump-belief-state/` | EVAL-063 (LLM judge, Llama-70B agent) | 50 | +0.020 | ✅ | NEUTRAL |
| neuromodulation | `src/neuromodulation.rs`, `crates/chump-neuromodulation/` | EVAL-063 (LLM judge, Llama-70B) + EVAL-069 (qwen14B) | 50+50 | +0.040 / 0.000 | ✅ both | NEUTRAL (with caveat — see below) |
| spawn_lessons | `src/reflection_db.rs::load_spawn_lessons` | EVAL-064 (LLM judge, qwen14B, n=50) | 50 | −0.140 | ✅ | NEUTRAL (directional concern) |
| blackboard | `src/blackboard.rs` | EVAL-064 (LLM judge, Llama-70B, n=50) | 50 | +0.060 | ✅ | NEUTRAL (directional positive) |

---

## Per-module decisions

### 1. surprisal_ema — `src/surprise_tracker.rs`

**Evidence:** EVAL-063 (Llama-3.3-70B agent, LLM judge, n=50/cell): delta=+0.000 exactly.
No historical positive signal. No model-tier concern.

**Decision: FILE REMOVAL SUB-GAP (REMOVAL-002)**

Rationale: delta at the exact neutral point. No positive evidence. No directional concern.
The module adds prompt tokens and CPU overhead every session without measurable benefit.
Removing it reduces noise surface for future measurements.

---

### 2. belief_state — `src/belief_state.rs` + `crates/chump-belief-state/`

**Evidence:** EVAL-063 (Llama-3.3-70B, LLM judge, n=50/cell): delta=+0.020, CIs overlap.
No historical positive signal. No model-tier concern.

**Decision: FILE REMOVAL SUB-GAP (REMOVAL-003)**

Rationale: delta within NEUTRAL band, no positive evidence from any sweep. The belief-state
crate adds codebase complexity. Removing frees up the "Metacognition" faculty slot for a
module that shows actual signal.

---

### 3. neuromodulation — `src/neuromodulation.rs` + `crates/chump-neuromodulation/`

**Evidence summary:**
- EVAL-063 (Llama-70B, n=50/cell): delta=+0.040, CIs overlap — NEUTRAL
- EVAL-069 (Ollama qwen2.5:14b, n=50/cell): delta=0.000 — NEUTRAL
- EVAL-026 prior (cross-arch, 2026-04-19): haiku-4-5 showed −0.15 harm (pre-EVAL-060 instrument)
- EVAL-076 (haiku-4-5 targeted rerun, 2026-04-21): tested **lessons block** (COG-016 text), not neuromod bypass specifically. Delta=−0.15 reproduced — but on the lessons feature, not the neuromod module.

**Gap in evidence:** No haiku-4-5 specific ablation of `CHUMP_BYPASS_NEUROMOD=1` has been run
under the EVAL-060 LLM-judge instrument. EVAL-063 and EVAL-069 used different agents. The
EVAL-026 haiku cell used the pre-EVAL-060 harness path.

**Decision: KEEP WITH CAVEAT + file REMOVAL-004 (haiku-specific neuromod bypass retest)**

Rationale: The EVAL-048 criterion formally calls this NEUTRAL. However, the unresolved
haiku-specific concern from EVAL-026 — and EVAL-076's confirmation that haiku IS harmed by
the lessons block — warrants caution before removing. The F1 U-curve (mid-tier models harmed)
predicts haiku could also be harmed by the neuromod module specifically. A n=50/cell
haiku-specific neuromod bypass ablation under EVAL-060 would resolve this definitively at
~$3 cost. Filing as REMOVAL-004 (low priority, informational).

**CHUMP_FACULTY_MAP.md update:** "EVAL-063 + EVAL-069: NULL on Llama-70B + qwen14B agents.
Haiku-specific neuromod bypass not yet tested; F1 U-curve predicts possible mid-tier concern.
EVAL-076 confirmed lessons harm on haiku (lessons block, not neuromod bypass directly).
Pending REMOVAL-004."

---

### 4. spawn-time lesson loading — `src/reflection_db.rs::load_spawn_lessons`

**Evidence:**
- EVAL-056 (binary-mode, n=30/cell): delta=+0.100, CIs overlap — noisy baseline
- EVAL-064 (LLM judge, qwen2.5:14b, n=50/cell): delta=−0.140, CIs overlap — NEUTRAL per criterion
- EVAL-076 (haiku-4-5, inference-time lessons, n=50/cell): delta=−0.150, directional harm confirmed (kappa caveat)

**Important distinction:** `load_spawn_lessons` (MEM-006) injects lessons at spawn time into
the system-level prefix. EVAL-076 measured inference-time lessons injection (COG-016 block).
These are two separate features controlled by different flags:
- Spawn-time: `CHUMP_LESSONS_AT_SPAWN_N` (default=OFF per COG-024 safe-by-default)
- Inference-time: `CHUMP_LESSONS_AT_SPAWN_N=0` vs lessons block in prompt assembler

The directional −0.140 at n=50 is not statistically distinguishable from zero but is the
largest-magnitude result in the set. Combined with EVAL-076's directional confirmation of
inference-time lesson harm on haiku, the risk profile is elevated.

**Decision: KEEP WITH CAVEAT (default=OFF confirmed correct)**

Rationale: The EVAL-048 formal criterion says NEUTRAL. The default is already OFF (COG-024).
The feature exists for opt-in use cases where lessons are expected to help (e.g. large models
with CHUMP_LESSONS_OPT_IN_MODELS). The INFRA-016 deny-list (CHUMP_LESSONS_DENY_FAMILIES=deepseek
by default) further guards against harm on untested architectures. No removal sub-gap needed
because the feature is already gated off by default.

**CHUMP_FACULTY_MAP.md update:** "EVAL-064: delta=−0.140 (CIs overlap, NEUTRAL per criterion)
but largest directional negative in the module set. Default=OFF (COG-024) is the correct
production stance. EVAL-076 (inference-time lessons, haiku): delta=−0.150 directional harm —
separate feature but convergent concern. Recommend keeping default=OFF."

---

### 5. blackboard — `src/blackboard.rs`

**Evidence:**
- EVAL-058 (binary-mode, n=30/cell): delta=−0.033, CIs overlap — noisy, not interpretable
- EVAL-064 (LLM judge, Llama-3.3-70B, n=50/cell): delta=+0.060, CIs overlap — NEUTRAL

**Decision: KEEP WITH CAVEAT**

Rationale: The +0.060 directional positive is the only module in the set with a positive
trend. The blackboard provides cross-turn state tracking that single-turn fixtures can't
measure well — a multi-turn entity-rich eval (not yet run) is the correct instrument. The
EVAL-048 criterion is NEUTRAL but directional positive + architectural plausibility (state
across tool calls) warrants keeping over removal.

**CHUMP_FACULTY_MAP.md update:** "EVAL-064: delta=+0.060 (CIs overlap, NEUTRAL per criterion).
Directionally positive — only module in the NULL set with a positive trend. Single-turn
fixture underestimates value; multi-turn eval required for definitive signal (INFRA-008)."

---

## Sub-gaps filed by this matrix

| Sub-gap | Module | Action | Priority | Effort |
|---|---|---|---|---|
| REMOVAL-002 | surprisal_ema | Remove `src/surprise_tracker.rs` + CHUMP_BYPASS_SURPRISAL flag | P2 | s |
| REMOVAL-003 | belief_state | Remove `src/belief_state.rs` + `crates/chump-belief-state/` + CHUMP_BYPASS_BELIEF_STATE | P2 | m |
| REMOVAL-004 | neuromodulation | Haiku-specific neuromod bypass retest (n=50/cell, EVAL-060 instrument) | P3 | s |

---

## Summary verdict

| Module | Verdict | Sub-gap | Rationale |
|---|---|---|---|
| surprisal_ema | **REMOVE** | REMOVAL-002 | delta=0.000 exactly; no signal, no concern |
| belief_state | **REMOVE** | REMOVAL-003 | delta=+0.020; no signal, crate complexity not justified |
| neuromodulation | **KEEP + re-test** | REMOVAL-004 | NULL on non-haiku; haiku-specific test outstanding |
| spawn_lessons | **KEEP (default=OFF)** | — | Default already OFF; INFRA-016 deny-list guards; directional concern noted |
| blackboard | **KEEP** | — | Directionally positive; multi-turn eval needed before removal decision |
