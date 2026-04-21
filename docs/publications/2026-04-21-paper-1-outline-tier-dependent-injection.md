# Paper 1 — Outline: Tier-dependent backfire of prompt-engineering on frontier LLM agents

**Status:** OUTLINE — this document locks the paper's structure, claims, and
data requirements. Sections labeled `[DATA REQUIRED]` are filled by the
ship of specific RESEARCH-* gaps; sections labeled `[DRAFT]` are authored
text ready for review.

**Target venue:** EMNLP 2026 Findings (primary) or NAACL 2026 Findings
(secondary). Submission window ~July 2026.

**Authors:** Jeff Adkins (corresponding), agent contributors credited per
Chump's COG-025 backend-logging convention.

**License:** MIT (code + findings artifacts), CC-BY-4.0 (paper text).

---

## 0. Abstract [PARTIAL DRAFT — fill in headline numbers when RESEARCH-018 + 021 data lands]

We report a **tier-dependent prompt-engineering backfire** on frontier
LLM agents: injecting a prescriptive "lessons block" into the system
prompt helps small-tier frontier models on reflection tasks but
actively harms large-tier models, increasing hallucinated tool-call
emission by `[Δ hallucination rate — fill from RESEARCH-021]` on
`[N model families]` independent frontier model families. We rule out
prompt-length as a confound via a length-matched null-prose control
(RESEARCH-018), validate cross-architecture via four independent
model families (RESEARCH-021), and report observer-effect bounds via
an evaluation-framing scrubbing control (RESEARCH-026). We decompose
the harm mechanism into conditional-chain dilution and trivial-token
contamination (per EVAL-029) and apply natural-direct-effect mediation
analysis (Pearl 2001 / VanderWeele 2015, via RESEARCH-023) to
quantify how much of the effect is direct vs. mediated by task-type
interaction. All data, harness, and preregistrations are public at
`github.com/repairman29/chump` for third-party reproduction.

**Headline numbers (to be filled after data collection):**
- Small tier (haiku-4-5): `[Δ correctness on reflection, with 95% CI]`
- Large tier (sonnet-4-5): `[Δ hallucination rate, with 95% CI]`
- Family-replication count: `[≥3 of 4 → field-wide claim; <3 → Anthropic-specific caveat]`
- Length-matched control: `[Δ content-vs-ceremony, supports H1 or forces reframe]`

---

## 1. Introduction [DRAFT]

### 1.1 The backfire phenomenon

As frontier model capabilities have grown, practitioners have
converged on a pattern: inject prescriptive behavior-shaping text
(rules, lessons, guardrails) into the system prompt at inference
time. This works when the model needs more structure. It is the
implicit assumption behind Constitutional AI-style deployment,
behavior-engineering prompts, and most agent-framework system
messages.

We show that this assumption **reverses sign** as model tier grows.
Small-tier frontier models benefit from prescriptive injection
on specific task types; large-tier frontier models are *harmed* by
the same injection, in a way that the standard binary pass/fail
scorer does not detect. The harm manifests as an increase in
hallucinated tool-call emission: the model claims to perform
actions it did not perform. This failure mode is undetectable
without multi-axis scoring (correctness + hallucination + attempt).

### 1.2 Why tier-dependence is plausible

Two mechanism hypotheses motivate the effect:

1. **Conditional-chain dilution.** Prescriptive text like "if X,
   then do Y" adds surface-level conditionals that interact with
   the model's instruction-following capacity. For small models,
   the conditional structure is clarifying; for large models, it
   dilutes the main ask.
2. **Trivial-token contamination.** Prescriptive blocks include
   generic directive tokens ("always", "never") that large models
   parse as rule-like constraints, triggering over-cautious or
   over-confident failure modes depending on the conditional
   direction.

Both mechanisms are diagnosable — see our EVAL-029 per-task
drilldown. They predict the effect should be tier-continuous: the
bigger the model, the larger the harm. Our data supports this
prediction across `[number]` model families.

### 1.3 What this paper contributes

1. **A tier-dependent backfire finding** at n≥100 per cell, 4 model
   families (RESEARCH-021), with non-overlapping Wilson 95% CIs on
   per-tier deltas.
2. **A methodology validation** — the length-matched prose control
   (RESEARCH-018) rules out prompt-length as a confound; the
   observer-effect control (RESEARCH-026) rules out eval-framing
   bias.
3. **A causal decomposition** via Pearl NDE/NIE (RESEARCH-023)
   quantifying direct vs. mediated pathways.
4. **An open methodology artifact** — full preregistrations
   ([`docs/eval/preregistered/`](../eval/preregistered/)), analysis code
   (`scripts/ab-harness/`), raw JSONLs, and reproduction commands for
   every headline number in the paper.

### 1.4 What this paper does not claim

- We do **not** claim the full nine-subsystem "cognitive
  architecture" framework is validated. That requires EVAL-043
  (pending) and is the subject of future work.
- We do **not** claim the tier-dependent effect generalizes to all
  task classes. We report on reflection fixtures only. Extension to
  perception, multi-turn, and ecological fixtures is future work
  (RESEARCH-020, 024).
- We do **not** claim mechanism exhaustiveness. Our two proposed
  harm mechanisms (conditional-chain dilution + trivial-token
  contamination) explain the majority of the per-task variance in
  our drilldown but do not preclude additional pathways (e.g.
  latent-state shifts, attention interference) that would require
  mechanistic interpretability work (filed for future research).

---

## 2. Related work [SKETCH — expand with 8–12 citations before submission]

- **GEPA** (Dean et al., 2024) — evolutionary prompt search; shows
  between-session optimization can shift behavior. Our work measures
  the within-session equivalent.
- **Hermes** (Block, 2025) — accumulates skills across runs. Their
  positive results are on small-tier deployment; our tier-dependent
  finding predicts their approach scales poorly to frontier tiers.
- **Constitutional AI** (Anthropic, 2022) — injection of rules into
  the prompt at training + inference time. Our finding complicates
  deployment: what helps at training may harm at inference on the
  same model.
- **Model-Written Evals** (Perez et al., 2022) — scales eval volume
  via LLM generation. We use MWE principles for our secondary
  fixtures (RESEARCH-014) but keep our headline fixture
  human-authored for validation.
- **CatAttack** (arXiv 2503.01781, 2025) — distractor-prepended
  prompts cause 300–500% error-rate spikes on reasoning models. Our
  work measures a complementary effect: *directive* prepending
  (lessons) causing similar-magnitude hallucination spikes on
  frontier tiers.
- **Mediation analysis in ML** — Vig et al. 2020 introduced NDE/NIE
  for transformer circuit analysis. We apply the same framing to
  A/B agent sweeps.
- **Pre-registration in ML** — ML Reproducibility Challenge / OSF
  registries. Our research-program-wide preregistration protocol
  (RESEARCH-019) is, to our knowledge, the first published
  agent-research preregistration system.

---

## 3. Methods [DRAFT — fill in final n values when RESEARCH-018/021/026 data lands]

### 3.1 Study design

Three-cell A/B/C paired-task design:

| Cell | System prompt content | Purpose |
|---|---|---|
| A | COG-016-versioned lessons block (~2,000 chars) | Treatment |
| B | No injection (bare system prompt) | Control |
| C | Length-matched null prose (~2,000 chars, markdown skeleton preserved) | Length-matched placebo — rules out prompt-length confound |

Cells A, B, C run the same task fixture. Each task is evaluated
across all three cells. Paired-bootstrap analysis controls for
task-level variance.

### 3.2 Model matrix [DATA REQUIRED per RESEARCH-021]

| Family | Small tier | Large tier |
|---|---|---|
| Anthropic | claude-haiku-4-5 | claude-sonnet-4-5 |
| Meta | Llama-3.3-8B-Instruct | Llama-3.3-70B-Instruct-Turbo |
| Alibaba | Qwen-2.5-7B-Instruct | Qwen-2.5-72B-Instruct-Turbo |
| DeepSeek | DeepSeek-V3-small | DeepSeek-V3 |

Total: 4 families × 2 tiers × 3 cells × n=100 = **2,400 trials**
for the headline finding. Each family's tier comparison is
independent; H1 holds if tier-direction-match occurs in ≥3 of 4
families (preregistered threshold).

### 3.3 Judge panel

Per our `docs/RESEARCH_INTEGRITY.md` cross-family requirement, every
trial is scored by a 3-judge panel with explicit family-exclusion
rule (same-family judge dropped when judging that family's agent):

- claude-sonnet-4-5 (Anthropic judge)
- Llama-3.3-70B-Instruct-Turbo (Meta judge, via Together)
- Qwen-2.5-72B-Instruct-Turbo (Alibaba judge, via Together)

Majority vote per trial; conservative tie-break (correctness=0).

### 3.4 Fixtures

Primary: `scripts/ab-harness/fixtures/reflection_tasks.json` (100
tasks, 50 clean + 50 gotcha categories). Same fixture as used in
EVAL-025/027/076 so results compose with prior Chump findings.

Cell C content generated via `scripts/ab-harness/gen-null-prose.py`
(RESEARCH-018 ship, PR #384). Deterministic given (target_chars,
seed); length-matched to Cell A's actual char count per trial
within ±2%; markdown skeleton (H2 + bullets) preserved; banned-
substring list excludes directive-shaped tokens.

### 3.5 Outcome metrics

**Primary (per trial):**
- `is_correct` — judge majority vote, binary (0/1)
- `hallucinated_tools` — regex detection of tool-call claims not
  matching actual tool execution log (per EVAL-041 specification)

**Secondary:**
- `did_attempt` — agent produced any output exceeding 10 chars
- `mean_tool_calls_per_trial` — for sequence-length covariate check
- `judge_inter_rater_kappa` — per-judge-pair agreement

### 3.6 Preregistration and analysis plan

All analyses preregistered before data collection. Preregistrations
committed at `docs/eval/preregistered/RESEARCH-<NNN>.md` before the
first trial JSONL is written. Compliance enforced by the
`CHUMP_PREREG_CHECK` pre-commit guard (RESEARCH-019, PR #352).

**Primary statistics:**
- Per-cell mean + Wilson 95% CI on `is_correct` and `hallucinated_tools`
- Pairwise deltas (A−B, C−B, A−C) with paired-bootstrap 95% CIs
  (10,000 resamples)
- H1 test: `|Δ(A−B)| > |Δ(C−B)| + 0.05` (content-above-ceremony)
- H1 test (tier): `sign(Δ_small) ≠ sign(Δ_large)` with both CIs
  excluding zero

**Secondary (all preregistered):**
- Natural direct effect (NDE) and natural indirect effect (NIE)
  via `scripts/ab-harness/mediation-analysis.py` (RESEARCH-023,
  PR #380). Mediator: task category.
- Per-judge breakdown — rerun primary analysis using each judge
  singly to bound judge-family inflation.
- Per-task-subtype — split by reflection subtype (clean vs gotcha).

**Exploratory (clearly labeled):**
- Response-length × Cell C delta correlation — does ceremony
  increase verbosity?
- Reference-rate analysis (RESEARCH-022 methodology) — does the
  agent textually reference the injected block content?

### 3.7 Exclusion rules

A trial is excluded iff:
- Agent output empty (exit_code ≠ 0 or output_chars < 10)
- Judge HTTP error after 3 retries
- Provider endpoint unreachable

Exclusions logged in JSONL with reason. Per-cell exclusion rate
>10% invalidates that cell and forces a re-run.

### 3.8 Observer-effect control [RESEARCH-026]

A separate n=50/cell × 2 framing arms × 2 tiers sweep measures
whether casual-user-message rewrites of the fixture shift agent
behavior relative to the standard fixture framing. Result gates
an explicit observer-effect correction section in the paper if the
delta exceeds 0.05.

---

## 4. Results [DATA REQUIRED — fills from RESEARCH-018 + 021 + 026 ships]

### 4.1 Headline: tier-dependent direction match

**Table 1 — Per-family per-tier correctness deltas (Cell A − Cell B)**

| Family | Small-tier Δ correctness | Small-tier Δ hallucination | Large-tier Δ correctness | Large-tier Δ hallucination | Direction match? |
|---|---|---|---|---|---|
| Anthropic | `[HAIKU VALUE]` | `[HAIKU VALUE]` | `[SONNET VALUE]` | `[SONNET VALUE]` | `[✓/✗]` |
| Meta | TBD | TBD | TBD | TBD | TBD |
| Alibaba | TBD | TBD | TBD | TBD | TBD |
| DeepSeek | TBD | TBD | TBD | TBD | TBD |

Count of families with direction match: `[N/4]`. H1 supported if N≥3.

### 4.2 Content-above-ceremony: the length-matched control

**Table 2 — Cell comparisons at n=100, haiku-4-5 × sonnet-4-5**

| Cell pair | Δ correctness (95% CI) | Δ hallucination (95% CI) | Interpretation |
|---|---|---|---|
| A − B (treatment vs. control) | TBD | TBD | — |
| C − B (placebo vs. control) | TBD | TBD | — |
| A − C (content-above-ceremony) | TBD | TBD | H1 supported if both CIs exclude 0 in the same direction as A−B |

### 4.3 Mechanism decomposition: NDE vs. NIE

**Table 3 — Pearl mediation analysis via task category mediator**

| Tier × Outcome | TE (95% CI) | NDE (95% CI) | NIE (95% CI) | Proportion mediated |
|---|---|---|---|---|
| Haiku × correctness | TBD | TBD | TBD | TBD |
| Haiku × hallucination | TBD | TBD | TBD | TBD |
| Sonnet × correctness | TBD | TBD | TBD | TBD |
| Sonnet × hallucination | TBD | TBD | TBD | TBD |

### 4.4 Observer-effect bound [RESEARCH-026]

**Table 4 — Framing-scrubbing delta at n=50/cell × 2 tiers**

Delta within ±`[threshold]` → observer-effect bias ruled out;
delta exceeds threshold → correction factor `[value]` applied to
Section 4.1 numbers and reported here.

---

## 5. Discussion [SKETCH — expand after data lands]

### 5.1 Implications for agent-framework deployment

The tier-dependent backfire means that behavior-shaping prompts
optimized for a particular frontier tier **do not transfer** to
adjacent tiers. Deployment-stack designers who rely on a single
prompt template across small + large tier models are introducing
unintended hallucination risk on their largest-tier workloads.

Practical recommendation: tier-gate prompt engineering. Small models
benefit from prescriptive structure; large models benefit from
minimal system prompts. The COG-024 "default lessons OFF, opt-in
per-model" pattern from Chump's production stack is one concrete
implementation.

### 5.2 Mechanism attribution caveats

Our NDE/NIE decomposition is consistent with direct causal
attribution but does not prove it — standard no-unmeasured-
confounders assumption applies. Mechanistic interpretability
work (SAE probing, activation steering) remains future research.

### 5.3 Scope limits

- Reflection fixtures only. Perception, multi-turn, and ecological
  fixtures are open work.
- n=100 per cell is sufficient for direction-match tests but not
  for fine-grained effect-size claims.
- Haiku and sonnet represent the Anthropic-4.5 tier pair; 4-family
  replication via Llama / Qwen / DeepSeek extends the claim but
  not to all post-2025 frontier models.

### 5.4 What this does not support

**Explicit non-claims — these are exactly the lines
`docs/RESEARCH_INTEGRITY.md` flags as prohibited without supporting
data:**
- Not a validation of the nine-subsystem cognitive architecture
- Not a claim that lessons blocks are universally harmful
- Not a claim that the effect generalizes to pre-frontier model
  tiers (GPT-3.5-class and below)

---

## 6. Limitations [DRAFT — authored up-front]

1. **Author-graded fixtures.** All primary-fixture tasks authored
   by a single researcher with knowledge of the tested modules.
   Mitigation partial: RESEARCH-020 ecological fixtures in progress
   will validate externally. Until RESEARCH-020 ships, primary-
   finding effect sizes should be interpreted as upper bounds.
2. **Single-platform evaluation.** All experiments on Apple Silicon
   M4; cloud APIs vary by provider. Cross-platform reproducibility
   filed as future work.
3. **Within-family judge panel for Anthropic agent cells.** When
   agent is claude-haiku-4-5 or sonnet-4-5 and the two non-Anthropic
   judges both time out, the single Anthropic judge path fires.
   Rare; flagged per trial in JSONL.
4. **Bootstrap percentile CIs.** For small strata, BCa bootstrap
   would be more accurate but is not yet implemented in
   `mediation-analysis.py`. Percentile CIs are conservative.
5. **No human grading on the headline fixture beyond EVAL-010's
   12-task subset.** Per-category human-LLM-judge kappa reported
   via RESEARCH-025 at 100 trials × 5 categories; deltas on
   categories with κ < 0.60 are flagged as instrument-limited.

---

## 7. Reproduction artifact

Every headline number in this paper is regeneratable from the
public `github.com/repairman29/chump` repo at commit
`[FINAL_COMMIT_SHA]` via:

```bash
git clone https://github.com/repairman29/chump
cd chump
git checkout <FINAL_COMMIT_SHA>

# Reproduce Section 4.1 headline
python3.12 scripts/ab-harness/run-cloud-v2.py \
    --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
    --cells A B C \
    --null-prose-match \
    --models claude-haiku-4-5,claude-sonnet-4-5 \
    --families anthropic,meta,alibaba,deepseek \
    --n-per-cell 100 \
    --judge-panel cross-family \
    --seed 42 \
    --out logs/ab/paper1-headline.jsonl

# Reproduce mediation (Section 4.3)
python3.12 scripts/ab-harness/mediation-analysis.py \
    --jsonl logs/ab/paper1-headline.jsonl \
    --exposure cell --exposure-treatment A --exposure-control B \
    --mediator category --outcome is_correct \
    --n-bootstrap 10000 --seed 42 \
    --out logs/ab/paper1-mediation.json
```

All preregistrations at `docs/eval/preregistered/RESEARCH-*.md`
were committed before the first trial JSONL was produced; see
`scripts/git-hooks/pre-commit` job 6b (RESEARCH-019) for the
enforcement mechanism.

---

## 8. Outstanding gaps to ship before submission

In the order they block the paper:

1. **RESEARCH-018 completion** — n=100 sweep on haiku + sonnet
   across A/B/C cells. Unblocks §4.2. Budget ~\$40 cloud
   (Together free-tier judges).
2. **RESEARCH-021 completion** — n=100 × 4 families. Unblocks §4.1.
   Budget ~\$40 cloud.
3. **RESEARCH-026 completion** — n=50 × 2 framing arms. Unblocks
   §4.4. Budget ~\$15 cloud.
4. **RESEARCH-025 human-grading completion** — 100 × 5 categories.
   Unblocks §6 footnotes. Budget ~60h human time.
5. **Related work section expansion** — 8–12 citations. Budget ~8h.
6. **Abstract + discussion final drafts** — fills in numbers from
   §4. Budget ~12h.

Post-data-collection wall-clock: ~2 weeks to submission-ready draft.
Total cloud: ~\$95 (well within research-program budget).

---

## 9. Next steps for the team

Read the gaps in §8 in order and pick one. Each preregistration is
at `docs/eval/preregistered/RESEARCH-<NNN>.md` with an exact
reproduction command. Result docs land at
`docs/eval/RESEARCH-<NNN>-*.md`; this paper outline's
`[DATA REQUIRED]` sections update atomically with those ships.

When Section 4's tables fill in, this file graduates from
`-outline` to a submission-ready draft at
`docs/publications/2026-06-XX-tier-dependent-injection.md` with a
LaTeX conversion for venue submission.
