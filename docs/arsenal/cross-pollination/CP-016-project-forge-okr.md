# CP-016: Compare project-forge OKR schema vs Chump state.db

**Target:** Chump gap registry evolution (Direction 4) — does project-forge's data model unlock superior primitives?
**Arsenal match:** `repairman29/project-forge` (149 MB active Next.js + Node + Postgres OKR platform)
**Source files cited:** `backend/prisma/schema.prisma`, `data-model.md`, `ai_copilot_integration.md`, `objectives_key_results.md`, `frontend/src/components/okrs/PerformanceInsights.tsx`
**Recommended route:** **(b) Extend schema** — add 3 columns (`parent_gap_id`, `due_date`, `owner_id`) inline. Skip the AI-insights and full-Postgres migration.
**Status:** proposed (2026-05-23, INFRA-1848)

## The Target — Mission Yield framing

Chump's `state.db.gaps` table is a **flat list of work items**: 1800+ rows, each row a leaf, all hierarchy emergent from `depends_on` (a JSON-array graph) and pillar-prefix conventions in titles. project-forge's data model is the opposite: an **explicit hierarchy** (`Objective` → `KeyResult`, with `OKR.parentOkrId` allowing objective trees) anchored to **explicit owners** (`User`), **explicit timeframes** (`startDate`/`endDate`), and **per-row status enums** with confidence-tracked check-ins.

Direction 4 asks: should Chump's flat gap list evolve to a richer initiative/OKR hierarchy? This brief grades the project-forge primitives against Chump's reality and picks the cheapest yield.

## project-forge data model

### Schema overview

Source: `backend/prisma/schema.prisma` (300+ lines, Postgres-targeted via Prisma ORM). Tables relevant to OKR data model:

| Table | Cardinality | Purpose |
|---|---|---|
| `User` | 1:N owns Objective/KR | Identity, with role enum and Google integration tokens |
| `Organization` | 1:N → Team, Project | Top-level tenant |
| `Department` | N:1 → Organization, 1:N → Team | Org subdivision |
| `Team` | N:1 → Department, 1:N → OKR | Group of users |
| `TeamMember` | N:N User↔Team | Membership with role |
| `Objective` | N:1 → User | Per-user OKR root (title/desc/start/end/status) |
| `KeyResult` | N:1 → Objective, optional N:1 → OKR | Measurable: `currentProgress`/`targetProgress`/`status` |
| `OKR` | N:1 → Team | Team-level OKR; aggregates KeyResults |
| `OKRTemplate` + `KeyResultTemplate` | 1:N | Reusable scaffolding |
| `ProgressUpdate` | N:1 → KeyResult, User | Check-in events |
| `Feedback` / `Recognition` | N:1 → User | Comment-stream qualitative signal |

Source `data-model.md` describes an explicit **OKRCheckIn** entity with a `confidence` enum (`high|medium|low`); the Prisma schema simplifies this to `ProgressUpdate` (value + notes) but the design intent is the same.

### Hierarchy

The Prisma schema exposes hierarchy at **two levels**:

1. **Implicit two-tier per Objective:** `Objective` → `KeyResult[]` (line 116-153 of schema.prisma)
2. **Explicit parent linkage:** `data-model.md` documents `OKR.parentOkrId: UUID (FK → OKR.id, nullable)` for parent-child OKR trees (e.g. company OKR → department OKR → team OKR). Note: the Prisma schema does **not** implement `parentOkrId` on the `OKR` model — the design doc is aspirational; only the doc-level `Objective`→`KeyResult` tree is realized in code. **This is a partial implementation**, useful as a design signal but not as a copy-paste artifact.

### AI-insights enrichment — aspirational only

`ai_copilot_integration.md` describes an AI copilot for OKR creation, but:
- No `AIInsight` / `AIEnrichment` table in `schema.prisma`
- No `backend/src/services/ai*.ts` files exist (verified via `gh api git/trees/main?recursive=1`)
- `frontend/src/components/okrs/PerformanceInsights.tsx` is dashboard scaffolding for system metrics (success rate, latency), **not LLM enrichment** of OKR content

**Verdict on AI-insights:** project-forge has the UI shell for AI assistance but no schema layer for it. Chump cannot harvest a primitive that doesn't exist in the source. Skip.

### Owner / Team / Status model

- **Owner:** every `Objective` and `KeyResult` has `userId` FK to `User` — first-class field, not derived
- **Status enum:** `"NOT_STARTED" | ... | "completed"` string on each row (not strictly enum'd in Prisma — default `"NOT_STARTED"`, no CHECK constraint visible)
- **Timeframe:** every Objective has `startDate` + `endDate` (DateTime), not optional
- **Status transition rules:** documented in `data-model.md` ("Status transitions must follow defined workflows") but **not enforced at the schema layer** — no triggers, no CHECK constraints

## Chump state.db schema

Source: `crates/chump-gap-store/src/lib.rs` lines 260-365.

### `gaps` table — current columns

```sql
CREATE TABLE gaps (
    id                   TEXT PRIMARY KEY,         -- "INFRA-1848" etc.
    domain               TEXT NOT NULL DEFAULT '', -- INFRA / EVAL / COG / META / FLEET / ...
    title                TEXT NOT NULL DEFAULT '', -- often pillar-tagged ("EFFECTIVE: foo")
    description          TEXT NOT NULL DEFAULT '',
    priority             TEXT NOT NULL DEFAULT '', -- P0 | P1 | P2 | P3
    effort               TEXT NOT NULL DEFAULT '', -- xs | s | m | l | xl
    status               TEXT NOT NULL DEFAULT 'open', -- open | claimed | done | wontfix
    acceptance_criteria  TEXT NOT NULL DEFAULT '', -- JSON or YAML-as-string
    depends_on           TEXT NOT NULL DEFAULT '', -- JSON array of gap IDs
    notes                TEXT NOT NULL DEFAULT '',
    source_doc           TEXT NOT NULL DEFAULT '',
    created_at           INTEGER NOT NULL DEFAULT 0,  -- unix ts
    closed_at            INTEGER,
    -- Added via ALTER TABLE (idempotent migration):
    opened_date          TEXT NOT NULL DEFAULT '',  -- "2026-05-23"
    closed_date          TEXT NOT NULL DEFAULT '',
    closed_pr            INTEGER,                   -- PR number on ship
    skills_required      TEXT NOT NULL DEFAULT '',  -- "rust,sqlite,macos"
    preferred_backend    TEXT NOT NULL DEFAULT '',  -- claude | local-llm | cascade | any
    preferred_machine    TEXT NOT NULL DEFAULT '',  -- macbook | pi-mesh | cloud-overflow
    estimated_minutes    TEXT NOT NULL DEFAULT '',
    required_model       TEXT NOT NULL DEFAULT ''   -- haiku | sonnet | opus | any
);
```

Sibling tables: `gap_counters` (per-domain ID counter), `leases` (session lock map), `intents` (planned file paths), `routing_outcomes` (dispatch scoreboard).

### How hierarchy works today

- **No `parent_gap_id` column.** Hierarchy is encoded three ways, none canonical:
  1. `depends_on` JSON array — DAG, not tree; a gap can depend on N others
  2. Filename convention: `META-068.yaml` describes parent META gap that produces sub-INFRA gaps, but the linkage lives in the description text, not the schema
  3. Title prefix `EFFECTIVE: foo` is a soft pillar tag, not a parent FK
- **No owner field.** Ownership is derived from `leases.session_id`: whichever worker holds the active lease "owns" the gap *for the duration of work*. Post-ship the gap has no owner. (Closed gaps record `closed_pr`, which transitively names the GitHub author, but state.db has no `owner_id`.)
- **No due_date.** Effort is a t-shirt size (`xs..xl`); no SLA, no time-bound deadline.
- **`acceptance_criteria` is an unstructured string** — usually YAML-as-string with a list of items, but the schema doesn't model individual AC items as rows, so progress tracking against AC items is impossible without re-parsing.

## Side-by-side mapping

| project-forge concept | Chump equivalent | Delta |
|---|---|---|
| `Objective` (root) | (none — gaps are flat) | Chump lacks any explicit tree root |
| `KeyResult` (measurable child) | `gap.acceptance_criteria` (string blob) | Chump's are not individually addressable |
| `User` / `Owner` (FK on every row) | `leases.session_id` (transient) | Chump owner = active lease; closed gaps have no owner |
| `Organization` / `Team` | (none) | Chump is single-tenant by design |
| `OKR.parentOkrId` (designed, not coded) | `gap.depends_on` (DAG, not tree) | Different shape entirely |
| `startDate` / `endDate` | (none) | Chump has no SLA / no due-date |
| `Objective.status` enum | `gap.status` (open/claimed/done/wontfix) | Chump's is tighter |
| `currentProgress` / `targetProgress` (Float) | (none on the gap itself) | Chump tracks binary done-vs-not |
| `ProgressUpdate` event log | (none on gap; `routing_outcomes` for dispatch only) | No per-gap progress event stream |
| `OKRCheckIn.confidence` (high/med/low) | (none) | No confidence signal |
| AI-insights enrichment | (none) | **Source has UI shell only, no schema** — moot |
| `OKRTemplate` + `KeyResultTemplate` | (none) | Chump uses `chump gap reserve` boilerplate; no template DB |
| `Feedback` / `Recognition` | (none on gap directly; PR review comments live in GitHub) | Chump externalizes comments to GitHub |

## Superior primitives in project-forge worth porting

Filtered to primitives that (a) actually exist in code, not just docs, and (b) plausibly fit Chump's single-tenant async-worker model:

1. **Explicit `parent_gap_id` column for tree hierarchy.** project-forge's `Objective`→`KeyResult` two-tier is real; the deeper `OKR.parentOkrId` tree is designed-not-coded but the design is sound. Chump's `depends_on` DAG cannot express "INFRA-1848 is a child of META-070" — the closest equivalent is filename convention, which is read by humans but not by `chump gap` tooling. **Cost:** one ALTER TABLE, one `--parent <ID>` flag on `gap reserve`, one tree-printer in `chump gap show`.
2. **Explicit `due_date` for SLA tracking.** Chump's `effort` (`xs..xl`) is a size estimate, not a deadline. The fleet already has `chump health --slo-check` (per CLAUDE.md) checking pillar SLOs at the fleet level — but no per-gap deadline. **Cost:** one ALTER TABLE, one `--due <ISO-date>` flag, one SLA-breach event in ambient.jsonl.
3. **Explicit `owner_id` field decoupled from lease.** Today's "owner = whoever last held the lease" model loses information on lease expiry. An explicit owner survives lease churn and gives `chump gap audit-priorities` a real "who owns this stale P0" answer. **Cost:** one ALTER TABLE, one `--owner <id>` flag, default to claiming worker's session_id at first claim.
4. **`OKRTemplate` pattern for reusable AC scaffolding.** Chump operators repeatedly type the same AC boilerplate for repo-takeover, fleet-meta, and pillar-tagged gaps. A small `gap_templates` table keyed by template_id (e.g. `"effective-ui-polish"`) with stock AC items would cut filing friction. **Cost:** one new table, `chump gap reserve --template <id>` flag. *Note:* this is convenience, not differentiation — flag as nice-to-have if (b) is approved.

**Explicitly NOT worth porting:**
- **Multi-tenant `Organization`/`Department`/`Team`.** Chump is intentionally single-tenant for the foreseeable future; this is a complexity tax against productization (META-068).
- **`ProgressUpdate` event log per gap.** Chump already streams via `ambient.jsonl`; duplicating that into state.db is overhead.
- **AI-insights enrichment.** project-forge has no schema for this — it's docs-only. Whatever Chump wants from per-gap LLM enrichment, it has to design from scratch (and the `ai_enrichment_json` shape is better served by ambient events than a state.db column).
- **Confidence enum on check-ins.** Chump's binary done/not-done is correct for fleet automation — confidence levels reintroduce ambiguity workers can't act on.

## Decision: **(b) Extend schema** — 3 columns inline, skip full migration

### Rationale and cost-benefit

| Option | Cost | Benefit | Verdict |
|---|---|---|---|
| (a) Keep as-is | $0 | Status quo | Misses high-value primitives below |
| **(b) Extend** | ~4 hours: 3 ALTER TABLE, 3 CLI flags, 1 ambient event, regen `state.sql`, doc update | Real hierarchy, real owners, real SLAs — without abandoning SQLite | **Chosen** |
| (c) Full Postgres + initiative tier | ~6 weeks: rewrite gap-store, dual-write migration, all 60+ scripts updated, Postgres ops burden | Multi-tenant ready, ACID complete, schema-validated enums | Overkill for single-tenant single-machine fleet; productization tax |

**Why (b) over (c):**
- Chump's `state.db` is read by 60+ shell scripts via `sqlite3` directly. Switching to Postgres breaks every one of them and forces the fleet offline during migration.
- The "offline + local-LLM" mission (per CLAUDE.md memory) explicitly leans on SQLite's zero-ops profile. Postgres reintroduces a daemon to manage.
- The 3 columns from (b) cover ~80% of project-forge's design-doc value (hierarchy + owner + SLA) at <1% of (c)'s cost.

**Why (b) over (a):**
- META-046 (PM-curation role) already wants "hierarchy depth" — `chump gap audit-priorities` cannot answer "what's the parent META gap of this orphan INFRA?" without `parent_gap_id`.
- `chump gap audit-priorities` flags "open P0 stuck > 7 d" — but the 7-day rule is a fleet-wide constant; an explicit `due_date` lets individual gaps set their own SLA (e.g. customer-promised features).
- The lease-derived ownership model loses information at every lease expiry; the dead-pool of "what worker last touched this" data is forensically hard to mine.

### Migration plan (for follow-up gap)

```sql
ALTER TABLE gaps ADD COLUMN parent_gap_id  TEXT NOT NULL DEFAULT '';
ALTER TABLE gaps ADD COLUMN due_date       TEXT NOT NULL DEFAULT '';  -- ISO date
ALTER TABLE gaps ADD COLUMN owner_id       TEXT NOT NULL DEFAULT '';  -- session_id, GH login, etc.
CREATE INDEX gaps_parent ON gaps(parent_gap_id);
CREATE INDEX gaps_owner  ON gaps(owner_id);
CREATE INDEX gaps_due    ON gaps(due_date);
```

YAML round-trip:
- Add three optional fields to `GapRow` struct in `crates/chump-gap-store/src/lib.rs` (with `#[serde(default)]` so existing YAML files don't break)
- Update `chump gap reserve` to accept `--parent <ID>`, `--owner <id>`, `--due <ISO-date>`
- Update `chump gap show` to render parent breadcrumb when `parent_gap_id` is set
- Update `chump gap audit-priorities` to consume `due_date` for per-gap SLA breach detection
- Emit `kind=gap_sla_breach` to `ambient.jsonl` when `due_date < today AND status != done`

## Follow-up schema-evolution gap

**Title:** `INFRA: extend state.db.gaps with parent_gap_id, owner_id, due_date columns (CP-016 follow-up)`
**Domain:** INFRA
**Priority:** P2 (no current production fire — enables META-046 + future SLA tracking)
**Effort:** m (3-5 hours; ALTER TABLE + 3 CLI flags + ambient event + YAML round-trip + tests)
**Acceptance criteria (sketch):**
- `state.db` schema dump (`scripts/dev/state-db-schema-dump.sh`) includes the three new columns + indexes
- `chump gap reserve --parent <ID> --owner <id> --due <ISO-date>` accepts and persists each field
- YAML round-trip: existing `docs/gaps/*.yaml` files load without error (defaults to empty string); new gaps with these fields round-trip cleanly via `gaps-integrity` CI
- `chump gap audit-priorities` reports per-gap SLA breaches when `due_date < today` and `status != done`
- Ambient event `kind=gap_sla_breach` emitted on first breach detection per gap
- `chump gap show <ID>` renders parent breadcrumb when `parent_gap_id` is set
- `crates/chump-gap-store/src/lib.rs` `GapRow` struct has the three fields with `#[serde(default)]`
- No changes to dispatch or claim logic — purely additive

## Lineage / Risk

- **Migration cost (chosen path):** ~4 hours of contiguous work. Three ALTER TABLE statements are idempotent (see existing `migrate()` pattern). YAML round-trip risk is moderate — `gaps-integrity` CI catches malformed AC blocks (see git status notes mentioning INFRA-1759/1760/1761 yaml fixes); the three new fields default to empty string and round-trip safely.
- **What we lose by NOT adopting (b):**
  - `chump gap audit-priorities` cannot answer "what's the parent META gap" — operator must grep filenames
  - SLA tracking remains fleet-wide-only; per-customer-promised feature deadlines can't be encoded
  - "Who owns this stale gap" remains lease-history archaeology
- **SQLite-vs-Postgres tradeoff (rejecting (c)):** Postgres gives enum CHECK constraints and concurrent-write performance, but Chump's write rate is bounded by `chump-coord` (single-process atomic claims). The bottleneck isn't the DB — it's the operator. Concurrency wins from Postgres are theoretical; ops burden is real.
- **What we lose by NOT adopting AI-insights:** nothing, because the source has no schema for it. Future Chump LLM enrichment is a separate design exercise, not a project-forge port. If/when Chump wants per-gap LLM-predicted effort or risk flags, the natural shape is an ambient event stream (`kind=gap_enriched`) + a CTE-like view over recent enrichments, not a state.db column.

**Vendoring note:** No code ports from project-forge — this brief is design influence only. Any future vendoring (e.g. the `OKRTemplate` table pattern, if adopted) would carry the standard lineage trailer:

```
Vendored from repairman29/project-forge at commit <SHA> (CP-016)
```

**Coordinates with:**
- **META-046** (PM-curation role) — hierarchy + owner unlock real "who owns this stale P0" answers
- **CLAUDE.md Mission Driver** — `parent_gap_id` lets pillar inventory roll up by initiative, not just count flat gaps
- **INFRA-1816** (echeo Ship Velocity Score) — score + hierarchy compose: per-initiative velocity, not just per-gap
- **META-068** (productization plan) — single-tenant assumption holds; (c)'s multi-tenant cost stays deferred
