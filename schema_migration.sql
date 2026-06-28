-- Schema migration script for chump_memory.db
-- Adds performance indexes and optimizes queries

-- ── state.db schema deltas (INFRA-1551, 2026-06-28) ─────────────────────────
-- Drop the intents table — it was schema'd but never written to; the live read
-- path (read_live_intents in atomic_claim.rs) reads ambient.jsonl instead.
-- Reversal: re-add CREATE TABLE IF NOT EXISTS intents(...) to GapStore::migrate()
--           in crates/chump-gap-store/src/lib.rs and remove the DROP below.
-- Applied by: GapStore::migrate() in crates/chump-gap-store/src/lib.rs
DROP TABLE IF EXISTS intents;
-- ─────────────────────────────────────────────────────────────────────────────

-- Index for faster task status lookups
CREATE INDEX IF NOT EXISTS idx_chump_tasks_status ON chump_tasks(status);

-- Index for expired memory cleanup
CREATE INDEX IF NOT EXISTS idx_chump_memory_expires_at ON chump_memory(expires_at);

-- Index for unverified memory filtering
CREATE INDEX IF NOT EXISTS idx_chump_memory_verified ON chump_memory(verified);

-- Index for task planner group lookups
CREATE INDEX IF NOT EXISTS idx_chump_tasks_planner_group ON chump_tasks(planner_group_id);

-- Index for task dependencies
CREATE INDEX IF NOT EXISTS idx_chump_tasks_depends_on ON chump_tasks(depends_on);

-- Index for memory type filtering
CREATE INDEX IF NOT EXISTS idx_chump_memory_memory_type ON chump_memory(memory_type);