-- Schema migration script for chump_memory.db
-- Adds performance indexes and optimizes queries
--
-- NOTE: state.db schema (gaps, leases, routing_outcomes) is managed inline
-- by GapStore::migrate() in crates/chump-gap-store/src/lib.rs — NOT here.
-- This file only applies to chump_memory.db (chump_tasks, chump_memory tables).
--
-- INFRA-1551 state.db dead-schema cull (2026-07-05):
--   DROPPED: intents table — never written in production; read_live_intents
--     in src/atomic_claim.rs reads intent_announced events from ambient.jsonl
--     directly. Migration added to GapStore::migrate() as DROP TABLE IF EXISTS.
--   REVERSAL: re-add CREATE TABLE IF NOT EXISTS intents(...) to create_schema()
--     and remove the DROP TABLE from migrate() in chump-gap-store/src/lib.rs.
--
--   KEPT: routing_outcomes table — INSERT is wired via
--     chump-orchestrator/src/monitor.rs::write_routing_outcome(), called from
--     MonitorLoop::watch_until_done(). Zero production rows because the
--     orchestrator monitor path is not yet the primary worker dispatch route,
--     not because the table is orphaned. COG-037 Thompson sampler reads from it.
--
--   KEPT: gaps.skills_required — 92 rows populated (external_repo:*, pwa,* tags);
--     actively used in external-repo routing (src/main.rs) and chump gap set CLI.
--
--   KEPT: gaps.preferred_backend / preferred_machine / estimated_minutes —
--     sparse (1 non-empty row each, value "any"/"any"/"180"); part of FLEET-034
--     NATS push-routing spec. Dropping requires GapRow struct + SQL + CLI refactor
--     (scope > s effort); deferred to a follow-up gap.

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