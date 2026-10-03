-- EFFECTIVE-1508 (EFFECTIVE-365 slice): launch draft data model + persistence.
--
-- A launch draft is a piece of outbound copy (a post, announcement, or
-- update) staged for a specific publish platform before it ships. This is
-- the storage layer only — the authoring/approval pipeline is out of scope
-- here, see EFFECTIVE-365.
--
-- status lifecycle: 'draft' (default, being written) -> 'approved' (ready
-- to publish) -> 'published' (live on platform) or 'discarded'.
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
