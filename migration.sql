-- Database Migration Script
-- Adds timestamps and constraints for better data integrity

BEGIN TRANSACTION;

-- Remove duplicate indexes that were created in previous migration
DROP INDEX IF EXISTS idx_chump_memory_5created_at;

-- Update existing records to set timestamps if they're NULL
UPDATE chump_tasks SET created_at = datetime('now') WHERE created_at IS NULL;
UPDATE chump_tasks SET updated_at = datetime('now') WHERE updated_at IS NULL;
UPDATE chump_memory SET created_at = datetime('now') WHERE created_at IS NULL;
UPDATE chump_memory SET updated_at = datetime('now') WHERE updated_at IS NULL;

-- Set default values for status and memory_type where NULL
UPDATE chump_tasks SET status = 'open' WHERE status IS NULL;
UPDATE chump_memory SET memory_type = 'semantic_fact' WHERE memory_type IS NULL;

COMMIT;