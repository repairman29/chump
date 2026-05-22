-- INFRA-1473: Marcus M-D Phase 2 — vector-similarity search RPC.
--
-- Phase 0 (INFRA-1665) shipped the nuggets table with a pgvector(1536) column
-- and an HNSW index. This migration ships the function the Rust client calls:
-- `search_nuggets(...)` does the cosine-similarity ranking server-side with
-- RLS still in effect (SECURITY INVOKER, not DEFINER).
--
-- The Rust client (chump-team::nuggets::search_nuggets) embeds the query text
-- via OpenAI, passes the resulting vector here, and gets back top-K matches.
--
-- Pairs with: 0003_nuggets.sql (the schema this queries).

-- ─── search_nuggets RPC ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION search_nuggets(
    query_embedding vector(1536),
    repo_filter     TEXT     DEFAULT NULL,
    kinds_filter    TEXT[]   DEFAULT NULL,
    top_k           INTEGER  DEFAULT 5,
    min_sim         REAL     DEFAULT 0.6
)
RETURNS TABLE (
    -- Mirror the nuggets schema 1:1 so PostgREST can deserialize into the
    -- same Rust Nugget struct.
    id                 UUID,
    team_id            UUID,
    gap_id             TEXT,
    repo_url           TEXT,
    repo_path_glob     TEXT,
    author_user_id     UUID,
    author_session_id  TEXT,
    author_machine     TEXT,
    title              TEXT,
    body               TEXT,
    embedding          vector(1536),
    kind               TEXT,
    confidence         TEXT,
    keeper             BOOLEAN,
    created_at         TIMESTAMPTZ,
    expires_at         TIMESTAMPTZ,
    deleted_at         TIMESTAMPTZ,
    -- Augmented:
    similarity         REAL
)
LANGUAGE SQL
STABLE
-- SECURITY INVOKER (default) so RLS on the nuggets table applies — the caller's
-- team_id scope is enforced by the existing "team_members_read_nuggets"
-- policy. We do NOT escalate via SECURITY DEFINER.
AS $$
    SELECT
        n.id,
        n.team_id,
        n.gap_id,
        n.repo_url,
        n.repo_path_glob,
        n.author_user_id,
        n.author_session_id,
        n.author_machine,
        n.title,
        n.body,
        -- Never return the embedding column over the wire (1536 floats × 4
        -- bytes = 6 KB/row of useless payload for the client).
        NULL::vector(1536) AS embedding,
        n.kind,
        n.confidence,
        n.keeper,
        n.created_at,
        n.expires_at,
        n.deleted_at,
        -- pgvector's <=> operator is cosine DISTANCE in [0, 2]; similarity
        -- is 1 - distance (mapped to [-1, 1], where 1 = identical).
        -- We clamp via the min_sim WHERE clause below.
        (1 - (n.embedding <=> query_embedding))::REAL AS similarity
    FROM nuggets n
    WHERE
        n.deleted_at IS NULL
        AND n.embedding IS NOT NULL
        AND (repo_filter IS NULL OR n.repo_url = repo_filter)
        AND (
            kinds_filter IS NULL
            OR cardinality(kinds_filter) = 0
            OR n.kind = ANY(kinds_filter)
        )
        -- RLS handles team_id scoping; we don't filter here.
        AND (1 - (n.embedding <=> query_embedding)) >= min_sim
    ORDER BY n.embedding <=> query_embedding ASC   -- closest first
    LIMIT GREATEST(top_k, 1);
$$;

COMMENT ON FUNCTION search_nuggets IS
    'INFRA-1473: cosine-similarity search over nuggets. SECURITY INVOKER so
     RLS applies. Returns top-K rows above min_sim, sorted by similarity desc.';

-- Grant execute to authenticated + anon (RLS still gates row visibility).
GRANT EXECUTE ON FUNCTION search_nuggets(vector(1536), TEXT, TEXT[], INTEGER, REAL)
    TO authenticated, anon, service_role;
