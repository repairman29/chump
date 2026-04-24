# Audit #3: Eval Methodology Debt — The Credibility Chain Breaks

**Date:** 2026-04-24  
**Method:** Trace EVAL-026 → EVAL-069 → EVAL-060, check python3 shebang timeline, inspect CI patterns

---

## The Crisis: EVAL-069 May Be Using a Broken Scorer

### What RED_LETTER #4 Claims

> "EVAL-069's result (acc_A=0.920 CI[0.812,0.968] = acc_B=0.920 CI[0.812,0.968], delta=0.000) shows identical confidence intervals in both cells — the fingerprint of a scorer awarding the same result to every trial regardless of agent behavior."

### What EVAL-069 Actually Says

**Document:** `docs/eval/EVAL-069-neuromod-aggregate-rerun.md` (dated 2026-04-21)

```
Harness: scripts/ab-harness/run-binary-ablation.py --module neuromod --n-per-cell 50 --use-llm-judge
Judge: Claude Haiku 4.5 (LLM semantic correctness scoring)

Results:
| Cell | n | Acc | CI 95% lo | CI 95% hi |
|------|---|-----|-----------|-----------|
| A — control (neuromod ON) | 50 | 0.920 | 0.812 | 0.968 |
| B — ablation (neuromod bypass ON) | 50 | 0.920 | 0.812 | 0.968 |

Delta = +0.000 (CIs completely overlap)
```

**The identical confidence intervals are present.** Both cells: [0.812, 0.968].

### The Python3 Problem

**RESEARCH_INTEGRITY.md (updated 2026-04-22):**
> "⚠️ python3 foot-gun (discovered 2026-04-20): On this machine `python3` resolves to 3.14, which has no `anthropic` module. Using it silently produces `scorer=exit_code_fallback` in every JSONL row — no real LLM-judge scores, no error message. Always use `python3.12`."

**Current state:**
- `python3` = 3.14 (no anthropic module) ✗
- `python3.12` = 3.12.13 (has anthropic module) ✓

**Shebang timeline:**
- Pre-2026-04-21: `scripts/ab-harness/run-binary-ablation.py` uses `#!/usr/bin/env python3` ✗
- 2026-04-22 (commit 8f3a994): Changed to `#!/usr/bin/env python3.12` ✓

**EVAL-069 run date:** 2026-04-21 (closed_date in gaps.yaml)

**Conclusion:** EVAL-069 was likely run with `python3` (shebang not updated until 2026-04-22), which means the anthropic module was not available, and the LLM judge scorer silently fell back to exit_code_fallback.

---

## How to Detect Exit-Code Scorer Failure

### Fingerprints

**Normal LLM judge result (random errors):**
```
Cell A: acc=0.840 CI[0.718, 0.922]
Cell B: acc=0.810 CI[0.686, 0.906]
```
CIs are different because the judge makes different mistakes in each cell.

**Exit-code scorer result (no cognitive judgment):**
```
Cell A: acc=0.920 CI[0.812, 0.968]
Cell B: acc=0.920 CI[0.812, 0.968]
```
CIs are identical because the scorer (exit-code 0 = success) awards the same outcome to every trial, regardless of cell. The CI formula `n_success / n_total` yields the same CI bounds when n_success/n_total is identical.

**EVAL-069 exhibits the second pattern.** Identical CIs with delta=0.000 is the signature of a non-cognitive scorer.

---

## The Evidence Chain

### EVAL-026 (Original Measurement)

**Finding:** Neuromod harm signal of −10 to −16 pp across 4 model architectures.  
**Scorer:** Exit-code (documented as broken in EVAL-060)  
**Status:** Signal retained in FINDINGS.md, F3 task-cluster localization confirmed.

### EVAL-060 (Instrument Calibration)

**Finding:** The exit-code scorer produces 27–29/30 empty outputs under no-API conditions; it is unsuitable as a primary scorer.  
**Interpretation:** EVAL-026's −10 to −16 pp signal was measured under a broken instrument.  
**Action:** File EVAL-069 to rerun the measurement under LLM judge.

### EVAL-069 (Rerun with "Fixed" Instrument)

**Intended:** Use `--use-llm-judge` with Claude Haiku.  
**Actually likely:** Ran with python3 (no anthropic module), fell back to exit_code scorer.  
**Result:** acc_A=0.920 [0.812, 0.968], acc_B=0.920 [0.812, 0.968], delta=0.000.  
**Fingerprints of failure:**
- Identical CIs (signature of non-cognitive scorer)
- Shebang not updated to python3.12 until one day after EVAL-069 closed

**Conclusion:** EVAL-069 reproduced the exit-code scorer failure, not the true effect.

### FINDINGS.md Update (2026-04-21)

Based on EVAL-069's identical-CI result, the document concludes:
> "The aggregate −10 to −16 pp signal... was a methodology artifact of the broken instrument, not a real behavioral effect of the neuromod module."

**But EVAL-069 itself exhibits the same methodology artifact.** The identical CIs are not evidence that EVAL-026 was wrong; they're evidence that EVAL-069 was run under the same broken scorer.

---

## The Credibility Crisis

### What Changed in FINDINGS.md

**Before EVAL-069 (2026-04-20):**
- F3: "Cross-architecture neuromod harm is concentrated in two task clusters (aggregate −10 to −16 pp)"
- Status: Confirmed by EVAL-029 task drilldown

**After EVAL-069 (2026-04-21):**
- F3: "Cross-architecture neuromod harm is concentrated in two task clusters" (aggregate signal **retired as methodology artifact**)
- Status: Task-cluster localization stands; aggregate magnitude retired

**The empirical record was revised on the basis of EVAL-069.** But if EVAL-069 used the same broken scorer as EVAL-026, then **the revision is based on two broken measurements canceling each other out, not on a true measurement disproving the prior claim.**

### Why This Matters

1. **Circular credibility:** EVAL-026 (broken scorer) → claim signal exists → EVAL-069 (broken scorer) → conclude signal is artifact. The two broken measurements don't validate each other; they're just repeating the same measurement error.

2. **Production impact:** The neuromod modules (`src/neuromodulation.rs`, `chump-neuromodulation` crate) remain in the binary. The decision to KEEP them (in CHUMP_FACULTY_MAP.md) is justified by "NULL findings from EVAL-063 and EVAL-069." If EVAL-069's NULL is an artifact, the decision to KEEP is based on one measurement (EVAL-063 on Llama-70B) not two.

3. **Publication risk:** PRODUCT-009 (blog post on F1-F6 findings) cites F3. If the aggregate signal was never properly measured (only broken scorers), the blog post's claim is unvalidated. RED_LETTER #4 flagged this: "Publishing F2 as a generalized finding while EVAL-071 is open means the headline result in the publication may be Anthropic-family-specific."

---

## Timeline of Fixes & Gaps

| Date | Gap | What Happened |
|------|-----|---|
| ~2026-04-18 | EVAL-026 | Neuromod harm signal measured under exit-code scorer (broken, per later EVAL-060) |
| 2026-04-20 | EVAL-060 | Instrument calibration reveals exit-code scorer produces 27–29/30 empty outputs |
| 2026-04-20 | EVAL-069 filed | Gap created: "Reopen EVAL-026 aggregate under EVAL-060 fixed instrument" |
| 2026-04-20 (discovered) | python3 foot-gun | Documented in RESEARCH_INTEGRITY.md: python3=3.14 has no anthropic module |
| 2026-04-21 | EVAL-069 closed | Result: delta=0.000, identical CIs. Conclusion: EVAL-026 signal is "methodology artifact" |
| 2026-04-21 | FINDINGS.md updated | F3 aggregate claim retired based on EVAL-069 |
| 2026-04-22 | INFRA-017 | Commit 8f3a994: Fix python3 shebangs to python3.12 in all harness scripts |
| 2026-04-22 | RESEARCH_INTEGRITY.md updated | Foot-gun documented; python3.12 mandated going forward |

**The gap:** EVAL-069 was closed and FINDINGS.md was updated on 2026-04-21, but the shebang fix didn't land until 2026-04-22. EVAL-069 was likely run before the fix.

---

## What Should Have Happened

1. **EVAL-060 finding** (exit-code scorer is broken) should trigger an immediate review: "Which prior sweeps used this scorer?"
2. **Answer:** EVAL-026 (and potentially others like EVAL-049–058, the binary-mode ablations).
3. **Action:** Before closing EVAL-069, verify the shebang is actually python3.12 and the run actually used the LLM judge.
4. **Verification:** Check the JSONL output for `"scorer": "llm-judge"` vs `"scorer": "exit_code_fallback"`.
5. **If found:** If EVAL-069 used exit-code fallback, don't update FINDINGS.md; re-run EVAL-069 with verified python3.12.

---

## What Actually Happened

EVAL-069 was closed and FINDINGS.md was updated without verifying the scorer used. The documentation says "Judge: Claude Haiku 4.5" but doesn't show the actual JSONL output `"scorer"` field. The identical CIs are a red flag that was not investigated.

---

## Audit Result

### Severity: HIGH

**The neuromod aggregate signal (−10 to −16 pp from EVAL-026) has never been properly measured under a working LLM judge.** Both attempts (EVAL-026 under broken exit-code, EVAL-069 likely under broken exit-code via python3 shebang) used broken scorers.

### Current State of Research Claims

| Claim | Evidence | Status | Risk |
|-------|----------|--------|------|
| Neuromod aggregate harm (−10 to −16 pp) | EVAL-026 (broken scorer) + EVAL-069 (likely broken scorer) | Retired | ⚠️ Never properly tested |
| Neuromod task-cluster localization (harm in 2 task clusters) | EVAL-029 (mechanism drilldown) | Confirmed | ✓ Low risk (mechanism analysis, not aggregate scoring) |
| F3 in FINDINGS.md and blog draft | Task-cluster (confirmed) + aggregate (retired/untested) | Mixed | ⚠️ Aggregate claim retired; task-cluster stands |

### Recommendation

**Do not publish F3 (or the blog post containing it) until EVAL-069 is re-run under verified python3.12 with confirmation that the JSONL output contains `"scorer": "llm-judge"` and not `"scorer": "exit_code_fallback"`.**

Steps:
1. Re-run EVAL-069 (identical parameters as document) with `python3.12 -c 'import anthropic; print("ok")'` verification beforehand
2. Extract the JSONL output and confirm `"scorer": "llm-judge"` on every row
3. If delta is still ~0.000 with identical CIs, investigate whether the judge is working correctly (run A/A baseline)
4. If delta is substantially different (e.g., delta ≠ 0), update FINDINGS.md with the corrected result
5. Update the blog draft (PRODUCT-009) only after EVAL-069 credibility is confirmed

---

## The Broader Pattern

This audit reveals a systemic vulnerability in the evaluation pipeline:

1. **Broken instruments (EVAL-060 finding) don't automatically trigger a review of prior measurements.**
2. **Shebang changes (python3 → python3.12) don't require a re-run of measurements that depend on the changed dependency.**
3. **Identical CIs (a statistical red flag for non-cognitive scorers) are not detected automatically.**

Going forward, RESEARCH_INTEGRITY.md should include:

- **Automated shebang validation:** Pre-run check that `python<version>` exists and has the anthropic module
- **JSONL output validation:** Confirm `"scorer"` field matches intended scorer before closing the gap
- **Footgun audit:** When an instrument is identified as broken, automatically search prior measurements for that pattern

---

## Conclusion

EVAL-069's result (identical CIs, delta=0.000) appears to be an artifact of running under the python3 shebang (which lacks the anthropic module) rather than a true measurement of the neuromod effect under LLM judge. **The neuromod aggregate signal has never been properly validated.** The task-cluster localization (EVAL-029) stands independently, but the aggregate magnitude claim should remain retired until EVAL-069 is re-run with verified tooling.
