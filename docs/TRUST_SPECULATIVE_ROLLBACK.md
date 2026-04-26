---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Trust and Speculative Rollback

Public summary of what speculative execution can and cannot undo. See [ADR-001](ADR-001-transactional-tool-speculation.md) for the full design rationale.

## What rollback covers

Chump's speculative execution (`src/speculative_execution.rs`) runs a batch of ≥3 tool calls speculatively, then rolls back or commits based on surprisal EMA delta.

**Always rolled back on `rollback()`:**
- In-process belief state (`src/belief_state.rs`)
- Neuromodulation registers (serotonin, dopamine, norepinephrine, acetylcholine)
- Blackboard entries written during the batch
- Working memory / context updates

**Rolled back when `CHUMP_SANDBOX_SPECULATION=1` (git worktree sandbox):**
- Filesystem writes within the repo — the worktree is discarded
- `cli_tool` shell commands — redirected to a detached worktree at `.chump-spec-<millis>/`

## What rollback cannot undo

| Side effect | Can rollback? | Notes |
|-------------|--------------|-------|
| In-process belief state | ✓ Always | |
| Repo filesystem writes | ✓ With `CHUMP_SANDBOX_SPECULATION=1` | Git worktree sandbox |
| SQLite writes (episodes, tasks, memory) | ✗ | DB changes are durable |
| HTTP calls (web_search, read_url) | ✗ | Network effects are external |
| Discord / Slack messages sent | ✗ | Already delivered |
| `web_fetch` side effects | ✗ | POST forms, OAuth flows |
| `fleet_tool` peer messages | ✗ | Already delivered to peer |
| `notify` DMs | ✗ | Already delivered |
| Shell effects outside the worktree (e.g. `/tmp`, `~`) | ✗ | Outside sandbox scope |

## Diagram

```
Speculative batch starts
        │
        ▼
   fork() ──────────────────────────────────────────────┐
        │                                                │
        │  CHUMP_SANDBOX_SPECULATION=1                  │  (default: off)
        ▼                                                ▼
git worktree add --detach              in-process snapshot only
.chump-spec-<millis>/                  (beliefs, neuromod, blackboard)
        │                                                │
        ▼                                                ▼
   tools run in worktree               tools run in real env
        │
        ▼
   surprisal delta check
   ┌────┴──────────┐
commit()         rollback()
   │                   │
copy files          remove worktree
to real tree        restore state
```

## Gate

`CHUMP_SANDBOX_SPECULATION=1` enables the worktree sandbox. Off by default — worktree creation has I/O cost (~100ms) per batch.

For deployments where file-system safety matters (pilot, defense posture), enable it alongside:
- `CHUMP_SPECULATIVE_SURPRISE_DELTA_MAX=0.15` (tighter rollback threshold)
- `CHUMP_SPECULATIVE_BATCH=1` (explicit enable if you want to be sure it's on)

## See Also

- [ADR-001](ADR-001-transactional-tool-speculation.md) — full design decision
- [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) — WP-2 (sandboxed shell) + WP-4 (audit trail)
- [OPERATIONS.md](OPERATIONS.md) — `CHUMP_SANDBOX_SPECULATION`, `CHUMP_SPECULATIVE_BATCH` env vars
