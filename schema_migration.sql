-- Schema migration script for chump_memory.db and .chump/state.db
-- Adds performance indexes and records destructive schema deltas.
--
-- NOTE: state.db migrations are applied automatically by GapStore::migrate()
-- in crates/chump-gap-store/src/lib.rs on every DB open. The deltas below
-- are the authoritative record; the Rust code is the execution path.

-- ─── state.db deltas (INFRA-1551) ────────────────────────────────────────────
-- Drop the `intents` table — schema corpse. src/atomic_claim.rs::read_live_intents
-- reads intent_announced events from ambient.jsonl (INFRA-1116); no INSERT path
-- ever wrote to this table.
--
-- Applied by: GapStore::migrate() — DROP TABLE IF EXISTS intents
-- REVERSAL: re-add CREATE TABLE intents(...) in GapStore initial execute_batch
--           and remove the DROP TABLE call in migrate().
--
-- DROP TABLE IF EXISTS intents;
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