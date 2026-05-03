//! INFRA-269 — `chump cascade stats` subcommand.
//!
//! Per-provider summary of cascade traffic since activation. Reads the
//! `chump_provider_quality` table (written by `provider_quality.rs` after
//! every cascade call) and prints a human-readable table on stdout.
//!
//! Today the bandit's slot-selection telemetry is buried in SQLite — there's
//! no fast way to answer "which slots actually carried work last week, and
//! how reliably?" without writing a SQL query. This subcommand surfaces it
//! as a one-liner so the operator (or an overnight script comparing
//! day-over-day deltas) can read the bandit's empirical state at a glance.
//!
//! Pure read; no mutations. Safe to run anytime, including while the cascade
//! is serving traffic (chump_memory.db is in WAL mode).
//!
//! Companion to:
//! - `scripts/overnight/40-cascade-consumption-report.sh` (INFRA-260) which
//!   writes a daily ambient.jsonl event from the same data; this subcommand
//!   is the on-demand human-facing equivalent.
//! - `chump dashboard` (INFRA-063) which prints a higher-level cycle-time
//!   view; cascade stats drill into the inference-routing layer.
//!
//! Output forms:
//! - Default: ASCII table with totals row.
//! - `--json`: compact machine-parseable JSON array (one object per slot).

use crate::repo_path;
use anyhow::{Context, Result};

/// Public entry point: render cascade stats to stdout.
///
/// `json_out`: when true, emit a single JSON line with all slots; otherwise
/// emit a fixed-width ASCII table.
pub fn print_stats(json_out: bool) -> Result<()> {
    let rows = read_quality_rows()?;
    if rows.is_empty() {
        if json_out {
            println!("[]");
        } else {
            println!(
                "[cascade-stats] no provider_quality rows yet — cascade hasn't recorded any calls"
            );
        }
        return Ok(());
    }

    if json_out {
        print_json(&rows);
    } else {
        print_table(&rows);
    }
    Ok(())
}

#[derive(Debug)]
struct QualityRow {
    slot: String,
    success: i64,
    sanity_fail: i64,
    p50_ms: Option<f64>,
    p95_ms: Option<f64>,
    last_updated: String,
}

fn read_quality_rows() -> Result<Vec<QualityRow>> {
    let db_path = repo_path::repo_root().join("sessions/chump_memory.db");
    if !db_path.exists() {
        // Cascade hasn't run on this machine yet — return empty (caller
        // prints the "no rows yet" message). This matches the same
        // graceful-degradation pattern the consumption-report script uses.
        return Ok(Vec::new());
    }
    let conn = rusqlite::Connection::open_with_flags(
        &db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .with_context(|| format!("opening {}", db_path.display()))?;

    // Best-effort: if the table doesn't exist (fresh DB pre-cascade), return
    // empty rather than erroring. provider_quality.rs creates the table on
    // first write.
    let table_exists: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='chump_provider_quality'",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if table_exists == 0 {
        return Ok(Vec::new());
    }

    let mut stmt = conn.prepare(
        "SELECT slot_name,
                COALESCE(success_count, 0),
                COALESCE(sanity_fail_count, 0),
                latency_ms_p50,
                latency_ms_p95,
                COALESCE(last_updated, '')
         FROM chump_provider_quality
         ORDER BY (success_count + sanity_fail_count) DESC, slot_name ASC",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok(QualityRow {
                slot: r.get(0)?,
                success: r.get(1)?,
                sanity_fail: r.get(2)?,
                p50_ms: r.get::<_, Option<f64>>(3)?,
                p95_ms: r.get::<_, Option<f64>>(4)?,
                last_updated: r.get(5)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

fn fmt_ms(v: Option<f64>) -> String {
    match v {
        Some(x) if x.is_finite() => format!("{:.0}", x),
        _ => "-".to_string(),
    }
}

fn success_rate(r: &QualityRow) -> Option<f64> {
    let total = r.success + r.sanity_fail;
    if total == 0 {
        None
    } else {
        Some(100.0 * (r.success as f64) / (total as f64))
    }
}

fn print_table(rows: &[QualityRow]) {
    println!("# cascade stats (per-slot)");
    println!();
    println!(
        "  {:<12} {:>8} {:>6} {:>7} {:>8} {:>8}  last_updated",
        "slot", "success", "fails", "rate%", "p50ms", "p95ms"
    );
    println!("  {}", "-".repeat(72));

    let mut total_success = 0i64;
    let mut total_fail = 0i64;
    for r in rows {
        let rate = success_rate(r)
            .map(|x| format!("{:.0}", x))
            .unwrap_or_else(|| "-".to_string());
        println!(
            "  {:<12} {:>8} {:>6} {:>7} {:>8} {:>8}  {}",
            r.slot,
            r.success,
            r.sanity_fail,
            rate,
            fmt_ms(r.p50_ms),
            fmt_ms(r.p95_ms),
            r.last_updated,
        );
        total_success += r.success;
        total_fail += r.sanity_fail;
    }

    println!("  {}", "-".repeat(72));
    let total = total_success + total_fail;
    let total_rate = if total == 0 {
        "-".to_string()
    } else {
        format!("{:.0}", 100.0 * (total_success as f64) / (total as f64))
    };
    println!(
        "  {:<12} {:>8} {:>6} {:>7}",
        "TOTAL", total_success, total_fail, total_rate
    );
}

fn print_json(rows: &[QualityRow]) {
    // Hand-roll one-line JSON to avoid pulling serde into a tiny module.
    // Same approach as crate::dashboard's gh JSON parsing pattern.
    let mut out = String::from("[");
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        let p50 = r
            .p50_ms
            .map(|x| format!("{:.2}", x))
            .unwrap_or_else(|| "null".to_string());
        let p95 = r
            .p95_ms
            .map(|x| format!("{:.2}", x))
            .unwrap_or_else(|| "null".to_string());
        let rate = success_rate(r)
            .map(|x| format!("{:.2}", x))
            .unwrap_or_else(|| "null".to_string());
        out.push_str(&format!(
            r#"{{"slot":"{}","success":{},"fails":{},"rate_pct":{},"p50_ms":{},"p95_ms":{},"last_updated":"{}"}}"#,
            json_escape(&r.slot),
            r.success,
            r.sanity_fail,
            rate,
            p50,
            p95,
            json_escape(&r.last_updated),
        ));
    }
    out.push(']');
    println!("{}", out);
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fmt_ms_handles_none_and_nan() {
        assert_eq!(fmt_ms(None), "-");
        assert_eq!(fmt_ms(Some(f64::NAN)), "-");
        assert_eq!(fmt_ms(Some(f64::INFINITY)), "-");
        assert_eq!(fmt_ms(Some(123.7)), "124");
        assert_eq!(fmt_ms(Some(0.0)), "0");
    }

    #[test]
    fn success_rate_zero_total_returns_none() {
        let r = QualityRow {
            slot: "s".into(),
            success: 0,
            sanity_fail: 0,
            p50_ms: None,
            p95_ms: None,
            last_updated: "".into(),
        };
        assert!(success_rate(&r).is_none());
    }

    #[test]
    fn success_rate_basic() {
        let r = QualityRow {
            slot: "s".into(),
            success: 9,
            sanity_fail: 1,
            p50_ms: None,
            p95_ms: None,
            last_updated: "".into(),
        };
        assert_eq!(success_rate(&r), Some(90.0));
    }

    #[test]
    fn json_escape_handles_quotes_and_control() {
        assert_eq!(json_escape("a\"b"), r#"a\"b"#);
        assert_eq!(json_escape("a\nb"), r"a\nb");
        assert_eq!(json_escape("plain"), "plain");
    }

    #[test]
    fn print_json_empty_does_not_panic() {
        let rows: Vec<QualityRow> = vec![];
        print_json(&rows);
    }
}
