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

-- ── state.db delta (INFRA-1551, 2026-06-22) ────────────────────────────────
-- NOTE: this file applies to chump_memory.db; state.db migrations live in
-- crates/chump-gap-store/src/lib.rs::migrate(). This block documents the
-- state.db change for audit purposes only — it is NOT executed against state.db.
--
-- Dropped: intents table — schema'd but never written; atomic_claim.rs reads
-- intent_announced events from ambient.jsonl instead (read_live_intents()).
-- Reversal: re-add CREATE TABLE intents to the base schema in migrate() and
-- remove the DROP TABLE IF EXISTS intents migration step.
--
-- Kept: routing_outcomes — INSERT wired in crates/chump-orchestrator/src/monitor.rs
-- (write_routing_outcome); 0 rows because chump-orchestrator --watch is dormant
-- in current pull-mode fleet; COG-037 Thompson sampler will consume this.
--
-- Kept: gaps.skills_required — 92 gaps carry active values; FLEET-034 NATS
-- subject derivation reads it; chump gap set/reserve writes it.
--
-- Kept: gaps.preferred_backend, gaps.preferred_machine, gaps.estimated_minutes
-- — in GapRow struct and CLI args (INFRA-314); always-empty in practice but
-- removing requires touching every SELECT in gap_store (20+ column positions);
-- deferred to a dedicated refactor gap.
-- ── end state.db delta ──────────────────────────────────────────────────────