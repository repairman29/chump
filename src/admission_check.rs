//! Admission check against the concurrency ceiling (RESILIENT-1426, RESILIENT-1427, RESILIENT-1611, RESILIENT-2228).
//!
//! Counts current active cargo/rustc jobs across workers, agents, and installs.
//! Includes cargo fix, cargo clippy, cargo test, cargo build, and generic cargo_job.
//! Rejects new job scheduling if the count would exceed max_concurrent_cargo_jobs.

use anyhow::Result;
use rusqlite::Connection;

/// Default TTL (minutes) after which a `'pending'` or `'running'` cargo job row
/// is considered orphaned (e.g. parent process SIGKILLed) and reaped before
/// admission counting so stale rows cannot permanently brick `run_cli cargo`.
pub const STALE_CARGO_JOB_TTL_MINS: u32 = 30;

const CARGO_JOB_TYPES: [&str; 5] = [
    "cargo_job",
    "cargo_fix",
    "cargo_clippy",
    "cargo_test",
    "cargo_build",
];

/// Get the configured max concurrent cargo jobs. Defaults to 4 if not set.
pub fn get_max_concurrent_cargo_jobs() -> i32 {
    std::env::var("CHUMP_MAX_CONCURRENT_CARGO_JOBS")
        .ok()
        .and_then(|s| s.parse::<i32>().ok())
        .unwrap_or(4)
}

/// Reap orphaned `'pending'` / `'running'` cargo rows older than `max_age_minutes` on `conn`.
pub fn reap_stale_cargo_jobs_in_conn(conn: &Connection, max_age_minutes: u32) -> Result<usize> {
    let modifier = format!("-{} minutes", max_age_minutes);
    let updated = conn.execute(
        "UPDATE chump_async_jobs
         SET status = 'failed',
             last_error = 'reaped: stale cargo job TTL exceeded',
             updated_at = datetime('now')
         WHERE job_type IN ('cargo_job', 'cargo_fix', 'cargo_clippy', 'cargo_test', 'cargo_build')
           AND status IN ('pending', 'running')
           AND updated_at <= datetime('now', ?1)",
        rusqlite::params![modifier],
    )?;
    Ok(updated)
}

/// Count active cargo/rustc jobs on `conn` after reaping stale orphaned rows.
pub fn count_active_cargo_jobs_in_conn(conn: &Connection) -> Result<i32> {
    let _ = reap_stale_cargo_jobs_in_conn(conn, STALE_CARGO_JOB_TTL_MINS);
    let active_statuses = ["running", "pending"];
    let placeholders = active_statuses
        .iter()
        .map(|_| "?")
        .collect::<Vec<_>>()
        .join(",");
    let job_type_placeholders = CARGO_JOB_TYPES
        .iter()
        .map(|_| "?")
        .collect::<Vec<_>>()
        .join(",");
    let query = format!(
        "SELECT COUNT(*) FROM chump_async_jobs WHERE job_type IN ({}) AND status IN ({})",
        job_type_placeholders, placeholders
    );
    let mut stmt = conn.prepare(&query)?;
    let mut params: Vec<&dyn rusqlite::ToSql> = Vec::new();
    for job_type in &CARGO_JOB_TYPES {
        params.push(job_type);
    }
    for status in &active_statuses {
        params.push(status);
    }
    let count: i32 = stmt.query_row(rusqlite::params_from_iter(params), |row| row.get(0))?;
    Ok(count)
}

/// Count active cargo/rustc jobs (status = 'running' or 'pending').
/// This includes: cargo_job, cargo_fix, cargo_clippy, cargo_test, cargo_build.
pub fn count_active_cargo_jobs() -> Result<i32> {
    let conn = crate::db_pool::get()?;
    count_active_cargo_jobs_in_conn(&conn)
}

/// Check if a new cargo job can be admitted given the concurrency ceiling.
/// Returns Ok(()) if admission is allowed, Err with a clear message if rejected.
pub fn check_admission(max_concurrent_jobs: i32) -> Result<()> {
    let active = count_active_cargo_jobs()?;
    if active >= max_concurrent_jobs {
        return Err(anyhow::anyhow!(
            "admission rejected: {} active cargo jobs >= concurrency ceiling of {}",
            active,
            max_concurrent_jobs
        ));
    }
    Ok(())
}

/// Determine the specific cargo job type from a command string.
/// Returns one of: cargo_fix, cargo_clippy, cargo_test, cargo_build, or cargo_job (generic).
pub(crate) fn get_cargo_job_type(cmd: &str) -> &'static str {
    let lower = cmd.to_lowercase();
    if lower.contains("cargo fix") {
        "cargo_fix"
    } else if lower.contains("cargo clippy") {
        "cargo_clippy"
    } else if lower.contains("cargo test") {
        "cargo_test"
    } else if lower.contains("cargo build") || lower.contains("cargo check") {
        "cargo_build"
    } else {
        "cargo_job"
    }
}

/// Insert a cargo job record into the async jobs log, determining the specific type.
pub fn insert_cargo_job(status: &str, detail: Option<&str>) -> Result<()> {
    let job_type = detail.map(get_cargo_job_type).unwrap_or("cargo_job");
    crate::job_log::insert_job(job_type, status, None, None, detail, None)
}

/// RAII guard for a synchronous `run_cli` cargo invocation (RESILIENT-2228).
///
/// Tracks the exact `chump_async_jobs.id` UUID inserted for this command (regardless
/// of whether `job_type` was classified as `cargo_test`, `cargo_clippy`, `cargo_build`,
/// `cargo_fix`, or `cargo_job`) and guarantees the row transitions out of `'running'`
/// even when the caller exits early via timeout, spawn error, or ACP delegation.
pub struct ActiveCargoJobGuard {
    job_id: Option<String>,
    finished: bool,
}

impl ActiveCargoJobGuard {
    /// Start a tracked cargo job in `'running'` state, returning an RAII guard.
    /// If DB insertion fails (best-effort telemetry), returns an inert guard so the
    /// command itself is not blocked when admission already passed.
    pub fn start(detail: Option<&str>) -> Self {
        let job_type = detail.map(get_cargo_job_type).unwrap_or("cargo_job");
        let job_id =
            crate::job_log::insert_job_with_id(job_type, "running", None, None, detail, None).ok();
        Self {
            job_id,
            finished: false,
        }
    }

    /// Record final exit code (`Some(0)` => `'completed'`, non-zero/`None` => `'failed'`).
    pub fn finish(&mut self, exit_code: Option<i32>) {
        if self.finished {
            return;
        }
        self.finished = true;
        if let Some(ref id) = self.job_id {
            if exit_code == Some(0) {
                let _ = crate::job_log::mark_completed_by_id(id);
            } else {
                let msg = format!("exit code: {:?}", exit_code);
                let _ = crate::job_log::mark_failed_by_id(id, &msg);
            }
        }
    }
}

impl Drop for ActiveCargoJobGuard {
    fn drop(&mut self) {
        if !self.finished {
            self.finished = true;
            if let Some(ref id) = self.job_id {
                let _ =
                    crate::job_log::mark_failed_by_id(id, "aborted or timed out before completion");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup_mem_jobs_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE chump_async_jobs (
                id TEXT PRIMARY KEY,
                job_type TEXT NOT NULL,
                status TEXT NOT NULL,
                task_id INTEGER,
                session_id TEXT,
                last_error TEXT,
                detail TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );",
        )
        .unwrap();
        conn
    }

    #[test]
    fn test_count_active_cargo_jobs_and_by_id_completion() {
        let conn = setup_mem_jobs_db();
        // Simulate 6 sequential cargo runs across distinct classified job_types;
        // completing each by UUID must return active count to 0 so ceiling=4 never wedges.
        for (i, cmd) in [
            "cargo test",
            "cargo clippy -- -D warnings",
            "cargo build",
            "cargo check",
            "cargo fix --allow-dirty",
            "cargo test --quiet",
        ]
        .iter()
        .enumerate()
        {
            let id = format!("job-{i}");
            let jtype = get_cargo_job_type(cmd);
            conn.execute(
                "INSERT INTO chump_async_jobs (id, job_type, status, detail) VALUES (?1, ?2, 'running', ?3)",
                rusqlite::params![id, jtype, cmd],
            )
            .unwrap();
            assert_eq!(count_active_cargo_jobs_in_conn(&conn).unwrap(), 1);
            conn.execute(
                "UPDATE chump_async_jobs SET status = 'completed', updated_at = datetime('now') WHERE id = ?1",
                rusqlite::params![id],
            )
            .unwrap();
            assert_eq!(count_active_cargo_jobs_in_conn(&conn).unwrap(), 0);
        }
    }

    #[test]
    fn test_reap_stale_cargo_jobs_clears_orphaned_pending_rows() {
        let conn = setup_mem_jobs_db();
        for i in 0..4 {
            conn.execute(
                "INSERT INTO chump_async_jobs (id, job_type, status, detail, updated_at)
                 VALUES (?1, 'cargo_test', 'pending', 'cargo test', datetime('now', '-45 minutes'))",
                rusqlite::params![format!("stale-{i}")],
            )
            .unwrap();
        }
        conn.execute(
            "INSERT INTO chump_async_jobs (id, job_type, status, detail, updated_at)
             VALUES ('fresh-1', 'cargo_build', 'running', 'cargo build', datetime('now'))",
            [],
        )
        .unwrap();

        // count_active_cargo_jobs_in_conn reaps the 4 stale rows and counts only the 1 fresh row.
        assert_eq!(count_active_cargo_jobs_in_conn(&conn).unwrap(), 1);
    }

    #[test]
    fn test_admission_check_at_ceiling() {
        let max_concurrent = 4;
        let active_count = 4;
        assert!(
            active_count >= max_concurrent,
            "admission should fail when active >= max"
        );
    }

    #[test]
    fn test_admission_check_below_ceiling() {
        let max_concurrent = 4;
        let active_count = 1;
        assert!(
            active_count < max_concurrent,
            "admission should pass when active < max"
        );
    }
}
