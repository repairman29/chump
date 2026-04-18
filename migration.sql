ALTER TABLE chump_tasks ADD COLUMN created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE chump_tasks ADD COLUMN updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE chump_memory ADD COLUMN created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE chump_memory ADD COLUMN updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
CREATE INDEX idx_chump_tasks_created_at ON chump_tasks (created_at);
CREATE INDEX idx_chump_tasks_updated_at ON chump_tasks (updated_at);
CREATE INDEX idx_chump_memory_created_at ON chump_memory (created_at);
CREATE INDEX idx_chump_memory_updated_at ON chump_memory (updated_at);
