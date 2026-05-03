---
doc_tag: ops
last_audited: 2026-05-02
---

# SOAK_72H_LOG.md — daily-driver soak runs

This file records 72h soak runs of the Chump stack. The unchecked
roadmap item "Overnight / 72h soak" in `docs/strategy/ROADMAP.md` (under
"Architecture vs proof") closes when at least one full 72h run completes
with no regressions in the metrics tracked below.

**Procedure:** see [`docs/operations/INFERENCE_STABILITY.md`](operations/INFERENCE_STABILITY.md) §Soak.

**Capture script:** [`scripts/eval/soak-checkpoint.sh`](../scripts/eval/soak-checkpoint.sh)

**Recommended cadence:** T0 (pre-flight) → +4h → +8h → ... → +72h (every 4h
or every hour for finer granularity; both work).

**Metrics tracked per checkpoint:**
- `memory_db` size + WAL behavior
- `logs/` and `sessions/` directory growth
- Model server reachability (`/api/health`, `/api/stack-status`)
- Chump process RSS
- Ship heartbeat status
- SQLite errors in last 500 log lines

**Pass criteria for closing the roadmap item:**
- `memory_db` does NOT grow unbounded (WAL checkpoint is happening)
- `logs/` size growth is sub-linear or rotated cleanly
- Model server reachable at >95% of checkpoints
- Chump RSS does not leak (steady-state ±20% over 72h)
- 0 unhandled SQLite errors


---

## Soak run: 2026-05-03T04:21:07Z (T0 — pre-flight)

| Check | Value |
|-------|-------|
| Time (UTC) | 2026-05-03T04:21:07Z |
| memory_db size | 1.0M |
| WAL | 3.9M |
| logs/ size | 203M |
| sessions/ size | 8.7M |
| Model server | web_ok |
| Chump RSS | 3.9M |
| Ship heartbeat | stopped |
| SQLite errors (last 500 lines) | 0 |

