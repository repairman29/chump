# Preregistration — `<GAP-ID>`

> **Status:** LOCKED at commit `<SHA-filled-at-commit-time>`. Do not edit
> locked fields after data collection begins — add a Deviations entry instead.
> See [`README.md`](README.md) for the protocol.

## 1. Gap reference

- **Gap ID:** `<GAP-ID>` (e.g. `RESEARCH-018`)
- **Gap title:** `<copy title from docs/gaps.yaml>`
- **Source critique:** `<link to docs/RESEARCH_CRITIQUE_*.md §N if applicable>`
- **Author:** `<name or agent session-id>`
- **Preregistration date:** `<YYYY-MM-DD>`

## 2. Hypothesis

**Primary hypothesis (H1) — must be falsifiable:**
> If `<intervention>`, then `<measurable outcome>` will change by
> `<direction>` of at least `<effect size>` relative to `<comparison condition>`.

**Null hypothesis (H0):**
> `<what "no effect" looks like on the primary metric>`

**Alternative explanations to rule out (specify which control addresses which):**
- Alternative 1: `<e.g. prompt-length confound — addressed by Cell C>`
- Alternative 2: `<e.g. judge-family bias — addressed by cross-family panel>`

## 3. Design

### Cells
| Cell | Intervention | Expected direction |
|---|---|---|
| A | `<control / baseline>` | neutral |
| B | `<treatment>` | `<+ / − / ≈ with magnitude>` |
| C (if needed) | `<length-matched null / placebo>` | `<+ / − / ≈ with magnitude>` |

### Sample size
- **n per cell:** `<number>`
- **Power analysis:** `<rationale for n — e.g. "to detect Δ=0.10 at α=0.05 with power=0.80 on a binary outcome, n≥48 per cell; using n=50">` 
- **Fixtures used:** `<scripts/ab-harness/fixtures/...>` (full paths)

### Model & provider matrix
| Role | Model(s) | Provider | Endpoint |
|---|---|---|---|
| Agent under test | `<list>` | `<list>` | `<list>` |
| LLM judge | `<list — MUST include ≥1 non-Anthropic per RESEARCH_INTEGRITY.md>` | `<list>` | `<list>` |
| Human judge subset (if any) | `<Jeff / external>` | — | — |

### Randomization & order
- **Trial order:** `<random per cell / deterministic A-then-B / interleaved>`
- **Seed discipline:** `<how RNG seeds are logged>`

## 4. Primary metric

**Exact definition (two analysts computing this must get the same number):**

```
<pseudocode or formula that computes the metric from the trial JSONL>
```

**Reporting format:** point estimate + Wilson 95% CI + A/A noise floor from
`<cite A/A run>`.

## 5. Secondary metrics

- `<e.g. hallucinated-tool-call rate per EVAL-041 regex>`
- `<e.g. mean tool-calls per trial>`
- `<e.g. judge inter-rater kappa>`

## 6. Stopping rule

**Planned n:** `<number>`

**Early stop allowed?** `<yes/no>`. If yes, under what condition:
`<e.g. after n=25/cell, if Wilson CI excludes zero at α=0.01, stop — and
explicitly label result as interim>`

**Exhaustion stop:** If budget exceeded before planned n, report partial
result with explicit "underpowered relative to preregistration" label.

## 7. Analysis plan

**Primary analysis (preregistered):**
1. Compute primary metric per cell with Wilson 95% CIs.
2. Compute pairwise deltas (B−A, and C−A if applicable) with bootstrapped CIs.
3. Test H1 by checking whether the B−A CI excludes zero in the predicted direction.
4. Report against the A/A noise floor: delta must be ≥3× the A/A stdev to be interpretable.

**Secondary analyses (also preregistered):**
- Subgroup analysis by `<task type / fixture category>`
- Per-judge agreement (kappa)
- Mediation analysis if applicable (per RESEARCH-023)

**Exploratory analyses (allowed but clearly labeled):**
- `<what you plan to look at if the preregistered analysis is ambiguous>`

## 8. Exclusion rules (lock before data collection)

A trial is excluded from analysis iff:
- `<e.g. agent response contains empty string>`
- `<e.g. judge call returned HTTP error>`
- `<e.g. OPENAI_API_BASE was unreachable>`

All exclusions must be logged with reason. Exclusion rate >10% invalidates the sweep.

## 9. Decision rule

**If H1 supported** (B−A CI excludes zero in predicted direction, Δ ≥ threshold):
`<what ships to FINDINGS.md, what gap closes how>`

**If H1 rejected** (CI overlaps zero or effect reversed):
`<how the result is still publishable — e.g. "null result ruling out alternative X">`

**If ambiguous** (CI wide, overlaps zero but mean in predicted direction):
`<next step — e.g. escalate to n=100, file follow-up gap>`

## 10. Budget

- **Cloud cost:** $`<estimate>`
- **Wall-clock:** `<estimate>`
- **Human time:** `<if any — e.g. 4h grading>`

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `<e.g. instrument returns empty outputs (INFRA-017 foot-gun)>` | `<e.g. smoke-test first 3 trials, abort if exit_code != 0>` |
| `<e.g. sibling session touches same fixture file>` | `<e.g. gap-claim.sh --paths covers fixture dir>` |

---

## Deviations (append-only, timestamped)

Any change to the locked fields above (sections 2–10) after data collection
begins must be recorded here. Do **not** edit the locked fields in place.

- `<YYYY-MM-DD HH:MM UTC>` — `<author>` — `<change>` — `<reason>`

---

## Result document

After data collection completes, the result document at
`docs/eval/<GAP-ID>-*.md` **must** link back to this preregistration and
explicitly state whether the preregistered hypothesis was supported,
rejected, or ambiguous per the decision rule above.
