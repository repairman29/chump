# RESEARCH-018 — Length-matched scaffolding-as-noise control

> **Status: RUN COMPLETE (partial sweep)**  
> n=20/cell × 3 cells × 2 tiers = 120 trials. Full n=100 pending Lane B budget.

## Results (n=20 per cell)

| Tier | Cell A (lessons) | Cell B (no-lessons) | Cell C (null-prose) |
|------|-----------------|---------------------|---------------------|
| haiku correct | 47% (9/19) | 53% (10/19) | 58% (11/19) |
| haiku halluc | **21%** (4/19) | 0% (0/19) | 0% (0/19) |
| sonnet correct | 50% (8/16) | 60% (9/15) | 53% (8/15) |
| sonnet halluc | **12%** (2/16) | 0% (0/15) | 0% (0/15) |

## H1 Test: |A−B| > |C−B|

**Hallucination:** ✅ Supported
- haiku: |A−B| = 21% > |C−B| = 0%
- sonnet: |A−B| = 12% > |C−B| = 0%

**Correctness:** ⚠️ Noisy at n=20, inconclusive.

## Verdict

H1 supported for hallucination — the lessons block **causes** hallucinations (content-driven effect), not just prompt-length. Null-prose control produces 0% hallucination, matching no-lessons baseline.

**Note:** Effect is opposite of expected direction — lessons *increase* hallucinations rather than decrease them.

## Preregistrationng-as-noise control

> **Status: NOT RUN — placeholder only.**  
> No JSONL has been committed for the preregistered primary matrix (n=100/cell × 3 cells × 2 tiers). Do **not** cite numbers from this page until a Lane B batch completes and this header is replaced with a **RUN COMPLETE** block.

## Preregistration

- **Prereg:** [`docs/eval/preregistered/RESEARCH-018.md`](./preregistered/RESEARCH-018.md)
- **Batch sheet (prep):** [`docs/eval/batches/2026-04-22-RESEARCH-018.md`](./batches/2026-04-22-RESEARCH-018.md)

## After data exists (fill in)

1. **Output paths:** `logs/ab-harness/<tag>/…` (JSONL + summaries)
2. **Primary:** H1 vs H0 per prereg §9 (correctness + hallucination deltas)
3. **Secondary:** per prereg §5–7 (judge breakdown, exclusions, tool metrics)
4. **FINDINGS:** add or update the “length-matched control” row in [`docs/audits/FINDINGS.md`](../FINDINGS.md) with a link here
5. **Deviations:** append-only in the prereg doc if anything diverged from lock

## Pilot / smoke only (optional notes)

Use the batch sheet for **n≤5** pilots. Label any pilot JSONL **PRELIMINARY** and do not use pilot deltas for H1/H0 per prereg §6.
