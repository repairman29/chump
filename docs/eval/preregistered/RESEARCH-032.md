# Preregistration — RESEARCH-032

> **Status:** LOCKED at commit `<filled-at-commit-time>`. Do not edit
> locked fields after data collection begins — add a Deviations entry instead.
> See [`README.md`](README.md) for the protocol.

## 1. Gap reference

- **Gap ID:** RESEARCH-032
- **Gap title:** Local-LLM capability-ceiling study — which Chump workflows actually compose under qwen3:14b-class constraints? (offline-mission validation)
- **Source critique:** Convergent finding from 3 Gemini reviewer-persona passes (CPO / distributed-systems architect / research-integrity reviewer) on `docs/strategy/NORTH_STAR.md` + `EXPERT_REVIEW_PANEL.md` (2026-05-02 cleanup pass).
- **Strategic anchor:** [`docs/strategy/NORTH_STAR.md`](../../strategy/NORTH_STAR.md) — "Would this work in an air-gapped environment on a $500 machine?" is one of the four founder-level decision questions; this study converts that question from an asserted axiom into a measured boundary.
- **Author:** agent claude/research-032 (Opus 4.7)
- **Preregistration date:** 2026-05-02

## 2. Hypothesis

This is a **capability-class characterization study**, not a single-effect
A/B. The empirical question is "where is the ceiling," not "does X help."
Hypotheses are framed as the offline-mission claim Chump's strategy
asserts, expressed in falsifiable form.

**H1 (primary, the offline-mission claim, falsifiable).** A qwen3:14b-class
local LLM on consumer hardware (24GB Apple Silicon) successfully composes
≥ 4 of the 5 representative Chump end-to-end workflows below at a binary
"shipping-quality" success rate of **≥ 0.60** per workflow, with Wilson
95% CI lower bound ≥ 0.40.

> Formally: for ≥ 4 of 5 workflows W_i,
> `success_rate(qwen3:14b, W_i) ≥ 0.60` with Wilson 95% lower bound ≥ 0.40.

**H0 (the offline mission is empirically too thin to bear the strategic
weight Chump puts on it).** qwen3:14b succeeds on ≤ 2 of 5 workflows at
the 0.60/0.40 bar. The "Chump is usable on local LLMs only" framing in
NORTH_STAR.md must be narrowed (e.g. "Chump v1 requires frontier
substrate; offline path needs more research") or the substrate bar must
rise (e.g. qwen3:32b or larger).

**Ambiguous-zone (3 of 5 succeeding).** Reported as a partial finding —
offline mission is workflow-conditional, with explicit per-workflow
labels of which paths require frontier substrate. NORTH_STAR.md is
amended to reflect the workflow-conditional scope, not retracted.

**Alternative explanations to rule out:**
- *Judge-family bias.* Llama-only or Anthropic-only judging could skew
  per-workflow success labels. Addressed by cross-judge audit (§3 judge
  panel) — κ ≥ 0.60 across ≥ 2 judge families on each workflow class
  before per-workflow rates are cited (RESEARCH_INTEGRITY.md §99-111).
- *Frontier-baseline ceiling effect.* If frontier also fails a workflow
  (e.g. ambient-stream coordination requires multi-agent infrastructure
  that no single agent can validate), the workflow is not measuring
  substrate ceiling — it's measuring harness limitations. Addressed by
  reporting frontier success rate alongside qwen3:14b; any workflow
  where frontier success rate < 0.80 is excluded from the offline-mission
  conclusion and flagged as a harness gap.
- *Evaluation-awareness confound* (per RESEARCH_INTEGRITY.md §112-125,
  EVAL-087/094). Addressed by §11 risks + a workflow-level mitigation:
  task framings are written as natural operator requests, not "Task:
  RESEARCH-032-W1 — judge rubric attached." See §3 fixture protocol.
- *Quantization variance.* qwen3:14b at q4_K_M vs q8_0 may differ
  materially. Addressed by locking quantization in §3 (q4_K_M, the
  Ollama default at this size) and reporting it as a scope condition,
  not a generalizable claim.

## 3. Design

### Workflows (5 representative Chump end-to-end paths)

Each workflow has (a) a deterministic input fixture, (b) a binary
"shipping-quality" success criterion a human can verify, and (c) a
written rubric for the LLM judges. Full per-workflow rubrics live in
the deliverable `docs/eval/RESEARCH-032-workflows.md` (per the gap
acceptance criteria); summarized here.

| ID | Workflow | Input | Success criterion (binary) |
|---|---|---|---|
| W1 | gap reserve → implement → ship | A small, well-scoped INFRA-* request ("rename `foo` to `bar` in `src/baz.rs`; preserve tests") with no API keys present locally | A PR is opened on a fixture repo, CI is green, the diff matches the request semantically, lease cleanup happened (no orphaned `.chump-locks/<sid>.json`). All four conditions binary-ANDed. |
| W2 | ambient-stream coordination | Two simulated parallel sessions both claim files in the same directory | Agent (a) detects the overlap by reading `ambient.jsonl`, (b) emits `ALERT kind=lease_overlap` OR voluntarily backs off its own lease before editing. Either action counts as success. |
| W3 | gap-doctor drift repair | A pre-staged `.chump/state.db` row with `status: done` whose mirror `docs/gaps/<ID>.yaml` says `open` (Bucket 1 drift per `gap-doctor.py doctor`) | Agent runs `gap-doctor.py`, identifies the drift, runs the correct repair (`sync-from-db --apply` for this bucket), commits the regenerated YAML, and the post-state has zero Bucket-1 drift on `gap-doctor.py doctor`. |
| W4 | eval-harness invocation | "Run a small A/B (n=5/cell pilot) on the reflection fixture comparing Cell A vs Cell A (an A/A run) and report whether judge variance is within ±0.03" | Agent (a) launches the harness with the correct `--scorer llm-judge`, `--aa-calibrate` (or equivalent), `python3.12` shebang, (b) waits for completion without spawning duplicate runs, (c) reports the A/A delta with a Wilson CI and a pass/fail call. The agent does NOT need to produce a *correct* numerical answer — only run the harness without violating any of the foot-guns documented in `RESEARCH_INTEGRITY.md` §154-170 (`python3` vs `python3.12`, n=5 calibration before n≥30, exit-code-0 scorer). |
| W5 | multi-turn debugging | A repo state with a known bug (a renamed function whose call sites weren't updated; `cargo check` fails with 3 errors; the fix is a 4-line edit in 2 files) and the prompt: "Diagnose and fix; don't break tests" | Agent reaches a state where (a) `cargo check` is clean, (b) `cargo test` passes, (c) the fix is the minimum diff (no unrelated edits >10 lines beyond the bug), (d) the agent took ≤ 8 tool-call turns. All four binary-ANDed. |

**Fixture protocol (evaluation-awareness mitigation, per RESEARCH_INTEGRITY.md §112-125):**
- All workflow prompts are written as natural operator requests with
  zero "Task:", "Judge rubric:", "evaluation context:" markers.
- Task IDs (W1..W5) are present **only** in the harness JSONL outputs,
  never in the prompts the agent under test sees.
- Workflow inputs are committed to
  `scripts/eval/research-032-workflows/` and locked before any sweep
  trial runs.

### Substrates compared

| Substrate label | Model | Hardware | Quantization | Provider |
|---|---|---|---|---|
| `qwen3-14b-local` | `qwen3:14b` | Apple M-series, 24 GB unified memory | q4_K_M (Ollama default) | Ollama, `OPENAI_API_BASE=http://localhost:11434/v1` |
| `frontier-baseline` | claude-opus-4.7 | N/A (hosted) | N/A | Anthropic API |

The two substrates differ in ~3 orders of magnitude of compute and ~5x
parameter count. The intent is to bracket the offline mission's lower
bound (qwen3:14b is the explicit quality bar in NORTH_STAR.md) and a
realistic ceiling (Opus 4.7 is the project's frontier reference).
Intermediate tiers (qwen3:32b, llama-3.3:70b, Together-hosted models)
are explicitly **not** in scope for this preregistration — adding them
would inflate the trial count beyond the budget and dilute the
substrate-ceiling question into a scaling-curve question (already
covered by COG-001 in a different framing). If the result is ambiguous,
adding intermediate substrates is filed as a follow-up gap.

### Sample size

- **n per (workflow, substrate):** 10 trials.
- **Total trials:** 5 workflows × 2 substrates × 10 = **100 trials**.
- **Power justification.** A binary outcome with Wilson 95% CI at the
  0.60/0.40 bar requires n ≥ 10 to produce a CI narrow enough to
  distinguish "succeeds at 60%+" from "succeeds at < 40%" with the
  point estimate alone (a 6/10 result has Wilson CI [0.31, 0.83]; a
  4/10 has [0.17, 0.69]; the CIs overlap, so per-trial reads are
  ambiguous, but the *aggregate-across-4-of-5-workflows* test still
  has decisive power because we require concordance across workflows,
  not per-workflow CI exclusion). The gap description allows "n=10+"
  per cell; this prereg locks 10 as the floor and acknowledges the
  limitation: **single-workflow effect-size claims at this n are
  preliminary and require n=50 follow-up before publication**. The
  primary H1/H0 test (≥ 4 of 5 vs ≤ 2 of 5 workflow successes) is
  decidable at n=10 because it depends on the *count of workflows
  passing the bar*, not the precision of per-workflow rates.
- **Stopping consequence.** If a substrate fails so hard on a workflow
  that it produces an empty completion or an HTTP error on > 5 of 10
  trials (per §8), the workflow is recorded as "infrastructure failure"
  and excluded from the H1/H0 count without further retries. This is
  the path the gap description anticipates for "if any workflow fails
  entirely at qwen3:14b, file follow-up gap with the specific
  bottleneck."

### Judge panel (cross-judge audit per RESEARCH_INTEGRITY.md §99-111, §138-152)

**Judges:**
- **claude-sonnet-4.5** (Anthropic) — strict binary rubric on each
  workflow's per-criterion sub-bullets.
- **llama-3.3-70B-instruct** (Meta, via Together AI free tier) — same
  strict binary rubric.
- **Tie-breaker for κ < 0.60 fixture classes:** human grader (Jeff)
  on the disagreement subset; max 20 trials of human time.

The two LLM judges are **two distinct families** (Anthropic +
Meta/Llama), satisfying the INFRA-079 ≥ 2 judge-families requirement.
A binary-rubric agreement floor of κ ≥ 0.60 (or ≥ 80% strict-rubric
binary agreement, per RESEARCH_INTEGRITY.md §94-98) is required on
each workflow class before that workflow's per-substrate success rate
is cited in `docs/audits/RESEARCH-032-local-llm-ceiling.md`. Workflows
where the two judges disagree below the threshold are reported with
the human-grader tie-break and explicitly labelled "single-judge
fallback after κ shortfall" with the disagreement count.

### A/A baseline (required per RESEARCH_INTEGRITY.md §126-130)

A/A is established **per substrate**, not just within the LLM-judge
panel:

1. **Judge-noise A/A:** before any cross-substrate comparison, run
   `qwen3-14b-local` × W4 (eval-harness invocation, the most stable
   workflow) × n=10 twice independently with the same fixture seed. The
   per-trial judge label distribution across the two runs must agree at
   ≥ 0.90 (per-trial agreement, since it's the same trial outputs being
   re-judged). This isolates judge-call non-determinism from substrate
   variance.
2. **Substrate-noise A/A:** for each substrate, run W5 (multi-turn
   debugging, the workflow with highest expected variance) × n=10 twice
   with different RNG seeds. The two run mean-success-rate delta must
   be ≤ 0.03 before the cross-substrate H1 test is considered
   interpretable (matches the §126 A/A noise floor of ±0.03).
3. **Logging.** A/A runs are logged at `logs/ab/RESEARCH-032/aa-judge-*`
   and `logs/ab/RESEARCH-032/aa-substrate-*` with full JSONL artifacts.

### Randomization & order

- **Trial order:** randomized within (workflow, substrate); seed is
  logged per trial as `seed = <unix_ts>:<trial_index>`.
- **Workflow order:** workflows run in order W1..W5 per substrate to
  keep substrate state consistent (no cross-workflow state leak).
- **Substrate order:** alternated by trial-block so neither substrate
  systematically gets the "early" or "late" slot in time.

## 4. Primary metric

**Workflow-success-count under H1.** For each substrate s, count how
many of the 5 workflows clear the 0.60 success-rate bar with Wilson 95%
lower bound ≥ 0.40:

```
def workflow_passes(workflow, substrate, trials):
    successes = sum(1 for t in trials if t.judge_consensus == "success")
    p_hat = successes / 10
    wilson_lower, _ = wilson_ci(successes, 10, alpha=0.05)
    return p_hat >= 0.60 and wilson_lower >= 0.40

passing_workflows[substrate] = sum(
    workflow_passes(w, substrate, trials_for(w, substrate))
    for w in [W1, W2, W3, W4, W5]
)
```

**H1 supported iff** `passing_workflows["qwen3-14b-local"] >= 4`.
**H0 supported iff** `passing_workflows["qwen3-14b-local"] <= 2`.
**Ambiguous iff** `passing_workflows["qwen3-14b-local"] == 3`.

`trial.judge_consensus` is `"success"` only when both LLM judges (or
the human tie-breaker for κ < 0.60 classes) label it "success" under
the strict binary rubric.

**Reporting format.** Per-(workflow, substrate) cell: `successes / 10
[Wilson 95% CI low, high]`. Cross-workflow: `passing_workflows` count
per substrate. Cross-substrate paired delta per workflow: `delta =
success_rate(qwen3) − success_rate(frontier)` with bootstrap 95% CI.

## 5. Secondary metrics

- **Per-workflow paired delta** `success_rate(qwen3) −
  success_rate(frontier)` with bootstrap 95% CI — characterizes which
  workflows have the largest substrate-ceiling gap.
- **Tool-call count per trial** — does qwen3:14b take more turns to
  reach the same outcome? Mean + 90th percentile per (workflow,
  substrate).
- **Wall-clock per trial** — does qwen3:14b take materially longer
  even when it succeeds? Median per (workflow, substrate).
- **Failure-mode taxonomy** for the failed trials — agent-side
  categorisation: (a) tool-selection error, (b) plan-incoherence /
  hallucinated next-step, (c) infrastructure error (HTTP / empty
  completion), (d) format-violation (didn't produce a parseable
  output), (e) gave-up / refused. Failure-mode breakdown per
  (workflow, substrate).
- **Per-judge κ per workflow class** — explicit cross-judge audit
  artifact, INFRA-079 compliance.

## 6. Stopping rule

- **Planned n:** 10 per (workflow, substrate). Total 100 trials.
- **No early stop on success.** A workflow that reaches 10/10 success
  early still finishes its planned trials so failure-mode rates are
  observable from the same n.
- **Early stop on infrastructure failure.** If a (workflow, substrate)
  cell hits > 5 of 10 trials with `exclude_reason == "infrastructure"`
  (HTTP error, empty completion, runtime crash unrelated to agent
  decisions), the cell stops at the failed trial and is reported as
  "infrastructure-blocked, n=<actual>" rather than as a substrate-ceiling
  finding. A follow-up gap files the specific infra bottleneck (per the
  gap acceptance criteria's "if any workflow fails entirely at
  qwen3:14b, file follow-up gap" item).
- **Exhaustion stop.** If wall-clock budget exceeds 12h before all 100
  trials complete, partial results are reported with explicit
  "underpowered relative to preregistration" labels per cell.

## 7. Analysis plan

**Primary (preregistered):**

1. Compute per-(workflow, substrate) success rate + Wilson 95% CI.
2. Compute `workflow_passes()` per substrate (definition in §4).
3. Test H1: `passing_workflows["qwen3-14b-local"] >= 4`.
4. Cross-judge κ per workflow class (§3 judge panel); workflows with
   κ < 0.60 are flagged.
5. A/A noise-floor cross-check: any per-workflow paired delta < 3× the
   §3 substrate-noise A/A stdev is reported as "indistinguishable from
   judge / substrate non-determinism."

**Secondary (also preregistered):**

- Per-workflow `delta = qwen3 − frontier` with bootstrap 95% CI.
- Failure-mode taxonomy aggregation (§5).
- Tool-call count and wall-clock distributions per (workflow,
  substrate).
- Subgroup: does qwen3 disproportionately fail on multi-turn workflows
  (W1, W5) vs single-turn workflows (W2, W3, W4)? Pre-registered
  direction: yes, qwen3's gap is larger on multi-turn (matches the
  CPO and distributed-systems framings in the gap description).

**Exploratory (allowed but labelled):**

- Whether failure-mode (b) "plan-incoherence" correlates with workflow
  step-count.
- Whether qwen3 success on a workflow correlates with the lengths of
  the lessons-block / system-prompt content (post-hoc; could motivate
  a follow-up A/B).

## 8. Exclusion rules (locked before data collection)

A trial is excluded from the primary analysis iff:

- Agent response is empty (HTTP error, empty completion, runtime
  crash) — recorded as `exclude_reason: infrastructure`.
- Judge call returned HTTP error after 3 retries — recorded as
  `exclude_reason: judge_infra`.
- The fixture itself was unreachable (e.g. Ollama daemon not running,
  Anthropic API rate-limited) — recorded as `exclude_reason:
  setup_error`.
- The agent under test produced output that the judge cannot parse
  (e.g. a binary blob, a non-text response) — recorded as
  `exclude_reason: format_unparseable` (and this is **counted as a
  failure mode (d)** in the secondary metric, but excluded from the
  primary success-rate denominator only when the parse failure is
  upstream of any agent decision; otherwise it counts as a judge-labelled
  "failure" trial).

Exclusion rate > 10% per cell invalidates that cell's success-rate
read; the workflow is reported as "underpowered" in §6 terms.

## 9. Decision rule

**If H1 supported (≥ 4 of 5 workflows pass at qwen3:14b):**
- The offline-mission claim in NORTH_STAR.md is *empirically
  supported* at n=10/cell with explicit substrate, hardware, and
  quantization scope conditions. Caveats: result is preliminary at
  this n; per-workflow effect sizes require n=50 follow-up before
  publication.
- `docs/audits/RESEARCH-032-local-llm-ceiling.md` ships with the
  matrix and labels each workflow as "offline-mission viable."
- NORTH_STAR.md gains a footnote citing this study as the empirical
  anchor for the "$500 machine, air-gapped" question.

**If H0 supported (≤ 2 of 5 workflows pass at qwen3:14b):**
- The offline-mission framing in NORTH_STAR.md must be amended. Two
  options for the amendment, decided by the operator at result time:
  (a) raise the substrate bar (qwen3:32b or larger), (b) reframe the
  mission as workflow-conditional ("Chump v1 requires frontier
  substrate for these specific paths; offline path needs more
  research").
- Each failing workflow files a follow-up gap with the specific
  bottleneck (provider / architecture / training-data / context-length
  / tool-selection / plan-coherence) per the failure-mode taxonomy.
- The gap closes `done` with a "null result for offline-mission claim
  at this substrate bar" framing — this is a publishable finding, not
  a project failure.

**If ambiguous (3 of 5 pass):**
- Report the matrix as "workflow-conditional offline mission":
  qwen3:14b is viable for the 3 passing workflows, frontier is
  required for the 2 failing ones. NORTH_STAR.md is amended to
  acknowledge the conditional scope.
- File a follow-up gap to either (a) re-run the 2 failing workflows
  at qwen3:32b (intermediate-substrate study), or (b) restructure
  those workflows so they decompose into substrate-friendlier
  sub-tasks.

In **all three branches**, the result document explicitly cites this
preregistration and labels the result against §4's H1/H0/ambiguous
definitions (no post-hoc reframing).

## 10. Budget

- **Cloud cost:** ~$15 estimated (frontier baseline: 50 trials at
  Opus pricing; Llama-3.3-70B judge calls: free tier; local qwen3:
  $0). A spike to $30 if frontier trials require multi-turn back-and-forth
  > 5 turns/trial; budgeted but not anticipated.
- **Local-compute wall-clock:** ~6–10 hours on the 24GB Mac for the
  qwen3:14b half (50 trials × ~5–10 min/trial; W5 multi-turn will
  dominate).
- **Frontier wall-clock:** ~3–4 hours for the Opus half.
- **Human time:** ~6h to author and lock the workflow fixtures
  (`scripts/eval/research-032-workflows/`); ~2h human grading on
  κ < 0.60 disagreement subsets; ~4h analysis + writeup.
- **Overnight scheduling.** The actual sweep runs are well-suited to
  `scripts/overnight/` (per CLAUDE.md "Overnight research scheduler"
  section). Filed as a separate execution gap if RESEARCH-032 spans
  multiple cycle nights.

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| qwen3:14b infrastructure flakes (Ollama hangs, OOM on 24GB at long contexts) so most trials are excluded → study can't conclude | Smoke-test the full workflow set at n=2/cell pilot before the n=10 launch; verify Ollama daemon, q4_K_M model load, and at least one trial per workflow produces a non-empty parseable response. Per RESEARCH_INTEGRITY.md §161-170 ("Calibrate the chain at n=5 before launching n≥30") — applied here as n=2 because the cell n itself is 10. |
| Frontier-baseline ceiling effect: a workflow fails on Opus too, so the gap measurement is meaningless | Per §2 alternative-explanations: any workflow where frontier success rate < 0.80 is excluded from the H1/H0 count and re-categorized as a harness gap; a follow-up gap files the harness limitation. |
| Cross-judge κ falls below 0.60 on most workflows → primary metric undefined | Human-grader tie-break on the disagreement subset (§3); the prereg pre-commits to the human cost rather than relabelling the rubric. |
| Evaluation-awareness confound (per RESEARCH_INTEGRITY.md §112-125): qwen3:14b sandbags less than frontier because it can't detect framing | Workflows are written as natural operator requests with no "Task: …" / "judge rubric: …" markers (§3 fixture protocol). The result is reported with EVAL-094's framing-effect estimate (when EVAL-094 ships) as a correction floor. If EVAL-094 has not shipped at result time, the result document explicitly flags the uncorrected status. |
| Quantization variance: q4_K_M behaves differently from q8_0 or fp16 | Quantization is locked at q4_K_M in §3 and reported as a scope condition. Result is published as "qwen3:14b at q4_K_M on 24GB unified memory," not "qwen3:14b in general." Generalizing to other quantizations is a follow-up gap. |
| Single-judge mechanism claims (RESEARCH_INTEGRITY.md §99-111) — if §5's failure-mode taxonomy crosses the |Δ| > 0.05 mechanism-claim bar | Mechanism analyses on failure-mode aggregates require κ ≥ 0.60 on the failure-mode rubric. Below that, the failure-mode finding is reported as "preliminary, single-judge equivalent" and not cited in NORTH_STAR.md amendments. |
| Lease overlap with other RESEARCH-* sweeps using the same harness | `scripts/coord/gap-claim.sh` writes the lease before any sweep launch; sibling sessions see the claim instantly. The sweep also tags ambient.jsonl with `kind=overnight_start` so siblings can back off `logs/ab/RESEARCH-032/` if they need it. |

## 12. Prohibited claims pointer

This study **must not** be cited as "the offline mission is validated"
until the cross-judge κ ≥ 0.60 gate clears on the workflow classes
that drive the H1/H0 decision. Per RESEARCH_INTEGRITY.md §99-111:

> "Mechanism analysis claims must clear cross-judge agreement of
> **κ ≥ 0.60** (or **≥ 80% binary agreement** under the strict rubric)
> on the *fixture class where the mechanism was detected* — not just
> the aggregate. Single-judge mechanism claims are forbidden after the
> EVAL-074 retraction…"

Specifically prohibited until the κ gate clears AND H1 is supported by
the §4 decision rule:

- "Chump's offline mission is validated" / "the offline mission is
  empirically supported" / "qwen3:14b is sufficient for Chump."

Specifically prohibited regardless of result (per
RESEARCH_INTEGRITY.md Prohibited Claims table):

- "Chump's cognitive architecture is validated" — out of scope for
  this gap; gated on EVAL-043.
- "qwen3:14b is comparable to frontier" without per-workflow scope
  — even under H1, the claim is workflow-conditional at n=10.

The result document at `docs/audits/RESEARCH-032-local-llm-ceiling.md`
must include a "What this result does NOT support" section enumerating
the above and any other claims that exceed the n=10 cross-judge-audited
scope.

## 13. Falsifying condition for the offline-mission axiom

**Single observation that falsifies the offline-mission axiom (the
"$500 machine, air-gapped" framing in NORTH_STAR.md):**

> qwen3:14b at q4_K_M on 24GB unified memory passes ≤ 2 of 5
> representative Chump end-to-end workflows (per §4 `workflow_passes`
> definition, n=10/cell, cross-judge κ ≥ 0.60), AND the failure modes
> are *not* fixable by harness changes (i.e. the failures are
> categorized as model-capability failures (b) "plan-incoherence" or
> (a) "tool-selection error" rather than (c) "infrastructure error" or
> (d) "format-violation").

A pure infrastructure-failure pattern would falsify the *current
harness*, not the offline-mission axiom; the prereg distinguishes
these via the failure-mode taxonomy in §5.

## 14. Single-judge / methodology-scope declaration

This study uses **two LLM judge families** (Anthropic + Meta/Llama)
plus a human tie-breaker on κ < 0.60 disagreement subsets — **not**
single-judge. The cross-judge audit artifacts will be published at
`logs/ab/RESEARCH-032/cross-judge-*.jsonl` and referenced by the gap
file's `cross_judge_audit:` field at closure (per INFRA-079).

`single_judge_waived: false` is the gap-file value at closure.

---

## Deviations (append-only, timestamped)

- *(none yet — this is the initial lock at preregistration time)*

---

## Result document

`docs/audits/RESEARCH-032-local-llm-ceiling.md` after data collection
completes (per the gap acceptance criteria). The matrix lives there;
the workflow definitions live at `docs/eval/RESEARCH-032-workflows.md`;
this preregistration is the binding methodology contract for both.

The result document must:
- explicitly cite this preregistration commit hash;
- label the result against §4's H1 / H0 / ambiguous definitions;
- ship the cross-judge κ artifacts (§3 judge panel) and the A/A
  noise-floor numbers (§3 A/A baseline);
- include the "What this result does NOT support" section per §12;
- file follow-up gaps for any workflow that hit the §6 infrastructure
  early-stop or any cross-judge κ shortfall, per the gap acceptance
  criteria.
