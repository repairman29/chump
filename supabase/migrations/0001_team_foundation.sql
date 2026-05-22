-- INFRA-1665: Marcus M-D Phase 0 — team foundation schema.
--
-- This migration creates the team-scoping primitives that every subsequent
-- table builds on. Three concerns:
--   1. teams                — the top-level grouping
--   2. team_members         — who belongs to which team, and in what role
--   3. team_api_keys        — headless CLI access for each operator's laptop
--
-- Every later table gets a `team_id UUID NOT NULL REFERENCES teams(id)`
-- column + an RLS policy restricting visibility to that team's members.
-- That is the security model. Don't bypass it from application code.
--
-- Deployment models all use this same migration:
--   • Operator BYO Supabase project — they run `chump team migrate` against
--     their own URL + service-role key
--   • Chump-hosted (future)         — we provision a project per customer
--   • Self-hosted (future)          — `supabase start` locally on the team's
--                                     hardware; same migration applies
--
-- Pairs with: 0002_shared_gaps.sql (INFRA-1475), 0003_nuggets.sql (INFRA-1473)

-- ─── Extensions ────────────────────────────────────────────────────────────
-- pgcrypto for gen_random_uuid(); pgvector for embeddings (used in 0003)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─── teams ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS teams (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    slug TEXT UNIQUE NOT NULL,  -- url-friendly identifier
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- tier metadata; future quota enforcement reads this
    tier TEXT NOT NULL DEFAULT 'free'
        CHECK (tier IN ('free', 'team', 'enterprise')),
    -- self_hosted_url is for cockpit hint only: when this team's data lives
    -- on the customer's own Supabase project, list it here so visiting
    -- operators know where to point. NULL = canonical hosted project.
    self_hosted_url TEXT,
    -- soft-delete; teams are immutable for audit trail purposes
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS teams_slug_idx ON teams (slug) WHERE deleted_at IS NULL;

COMMENT ON TABLE teams IS
    'Top-level team grouping. All other tables join through team_id.';

-- ─── team_members ──────────────────────────────────────────────────────────
-- Membership uses Supabase's built-in auth.users table for user_id. When
-- running against vanilla Postgres (e.g. local dev without Supabase auth),
-- user_id is just an opaque UUID the application manages.
CREATE TABLE IF NOT EXISTS team_members (
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    -- role gates what the member can do within the team
    --   owner    — billing, member admin, schema migrations
    --   admin    — member admin (cannot remove owner), all data ops
    --   operator — data ops only (claim gaps, write nuggets, etc.)
    --   viewer   — read-only access
    role TEXT NOT NULL DEFAULT 'operator'
        CHECK (role IN ('owner', 'admin', 'operator', 'viewer')),
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- removed members keep the row for audit; check removed_at IS NULL for active
    removed_at TIMESTAMPTZ,
    PRIMARY KEY (team_id, user_id)
);

CREATE INDEX IF NOT EXISTS team_members_user_idx ON team_members (user_id)
    WHERE removed_at IS NULL;

COMMENT ON TABLE team_members IS
    'Active membership lookup. RLS policies on other tables JOIN through this.';

-- ─── team_api_keys ─────────────────────────────────────────────────────────
-- API keys are how the `chump` CLI authenticates without an interactive
-- login. Each operator's laptop gets at least one key. We store only the
-- bcrypt hash; the plaintext is shown ONCE at creation time.
CREATE TABLE IF NOT EXISTS team_api_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,  -- which member this key represents
    -- bcrypt hash of the plaintext key (never store the key itself)
    key_hash TEXT NOT NULL,
    -- short prefix shown in CLI output for human identification
    -- format: "chump_tm_<random>" where <random> is the first 8 chars
    prefix TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    -- optional auto-expiry; null = never expires (operator must revoke manually)
    expires_at TIMESTAMPTZ,
    -- which user_id revoked this key (for audit)
    revoked_by_user_id UUID
);

CREATE INDEX IF NOT EXISTS team_api_keys_team_user_idx ON team_api_keys (team_id, user_id)
    WHERE revoked_at IS NULL;

COMMENT ON TABLE team_api_keys IS
    'Headless CLI auth tokens. Plaintext shown ONCE at creation; only hash stored.';

-- ─── Row-level security ────────────────────────────────────────────────────
-- The security model: every read/write goes through Supabase's PostgREST
-- API with the requesting user's JWT. RLS policies check that the JWT's
-- subject (auth.uid()) is a member of the row's team_id.
--
-- Service-role key BYPASSES RLS — only use for migrations + admin tasks,
-- never expose to the CLI.

ALTER TABLE teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE team_api_keys ENABLE ROW LEVEL SECURITY;

-- Policy: members can see teams they belong to
CREATE POLICY "team_members_can_read_team" ON teams
    FOR SELECT
    USING (
        id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid() AND removed_at IS NULL
        )
    );

-- Policy: members can see the membership list for their own teams
CREATE POLICY "team_members_can_read_membership" ON team_members
    FOR SELECT
    USING (
        team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid() AND removed_at IS NULL
        )
    );

-- Policy: admins/owners can insert new members into their teams
CREATE POLICY "admins_can_add_members" ON team_members
    FOR INSERT
    WITH CHECK (
        team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid()
              AND removed_at IS NULL
              AND role IN ('owner', 'admin')
        )
    );

-- Policy: members can see their own API keys (never other members')
CREATE POLICY "members_can_read_own_api_keys" ON team_api_keys
    FOR SELECT
    USING (user_id = auth.uid());

-- Policy: members can create API keys for themselves
CREATE POLICY "members_can_create_own_api_keys" ON team_api_keys
    FOR INSERT
    WITH CHECK (
        user_id = auth.uid()
        AND team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid() AND removed_at IS NULL
        )
    );

-- Policy: members can revoke their own API keys
CREATE POLICY "members_can_revoke_own_api_keys" ON team_api_keys
    FOR UPDATE
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- ─── Smoke test data (commented; uncomment for local dev only) ─────────────
-- INSERT INTO teams (id, name, slug) VALUES
--     ('00000000-0000-0000-0000-000000000001', 'Chump Dogfood', 'chump-dogfood');
-- INSERT INTO team_members (team_id, user_id, role) VALUES
--     ('00000000-0000-0000-0000-000000000001',
--      '00000000-0000-0000-0000-000000000999', 'owner');
