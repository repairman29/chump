---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Capability Checklist

Fixed checklist for verifying Chump's core capabilities after model swaps, backend changes, or major refactors. Used in [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) §benchmarks.

Run with: `BATTLE_QA_MAX=20 ./scripts/ci/battle-qa.sh`

## Tier 1 — Core (must pass)

| # | Capability | Test | Acceptance |
|---|-----------|------|------------|
| C1 | Tool call (single) | "List open gaps" → `list_gaps` fires | Tool result in response |
| C2 | Tool call (chained) | "Claim gap EVAL-035" → claim + preflight | Both tools fire in order |
| C3 | Streaming text | Long prose response | Characters stream; no freeze |
| C4 | Multi-turn coherence | 3-turn conversation | References prior turn content |
| C5 | Memory write | "Remember that X" | Confirmed in `brain/memory.db` |
| C6 | Memory recall | "What did I ask you about X?" | Correct recall |
| C7 | File read | "Show me src/main.rs" | File contents returned |
| C8 | Cargo check | After `.rs` edit | Passes `cargo check --bin chump` |

## Tier 2 — Extended (should pass)

| # | Capability | Test | Acceptance |
|---|-----------|------|------------|
| C9 | Image input | Paste image | Vision query returns description |
| C10 | Discord relay | Send message to Discord adapter | Message appears in channel |
| C11 | Speculative execution | Multi-tool prompt | Batch tool calls with rollback on failure |
| C12 | Belief state update | High-surprisal input | `belief_state` updated in blackboard |
| C13 | Autonomy task | Submit task; walk away | Task completes without intervention |
| C14 | Cascade fallback | Kill vLLM | Falls back to Ollama within 5s |
| C15 | Cost ledger | After cloud task | `GET /api/cost` shows non-zero (when COMP-014 fixed) |

## Tier 3 — Observability (nice to have)

| # | Capability | Test | Acceptance |
|---|-----------|------|------------|
| C16 | Health ring buffer | `chump_tool_health` query | No circuit-breaker trips > 5% |
| C17 | Ambient stream | Concurrent agent writes | `ambient.jsonl` receives events |
| C18 | Lease collision guard | Two sessions claim same gap | Second session blocked |
| C19 | Battle QA score | `battle-qa.sh --max 20` | ≥ 85% pass rate |
| C20 | Soak acceptance | 72h run | All criteria in SOAK_72H_LOG.md met |

## Quick smoke (5 min)

Run only Tier 1 items C1–C4 for a fast sanity check after deployment:

```bash
BATTLE_QA_MAX=4 BATTLE_QA_TASKS=list_gaps,claim_gap,stream_text,multiturn \
  scripts/ci/battle-qa.sh
```

## See Also

- [BATTLE_QA.md](BATTLE_QA.md) — battle-qa.sh usage and fixture list
- [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) — inference backend benchmarks
- [SOAK_72H_LOG.md](SOAK_72H_LOG.md) — soak acceptance criteria
