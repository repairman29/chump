-- EFFECTIVE-1508 (EFFECTIVE-365 slice): persisted model for publisher launch drafts.
--
-- A launch draft is one per-platform outward-launch post (Show HN, Reddit,
-- LinkedIn, Substack, ...) staged for Jeff's explicit approval before send —
-- per PUBLISHER.md, the co-pilot drafts, it never auto-posts.
--
-- status lifecycle: 'draft' (default, awaiting review) -> 'approved' (Jeff
-- blessed it, ready to drive/hand-off) -> 'sent' (posted) -> 'rejected'
-- (Jeff declined it).
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
