# Preregistration — RESEARCH-020

> **Status:** LOCKED. See [`README.md`](README.md) for the protocol.

## 1. Gap reference

- **Gap ID:** RESEARCH-020
- **Gap title:** Ecological fixture set — 100 real-world tasks scraped from open-source GitHub issues and PRs
- **Source critique:** [`docs/research/RESEARCH_CRITIQUE_2026-04-21.md`](../../RESEARCH_CRITIQUE_2026-04-21.md) §2
- **Author:** agent frontier-scientist (Opus 4.7)
- **Preregistration date:** 2026-04-21

## 2. Hypothesis

**H1 (primary).** The three headline Chump findings — (i) tier-dependent
injection, (ii) lessons-block hallucination channel, (iii) scaffolding
U-curve — reproduce on an ecological fixture set (real-world GitHub
issues/PRs) with effect magnitudes within ±50% of the synthetic-fixture
values. Formally, for each finding: `|Δ_ecological / Δ_synthetic − 1| ≤ 0.50`.

**H0.** At least one of the three findings shrinks by >50% or flips sign
on the ecological fixture set — indicating the synthetic fixtures were
author-tuned in a way that inflated the effect.

**Alternative explanations ruled out:** *Author-tuning confound.* If
findings replicate on fixtures authored independently by OSS contributors,
author-tuning cannot be the driver.

## 3. Design

### Cells (per finding)

For each of the three findings, run the original A/B cells from the
published EVAL docs, on the ecological fixture instead of the synthetic
one. Cells mirror the published study.

### Fixture curation (the actual deliverable)

- **Source:** 5 open-source repositories spanning 3 domains —
  - Systems: `https://github.com/rust-lang/rust` issues, `https://github.com/sharkdp/bat` issues
  - Web: `https://github.com/vercel/next.js` issues
  - ML tooling: `https://github.com/huggingface/transformers` issues, `https://github.com/ollama/ollama` issues
- **Selection:** 20 tasks per repo, sampled from the 90th-percentile-engagement 2025 tickets (comments ≥ 5, state closed with PR). 100 total.
- **Conversion protocol:** Each issue + its resolving PR becomes a fixture item with:
  - `prompt`: issue body + "Propose a fix"
  - `rubric`: SHA-hashed PR diff (success = agent's proposed fix touches ≥1 of the same files as the real PR and its test-assertion structure matches real PR's)
  - `fixture_id`: `ecological_v1/<repo>/<issue-id>`
- **Sourcing criterion:** issue must not have been used in any EVAL-NNN synthetic fixture (dedupe against existing fixtures).
- **Human validation:** 10 randomly-sampled ecological tasks are manually graded by the author to verify the rubric correctly detects the real PR's fix. ≥80% agreement required before the sweep runs.

### Sample size
- **n per cell per finding:** 50 (subsampled to 50 of the 100 per cell-role)
- **Cells per finding:** 2 (A/B as in original)
- **Findings:** 3
- **Total trials:** 3 × 2 × 50 = 300 trials on ecological fixture

### Model & provider matrix
Same as the original EVAL for each finding being replicated. Judge panel
follows RESEARCH_INTEGRITY.md: ≥1 non-Anthropic judge.

## 4. Primary metric

**Per finding**: the same primary metric defined in the original EVAL doc
(correctness, hallucination rate, or pass rate as applicable). Re-compute
on ecological data; compare to synthetic value.

**Replication metric:** `|Δ_ecological / Δ_synthetic − 1|` (relative
deviation). H1 supported if ≤0.50 for all three findings.

## 5. Secondary metrics

- Per-repository subgroup analysis — is any domain driving the replication
  (or lack thereof)?
- Difficulty stratification — ecological tasks are likely harder than
  synthetic; report per-cell baseline accuracy alongside deltas.

## 6. Stopping rule

Planned n=50 per cell per finding. No early stop. If ecological fixture
construction fails to produce 100 valid tasks within 2 weeks, reduce to n=30
per cell and label as underpowered.

## 7. Analysis plan

**Primary (preregistered):**
1. Ecological sweep for each finding at n=50/cell.
2. Compute ecological Δ per finding with Wilson 95% CI.
3. Compute relative deviation `|Δ_ecological / Δ_synthetic − 1|`; bootstrap 95% CI.
4. H1 holds if ≤0.50 for all three findings simultaneously.

**Secondary (preregistered):**
- Per-repo replication rate.
- Per-difficulty-bin replication (easy/medium/hard partitioning by real-PR LOC).

## 8. Exclusion rules

Trial excluded if fixture rubric cannot be evaluated (real PR SHA missing,
test structure unreadable, judge cannot compare agent fix to real fix).

## 9. Decision rule

**If H1 supported:** findings are ecological-valid. Paper 2 publishes as
"validated replication." Note limitation that it's 5 repos, not universe.

**If H1 rejected on ≥1 finding:** the failing finding needs a reframe.
Publish as "synthetic-fixture author-tuning inflated effect X" — still a
publishable methodology contribution. Paper 2 leads with that reframe.

## 10. Budget

- **Cloud:** ~$25 (300 trials × ~$0.08)
- **Wall-clock fixture curation:** ~2 weeks
- **Sweep wall-clock:** ~4 hours
- **Human time:** ~40 hours (fixture curation + validation + analysis)

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Rubric cannot reliably detect agent's fix matches real PR | Manual validation gate (≥80% agreement on 10 random fixtures) before sweep |
| Real PRs are too complex for n=50 to surface signal | Report underpowered result; file follow-up at n=100 |
| Repo license incompatibility with redistribution | Use issue *content hash* + pointer URL, not verbatim copy, in fixture JSON |
| Dataset contamination (judge saw these PRs in training) | Stratify report by pre-2024 vs 2025 issues (training-cutoff boundary) |

---

## Deviations

*(none yet)*

---

## Result document

`docs/eval/RESEARCH-020-ecological-replication.md` after sweep.
