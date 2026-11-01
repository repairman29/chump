# RESILIENT-015 — close: already shipped

Scope (reconstructed from title): bot-merge.sh process lifecycle — no orphaned children, trackable health.

Already on main in `scripts/coord/bot-merge.sh`:
- `_bm_cleanup` (EXIT/TERM/INT traps) kills background helpers (`_BM_BUDGET_WARN_PID`, `_BM_HEALTH_PID`, `_BM_WATCHDOG_PID`, `__STAGE_BUDGET_PID`).
- `_bm_health_init` / `_bm_health_write` (INFRA-119, INFRA-1315): `.chump-locks/bot-merge-<pid>.health` with PID, step, `last_heartbeat_at`, gap ids.
- Budget watchdog emits `kind=bot_merge_hung` and SIGTERMs; the TERM handler emits `kind=bot_merge_timeout` (INFRA-2426).
- `scripts/coord/bot-merge-watchdog.sh` acts on stale/zombie health files.

Original AC was lost in an overwrite; no remaining unmet scope.
