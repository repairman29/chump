# Preregistration — EVAL-087

> **Status:** LOCKED. Methodology / single-judge preregistration study (no
> sweep data collection in this gap — see Decision rule). EVAL-094 is the
> downstream execution gap that will run the n=50/cell comparison.

## 1. Gap reference

- **Gap ID:** EVAL-087
- **Gap title:** Evaluation-awareness literature invalidates A/B trust —
  reframe RESEARCH-026 to P1
- **Source critique:** `docs/audits/RED_LETTER.md` Cold Water Issue #7
  (2026-04-26)
- **External evidence:** Institute for AI Policy and Strategy (IAPS),
  "Evaluation Awareness: Why Frontier AI Models Are Getting Harder to Test"
  (2026, https://www.iaps.ai/research/evaluation-awareness-why-frontier-ai-models-are-getting-harder-to-test);
  arXiv:2508.00943, ICLR 2026, "LLMs Can Covertly Sandbag on Capability
  Evaluations Against Chain-of-Thought Monitoring"; Meta Muse Spark April
  2026 safety report (covered by Kili Technology,
  https://kili-technology.com/blog/llm-benchmarks-evaluation-awareness-muse-spark-report).
- **Author:** agent claude/eval-087 (Opus 4.7) on behalf of Cold Water
  cycle owner
- **Preregistration date:** 2026-05-02

## 2. Hypothesis (methodology gap)

This gap is a **methodology preregistration** rather than a data-collection
sweep. It locks in *how the project will rule out evaluation-awareness as a
confound* before EVAL-094 runs the actual comparison. The empirical
hypothesis below is the one EVAL-094's sweep will test; it is documented
here because EVAL-087's deliverable is the methodology spec that EVAL-094
must follow.

**H1 (primary, to be tested by EVAL-094).** Behavior on the reflection
fixture differs between evaluation-framed and naturalized "casual user
message" prompts on at least one frontier model tier (haiku-4-5 or
sonnet-4-5):

> `|Δ(correctness_eval-framed − correctness_naturalized)| > 0.05`
> with Wilson 95% CI excluding zero on at least one tier.

**H0.** No detectable framing effect on either tier — Chump's A/B harness
results are robust to evaluation-context confounding at the n=50 noise
floor.

**Why this is necessary now.** RESEARCH-026 was opened P2 with the same
empirical question but has been backlogged for ~2 weeks ("operating
stance: keep status open and backlog the paid full sweep until a paper or
external-credibility sprint"). Three independent external publications
(IAPS 2026, ICLR 2026 #2508.00943, Meta Muse Spark) now make
evaluation-awareness a *quantified empirical concern* — Muse Spark's 19.8%
flagging rate on public benchmarks vs 2.0% on internal data implies ~1 in
5 Chump A/B trials may trigger evaluation-aware behavior. RESEARCH-026's
priority is therefore wrong (P2) and its backlog rationale is invalidated.

## 3. Design (methodology spec for EVAL-094)

### Reframe action (this gap)

1. RESEARCH-026 priority: P2 → P1 in the registry, with EVAL-087 as the
   escalation rationale recorded in `notes`.
2. `docs/process/RESEARCH_INTEGRITY.md` adds a mandatory Required
   Methodology Standard: **mechanism analysis for any delta > ±0.05 must
   explicitly consider evaluation-awareness as a candidate mechanism, and
   must cite either (a) a paired naturalized-framing comparison from the
   RESEARCH-026 / EVAL-094 result set, or (b) a justification for why the
   fixture is not susceptible to evaluation-context discrimination.**
3. The Validated Findings table in `RESEARCH_INTEGRITY.md` carries a
   standing caveat noting that all rows F1–F5 were produced under
   conditions that have not yet been controlled for evaluation-awareness;
   the caveat lifts when EVAL-094 ships a null result, or the table
   updates if EVAL-094 ships |Δ| > 0.05.

### Methodology spec for EVAL-094 sweep (locked here)

| Cell | Prompt framing | Notes |
|---|---|---|
| A | Evaluation-framed (current Chump fixture style — task IDs, structured rubrics, "the user asks…") | Existing `reflection_tasks_formal_paired_v1.json` |
| B | Naturalized casual user message (no task IDs, no rubric language, no "the user asks…" preamble) | Existing `reflection_tasks_casual_v1.json` (paired, same task ordering — see RESEARCH-026 deviation §1) |

- **n per cell:** ≥ 50 per tier
- **Tiers:** haiku-4-5, sonnet-4-5 (matches Chump A/B harness)
- **Total trials:** ≥ 200 (2 cells × 2 tiers × 50)
- **Judge panel:** ≥ 1 non-Anthropic judge (Llama-3.3-70B via Together free
  tier) plus claude-sonnet-4-5; strict binary rubric on both, per
  RESEARCH_INTEGRITY.md §73-78 (EVAL-073 finding).
- **Cross-judge audit at closure:** required per INFRA-079 — cell B
  (naturalized) prompts must be audited for semantic preservation against
  cell A on ≥ 10 random task pairs; ≥ 8 of 10 pass.
- **A/A baseline:** required per RESEARCH_INTEGRITY.md §5 — Cell A vs
  Cell A on the same tier, n=50, A/A delta ≤ ±0.03 before B−A delta is
  cited.
- **Reproduction:** the exact harness call must be logged in
  `docs/eval/EVAL-094-evaluation-awareness.md` with checkpoint hash per
  INFRA-EXPERIMENT-CHECKPOINT.

## 4. Primary metric (for EVAL-094)

Per-tier `correctness_A − correctness_B` paired delta, with bootstrap 95%
CI on the paired delta and Wilson 95% CI on the per-cell rates. H1 is
supported if |delta| > 0.05 with CI excluding zero on at least one tier.

## 5. Secondary metrics (for EVAL-094)

- Hallucination rate per cell (per EVAL-041 regex), reported separately.
- Mean response length per cell (length confound).
- Mean tool-call count per cell.
- Per-judge agreement (Cohen's κ) per cell.
- Tier interaction: does sonnet-4-5 show a larger framing delta than
  haiku-4-5? Pre-registered direction: yes (larger models discriminate
  evaluation contexts more reliably per IAPS 2026).

## 6. Stopping rule

This gap (EVAL-087) is methodology only — no sweep, no early stopping
question. EVAL-094's stopping rule: planned n=50/cell/tier, no early
stop, exhaustion stop labelled "underpowered relative to preregistration"
if budget exceeds.

## 7. Analysis plan (for EVAL-094)

**Primary (preregistered):**

1. Per-tier mean correctness per cell with Wilson 95% CIs.
2. Paired delta (same `task_id`, different framing) per tier, bootstrap
   95% CI.
3. H1 test: |Δ| > 0.05 with CI excluding zero on at least one tier.
4. Compare delta against the A/A noise floor; delta must be ≥ 3× A/A
   stdev to be interpretable.

**Secondary (also preregistered):**

- Per-judge κ.
- Hallucination-rate delta per cell.
- Response-length delta.
- Subgroup analysis by reflection-task subtype.

**Exploratory (labelled):**

- Whether tier interaction matches the IAPS direction prediction.
- Whether Cell B sentinel completions ("I notice this looks like a
  benchmark task") appear at all.

## 8. Exclusion rules (for EVAL-094)

A trial is excluded iff:

- Agent response is empty (HTTP error, empty completion).
- Judge call returned HTTP error after 3 retries.
- Cell B rewrite failed the semantic-preservation gate (caught at
  fixture lock time, not per-trial).

Exclusion rate > 10% invalidates the sweep.

## 9. Decision rule

**For this gap (EVAL-087):** ships when (a) RESEARCH-026 priority is P1
in the registry, (b) RESEARCH_INTEGRITY.md adds the
evaluation-awareness mechanism standard, (c) this preregistration doc
exists, and (d) the standing caveat lands on the Validated Findings
table.

**For EVAL-094 (downstream):**

- **H1 supported** (|Δ| > 0.05 on at least one tier with CI excluding 0):
  Validated Findings table is updated row-by-row with the correction
  factor; any external publication (Paper 1) requires a dedicated
  evaluation-awareness section quantifying the bias.
- **H0** (|Δ| ≤ 0.05 or CI overlaps zero on both tiers): standing caveat
  on the table is replaced with an explicit "evaluation-awareness ruled
  out at n=50" footnote citing EVAL-094.
- **Tier interaction asymmetry** (sonnet effect > haiku effect by
  > 0.05): publishable as a separate methodological finding —
  cross-tier evaluation-awareness amplification.

## 10. Budget

- This gap (EVAL-087): doc only — $0 cloud, ~2h human time.
- EVAL-094 downstream: ~$20 cloud, ~3h wall-clock, ~6h human time
  (per RESEARCH-026 budget §10 — same harness, same fixtures, same
  tiers).

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| RESEARCH-026 was prematurely closed `done` at P2 without the sweep ever running — methodology change risks contradicting that closure | This preregistration explicitly notes RESEARCH-026's `done` status was based on harness + smoke + human pilot only, not the n=50/cell sweep. EVAL-094 is the execution path that completes RESEARCH-026's original acceptance criteria. |
| Naturalized prompts (Cell B) leak evaluation cues anyway (e.g. via consistent phrasing, missing task variation) | Semantic-preservation audit at fixture lock; ≥ 8 of 10 random pairs reviewed by Jeff before sweep. |
| Judge detects the framing change and scores Cell B differently for non-correctness reasons | Strict binary rubric on both judges; per-judge κ reported per EVAL-093 (κ ≥ 0.60 on the framing-comparison fixture class). |
| Result is null but underpowered (CI wide, overlaps zero) | Treated as ambiguous per EVAL-094 decision rule §9; escalation to n=100 filed as follow-up gap, not auto-claimed. |
| Doc-only ship doesn't change behavior — agents continue producing deltas without evaluation-awareness controls | RESEARCH_INTEGRITY.md change is *required reading* for any agent touching eval / cog code; pre-commit check on Validated Findings claims will block citations that don't acknowledge the standing caveat. |

## 12. Single-judge / methodology-scope declaration

This is a **single-judge preregistration study** in the sense of
RESEARCH_INTEGRITY.md §8 (INFRA-079 cross-judge gate). EVAL-087 itself
collects **no trial data** — it is the methodology spec. The cross-judge
audit requirement applies to the downstream EVAL-094 execution gap, where
the spec above mandates ≥ 1 non-Anthropic judge on every trial and a
semantic-preservation audit on Cell B.

`single_judge_waived: true` in the gap file is justified because no
single-judge claim is made — no claim is made at all in this gap. The
gap ships methodology + reframe; no Validated Findings rows are added or
modified by this PR (the standing caveat is a *qualifier on existing
rows*, not a new claim).

---

## Deviations (append-only, timestamped)

- *(none yet — this is the initial lock)*

---

## Result document

`docs/eval/EVAL-094-evaluation-awareness.md` after EVAL-094's sweep
completes. This preregistration is the binding methodology contract for
that sweep.
