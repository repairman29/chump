//! INFRA-877: Cost quota enforcement — daily spend gate for `claude -p` spawns.
//!
//! Reads `CHUMP_DAILY_BUDGET_USD` and compares against today's spend
//! (from `ambient.jsonl` `session_end` events).
//!
//! - At ≥ 80% of budget → emits `kind=cost_quota_warning` to ambient.jsonl.
//! - At ≥ 100% of budget → emits `kind=cost_quota_exceeded`; spawn gated (returns `Err`).
//! - `budget_used_pct` is surfaced in `chump fleet doctor` output.
//!
//! Event fields (both kinds): ts, kind, gap_id, model, cost_so_far_usd, limit_usd.

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
/// * `gap_id`    – included in emitted event payload (required by AC)
/// * `model`     – included in emitted event payload (required by AC)
/// * `emit`      – if true, write event to ambient.jsonl on warning/exceeded
pub fn check_quota(repo_root: &Path, gap_id: &str, model: &str, emit: bool) -> QuotaStatus {
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
                    gap_id,
                    model,
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
                    gap_id,
                    model,
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
/// Fields: ts, kind, gap_id, model, cost_so_far_usd, limit_usd, budget_used_pct.
fn emit_event(
    repo_root: &Path,
    kind: &str,
    gap_id: &str,
    model: &str,
    spend_usd: f64,
    limit_usd: f64,
    pct: f64,
) {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let ts = utc_now_iso8601();
    let line = format!(
        r#"{{"ts":"{ts}","kind":"{kind}","gap_id":"{gap_id}","model":"{model}","cost_so_far_usd":{spend_usd:.6},"limit_usd":{limit_usd:.2},"budget_used_pct":{pct:.2}}}"#,
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
/// Does not emit events (read-only check).
pub fn doctor_line(repo_root: &Path) -> String {
    let status = check_quota(repo_root, "", "", false);
    let pct = status.budget_used_pct();
    let label = status.label();
    format!("budget_used_pct={pct:.1}%  status={label}")
}

fn utc_now_iso8601() -> String {
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
    use serial_test::serial;
    use std::io::Write;

    /// Write a `session_end` event whose cost equals `target_usd`.
    ///
    /// Uses `CHUMP_COST_INPUT_PER_MTK=1.0` (set by the serial-env wrapper) so
    /// cost = input_tokens / 1_000_000.  Callers must call `set_rate_env()` first.
    fn write_spend(dir: &std::path::Path, target_usd: f64) {
        let amb = dir.join(".chump-locks/ambient.jsonl");
        let _ = std::fs::create_dir_all(amb.parent().unwrap());
        let ts = super::utc_now_iso8601();
        let input_tokens = (target_usd * 1_000_000.0) as u64;
        let line = format!(
            r#"{{"ts":"{ts}","kind":"session_end","model":"test-model","input_tokens":{input_tokens},"output_tokens":0,"cache_read_tokens":0}}"#
        );
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&amb)
            .unwrap();
        writeln!(f, "{line}").unwrap();
    }

    fn set_rate_env() {
        std::env::set_var("CHUMP_COST_INPUT_PER_MTK", "1.0");
        std::env::set_var("CHUMP_COST_OUTPUT_PER_MTK", "0.0");
        std::env::set_var("CHUMP_COST_CACHE_READ_PER_MTK", "0.0");
    }

    fn clear_env() {
        std::env::remove_var("CHUMP_DAILY_BUDGET_USD");
        std::env::remove_var("CHUMP_COST_INPUT_PER_MTK");
        std::env::remove_var("CHUMP_COST_OUTPUT_PER_MTK");
        std::env::remove_var("CHUMP_COST_CACHE_READ_PER_MTK");
    }

    #[test]
    #[serial]
    fn quota_ok_at_50_pct() {
        set_rate_env();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        let dir = tempfile::tempdir().unwrap();
        write_spend(dir.path(), 5.0);
        let status = check_quota(dir.path(), "INFRA-877", "test-model", false);
        assert!(matches!(status, QuotaStatus::Ok { .. }), "got {:?}", status);
        assert!(
            (status.budget_used_pct() - 50.0).abs() < 1.0,
            "pct={}",
            status.budget_used_pct()
        );
        clear_env();
    }

    #[test]
    #[serial]
    fn quota_warning_at_80_pct() {
        set_rate_env();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        let dir = tempfile::tempdir().unwrap();
        write_spend(dir.path(), 8.0);
        let status = check_quota(dir.path(), "INFRA-877", "test-model", false);
        assert!(
            matches!(status, QuotaStatus::Warning { .. }),
            "got {:?}",
            status
        );
        assert!(
            (status.budget_used_pct() - 80.0).abs() < 1.0,
            "pct={}",
            status.budget_used_pct()
        );
        clear_env();
    }

    #[test]
    #[serial]
    fn quota_exceeded_at_100_pct() {
        set_rate_env();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        let dir = tempfile::tempdir().unwrap();
        write_spend(dir.path(), 10.0);
        let status = check_quota(dir.path(), "INFRA-877", "test-model", false);
        assert!(
            status.is_exceeded(),
            "expected Exceeded at 100%, got {:?}",
            status
        );
        clear_env();
    }

    #[test]
    #[serial]
    fn quota_exceeded_at_110_pct() {
        set_rate_env();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        let dir = tempfile::tempdir().unwrap();
        write_spend(dir.path(), 11.0);
        let status = check_quota(dir.path(), "INFRA-877", "test-model", false);
        assert!(
            status.is_exceeded(),
            "expected Exceeded at 110%, got {:?}",
            status
        );
        assert!(
            status.budget_used_pct() > 100.0,
            "pct={}",
            status.budget_used_pct()
        );
        clear_env();
    }

    #[test]
    #[serial]
    fn emit_warning_writes_required_fields() {
        set_rate_env();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        let dir = tempfile::tempdir().unwrap();
        write_spend(dir.path(), 8.5);
        check_quota(dir.path(), "INFRA-877", "claude-haiku", true);
        let content = std::fs::read_to_string(dir.path().join(".chump-locks/ambient.jsonl"))
            .unwrap_or_default();
        assert!(
            content.contains("cost_quota_warning"),
            "expected warning event in: {content}"
        );
        assert!(
            content.contains(r#""gap_id":"INFRA-877""#),
            "missing gap_id: {content}"
        );
        assert!(
            content.contains(r#""model":"claude-haiku""#),
            "missing model: {content}"
        );
        assert!(
            content.contains("cost_so_far_usd"),
            "missing cost_so_far_usd: {content}"
        );
        assert!(
            content.contains("limit_usd"),
            "missing limit_usd: {content}"
        );
        clear_env();
    }

    #[test]
    #[serial]
    fn emit_exceeded_writes_required_fields() {
        set_rate_env();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "1.0");
        let dir = tempfile::tempdir().unwrap();
        write_spend(dir.path(), 1.5);
        check_quota(dir.path(), "INFRA-TEST", "claude-sonnet", true);
        let content = std::fs::read_to_string(dir.path().join(".chump-locks/ambient.jsonl"))
            .unwrap_or_default();
        assert!(
            content.contains("cost_quota_exceeded"),
            "expected exceeded event in: {content}"
        );
        assert!(
            content.contains(r#""gap_id":"INFRA-TEST""#),
            "missing gap_id: {content}"
        );
        assert!(
            content.contains(r#""model":"claude-sonnet""#),
            "missing model: {content}"
        );
        clear_env();
    }

    #[test]
    #[serial]
    fn doctor_line_format() {
        set_rate_env();
        std::env::set_var("CHUMP_DAILY_BUDGET_USD", "10.0");
        let dir = tempfile::tempdir().unwrap();
        write_spend(dir.path(), 3.0);
        let line = doctor_line(dir.path());
        assert!(line.contains("budget_used_pct="), "got: {line}");
        assert!(line.contains("status=ok"), "got: {line}");
        clear_env();
    }
}
