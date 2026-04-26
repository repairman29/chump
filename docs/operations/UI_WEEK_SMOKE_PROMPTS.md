---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# UI Week Smoke Prompts

Fixed prompts for the weekly UI smoke test. Used in [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md) Scenario B (3-tool sequence) and [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md) scenarios 2–5.

## Prompt set A — Core tool coverage

These 6 prompts exercise the most important tool paths:

| ID | Prompt | Expected tools | Pass criteria |
|----|--------|---------------|---------------|
| S1 | "What are the open P1 gaps?" | `list_gaps` | Table of P1 gaps returned |
| S2 | "Show me the last 5 commits" | `run_shell` (`git log`) | Commit SHAs + messages |
| S3 | "What files changed in the last commit?" | `run_shell` (`git diff HEAD~1 --name-only`) | File list |
| S4 | "Read docs/README.md and summarize it" | `read_file` | Accurate summary |
| S5 | "Check if cargo compiles" | `run_shell` (`cargo check`) | Pass/fail with error details |
| S6 | "List my last 3 memories" | `recall_memory` | 3 memory entries |

## Prompt set B — Multi-tool sequence (3-tool chain)

For Scenario B in LATENCY_ENVELOPE.md:

> "Check if there are any open gaps related to evaluation, then read the EVAL section of the roadmap, then tell me which eval gap I should tackle next given the current status."

Expected tool sequence:
1. `list_gaps` (filter: prefix=EVAL, status=open)
2. `read_file` (docs/strategy/ROADMAP.md or ROADMAP_FULL.md)
3. LLM synthesis → recommendation

Pass: All 3 tools fire in order; recommendation is sensible and cites gap IDs.

## Prompt set C — Multi-turn coherence

Run these 3 prompts in sequence in the same session:

1. "What is the COG-016 directive?"
2. "What model tiers does it apply to?"
3. "Has it been validated at n=100?"

**Pass:** Response 3 builds on responses 1 and 2 without re-explaining; correct answer (yes, EVAL-025, p < 0.05).

## Running the smoke suite

```bash
# Automated (headless, no browser)
scripts/battle-qa.sh --fixture smoke-prompts --max 9

# Manual (in browser)
# Open http://localhost:5173 and paste prompts from set A + B
# Time each with a stopwatch; log in LATENCY_ENVELOPE.md
```

## See Also

- [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md) — latency targets and measurement
- [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md) — full 20-scenario matrix
- [CAPABILITY_CHECKLIST.md](CAPABILITY_CHECKLIST.md) — tier 1/2/3 capability checks
