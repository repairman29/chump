# RESEARCH-018 — Length-matched scaffolding-as-noise control

> **Status: NOT RUN — placeholder only.**  
> No JSONL has been committed for the preregistered primary matrix (n=100/cell × 3 cells × 2 tiers). Do **not** cite numbers from this page until a Lane B batch completes and this header is replaced with a **RUN COMPLETE** block.

## Preregistration

- **Prereg:** [`docs/eval/preregistered/RESEARCH-018.md`](./preregistered/RESEARCH-018.md)
- **Batch sheet (prep):** [`docs/eval/batches/2026-04-22-RESEARCH-018.md`](./batches/2026-04-22-RESEARCH-018.md)

## After data exists (fill in)

1. **Output paths:** `logs/ab-harness/<tag>/…` (JSONL + summaries)
2. **Primary:** H1 vs H0 per prereg §9 (correctness + hallucination deltas)
3. **Secondary:** per prereg §5–7 (judge breakdown, exclusions, tool metrics)
4. **FINDINGS:** add or update the “length-matched control” row in [`docs/FINDINGS.md`](../FINDINGS.md) with a link here
5. **Deviations:** append-only in the prereg doc if anything diverged from lock

## Pilot / smoke only (optional notes)

Use the batch sheet for **n≤5** pilots. Label any pilot JSONL **PRELIMINARY** and do not use pilot deltas for H1/H0 per prereg §6.
