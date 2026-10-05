-- chump-github-cache pr_state_write_log (INFRA-3833)
--
-- Append-only log of every pr_state upsert, tagged by which receiver
-- performed the write ('python' = scripts/ops/github-webhook-receiver.py,
-- 'rust' = chump-webhook-receiver / crate::webhook). Both receivers write
-- into the SAME `pr_state` row during the 14-day parallel-run validation
-- window (INFRA-2062 AC1), so the canonical table alone cannot answer
-- "did python and rust observe the same PR state" — only the most recent
-- writer's view survives there. This log preserves both views so
-- scripts/ops/github-cache-divergence-audit.sh can diff them per PR
-- number and flag real divergence (kind=cache_divergence_detected)
-- instead of the cutover being claimed on faith.
--
-- Idempotent so repeated `SqliteCache::open()` calls (and the Python
-- receiver's own `_ensure_schema`) are safe no-ops once created.

CREATE TABLE IF NOT EXISTS pr_state_write_log (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    number              INTEGER NOT NULL,
    source              TEXT NOT NULL,
    mergeable_state     TEXT,
    auto_merge_enabled  INTEGER NOT NULL DEFAULT 0,
    draft               INTEGER NOT NULL DEFAULT 0,
    title               TEXT,
    written_at          TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS pr_state_write_log_lookup
    ON pr_state_write_log(number, source, written_at);
