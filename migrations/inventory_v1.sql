-- META-271 / INFRA-2367: Fleet Inventory + Tech-Debt Audit DB — v1 schema.
--
-- Design contract (operator-mandated, REVIEW-ONLY mode):
--   * All detector findings land at tier=0 (surface-only). No gap-filing,
--     no removal, no auto-action in this PR's scope.
--   * Operator promotes a finding_class from tier 0 → 2 only after
--     calibration via `chump inventory review` + `chump inventory promote`.
--   * Tier-2 auto-file machinery is deferred to INFRA-2374.
--   * Tier-3 (auto-remove) is intentionally NOT defined — the orchestrator
--     (META-270) ships removal PRs through the normal review path.
--
-- All timestamps are Unix epoch seconds (INTEGER) for fast range queries.

-- ─── pr_index ────────────────────────────────────────────────────────────────
-- One row per PR ever opened against the fleet. Populated by
-- scripts/inventory/collect-prs.sh (REST/GraphQL) + cache_query_open_prs.
-- The inventory DB is rebuildable from scratch at any time, so we never
-- ON CONFLICT-fail — we upsert.
CREATE TABLE IF NOT EXISTS pr_index (
    pr_number INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    state TEXT NOT NULL,                       -- OPEN | CLOSED | MERGED
    head_ref TEXT,
    base_ref TEXT,
    author TEXT,
    created_at INTEGER NOT NULL,
    closed_at INTEGER,
    merged_at INTEGER,
    gap_id TEXT,                               -- extracted from title (e.g. INFRA-2367)
    domain TEXT,                               -- INFRA | META | CREDIBLE | ...
    files_changed INTEGER DEFAULT 0,
    additions INTEGER DEFAULT 0,
    deletions INTEGER DEFAULT 0,
    last_synced_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pr_index_state ON pr_index(state);
CREATE INDEX IF NOT EXISTS idx_pr_index_gap_id ON pr_index(gap_id);
CREATE INDEX IF NOT EXISTS idx_pr_index_domain ON pr_index(domain);
CREATE INDEX IF NOT EXISTS idx_pr_index_merged_at ON pr_index(merged_at);

-- ─── artifact_index ──────────────────────────────────────────────────────────
-- One row per artifact (file/script/Rust module/launchd plist/doc).
-- Class identifies the artifact kind; activation_state describes how
-- (and whether) it is referenced from anywhere else in the fleet.
CREATE TABLE IF NOT EXISTS artifact_index (
    artifact_id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL UNIQUE,                 -- relative to repo root
    class TEXT NOT NULL,                       -- rust-mod | shell-script | plist | doc | yaml | other
    size_bytes INTEGER NOT NULL DEFAULT 0,
    first_seen_at INTEGER NOT NULL,            -- earliest git commit touching this path
    last_modified_at INTEGER NOT NULL,         -- most recent git commit touching this path
    activation_state TEXT NOT NULL,            -- referenced | dormant | orphan | unknown
    reference_count INTEGER NOT NULL DEFAULT 0,
    referenced_from TEXT,                      -- JSON array of paths that grep-match this artifact
    introducing_pr INTEGER,                    -- pr_index.pr_number that first added it
    introducing_gap TEXT,                      -- gap ID extracted from the introducing PR title
    notes TEXT,
    last_synced_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_artifact_class ON artifact_index(class);
CREATE INDEX IF NOT EXISTS idx_artifact_activation ON artifact_index(activation_state);
CREATE INDEX IF NOT EXISTS idx_artifact_intro_gap ON artifact_index(introducing_gap);

-- ─── tech_debt_findings ──────────────────────────────────────────────────────
-- One row per detector finding. tier=0 (surface-only) is the only
-- value any detector writes in this PR's scope. operator_classification
-- and operator_reviewed_at are populated by `chump inventory review`.
-- auto_fix_filed_gap_id is NULL on every row written by this PR — it
-- becomes populated only after INFRA-2374 wires tier-2 auto-file machinery.
CREATE TABLE IF NOT EXISTS tech_debt_findings (
    finding_id INTEGER PRIMARY KEY AUTOINCREMENT,
    finding_class TEXT NOT NULL,               -- one of the 9 detector class names
    severity TEXT NOT NULL,                    -- info | low | med | high
    artifact_path TEXT,                        -- nullable for class-wide findings
    pr_number INTEGER,                         -- nullable: some findings are repo-wide
    gap_id TEXT,                               -- nullable: some findings are gap-less
    detail TEXT NOT NULL,                      -- human-readable one-liner
    evidence TEXT,                             -- JSON blob of supporting refs
    detected_at INTEGER NOT NULL,
    -- Review-tier model (META-271 / operator-mandate 2026-05-31):
    tier INTEGER NOT NULL DEFAULT 0,           -- 0 = surface-only (default); 1 = review-pending; 2 = auto-file enabled (per-class promotion)
    operator_classification TEXT,              -- NULL | REAL_POSITIVE | FALSE_POSITIVE | NEEDS_INVESTIGATION
    operator_reviewed_at INTEGER,
    operator_note TEXT,
    -- Reserved for INFRA-2374 (tier-2 auto-file). Always NULL in this PR.
    auto_fix_filed_gap_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_finding_class ON tech_debt_findings(finding_class);
CREATE INDEX IF NOT EXISTS idx_finding_tier ON tech_debt_findings(tier);
CREATE INDEX IF NOT EXISTS idx_finding_classification ON tech_debt_findings(operator_classification);
CREATE INDEX IF NOT EXISTS idx_finding_detected ON tech_debt_findings(detected_at);

-- ─── finding_class_tiers ─────────────────────────────────────────────────────
-- Per-detector current tier. Defaults to 0 (surface-only). Operator runs
-- `chump inventory promote <class>` after ≥10 reviewed findings + ≥70%
-- REAL_POSITIVE ratio to elevate to tier=2. Demote escape hatch always
-- writes tier=0.
CREATE TABLE IF NOT EXISTS finding_class_tiers (
    finding_class TEXT PRIMARY KEY,
    current_tier INTEGER NOT NULL DEFAULT 0,
    promoted_at INTEGER,
    promoted_by TEXT,
    demoted_at INTEGER,
    demoted_by TEXT,
    reviewed_count INTEGER NOT NULL DEFAULT 0,
    real_positive_count INTEGER NOT NULL DEFAULT 0
);

-- Seed the 9 detector classes at tier=0 (review-only).
INSERT OR IGNORE INTO finding_class_tiers (finding_class, current_tier) VALUES
    ('orphan-artifact',            0),  -- artifact has zero inbound references in the repo
    ('dormant-script',             0),  -- shell script not invoked from any other script/plist/Rust/docs
    ('dead-rust-mod',              0),  -- Rust module compiled but not pub-used from any reachable binary
    ('stale-plist',                0),  -- launchd plist whose target binary does not exist
    ('doc-only-feature',           0),  -- gap shipped a doc but no code change touched the named subsystem
    ('unreferenced-gap',           0),  -- gap shipped >30d ago but artifacts it produced are orphans
    ('long-undormant-substrate',   0),  -- substrate PR merged >90d but no inbound reference growth
    ('shadow-duplicate',           0),  -- two artifacts implement near-identical shell of a primitive (META-063 sibling)
    ('event-kind-zero-emit',       0);  -- EVENT_REGISTRY kind has zero ambient occurrences in 30d

-- ─── inventory_meta ──────────────────────────────────────────────────────────
-- Single-row table tracking the last rebuild + schema version.
CREATE TABLE IF NOT EXISTS inventory_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT OR IGNORE INTO inventory_meta (key, value) VALUES
    ('schema_version', '1'),
    ('last_rebuild_at', '0'),
    ('last_rebuild_pr_count', '0'),
    ('last_rebuild_artifact_count', '0');
