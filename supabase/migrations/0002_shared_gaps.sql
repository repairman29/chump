-- INFRA-1665: Marcus M-D Phase 0 — shared work queue schema (INFRA-1475 foundation).
--
-- Tables for the cross-operator fleet queue:
--   1. shared_gaps         — team-visible work items (mirrors local state.db gaps)
--   2. shared_claims       — atomic claim/lease records (CAS-protected)
--   3. worker_capabilities — what each operator's hardware can claim
--   4. operator_quotas     — per-operator spend caps
--
-- Pairs with: 0001_team_foundation.sql (provides teams + auth)
--             0003_nuggets.sql        (sibling INFRA-1473 schema)

-- ─── shared_gaps ───────────────────────────────────────────────────────────
-- Mirror of the local state.db `gaps` table, scoped to a team. Operators
-- reserve work here; their fleet workers pull from this queue.
CREATE TABLE IF NOT EXISTS shared_gaps (
    -- Gap ID format: "DOMAIN-NNNN" (matches local convention)
    id TEXT PRIMARY KEY,
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    domain TEXT NOT NULL,
    priority TEXT NOT NULL
        CHECK (priority IN ('P0', 'P1', 'P2', 'P3')),
    effort TEXT NOT NULL
        CHECK (effort IN ('xs', 's', 'm', 'l')),
    status TEXT NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'claimed', 'shipped', 'superseded', 'blocked')),
    description TEXT,
    acceptance_criteria TEXT,
    notes TEXT,
    -- skills the worker needs (push-routing hint per FLEET-034)
    skills_required JSONB DEFAULT '[]'::jsonb,
    -- machine-tier hint (e.g. "m4-mini" for compile-heavy work)
    preferred_machine TEXT,
    -- depends_on is a JSON array of gap IDs this gap blocks on
    depends_on JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by_user_id UUID NOT NULL,  -- which team member filed it
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- shipped_at + closed_pr for retrospective queries
    shipped_at TIMESTAMPTZ,
    closed_pr INT
);

CREATE INDEX IF NOT EXISTS shared_gaps_team_status_idx ON shared_gaps (team_id, status);
CREATE INDEX IF NOT EXISTS shared_gaps_priority_idx ON shared_gaps (team_id, priority)
    WHERE status = 'open';

COMMENT ON TABLE shared_gaps IS
    'Team-shared work queue. Each row is a gap any team operator can claim.';

-- ─── shared_claims ─────────────────────────────────────────────────────────
-- One active claim per gap, enforced via partial UNIQUE index. Workers
-- competing for the same gap will race on INSERT; the database picks one.
CREATE TABLE IF NOT EXISTS shared_claims (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    gap_id TEXT NOT NULL REFERENCES shared_gaps(id) ON DELETE CASCADE,
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    -- which team member's worker holds this claim
    operator_user_id UUID NOT NULL,
    -- machine identifier (hostname or chump-coord-assigned)
    worker_machine TEXT NOT NULL,
    -- session id from chump claim (claim-<gap>-<pid>-<ts>)
    session_id TEXT NOT NULL,
    claimed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    released_at TIMESTAMPTZ,
    -- release reason: 'shipped' | 'aborted' | 'expired' | 'evicted'
    release_reason TEXT
        CHECK (release_reason IN ('shipped', 'aborted', 'expired', 'evicted'))
);

-- THE CAS GUARANTEE: at most one active claim per gap.
-- Index is partial — only enforces uniqueness while released_at IS NULL.
CREATE UNIQUE INDEX IF NOT EXISTS shared_claims_active_unique
    ON shared_claims (gap_id)
    WHERE released_at IS NULL;

CREATE INDEX IF NOT EXISTS shared_claims_team_active_idx
    ON shared_claims (team_id, claimed_at DESC)
    WHERE released_at IS NULL;

COMMENT ON TABLE shared_claims IS
    'Lease records for shared_gaps. Partial unique index enforces atomic claim.';

-- ─── worker_capabilities ───────────────────────────────────────────────────
-- Each operator's machine advertises its skills/backend so push-routing
-- (FLEET-034 style) can dispatch matching gaps. Mirrors the local
-- worker.sh's WORKER_SKILLS env var.
CREATE TABLE IF NOT EXISTS worker_capabilities (
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    machine TEXT NOT NULL,  -- hostname
    skills JSONB NOT NULL DEFAULT '[]'::jsonb,  -- ['rust','sqlite','macos']
    -- which agent backend runs on this machine
    backend TEXT NOT NULL DEFAULT 'claude'
        CHECK (backend IN ('claude', 'opencode', 'codex', 'manual')),
    -- soft cap; chump fleet up enforces this client-side
    max_concurrent_gaps INT NOT NULL DEFAULT 2,
    -- last heartbeat from the worker; stale rows mean the machine is offline
    last_heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (team_id, user_id, machine)
);

CREATE INDEX IF NOT EXISTS worker_capabilities_team_idx ON worker_capabilities (team_id);

COMMENT ON TABLE worker_capabilities IS
    'Per-machine capability registry. Push-routing matches gaps to capable workers.';

-- ─── operator_quotas ───────────────────────────────────────────────────────
-- Per-operator monthly spend cap. Predecessor to a full billing system;
-- enforces "Operator A cannot exhaust the team budget" (INFRA-1475 AC #6).
CREATE TABLE IF NOT EXISTS operator_quotas (
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    -- USD cap per calendar month; null = no cap
    max_llm_cost_usd_per_month NUMERIC(10, 2),
    -- tokens consumed this calendar month (running total)
    tokens_used_current_month BIGINT NOT NULL DEFAULT 0,
    -- USD spent this calendar month (running total)
    cost_used_current_month_usd NUMERIC(10, 2) NOT NULL DEFAULT 0,
    -- when this counter resets (first of next month, UTC)
    reset_at TIMESTAMPTZ NOT NULL
        DEFAULT date_trunc('month', NOW() + INTERVAL '1 month'),
    PRIMARY KEY (team_id, user_id)
);

COMMENT ON TABLE operator_quotas IS
    'Monthly per-operator spend cap; enforced client-side via budget_tracker.';

-- ─── Row-level security ────────────────────────────────────────────────────
ALTER TABLE shared_gaps ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE worker_capabilities ENABLE ROW LEVEL SECURITY;
ALTER TABLE operator_quotas ENABLE ROW LEVEL SECURITY;

-- Standard read pattern: team members see their team's data
CREATE POLICY "team_members_read_shared_gaps" ON shared_gaps
    FOR SELECT
    USING (
        team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid() AND removed_at IS NULL
        )
    );

CREATE POLICY "team_members_insert_shared_gaps" ON shared_gaps
    FOR INSERT
    WITH CHECK (
        team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid()
              AND removed_at IS NULL
              AND role IN ('owner', 'admin', 'operator')
        )
        AND created_by_user_id = auth.uid()
    );

CREATE POLICY "team_members_update_shared_gaps" ON shared_gaps
    FOR UPDATE
    USING (
        team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid()
              AND removed_at IS NULL
              AND role IN ('owner', 'admin', 'operator')
        )
    );

CREATE POLICY "team_members_read_shared_claims" ON shared_claims
    FOR SELECT
    USING (
        team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid() AND removed_at IS NULL
        )
    );

CREATE POLICY "team_members_create_own_claims" ON shared_claims
    FOR INSERT
    WITH CHECK (
        operator_user_id = auth.uid()
        AND team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid()
              AND removed_at IS NULL
              AND role IN ('owner', 'admin', 'operator')
        )
    );

CREATE POLICY "team_members_release_own_claims" ON shared_claims
    FOR UPDATE
    USING (operator_user_id = auth.uid())
    WITH CHECK (operator_user_id = auth.uid());

CREATE POLICY "team_members_read_capabilities" ON worker_capabilities
    FOR SELECT
    USING (
        team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid() AND removed_at IS NULL
        )
    );

CREATE POLICY "team_members_manage_own_capabilities" ON worker_capabilities
    FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "team_members_read_own_quota" ON operator_quotas
    FOR SELECT
    USING (
        user_id = auth.uid()
        OR team_id IN (
            -- admins/owners can see all team-member quotas
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid()
              AND removed_at IS NULL
              AND role IN ('owner', 'admin')
        )
    );

CREATE POLICY "team_admins_manage_quotas" ON operator_quotas
    FOR ALL
    USING (
        team_id IN (
            SELECT team_id FROM team_members
            WHERE user_id = auth.uid()
              AND removed_at IS NULL
              AND role IN ('owner', 'admin')
        )
    );
