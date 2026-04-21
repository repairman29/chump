# Preregistration — RESEARCH-028

> **Status:** LOCKED. See [`README.md`](README.md) for the protocol.

## 1. Gap reference

- **Gap ID:** RESEARCH-028
- **Gap title:** Blackboard tool-selection-mediation test — does the blackboard mediate behavior non-verbally via tool sequences?
- **Source critique:** [`docs/eval/REMOVAL-001-addendum-RESEARCH-022.md`](../REMOVAL-001-addendum-RESEARCH-022.md) §"blackboard" + "New recommended follow-up gap"
- **Author:** agent frontier-scientist (Opus 4.7)
- **Preregistration date:** 2026-04-21

## 2. Hypothesis

**H1 (primary).** Tool-call sequence divergence between Cell A (blackboard ON)
and Cell B (blackboard OFF) exceeds the A/A noise floor on blackboard-salience-
rich tasks. Formally: `mean_divergence(A vs B) > mean_divergence(A vs A) + ε`
with bootstrap 95% CI excluding zero, where ε = 2 × A/A_stdev.

**H0.** Sequence divergence not distinguishable from A/A noise — the
blackboard does not mediate behavior even non-verbally at this fixture.
**If H0 holds, file REMOVAL-005** (blackboard removal) per the
REMOVAL-001-addendum recommendation.

**Alternative explanations:**
- *Agent non-determinism as noise floor* — addressed by the A/A baseline
  cell (same config, same exposure, just re-runs). Anything below A/A
  divergence is noise.
- *Fixture task-mix accidentally biases toward blackboard use in Cell A* —
  addressed by task-pair matching: A and B run the same task ids; no
  fixture asymmetry.
- *Sequence divergence reflects response-length differences not actual
  tool-selection differences* — addressed by two divergence metrics:
  (i) tool-bigram Jensen-Shannon (shape-invariant to total-count
  differences), (ii) normalized Levenshtein edit distance on tool-name
  sequences.

## 3. Design

### Cells

| Cell | Blackboard | CHUMP_BYPASS_BLACKBOARD | Purpose |
|---|---|---|---|
| A  | ON (default) | 0 | Treatment |
| B  | OFF | 1 | Control |
| A' | ON (default) | 0 | A/A noise-floor baseline (same config as A, re-runs) |

### Sample size

- **n per cell:** 50 matched tasks
- **Cells:** A, B, A' — 3 total
- **Total trials:** 150
- **Power rationale:** At n=50 per cell the A-vs-B paired-sequence
  comparison has power ≥0.80 to detect a mean-divergence shift of
  0.15 on a 0-1 normalized metric (small-effect detection). A/A
  baseline at n=50 tightens the noise-floor estimate to ±0.04 stdev.

### Fixture — blackboard-salience subset

Select 50 tasks from the existing neuromod fixture
(`scripts/ab-harness/fixtures/neuromod_tasks.json` — per EVAL-029
mechanism drilldown, this is the fixture with tool-retry /
escalation / refusal patterns where prior-turn state should matter).

**Selection criterion (preregistered):**
- Task must involve a tool call whose outcome (success / failure /
  risk-flag) could plausibly inform the next tool call.
- Task ID patterns meeting criterion: `dynamic-*`, `*-conditional-*`,
  `*-retry-*`, `*-escalate-*` (regex-matched from the fixture id
  field).
- If fewer than 50 qualifying tasks exist, degrade to all qualifying
  tasks and report the final n in the result doc. Minimum acceptable
  n = 30 (below which power falls below 0.70).

The selection is deterministic: every task in the neuromod fixture
matching the regex above is included, in filename order. No post-hoc
task removal allowed after data collection.

### Model & provider matrix

| Role | Model | Provider |
|---|---|---|
| Agent | claude-haiku-4-5 | Anthropic native |
| Judge-free — sequence comparison is a mechanical metric, no LLM scoring required for the primary hypothesis | — | — |

Haiku-4-5 is chosen as agent because: (a) all existing Chump A/B
findings on neuromod fixture use haiku, (b) the blackboard's
architectural-plausibility argument in REMOVAL-001 cited cross-turn
state tracking — frontier-tier sonnet models are more likely to
maintain state latently regardless of blackboard, so haiku is the
tier where the blackboard's utility, if real, should show most
clearly.

### Randomization & order

- Trial order: deterministic (task id sort), same across all 3 cells.
- RNG seed: `(cell_name, trial_idx)` hashed with SHA-256 — reproducibility.
- A/A cell is Cell A re-run under a **different** RNG seed to capture
  agent-level stochasticity; does not resample the task list.

## 4. Primary metric

**Tool-call sequence divergence** between a cell-A trial and its
paired cell-B trial (same task id).

**Two divergence metrics computed per task pair:**

1. **`js_div_bigram`** — Jensen-Shannon divergence over tool-call
   bigram distributions. For each trial, extract the ordered
   sequence of tool names (e.g. `[read_file, run_cli, read_file]`),
   build bigrams including `<START>` and `<END>` sentinels,
   normalize to a distribution, compute JS divergence between the
   two trials' distributions.
2. **`norm_levenshtein`** — Levenshtein edit distance on the tool
   name sequence, normalized by max(len_A, len_B).

**Per-cell mean divergence vs paired A' trial:**

```
mean_divergence(X vs Y) = mean over tasks of {
    0.5 * js_div_bigram(task_X, task_Y) + 0.5 * norm_levenshtein(task_X, task_Y)
}
```

The 0.5/0.5 weighting is locked here and may not change after data
collection. Report both metrics individually as secondary analyses
so downstream readers can re-weight.

**Primary H1 test:**
- Compute `mean_divergence(A vs B)` — treatment vs control.
- Compute `mean_divergence(A vs A')` — noise floor.
- H1 holds iff `mean_divergence(A vs B)` exceeds `mean_divergence(A vs A')`
  by ≥ 2 × stdev(A vs A') with a paired-bootstrap 95% CI excluding
  zero on the difference.

## 5. Secondary metrics

- **Per-metric decomposition:** report JS-bigram delta and normalized-
  Levenshtein delta separately. If one metric crosses threshold and the
  other doesn't, report as "partial evidence."
- **Outcome axis:** compute per-trial `is_correct` for both cells. Does
  sequence divergence correlate with outcome divergence? If the two
  correlate, the blackboard's mediation has a meaningful downstream
  footprint. If not, the blackboard changes HOW the agent reaches the
  same outcome.
- **Sequence length:** mean tool-calls-per-trial per cell. If Cell A
  systematically emits more tool calls than Cell B, the metric may be
  confounded with tool-call count; flag if delta > 20%.

## 6. Stopping rule

Planned n=50 matched tasks per cell. No early stop.

**Exhaustion stop:** If the blackboard-salience subset yields fewer
than 30 qualifying tasks, report at the lower n and mark as
underpowered.

## 7. Analysis plan

**Primary (preregistered):**
1. Run the 3-cell sweep; collect JSONL with per-trial tool-call
   sequences (already logged by run-cloud-v2.py as part of the trial
   records).
2. For each task id, compute the two divergence metrics on each of
   the A-vs-B and A-vs-A' pairs.
3. Compute mean divergence per pair-type with paired-bootstrap 95% CIs
   (10k resamples).
4. Apply the H1 test.

**Secondary (preregistered):**
- Per-metric reporting.
- Outcome-divergence correlation.
- Sequence-length covariate check.

**Mediation analysis integration (RESEARCH-023):**
If H1 holds, report TE/NDE/NIE via
`scripts/ab-harness/mediation-analysis.py` with
`tool_sequence_category` as the mediator variable (bucketed by
dominant bigram pattern). This quantifies how much of the
blackboard's outcome effect (if any) flows through tool-selection
vs. other paths.

**Exploratory:**
- Per-task subgroup — which task shapes (retry / escalate / refusal)
  produce the largest divergence?
- Qualitative review — read the 5 highest-divergence tasks' tool
  sequences side-by-side to characterize what the blackboard is
  doing when it matters.

## 8. Exclusion rules

Trial excluded iff:
- Agent produced empty output (exit_code ≠ 0 or output_chars < 10)
- Tool-call sequence is empty (no tools invoked) on **both** cells
  for the paired task (gives no signal)
- Bypass flag did not propagate (detected by absence of expected
  env var in trial log)

Exclusion rate >15% invalidates the sweep.

## 9. Decision rule

**H1 supported (divergence exceeds noise floor by ≥2σ):** Blackboard
mediates behavior via tool selection. REMOVAL-001's KEEP verdict
upgraded from "conditional" to "confirmed." The result is a novel
mechanism finding for Paper-3-adjacent work.

**H0 supported (divergence within noise floor):** Blackboard does
not mediate even non-verbally. **File REMOVAL-005** to remove the
blackboard module. Update `docs/CHUMP_FACULTY_MAP.md` Executive
Function row. Update `docs/eval/REMOVAL-001-addendum-RESEARCH-022.md`
with the confirmed-remove decision.

**Ambiguous (CIs wide, directional positive but not significant):**
Escalate to n=100 per cell. File follow-up gap RESEARCH-029.

## 10. Budget

- **Cloud:** ~$8 haiku (150 trials × ~\$0.05 amortized)
- **Wall-clock:** ~2 hours sweep + ~1 hour analysis
- **Human time:** ~12 hours (fixture selection validation, result doc)

Per `docs/eval/preregistered/COST_OPTIMIZATION.md` this gap has no
Together free-tier substitution available — agent is Anthropic-family
and the judge is mechanical (sequence-divergence metric, no LLM
judge). Budget is as-stated.

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Agent non-determinism dominates divergence | A/A noise-floor cell explicitly measures it — anything below A/A is noise |
| Tool-sequence length shift between cells confounds metric | Sequence-length covariate check in §5; flag if >20% delta |
| Blackboard-salience task selection biases toward retry-heavy patterns | Deterministic regex-based selection locked in §3; no post-hoc task removal |
| CHUMP_BYPASS_BLACKBOARD doesn't actually disable the module | Pre-sweep smoke: 3-trial inspection verifies no blackboard-related log lines in Cell B traces; abort if present |
| Haiku is too small a tier to exhibit blackboard mediation even if it's real on frontier models | Acknowledged scope caveat — H0 result interpreted as "at haiku tier"; file follow-up for sonnet if H0 |
| python3 vs python3.12 foot-gun (INFRA-017) | Fixed across harness per INFRA-017 ship — verify harness invocation uses python3.12 pre-sweep |

---

## Deviations (append-only)

*(none yet — locked at preregistration commit)*

---

## Result document

After data collection, results will be reported in
`docs/eval/RESEARCH-028-blackboard-tool-mediation.md` with an explicit
statement of whether H1 was supported, rejected, or ambiguous per §9.
Faculty-map update and REMOVAL-005 filing (if H0) happen in the same
commit as the result doc.
