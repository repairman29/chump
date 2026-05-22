-- INFRA-1665: Marcus M-D Phase 0 — shared vector-space schema (INFRA-1473 foundation).
--
-- Marcus quote (2026-05-15): "If Agent 3 discovers a hyper-specific quirk
-- about how our legacy database handles an indexing edge case, and that
-- context gets instantly committed to a shared team vector space, the
-- next guy on my team running a fleet doesn't have to suffer through
-- the same failure mode."
--
-- Tables:
--   1. nuggets       — discoveries (gotchas / patterns / dead-ends / failure modes)
--                      with vector embeddings for semantic similarity search
--   2. nugget_reads  — audit trail of which sessions read which nuggets
--
-- Pairs with: 0001_team_foundation.sql (teams + auth)
--             0002_shared_gaps.sql      (sibling INFRA-1475 schema)

-- ─── Extensions ────────────────────────────────────────────────────────────
-- pgvector for cosine-similarity search over text embeddings.
-- Supabase enables this for free; on vanilla Postgres run:
--   CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS vector;

-- ─── nuggets ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS nuggets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    -- which gap surfaced this nugget; null = free-floating discovery
    gap_id TEXT,
    -- which repo this applies to (multi-repo teams need scoping)
    repo_url TEXT NOT NULL,
    -- optional file-glob scope: "src/db/**" or "docs/**" etc.
    repo_path_glob TEXT,
    -- author attribution
    author_user_id UUID NOT NULL,
    author_session_id TEXT,
    author_machine TEXT,
    -- the actual content
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    -- 1536-dim embedding (matches OpenAI text-embedding-3-small + ada-002).
    -- Alternative models supported by changing this dimension:
    --   - text-embedding-3-large: 3072
    --   - sentence-transformers/all-MiniLM-L6-v2: 384
    -- We commit to 1536 for v1 to match the most common managed-API option.
    embedding vector(1536),
    -- categorization
    kind TEXT NOT NULL
        CHECK (kind IN (
            'gotcha',        -- 'X breaks when Y happens'
            'pattern',       -- 'use idiom Z for this case'
            'dead_end',      -- 'tried W; doesn''t work because...'
            'failure_mode',  -- 'system V fails this way when overloaded'
            'convention',    -- 'project uses U style for this'
            'other'
        )),
    -- author's self-rated confidence; affects ranking in retrieval
    confidence TEXT NOT NULL DEFAULT 'medium'
        CHECK (confidence IN ('low', 'medium', 'high')),
    -- INFRA-1473 AC #9: keeper-nuggets have indefinite retention; default
    -- non-keepers expire after 30 days.
    keeper BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- null for keepers; default NOW() + 30 days for non-keepers (computed
    -- in application code, not SQL — DEFAULT can't reference other cols)
    expires_at TIMESTAMPTZ,
    -- soft-delete; rows kept for audit
    deleted_at TIMESTAMPTZ,
    deleted_by_user_id UUID
);

CREATE INDEX IF NOT EXISTS nuggets_team_repo_idx ON nuggets (team_id, repo_url)
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS nuggets_team_kind_idx ON nuggets (team_id, kind)
    WHERE deleted_at IS NULL;

-- The similarity-search index. HNSW (hierarchical navigable small worlds)
-- is the modern default; trades a small amount of recall for fast queries.
-- Tune `m` (graph density) and `ef_construction` (build quality) per workload.
CREATE INDEX IF NOT EXISTS nuggets_embedding_idx
    ON nuggets
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

COMMENT ON TABLE nuggets IS
    'Cross-agent context discoveries with vector embeddings for similarity search.';

-- ─── nugget_reads ──────────────────────────────────────────────────────────
-- Audit: which session read which nugget, when. This is what INFRA-1473
-- AC #6 ("agent reports having read it before starting") joins against.
CREATE TABLE IF NOT EXISTS nugget_reads (
    nugget_id UUID NOT NULL REFERENCES nuggets(id) ON DELETE CASCADE,
    -- which team member's session read this
    user_id UUID NOT NULL,
    session_id TEXT NOT NULL,
    -- which gap the reader was working on when they read it
    gap_id TEXT,
    read_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- similarity score at retrieval time (0..1; cosine similarity)
    similarity NUMERIC(5, 4),
    PRIMARY KEY (nugget_id, session_id)
);

CREATE INDEX IF NOT EXISTS nugget_reads_user_idx ON nugget_reads (user_id, read_at DESC);

COMMENT ON TABLE nugget_reads IS
    'Read audit: which session retrieved which nugget. Joins prove cross-pollination.';

-- ─── Cleanup helper: expire stale nuggets ──────────────────────────────────
-- Application code runs this periodically; could also be a pg_cron job.
-- Soft-deletes nuggets where expires_at < NOW() AND keeper = FALSE.
CREATE OR REPLACE FUNCTION expire_stale_nuggets() RETURNS INT AS $$
DECLARE
    affected INT;
BEGIN
    UPDATE nuggets
    SET deleted_at = NOW()
    WHERE deleted_at IS NULL
      AND keeper = FALSE
      AND expires_at IS NOT NULL
      AND expires_at < NOW();
    GET DIAGNOSTICS affected = ROW_COUNT;
    RETURN affected;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER;

COMMENT ON FUNCTION expire_stale_nuggets() IS
    'Soft-deletes non-keeper nuggets past their expires_at. Run periodically.';

-- ─── Row-level security ────────────────────────────────────────────────────
ALTER TABLE nuggets ENABLE ROW LEVEL SECURITY;
ALTER TABLE nugget_reads ENABLE ROW LEVEL SECURITY;

CREATE POLICY "team_members_read_nuggets" ON nuggets
    FOR SELECT
    USING (
        deleted_at IS NULL
        AND team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid() AND removed_at IS NULL
        )
    );

CREATE POLICY "team_members_create_nuggets" ON nuggets
    FOR INSERT
    WITH CHECK (
        author_user_id = auth.uid()
        AND team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid()
              AND removed_at IS NULL
              AND role IN ('owner', 'admin', 'operator')
        )
    );

-- Update: only the author can edit their own nuggets (no role-based override
-- for now; admins delete-and-recreate if they need to fix something).
CREATE POLICY "authors_update_own_nuggets" ON nuggets
    FOR UPDATE
    USING (author_user_id = auth.uid())
    WITH CHECK (author_user_id = auth.uid());

CREATE POLICY "admins_delete_nuggets" ON nuggets
    FOR UPDATE
    USING (
        team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid()
              AND removed_at IS NULL
              AND role IN ('owner', 'admin')
        )
    );

CREATE POLICY "team_members_read_nugget_reads" ON nugget_reads
    FOR SELECT
    USING (
        nugget_id IN (
            SELECT id FROM nuggets
            WHERE team_id IN (
                SELECT team_id FROM team_members
                WHERE user_id = auth.uid() AND removed_at IS NULL
            )
        )
    );

CREATE POLICY "team_members_log_own_reads" ON nugget_reads
    FOR INSERT
    WITH CHECK (user_id = auth.uid());
