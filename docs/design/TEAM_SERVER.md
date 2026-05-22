# Chump team-shared substrate (Marcus M-D Phase 0)

**Tracking gap:** INFRA-1665
**Pairs with:** INFRA-1473 (vector-space implementation), INFRA-1475 (fleet queue implementation)
**SOC2 spinoff:** META-065 (decoupled timeline)

## The problem

Marcus's 2026-05-15 interview surfaced two Team-tier requirements:

1. **Shared work queue** — multiple operators on the same team share one logical pipeline. Operator A files gaps that Operator B's fleet can claim.
2. **Shared "things we've learned" memory** — one agent's discovery (a gotcha about a database edge case, a working pattern for a tricky refactor) is automatically available to every subsequent agent on the team's repo.

Both need the same primitive: **a team-scoped persistence layer** that lives on the network, not on any single laptop.

## The choice

We evaluated three approaches:

| Option | Verdict |
|---|---|
| Hand-write a Rust server binary (axum + Postgres) | ~3 weeks, owns auth + RLS + REST, duplicates Supabase's work |
| **Use Supabase as the substrate** | **Chosen.** ~1 week. Free pgvector, free RLS, free auth, free REST API |
| Roll our own + bring NATS for sync | Out of scope; revisit only if Supabase becomes commercially unviable |

## Deployment models (all one code path)

```
chump CLI ──→ HTTPS ──→ Supabase project
                          │
                          ├── operator BYO project (default)
                          ├── Chump-hosted (future paid escape hatch)
                          └── self-hosted (supabase start on team hardware)
```

The CLI cares only about `CHUMP_TEAM_URL` + `CHUMP_TEAM_API_KEY` + `CHUMP_TEAM_JWT`. Everything else is identical.

## Schema

Three migrations applied in order:

1. **`0001_team_foundation.sql`** — `teams`, `team_members`, `team_api_keys` + RLS scaffolding. Every other table joins through `team_id`.
2. **`0002_shared_gaps.sql`** — `shared_gaps`, `shared_claims`, `worker_capabilities`, `operator_quotas`. Foundation for INFRA-1475.
3. **`0003_nuggets.sql`** — `nuggets`, `nugget_reads`, pgvector HNSW index, `expire_stale_nuggets()` cleanup function. Foundation for INFRA-1473.

### Key invariants

- **`team_id` on every domain table.** RLS policies all filter on it. Cross-team data leak requires the service-role key (admin only).
- **`shared_claims` partial unique index** on `(gap_id) WHERE released_at IS NULL` is the CAS guarantee. Workers that lose the race get `ChumpTeamError::Conflict`.
- **`nuggets.embedding vector(1536)`** fits OpenAI `text-embedding-3-small` and `ada-002`. Larger models (3072-dim `3-large`) need a schema migration.
- **HNSW index** on the embedding column — modern default, fast similarity queries at ≥99% recall.

## Auth model

Two credentials at runtime:

| Credential | Use | Risk |
|---|---|---|
| `anon` key + user JWT | Daily-driver. RLS enforces per-team isolation. | Low. Compromised JWT exposes only that user's team's data. |
| `service-role` key | Schema migrations, admin scripts. Bypasses RLS. | High. Never ship to operators' machines. Only `chump team migrate` uses it. |

API keys (`team_api_keys`) are the headless-CLI path. Plaintext shown once at creation, bcrypt hash stored. Subsequent calls authenticate by submitting the plaintext as a bearer token; server hashes and compares.

## The crate (`crates/chump-team`)

Thin client over Supabase's PostgREST. Module per concern:

- `auth` — whoami, create/list/revoke API keys
- `gaps` — list/reserve/get/update on `shared_gaps`
- `claims` — `try_claim_gap` (CAS), release, renew
- `nuggets` — create, similarity-search, log read
- `capabilities` — upsert, heartbeat, list
- `quotas` — get-mine, set (admin), record-usage

All async (`tokio`). All errors collapse to `ChumpTeamError`. Transport failures (`is_transport()`) signal "fall back to local state.db" per INFRA-1475 AC #7.

## CLI surface

New subcommands under `chump team`:

```
chump team init <project-url>     # writes ~/.chump/team.toml, mints first API key
chump team auth                   # show current identity + active team
chump team status                 # team-wide fleet activity (cockpit summary)
chump team migrate                # apply pending SQL migrations (service-role)
chump team members                # list / add / remove team members
chump team keys                   # list / create / revoke API keys
```

## Offline degradation

Every team-server call has a local fallback:

| Remote call | Local fallback |
|---|---|
| `try_claim_gap` (remote) | Existing local `chump claim` (NATS-KV or `.chump-locks/*.json`) |
| `reserve_gap` (remote) | Existing `chump gap reserve` against local `state.db` |
| `search_nuggets` (remote) | Local-only nuggets file (SQLite or JSONL) shipped in Phase 2 |

Transport errors trigger fallback; the result is wrapped in `Outcome::Local(...)` so callers know what they got.

## What Phase 0 ships

- Three migration files (the schema is the contract)
- The `chump-team` crate skeleton (types + signatures; methods are scaffolding that `unimpl`s)
- This design doc
- Workspace registration

## What Phase 0 explicitly does NOT ship

- Working `whoami`/`reserve_gap`/`try_claim_gap`/`search_nuggets` implementations — those land in INFRA-1475 and INFRA-1473
- The `chump team` subcommand wiring in `src/main.rs` — depends on Phase 0 crate being merged first
- Embedding-generation glue — that's an INFRA-1473 concern (OpenAI? local model? both?)
- Cockpit team-mind view — INFRA-1473 implementation
- Web UI changes — comes after the CLI surface stabilizes

## What I need from the operator

To take Phase 0 from "scaffolding" to "live":

1. **Supabase project URL** — your existing account or a new dedicated `chump-dogfood` project
2. **Service-role key** — for me to run `chump team migrate` once. After that, I revoke it.
3. **Anon key** — for the CLI's daily-driver path. This goes into `~/.chump/team.toml`.

Once those are in hand, Phase 0 implementation (filling in the `unimpl`s, wiring the CLI, integration test against a real project) is one more focused PR — probably another 2-3 days.

## Pending decisions

| Decision | Default I'd recommend |
|---|---|
| Use existing Supabase account for dogfood, dedicated one for shipped product? | Yes — existing for dev now, dedicated when first paying customer surfaces |
| Embedding model for nuggets? | `text-embedding-3-small` (1536-dim, $0.02/M tokens, cheap and good) |
| Default nugget retention for non-keepers? | 30 days (matches AC #9) |
| SOC2 audit timing? | Deferred to META-065; not on the M-D MVP timeline |
| First Chump-hosted tier — when? | After 5 customers ask, or first enterprise prospect, whichever first |
