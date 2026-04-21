# REMOVAL-001 addendum — integrate RESEARCH-022 mechanism evidence

**Filed:** 2026-04-21
**Supersedes:** nothing (addendum only)
**References:** [`REMOVAL-001-decision-matrix.md`](./REMOVAL-001-decision-matrix.md), [`RESEARCH-022-module-reference-analysis.md`](./RESEARCH-022-module-reference-analysis.md) (shipped PR #368)

---

## What changed

PR #368 shipped RESEARCH-022's mechanism-evidence analysis. Headline finding:

> All 5 NULL-validated modules show ≤1% reference rate in agent text output.
> `neuromodulation`/`belief_state`/`surprisal_ema` = 0%; `blackboard` and
> `spawn_lessons` = 1%. All below the preregistered 5% mechanistic-support
> threshold.

REMOVAL-001-decision-matrix.md was authored before RESEARCH-022 landed. Its
per-module verdicts rest on outcome evidence (EVAL-048 decision rule:
delta ± CI overlap with 0). Mechanism evidence — whether the agent
*textually references* the injected module state — was not available at
the time the matrix was written.

This addendum integrates the new evidence **without** changing which
sub-gaps are filed. It updates rationales, not actions.

---

## Per-module re-assessment

### 1. surprisal_ema — REMOVE (REMOVAL-002)

**Prior rationale:** delta=+0.000 exactly; no positive evidence; no
directional concern.

**With RESEARCH-022 evidence:** **doubly confirmed.** The module produces
no measurable output effect *and* the agent does not reference its state
in any observable way. Both the outcome channel and the textual-mediation
channel are null. Removing surprisal_ema is the least controversial
decision in the program.

**Action:** no change. REMOVAL-002 stands.

### 2. belief_state — REMOVE (REMOVAL-003)

**Prior rationale:** delta=+0.020; no signal; crate complexity not justified.

**With RESEARCH-022 evidence:** **doubly confirmed.** 0% reference rate —
the agent never verbally conditions on the injected `my_ability` /
uncertainty estimates. Same double-null pattern as surprisal_ema.

Note for RESEARCH-024 preregistration: the multi-turn degradation
hypothesis *requires* belief_state to be re-wired (or the analysis run
against a revived branch) if REMOVAL-003 lands before RESEARCH-024's
sweep. Order-of-operations matters. Flag for the RESEARCH-024 implementer
to consult REMOVAL-003's status before beginning the sweep.

**Action:** no change to REMOVAL-003. Flag the RESEARCH-024 ordering
concern as a note in the RESEARCH-024 preregistration's deviations log
when it's touched next.

### 3. neuromodulation — KEEP + REMOVAL-004 haiku retest

**Prior rationale:** NULL on non-haiku; F1 U-curve predicts possible
haiku-specific concern; retest outstanding.

**With RESEARCH-022 evidence:** 0% textual reference rate is **orthogonal**
to the haiku-specific concern. Neuromod modifies regime thresholds and
tool-budget scalars — these are internal control-flow knobs, not prompt
content the agent would parrot back. The absence of verbal references is
not evidence against neuromod; it's just uninformative for neuromod.

REMOVAL-004's haiku-retest under the EVAL-060 instrument remains the
load-bearing test. Reference-rate data does not substitute for outcome
data on the one cell (haiku-4-5 × neuromod bypass) that has never been
properly measured.

**Action:** no change. REMOVAL-004 stands as the decisive test.

### 4. spawn_lessons — KEEP (default=OFF)

**Prior rationale:** directional −0.140 at n=50, not statistically
distinguishable from 0; default=OFF (COG-024); deny-list (INFRA-016)
guards harmful architectures.

**With RESEARCH-022 evidence:** 1% reference rate — slightly above
surprisal/belief_state's 0% but still far below the 5% threshold. The
agent is almost never echoing the injected lessons content back in
text. This is **consistent with** the directional harm pattern: if the
agent isn't explicitly reasoning *from* the lessons, the lessons may
still be shifting distributions over tokens without the agent being
able to articulate why — which is exactly how prompt contamination
manifests. The low reference rate doesn't rebut the EVAL-076 haiku
harm finding; it may help explain it (harm without articulable
mechanism = hard to debug, hard to steer).

**Action:** no change to the KEEP-default-OFF decision. Note in
`CHUMP_FACULTY_MAP.md` Learning row: "RESEARCH-022 confirms lessons
block operates sub-verbally — agent behavior shifts without textual
reference. Harm pathway is therefore *not* mediated by the agent
reading-and-following the lessons, but by prompt-distribution effects.
This is consistent with EVAL-029's mechanism-decomposition finding
(conditional-chain dilution + trivial-token contamination) — both are
non-verbal shift mechanisms."

### 5. blackboard — KEEP (directionally positive, architectural plausibility)

**Prior rationale:** +0.060 directional positive; the only module with
an upward trend; architectural plausibility around cross-turn state;
multi-turn eval needed.

**With RESEARCH-022 evidence:** 1% reference rate **weakens** the
architectural-plausibility argument. If the blackboard's value proposition
is "the agent can see cross-turn state and condition on it," but the agent
rarely or never textually references that state, then either:
- (a) The blackboard's benefit (if real) is sub-verbal — the agent
  conditions on it in ways that don't surface as text (tool selection,
  response latency, refusal rates). This is testable.
- (b) The +0.060 directional positive is noise at n=50 and is not a real
  effect.

The original "KEEP" decision assumed architectural plausibility was
self-evident. RESEARCH-022 says it's not — the blackboard requires a
specific mechanism hypothesis and a test designed to detect it. Without
that test, "KEEP based on architectural plausibility" is a claim the
evidence does not support.

**Recommendation:** file a follow-up gap RESEARCH-028 (see below) for a
tool-selection-mediation test of the blackboard. If that test is null,
REMOVAL-005 (blackboard removal) becomes the correct move.

**CHUMP_FACULTY_MAP.md update:** "EVAL-064 directional +0.060 (NEUTRAL
per EVAL-048). RESEARCH-022: 1% textual reference rate — architectural
plausibility argument weakened. Keep conditional on RESEARCH-028
tool-selection-mediation test result."

---

## New recommended follow-up gap

### RESEARCH-028 — Blackboard tool-selection-mediation test

If the blackboard mediates behavior non-verbally, the most plausible
channel is tool selection. Specifically: the blackboard carries high-
salience state (tool failures, risk flags, recent-tool-outcomes). The
agent should — if the blackboard is load-bearing — exhibit measurably
different **tool-call sequences** in Cell A (blackboard ON) vs Cell B
(blackboard OFF), even if it doesn't verbalize the blackboard state.

Preregistered analysis:
- Per-trial tool-call sequence alignment between Cell A and Cell B.
- H1: Cell A and Cell B produce statistically different tool-call
  distributions on blackboard-state-sensitive tasks (tasks where a
  prior tool failed or returned risky output).
- H0: Tool-call distributions match — the blackboard is not mediating
  even non-verbally.
- n=50/cell on a blackboard-salience-rich subset of the neuromod fixture
  (tasks with tool retries, escalations, refusals).

If H0 holds, file REMOVAL-005.

Scope: file RESEARCH-028 in the research queue at P2/m. Preregistration
per RESEARCH-019 required before sweep.

---

## Summary verdict table (updated)

| Module | Prior verdict | RESEARCH-022 effect | Updated verdict |
|---|---|---|---|
| surprisal_ema | REMOVE (REMOVAL-002) | Double-null confirmed | REMOVE — no change |
| belief_state | REMOVE (REMOVAL-003) | Double-null confirmed | REMOVE — no change. Note RESEARCH-024 ordering. |
| neuromodulation | KEEP + REMOVAL-004 retest | Orthogonal (not verbal-mediated module) | KEEP + REMOVAL-004 — no change |
| spawn_lessons | KEEP (default=OFF) | Consistent with EVAL-029 sub-verbal harm pattern | KEEP — no change. Update faculty-map note. |
| blackboard | KEEP | Architectural plausibility weakened | KEEP **conditional** on RESEARCH-028 test |

## Action items

1. No existing sub-gap changes (REMOVAL-002/003/004 all stand).
2. File **RESEARCH-028** (blackboard tool-selection-mediation test) in
   gaps.yaml at P2/m. This addendum functions as the source_doc.
3. Update `docs/CHUMP_FACULTY_MAP.md` with the per-module annotation
   updates noted above. Light-touch — the original faculty-map rows are
   still accurate; this adds a "RESEARCH-022 integration" line to the
   Metacognition, Memory/Learning, and Executive Function rows where
   the affected modules live.
4. RESEARCH-024 preregistration should be re-read by whoever ships
   it — a note about the REMOVAL-003 ordering concern belongs in the
   deviations log if REMOVAL-003 lands first.
