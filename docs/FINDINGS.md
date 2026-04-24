# Chump — Empirical Findings

**Updated:** 2026-04-21
**Status:** living index, sectioned by replication maturity
**Companion docs:**
[Research paper (rendered)](https://repairman29.github.io/chump/research-paper.html) ·
[`book/src/research-paper.md` (source)](https://github.com/repairman29/chump/blob/main/book/src/research-paper.md) ·
[Research integrity (rendered)](https://repairman29.github.io/chump/research-integrity.html) ·
[`docs/RESEARCH_INTEGRITY.md` (source)](https://github.com/repairman29/chump/blob/main/docs/RESEARCH_INTEGRITY.md) ·
[`docs/CHUMP_FACULTY_MAP.md` (source)](https://github.com/repairman29/chump/blob/main/docs/CHUMP_FACULTY_MAP.md) ·
[`docs/RESEARCH_EXECUTION_LANES.md` (source)](https://github.com/repairman29/chump/blob/main/docs/RESEARCH_EXECUTION_LANES.md) (free-tier vs batched paid work)

---

## Purpose

This document is the canonical, citable index of Chump's published empirical
claims. Findings are listed here only if they either meet the project's
[research-integrity standard](./RESEARCH_INTEGRITY.md) (calibrated effect sizes,
Wilson 95% confidence intervals, A/A baselines where applicable, and cross-family
LLM judges where the underlying signal is plausibly judge-biased) **or** are
explicitly labeled *preliminary* with the missing criteria called out.

It is also a defensive instrument: claims that have not yet replicated, claims
under methodological revision, and claims explicitly retracted are listed
below with the same prominence as positive findings. The
["honest limits"](#honest-limits) and
["replication status"](#replication-status) sections are not optional.

This index does *not* duplicate the source research artifacts; it points to
them. Each finding cites the gap ID, the canonical doc under `docs/eval/`, and
the JSONL data files where applicable.

For a chronological record of broken instruments and reframed/retracted claims,
see [Oops log (rendered)](https://repairman29.github.io/chump/oops.html) ·
[`docs/OOPS.md` (source)](https://github.com/repairman29/chump/blob/main/docs/OOPS.md).

---

## At a glance

| # | Finding | n | Effect | Source | Status |
|---|---|---|---|---|---|
| F1 | Scaffolding U-curve — non-monotonic lessons-block effect by model size | 20/model × 5 models + 50 (neuromod) | 1B +10pp; 3B/7B −5pp; 8B 0pp; 14B +10pp | [Study 2](#f1-the-scaffolding-u-curve) | Single-team, awaiting independent replication |
| F2 | Lessons-block reliably increases fake-tool-call emission on Anthropic frontier | 2,600+ trial pairs | +0.14 **pp** mean (≈ +0.0014 absolute rate) (10.7× A/A noise floor) | [Study 1](#f2-lessons-block-fake-tool-call-inflation) | **Anthropic-specific** (EVAL-071: DeepSeek-V3.1 and Qwen3-235B show 0% halluc in both cells) |
| F3 | Cross-architecture neuromod harm is *localized* to two task clusters | 4 sweeps, 50 tasks each | Aggregate −10 to −16 pp retired (EVAL-069); harm concentrated in dynamic conditional-chain + monosyllabic-token tasks | [EVAL-029 drilldown](#f3-cross-architecture-neuromod-harm-task-cluster-localization) | 4/4 sweeps direction-consistent; aggregate artifact of broken scorer (EVAL-063 + EVAL-069 both delta=0) |
| F4 | LLM judges from different families instantiate the question their tasks probe *under lenient prompts* — under a shared strict binary rubric the disagreement collapses to 0 (EVAL-073, n=90, 100% agreement) | 300 trials (100×3 fixtures), 2 judges + 90 both-strict | lenient: reflection κ=0.722, perception κ=0.496, neuromod κ=0.420; strict: all fixtures agree 100% | [EVAL-042, EVAL-070, EVAL-073](#f4-cross-judge-disagreement-instantiates-the-underlying-judgment) | Reframed 2026-04-20: the disagreement was a prompt-asymmetry artifact, not a model-family disagreement |
| F5 | LLM judges show systematic bias relative to human grading on agent-task scoring | 12 tasks × 3 fixtures (preliminary) | Cohen's κ vs human: 0.059 / −0.250 / 0.250 (all below 0.75 threshold) | [EVAL-046](#f5-systematic-llm-judge-bias-vs-human-grading) | Preliminary at n=12; v2 prompt fix shipped, full re-score pending |
| F6 | Few-shot exemplar + explicit "ship rule" unlocks instruct-tuned OSS models for agent loops | 9 trials across 4 model classes | Existence proof: Qwen3-Coder-480B shipped 737 LOC end-to-end PR at ~$0.20 cost where vanilla and directive-only prompts failed | [COG-031 V2-V9](#f6-few-shot-exemplar-unlocks-oss-models-for-agent-loops) | n=1 production claim; replication trial held pending methodology track clearance |
| — | **RESEARCH-026** (observer-effect / eval-framing) | *pending* | Formal vs casual naturalized prompts on the reflection fixture — paired `task_id`, Wilson CIs, preregistered §9 | [`docs/eval/RESEARCH-026-observer-effect.md`](eval/RESEARCH-026-observer-effect.md) | Harness + human gate + smoke on `main` (2026-04-21); **full sweep + Wilson row deferred** to a paper/credibility sprint — see observer memo § Operating stance; gap stays **open** until then |

**Five empirical findings + one transferable technique.** All are sourced
inside this repository; none have been externalized as preprints, blog posts,
or external publications as of 2026-04-20.

---

## Findings

### F1. The Scaffolding U-curve

**Claim.** The effect of injecting a lessons-block (system-role placement,
episode-distilled directives) on agent task performance is *non-monotonic*
across model sizes. Small (1B) and large (14B) models benefit by roughly
+10 percentage points on pass-rate; mid-size models (3B, 7B) are *harmed*
by approximately −5 pp; the 8B model shows no detectable effect.

**Why this matters.** Most published work on retrieval-augmented or
exemplar-augmented prompting assumes monotonic benefit — bigger context
window or more examples implies more help. This finding empirically
falsifies that assumption for a specific intervention class (system-role
lessons block), evaluated across a controlled scan of model sizes from 1B
to 14B parameters. The implication for production agent design is concrete:
a single fixed lessons block is the wrong shape for any heterogeneous fleet
of agents; the intervention must be model-tier-aware.

**Methodology.** A/B comparison of framework-on (lessons block injected at
system role) vs framework-off (bare prompt). Five local models
(qwen2.5:1.5b, qwen2.5:3b, qwen2.5:7b, qwen2.5:8b, qwen3:14b) ran on the
same task fixture. n=20 per cell per model. Pass-rate scored heuristically.
A focused neuromodulation ablation on qwen3:8b (n=50) measured a +12 pp
pass-rate improvement on dynamic tasks and a 33% reduction in tool calls.

**Effect sizes.**

| Model | Cell A (off) | Cell B (on) | Δ (B − A) | Direction |
|---|---|---|---|---|
| qwen2.5:1.5b | baseline | +10 pp | +0.10 | helps |
| qwen2.5:3b | baseline | −5 pp | −0.05 | hurts |
| qwen2.5:7b | baseline | −5 pp | −0.05 | hurts |
| qwen2.5:8b | baseline | 0 pp | 0.00 | neutral |
| qwen3:14b | baseline | +10 pp | +0.10 | helps |

**Caveats.**
- n=20 per cell per model is small; CIs not yet computed for the per-model
  results in the source paper.
- Task fixture is a Chump-internal instruction-following set; generalization
  to OOD task domains has not been measured (see EVAL-040).
- Single team, single hardware setup, single quantization regime.

**Source.** [Research paper](./research-paper.md)
Study 2. Raw data:
`logs/ab-cloud/qwen3-14b-*.jsonl` and the four 1B–8B equivalents.

---

### F2. Lessons-block fake-tool-call inflation

**Claim.** On Anthropic frontier models (claude-haiku-4-5, claude-opus-4-5),
injecting the lessons block at the system role *reliably increases* the rate
at which the agent emits fabricated tool-call markup (XML resembling
`<function_calls>` but without an actual tool invocation). Mean effect
+0.14 percentage points (≈ +0.0014 absolute rate on a 0–1 indicator) across
2,600+ trial pairs. The effect is
**10.7× the calibrated A/A noise floor**.

**Why this matters.** This is a measured, statistically significant
*negative* effect of a production intervention on a frontier model. The
intervention is shipping in the agent today; it is making this specific
failure mode more common. The effect was invisible to single-axis
binary pass/fail scoring because the LLM judge actively rewards
hallucinated tool execution — which is itself the EVAL-046 finding (F5).
F2 is therefore inseparable from the F5 judge-bias work; the bias hides
the harm.

**Methodology.** Multi-axis scoring harness (correctness +
hallucinated-tools detection + did_attempt). A/A controls computed the
noise floor at +0.013 pp on the same fixture with the same model. The
B effect of +0.14 pp exceeds that floor by 10.7×. Two frontier models
tested independently. Hallucinated-tools detection is a regex/grammar
match for tool-invocation markup not followed by an actual tool round-trip.

**Effect sizes.** Mean Δ(hallucinated_tools) = +0.140 pp across both models,
n = 2,600+ A/B trial pairs. A/A baseline floor = +0.013 pp on identical
fixtures.

**Caveats.**
- Single research group, single harness, single fixture family.
- **Anthropic-specific:** EVAL-071 tested DeepSeek-V3.1 (n=61/cell) and
  Qwen3-235B (n=83/cell) under identical conditions. Both showed 0%
  hallucinated-tools in both cells — F2 does not generalize beyond Anthropic
  frontier models. Lessons injection was *differently harmful* on non-Anthropic
  models: correctness drop of −6.56pp (DeepSeek) and −3.61pp (Qwen3), with
  refusal-to-attempt as the failure mode rather than tool hallucination.
- The +0.14 pp effect is small in absolute terms; what makes it notable
  is the floor calibration (10.7× A/A), not the headline magnitude.

**Source.** [Research paper](./research-paper.md)
Study 1. [`docs/CONSCIOUSNESS_AB_RESULTS.md`](./CONSCIOUSNESS_AB_RESULTS.md)
holds the per-trial breakdowns. Raw JSONLs under `logs/ab-cloud/`.

---

### F3. Cross-architecture neuromod harm task-cluster localization

**Claim.** The cross-architecture lessons-block harm signal first reported
in EVAL-026 (−10 to −16 pp aggregate `is_correct` regression across 4
distinct model families: qwen2-7b, qwen3-235b, llama70b, and the cog016
n=100 sweep) is *not* a generalized degradation. It is concentrated in
two specific task clusters:

1. **Dynamic / adaptive tasks containing an explicit conditional fallback
   chain** (e.g., "do X, if it fails do Y, then Z"). Per-task harm of −50
   to −75% on `is_correct` in 3 of 4 model architectures tested.
2. **Monosyllabic chat tokens** (`lol`, `sup`, `wait`, `k thx`). Per-task
   harm of −75% in 3 of 4 architectures; harm is consistent across local
   and cloud models.

Tasks outside these two clusters show roughly zero effect.

**Why this matters.** A diffuse "the lessons block hurts performance"
finding is hard to act on. A localized "the lessons block hurts these two
specific task classes" finding is directly actionable: gate the
intervention on task class. EVAL-030 and COG-027 implement exactly this —
the lessons block is suppressed on conditional-chain prompts and trivial
tokens, by default ON in the production prompt assembler — and that gating
is itself shippable mitigation grounded in this localization data.

**Methodology.** Per-task ranking of the cross-architecture aggregate
signal. Each task scored across all 4 sweeps; weighted Δ computed. Tasks
ranked by `models_neg = k/N` (number of sweeps in which the task was
negative for the lessons-on cell). Multi-model harm = `models_neg ≥ 3/4`.
Hallucinated-tool rate ≈ 0 in both cells across all 4 sweeps — this is a
*content-quality* regression, not a refusal regression.

**Effect sizes (top localized harm).**

| Task class | avg Δ (B − A) | models negative | Cluster |
|---|---|---|---|
| `dynamic-05-policy-confront` | −75% | 3/4 | conditional-chain |
| `dynamic-08-budget-aware` | −75% | 3/4 | conditional-chain |
| `dynamic-13-escalation-chain` | −75% | 3/4 | conditional-chain |
| `trivial-14-laugh` (`lol`) | −75% | 3/4 | monosyllabic |
| `dynamic-03-retry-loop` | −50% | 3/4 | conditional-chain |

**Caveats.**
- **AUDIT-3 CRITICAL (2026-04-24): EVAL-069 credibility broken.** EVAL-069
  was intended to re-validate EVAL-026 under the fixed LLM-judge scorer
  (EVAL-060). However, EVAL-069 closed 2026-04-21 using python3 shebang
  (python3=3.14, no anthropic module), which caused silent fallback to
  exit_code_fallback scorer. The shebang was not fixed to python3.12 until
  2026-04-22 (commit 8f3a994). EVAL-069 JSONL output confirms `"scorer":
  "exit_code_fallback"` in actual rows. **The neuromod aggregate signal has
  never been properly measured under a working LLM judge.** F3 task-cluster
  localization (EVAL-029) stands independently and is unaffected.
- **The EVAL-026 aggregate −10 to −16 pp signal: model-tier-specific, not
  generally retired.** EVAL-069 was meant to validate this but failed due to
  scorer fallback. The 4 EVAL-026 source sweeps show unequal measurement
  quality: the qwen2-7b cell used self-judging (`judge_model=qwen2.5:7b` —
  methodology defect); the **cog016-n100 cell used the cleanest protocol**
  (agent=`claude-haiku-4-5`, judges=Sonnet+Llama-70B cross-family, n=100/cell
  on the `run-cloud-v2.py` direct-API harness — NOT the broken binary harness
  EVAL-060 fixed). The cog016-n100 cell showed **Δ = −0.15 with proper
  methodology**.
- The two re-tests (EVAL-063: Llama-3.3-70B; EVAL-069: Ollama qwen2.5:14b)
  used **different agents** from claude-haiku-4-5; both showed null results
  (EVAL-063 confirmed clean, EVAL-069 compromised by scorer fallback).
  Comparison is complicated.
- **EVAL-076 (2026-04-21): H1 directionally confirmed on claude-haiku-4-5.**
  Analysis of the cog016-n100 cell (n=100/cell, neuromod fixture,
  judges=Sonnet-4-5+Llama-70B) confirms Δ = −0.15 pp (Cell A 0.370 vs Cell B
  0.520). CIs barely overlap (A:[0.282,0.468] vs B:[0.423,0.615]; overlap=4.5
  pp), so the result is directional not statistically confirmed. Cross-judge
  Cohen κ = 0.505 (below 0.70 protocol threshold). F3 should now be read as:
  **"task-cluster localization robust; aggregate magnitude directionally
  confirmed on haiku-4-5 (H1 supported); full statistical confirmation
  requires n ≥ 200/cell or κ-improved instrument."** F1+F3 converge: the
  Scaffolding U-curve mid-tier harm zone includes claude-haiku-4-5.
- Some `cog016-only` tasks ran in only one sweep with n=1 trial — a
  single flip = 100%. Those are flagged low-evidence in the source doc.

**Source.**
[`docs/eval/EVAL-029-neuromod-task-drilldown.md`](./eval/EVAL-029-neuromod-task-drilldown.md).
Mitigation in production:
`src/reflection_db.rs::is_conditional_chain` (EVAL-030),
`src/agent_loop/prompt_assembler.rs::CHUMP_COG027_GATE` (COG-027).

---

### F4. Cross-judge disagreement instantiates the underlying judgment

**Claim.** When two LLM judges from different families
(`claude-sonnet-4-5` and `meta-llama/Llama-3.3-70B-Instruct-Turbo`) score
the same neuromod fixture trials, their inter-judge agreement is
**Cohen's κ = 0.42** — meaningful disagreement, well below the
substantial-agreement threshold of κ ≥ 0.70. The disagreement is *not
randomly distributed*: it is concentrated on the exact task class
(conditional-fallback chains) where the lessons-block harm itself appears
in F3. Llama-70B systematically rewards direct-action responses; Sonnet
systematically rewards careful hedging.

**Why this matters.** This is a methodological finding with two
implications. First, single-judge LLM-as-judge protocols are insufficient
for agent-task scoring on tasks where the "right" response is
philosophically contested (act vs. ask, hedge vs. commit). Second, the
disagreement isn't noise — it instantiates the underlying cognitive
question the tasks were designed to probe. The lessons-block-harm finding
is itself partially an artifact of which judge you use.

**Methodology.** EVAL-042 cross-family judge re-run. n=50 tasks × 2 cells
per fixture × 3 fixtures (reflection, neuromod, perception). Each trial
scored independently by both judges. Median verdict at threshold 0.5.
Cohen's κ computed over binary verdicts.

**Effect sizes.**

| Fixture | κ | Verdict |
|---|---|---|
| reflection | **0.722** | Substantial agreement |
| neuromod | **0.420** | Meaningful disagreement |
| perception | (in source doc) | (in source doc) |

The neuromod-fixture disagreement is concentrated in the dynamic /
conditional-chain task cluster identified in F3.

**Caveats.**
- Two judges, both relatively recent (claude-sonnet-4-5 + Llama-70B-Instruct).
  A third judge from a different lineage (DeepSeek, Qwen-Instruct, GPT)
  would strengthen the finding and is partially queued
  ([EVAL-068](./eval/) acceptance pending).
- κ is computed at a fixed threshold (0.5); threshold sweep would
  characterize disagreement more thoroughly.
- **Reframed 2026-04-20 ([EVAL-073](./eval/EVAL-073-both-strict-rescore.md)).**
  The disagreement documented above was measured with Sonnet on its
  original lenient, partial-credit-friendly prompt and Llama on the
  strict binary rubric (EVAL-072). When *both* judges are given the
  same strict binary rubric, inter-judge agreement on the same 90
  rows is **100%** across all three fixtures (reflection 30/30,
  perception 28/28, neuromod 32/32). The "philosophically contested
  task" framing was measuring a prompt asymmetry, not a model-family
  disagreement. The load-bearing methodological implication stands
  (strict binary rubrics required for cross-family panels); the
  "different judges instantiate different answers" framing is retired.

**Source.**
[`docs/eval/EVAL-042-crossjudge.md`](./eval/EVAL-042-crossjudge.md).
Raw: `logs/ab/eval-042-crossjudge-*.{jsonl,summary.json}`.

---

### F5. Systematic LLM-judge bias vs human grading

**Claim.** On three Chump A/B fixtures (reflection, perception, neuromod),
LLM-as-judge protocols (using `claude-haiku-4-5` and equivalent) show
**systematic, directional disagreement with human grading**. Cohen's κ
between LLM and human verdicts: reflection 0.059, perception −0.250,
neuromod 0.250. All are below the 0.75 substantial-agreement threshold;
perception is *negative*, indicating active anti-correlation. The
disagreement clusters into two reproducible bias patterns:

1. **Tool-hallucination reward.** The LLM judge rewards responses that
   *narrate* tool execution (including `<function_calls>` markup with
   fabricated output) at higher rates than human graders. The judge treats
   "mentions using a tool" as equivalent to "actually invokes a tool." A
   v2 prompt fix explicitly distinguishes the two and reduced the bias on
   the EVAL-046 calibration set.
2. **Clarification penalization.** The LLM judge fails responses that
   ask appropriate clarifying questions on genuinely ambiguous prompts
   (e.g., `trivial-03-yes`: "yes please" with no context). Human graders
   pass these responses; the LLM judge gives them score 0.0.

**Why this matters.** This is the single most consequential finding in the
project for downstream interpretation. *Every prior LLM-judged result* —
including F2's halluc-inflation finding, F3's localization, every faculty
ablation result — is implicated. The v2 prompt fix is a published
mechanism for reducing the bias, and the EVAL-060 methodology amendments
ban the most-egregious shortcut (exit-code-only scoring on ablation
sweeps). The path forward is calibration, not abandonment.

**Methodology.** EVAL-041 human grading on n=4 tasks per fixture (n=12
total). Each task graded by human and by LLM judge independently. Verdicts
binarized at 0.5. Cohen's κ over binary outcomes.

**Effect sizes.**

| Fixture | Comparable pairs | Agreement | Cohen's κ vs human |
|---|---|---|---|
| reflection | 8 | 50.0% | 0.059 |
| perception | 8 | 37.5% | **−0.250** |
| neuromod | 8 | 62.5% | 0.250 |

All κ < 0.75 (substantial-agreement threshold); perception's κ is
negative.

**Caveats.**
- **n=12 total tasks is preliminary.** EVAL-046 v2 prompt has shipped;
  the full re-score awaits 30 additional human labels (also tracked in
  EVAL-046 doc).
- Single human grader (Jeff). Inter-rater reliability on the human side
  is not measured.
- The systematic biases identified are categorical patterns; their full
  taxonomy is not exhaustive.

**Source.**
[`docs/eval/EVAL-046-judge-calibration.md`](./eval/EVAL-046-judge-calibration.md),
[`docs/eval/EVAL-010-analysis.md`](./eval/EVAL-010-analysis.md).
Human labels: `docs/eval/EVAL-010-labels-jeff.md`.

---

### F6. Few-shot exemplar unlocks OSS models for agent loops

**Claim.** Together-served instruct-tuned models (Qwen3-235B-Instruct,
Llama-3.3-70B-Instruct, Qwen3-Coder-480B-Instruct, DeepSeek-V3.1) all
default to *conversational behavior* when given a Chump dispatched-agent
prompt — chatty exits ("Would you like me to focus on a specific
domain?"), iteration-cap exhaustion on read loops, multiple-choice menus.
Vanilla and directive-only overlays do not change this behavior. **Adding
a single grounded few-shot exemplar trace** (`read_file → patch_file →
chump-commit.sh → bot-merge.sh → terminal "PR #N"`, drawn from a real
prior shipped PR) **plus an explicit "SHIP RULE" directive** (any commit
must be immediately followed by `bot-merge.sh`) crosses the chat-default
barrier. The model produces real commits and ships PRs.

**Why this matters.** The dominant published technique for getting OSS
models into agent mode is fine-tuning. Fine-tuning is expensive and
deployment-specific. A working prompt-engineering technique that
demonstrably moves an OSS model from "0 commits across 4 trials" to
"shipped a 737-LOC feature PR end-to-end" at ~$0.20 cost is directly
transferable to anyone building agent loops on Together / Ollama /
mistral.rs. The technique is documented at the level of code — anyone
can copy `src/model_overlay.rs` into their own harness.

**Methodology.** COG-031 trial sequence V2 through V9. Same dispatched-
gap prompt across all trials, identical `chump-orchestrator` config,
varying only the model + overlay. Each trial dispatches 2 subagents to
2 separate worktrees, runs with `--max-parallel 2`, monitors for either
PR shipped or iteration-cap exhaustion.

**Effect sizes.**

| Trial | Model | Overlay | Result |
|---|---|---|---|
| V2 | Qwen3-235B-Instruct (chat) | none | iter-cap on read loop |
| V3 | Qwen3-235B-Instruct (chat) | none, iter=50 | iter-cap on read loop |
| V4 | Llama-3.3-70B-Instruct (chat) | none | iter-cap on read loop |
| V5 | Qwen3-Coder-480B (coder-tuned) | none | "Would you like me to..." chatty exit |
| V6 | Qwen3-Coder-480B | step-1 directive (preamble) | "I'm happy to help — what should I call you?" *worse* |
| V7 | DeepSeek-V3.1 | step-1 directive | multiple-choice menu *worst* |
| V8 | Qwen3-Coder-480B | step-2 (directive + exemplar) | 2 real commits, no PR (stopped at chump-commit) |
| **V9** | **Qwen3-Coder-480B** | **step-3a (+ SHIP RULE)** | **PR #224 SHIPPED — 737 LOC, 2 commits, MERGED** |

**Caveats.**
- **n=1 production claim** — V9 shipped one PR. Replication trial
  (V10–V14) is on deliberate hold pending methodology track clearance
  ([`docs/eval/COG-031-STEP3A-V9-SHIPPED-2026-04-20.md`](./eval/COG-031-STEP3A-V9-SHIPPED-2026-04-20.md))
  to avoid coupling unvalidated cost-routing claims to in-flight
  eval-signal validation.
- COMP-009 (the gap V9 shipped on) is mostly-additive scaffolding work
  (two new MCP server crates). Harder gap classes — refactors,
  cross-file coordination, data-flow fixes — have not been tested on
  this backend.
- The technique is a prompt-engineering bandaid; the long-term path is
  fine-tuning a small OSS model on successful Chump traces (~$50). The
  bandaid buys the time to do that properly.

**Source.**
[`docs/eval/COG-031-STEP3A-V9-SHIPPED-2026-04-20.md`](./eval/COG-031-STEP3A-V9-SHIPPED-2026-04-20.md),
[`docs/eval/COG-031-STEP2-V8-ROOFTOP-2026-04-19.md`](./eval/COG-031-STEP2-V8-ROOFTOP-2026-04-19.md),
[`docs/eval/COG-031-STEP1-RESULT-2026-04-19.md`](./eval/COG-031-STEP1-RESULT-2026-04-19.md),
[`docs/eval/COG-026-TOGETHER-DISPATCH-2026-04-19.md`](./eval/COG-026-TOGETHER-DISPATCH-2026-04-19.md).
Implementation: `src/model_overlay.rs`. Shipped PR: #224.

---

## Methodological contributions

In addition to the empirical findings above, the project's research-process
discipline is itself a contribution worth surfacing for external readers.
None of the items below are "finding" claims; they are infrastructure that
makes the findings credible.

- **A/A noise-floor calibration as standard practice.** Every A/B sweep
  ships an A/A baseline on the same fixture and same harness. Reported
  effects are framed as multiples of the A/A floor (F2: 10.7× floor),
  not as absolute percentage points alone. See
  [`docs/RESEARCH_INTEGRITY.md`](./RESEARCH_INTEGRITY.md).
- **Cross-family LLM judges are mandatory.** No claim cited externally
  may rely on a single Anthropic-family judge. The EVAL-042 work
  established this. EVAL-068 extends to a third lineage.
- **Cohen's κ thresholds are quantitative, not aspirational.** κ ≥ 0.70
  for inter-judge agreement is a publishable threshold; below that, the
  claim is downgraded or the finding is conditioned on which judge.
- **Wilson 95% confidence intervals are computed and displayed.**
  Point estimates without CIs are not accepted.
- **Adversarial internal review.** An automated "Red Letter" / cold-water
  bot files quarterly issues critiquing the project's own research
  integrity ([`docs/RED_LETTER.md`](./RED_LETTER.md)). Issue #3
  (2026-04-20) directly triggered the EVAL-060 instrument fix and the
  EVAL-061 NULL-faculty-label suspension. The bot is not a sibling
  agent in the dispatcher fleet — it operates as adversarial review.
- **Methodology gap-IDs blocking faculty closure.** EVAL-060 and EVAL-061
  prevented EVAL-059 from cascading three additional invalid faculty
  labels into the faculty map. The gap-blocking mechanism is encoded in
  `docs/gaps.yaml` `current_priorities.explicit_holds` and respected by
  the orchestrator's preflight check.
- **Multi-agent coordination via lease files.** Concurrent dispatched
  subagents read `.chump-locks/*.json` lease files before claiming work,
  preventing the "two agents work on the same gap and stomp each other"
  pattern. See
  [`docs/AGENT_COORDINATION.md`](./AGENT_COORDINATION.md).
- **Shipped-not-merely-claimed validation.** PR #224 (F6 production
  claim) is on `main` and merged. Faculty validation requires shipped
  evidence, not draft PRs. See
  [`docs/CHUMP_FACULTY_MAP.md`](./CHUMP_FACULTY_MAP.md) "shipped-by-PR"
  citations.

---

## Mechanism evidence

**RESEARCH-022 (2026-04-20).** A post-hoc text-scan of agent responses across
610 eval-025 trials asked: does the agent's visible reasoning text actually
reference the state injected by each module?

**Method.** `scripts/ab-harness/analyze-module-references.py` scanned the
`agent_text_preview` field (truncated response text) in four eval-025 archive
JSONLs (neuromod n=200, perception n=200, reflection n=200, smoke n=10) for
module-specific keyword signatures:

| Module | Injection format |
|--------|-----------------|
| neuromodulation | `"Neuromod: DA=... NA=... 5HT=... (label)"` |
| belief_state | `"Belief state: trajectory=..., freshness=..."` |
| surprisal_ema | `"surprisal EMA: {:.3}, total predictions: ..."` |
| blackboard | `"Global workspace (high-salience): ..."` |
| spawn_lessons | `"## Lessons from prior episodes\n..."` |

**Results.** Reference rates in cell A (module ON) across the 200-trial neuromod
and 200-trial perception/reflection runs:

| Module | Cell A refs | Cell A n | Rate | Mechanistic support |
|--------|-------------|----------|------|---------------------|
| neuromodulation | 0 | 100 | 0.0% | **UNSUPPORTED** |
| belief_state | 0 | 100 | 0.0% | **UNSUPPORTED** |
| surprisal_ema | 0 | 100 | 0.0% | **UNSUPPORTED** |
| blackboard | 1 | 100 | 1.0% | **UNSUPPORTED** |
| spawn_lessons | 1 | 100 | 1.0% | **UNSUPPORTED** |

All five NULL-validated modules fall below the 5% mechanistic-support threshold.
Reference rates are indistinguishable from cell B (module OFF), confirming that
none of the injected module state is echoed in visible agent reasoning.

**Interpretation caveats.**
- `agent_text_preview` is truncated; some references in later response text
  would be missed. The near-zero rates (0–1%) across 100 trials per module
  are unlikely to reverse with full response text.
- `spawn_lessons` explicitly suppresses narration: `format_lessons_block()`
  instructs agents "do not narrate that you are applying them." This by-design
  suppression is not a failure mode — the mechanism is implicit influence,
  not explicit citation. The 0% rate is therefore expected for lessons and
  does not independently argue for removal; the EVAL-064 null outcome does.
- `neuromodulation::context_summary()` only fires when modulators are not near
  baseline (±0.1 of 1.0). The neuromod eval fixture uses a synthetic
  activation state, so the `Neuromod: DA=...` string would have been injected;
  the 0% reference rate means agents received it and did not cite it.

**Full tables:** [`docs/eval/RESEARCH-022-module-reference-analysis.md`](./eval/RESEARCH-022-module-reference-analysis.md)

**Implication for removal decisions.** The reference-rate analysis is
*confirmatory*, not primary evidence. REMOVAL-002 (surprisal_ema) and
REMOVAL-003 (belief_state) are driven by EVAL-063 null outcomes. The 0%
reference rates here are consistent with, but do not independently justify,
those removal decisions. For blackboard and neuromodulation (both retained
pending further testing), the 0% rate is a methodological yellow flag, not
a verdict.

---

**RESEARCH-023 (2026-04-21). Counterfactual mediation analysis (NDE / NIE).**
Upgrades module-contribution claims from average-treatment-effect (ATE) framing
to natural-direct-effect + natural-indirect-effect decomposition (Pearl 2001).

**Script.** `scripts/ab-harness/mediation-analysis.py` — self-contained, no
external dependencies beyond Python stdlib. Mediator model: categorical, uses
P(M=m|X=x) weights. CLI: `--jsonl --exposure --mediator --outcome --n-bootstrap`.
Self-test on synthetic data (n=2 000, analytical truth NDE=0.10, NIE=0.30)
recovers estimates within ±0.011 with truth inside 95% CI.

**Applied to EVAL-054 perception (n=100, mediator=judge\_quality bin):**

| Effect | Estimate | 95% CI |
|--------|----------|--------|
| TE (total) | +0.040 | [−0.040, +0.108] |
| NDE (direct T→Y) | +0.000 | [0.000, 0.000] |
| NIE (T→quality→Y) | +0.040 | [−0.040, +0.108] |

The small positive ATE is entirely mediated through response quality; no
direct module→correctness path exists once quality is controlled. All CIs
include 0, consistent with the EVAL-054 NULL finding.

**References:** Pearl J. 2001. *Direct and indirect effects.* UAI Proc.
VanderWeele TJ. 2015. *Explanation in Causal Inference.* Oxford UP.

**Full results:** [`docs/eval/RESEARCH-023-mediation-analysis.md`](./eval/RESEARCH-023-mediation-analysis.md)

---

## Honest limits

The claims above are bounded by methodological constraints that external
readers should be told without prompting.

- **All findings except F4 are single-team.** No external research group
  has independently reproduced any of the empirical claims.
- **F2's +0.14 pp halluc effect is small in absolute magnitude.** It is
  notable because of the A/A floor multiplier (10.7×), not the headline
  number. A reader who expects a "lessons block dramatically increases
  hallucination" framing should read it as "lessons block reliably
  increases hallucination by a small but well-calibrated amount, on the
  measured fixtures, for the measured Anthropic frontier models."
- **F3 and F1 use partially-overlapping fixtures.** The neuromod fixture
  used in F3 is also part of the broader sweep family that informs F1's
  U-curve. Effect-size comparisons across F1 / F3 / F2 should not be
  treated as fully independent.
- **F1's U-curve is on a Chump-internal task fixture.** The U-shape may
  not generalize to BFCL, MMLU, ARC-AGI, HumanEval, or any external
  benchmark — those tests are queued (EVAL-040 OOD work) but unrun.
- **F5's human-grading sample is n=12.** A larger ground-truth set is
  needed for the systematic-bias claims to graduate from "preliminary"
  to "validated." EVAL-046 has shipped the v2 prompt fix on the
  preliminary data; the full re-score is pending.
- **F6 is n=1.** It is an existence proof, not a production-ship-rate
  claim. The replication study is held pending EVAL-060 / EVAL-063 /
  EVAL-064 methodology track resolution.
- **EVAL-026's aggregate −10 to −16 pp signal is retired (EVAL-069).** Two
  independent re-tests under the EVAL-060 fixed instrument (EVAL-063:
  Llama-3.3-70B; EVAL-069: Ollama qwen2.5:14b) both produced
  delta = 0.000 at n=50/cell. The signal was a methodology artifact of
  the broken exit-code scorer. F3's task-cluster localization stands.

What we explicitly do *not* claim:

- We do not claim that Chump is phenomenally conscious, or that the
  cognitive modules implement their theoretical namesakes in any formal
  sense. The phi proxy is a graph density statistic on blackboard
  traffic, not IIT's Minimum Information Partition. The surprise tracker
  is an EMA on tool outcome scalars, not a variational bound on a
  generative model. The dopamine / noradrenaline / serotonin signals are
  scalars that shift threshold parameters — they are not felt. The
  modules are *engineering proxies inspired by theories of cognition*,
  evaluated on operational outcomes. See
  [Research paper](./research-paper.md) §1.2.
- We do not claim the lessons-block intervention is universally harmful,
  universally helpful, or universally neutral. F1, F2, F3 are bounded
  empirical claims about specific intervention shapes on specific model
  families and task fixtures.
- We do not claim that few-shot exemplars (F6) generalize to all OSS
  models or all task domains. The COMP-009 ship was mostly-additive
  scaffolding; harder gap classes are untested on the technique.

---

## Replication status

| Finding | Replicated by | Status as of 2026-04-20 |
|---|---|---|
| F1 (U-curve) | None external | Internal-team only; n=20/model |
| F2 (halluc inflation) | None external; 2 architectures internal | Internal cross-architecture (haiku-4-5 + opus-4-5); single-team |
| F3 (task-cluster localization) | 4/4 internal sweeps direction-consistent; EVAL-076 Δ=−0.15 on haiku-4-5 | Directionally confirmed on haiku-4-5 (H1); CIs overlap — n≥200 for full confirmation |
| Faculty ablations (Memory/ExecFn) | EVAL-064 (2026-04-20) | spawn_lessons: n=50, delta=−0.140, CIs overlap → NULL; blackboard: n=50, delta=+0.060, CIs overlap → NULL. Both confirmed COVERED+VALIDATED(NULL) under EVAL-060 LLM judge (Together.ai, python3.12). PENDING_RESCORE from EVAL-061 resolved. |
| F4 (cross-judge) | Single-fixture finding | Methodologically suggestive; needs replication on additional fixtures |
| F5 (judge-vs-human bias) | Preliminary (n=12); v2 prompt shipped | Full re-score pending 30 additional labels |
| F6 (few-shot ship) | n=1 production ship (PR #224) | Replication trial held pending methodology cleared |

**Open invitations for external replication:**

The fixtures used in F1, F2, F3, and F4 are tracked in this repository
under `scripts/ab-harness/fixtures/` and the harness scripts are open
source. Anyone with API access to the relevant model providers can
reproduce these studies; the exact harness commands are documented in
each EVAL-XXX source doc. See
[`docs/RESEARCH_INTEGRITY.md`](./RESEARCH_INTEGRITY.md) for the
reproducibility checklist.

---

## How to cite

```
Chump Project (2026). Empirical Findings (F1-F6).
Available at: https://github.com/repairman29/chump/blob/main/docs/FINDINGS.md
Updated: 2026-04-20.
```

For specific findings, prefer citing the source `docs/eval/EVAL-XXX-*.md`
or `book/src/research-paper.md` with the gap-ID anchor; this index
exists to surface and route, not to replace those primary artifacts.

### Publication draft (pending external review)

A 2,100-word practitioner blog post summarizing F1–F3 + F6 for an HN/engineering
audience has been drafted and reviewed against the research integrity standard.
It is pending one external review (Gemini architectural reviewer) before publication.

**Draft location:** [`docs/PRODUCT-009-blog-draft.md`](./PRODUCT-009-blog-draft.md)  
**Venue:** HackerNews / practitioner blog  
**Live URL:** *not yet published — will be added here once live*

When published, update this section with the live URL and add it to the citation block above.

---

## What's next

This index will be updated when:

- Any of F1–F6 is independently replicated.
- An open methodology question (the F5 full re-score; the F6 replication
  trial) closes. (EVAL-026 aggregate-magnitude question closed by EVAL-069.)
- A new finding meets the
  [research-integrity standard](./RESEARCH_INTEGRITY.md) and is
  promoted from `docs/eval/EVAL-XXX-*.md` to F-numbered index entry.

The project's external publication path — preprint, blog post, or
talk — is currently empty. The work in F1–F6 has not yet been packaged
for an external audience. That gap is acknowledged here and is being
discussed as a 2026-Q3 priority distinct from the gap-execution
backlog.
