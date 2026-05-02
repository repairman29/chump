# Preregistration — EVAL-090

> **Status:** LOCKED at commit `<filled-at-commit-time>`. Do not edit
> locked fields after data collection begins — add a Deviations entry instead.

## 1. Gap reference

- **Gap ID:** EVAL-090
- **Gap title:** Re-run EVAL-069 under verified python3.12 — F3 retirement is based on broken-vs-broken comparison
- **Source critique:** `docs/audits/INTEGRITY_AUDIT_3_EVAL_METHODOLOGY.md`
- **Author:** chump-eval-090-rerun-1777683833 (Claude Opus 4.7)
- **Preregistration date:** 2026-05-01

## 2. Hypothesis

This preregistration tests two distinct claims:

**Empirical hypothesis (H1) — falsifiable:**
> If `CHUMP_BYPASS_NEUROMOD=1` (cell B) actually harms the chump binary's
> aggregate `is_correct` rate on the `neuromod_tasks.json` fixture under the
> Ollama qwen2.5:14b agent, then under a verified `scorer=llm_judge`
> instrument the cell-A − cell-B accuracy delta will be ≥ +0.10 (i.e. ≥10
> percentage points harm) with a Wilson 95% CI excluding zero.

**Null hypothesis (H0):**
> Delta is ≤ 0.10 in absolute value, with CI overlapping zero. EVAL-069's
> retirement of F3 (neuromod aggregate magnitude claim) stands.

**Methodological hypothesis (M1):**
> If INTEGRITY_AUDIT_3's claim (EVAL-069 ran under broken `exit_code_fallback`)
> is correct, the new JSONL will show `scorer=llm_judge` for ≥99% of rows
> (because we explicitly invoke `python3.12` and pass `--scorer llm-judge`),
> producing **different** numbers than EVAL-069's archived JSONL. M1 is
> rejected if the new JSONL replicates the archived `acc_A=0.920, acc_B=0.920`
> within sampling noise.

**Alternative explanations to rule out:**
- *Judge family bias (Claude-only).* Addressed by secondary cross-judge (§3).
- *Fixture too easy (ceiling effect).* Addressed by secondary metric: per-task
  failure-rate variance between cells.
- *Stochastic agent variation, not neuromod.* Addressed by A/A baseline run.

## 3. Design

### Cells
| Cell | Intervention | Expected direction |
|---|---|---|
| A | `CHUMP_BYPASS_NEUROMOD` unset (neuromod active, control) | neutral |
| B | `CHUMP_BYPASS_NEUROMOD=1` (neuromod bypassed, ablation) | unknown — H1 predicts −10pp; H0 predicts ≈0 |

### Sample size
- **n per cell:** 50 (matching EVAL-069 for direct comparability)
- **Power analysis:** With n=50/cell on a binary outcome, we have ~80% power
  to detect Δ=0.10 at α=0.05 (Wilson CI). The original EVAL-026 effect was
  −10 to −16 pp; if real, n=50 should detect it. If we miss a Δ<0.10 effect,
  that's an acceptable miss for this gap's scope.
- **Fixtures used:** `scripts/ab-harness/fixtures/neuromod_tasks.json` (100
  tasks, cycled t001–t030 — same fixture EVAL-069 used)

### Model & provider matrix
| Role | Model | Provider | Endpoint |
|---|---|---|---|
| Agent under test | qwen2.5:14b | Ollama (local) | http://127.0.0.1:11434/v1 |
| LLM judge — primary | claude-haiku-4-5 | Anthropic | api.anthropic.com |
| LLM judge — secondary (kappa subset) | meta-llama/Llama-3.3-70B-Instruct-Turbo | Together (free tier) | api.together.xyz/v1 |

Cross-judge audit: secondary judge re-scores a random 20-row subset (10 from
each cell) for kappa computation. Below the INFRA-079 cross-judge bar of full
n=50 cross-scoring, but sufficient for kappa direction; pre-declared as scope
limit per `single_judge_waived: false, kappa_subset: true`.

### Randomization & order
- **Trial order:** deterministic — A then B, task IDs cycled identically
  across cells (EVAL-069 protocol)
- **Seed discipline:** Ollama is run with default temperature; we capture
  per-trial wall-clock + token counts in JSONL. No reseed control — variance
  is what it is.

## 4. Primary metric

```
acc_cell = sum(1 for r in rows if r['cell'] == cell and r['scorer'] == 'llm_judge' and r['correct']) / sum(1 for r in rows if r['cell'] == cell and r['scorer'] == 'llm_judge')
delta = acc_A - acc_B
```

Rows with `scorer=exit_code_fallback` are **excluded** from the primary
analysis (those represent the foot-gun the gap exists to avoid). Exclusion
rate >5% invalidates the sweep; abort and report.

**Reporting:** point estimate + Wilson 95% CI per cell; bootstrap 95% CI on
the delta.

## 5. Secondary metrics

- Per-task failure rates by cell (where do the failures concentrate?)
- Cross-judge kappa on the n=20 subset (Cohen's κ between Claude Haiku and Llama-3.3-70B)
- Mean tool-calls per trial (cheap proxy for whether neuromod ablation changes behavior at all, even if accuracy doesn't move)

## 6. Stopping rule

**Planned n:** 50/cell. **Early stop:** none. **Exhaustion stop:** if Anthropic
API spend exceeds $2 or wall-clock exceeds 4h, stop and report partial.

## 7. Analysis plan

1. Confirm `scorer=llm_judge` rate ≥95% in raw JSONL. If not, abort.
2. Compute primary metric per cell with Wilson 95% CIs.
3. Compute delta with bootstrap CI.
4. Compare to EVAL-069 archived JSONL: do we replicate the `acc=0.920` point
   estimate within ±0.05?
5. Cross-judge kappa on subset.

## 8. Exclusion rules

A trial is excluded iff:
- `scorer=exit_code_fallback` (the foot-gun)
- agent subprocess timed out (>120s, harness default)
- `output_chars=0` AND `exit_code != 0` (degenerate)

All exclusions logged with reason. Exclusion rate >5% invalidates.

## 9. Decision rule

**If H1 supported** (delta ≥ +0.10, CI excludes zero, predicted direction):
F3 is **reinstated** in `docs/FINDINGS.md`. EVAL-069's retirement decision
was correct that the audit's instrument concern was real, but wrong that
the underlying signal was absent. File follow-up to extend to other agents.

**If H0 supported** (delta CI overlaps zero, |delta| < 0.10):
F3 retirement **stands**, but the AUDIT-3 caveat in `docs/FINDINGS.md` is
**rewritten** to remove the "broken-vs-broken" framing — replication under
verified scorer confirms the null. Note that the audit's broader
methodological lesson (audit JSONL evidence, not just shebang inference)
is preserved.

**If ambiguous** (delta point estimate in predicted direction but CI overlaps
zero): file follow-up to extend to n=100/cell or replicate on Together-routed
agent.

**Methodological M1 outcome:** documented in result writeup either way —
this is the audit-versus-evidence reconciliation that motivated EVAL-090.

## 10. Budget

- **Cloud cost:** ≤ $2 (Claude Haiku 4.5 judge for 100 trials + 20-trial cross-judge subset on Together free tier)
- **Wall-clock:** ≤ 2h (Ollama local agent is the bottleneck; ~30s/trial × 100 = 50min plus judge time)
- **Human time:** none beyond writeup

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Scorer falls back to exit_code_fallback (the original foot-gun) | Smoke-test first 3 trials, abort if any row shows fallback |
| Ollama crashes mid-run | Harness logs per-row; can resume from JSONL gap |
| Together API rate-limits judge subset | Subset is small; retry once, else report kappa as N/A |
| Sibling session touches `scripts/ab-harness/fixtures/neuromod_tasks.json` | Lease covers the fixture path implicitly via worktree isolation |

---

## Deviations (append-only, timestamped)

_(none yet)_

---

## Result document

After data collection completes, the result document at
`docs/eval/EVAL-090-neuromod-aggregate-rerun.md` **must** link back to this
preregistration and explicitly state whether H1, H0, or ambiguous per §9.
