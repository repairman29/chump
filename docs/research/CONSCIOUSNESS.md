---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Consciousness framework — summary and utility pass

Merged from: `CONSCIOUSNESS_UTILITY_PASS.md` + summary index for `CONSCIOUSNESS_AB_RESULTS.md`.
Source files archived after this lands (DOC-002 Phase 4).

> **METHODOLOGY STATUS — READ BEFORE CITING**
>
> All headline deltas in `CONSCIOUSNESS_AB_RESULTS.md` are **preliminary** — produced with
> Anthropic-only judges at n < 100/cell in several cases.
>
> **What is validated:** Instruction injection effects are tier-dependent. The lessons block
> helps haiku-4-5 on reflection fixtures (EVAL-025, n=100, cross-family judge) and backfires
> on sonnet-4-5 (EVAL-027c, n=100). All other deltas are preliminary until cross-family
> judge re-runs (EVAL-042 series) ship. See `docs/process/RESEARCH_INTEGRITY.md`.

---

## What "consciousness framework" means

The cognitive architecture enabled by `CHUMP_CONSCIOUSNESS_ENABLED` includes:
- **Surprisal EMA** — tracks task-complexity signal across turns
- **Belief state** — epistemic model updated per tool result
- **Neuromodulation** — adjusts exploration vs exploitation based on surprisal
- **Lesson injection** — prepends top-N lessons from `chump_improvement_targets` (tier-gated)

These modules are measured **as a bundle** in `CONSCIOUSNESS_AB_RESULTS.md`. Per-module ablation
is under [docs/audits/FINDINGS.md](FINDINGS.md) F3 (neuromod localization) and F4 (cross-judge agreement).

---

## Key findings to date

| Finding | Source | Confidence |
|---------|--------|-----------|
| Lessons block helps haiku-4-5 on reflection fixtures (+Δ, n=100, cross-family judge) | EVAL-025 | **Validated** |
| Lessons block backfires on sonnet-4-5 (−Δ, n=100) | EVAL-027c | **Validated** |
| Neuromod harm concentrated in dynamic + adaptive task classes | EVAL-029 | **Validated** (F3) |
| Bundle-level AB deltas across other fixture types | CONSCIOUSNESS_AB_RESULTS.md §2 | **Preliminary** |

COG-023 + COG-024 gates: lessons injection is **tier-dependent** and **off by default** post-COG-024.

---

## Utility pass procedure

Run the same scripted task mix with consciousness ON vs OFF and compare pass rate + latency:

```bash
# With consciousness enabled (default)
CHUMP_CONSCIOUSNESS_ENABLED=1 scripts/ci/battle-qa.sh --max 20 --log logs/study-ON-baseline.json

# With consciousness disabled
CHUMP_CONSCIOUSNESS_ENABLED=0 scripts/ci/battle-qa.sh --max 20 --log logs/study-OFF-baseline.json

# Compare
scripts/eval/analyze-ab-results.sh logs/study-ON-baseline.json logs/study-OFF-baseline.json
```

**Timing variant:**
```bash
CHUMP_CONSCIOUSNESS_ENABLED=1 CHUMP_LOG_TIMING=1 scripts/ci/battle-qa.sh --max 20 2>&1 | tee logs/study-ON-timings.jsonl
```

**What to measure:**

| Metric | Expected direction |
|--------|-------------------|
| Task pass rate | ON ≥ OFF for sonnet-tier models |
| Wall time per task | ON may be slower (belief updates) |
| Tool call count | ON should reduce fake/retry calls |
| Haiku fake-tool rate | ON expected worse (COG-016 finding) |

---

## AB Results index

`CONSCIOUSNESS_AB_RESULTS.md` (1972 lines, 108K chars) covers:
- §1 Methodology (hardware: M4 24GB, model: mlx-community/Qwen3.5-9B-OptiQ-4bit)
- §2 Results (key metrics, per-category breakdown, 28-prompt battery)
- Full data tables across 7 task categories (memory store, tool use, episodes, tasks, reasoning, graph density, edge cases)
- Methodology warnings: Anthropic-only judge + n<100 limitations

All result citation requires cross-family judge validation per `docs/process/RESEARCH_INTEGRITY.md`.

---

## Related docs

| Doc | Topic |
|-----|-------|
| [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) | Full AB data tables (108K chars) — preliminary |
| [FINDINGS.md](FINDINGS.md) | F1–F6 validated findings including F3 (neuromod) |
| [RESEARCH_INTEGRITY.md](RESEARCH_INTEGRITY.md) | Citation rules |
| [MISTRALRS.md](MISTRALRS.md) §Consciousness toggle | Inference × consciousness correlation |
| [METRICS.md](METRICS.md) | Metric definitions |
