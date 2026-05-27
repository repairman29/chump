-- chump-github-cache initial schema (INFRA-1999 Phase 1)
--
-- Matches the schema produced by:
--   scripts/ops/github-webhook-receiver.py::_ensure_schema
--   scripts/coord/lib/github_cache.sh::_cache_fetch_and_store
--
-- Idempotent so the receiver + the bash shim can run side-by-side on the
-- same DB during the 1-week parallel-validation window.

CREATE TABLE IF NOT EXISTS pr_state (
    number              INTEGER PRIMARY KEY,
    head_ref            TEXT,
    head_sha            TEXT,
    base_ref            TEXT,
    base_sha            TEXT,
    mergeable_state     TEXT,
    auto_merge_enabled  INTEGER NOT NULL DEFAULT 0,
    draft               INTEGER NOT NULL DEFAULT 0,
    merged_at           TEXT,
    title               TEXT,
    user_login          TEXT,
    updated_at_api      TEXT NOT NULL,
    fetched_at_local    TEXT NOT NULL,
    raw_payload_json    TEXT,
    -- INFRA-1368: separately-stored merge_state_status column. The legacy
    -- Python receiver adds this via ALTER TABLE on the older base schema;
    -- new DBs created by this crate get it on first CREATE.
    merge_state_status  TEXT
);

CREATE INDEX IF NOT EXISTS pr_state_behind_armed
    ON pr_state(mergeable_state, auto_merge_enabled);

CREATE TABLE IF NOT EXISTS check_runs (
    head_sha          TEXT NOT NULL,
    name              TEXT NOT NULL,
    status            TEXT,
    conclusion        TEXT,
    started_at        TEXT,
    completed_at      TEXT,
    fetched_at_local  TEXT NOT NULL,
    PRIMARY KEY (head_sha, name)
);

CREATE INDEX IF NOT EXISTS check_runs_sha
    ON check_runs(head_sha);
