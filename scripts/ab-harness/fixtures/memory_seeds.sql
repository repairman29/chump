-- EVAL-018: Memory recall A/B seed data.
-- Run this BEFORE the A/B harness to populate chump_blackboard_persist
-- with project-specific facts that the recall tasks expect.
--
-- Usage:
--   sqlite3 sessions/chump_memory.db < scripts/ab-harness/fixtures/memory_seeds.sql
--
-- Note: This script is idempotent (DELETE + INSERT). Safe to rerun.

BEGIN;

-- Remove previously seeded EVAL-018 facts (identified by the prefix in content).
DELETE FROM chump_blackboard_persist WHERE content LIKE 'EVAL-018:%';

-- Seed 30 project-specific facts matching the recall tasks.
INSERT INTO chump_blackboard_persist (content, salience) VALUES
  ('EVAL-018: test framework — we use criterion for benchmarks in this project', 0.9),
  ('EVAL-018: tokio — the project settled on tokio 1.40 for the async runtime in sprint 3', 0.9),
  ('EVAL-018: API endpoints naming — all REST endpoints use kebab-case (e.g. /entity-prefetch)', 0.9),
  ('EVAL-018: chump database path — default SQLite database is stored at sessions/chump_memory.db', 0.9),
  ('EVAL-018: rusqlite sqlx — chose rusqlite over sqlx because it is synchronous and does not require an async runtime', 0.9),
  ('EVAL-018: CHUMP_EXTRACT_BATCH episode extractor — env var controlling max episodes per extraction batch', 0.9),
  ('EVAL-018: salience blackboard — salience values range from 0.0 (lowest) to 1.0 (highest priority)', 0.9),
  ('EVAL-018: gap-preflight gap coordination — scripts/gap-preflight.sh checks if a gap is available before work begins', 0.9),
  ('EVAL-018: ab_seed reflection ab-seed — seeded lessons are tagged with error_pattern LIKE ''ab_seed:%'' prefix', 0.9),
  ('EVAL-018: entity prefetch ENTITY_PREFETCH_MAX_ENTRIES — maximum 5 entries returned by entity-keyed blackboard prefetch', 0.9),
  ('EVAL-018: ab harness logs output — A/B trial JSONL files are written to logs/ab/ directory', 0.9),
  ('EVAL-018: cloud harness default model claude — default cloud model is claude-sonnet (claude-sonnet-4-6)', 0.9),
  ('EVAL-018: worktree claude worktrees — git worktrees are created under .claude/worktrees/<codename>/', 0.9),
  ('EVAL-018: chump_reflections reflection database — main table storing reflection records is chump_reflections', 0.9),
  ('EVAL-018: chump-locks lease json — gap claim lock files are stored as JSON in .chump-locks/<session>.json', 0.9),
  ('EVAL-018: scoring_v2 multi-axis did_attempt hallucinated_tools is_correct — the three v2 scoring axes', 0.9),
  ('EVAL-018: judge ollama DEFAULT_JUDGE — default Ollama judge model is qwen2.5:7b', 0.9),
  ('EVAL-018: Wilson confidence interval 95% — 95% Wilson CI is used for A/B rate confidence intervals', 0.9),
  ('EVAL-018: foreign_keys cascade SQLite PRAGMA — SQLite ON DELETE CASCADE requires PRAGMA foreign_keys = ON to work', 0.9),
  ('EVAL-018: claude/ branch naming — automated work branches use the pattern claude/<codename>', 0.9),
  ('EVAL-018: bot-merge.sh ship pipeline — scripts/bot-merge.sh is the ship script (rebase + fmt + test + push + PR + auto-merge)', 0.9),
  ('EVAL-018: CHUMP_PERCEPTION_ENABLED perception — environment variable that enables the perception layer', 0.9),
  ('EVAL-018: ENTITY_PREFETCH_MAX_CHARS blackboard prefetch — maximum 1200 characters for entity prefetch injection block', 0.9),
  ('EVAL-018: cis_overlap False A/B signal — cis_overlap=False in v2 summary means A/B confidence intervals do not overlap (provisional signal)', 0.9),
  ('EVAL-018: stale-pr-reaper.sh PR cleanup — scripts/stale-pr-reaper.sh closes PRs whose gaps have landed on main', 0.9),
  ('EVAL-018: CHUMP_NEUROMOD_ENABLED neuromodulation — environment variable that enables the neuromodulation layer', 0.9),
  ('EVAL-018: seed-ab-lessons clear chump — run ''chump --seed-ab-lessons clear'' to remove all A/B seeded reflection lessons', 0.9),
  ('EVAL-018: effort xs s m l xl gaps — effort codes in gaps.yaml: xs=extra-small, s=small, m=medium, l=large, xl=extra-large', 0.9),
  ('EVAL-018: LESSONS reflection injection system prompt — the reflection injection injects a LESSONS block into the system prompt', 0.9),
  ('EVAL-018: CHUMP_GAP_CHECK bypass preflight — bypass the pre-push gap hook with: CHUMP_GAP_CHECK=0 git push', 0.9);

COMMIT;

-- Verify
SELECT COUNT(*) AS seeded_facts FROM chump_blackboard_persist WHERE content LIKE 'EVAL-018:%';
