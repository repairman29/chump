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

-- INFRA-1551 (2026-07-05): dead table culls for .chump/state.db
-- Canonical schema is managed in crates/chump-gap-store/src/lib.rs::migrate().
-- These DROP statements are applied there via execute_batch in the migration block.
-- Reversal (re-add both tables):
--   intents: re-add CREATE TABLE IF NOT EXISTS intents (ts INTEGER NOT NULL,
--     session_id TEXT NOT NULL, gap_id TEXT NOT NULL, files TEXT NOT NULL DEFAULT '')
--     before the DROP TABLE lines in migrate() and remove the DROP.
--   routing_outcomes: re-add COG-036 CREATE TABLE block (see git history) and
--     restore RoutingOutcomeRow / ScoreboardEntry / record_routing_outcome /
--     routing_scoreboard from chump-gap-store and dispatch scoreboard handler
--     from src/main.rs.
DROP TABLE IF EXISTS routing_outcomes;  -- applied by migrate(); audit trail only here
DROP TABLE IF EXISTS intents;           -- applied by migrate(); audit trail only here