---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Road Test Validation

Procedure for validating intent calibration in production-like conditions. "Road test" = running real user tasks (not fixtures) against a new build before treating it as stable.

Companion to [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md) and [CAPABILITY_CHECKLIST.md](CAPABILITY_CHECKLIST.md).

## What a road test covers

Unlike `battle-qa.sh` (scripted fixtures), a road test uses **real, open-ended tasks** sourced from:
- Jeff's actual work backlog (`brain/notes/pending.md`)
- Unresolved Discord messages
- Open P2/P3 gaps in `docs/gaps.yaml`

The goal is to catch regressions that scripted tests miss: off-topic responses, intent misclassification, subtle multi-turn failures.

## Procedure

### 1. Baseline snapshot

Before the build under test:

```bash
CHUMP_MODEL=claude-sonnet-4-7 \
  scripts/battle-qa.sh --max 10 --log logs/road-test-baseline.json
```

### 2. Real task session (30 min)

Run Chump on 5–10 real tasks. Log each with intent + outcome:

| Task | Intent classified | Actual outcome | Correct? |
|------|------------------|---------------|----------|
| "What's the status of EVAL-030?" | status_query | Correct gap status returned | ✓ |
| "Summarize yesterday's commits" | summarize | Correct summary | ✓ |
| "Fix the cargo fmt error" | code_change | PR opened | ✓ |

### 3. Intent calibration check

Compare against [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md) §Intent taxonomy. Each task should be classified into exactly one intent. Misclassifications are the main signal.

### 4. Acceptance criteria

| Criterion | Threshold |
|-----------|-----------|
| Battle QA pass rate | ≥ 85% |
| Intent classification accuracy | ≥ 90% on road test tasks |
| Zero tool call hallucinations | No fake tool calls in road test |
| No regression from baseline | Pass rate within ±5% |

## When to road test

- After any change to `src/prompt_assembler.rs`
- After any change to the COG-016 directive or lessons block
- After a model upgrade (new Claude version)
- Before a 72h soak run ([SOAK_72H_LOG.md](SOAK_72H_LOG.md))

## See Also

- [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md) — intent taxonomy and calibration data
- [CAPABILITY_CHECKLIST.md](CAPABILITY_CHECKLIST.md) — tier 1/2/3 capability checks
- [BATTLE_QA.md](BATTLE_QA.md) — scripted QA harness
