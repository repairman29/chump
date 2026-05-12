//! INFRA-877: Cost quota enforcement — daily spend gate for `claude -p` spawns.
//!
//! Reads `CHUMP_DAILY_BUDGET_USD` (default $5.00/day) and compares against today's
//! spend (from `ambient.jsonl` `session_end` events).
//!
//! - At ≥ 80% of budget → emits `kind=cost_quota_warning` to ambient.jsonl.
//! - At ≥ 100% of budget → emits `kind=cost_quota_exceeded`; spawn gated (returns `Err`).
//! - `budget_used_pct` is surfaced in `chump fleet doctor` output.

use std::path::Path;

/// Quota check outcome.
#[derive(Debug, Clone, PartialEq)]
pub enum QuotaStatus {
    /// Spend < 80% of budget — proceed normally.
    Ok {
        spend_usd: f64,
        budget_usd: f64,
        budget_used_pct: f64,
    },
    /// Spend ≥ 80% but < 100% — emit warning, allow spawns.
    Warning {
        spend_usd: f64,
        budget_usd: f64,
        budget_used_pct: f64,
    },
    /// Spend ≥ 100% — emit exceeded event, block spawns.
    Exceeded {
        spend_usd: f64,
        budget_usd: f64,
        budget_used_pct: f64,
    },
}

impl QuotaStatus {
    pub fn budget_used_pct(&self) -> f64 {
        match self {
            QuotaStatus::Ok {
                budget_used_pct, ..
            } => *budget_used_pct,
            QuotaStatus::Warning {
                budget_used_pct, ..
            } => *budget_used_pct,
            QuotaStatus::Exceeded {
                budget_used_pct, ..
            } => *budget_used_pct,
        }
    }

    pub fn is_exceeded(&self) -> bool {
        matches!(self, QuotaStatus::Exceeded { .. })
    }

    pub fn label(&self) -> &'static str {
        match self {
            QuotaStatus::Ok { .. } => "ok",
            QuotaStatus::Warning { .. } => "warning",
            QuotaStatus::Exceeded { .. } => "exceeded",
        }
    }
}

/// Check daily quota using the existing cost-watch infrastructure.
///
/// Returns the quota status and optionally emits to `ambient.jsonl` when the
/// threshold is breached.  Pass `emit = false` in tests to suppress I/O.
///
/// # Arguments
/// * `repo_root` – repository root (for ambient.jsonl path)
/// * `emit`      – if true, write event to ambient.jsonl on warning/exceeded
pub fn check_quota(repo_root: &Path, emit: bool) -> QuotaStatus {
    let budget_usd = std::env::var("CHUMP_DAILY_BUDGET_USD")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(5.00_f64);

    let report = crate::cost_watch::build_report(repo_root, budget_usd);
    let spend = report.today_spend_usd;
    let pct = if budget_usd > 0.0 {
        spend / budget_usd * 100.0
    } else {
        0.0
    };

    let status = if spend >= budget_usd {
        QuotaStatus::Exceeded {
            spend_usd: spend,
            budget_usd,
            budget_used_pct: pct,
        }
    } else if spend >= budget_usd * 0.80 {
        QuotaStatus::Warning {
            spend_usd: spend,
            budget_usd,
            budget_used_pct: pct,
        }
    } else {
        QuotaStatus::Ok {
            spend_usd: spend,
            budget_usd,
            budget_used_pct: pct,
        }
    };

    if emit {
        match &status {
            QuotaStatus::Exceeded {
                spend_usd,
                budget_usd,
                budget_used_pct,
            } => {
                emit_event(
                    repo_root,
                    "cost_quota_exceeded",
                    *spend_usd,
                    *budget_usd,
                    *budget_used_pct,
                );
            }
            QuotaStatus::Warning {
                spend_usd,
                budget_usd,
                budget_used_pct,
            } => {
                emit_event(
                    repo_root,
                    "cost_quota_warning",
                    *spend_usd,
                    *budget_usd,
                    *budget_used_pct,
                );
            }
            _ => {}
        }
    }

    status
}

/// Write a cost quota event to `ambient.jsonl`.
fn emit_event(repo_root: &Path, kind: &str, spend_usd: f64, limit_usd: f64, pct: f64) {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let ts = utc_now_iso8601();
    let line = format!(
        r#"{{"ts":"{ts}","kind":"{kind}","cost_so_far_usd":{spend_usd:.6},"limit_usd":{limit_usd:.2},"budget_used_pct":{pct:.2}}}"#,
    );
    let _ = std::fs::create_dir_all(ambient.parent().unwrap_or(Path::new(".")));
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        use std::io::Write;
        let _ = writeln!(f, "{line}");
    }
}

/// Returns a one-line summary suitable for `chump fleet doctor`.
pub fn doctor_line(repo_root: &Path) -> String {
    let status = check_quota(repo_root, false);
    let pct = status.budget_used_pct();
    let label = status.label();
    format!("budget_used_pct={pct:.1}%  status={label}")
}

fn utc_now_iso8601() -> String {
    // Reuse the same approach as cost_watch.rs — seconds since epoch.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = unix_to_ymdhms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn unix_to_ymdhms(ts: u64) -> (u64, u64, u64, u64, u64, u64) {
    let s = ts % 60;
    let ts = ts / 60;
    let mi = ts % 60;
    let ts = ts / 60;
    let h = ts % 24;
    let ts = ts / 24;
    // Days since 1970-01-01
    let mut year = 1970u64;
    let mut days = ts;
    loop {
        let dy = if is_leap(year) { 366 } else { 365 };
        if days < dy {
            break;
        }
        days -= dy;
        year += 1;
    }
    let months = [
        31u64,
        if is_leap(year) { 29 } else { 28 },
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
    let mut month = 1u64;
    for &m in &months {
        if days < m {
            break;
        }
        days -= m;
        month += 1;
    }
    (year, month, days + 1, h, mi, s)
}

fn is_leap(y: u64) -> bool {
    y % 400 == 0 || (y % 4 == 0 && y % 100 != 0)
}

// ── Tests ─────────────────────────────────────────────────────────────────────
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_session_end(dir: &std::path::Path, cost_usd: f64) {
        let amb = dir.join(".chump-locks/ambient.jsonl");
        let _ = std::fs::create_dir_all(amb.parent().unwrap());
        let ts = super::utc_now_iso8601();
        let line = format!(
            r#"{{"ts":"{ts}","kind":"session_end","model":"claude-3-haiku-20240307","input_tokens":1000,"output_tokens":500,"cache_read_tokens":0,"cost_usd":{cost_usd:.6}}}"#
        );
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&amb)
            .unwrap();
        writeln!(f, "{line}").unwrap();
    }

    #[test]
    fn quota_ok_at_50_pct() {
        // Budget $10, spend $5 (50%)
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        write_session_end(dir.path(), 5.0);
        let status = check_quota(dir.path(), false);
        assert!(matches!(status, QuotaStatus::Ok { .. }), "got {:?}", status);
        assert!((status.budget_used_pct() - 50.0).abs() < 1.0);
        std::env::remove_var("CHUMP_DAILY_BUDGET_USD");
    }

    #[test]
    fn quota_warning_at_80_pct() {
        // Budget $10, spend $8 (80%)
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        write_session_end(dir.path(), 8.0);
        let status = check_quota(dir.path(), false);
        assert!(
            matches!(status, QuotaStatus::Warning { .. }),
            "got {:?}",
            status
        );
        std::env::remove_var("CHUMP_DAILY_BUDGET_USD");
    }

    #[test]
    fn quota_exceeded_at_110_pct() {
        // Budget $10, spend $11 (110%)
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        write_session_end(dir.path(), 11.0);
        let status = check_quota(dir.path(), false);
        assert!(status.is_exceeded(), "got {:?}", status);
        std::env::remove_var("CHUMP_DAILY_BUDGET_USD");
    }

    #[test]
    fn emit_writes_event_to_ambient() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "1.0");
        write_session_end(dir.path(), 1.5); // 150% — exceeded
        check_quota(dir.path(), true); // emit=true
        let content = std::fs::read_to_string(dir.path().join(".chump-locks/ambient.jsonl"))
            .unwrap_or_default();
        assert!(
            content.contains("cost_quota_exceeded"),
            "expected event in: {content}"
        );
        std::env::remove_var("CHUMP_DAILY_BUDGET_USD");
    }

    #[test]
    fn doctor_line_format() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        write_session_end(dir.path(), 3.0);
        let line = doctor_line(dir.path());
        assert!(line.contains("budget_used_pct="), "got: {line}");
        assert!(line.contains("status=ok"), "got: {line}");
        std::env::remove_var("CHUMP_DAILY_BUDGET_USD");
    }
}
