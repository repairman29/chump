---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Research Critique — 2026-04-21

> Frontier-scientist review of Chump's empirical methodology.
> Paired gap set: RESEARCH-018 through RESEARCH-026 (see `docs/gaps.yaml`).
> Supersedes no prior critique. Does not change any prior finding's status —
> this is forward-looking test design.

---

## What Chump's empirical record actually supports

Reading `docs/FINDINGS.md`, `docs/RESEARCH_INTEGRITY.md`, and the ~60 EVAL-*
gaps against the 2026-04-21 state of origin/main, the evidence supports one
load-bearing finding and four supporting observations:

| Claim | Strength | What it rests on |
|---|---|---|
| **Tier-dependent injection effect** (lessons block helps haiku-4-5 on reflection; harms sonnet-4-5 at +0.33 hallucination rate) | n=100 cross-family judges, Wilson CIs non-overlapping; replicated across two Anthropic tiers; mechanism drilldown (EVAL-029) identifies two distinct harm pathways | Strong, publishable if the methodology gaps below are closed |
| Mechanism decomposition (conditional-chain dilution + trivial-token contamination) | EVAL-029 task-drilldown | Medium — single-analyst interpretation; mechanism claims need independent replication |
| Scaffolding U-curve on local models (1B/14B benefit, 3B/7B hurt, 8B neutral) | n=20/model × 5 models | Weak — small n per cell; never replicated on a second GPU box; no CIs reported |
| Lessons-block hallucination channel (+0.14 pp mean (≈ +0.0014 absolute rate), 10.7× A/A noise floor) | n=100 A/A baseline; multi-axis scoring caught what single-axis missed | Medium — holds on haiku/opus, unreplicated on non-Anthropic |
| F3 (neuromod aggregate signal) | **Retired 2026-04-21**, pending EVAL-069-REDO under the fixed instrument | Provisionally void — was retired under a harness with documented foot-guns (Red Letter #4) |

Everything else labeled COVERED+VALIDATED(NULL) in `docs/CHUMP_FACULTY_MAP.md`
(Memory EVAL-056, Executive Function EVAL-058, Metacognition EVAL-053) reflects
**measurement failure rebranded as measurement result**, per Red Letter #3's
reading. The instrument could not resolve those modules' effects at n=30
with exit-code scoring. "No signal" and "instrument cannot detect signal"
are not the same claim.

## What's strong in the current approach

Credit where due. Three things Chump gets right that most agent-research
projects don't:

1. **Multi-axis scoring with hallucination detection.** Binary pass/fail
   scoring rewards hallucinated tool calls (they look like "doing something").
   Chump's scorer separates correctness from attempt, which is how the F2
   hallucination channel was surfaced in the first place. Most published
   agent evaluations would have missed this.
2. **A/A controls published alongside A/B deltas.** The noise floor is
   quantified, not assumed. When Chump reports a +0.14 delta at 10.7× the
   A/A noise floor, that framing is reproducible and honest. Most papers
   cite deltas against zero.
3. **Gap registry linked to evidence.** Every claim traces back to a
   specific EVAL-NNN gap with fixture, n, and raw JSONL. This is closer
   to a reproducibility artifact than most lab-written papers are at
   submission time.

These are the reasons a narrow, rigorous paper is reachable from here.
The rest of this memo is about the gaps between here and that paper.

---

## Methodology weaknesses — what the evidence doesn't yet rule out

### 1. No length-matched scaffolding-as-noise control

Every lessons-block A/B compares "lessons block" vs "no lessons block".
Neither condition controls for **prompt length**. The lessons block adds
~2,000 characters of structured text to the system prompt. A control
condition of "2,000 characters of length-matched random prose" would
distinguish "the content of the lessons helped" from "adding ceremony
to the system prompt shifted the model's behavior regardless of
content."

If the length-matched control produces a delta of similar magnitude
to the real lessons block, the claim has to be reframed: "system-prompt
length, not lessons content, drives the tier-dependent effect." That's a
publishable negative result. The current framing is not yet safe against
this alternative explanation.

**Ships as:** RESEARCH-018.

### 2. Author-graded fixtures

Every fixture in `scripts/ab-harness/fixtures/` was authored by the
same person (and with LLM assistance) who designed the cognitive modules
being tested. This is a classic Goodhart risk: the test designer is not
blind to the mechanism, and there is strong (unintentional) pressure to
design tasks where the module will help. The tier-dependent injection
finding is partially insulated because the harm case wasn't predicted
in advance — but the scaffolding U-curve and neuromod findings sit on
fully author-designed fixtures.

Fix: ship an **ecological fixture set** scraped from real GitHub issues
and PRs on open-source projects. Re-run the top-3 findings on ecological
fixtures. If the deltas hold, the author-tuning concern is allayed. If
they shrink or flip, the limitation is important to disclose.

**Ships as:** RESEARCH-020.

### 3. No pre-registration

Every EVAL-NNN gap filed after data collection records what the data
showed. None of them records what hypothesis was locked before the data
was collected, what analysis plan was pre-committed, or what stopping
rule was applied. This is not unique to Chump — most ML research has
this problem — but it is unfixable *after* the fact. From today forward,
every new A/B gap should land a one-page `.md` pre-registration in
`docs/eval/preregistered/` before the first trial is run.

This is a methodology infrastructure change, not a single experiment.
It's the single highest-leverage thing we can do for publication
credibility.

**Ships as:** RESEARCH-019.

### 4. Within-architecture replication only

The tier-dependent injection finding is measured on haiku-4-5 vs
sonnet-4-5 — same provider, same training lineage, size difference
only. Replicating on `Llama-3.3-70B`, `Qwen-2.5-72B`, `DeepSeek-V3`,
and `Gemma-3-27B` would distinguish "a tier-dependent effect in the
Anthropic family" from "a field-wide tier-dependent effect across
frontier LLMs." Only one of those is a publishable field-level finding.

EVAL-071 was filed to extend the hallucination-channel finding to
non-Anthropic frontier models. It's P2 and open. Expanding this to
cover the full 4-family matrix for the core tier-dependent finding
is the single highest-impact scientific investment.

**Ships as:** RESEARCH-021.

### 5. No mechanism-level evidence — only output-level

A "cognitive architecture" claim rests on whether the agent *uses*
the architecture. Chump measures outputs (did the task succeed? did
it hallucinate?) but never measures whether the agent's output
actually references the injected module state. If `belief_state`
provides `{"my_ability": 0.9}` to the prompt and the agent never
mentions or conditions on it in any observable way, the module is
dead weight — regardless of whether task outcomes shifted.

Fix: post-hoc text analysis of agent outputs for textual references
to injected module state, with reference-rate × task-type × outcome
broken out. If reference rate is near zero, the architecture claim
is mechanistically unsupported even when outcome deltas exist.

**Ships as:** RESEARCH-022.

### 6. Correlation reported, mediation not estimated

The current "module contribution" analysis is: P(pass | module=on)
minus P(pass | module=off), measured aggregate. For a causal claim,
the stronger quantity is the **counterfactual mediation estimate**:
for matched trials that differ *only* in the module's value, what
is the expected outcome difference? Pearl's mediation framework
applies directly. At n=50+ we have the statistical power; the
existing A/B harness produces the needed matched pairs; what's
missing is the analysis pipeline.

This upgrades every existing module-contribution claim from
"average treatment effect" (what we report) to "natural direct
effect" (what a causal claim requires).

**Ships as:** RESEARCH-023.

### 7. Single-turn fixtures only

Every scored fixture is single-shot: one user turn, one agent
response, done. Real agent deployment is multi-turn; errors compound;
belief state either stabilizes or drifts. EVAL-044 designed a 10-turn
debug scenario with coherence and belief-drift rubrics but has not
been run. The multi-turn run is where "belief_state" either earns
its keep or is revealed as decorative.

The publishable framing: "When do memory modules actually help?
A turn-level analysis of state-injection in 10-turn debug scenarios."
This is a novel enough dimension that the result — either positive
or null — is publishable.

**Ships as:** RESEARCH-024.

### 8. Judge homogeneity within task class

EVAL-068 reported cross-judge kappa (sonnet-4-5 vs Llama-3.3-70B)
at 77.3% overall but with per-fixture variance: reflection=86%,
perception=75%, neuromod=71%. The overall number hides that
neuromod judgments have much lower inter-rater reliability than
reflection. Every delta reported on the neuromod fixture sits on
weaker judge ground than deltas on reflection.

Fix: expand EVAL-041's human-grading subset to 100 trials × 5 task
categories. Compute kappa per category against the LLM judge panel.
Report category-conditional judge reliability alongside every
downstream delta.

**Ships as:** RESEARCH-025.

### 9. No observer-effect / sandbagging check

Frontier models can behave differently when they detect they are
being evaluated. Chump's fixtures often include explicit "this is a
test" framing (task IDs, structured rubrics, etc.). We have not
measured whether scrubbing evaluation framing from the prompt
changes agent behavior. If it does, every reported delta is
inflated by the same observer-effect bias.

Fix: rerun the reflection fixture at n=50 with two arms — (a)
normal framing, (b) evaluation-framing scrubbed. Measure behavior
delta. If significant, publish correction factor; if not, publish
as validation that our fixtures don't have detectable eval-framing
bias.

**Ships as:** RESEARCH-026.

---

## Cutting-edge methods to adopt

Drawing on 2024-2026 literature. Not all of these are one-gap items;
some are methodology commitments that shape future gap design.

### Model-Written Evals (Perez et al., Anthropic)

Our fixtures are human/author-written. Anthropic's MWE paper showed
that a strong frontier model can generate >10× the evaluation items
of a human at comparable quality, provided the generation is
validated against a human subset. Our n=50 constraint is largely
a fixture-authoring-cost constraint. MWE would let us run n=500+
sweeps on the same compute budget.

The risk is test-on-test contamination. Mitigation: use a different
model family to generate fixtures than the ones being evaluated.

### Representation engineering / activation steering

Hendrycks et al. and subsequent work showed that frontier model
behavior can be steered at inference time by adding precomputed
vectors to internal activations. The technique has obvious eval
applications: if we can steer "confidence" or "attention to the
system prompt" as scalar knobs, we can measure dose-response curves
for lessons-block injection. This is more mechanistic than our
current on/off toggles.

Requires activation access, which we have for the OSS models
(Llama, Qwen, DeepSeek) but not for Anthropic models. Pairs well
with the OSS tier-dependence replication (RESEARCH-021).

### Counterfactual mediation analysis (Pearl; Halpern)

Already covered in weakness #6 above. Worth restating: moving from
average treatment effects to natural direct effects is the standard
for causal claims in clinical trials and modern empirical economics.
ML papers are starting to adopt this framing (e.g., TextMediation).
Our A/B harness already produces the needed data; what's missing is
the analysis pipeline.

### Pre-registration (AsPredicted, OSF, ML Reproducibility Challenge)

Already covered in weakness #3. The friction cost is low (~1 hour
per gap). The credibility premium is large — preregistered findings
are systematically less inflated than post-hoc ones. Ships as
RESEARCH-019.

### Behavioral cloning baselines (Cabi et al.; Voyager)

For every "architecture M adds signal" claim, we should run a
behavioral-cloning baseline: a smaller model fine-tuned on the
larger model's trajectories with no M. If the smaller+BC model
matches the larger+M model, the architecture is decorative.
Smaller investment now: state it as a future-work caveat, make
sure nothing we publish today would be falsified by this test.

### Mechanistic interpretability — SAE probes

Training sparse autoencoders on intermediate activations lets us
identify feature directions that correspond to interpretable concepts
("apology", "confidence", "numeric reasoning"). For our OSS
replication tier, attaching SAE probes would let us measure whether
the lessons block actually shifts interpretable internal features
— the strongest possible mechanism evidence. This is aggressive
scope; file as a P2 longer-term gap.

---

## Publication pathway — three papers, two years

### Paper 1 — "Tier-dependent backfire of prompt-engineering on frontier models"

Target venue: **EMNLP 2026 Findings** or **NAACL 2026 Findings**.
Submission window: mid-summer 2026.

Contribution: We report a tier-dependent injection effect — system-prompt
lessons help small-tier frontier models (haiku-4-5) on reflection tasks
but actively harm large-tier models (sonnet-4-5) with a +0.33
hallucination-rate increase. We decompose the harm mechanism into
conditional-chain dilution and trivial-token contamination, validate
the effect across four model families (Anthropic, Llama, Qwen,
DeepSeek), and show the length-matched prose control does not produce
the effect — ruling out system-prompt-length as a confound. We also
quantify the failure mode a single-axis pass/fail scorer would miss.

Prerequisites (RESEARCH-018 through RESEARCH-021, RESEARCH-026):
- Length-matched control re-runs the core finding
- Preregistration locks analysis plan
- OSS tier-dependence replication extends to 4-family matrix
- Observer-effect control shows no evaluation-framing confound
- Human-grading subset (EVAL-041) validates LLM judge kappa
- Author-graded fixture concern addressed via RESEARCH-020

Incremental cost: ~$200 cloud (4 families × n=200 × scaffolding ×
length-matched control), ~80 hours human time.

### Paper 2 — "Author-graded fixtures inflate architecture-validation deltas: a reproducibility study"

Target venue: **ICLR Tiny Papers** or **TMLR**. Can be shorter and
more methodology-focused.

Contribution: We take a previously published set of cognitive-
architecture module deltas (Chump's own) and re-run them on blind-
scored ecological fixtures. We report the change in effect size from
synthetic-author-graded to ecological-blind-scored conditions.
Whichever direction the result goes is a useful calibration data
point for the agent-research field.

This is a deliberately self-skeptical contribution. Its value is
raising the bar for how other labs should report agent-architecture
evals.

Prerequisites (RESEARCH-020, RESEARCH-019, RESEARCH-025):
- Ecological fixture set (100+ tasks)
- Pre-registration of the replication analysis before re-running
- Per-category human-LLM-judge kappa

Incremental cost: ~$80 cloud, ~120 hours human time (mostly fixture
curation).

### Paper 3 — "Multi-turn belief dynamics in cognitive-scaffolded agents"

Target venue: **NeurIPS 2026** or a workshop at either NeurIPS or
ICLR.

Contribution: We measure turn-by-turn accuracy decay across 10-turn
debug scenarios, with and without an explicit belief_state module.
We report where memory modules earn their keep (late-turn recovery
from early errors) versus where they're decorative (steady-state
question answering). The publishable story is a *conditional* claim
— not "belief_state helps" or "doesn't help," but "helps in
trajectory-dependent tasks after turn N."

Prerequisites (RESEARCH-022, RESEARCH-024):
- Module-use reference analysis establishes that the agent *reads*
  belief_state (mechanism evidence)
- Multi-turn degradation curve run against EVAL-044 fixture

Incremental cost: ~$60 cloud, ~40 hours human time.

### Cumulative cost of the three-paper program

~$340 cloud + ~240 hours human time, over ~6 months. Conservative:
double both estimates to account for re-runs and review-response
cycles, so ~$700 + ~480 hours. Fits within the Q3 budget envelope
established by `docs/RESEARCH_PLAN_2026Q3.md`.

---

## The research program — gap map

The new `RESEARCH-018` through `RESEARCH-026` gaps filed with this
critique form a coherent sprint-able program. Rough dependency order:

```
RESEARCH-019 (pre-registration infra)  ──┐
                                          │
RESEARCH-018 (length-matched control) ───┤
RESEARCH-021 (OSS tier-dependence) ──────┼──► Paper 1
RESEARCH-026 (observer-effect check) ────┤
RESEARCH-025 (per-category judge kappa) ─┘

RESEARCH-020 (ecological fixtures) ──────┐
                                          ├──► Paper 2
RESEARCH-019 ─── (same as above)          │
RESEARCH-025 ─── (same as above)          │

RESEARCH-022 (module-use reference) ─────┐
                                          ├──► Paper 3
RESEARCH-024 (multi-turn run) ───────────┘

RESEARCH-023 (counterfactual mediation) ─► upgrades all three papers' analysis sections
```

All nine gaps are sized xs–m. The largest single-gap investment is
RESEARCH-020 (ecological fixture curation) at ~2 weeks.

## What I am not proposing

Deliberately excluded from this program:

- **SAE probing on OSS models.** Rich methodology but requires
  dedicated compute and an interpretability specialist. File as
  future work; do not block the three papers on it.
- **Removal of VALIDATED(NULL) modules.** This is a legitimate
  decision but it's a *product* question (simpler binary) not a
  *research* question. Handle via EVAL-048's own decision rule
  in a separate cleanup gap.
- **Full EVAL-043 cognitive-architecture ablation.** This gap is
  already filed. Infrastructure exists; it needs to be *run*
  under the fixed python3.12 instrument. It's a prerequisite for
  the "Chump's cognitive architecture is validated" claim, which
  is not one of the three papers I'm proposing. Keep EVAL-043 on
  the roadmap but don't gate publication on it.

## Decision point

I am proposing nine new RESEARCH-* gaps. This is additive to the
existing roadmap, not a replacement. If the operator thinks the
roadmap is already too full, the triage is:

- **Must-have** (blocks Paper 1): RESEARCH-018, 019, 021, 026
- **Should-have** (strengthens every paper): RESEARCH-025, 022, 024
- **Nice-to-have** (opens Paper 2): RESEARCH-020, 023

The must-have set is ~6 weeks of work at single-dogfooder pace.
That investment buys a publishable preprint in summer 2026.
