# Chump Research Plan: Bringing All 10 Cognitive Faculties to Validated (2026-Q3)

## Purpose

`docs/CHUMP_FACULTY_MAP.md` (shipped 2026-04-19) showed that **only 4 of 10
DeepMind cognitive faculties are currently COVERED+VALIDATED** in Chump
(Generation, Learning, Reasoning, Problem Solving). The other six are either
COVERED+UNTESTED, PARTIAL (with one net-negative signal), or outright GAP.

This plan defines, faculty by faculty, the minimum experimental work required
to graduate each to COVERED+VALIDATED. It is the master research roadmap for
2026-Q3 (May–July 2026). It composes the 22 strategic gaps filed in PR #128
into a sprint-paced execution plan with explicit dependencies, costs, wall-time
estimates, and per-faculty graduation criteria.

The plan is calibrated against Chump's actual operating constraints:
- Local 24 GB M4 (max ~16 GB available for in-process models)
- ~$5/sweep cloud budget per validation experiment (mostly Together + Anthropic)
- Single dogfooder developer time (~1 day equivalent of focused work per gap entry on average)

It is also calibrated against the validation discipline established by the
EVAL-023 → EVAL-027b trilogy: every faculty graduation requires (a) a published
A/B with cross-family judging and Wilson 95% CIs, (b) cell A vs cell B
non-overlapping deltas on at least one axis, (c) replication across at least
two model architectures where applicable.

## Executive summary

Six faculties need new experimental work to reach validated:

| # | Faculty | Status | Required experiments | Effort | Cloud $ |
|---|---|---|---|---|---|
| 1 | Perception | UNTESTED | EVAL-032 perception A/B isolation | M | $3 |
| 3 | Attention | GAP | EVAL-028 CatAttack baseline + EVAL-033 mitigation A/B | M | $4 |
| 5 | Memory | UNTESTED | EVAL-034 retrieval-precision + multi-hop QA fixture | L | $5 |
| 7 | Metacognition | NET-NEG | EVAL-029→EVAL-030 fix neuromod + EVAL-035 belief_state ablation | L | $6 |
| 8 | Executive Function | UNTESTED | EVAL-036 prompt-assembler ablation + EVAL-037 multi-agent coord A/B | L | $5 |
| 10 | Social Cognition | PARTIAL | EVAL-038 ambiguous-prompt clarification A/B | M | $3 |

The four already-validated faculties (Generation, Learning, Reasoning, Problem
Solving) need maintenance — re-validation under the COG-016 production block at
each new model tier — but no greenfield work in 2026-Q3.

**Total Q3 budget:** ~$26 cloud + ~9 weeks of dev work, parallelizable into
3 sprints. Detailed per-faculty plans below.

## Per-faculty plans

### 1. Perception (currently COVERED+UNTESTED)

**Current state:** `chump-perception` crate handles inbound multi-modal
extraction. The crate is exercised in every full agent run but its quality
is not isolated by any A/B. We don't actually know whether the perception
layer is helping, hurting, or neutral — only that it doesn't crash.

**Target state:** A measured A/B comparing perception ON vs perception OFF
across our 3 fixtures, on at least claude-haiku-4-5 + one Qwen size point.

**Required experiments:**
- **EVAL-032 (NEW)** — perception layer ablation A/B. Cell A: full perception
  layer active. Cell B: bypass perception, raw prompt only. Cross-family
  judges, n=50 reflection + n=50 perception fixtures.
- Decision rule: if perception adds correctness > noise floor (~+0.05),
  validated. If it's noise or negative, file follow-up to redesign or remove.

**Dependencies:** none. Can start any time after PR #128 lands.

**Cost:** ~$3 cloud (haiku-4-5 + Qwen-7B × 2 fixtures × n=50 × 2 cells).

**Wall:** ~1 day code (add `--bypass-perception` flag) + 1 hour sweep.

**Graduation criterion:** A/B published in CONSCIOUSNESS_AB_RESULTS.md with
Wilson CIs and a clear "perception is net-positive / net-negative / noise"
verdict. Update CHUMP_FACULTY_MAP.md status.

### 2. Generation (currently COVERED+VALIDATED)

**Current state:** EVAL-023 (n=600), EVAL-025 (n=600), EVAL-026 (n=900),
EVAL-026b (n=300) all measure generation quality via judge rubrics. Status
is solid.

**Target state:** Maintain. Re-validate when EVAL-027b lands at frontier tier
to confirm generation quality is stable under the production COG-016 block.

**Required experiments:** none new. EVAL-027b already in flight covers the
re-validation.

**Maintenance:** When new flagship Anthropic models ship (post-opus-4-5),
add a single n=50 cell to confirm generation behavior is consistent. Budget
~$5 per new model.

### 3. Attention (currently GAP — clearest single hole)

**Current state:** No Chump module implements selective attention or distractor
suppression. No A/B evidence. The Gemini-document CatAttack research
(arxiv 2503.01781) shows reasoning models suffer 300-500% error-rate increase
when irrelevant text is prepended to prompts.

**Target state:** Quantify Chump's attention vulnerability AND validate at
least one mitigation.

**Required experiments:**
- **EVAL-028 (FILED)** — CatAttack robustness baseline. Cell A bare prompt,
  cell B prompt + cat distractor, cell C prompt + distractor + lessons-block-
  with-anti-distraction-directive. n=50 reflection + perception × claude-haiku-
  4-5 + Qwen-7B.
- **EVAL-033 (NEW)** — Attention-specific mitigation A/B. Test 3 candidate
  mitigations: (a) prefix-prompt anchor reminder ("ignore preceding irrelevant
  context"), (b) suffix-prompt restatement of the original ask, (c) fine-tuned
  attention-mask via prompt structure. n=50 per mitigation.

**Dependencies:** EVAL-028 should land before EVAL-033 designs its mitigations.

**Cost:** ~$4 total (~$2 EVAL-028 + ~$2 EVAL-033).

**Wall:** ~3 days code (add `--distractor` harness flag, mitigation variants)
+ 2 hours sweeps.

**Graduation criterion:** Quantified vulnerability magnitude (e.g. "Chump's
agent shows N% error-rate increase under CatAttack triggers") + validated
mitigation that reduces the impact by ≥50%. Both in
CONSCIOUSNESS_AB_RESULTS.md. Faculty status moves from GAP → PARTIAL (no
defensive module yet) or COVERED+VALIDATED (if mitigation gets shipped to
production in `prompt_assembler.rs`).

### 4. Learning (currently COVERED+VALIDATED)

**Current state:** Lessons block + reflection_db is the deepest-validated
learning channel in the codebase. EVAL-023/025/026 trilogy + COG-016 ship.

**Target state:** Maintain plus extend with longitudinal validation.

**Required experiments:**
- **EVAL-039 (NEW, optional Q4)** — Longitudinal learning A/B. Fresh agent
  with N=0 lessons vs same agent after consuming N=10/50/100 prior reflection
  episodes. Tests whether the *accumulation loop* (write → recall → improve)
  itself produces measurable improvement, not just whether a hand-authored
  lessons block is helpful. This is the actually-novel learning question.

**Dependencies:** Need a fixture where the same task can be re-run with
different reflection-DB priors. May require a new test harness mode.

**Cost:** ~$10 cloud (multiple model-state cells).

**Wall:** ~1 week. Optional for Q3 — could defer to Q4.

### 5. Memory (currently COVERED+UNTESTED)

**Current state:** `memory_db.rs` (SQLite key-value) + `memory_graph.rs`
(entity-relation graph) + `chump-mcp-adb` adapter. Used as fixture state
in EVAL-023/025 but recall accuracy never isolated.

**Target state:** Quantified retrieval precision + recall on a multi-hop QA
fixture, plus a comparison to a no-memory baseline.

**Required experiments:**
- **EVAL-034 (NEW)** — Memory retrieval evaluation. Build a multi-hop QA
  fixture (~30 questions) where the correct answer requires combining
  multiple stored memory entries. Three cells: (A) memory ON full,
  (B) memory OFF (no recall), (C) memory ON with SAKE-style anchoring per
  EVAL-027. Measures both raw memory utility AND whether KID applies to
  Chump's memory layer specifically.
- **EVAL-031 (FILED — Search-Augmented Reasoning)** — Composes here. Tests
  whether AutoRefine-style multi-step retrieval would beat single-shot.

**Dependencies:** Need to author the multi-hop fixture (~1 day). EVAL-027
SAKE work informs EVAL-034 cell C design.

**Cost:** ~$5 cloud (3 cells × n=50 × 2 model points).

**Wall:** ~3 days fixture authoring + 2 days code + 1 hour sweep.

**Graduation criterion:** A/B published showing memory layer's measured
contribution to multi-hop QA, with the SAKE comparison. If memory adds
≥+0.10 correctness on multi-hop tasks, validated. If not, file follow-up.

### 6. Reasoning (currently COVERED+VALIDATED)

**Current state:** Best-validated faculty. 6 EVAL-XXX gaps + COG-016
production ship.

**Target state:** Maintain. Plus integrate test-time-compute (reasoning mode)
when models support it.

**Required experiments:**
- **COG-021 (FILED)** — Test-time-compute integration A/B. When o3-style
  reasoning is invoked, does correctness improve enough to justify the latency
  + cost? Measure on the "hardest" subset of our fixtures (dynamic-* tasks
  in neuromod, gotcha-* in reflection).

**Cost:** ~$8 cloud (reasoning mode is more expensive per call).

**Wall:** ~1 week implementation + 2 hours sweep.

### 7. Metacognition (currently PARTIAL — net-negative)

**Current state:** `belief_state.rs` + `neuromodulation.rs`. Cross-architecture
A/B (1200 trials) shows the lessons-block-driven meta-modulation HURTS by
-0.10 to -0.16 on the neuromod fixture. EVAL-029 identified two distinct
mechanisms (conditional-chain dilution + trivial-token contamination).

**Target state:** Net-positive metacognition contribution after fix.

**Required experiments:**
- **EVAL-030 (FILED, P1)** — Task-class-aware lessons block. Suppress
  "ask one clarifying question" directive on conditional-chain markers;
  skip lessons entirely on trivial-token prompts. Cells A (v1), B (off),
  C (task-class-aware). Goal: cell C ≥ cell B.
- **EVAL-035 (NEW)** — Belief-state ablation A/B. Cell A: belief_state
  active. Cell B: belief_state bypassed. Currently we don't know if
  belief_state is helping at all — never measured.

**Dependencies:** EVAL-030 informs EVAL-035 design (if EVAL-030 fixes the
neuromod harm, the belief_state layer's contribution becomes measurable
without being masked).

**Cost:** ~$6 cloud total.

**Wall:** ~1 week (EVAL-030 implementation) + ~3 days (EVAL-035) + 2 hours
sweeps.

**Graduation criterion:** Cell C in EVAL-030 eliminates the -0.10 to -0.16
neuromod harm. EVAL-035 shows belief_state is at minimum noise-neutral.
Faculty status moves from PARTIAL → COVERED+VALIDATED (or stays PARTIAL
with explicit "belief_state is decorative, candidate for removal" note).

### 8. Executive Function (currently COVERED+UNTESTED)

**Current state:** `agent_loop/`, `blackboard.rs`, `tool_middleware.rs`, plus
the `chump-coord` crate for multi-agent NATS coordination. Tested implicitly
via task pass-rate but no isolated A/B.

**Target state:** Validated prompt-assembler + validated multi-agent coord.

**Required experiments:**
- **EVAL-036 (NEW)** — Prompt-assembler ablation. Two strategies for
  assembling agent context (current vs. minimalist). Same task fixture,
  measure pass rate. Cheap test of whether our context-assembly is doing
  useful work or adding noise.
- **EVAL-037 (NEW)** — Multi-agent coordination A/B. Solo agent vs. agent
  with chump-coord active. Use a coordination-requiring fixture (e.g. tasks
  that span multiple files / require intermediate handoffs). Measures
  whether coord overhead pays for itself.

**Dependencies:** EVAL-037 needs a coordination fixture that doesn't currently
exist (~2 days authoring).

**Cost:** ~$5 cloud.

**Wall:** ~5 days fixture authoring + ~2 days code + 1 hour sweeps.

**Graduation criterion:** Both ablations show executive-function components
are ≥noise-neutral or net-positive. If either is net-negative, file followup
redesign gap.

### 9. Problem Solving (currently COVERED+VALIDATED — narrow domain)

**Current state:** Validated within our 3 fixtures (reflection, perception,
neuromod). But these are all hallucination-and-instruction-following tasks.
Out-of-distribution problem solving (e.g. ARC-AGI subset) is untested.

**Target state:** Validated across at least one OOD problem-solving fixture
(could be a simple ARC subset, novel reasoning tasks, or BFCL-style function
calling).

**Required experiments:**
- **EVAL-040 (NEW, optional Q3 / definite Q4)** — OOD problem-solving A/B.
  Pick one external benchmark (e.g. BFCL function calling, MMLU subset,
  ARC-AGI mini). Run Chump's full agent loop + lessons block on it. Compare
  to the same model's published baseline.

**Dependencies:** Choose benchmark + adapt fixture format (~3 days).

**Cost:** ~$10 cloud (depends on benchmark size).

**Wall:** ~1 week. Optional for Q3.

### 10. Social Cognition (currently PARTIAL)

**Current state:** ASK_JEFF flow + tool-approval list (`CHUMP_TOOLS_ASK`)
implement primitive social cognition. Never A/B tested.

**Target state:** Quantified appropriateness of clarifying-question behavior
on ambiguous prompts.

**Required experiments:**
- **EVAL-038 (NEW)** — Ambiguous-prompt A/B. Author ~30 prompts deliberately
  underspecified ("fix the bug", "make it faster", "what should I do?").
  Cell A: agent asks clarifying question first. Cell B: agent guesses and
  acts. Judge rubric scores: did the eventual action match user intent
  (provided as ground truth in fixture)? Measures whether "ask first" is
  actually the right policy or an over-trigger of EVAL-029's
  conditional-chain dilution mechanism.

**Dependencies:** Author the ambiguous-prompts fixture (~2 days).

**Cost:** ~$3 cloud.

**Wall:** ~3 days fixture + 2 hours sweep.

**Graduation criterion:** A/B published with directional signal on
ask-vs-guess behavior. Faculty status moves from PARTIAL → COVERED+VALIDATED
(in narrow scope). Connects to EVAL-030 finding — if "ask first" is broadly
harmful (per EVAL-029) but specifically helpful on truly ambiguous prompts,
the production fix is not "remove the directive" but "scope it to actually-
ambiguous cases."

## Cross-cutting infrastructure investments

These are not faculty-specific but unblock multiple faculty graduations:

1. **New fixtures (~1 week total authoring time):**
   - Multi-hop QA fixture for EVAL-034 (Memory)
   - Coordination-requiring fixture for EVAL-037 (Executive Function)
   - Ambiguous-prompts fixture for EVAL-038 (Social Cognition)
   - OOD problem-solving fixture for EVAL-040 (Problem Solving)

2. **Harness extensions (~1 week total code):**
   - `--bypass-perception` flag for EVAL-032
   - `--distractor` flag for EVAL-028 / EVAL-033
   - `--lessons-version v1|cog016|cog016+sake|task-aware` for EVAL-027 / EVAL-030
   - `--bypass-belief-state` flag for EVAL-035
   - Reasoning-mode invocation for COG-021

3. **Judge calibration (~3 days):**
   - Re-run A/A control on all 3 baseline fixtures with the current judge
     panel to refresh the noise floor estimate. Last A/A was several months
     ago; the cross-family judge panel has changed.
   - Add Llama-3.3-70B-only judge cell to detect any Anthropic judge bias
     creeping back in as we add more Anthropic-agent A/B tests.

4. **MCP-server enterprise patterns (COG-022)** — implements Sampling +
   Elicitation per AAIF 2026 MCP roadmap. Required before COG-021's
   reasoning-mode integration can interact properly with downstream MCP
   tools that need to pause for clarification.

5. **MCPwned audit (COMP-013)** — security audit of MCP servers BEFORE
   COMP-009 ships 3 new ones. ~half a day, no-cost dependency that can
   gate the COMP-009 work.

## Q3 sprint plan (12 weeks, May–July 2026)

### Sprint 1 (Weeks 1-4): unblock + validate easy faculties

**Week 1 — infrastructure week**
- Author multi-hop QA, ambiguous-prompts fixtures (Memory + Social Cognition)
- Add `--bypass-perception`, `--distractor` harness flags (Perception + Attention)
- COMP-014 cost ledger pricing fix (clears noise from logs)
- COMP-013 MCPwned audit (unblocks COMP-009)

**Week 2-3 — fast faculties**
- Run EVAL-032 perception ablation (~$3, 1 day) → graduate Perception or file fix
- Run EVAL-028 CatAttack baseline (~$2, 1 day) → quantify Attention gap
- Run EVAL-038 ambiguous-prompts A/B (~$3, 1 day) → graduate Social Cognition or refine
- Begin EVAL-030 task-class-aware lessons code

**Week 4 — neuromod fix (the biggest research bet)**
- Ship EVAL-030 sweep (~$2, 1 day) → if cell C beats cell B, ship to production
- Re-run EVAL-026 cross-architecture neuromod with fix → confirm cross-arch
- Update CHUMP_FACULTY_MAP.md with Sprint-1 status changes

**Sprint 1 budget:** ~$12 cloud. Faculty graduations expected: Perception,
Social Cognition, Attention (PARTIAL after baseline), Metacognication
(post-EVAL-030).

### Sprint 2 (Weeks 5-8): deeper validation

**Week 5-6 — Memory + Executive Function**
- Run EVAL-034 memory retrieval (~$5, 2 days) → graduate Memory or file followup
- Run EVAL-036 prompt-assembler ablation (~$3, 1 day)
- Author coordination fixture for EVAL-037

**Week 7 — multi-agent coordination + attention mitigation**
- Run EVAL-037 multi-agent coord A/B (~$2, 1 day) → graduate Executive Function
- Run EVAL-033 attention mitigation A/B (~$2, 1 day) → potentially graduate Attention

**Week 8 — belief-state ablation + EVAL-031 SAR investigation**
- Run EVAL-035 belief_state ablation (~$2, 1 day) → graduate Metacognition fully
- Begin EVAL-031 Search-Augmented Reasoning literature/eval

**Sprint 2 budget:** ~$14 cloud. Faculty graduations expected: Memory,
Executive Function, Attention (full), Metacognition (full).

### Sprint 3 (Weeks 9-12): Q4 prep + research narrative

**Week 9-10 — research narrative**
- Ship RESEARCH-001 public 2000+ A/B trials blog post / paper, now backed by
  6 newly-graduated faculties' worth of evidence
- Optional EVAL-039 longitudinal learning A/B if sprint capacity allows

**Week 11 — Q4 prep**
- File EVAL-040 (OOD problem solving) for Q4 execution
- Begin COMP-007 (AGENTS.md), COMP-008 (Recipes), COMP-010 (brew install)
  ecosystem-alignment work

**Week 12 — buffer week**
- Slack for any sweep that needs n=100 follow-up at significance
- Re-validation pass: confirm all 10 faculties' status in
  CHUMP_FACULTY_MAP.md is current

**Sprint 3 budget:** ~$5 cloud. No new faculty graduations; consolidation +
publication + Q4 setup.

## Total Q3 numbers

- **Cloud spend:** ~$31 (well within $5/sweep × 7 graduating-faculty sweeps + buffer)
- **Dev time:** ~9 weeks single-dogfooder equivalent
- **Faculty graduations targeted:** 6 (from 4 → 10 of 10 validated)
- **New gap entries created (already filed in PR #128):** 22
- **New gap entries this plan adds:** EVAL-032 / EVAL-033 / EVAL-034 / EVAL-035
  / EVAL-036 / EVAL-037 / EVAL-038 / EVAL-039 / EVAL-040 (9 more)

## Risk register

1. **EVAL-030 may not eliminate neuromod harm.** EVAL-029's mechanism analysis
   is well-grounded but the proposed fix (task-class detection) is heuristic.
   Risk: cell C still negative. Mitigation: design EVAL-030 as a sweep across
   3 candidate detection rules (regex-based, LLM-based, hybrid) so we have
   fallbacks even if the first attempt fails.

2. **Multi-hop QA fixture authoring is harder than budgeted.** Ambiguous
   ground truth on multi-hop questions can poison the eval. Mitigation:
   start with 10-question pilot before scaling to 30-question fixture; use
   cross-family judge agreement as a fixture-quality signal.

3. **CatAttack mitigations may not work.** Reasoning models have proven
   robustly distractable. Risk: EVAL-033 cell A/B/C all fail to mitigate.
   Mitigation: even a null result here is publishable (extends CatAttack
   findings to local-agent context). Acceptance criterion is "measure +
   attempt", not "fix."

4. **EVAL-037 multi-agent coord A/B requires a fixture we haven't designed
   yet.** Could blow the Week 6 timeline. Mitigation: defer to Sprint 3 if
   Sprint 2 fills.

5. **Cloud spend underestimated.** The +$3-5 per experiment estimates are
   based on n=50 single-fixture sweeps. If significance requires n=100 on
   any experiment, double the estimate. Mitigation: explicit n=50→n=100
   escalation only on findings worth confirming.

6. **External research lands that obsoletes our work.** If e.g. Block
   publishes a CatAttack mitigation in goose mid-Sprint, our EVAL-033 may
   want to incorporate. Mitigation: weekly check of AAIF + arxiv before
   each sprint planning session.

## Success metrics (faculty graduation criteria)

A faculty graduates from anything-other-than-COVERED+VALIDATED to
COVERED+VALIDATED if:

- A/B sweep is published in `docs/archive/2026-04/briefs/CONSCIOUSNESS_AB_RESULTS.md` with cross-
  family judges (Sonnet + Llama-3.3-70B at minimum), n ≥ 50 per cell, and
  Wilson 95% CIs reported.
- At least one cell delta is non-overlapping for at least one axis
  (`is_correct`, `did_attempt`, `hallucinated_tools`).
- The faculty's module(s) demonstrably contribute non-negatively to
  measured task performance, OR the negative contribution is documented
  with a follow-up gap to fix or remove.
- `CHUMP_FACULTY_MAP.md` is updated with the new status + cited evidence.

End-of-Q3 success state: **all 10 faculties COVERED+VALIDATED**, with
documented next-step gaps for any that needed redesign. This becomes
RESEARCH-001's evidence base — "we measured 10 cognitive faculties on a
local agent, here's what works and what doesn't" — a research artifact
no other open agent project can match.

## Cross-references

- `docs/CHUMP_FACULTY_MAP.md` — current faculty status
- `docs/archive/2026-04/STRATEGY_VS_GOOSE.md` — competitive positioning (archived)
- `docs/archive/2026-04/briefs/CONSCIOUSNESS_AB_RESULTS.md` — published findings
- `docs/eval/EVAL-029-neuromod-task-drilldown.md` — mechanism analysis
- `docs/gaps.yaml` — full gap registry (EVAL-027 through COG-022 already filed)
