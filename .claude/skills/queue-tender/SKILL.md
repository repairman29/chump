---
name: queue-tender
description: Chump's merge-queue curator (curator-opus-queue-tender role) — run one queue-tend cycle that brings BEHIND open PRs up to date with the base branch. Thin wrapper over `scripts/coord/queue-tender-loop.sh`. Examples that should trigger this skill - "tend the queue", "update behind PRs", "queue tender heartbeat".
user-invocable: true
allowed-tools:
  - Bash
  - Read
  - Grep
---

# /queue-tender — merge-queue curator loop

Discipline lives in [`.claude/agents/curator-opus-queue-tender.md`](../../agents/curator-opus-queue-tender.md) and [`docs/process/QUEUE_TENDER_DOCTRINE.md`](../../../docs/process/QUEUE_TENDER_DOCTRINE.md).

Arguments passed: `$ARGUMENTS`.

## Routing

- Empty / `tick` → `scripts/coord/queue-tender-loop.sh tick`
- `heartbeat` → `scripts/coord/queue-tender-loop.sh heartbeat`
- `help` → `scripts/coord/queue-tender-loop.sh help`

```bash
scripts/coord/queue-tender-loop.sh ${ARGUMENTS:-tick}
```

Surface stdout directly. The loop is dry-run by default; set `CHUMP_QUEUE_TENDER_DRY_RUN=0` to act. Lane: update BEHIND branches only — never merge or bypass protection.
