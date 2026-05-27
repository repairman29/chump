# chump-github-cache

Typed Rust replacement for the bash + Python GitHub cache stack. Phase 1 of
[INFRA-1999](../../docs/gaps/) under the [META-107 Rust-First Migration
Blueprint](../../docs/strategy/) umbrella.

## What this replaces

| Legacy surface | LOC | Role |
|---|---|---|
| `scripts/coord/lib/github_cache.sh` | 493 bash | Reader-side helpers (`cache_lookup_pr`, `cache_lookup_checks`, `cache_query_open_prs`, `cache_query_behind_prs`, etc.) over `.chump/github_cache.db`. |
| `scripts/ops/github-webhook-receiver.py` | 656 Python | Writer-side HTTP receiver: HMAC-verifies GitHub webhooks, UPSERTs `pr_state` / `check_runs`. |

Both keep running during Phase 1 — the bash callsites route through the
Rust CLI via a feature flag, and the Rust receiver binds a different port
from the Python receiver so the two can run in parallel during the
validation window.

## Phase 1 scope (what this PR ships)

1. **`GithubCache` trait** with the six read methods that match the bash
   `cache_*` helpers' surfaces:
   - `lookup_pr(number) -> Option<PrState>`
   - `lookup_checks(head_sha) -> Vec<CheckRun>`
   - `query_open_prs() -> Vec<PrSummary>`
   - `query_open_prs_by_title(substring) -> Vec<PrSummary>`
   - `query_behind_prs() -> Vec<u64>`
   - `lookup_pr_files(number) -> Vec<String>` (Phase 1 stub — bash also
     falls back to REST since the schema doesn't store files yet).
2. **`SqliteCache` concrete impl** backed by `.chump/github_cache.db`.
   Uses `rusqlite` with parameter-binding (`?1`, `?2`) for every user
   input — eliminates the `sqlite3` CLI escape bug class.
3. **`chump-github-cache-cli` binary** that mirrors the bash helpers'
   argv surface:
   ```
   chump-github-cache-cli lookup-pr <N>
   chump-github-cache-cli lookup-checks <HEAD_SHA>
   chump-github-cache-cli query-open-prs
   chump-github-cache-cli query-behind-prs
   chump-github-cache-cli refresh-open-prs   # Phase 1 stub (no REST refill)
   ```
4. **`chump-webhook-receiver` binary** — axum HTTP server with HMAC-SHA256
   signature verification (`X-Hub-Signature-256` matching the Python
   receiver). Routes `pull_request`, `check_run`, `workflow_run` event
   types into UPSERTs against the same SQLite DB.
   - Default port: 9876 (Python defaults to 9097 — different ports so
     both can run during validation).
5. **Bash shim** — `scripts/coord/lib/github_cache.sh` gets a
   feature-flag block at the top that selects the Rust CLI when
   `CHUMP_GITHUB_CACHE_RUST=1`. The legacy 493-LOC bash body is
   **preserved untouched** below the flag block.
6. **Smoke test** — `scripts/ci/test-github-cache-rust-parity.sh`
   exercises both code paths against synthetic PR rows and asserts
   identical output, plus SQL-injection-shape inputs (titles containing
   `; DROP TABLE`, `' OR 1=1`, quote chars) are escaped via the
   `rusqlite` parameter binding.

## Phase 1 explicit non-goals (follow-up sub-gaps)

- Decommissioning the Python receiver. It stays running on its port.
- DNS/proxy cutover so smee.io routes to the Rust receiver.
- Migrating `scripts/coord/queue-driver.sh` + other bash callsites away
  from the shim — they keep using `cache_lookup_pr` etc; the feature
  flag routes them transparently.
- The REST bulk-refill loop in `refresh-open-prs`. The CLI command
  returns immediately in Phase 1.
- Auth/HMAC-secret rotation infrastructure. Single static
  `CHUMP_WEBHOOK_SECRET` is enough.
- **No new ambient event kinds.** This crate does not write to
  `.chump-locks/ambient.jsonl` at all — the bash legacy body still
  emits the existing `cache_hit` / `cache_miss` / `cache_refilled`
  events when the feature flag is OFF.

## Feature flag

```bash
# Default: legacy bash path (Phase 1 parallel-run)
cache_lookup_pr 1234

# Opt into Rust path
CHUMP_GITHUB_CACHE_RUST=1 cache_lookup_pr 1234
```

## Why sqlx is NOT a dependency yet

The brief mentioned `sqlx::query!` (compile-time-checked queries) but
those require a `DATABASE_URL` at compile time or a checked-in `.sqlx`
offline-mode cache. Neither exists in this workspace today, and
introducing either is a meaningful infrastructure step outside the
Phase 1 ship scope. Phase 1 uses `rusqlite` (already a workspace
dependency in the root crate) with `?` parameter binding for the same
SQL-injection-immunity property; a follow-up sub-gap can migrate to
sqlx when the offline-cache infrastructure lands.

## Sibling discipline pattern

This crate follows the same Phase 1 recipe as:

- [`chump-git-hooks`](../chump-git-hooks/) (INFRA-1997 / #2605) —
  trait + ONE concrete impl + smoke test + bash shim, no event-kind
  adds, parallel-run via feature flag.
- [`chump-messaging`](../chump-messaging/) (INFRA-1998 / #2611) —
  Broker trait + FileBroker + 2 CLI shims + smoke parity test.
