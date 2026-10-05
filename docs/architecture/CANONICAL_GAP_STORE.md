# Canonical gap store: one source of truth

**Decision (RESILIENT-1057):** the gap registry has exactly one canonical store —
the local SQLite database `.chump/state.db`. Everything else is either a derived
mirror or a dormant future backend. This document exists so no future change
silently re-creates the split-brain that this gap drained
(`[[gap-store-split-brain-swamp]]`).

## The three representations (and which one is truth)

| Store | Role | Written by the fleet? |
|-------|------|-----------------------|
| **SQLite `.chump/state.db`** | **CANONICAL.** The CLI (`chump gap …`) and every worker read/write here. | Yes — this is the truth. |
| YAML `docs/gaps/*.yaml` | Derived **git mirror**, reconciled by `chump gap sync` / `chump-gap-doctor`. Drift here is expected staleness, not a second truth (a `--pull` never reverts a terminal-status row — INFRA-3606). | Regenerated from state.db; never authoritative. |
| PostgREST `shared_gaps` (self-hosted Postgres `chump_fleet`) | **DORMANT future backend** (INFRA-2092, `postgres-backend` cargo feature, **OFF by default**). Empty until an explicit migration + backfill lands. | **No.** Must never be treated as canonical while it diverges from state.db. |

## What the split-brain actually was

PostgREST was "configured" (roles, `postgrest.conf`, an enabled
`chump-postgrest.service`, a canonical `CHUMP_GAP_STORE_URL`) and declared a
first-class owned-node organ (INFRA-3642) — but it was **broken and empty**, so
the fleet silently ran on SQLite while a second, authoritative-looking store sat
there returning errors. Three stacked root causes kept the endpoint broken:

1. **PG16+ `SET` membership option.** `GRANT chump_anon TO chump_authenticator`
   makes the authenticator a *member* of `chump_anon`, but on Postgres 16+ that
   no longer implies the right to `SET ROLE` unless the membership carries the
   `SET` option. Symptom: `permission denied to set role "chump_anon"`
   (SQLSTATE 42501). Check with `pg_has_role('…','chump_anon','SET')`, not
   `'MEMBER'` — `MEMBER` is true even when `SET` is false.
2. **Stale process on an old in-memory config.** `chump-postgrest.service`
   (PID from Aug-21) predated the Aug-22 fix to `postgrest.conf`. The running
   process still connected as the plain `authenticator` role (no `SET` on
   `chump_anon`) while the on-disk conf already named `chump_authenticator`
   (which *can* set it). PostgREST re-reads `db-uri`/`db-anon-role` only on a
   full restart — a schema reload (SIGUSR2) is not enough.
3. **Bind scope.** `postgrest.conf` sets `server-host`. Bind the **tailnet**
   interface (`100.90.52.126`), not `127.0.0.1` (unreachable by the fleet) and
   not `0.0.0.0` (these are public Oracle nodes — don't expose Postgres' REST
   layer on the public IP).

All three were fixed live: restart to pick up the correct role, and
`server-host = "100.90.52.126"`. The endpoint now serves `shared_gaps` → `[]`
HTTP 200 (empty, dormant) over the tailnet instead of 42501.

Full unification onto PostgREST (backfilling ~1900 open gaps and flipping the
`postgres-backend` feature on across the fleet) is the INFRA-2092 migration — a
separate, deliberate change with its own backfill and verification, **not** an
env-var flip. Until it lands, SQLite stays canonical.

## How to verify single-source (run these)

Runtime (against the live fleet):

```
scripts/coord/gap-store-single-source-check.sh
```
Asserts (A) `chump gap list` open-count == `state.db` open-count, and (B) the
PostgREST store is empty/unreachable (dormant) or — if non-empty — does not
diverge from `state.db`. Exits non-zero on any split-brain. Example green run:

```
canonical(sqlite state.db) open = 1946
CLI (chump gap list)      open = 1946
OK(A): CLI and canonical store agree (1946 open)
postgrest(shared_gaps) reachable, rows = 0 (dormant backend)
OK(B): postgrest is dormant (empty) — not a competing source of truth
RESULT: single source of truth confirmed (sqlite state.db)
```

Structural (in CI, every push — `scripts/ci/test-gap-store-single-source.sh`):
pins that `postgres-backend` stays opt-in, that the default store path is
`.chump/state.db`, and that no crate silently redirects the store via
`CHUMP_GAP_STORE_URL`. This is the enforced-and-watched half — it makes the
split-brain impossible to reintroduce by accident.

## If you ever DO wire PostgREST as canonical (INFRA-2092)

1. Backfill `shared_gaps` from `state.db` (all statuses, not just open).
2. Point the runtime guard's (B) check at parity, not emptiness.
3. Flip `postgres-backend` on deliberately, with the migration — update this
   doc and the CI test in the same change.
