//! Persistent tracking of tool approval decisions for auto-approve rate metrics.
//!
//! Schema: `tool_approval_stats(day TEXT, tool TEXT, risk TEXT, decision TEXT, count INTEGER)`
//! where `day` is ISO date (YYYY-MM-DD), `decision` is one of:
//!   "auto_approved_low_risk" | "auto_approved_tools_env" | "policy_override_session"
//!   | "allowed" | "denied" | "timeout"
//!
//! Call `record_decision` after every approval gate decision.
//! Query `auto_approve_rate_today` for the AUTO-005 acceptance metric.

use anyhow::Result;

// Thread-local DB path for tests — avoids relying on set_current_dir which is
// process-global and races with other test threads that also change cwd.
#[cfg(test)]
thread_local! {
    static TEST_DB_FILE: std::cell::RefCell<std::path::PathBuf> = std::cell::RefCell::new(
        std::path::PathBuf::from("sessions/chump_memory.db")
    );
}

#[cfg(test)]
fn test_db_path() -> std::path::PathBuf {
    TEST_DB_FILE.with(|p| p.borrow().clone())
}

fn today() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let days = secs / 86400;

    chrono_days_to_iso(days)
}

/// Convert days-since-epoch to ISO date string (YYYY-MM-DD). Avoids pulling in chrono.
fn chrono_days_to_iso(days: u64) -> String {
    // Rata Die algorithm: epoch = 1970-01-01
    let mut remaining = days as i64;
    let mut year = 1970i64;
    loop {
        let days_in_year = if is_leap(year) { 366 } else { 365 };
        if remaining < days_in_year {
            break;
        }
        remaining -= days_in_year;
        year += 1;
    }
    let months = [
        31i64,
        28 + is_leap(year) as i64,
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut month = 1i64;
    for m in &months {
        if remaining < *m {
            break;
        }
        remaining -= m;
        month += 1;
    }
    format!("{:04}-{:02}-{:02}", year, month, remaining + 1)
}

fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn ensure_table(conn: &rusqlite::Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS tool_approval_stats (
            day      TEXT NOT NULL,
            tool     TEXT NOT NULL,
            risk     TEXT NOT NULL,
            decision TEXT NOT NULL,
            count    INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, tool, risk, decision)
        );",
    )?;
    Ok(())
}

/// Record one approval gate outcome. `decision` values match `log_tool_approval_audit`.
pub fn record_decision(tool: &str, risk: &str, decision: &str) {
    let day = today();
    let _ = record_decision_inner(&day, tool, risk, decision);
}

fn record_decision_inner(day: &str, tool: &str, risk: &str, decision: &str) -> Result<()> {
    #[cfg(not(test))]
    let conn = crate::db_pool::get()?;
    #[cfg(test)]
    let conn = {
        let path = test_db_path();
        if let Some(p) = path.parent() {
            let _ = std::fs::create_dir_all(p);
        }
        rusqlite::Connection::open(&path)?
    };

    ensure_table(&conn)?;
    conn.execute(
        "INSERT INTO tool_approval_stats (day, tool, risk, decision, count)
         VALUES (?1, ?2, ?3, ?4, 1)
         ON CONFLICT(day, tool, risk, decision) DO UPDATE SET count = count + 1",
        rusqlite::params![day, tool, risk, decision],
    )?;
    Ok(())
}

/// Fraction of today's approval gate decisions that were auto-approved (not awaiting human input).
/// Returns None when no decisions have been recorded yet today.
pub fn auto_approve_rate_today() -> Option<f64> {
    auto_approve_rate_for_day(&today())
}

fn auto_approve_rate_for_day(day: &str) -> Option<f64> {
    #[cfg(not(test))]
    let conn = crate::db_pool::get().ok()?;
    #[cfg(test)]
    let conn = {
        let path = test_db_path();
        rusqlite::Connection::open(&path).ok()?
    };

    ensure_table(&conn).ok()?;

    let total: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(count), 0) FROM tool_approval_stats WHERE day = ?1",
            rusqlite::params![day],
            |r| r.get(0),
        )
        .ok()?;

    if total == 0 {
        return None;
    }

    let auto: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(count), 0) FROM tool_approval_stats
             WHERE day = ?1 AND decision IN (
                 'auto_approved_low_risk', 'auto_approved_tools_env',
                 'policy_override_session', 'auto_approved_static_low_risk'
             )",
            rusqlite::params![day],
            |r| r.get(0),
        )
        .ok()?;

    Some(auto as f64 / total as f64)
}

/// JSON summary for `/api/stack-status` diagnostics.
pub fn approval_stats_for_stack_status() -> serde_json::Value {
    let rate = auto_approve_rate_today();
    serde_json::json!({
        "auto_approve_rate_today": rate,
        "tracked_in_db": true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    /// Returns a fresh unique temp dir for the test + pins TEST_DB_FILE to
    /// the sessions/chump_memory.db inside it. Uses a UUID (not
    /// `subsec_nanos()`) so two tests starting in the same nanosecond —
    /// plausible on fast CI runners — still get distinct dirs.
    ///
    /// Returns a `TempDir` guard so the dir + its contents are auto-
    /// cleaned when the test returns (no lingering `/tmp/chump_*` dirs).
    fn setup_temp_db() -> tempfile::TempDir {
        let dir = tempfile::Builder::new()
            .prefix("chump_approval_stats_test_")
            .tempdir()
            .expect("tempdir");
        let sessions = dir.path().join("sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        // Pin the thread-local DB path — avoids relying on set_current_dir
        // (process-global) which would race with any sibling test that
        // changes cwd. Tests using `#[serial]` wouldn't need this, but the
        // thread-local makes this module's tests also safe to mix with
        // threaded-but-non-serial code in the future.
        TEST_DB_FILE.with(|p| *p.borrow_mut() = sessions.join("chump_memory.db"));
        dir
    }

    #[test]
    #[serial]
    fn record_and_rate_auto_approved() {
        let _dir = setup_temp_db();
        let day = "2099-01-01";
        record_decision_inner(day, "read_file", "low", "auto_approved_static_low_risk").unwrap();
        record_decision_inner(day, "read_file", "low", "auto_approved_static_low_risk").unwrap();
        record_decision_inner(day, "run_cli", "low", "allowed").unwrap();
        let rate = auto_approve_rate_for_day(day).unwrap();
        // 2 auto out of 3 total = 0.666...
        assert!((rate - 2.0 / 3.0).abs() < 1e-9, "rate={rate}");
    }

    #[test]
    #[serial]
    fn rate_none_when_no_data() {
        let _dir = setup_temp_db();
        assert!(auto_approve_rate_for_day("2000-01-01").is_none());
    }

    #[test]
    fn today_iso_format() {
        let d = today();
        assert!(d.len() == 10, "expected YYYY-MM-DD, got {d}");
        assert_eq!(&d[4..5], "-");
        assert_eq!(&d[7..8], "-");
    }

    #[test]
    fn chrono_days_known_dates() {
        // 1970-01-01 = day 0
        assert_eq!(chrono_days_to_iso(0), "1970-01-01");
        // 1970-01-31 = day 30
        assert_eq!(chrono_days_to_iso(30), "1970-01-31");
        // 1970-02-28 = day 58
        assert_eq!(chrono_days_to_iso(58), "1970-02-28");
        // 1972-02-29 = leap year; day 789
        assert_eq!(chrono_days_to_iso(789), "1972-02-29");
    }
}
