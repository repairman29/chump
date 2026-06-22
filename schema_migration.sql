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

-- ── state.db schema culls (INFRA-1551) ──────────────────────────────────────
-- Apply these against .chump/state.db to drop tables that were never written
-- in production. The CREATE TABLE IF NOT EXISTS lines in
-- crates/chump-gap-store/src/lib.rs have been removed so new DBs never get
-- these tables; run the DROP lines once on any existing DB to reclaim space.
--
-- Reversal: if routing_outcomes is re-introduced, re-add the CREATE TABLE
-- in lib.rs::migrate() and re-create the two indexes listed below.
--
--   DROP TABLE IF EXISTS routing_outcomes;  -- COG-036: scoreboard, zero INSERTs in prod
--   DROP TABLE IF EXISTS intents;           -- superseded by ambient.jsonl read in atomic_claim.rs