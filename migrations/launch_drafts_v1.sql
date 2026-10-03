-- EFFECTIVE-1508 (EFFECTIVE-365 slice): persisted model for launch drafts.
--
-- A launch draft is a per-platform post (HN / PH / LinkedIn / etc.) in the
-- draft -> approve -> drive -> track pipeline described by the publisher
-- co-pilot design (EFFECTIVE-365). This crate owns only the schema + a thin
-- CRUD surface; the drafting/approval pipeline itself is out of scope here.
--
-- status lifecycle: 'draft' (default) -> 'approved' -> 'posted' (or
-- 'discarded' if abandoned before posting).
CREATE TABLE IF NOT EXISTS launch_drafts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    platform   TEXT    NOT NULL,
    title      TEXT    NOT NULL,
    body       TEXT    NOT NULL,
    status     TEXT    NOT NULL DEFAULT 'draft',
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS launch_drafts_platform_idx
    ON launch_drafts (platform);

CREATE INDEX IF NOT EXISTS launch_drafts_status_idx
    ON launch_drafts (status);
