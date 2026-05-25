//! # chump-github-cache
//!
//! Typed Rust replacement for the bash + Python GitHub cache stack.
//! Phase 1 of INFRA-1999 / META-107 (Rust-First Migration Blueprint).
//!
//! ## Replaces
//!
//! - `scripts/coord/lib/github_cache.sh` (493 LOC bash) — reader-side
//!   helpers. The bash file gets a feature-flag header that routes
//!   through the [`crate::SqliteCache`] (via the
//!   `chump-github-cache-cli` binary) when `CHUMP_GITHUB_CACHE_RUST=1`.
//!   The legacy 493 LOC bash body is preserved untouched below the flag.
//! - `scripts/ops/github-webhook-receiver.py` (656 LOC Python Flask /
//!   stdlib http.server) — writer-side. The
//!   [`crate::webhook`] module exposes an axum router that the
//!   `chump-webhook-receiver` binary mounts on
//!   `$CHUMP_WEBHOOK_RUST_PORT` (default 9876, intentionally different
//!   from the Python receiver's 9097 so both can run side-by-side
//!   during 1-week validation).
//!
//! ## Phase 1 scope
//!
//! 1. [`GithubCache`] trait + [`SqliteCache`] concrete impl over
//!    `.chump/github_cache.db`.
//! 2. Six read methods matching the bash `cache_*` helpers'
//!    surfaces (see trait docs).
//! 3. `chump-github-cache-cli` binary that matches the bash helpers'
//!    argv surface 1:1.
//! 4. `chump-webhook-receiver` binary — axum HTTP server with
//!    HMAC-SHA256 verification of the GitHub `X-Hub-Signature-256`
//!    header. Routes `pull_request`, `check_run`, `workflow_run` event
//!    types to UPSERTs against the same SQLite DB.
//! 5. Smoke test `scripts/ci/test-github-cache-rust-parity.sh` exercises
//!    both code paths and asserts identical output, plus
//!    SQL-injection-shape inputs are escaped via `rusqlite` parameter
//!    binding (eliminating the `sqlite3` CLI escape bug class).
//!
//! ## Non-goals (Phase 1)
//!
//! - **NO new ambient event kinds.** This crate does not write to
//!   `.chump-locks/ambient.jsonl` at all. INFRA-2003 holds a lease on
//!   `scripts/ci/event-registry-reserved.txt`; INFRA-2020 holds one on
//!   `docs/observability/EVENT_REGISTRY.yaml`. Neither file is touched
//!   by this PR. The legacy bash body still emits the existing
//!   `cache_hit` / `cache_miss` / `cache_refilled` events when the
//!   feature flag is OFF.
//! - **NO cutover.** The Python receiver keeps running. Phase 2
//!   (separate gap) flips the smee.io target to the Rust receiver's
//!   port and decommissions Python.
//! - **NO bulk-refill REST loop in `refresh-open-prs`.** Stub returns
//!   immediately in Phase 1; real refill comes in a follow-up sub-gap.
//!
//! ## Why rusqlite, not sqlx
//!
//! The brief mentioned `sqlx::query!` for compile-time-checked queries
//! but those require a `DATABASE_URL` env at compile time or an
//! offline-mode `.sqlx` cache checked into the workspace. Neither
//! exists today, and introducing either is its own infrastructure step.
//! Phase 1 uses `rusqlite` (already a workspace dependency in the root
//! `chump` crate) with `?` parameter binding — same
//! SQL-injection-immunity property, no new build dependencies. A
//! follow-up sub-gap can migrate to sqlx once the offline cache lands.

#![warn(missing_docs)]

pub mod error;
pub mod schema;
pub mod webhook;

use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension};

pub use error::CacheError;
pub use schema::{CheckRun, PrState, PrSummary};

/// SQL schema embedded at compile time.
///
/// Applied idempotently in [`SqliteCache::open`]; safe to run against
/// existing DBs that already have the tables (uses `CREATE TABLE IF NOT
/// EXISTS`).
const SCHEMA_SQL: &str = include_str!("../migrations/001_initial_schema.sql");

/// Reader-side GitHub cache surface.
///
/// All methods read from `.chump/github_cache.db` (the Python webhook
/// receiver and the bash legacy `cache_*` helpers all write there).
/// Phase 1 is read-only — writes go through the
/// [`crate::webhook::WebhookHandler`] used by `chump-webhook-receiver`.
///
/// The six methods match 1:1 the bash helpers in
/// `scripts/coord/lib/github_cache.sh` that callers depend on.
#[async_trait::async_trait]
pub trait GithubCache: Send + Sync {
    /// Fetch one PR row by number.
    ///
    /// Returns `Ok(None)` on cache miss (no row with this number);
    /// returns `Ok(Some(...))` on hit regardless of staleness. The
    /// caller is responsible for TTL checks if it cares — the bash
    /// helper checks `fetched_at_local` against `CHUMP_CACHE_TTL_S`
    /// for the same purpose.
    async fn lookup_pr(&self, number: u64) -> Result<Option<PrState>, CacheError>;

    /// Look up all check_runs for one head SHA.
    ///
    /// Returns sorted ASC by check-name. Empty Vec on cache miss.
    async fn lookup_checks(&self, head_sha: &str) -> Result<Vec<CheckRun>, CacheError>;

    /// List all open PRs (`merged_at IS NULL`).
    ///
    /// Returns rows ordered by `number DESC` (matches the bash helper's
    /// `ORDER BY number DESC`).
    async fn query_open_prs(&self) -> Result<Vec<PrSummary>, CacheError>;

    /// List open PRs whose title contains `substring` (case-insensitive).
    ///
    /// Implemented as a parameter-bound `LOWER(title) LIKE LOWER(?)`
    /// query — the substring is wrapped in `%...%` inside the impl,
    /// caller passes the raw text. SQL-injection-immune.
    async fn query_open_prs_by_title(&self, substring: &str) -> Result<Vec<PrSummary>, CacheError>;

    /// List PR numbers in BEHIND + auto_merge_enabled state.
    ///
    /// Returns sorted ASC by number — matches the bash
    /// `cache_query_behind_prs` output. Used by `queue-driver.sh`.
    async fn query_behind_prs(&self) -> Result<Vec<u64>, CacheError>;

    /// Look up files changed by a PR.
    ///
    /// Phase 1 stub: the underlying schema does NOT store file paths
    /// (no webhook event populates them). The bash helper falls back
    /// to a REST call; the Rust impl returns an empty Vec for now.
    /// A follow-up sub-gap will extend `pr_state` with a `files_csv`
    /// column and populate it from the receiver.
    async fn lookup_pr_files(&self, number: u64) -> Result<Vec<String>, CacheError>;
}

/// Concrete [`GithubCache`] impl backed by SQLite via `rusqlite`.
///
/// Uses `?N` parameter binding for every user input — eliminates the
/// `sqlite3` CLI escape bug class behind the bash callsites.
///
/// Phase 1 owns one synchronous [`rusqlite::Connection`] guarded by a
/// `std::sync::Mutex`. Throughput is not a concern for the current
/// callsite mix (a handful of cache reads per fleet cycle); a future
/// follow-up can swap to a connection pool or sqlx-async once a real
/// hot path emerges.
pub struct SqliteCache {
    /// Path the cache was opened from (kept for diagnostics).
    pub db_path: PathBuf,
    conn: std::sync::Mutex<Connection>,
}

impl std::fmt::Debug for SqliteCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SqliteCache")
            .field("db_path", &self.db_path)
            .finish_non_exhaustive()
    }
}

impl SqliteCache {
    /// Open / create the cache at `path` and apply the initial schema
    /// idempotently.
    ///
    /// Creates parent directories as needed. If the DB already exists
    /// with an older schema (no `merge_state_status` column), this call
    /// is a no-op for that column — Phase 1 reads tolerate a NULL
    /// `merge_state_status`. The legacy Python receiver `ALTER TABLE`s
    /// the column in on startup.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, CacheError> {
        let db_path = path.as_ref().to_path_buf();
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(&db_path)?;
        conn.execute_batch(SCHEMA_SQL)?;
        Ok(Self {
            db_path,
            conn: std::sync::Mutex::new(conn),
        })
    }

    /// Open an in-memory SQLite for tests.
    #[doc(hidden)]
    pub fn open_in_memory() -> Result<Self, CacheError> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(SCHEMA_SQL)?;
        Ok(Self {
            db_path: PathBuf::from(":memory:"),
            conn: std::sync::Mutex::new(conn),
        })
    }

    /// Write-side helper used by the webhook receiver and by tests.
    ///
    /// UPSERTs the given PR row by `number`. The `raw_payload_json`
    /// field is whatever the caller wants to store (typically the raw
    /// body as received from GitHub).
    pub fn upsert_pr(&self, pr: &PrState) -> Result<(), CacheError> {
        let conn = self.conn.lock().expect("cache mutex poisoned");
        conn.execute(
            "INSERT INTO pr_state ( \
             number, head_ref, head_sha, base_ref, base_sha, \
             mergeable_state, auto_merge_enabled, draft, merged_at, \
             title, user_login, updated_at_api, fetched_at_local, \
             raw_payload_json, merge_state_status \
             ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15) \
             ON CONFLICT(number) DO UPDATE SET \
             head_ref=excluded.head_ref, head_sha=excluded.head_sha, \
             base_ref=excluded.base_ref, base_sha=excluded.base_sha, \
             mergeable_state=excluded.mergeable_state, \
             auto_merge_enabled=excluded.auto_merge_enabled, \
             draft=excluded.draft, merged_at=excluded.merged_at, \
             title=excluded.title, user_login=excluded.user_login, \
             updated_at_api=excluded.updated_at_api, \
             fetched_at_local=excluded.fetched_at_local, \
             raw_payload_json=excluded.raw_payload_json, \
             merge_state_status=excluded.merge_state_status",
            params![
                pr.number as i64,
                pr.head_ref,
                pr.head_sha,
                pr.base_ref,
                pr.base_sha,
                pr.mergeable_state,
                pr.auto_merge_enabled as i64,
                pr.draft as i64,
                pr.merged_at,
                pr.title,
                pr.user_login,
                pr.updated_at_api,
                pr.fetched_at_local,
                pr.raw_payload_json,
                pr.merge_state_status,
            ],
        )?;
        Ok(())
    }

    /// Write-side helper for check_runs.
    pub fn upsert_check_run(&self, run: &CheckRun) -> Result<(), CacheError> {
        let conn = self.conn.lock().expect("cache mutex poisoned");
        conn.execute(
            "INSERT INTO check_runs ( \
             head_sha, name, status, conclusion, \
             started_at, completed_at, fetched_at_local \
             ) VALUES (?1,?2,?3,?4,?5,?6,?7) \
             ON CONFLICT(head_sha, name) DO UPDATE SET \
             status=excluded.status, \
             conclusion=excluded.conclusion, \
             started_at=excluded.started_at, \
             completed_at=excluded.completed_at, \
             fetched_at_local=excluded.fetched_at_local",
            params![
                run.head_sha,
                run.name,
                run.status,
                run.conclusion,
                run.started_at,
                run.completed_at,
                run.fetched_at_local,
            ],
        )?;
        Ok(())
    }
}

fn row_to_pr_state(row: &rusqlite::Row<'_>) -> rusqlite::Result<PrState> {
    Ok(PrState {
        number: row.get::<_, i64>(0)? as u64,
        head_ref: row.get(1)?,
        head_sha: row.get(2)?,
        base_ref: row.get(3)?,
        base_sha: row.get(4)?,
        mergeable_state: row.get(5)?,
        auto_merge_enabled: row.get::<_, i64>(6)? != 0,
        draft: row.get::<_, i64>(7)? != 0,
        merged_at: row.get(8)?,
        title: row.get(9)?,
        user_login: row.get(10)?,
        updated_at_api: row.get(11)?,
        fetched_at_local: row.get(12)?,
        raw_payload_json: row.get(13)?,
        merge_state_status: row.get(14).ok(),
    })
}

fn row_to_pr_summary(row: &rusqlite::Row<'_>) -> rusqlite::Result<PrSummary> {
    let title: Option<String> = row.get(1)?;
    let head_ref: Option<String> = row.get(2)?;
    Ok(PrSummary {
        number: row.get::<_, i64>(0)? as u64,
        title: title.unwrap_or_default(),
        head_ref: head_ref.unwrap_or_default(),
    })
}

fn row_to_check_run(row: &rusqlite::Row<'_>) -> rusqlite::Result<CheckRun> {
    Ok(CheckRun {
        head_sha: row.get(0)?,
        name: row.get(1)?,
        status: row.get(2)?,
        conclusion: row.get(3)?,
        started_at: row.get(4)?,
        completed_at: row.get(5)?,
        fetched_at_local: row.get(6)?,
    })
}

#[async_trait::async_trait]
impl GithubCache for SqliteCache {
    async fn lookup_pr(&self, number: u64) -> Result<Option<PrState>, CacheError> {
        let conn = self.conn.lock().expect("cache mutex poisoned");
        let mut stmt = conn.prepare_cached(
            "SELECT number, head_ref, head_sha, base_ref, base_sha, \
             mergeable_state, auto_merge_enabled, draft, merged_at, \
             title, user_login, updated_at_api, fetched_at_local, \
             raw_payload_json, merge_state_status \
             FROM pr_state WHERE number = ?1",
        )?;
        let row = stmt
            .query_row(params![number as i64], row_to_pr_state)
            .optional()?;
        Ok(row)
    }

    async fn lookup_checks(&self, head_sha: &str) -> Result<Vec<CheckRun>, CacheError> {
        let conn = self.conn.lock().expect("cache mutex poisoned");
        let mut stmt = conn.prepare_cached(
            "SELECT head_sha, name, status, conclusion, \
             started_at, completed_at, fetched_at_local \
             FROM check_runs WHERE head_sha = ?1 ORDER BY name ASC",
        )?;
        let rows = stmt
            .query_map(params![head_sha], row_to_check_run)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    async fn query_open_prs(&self) -> Result<Vec<PrSummary>, CacheError> {
        let conn = self.conn.lock().expect("cache mutex poisoned");
        let mut stmt = conn.prepare_cached(
            "SELECT number, title, head_ref \
             FROM pr_state WHERE merged_at IS NULL ORDER BY number DESC",
        )?;
        let rows = stmt
            .query_map([], row_to_pr_summary)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    async fn query_open_prs_by_title(&self, substring: &str) -> Result<Vec<PrSummary>, CacheError> {
        // Wrap in % for LIKE; parameter binding handles all escape concerns,
        // INCLUDING the single-quote / "'; DROP TABLE pr_state; --" injection
        // class that the bash sqlite3-CLI helper had to defend against by hand.
        let needle = format!("%{}%", substring);
        let conn = self.conn.lock().expect("cache mutex poisoned");
        let mut stmt = conn.prepare_cached(
            "SELECT number, title, head_ref \
             FROM pr_state \
             WHERE merged_at IS NULL \
             AND LOWER(title) LIKE LOWER(?1) \
             ORDER BY number DESC",
        )?;
        let rows = stmt
            .query_map(params![needle], row_to_pr_summary)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    async fn query_behind_prs(&self) -> Result<Vec<u64>, CacheError> {
        let conn = self.conn.lock().expect("cache mutex poisoned");
        let mut stmt = conn.prepare_cached(
            "SELECT number FROM pr_state \
             WHERE mergeable_state = 'BEHIND' \
             AND auto_merge_enabled = 1 \
             AND merged_at IS NULL \
             ORDER BY number ASC",
        )?;
        let rows = stmt
            .query_map([], |r| Ok(r.get::<_, i64>(0)? as u64))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    async fn lookup_pr_files(&self, _number: u64) -> Result<Vec<String>, CacheError> {
        // Phase 1 stub. The schema does not store file lists yet; the
        // bash helper falls back to REST in this case. We deliberately
        // return Empty rather than panicking — callers see "no files
        // cached" and can choose to call REST themselves. A follow-up
        // sub-gap will add a `files_csv` column + receiver population
        // + a REST fallback inside this method.
        Ok(Vec::new())
    }
}

// ---- Tests --------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn make_pr(number: u64, title: &str, mergeable_state: &str, behind_armed: bool) -> PrState {
        PrState {
            number,
            head_ref: Some(format!("feature/{}", number)),
            head_sha: Some(format!("sha-{:040}", number)),
            base_ref: Some("main".to_string()),
            base_sha: Some("base-sha".to_string()),
            mergeable_state: Some(mergeable_state.to_string()),
            auto_merge_enabled: behind_armed,
            draft: false,
            merged_at: None,
            title: Some(title.to_string()),
            user_login: Some("alice".to_string()),
            updated_at_api: "2026-05-25T19:00:00Z".to_string(),
            fetched_at_local: "2026-05-25T19:01:00Z".to_string(),
            raw_payload_json: Some(format!("{{\"number\":{}}}", number)),
            merge_state_status: Some(mergeable_state.to_string()),
        }
    }

    #[tokio::test]
    async fn open_in_memory_creates_schema() {
        let cache = SqliteCache::open_in_memory().unwrap();
        // Empty cache returns empty lists, not errors.
        assert!(cache.query_open_prs().await.unwrap().is_empty());
        assert!(cache.query_behind_prs().await.unwrap().is_empty());
        assert!(cache.lookup_pr(42).await.unwrap().is_none());
        assert!(cache.lookup_checks("abc").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn upsert_and_lookup_pr_roundtrip() {
        let cache = SqliteCache::open_in_memory().unwrap();
        let pr = make_pr(123, "feat: thing", "clean", false);
        cache.upsert_pr(&pr).unwrap();
        let got = cache.lookup_pr(123).await.unwrap().expect("hit");
        assert_eq!(got.number, 123);
        assert_eq!(got.title.as_deref(), Some("feat: thing"));
        assert_eq!(got.mergeable_state.as_deref(), Some("clean"));
        assert!(!got.auto_merge_enabled);
    }

    #[tokio::test]
    async fn upsert_pr_is_idempotent_on_conflict() {
        let cache = SqliteCache::open_in_memory().unwrap();
        let mut pr = make_pr(7, "first", "clean", false);
        cache.upsert_pr(&pr).unwrap();
        pr.title = Some("second".to_string());
        pr.mergeable_state = Some("dirty".to_string());
        cache.upsert_pr(&pr).unwrap();
        let got = cache.lookup_pr(7).await.unwrap().unwrap();
        assert_eq!(got.title.as_deref(), Some("second"));
        assert_eq!(got.mergeable_state.as_deref(), Some("dirty"));
    }

    #[tokio::test]
    async fn query_open_prs_orders_desc_by_number() {
        let cache = SqliteCache::open_in_memory().unwrap();
        for n in [10u64, 5, 20, 1] {
            cache.upsert_pr(&make_pr(n, "x", "clean", false)).unwrap();
        }
        let rows = cache.query_open_prs().await.unwrap();
        let nums: Vec<u64> = rows.iter().map(|r| r.number).collect();
        assert_eq!(nums, vec![20, 10, 5, 1]);
    }

    #[tokio::test]
    async fn query_open_prs_filters_out_merged() {
        let cache = SqliteCache::open_in_memory().unwrap();
        let mut open = make_pr(1, "open", "clean", false);
        let mut merged = make_pr(2, "merged", "clean", false);
        merged.merged_at = Some("2026-05-25T18:00:00Z".to_string());
        cache.upsert_pr(&open).unwrap();
        cache.upsert_pr(&merged).unwrap();
        // Sanity: the open one stays returned.
        open.title = Some("still open".to_string());
        cache.upsert_pr(&open).unwrap();
        let rows = cache.query_open_prs().await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].number, 1);
    }

    #[tokio::test]
    async fn query_open_prs_by_title_case_insensitive() {
        let cache = SqliteCache::open_in_memory().unwrap();
        cache
            .upsert_pr(&make_pr(1, "feat(FOO): bar", "clean", false))
            .unwrap();
        cache
            .upsert_pr(&make_pr(2, "chore(baz): qux", "clean", false))
            .unwrap();
        let rows = cache.query_open_prs_by_title("foo").await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].number, 1);
        let rows = cache.query_open_prs_by_title("BAZ").await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].number, 2);
        let rows = cache.query_open_prs_by_title("nope").await.unwrap();
        assert!(rows.is_empty());
    }

    #[tokio::test]
    async fn query_open_prs_by_title_injection_safe() {
        let cache = SqliteCache::open_in_memory().unwrap();
        cache
            .upsert_pr(&make_pr(1, "innocent title", "clean", false))
            .unwrap();
        // Classic injection attempts: must NOT drop the table, must
        // simply return no matches.
        for payload in [
            "'; DROP TABLE pr_state; --",
            "' OR 1=1 --",
            "\\'; SELECT * FROM pr_state; --",
            "%' UNION SELECT * FROM check_runs --",
        ] {
            let rows = cache.query_open_prs_by_title(payload).await.unwrap();
            assert!(
                rows.is_empty(),
                "{payload} returned rows; injection-class regression"
            );
        }
        // Table still exists with the original row.
        let rows = cache.query_open_prs().await.unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[tokio::test]
    async fn query_behind_prs_filters_correctly() {
        let cache = SqliteCache::open_in_memory().unwrap();
        cache
            .upsert_pr(&make_pr(1, "behind+armed", "BEHIND", true))
            .unwrap();
        cache
            .upsert_pr(&make_pr(2, "behind+unarmed", "BEHIND", false))
            .unwrap();
        cache
            .upsert_pr(&make_pr(3, "clean+armed", "clean", true))
            .unwrap();
        let nums = cache.query_behind_prs().await.unwrap();
        assert_eq!(nums, vec![1]);
    }

    #[tokio::test]
    async fn lookup_checks_returns_sorted_by_name() {
        let cache = SqliteCache::open_in_memory().unwrap();
        for name in ["zeta", "alpha", "mu"] {
            cache
                .upsert_check_run(&CheckRun {
                    head_sha: "sha1".to_string(),
                    name: name.to_string(),
                    status: Some("completed".to_string()),
                    conclusion: Some("success".to_string()),
                    started_at: Some("2026-05-25T18:00:00Z".to_string()),
                    completed_at: Some("2026-05-25T18:05:00Z".to_string()),
                    fetched_at_local: "2026-05-25T18:06:00Z".to_string(),
                })
                .unwrap();
        }
        let rows = cache.lookup_checks("sha1").await.unwrap();
        let names: Vec<&str> = rows.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["alpha", "mu", "zeta"]);
    }

    #[tokio::test]
    async fn lookup_pr_files_phase1_stub_returns_empty() {
        let cache = SqliteCache::open_in_memory().unwrap();
        cache.upsert_pr(&make_pr(1, "x", "clean", false)).unwrap();
        let files = cache.lookup_pr_files(1).await.unwrap();
        assert!(files.is_empty(), "Phase 1 stub must return empty");
    }

    #[tokio::test]
    async fn schema_idempotent_across_opens() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("github_cache.db");
        // First open creates schema.
        {
            let cache = SqliteCache::open(&path).unwrap();
            cache.upsert_pr(&make_pr(1, "x", "clean", false)).unwrap();
        }
        // Second open should find the data + not recreate-and-blow-up.
        let cache = SqliteCache::open(&path).unwrap();
        let got = cache.lookup_pr(1).await.unwrap();
        assert!(got.is_some());
    }
}
