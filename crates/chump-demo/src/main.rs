//! META-072: chump-demo — Track-3 (autonomous-throughput) demo loop.
//!
//! Operationalizes the 2026-05-23 cascade evidence (see
//! docs/writeups/2026-05-23-autonomy-cascade.md from DOC-052) into a
//! repeatable 60-minute scenario:
//!
//!   1. Drop N synthetic gaps into a sandbox state.db.
//!   2. Watch ambient.jsonl + the GitHub merge queue for K minutes.
//!   3. At the end, emit a JSON metrics report:
//!        - prs_merged_per_hour
//!        - operator_keystrokes_per_ship (estimated from bash_call events
//!          whose session matches CHUMP_OPERATOR_SESSION_GLOB)
//!        - automation_alerts_fired
//!        - cascade_keystones_auto_classified (kind=keystone_candidate
//!          ambient events; populated by INFRA-1840 once it lands)
//!
//! v0 scope (this binary):
//!
//! * `--seed N` — write N synthetic SMOKE-*.yaml gaps via
//!   `chump gap reserve --domain SMOKE`.
//! * `--duration <Nm>` — wall-clock for the scenario; default 60m.
//! * `--report-path PATH` — output JSON metrics report; default
//!   `./.chump-locks/demo-metrics-<ts>.json`.
//! * `--dry-run` — print what would happen without seeding or sleeping.
//!
//! Out of scope for v0 (deferred to follow-up gaps):
//!
//! * Loom/asciinema recording (operator-side action; META-072 final AC).
//! * `chump fleet demo-loop` wiring into src/main.rs (contested file;
//!   ship as standalone `chump-demo` binary first, then alias once
//!   main.rs lease window opens).
//! * Live dashboard integration (Rust route work — pair with INFRA-1338's
//!   /api/fleet-status once available).
//!
//! Failure modes documented at docs/demos/META-072-failure-modes.md.

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// chump-demo — 60-min synthetic autonomy-throughput demonstration.
#[derive(Parser, Debug)]
#[command(name = "chump-demo", about = "META-072 demo loop")]
struct Args {
    /// Number of synthetic gaps to seed at the start.
    #[arg(long, default_value_t = 10)]
    seed: usize,

    /// Scenario duration. Accepted forms: `60m`, `30m`, `5m`, `15s` (mostly
    /// for smoke-testing). Default 60m.
    #[arg(long, default_value = "60m")]
    duration: String,

    /// Output path for the metrics report.
    #[arg(long)]
    report_path: Option<PathBuf>,

    /// Print plan + metrics shape without seeding or sleeping.
    #[arg(long, default_value_t = false)]
    dry_run: bool,

    /// Ambient log path. Defaults to .chump-locks/ambient.jsonl.
    #[arg(long, env = "CHUMP_AMBIENT_LOG")]
    ambient_log: Option<PathBuf>,

    /// Glob of operator-side session IDs (used to estimate
    /// operator-keystrokes by counting their bash_call events).
    #[arg(long, default_value = "chump-Chump-*")]
    operator_session_glob: String,
}

#[derive(Serialize)]
struct MetricsReport {
    schema_version: u32,
    started_at: String,
    ended_at: String,
    duration_s: u64,
    seed_gaps: usize,
    prs_merged: u64,
    prs_merged_per_hour: f64,
    operator_bash_calls: u64,
    operator_keystrokes_per_ship: Option<f64>,
    automation_alerts: u64,
    cascade_keystones_classified: u64,
    notes: Vec<String>,
}

fn parse_duration(s: &str) -> Result<Duration> {
    let s = s.trim();
    if let Some(num) = s.strip_suffix('s') {
        let n: u64 = num.parse().context("--duration: bad seconds value")?;
        return Ok(Duration::from_secs(n));
    }
    if let Some(num) = s.strip_suffix('m') {
        let n: u64 = num.parse().context("--duration: bad minutes value")?;
        return Ok(Duration::from_secs(n * 60));
    }
    if let Some(num) = s.strip_suffix('h') {
        let n: u64 = num.parse().context("--duration: bad hours value")?;
        return Ok(Duration::from_secs(n * 3600));
    }
    Err(anyhow!(
        "--duration {s:?}: expected suffix s|m|h (e.g. 60m, 30s, 1h)"
    ))
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// Drop N synthetic gaps via `chump gap reserve --domain SMOKE`. Best-effort;
/// returns the count successfully reserved (may be less than N if the binary
/// is unavailable or refuses for other reasons). The SMOKE domain is the
/// idiomatic test-fixture namespace in chump.
fn seed_gaps(n: usize, dry_run: bool) -> Result<usize> {
    if dry_run {
        eprintln!("[chump-demo] dry-run: would seed {n} SMOKE-* gaps");
        return Ok(n);
    }
    let mut count = 0usize;
    for i in 0..n {
        let title = format!(
            "SMOKE: META-072 demo-loop synthetic gap {} (auto-filed by chump-demo)",
            i + 1
        );
        let status = Command::new("chump")
            .args([
                "gap",
                "reserve",
                "--domain",
                "SMOKE",
                "--title",
                &title,
                "--priority",
                "P3",
            ])
            .status();
        match status {
            Ok(s) if s.success() => count += 1,
            Ok(s) => eprintln!("[chump-demo] gap reserve exit {s}; continuing"),
            Err(e) => eprintln!("[chump-demo] gap reserve failed: {e}"),
        }
    }
    Ok(count)
}

/// Scan ambient.jsonl for events emitted between [start_unix, end_unix] and
/// produce the metrics tallies. Resilient to malformed lines.
fn collect_metrics(
    ambient_path: &Path,
    start_unix: u64,
    end_unix: u64,
    operator_glob: &str,
) -> (u64, u64, u64, u64) {
    let mut prs_merged = 0u64;
    let mut op_bash = 0u64;
    let mut alerts = 0u64;
    let mut keystones = 0u64;

    let text = match std::fs::read_to_string(ambient_path) {
        Ok(t) => t,
        Err(_) => return (0, 0, 0, 0),
    };
    let glob_prefix = operator_glob.trim_end_matches('*');

    for line in text.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let ts = v["ts"].as_str().unwrap_or("");
        let event_unix = match chrono::DateTime::parse_from_rfc3339(ts) {
            Ok(t) => t.timestamp() as u64,
            Err(_) => continue,
        };
        if event_unix < start_unix || event_unix > end_unix {
            continue;
        }
        let kind = v["kind"].as_str().unwrap_or("");
        match kind {
            "pr_merged" | "bot_merge_auto_armed" | "auto_merge_armed" => prs_merged += 1,
            "bash_call" => {
                let sess = v["session"].as_str().unwrap_or("");
                if sess.starts_with(glob_prefix) {
                    op_bash += 1;
                }
            }
            "keystone_candidate" => keystones += 1,
            _ => {}
        }
        // Alert events follow the kind=*_alert convention OR an explicit
        // "event":"ALERT" wrapper from the broadcast layer.
        if v["event"].as_str() == Some("ALERT") || kind.ends_with("_alert") {
            alerts += 1;
        }
    }
    (prs_merged, op_bash, alerts, keystones)
}

fn default_ambient_path() -> PathBuf {
    let root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(root).join(".chump-locks/ambient.jsonl")
}

fn default_report_path(started_at: &str) -> PathBuf {
    let root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    let safe_ts = started_at.replace(':', "-");
    PathBuf::from(root).join(format!(".chump-locks/demo-metrics-{safe_ts}.json"))
}

fn main() -> Result<()> {
    let args = Args::parse();
    let duration = parse_duration(&args.duration)?;
    let ambient_path = args.ambient_log.unwrap_or_else(default_ambient_path);

    let started_at = now_iso();
    let started_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    eprintln!(
        "[chump-demo] starting META-072 demo loop: seed={} duration={}s ambient={}",
        args.seed,
        duration.as_secs(),
        ambient_path.display()
    );

    let actual_seed = seed_gaps(args.seed, args.dry_run)?;

    if args.dry_run {
        eprintln!("[chump-demo] dry-run: skipping wait + metrics; emitting empty-shape report");
    } else {
        std::thread::sleep(duration);
    }

    let ended_at = now_iso();
    let ended_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(started_unix);

    let (prs_merged, op_bash, alerts, keystones) = collect_metrics(
        &ambient_path,
        started_unix,
        ended_unix,
        &args.operator_session_glob,
    );

    let hours = (duration.as_secs() as f64) / 3600.0;
    let prs_per_hour = if hours > 0.0 {
        (prs_merged as f64) / hours
    } else {
        0.0
    };
    let op_per_ship = if prs_merged > 0 {
        Some((op_bash as f64) / (prs_merged as f64))
    } else {
        None
    };

    let report = MetricsReport {
        schema_version: 1,
        started_at: started_at.clone(),
        ended_at,
        duration_s: duration.as_secs(),
        seed_gaps: actual_seed,
        prs_merged,
        prs_merged_per_hour: prs_per_hour,
        operator_bash_calls: op_bash,
        operator_keystrokes_per_ship: op_per_ship,
        automation_alerts: alerts,
        cascade_keystones_classified: keystones,
        notes: vec![
            "v0 metrics — operator_keystrokes_per_ship approximates from bash_call events whose session matches --operator-session-glob".into(),
            "cascade_keystones_classified depends on INFRA-1840 (failure-class classifier) emitting kind=keystone_candidate — until that lands the value is always 0".into(),
            "pr_merged count comes from ambient events; if the merge happens outside the watcher window or the emit is missed, the count under-reports".into(),
        ],
    };

    let report_path = args
        .report_path
        .unwrap_or_else(|| default_report_path(&started_at));
    if let Some(parent) = report_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let body = serde_json::to_string_pretty(&report)?;
    std::fs::write(&report_path, &body)
        .with_context(|| format!("writing report to {}", report_path.display()))?;
    println!("{body}");
    eprintln!("[chump-demo] report written: {}", report_path.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_duration_minutes() {
        assert_eq!(parse_duration("60m").unwrap(), Duration::from_secs(3600));
        assert_eq!(parse_duration("15s").unwrap(), Duration::from_secs(15));
        assert_eq!(parse_duration("1h").unwrap(), Duration::from_secs(3600));
    }

    #[test]
    fn parse_duration_rejects_garbage() {
        assert!(parse_duration("forever").is_err());
        assert!(parse_duration("60x").is_err());
        assert!(parse_duration("").is_err());
    }

    #[test]
    fn collect_metrics_counts_kinds() {
        // Build a synthetic ambient log + verify the tallies match the
        // schema we promise. Keep this test self-contained — no I/O.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("amb.jsonl");
        let lines = [
            r#"{"ts":"2026-05-23T22:00:00Z","kind":"pr_merged","session":"x"}"#,
            r#"{"ts":"2026-05-23T22:00:30Z","kind":"bash_call","session":"chump-Chump-abc"}"#,
            r#"{"ts":"2026-05-23T22:01:00Z","kind":"bash_call","session":"worker-sonnet-1"}"#,
            r#"{"ts":"2026-05-23T22:01:30Z","kind":"keystone_candidate","session":"opus-x"}"#,
            r#"{"ts":"2026-05-23T22:02:00Z","kind":"random_alert","session":"opus-y"}"#,
            r#"{"ts":"2026-05-23T22:03:00Z","kind":"pr_merged","session":"y"}"#,
        ];
        std::fs::write(&path, lines.join("\n")).unwrap();
        // Bounds bracket the synthetic event timestamps above (2026-05-23 22:00-22:03 UTC).
        let (prs, op, alerts, keys) =
            collect_metrics(&path, 1779573600, 1779573800, "chump-Chump-*");
        assert_eq!(prs, 2, "pr_merged events counted");
        assert_eq!(op, 1, "only operator-session bash_calls counted");
        assert_eq!(alerts, 1, "*_alert kind counted");
        assert_eq!(keys, 1, "keystone_candidate counted");
    }
}
