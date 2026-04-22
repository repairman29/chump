# RESEARCH-021 — Tier-dependence across 4 model families (NOT RUN — prep only)

This document is a **prep stub** for RESEARCH-021. It is intentionally labeled
**NOT RUN** until at least one real JSONL exists for this gap.

Preregistration: `docs/eval/preregistered/RESEARCH-021.md`

## Families × tiers × cells

Fixture: `scripts/ab-harness/fixtures/reflection_tasks.json`

Cells (per family × tier):
- **A**: lessons ON (`--lessons-version cog016`)
- **B**: lessons OFF (`--lessons-version none`)

| Family | Provider | Small tier (~8B) | Large tier (~70B+) |
|---|---|---|---|
| Anthropic | Anthropic API | `claude-haiku-4-5` | `claude-sonnet-4-5` |
| Meta | Together | `Llama-3.3-8B-Instruct` | `meta-llama/Llama-3.3-70B-Instruct-Turbo` |
| Alibaba | Together | `Qwen-2.5-7B-Instruct` | `Qwen-2.5-72B-Instruct` |
| DeepSeek | Together / DeepSeek API | `DeepSeek-V3-small` | `DeepSeek-V3` |

## Judge panel (preregistered)

Panel: `{claude-sonnet-4-5, Llama-3.3-70B-Instruct-Turbo, Qwen-2.5-72B-Instruct}`.

Rule: exclude the same-family judge for each trial; when only two judges remain,
use conservative tie-break (= fail).

