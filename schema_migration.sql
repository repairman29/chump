-- Schema migration script for chump_memory.db
-- Adds performance indexes and optimizes queries

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

-- ── .chump/state.db schema culls (INFRA-1551) ─────────────────────────────
-- These DROP TABLE statements clean up dead schema from .chump/state.db.
-- Apply: sqlite3 .chump/state.db < schema_migration.sql
-- Reversal: re-apply the CREATE TABLE statements from the ensure_schema
--   delta in crates/chump-gap-store/src/lib.rs (git show HEAD~1:... | grep -A20 'routing_outcomes')

-- routing_outcomes: COG-036 scoreboard table — write path removed (monitor.rs),
-- read path removed (chump dispatch scoreboard CLI handler). COG-037 Thompson
-- sampler now uses empty-ArmStats fast path in dispatch.rs.
DROP TABLE IF EXISTS routing_outcomes;

-- intents: never written; src/atomic_claim.rs reads intent_announced events
-- from ambient.jsonl instead of this table.
DROP TABLE IF EXISTS intents;