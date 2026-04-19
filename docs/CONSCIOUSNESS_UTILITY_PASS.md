# Consciousness Utility Pass

Procedure and log table for the scripted comparison of `CHUMP_CONSCIOUSNESS_ENABLED=1` vs `0`. This measures whether the cognitive architecture (surprisal, neuromodulation, belief state) helps or hurts on real tasks — not just eval fixtures.

Cross-links: [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) §8, [METRICS.md](METRICS.md).

## Procedure

Run the **same scripted task mix** twice — once with consciousness enabled, once disabled — and compare wall time, pass/fail, and optional baseline JSON.

```bash
# With consciousness enabled (default)
CHUMP_CONSCIOUSNESS_ENABLED=1 \
  scripts/battle-qa.sh --max 20 --log logs/study-ON-baseline.json

# With consciousness disabled
CHUMP_CONSCIOUSNESS_ENABLED=0 \
  scripts/battle-qa.sh --max 20 --log logs/study-OFF-baseline.json

# Compare
scripts/analyze-ab-results.sh logs/study-ON-baseline.json logs/study-OFF-baseline.json
```

**Timing variant** (captures per-round latency):

```bash
CHUMP_CONSCIOUSNESS_ENABLED=1 \
  CHUMP_LOG_TIMING=1 \
  scripts/battle-qa.sh --max 20 2>&1 | tee logs/study-ON-timings.jsonl
```

## What to measure

| Metric | How to capture | Expected direction |
|--------|---------------|-------------------|
| Task pass rate | `battle-qa.sh` pass/fail count | Consciousness ≥ OFF (if positive) |
| Wall time per task | Timing flag or `time` wrapper | ON may be slower (belief updates) |
| Tool call count | `chump_tool_health` ring buffer | ON should reduce fake/retry calls |
| Haiku fake-tool rate | `CHUMP_MODEL_TIER=haiku` subset | ON expected worse (COG-016 finding) |

## Log table

| Run | Date | Model | Consciousness | Pass rate | Wall time (avg) | Notes |
|-----|------|-------|---------------|-----------|-----------------|-------|
| Baseline | 2026-04-17 | sonnet-4-7 | ON | TBD | TBD | Pre-COG-016 directive |
| Post-directive | 2026-04-19 | sonnet-4-7 | ON | TBD | TBD | COG-016 directive active |

*Fill in from `battle-qa.sh` output and `logs/study-*.json`.*

## Findings to date

- **Haiku + consciousness = worse**: COG-016 finding confirms lessons block amplifies fake tool calls on haiku-class models. COG-016 directive (n=100 validated, EVAL-025) addresses this by gating injection by model tier.
- **Sonnet + consciousness**: net positive confirmed at n=100 in EVAL-025; carve-out in COG-023 preserves sonnet injection.
- **Quantitative utility pass**: pending — the procedure above hasn't been run as a standalone comparison yet. Candidate for EVAL-030 test plan.

## See Also

- [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) — full EVAL chain
- [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) §8 — inference × consciousness correlation
- [METRICS.md](METRICS.md) — metric definitions
- [BATTLE_QA.md](BATTLE_QA.md) — battle-qa.sh usage
