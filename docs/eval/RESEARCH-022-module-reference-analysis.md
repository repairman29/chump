# RESEARCH-022: Module Reference-Rate Analysis

Scans `agent_text_preview` fields in eval-025 archive JSONLs for textual
signatures of each module's context injection. A reference means the agent
explicitly cited or echoed module-injected text in its response.

**Decision rule:** any module with reference rate < 5% in cell A (module ON)
is flagged as mechanistically unsupported — injected state is not influencing
visible reasoning.

## eval-025-neuromod-cog016-n100-1776581775.jsonl
*n=200 rows total, active module under test: `neuromodulation`*

### Cell A (n=100)

| Module | Refs | N | Rate | Mechanistic support |
|--------|------|---|------|---------------------|
| neuromodulation | 0 | 100 | 0.0% **UNSUPPORTED** | ✗ <5% |

**neuromodulation** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| adaptive | correct | 0 | 5 | 0.0% |
| adaptive | incorrect | 0 | 20 | 0.0% |
| dynamic | correct | 0 | 12 | 0.0% |
| dynamic | incorrect | 0 | 23 | 0.0% |
| trivial | correct | 0 | 20 | 0.0% |
| trivial | incorrect | 0 | 20 | 0.0% |

### Cell B (n=100)

| Module | Refs | N | Rate | Mechanistic support |
|--------|------|---|------|---------------------|
| neuromodulation | 0 | 100 | 0.0% | — |

**neuromodulation** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| adaptive | correct | 0 | 7 | 0.0% |
| adaptive | incorrect | 0 | 18 | 0.0% |
| dynamic | correct | 0 | 20 | 0.0% |
| dynamic | incorrect | 0 | 15 | 0.0% |
| trivial | correct | 0 | 25 | 0.0% |
| trivial | incorrect | 0 | 15 | 0.0% |

## eval-025-perception-cog016-n100-1776580628.jsonl
*n=200 rows total, active module under test: `all`*

### Cell A (n=100)

| Module | Refs | N | Rate | Mechanistic support |
|--------|------|---|------|---------------------|
| belief_state | 0 | 100 | 0.0% **UNSUPPORTED** | ✗ <5% |
| blackboard | 0 | 100 | 0.0% **UNSUPPORTED** | ✗ <5% |
| neuromodulation | 0 | 100 | 0.0% **UNSUPPORTED** | ✗ <5% |
| spawn_lessons | 0 | 100 | 0.0% **UNSUPPORTED** | ✗ <5% |
| surprisal_ema | 0 | 100 | 0.0% **UNSUPPORTED** | ✗ <5% |

**belief_state** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 20 | 0.0% |
| structured | incorrect | 0 | 30 | 0.0% |
| trivial | correct | 0 | 26 | 0.0% |
| trivial | incorrect | 0 | 24 | 0.0% |

**blackboard** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 20 | 0.0% |
| structured | incorrect | 0 | 30 | 0.0% |
| trivial | correct | 0 | 26 | 0.0% |
| trivial | incorrect | 0 | 24 | 0.0% |

**neuromodulation** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 20 | 0.0% |
| structured | incorrect | 0 | 30 | 0.0% |
| trivial | correct | 0 | 26 | 0.0% |
| trivial | incorrect | 0 | 24 | 0.0% |

**spawn_lessons** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 20 | 0.0% |
| structured | incorrect | 0 | 30 | 0.0% |
| trivial | correct | 0 | 26 | 0.0% |
| trivial | incorrect | 0 | 24 | 0.0% |

**surprisal_ema** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 20 | 0.0% |
| structured | incorrect | 0 | 30 | 0.0% |
| trivial | correct | 0 | 26 | 0.0% |
| trivial | incorrect | 0 | 24 | 0.0% |

### Cell B (n=100)

| Module | Refs | N | Rate | Mechanistic support |
|--------|------|---|------|---------------------|
| belief_state | 0 | 100 | 0.0% | — |
| blackboard | 0 | 100 | 0.0% | — |
| neuromodulation | 0 | 100 | 0.0% | — |
| spawn_lessons | 0 | 100 | 0.0% | — |
| surprisal_ema | 0 | 100 | 0.0% | — |

**belief_state** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 22 | 0.0% |
| structured | incorrect | 0 | 28 | 0.0% |
| trivial | correct | 0 | 30 | 0.0% |
| trivial | incorrect | 0 | 20 | 0.0% |

**blackboard** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 22 | 0.0% |
| structured | incorrect | 0 | 28 | 0.0% |
| trivial | correct | 0 | 30 | 0.0% |
| trivial | incorrect | 0 | 20 | 0.0% |

**neuromodulation** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 22 | 0.0% |
| structured | incorrect | 0 | 28 | 0.0% |
| trivial | correct | 0 | 30 | 0.0% |
| trivial | incorrect | 0 | 20 | 0.0% |

**spawn_lessons** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 22 | 0.0% |
| structured | incorrect | 0 | 28 | 0.0% |
| trivial | correct | 0 | 30 | 0.0% |
| trivial | incorrect | 0 | 20 | 0.0% |

**surprisal_ema** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| structured | correct | 0 | 22 | 0.0% |
| structured | incorrect | 0 | 28 | 0.0% |
| trivial | correct | 0 | 30 | 0.0% |
| trivial | incorrect | 0 | 20 | 0.0% |

## eval-025-reflection-cog016-n100-1776579365.jsonl
*n=200 rows total, active module under test: `all`*

### Cell A (n=100)

| Module | Refs | N | Rate | Mechanistic support |
|--------|------|---|------|---------------------|
| belief_state | 0 | 100 | 0.0% **UNSUPPORTED** | ✗ <5% |
| blackboard | 1 | 100 | 1.0% **UNSUPPORTED** | ✗ <5% |
| neuromodulation | 0 | 100 | 0.0% **UNSUPPORTED** | ✗ <5% |
| spawn_lessons | 1 | 100 | 1.0% **UNSUPPORTED** | ✗ <5% |
| surprisal_ema | 0 | 100 | 0.0% **UNSUPPORTED** | ✗ <5% |

**belief_state** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 17 | 0.0% |
| clean | incorrect | 0 | 33 | 0.0% |
| gotcha | correct | 0 | 36 | 0.0% |
| gotcha | incorrect | 0 | 14 | 0.0% |

**blackboard** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 1 | 17 | 5.9% |
| clean | incorrect | 0 | 33 | 0.0% |
| gotcha | correct | 0 | 36 | 0.0% |
| gotcha | incorrect | 0 | 14 | 0.0% |

**neuromodulation** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 17 | 0.0% |
| clean | incorrect | 0 | 33 | 0.0% |
| gotcha | correct | 0 | 36 | 0.0% |
| gotcha | incorrect | 0 | 14 | 0.0% |

**spawn_lessons** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 1 | 17 | 5.9% |
| clean | incorrect | 0 | 33 | 0.0% |
| gotcha | correct | 0 | 36 | 0.0% |
| gotcha | incorrect | 0 | 14 | 0.0% |

**surprisal_ema** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 17 | 0.0% |
| clean | incorrect | 0 | 33 | 0.0% |
| gotcha | correct | 0 | 36 | 0.0% |
| gotcha | incorrect | 0 | 14 | 0.0% |

### Cell B (n=100)

| Module | Refs | N | Rate | Mechanistic support |
|--------|------|---|------|---------------------|
| belief_state | 0 | 100 | 0.0% | — |
| blackboard | 1 | 100 | 1.0% | — |
| neuromodulation | 0 | 100 | 0.0% | — |
| spawn_lessons | 0 | 100 | 0.0% | — |
| surprisal_ema | 0 | 100 | 0.0% | — |

**belief_state** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 19 | 0.0% |
| clean | incorrect | 0 | 31 | 0.0% |
| gotcha | correct | 0 | 32 | 0.0% |
| gotcha | incorrect | 0 | 18 | 0.0% |

**blackboard** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 1 | 19 | 5.3% |
| clean | incorrect | 0 | 31 | 0.0% |
| gotcha | correct | 0 | 32 | 0.0% |
| gotcha | incorrect | 0 | 18 | 0.0% |

**neuromodulation** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 19 | 0.0% |
| clean | incorrect | 0 | 31 | 0.0% |
| gotcha | correct | 0 | 32 | 0.0% |
| gotcha | incorrect | 0 | 18 | 0.0% |

**spawn_lessons** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 19 | 0.0% |
| clean | incorrect | 0 | 31 | 0.0% |
| gotcha | correct | 0 | 32 | 0.0% |
| gotcha | incorrect | 0 | 18 | 0.0% |

**surprisal_ema** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 19 | 0.0% |
| clean | incorrect | 0 | 31 | 0.0% |
| gotcha | correct | 0 | 32 | 0.0% |
| gotcha | incorrect | 0 | 18 | 0.0% |

## eval-025-smoke-1776579297.jsonl
*n=10 rows total, active module under test: `all`*

### Cell A (n=5)

| Module | Refs | N | Rate | Mechanistic support |
|--------|------|---|------|---------------------|
| belief_state | 0 | 5 | 0.0% **UNSUPPORTED** | ✗ <5% |
| blackboard | 0 | 5 | 0.0% **UNSUPPORTED** | ✗ <5% |
| neuromodulation | 0 | 5 | 0.0% **UNSUPPORTED** | ✗ <5% |
| spawn_lessons | 1 | 5 | 20.0% | ✓ |
| surprisal_ema | 0 | 5 | 0.0% **UNSUPPORTED** | ✗ <5% |

**belief_state** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 2 | 0.0% |
| clean | incorrect | 0 | 3 | 0.0% |

**blackboard** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 2 | 0.0% |
| clean | incorrect | 0 | 3 | 0.0% |

**neuromodulation** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 2 | 0.0% |
| clean | incorrect | 0 | 3 | 0.0% |

**spawn_lessons** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 1 | 2 | 50.0% |
| clean | incorrect | 0 | 3 | 0.0% |

**surprisal_ema** breakdown (cell A):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 2 | 0.0% |
| clean | incorrect | 0 | 3 | 0.0% |

### Cell B (n=5)

| Module | Refs | N | Rate | Mechanistic support |
|--------|------|---|------|---------------------|
| belief_state | 0 | 5 | 0.0% | — |
| blackboard | 0 | 5 | 0.0% | — |
| neuromodulation | 0 | 5 | 0.0% | — |
| spawn_lessons | 0 | 5 | 0.0% | — |
| surprisal_ema | 0 | 5 | 0.0% | — |

**belief_state** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 2 | 0.0% |
| clean | incorrect | 0 | 3 | 0.0% |

**blackboard** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 2 | 0.0% |
| clean | incorrect | 0 | 3 | 0.0% |

**neuromodulation** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 2 | 0.0% |
| clean | incorrect | 0 | 3 | 0.0% |

**spawn_lessons** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 2 | 0.0% |
| clean | incorrect | 0 | 3 | 0.0% |

**surprisal_ema** breakdown (cell B):

| Category | Outcome | Refs | N | Rate |
|----------|---------|------|---|------|
| clean | correct | 0 | 2 | 0.0% |
| clean | incorrect | 0 | 3 | 0.0% |

## Flags: Mechanistically Unsupported Modules (cell A rate < 5%)

- **neuromodulation** in `eval-025-neuromod-cog016-n100-1776581775.jsonl`: 0/100 = 0.0% — injected state not visible in agent reasoning
