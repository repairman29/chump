-- RESILIENT-059: durable_journal — SQLite-native activity journal for gap execution.
--
-- Each gap execution is a sequence of named activities (steps). An activity is
-- uniquely identified by (gap_id, run_id, step_name). Calling the same triple
-- returns the cached result — never re-executes. This is the Temporal/DBOS
-- durable-execution pattern, zero new infra (appends to existing state.db).
--
-- run_id is monotonically increasing per gap_id. A fresh run allocates
-- MAX(run_id)+1; resume finds the most recent run_id with incomplete steps.

CREATE TABLE IF NOT EXISTS durable_journal (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    gap_id           TEXT    NOT NULL,
    run_id           INTEGER NOT NULL,
    step_name        TEXT    NOT NULL,
    step_index       INTEGER NOT NULL,  -- monotonic per (gap_id, run_id)
    started_at       TEXT    NOT NULL,
    completed_at     TEXT,              -- NULL while in-flight; set on completion
    result_json      TEXT,              -- NULL while in-flight; JSON on completion
    attempt_count    INTEGER NOT NULL DEFAULT 1,
    UNIQUE (gap_id, run_id, step_name)
);

CREATE INDEX IF NOT EXISTS durable_journal_lookup
    ON durable_journal (gap_id, run_id, step_index);
