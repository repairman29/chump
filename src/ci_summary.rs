//! INFRA-506: CI Summary — classify recent CI failures as flake / test-coupling /
//! real-bug / infra-broken.
//!
//! Companion to `waste_tally.rs` for the CI/CD observability primitive.
//! Reads `gh run list` + `gh run view --log-failed` for a time window,
//! classifies each failed run, and emits a per-class count with sample
//! diagnostic lines — like waste-tally for the fleet, but for CI.
//!
//! ## Failure taxonomy
//!
//! | Class          | Description                                              |
//! |----------------|----------------------------------------------------------|
//! | `flake`        | Transient — same workflow passes on a later rerun        |
//! | `test-coupling`| Fixture/snapshot broke after upstream change             |
//! | `real-bug`     | clippy/build/test error introduced by the PR's diff      |
//! | `infra-broken` | CI infra issue: toolchain, runner, disk, rate-limit      |
//!
//! ## Usage
//!
//! `chump ci-summary [--since 24h] [--json]`

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::Path;
use std::process::Command;

// ── Public types ────────────────────────────────────────────────────────────

/// One aggregated bucket per failure class.
#[derive(Debug, Clone, Default)]
pub struct CiEntry {
    pub class: String,
    pub count: u64,
    /// Up to 3 representative diagnostic lines sampled from failed logs.
    pub sample_lines: Vec<String>,
}

/// Full report for the requested time window.
#[derive(Debug, Clone, Default)]
pub struct CiReport {
    pub since_seconds: u64,
    /// Total runs fetched (successful + failed) in the window.
    pub total_runs_checked: u64,
    /// How many of those runs failed (conclusion == "failure").
    pub failed_runs: u64,
    /// Per-class aggregates, sorted by count desc.
    pub entries: Vec<CiEntry>,
}

// ── Classification ───────────────────────────────────────────────────────────

/// Classify a CI job log text.
///
/// `reran_and_passed`: true when we observed a successful run of the same
/// workflow + branch *after* this failure — the strongest flake signal.
pub fn classify_log(log: &str, reran_and_passed: bool) -> &'static str {
    // Infra-broken has the highest priority — it masks everything else.
    if is_infra_broken(log) {
        return "infra-broken";
    }
    // Snapshot/fixture coupling — distinct from real code bugs.
    if is_test_coupling(log) {
        return "test-coupling";
    }
    // Flake: either the rerun passed, or the log has transient-error signatures.
    if reran_and_passed || is_flake_signature(log) {
        return "flake";
    }
    // Everything else: an actual defect in the PR.
    "real-bug"
}

fn is_infra_broken(log: &str) -> bool {
    let lower = log.to_lowercase();
    lower.contains("no space left on device")
        || lower.contains("rustup: error")
        || lower.contains("error: toolchain '")
        || lower.contains("the runner has received a shutdown signal")
        || lower.contains("the operation was canceled")
        || lower.contains("rate limit exceeded")
        || lower.contains("error response from daemon")
        || lower.contains("runner exited")
        || lower.contains("github actions runner")
        || (lower.contains("failed to connect") && lower.contains("server"))
        || lower.contains("tls handshake timeout")
        || lower.contains("i/o timeout")
        || lower.contains("name resolution failed")
}

fn is_flake_signature(log: &str) -> bool {
    let lower = log.to_lowercase();
    lower.contains("econnreset")
        || lower.contains("signal: killed")
        || lower.contains("oom killer")
        || (lower.contains("connection refused") && !lower.contains("error[e"))
        || lower.contains("operation timed out")
        || lower.contains("context deadline exceeded")
        || lower.contains("socket hang up")
        || (lower.contains("killed") && lower.contains("memory"))
}

fn is_test_coupling(log: &str) -> bool {
    let lower = log.to_lowercase();
    lower.contains("snapshot mismatch")
        || lower.contains("snapshot differs")
        || (lower.contains("snapshot") && lower.contains("outdated"))
        || (lower.contains("snapshot") && lower.contains("updated"))
        || lower.contains("golden file")
        || lower.contains(".snap")
        || (lower.contains("fixture") && lower.contains("fail"))
        || lower.contains("expected snapshot")
        || lower.contains("update snapshots")
}

/// Extract the most diagnostic lines from a log for human display (up to 3).
pub fn extract_sample_lines(log: &str) -> Vec<String> {
    let mut samples: Vec<String> = Vec::new();
    for line in log.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.len() > 300 {
            continue;
        }
        let lower = trimmed.to_lowercase();
        let is_diagnostic = lower.starts_with("error")
            || lower.starts_with("failed")
            || lower.starts_with("::error::")
            || lower.contains("panicked at")
            || lower.starts_with("assertion `left == right` failed")
            || lower.contains("error[e")
            || lower.starts_with("the process")
            || lower.starts_with("killed");
        if is_diagnostic {
            let s = if trimmed.len() > 120 {
                format!("{}…", &trimmed[..120])
            } else {
                trimmed.to_string()
            };
            if !samples.contains(&s) {
                samples.push(s);
            }
            if samples.len() >= 3 {
                break;
            }
        }
    }
    samples
}

// ── Data fetching ────────────────────────────────────────────────────────────

/// A single failed run fetched from GitHub.
#[derive(Debug, Clone)]
struct RunRecord {
    id: u64,
    workflow: String,
    branch: String,
    created_unix: u64,
    log: String,
}

/// Build a CI summary report for the given time window. Calls `gh`.
/// On any `gh` failure (not authenticated, no network) the report will
/// have zero entries rather than crashing.
pub fn build_report(since_secs: u64) -> CiReport {
    let now = current_unix();
    let cutoff = now.saturating_sub(since_secs);

    // Step 1: list recent runs.
    let run_json = gh_run_list(200);
    if run_json.is_empty() {
        return CiReport {
            since_seconds: since_secs,
            ..Default::default()
        };
    }

    // Step 2: parse runs, filter to window.
    let all_runs = parse_run_list(&run_json);
    let in_window: Vec<&ParsedRun> = all_runs
        .iter()
        .filter(|r| r.created_unix >= cutoff)
        .collect();
    let total_checked = in_window.len() as u64;

    // Step 3: build a rerun-pass map: (workflow, branch) -> set of successful run timestamps
    // so we can flag failures that were later resolved without a code fix.
    let mut success_times: BTreeMap<(String, String), Vec<u64>> = BTreeMap::new();
    for r in &in_window {
        if r.conclusion == "success" {
            success_times
                .entry((r.workflow.clone(), r.branch.clone()))
                .or_default()
                .push(r.created_unix);
        }
    }

    // Step 4: fetch logs for failed runs (cap at 30 to stay within rate limits).
    let failed: Vec<&ParsedRun> = in_window
        .iter()
        .copied()
        .filter(|r| r.conclusion == "failure")
        .take(30)
        .collect();
    let failed_total = in_window
        .iter()
        .filter(|r| r.conclusion == "failure")
        .count() as u64;

    let mut records: Vec<RunRecord> = Vec::new();
    for run in &failed {
        let log = gh_run_log(run.id);
        let reran = success_times
            .get(&(run.workflow.clone(), run.branch.clone()))
            .map(|times| times.iter().any(|&t| t > run.created_unix))
            .unwrap_or(false);
        records.push(RunRecord {
            id: run.id,
            workflow: run.workflow.clone(),
            branch: run.branch.clone(),
            created_unix: run.created_unix,
            log,
        });
        // Store reran flag alongside; use a parallel Vec for simplicity.
        let _ = reran; // will re-compute inline below
    }

    // Step 5: classify and aggregate.
    let mut by_class: BTreeMap<String, CiEntry> = BTreeMap::new();
    for (i, record) in records.iter().enumerate() {
        let reran = success_times
            .get(&(record.workflow.clone(), record.branch.clone()))
            .map(|times| times.iter().any(|&t| t > record.created_unix))
            .unwrap_or(false);
        let class = classify_log(&record.log, reran).to_string();
        let entry = by_class.entry(class.clone()).or_insert_with(|| CiEntry {
            class: class.clone(),
            count: 0,
            sample_lines: Vec::new(),
        });
        entry.count += 1;
        // Collect sample lines from the first run in each class.
        if entry.sample_lines.is_empty() {
            entry.sample_lines = extract_sample_lines(&record.log);
        }
        let _ = i;
    }

    let mut entries: Vec<CiEntry> = by_class.into_values().collect();
    entries.sort_by_key(|e| std::cmp::Reverse(e.count));

    CiReport {
        since_seconds: since_secs,
        total_runs_checked: total_checked,
        failed_runs: failed_total,
        entries,
    }
}

// ── gh wrappers ──────────────────────────────────────────────────────────────

fn gh_run_list(limit: u32) -> String {
    let limit_s = limit.to_string();
    let out = Command::new("gh")
        .args([
            "run",
            "list",
            "--limit",
            &limit_s,
            "--json",
            "databaseId,name,conclusion,createdAt,headBranch",
        ])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => String::new(),
    }
}

fn gh_run_log(run_id: u64) -> String {
    let id_s = run_id.to_string();
    let out = Command::new("gh")
        .args(["run", "view", &id_s, "--log-failed"])
        .output();
    match out {
        Ok(o) => {
            let raw = String::from_utf8_lossy(&o.stdout).into_owned();
            // Truncate to 64 KB to avoid OOM on huge logs.
            if raw.len() > 65_536 {
                raw[..65_536].to_string()
            } else {
                raw
            }
        }
        Err(_) => String::new(),
    }
}

// ── JSON parsing (no serde) ──────────────────────────────────────────────────

#[derive(Debug)]
struct ParsedRun {
    id: u64,
    workflow: String,
    branch: String,
    conclusion: String,
    created_unix: u64,
}

/// Parse the `gh run list --json ...` array into `ParsedRun` records.
/// Tolerant of field ordering; ignores unknown fields.
fn parse_run_list(json: &str) -> Vec<ParsedRun> {
    let mut out = Vec::new();
    let bytes = json.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'{' {
            let start = i;
            let mut depth = 0i32;
            loop {
                if i >= bytes.len() {
                    break;
                }
                match bytes[i] {
                    b'{' => depth += 1,
                    b'}' => {
                        depth -= 1;
                        if depth == 0 {
                            let obj = &json[start..=i];
                            if let Some(rec) = parse_one_run(obj) {
                                out.push(rec);
                            }
                            i += 1;
                            break;
                        }
                    }
                    _ => {}
                }
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    out
}

fn parse_one_run(obj: &str) -> Option<ParsedRun> {
    let id = extract_int_field(obj, "databaseId")?;
    let workflow = extract_str_field(obj, "name").unwrap_or_default();
    let branch = extract_str_field(obj, "headBranch").unwrap_or_default();
    let conclusion = extract_str_field(obj, "conclusion").unwrap_or_default();
    let created_at_str = extract_str_field(obj, "createdAt").unwrap_or_default();
    let created_unix = parse_iso8601_to_unix(&created_at_str).unwrap_or(0);
    Some(ParsedRun {
        id,
        workflow,
        branch,
        conclusion,
        created_unix,
    })
}

// ── Rendering ───────────────────────────────────────────────────────────────

impl CiReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        let hours = (self.since_seconds / 3600).max(1);
        out.push_str(&format!(
            "═══ CI Summary ═══ (last {} h, {} runs checked, {} failed)\n",
            hours, self.total_runs_checked, self.failed_runs
        ));
        if self.entries.is_empty() {
            out.push_str("  (no failed runs in window — CI healthy)\n");
            return out;
        }
        for e in &self.entries {
            out.push_str(&format!("  {:>4} × {}\n", e.count, e.class));
            for line in &e.sample_lines {
                out.push_str(&format!("         {}\n", line));
            }
        }
        let pct = if self.failed_runs > 0 && self.total_runs_checked > 0 {
            self.failed_runs * 100 / self.total_runs_checked
        } else {
            0
        };
        out.push_str(&format!(
            "  ─────────────────────────────\n  Failure rate: {}% ({}/{})\n",
            pct, self.failed_runs, self.total_runs_checked
        ));
        out
    }

    pub fn render_json(&self) -> String {
        let entries_json: Vec<String> = self
            .entries
            .iter()
            .map(|e| {
                let samples_json: Vec<String> = e
                    .sample_lines
                    .iter()
                    .map(|l| format!(r#""{}""#, json_escape(l)))
                    .collect();
                format!(
                    r#"{{"class":"{}","count":{},"sample_lines":[{}]}}"#,
                    json_escape(&e.class),
                    e.count,
                    samples_json.join(",")
                )
            })
            .collect();
        format!(
            r#"{{"since_seconds":{},"total_runs_checked":{},"failed_runs":{},"entries":[{}]}}"#,
            self.since_seconds,
            self.total_runs_checked,
            self.failed_runs,
            entries_json.join(",")
        )
    }
}

// ── Ambient alert emission ───────────────────────────────────────────────────

impl CiReport {
    /// Failure rate as a percentage (0–100), rounded down.
    pub fn failure_rate_pct(&self) -> u64 {
        if self.total_runs_checked == 0 {
            return 0;
        }
        self.failed_runs * 100 / self.total_runs_checked
    }

    /// If failure rate exceeds `threshold_pct`, append a `kind=ci_health` ALERT
    /// to `ambient_path` and return `true`. Returns `false` when under threshold
    /// or when the file cannot be opened (non-fatal).
    pub fn emit_ambient_alert(&self, threshold_pct: u64, ambient_path: &Path) -> bool {
        let rate = self.failure_rate_pct();
        if rate <= threshold_pct {
            return false;
        }
        let top_class = self
            .entries
            .first()
            .map(|e| e.class.as_str())
            .unwrap_or("unknown");
        let ts = {
            use std::time::{SystemTime, UNIX_EPOCH};
            let secs = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            // Format as ISO 8601 via `date` to avoid pulling in chrono.
            let out = Command::new("date")
                .args(["-u", "-r", &secs.to_string(), "+%Y-%m-%dT%H:%M:%SZ"])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
            // GNU date fallback (-d @secs)
            out.unwrap_or_else(|| {
                Command::new("date")
                    .args(["-u", "-d", &format!("@{secs}"), "+%Y-%m-%dT%H:%M:%SZ"])
                    .output()
                    .ok()
                    .filter(|o| o.status.success())
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                    .unwrap_or_else(|| "1970-01-01T00:00:00Z".to_string())
            })
        };
        let line = format!(
            "{{\"ts\":\"{ts}\",\"event\":\"ALERT\",\"kind\":\"ci_health\",\
             \"failure_rate_pct\":{rate},\"threshold_pct\":{threshold_pct},\
             \"total_runs\":{total},\"failed_runs\":{failed},\
             \"top_class\":\"{top_class}\",\"since_seconds\":{since}}}",
            ts = ts,
            rate = rate,
            threshold_pct = threshold_pct,
            total = self.total_runs_checked,
            failed = self.failed_runs,
            top_class = top_class,
            since = self.since_seconds,
        );
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(ambient_path)
        {
            let _ = writeln!(f, "{}", line);
            return true;
        }
        false
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn current_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    let out = Command::new("date")
        .args(["-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", s, "+%s"])
        .output()
        .ok()?;
    if out.status.success() {
        return String::from_utf8_lossy(&out.stdout).trim().parse().ok();
    }
    let out2 = Command::new("date")
        .args(["-u", "-d", s, "+%s"])
        .output()
        .ok()?;
    if !out2.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out2.stdout).trim().parse().ok()
}

fn extract_str_field(obj: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":""#, field);
    let start = obj.find(&needle)? + needle.len();
    let rest = &obj[start..];
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'r' => out.push('\r'),
                '\\' => out.push('\\'),
                '"' => out.push('"'),
                'u' => {
                    for _ in 0..4 {
                        chars.next()?;
                    }
                }
                other => out.push(other),
            },
            c => out.push(c),
        }
    }
    None
}

fn extract_int_field(obj: &str, field: &str) -> Option<u64> {
    let needle = format!(r#""{}":"#, field);
    let start = obj.find(&needle)? + needle.len();
    let rest = &obj[start..];
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    rest[..end].parse().ok()
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── Unit: classify_log ──────────────────────────────────────────────────

    #[test]
    fn infra506_classify_infra_broken_toolchain() {
        let log = "error: toolchain 'stable-x86_64-unknown-linux-gnu' is not installed\nhint: run `rustup toolchain install stable`";
        assert_eq!(classify_log(log, false), "infra-broken");
    }

    #[test]
    fn infra506_classify_infra_broken_disk_full() {
        let log = "error: could not write file\ncaused by: No space left on device (os error 28)";
        assert_eq!(classify_log(log, false), "infra-broken");
    }

    #[test]
    fn infra506_classify_infra_broken_runner_shutdown() {
        let log = "The runner has received a shutdown signal. This can happen when the runner service is stopped, or a manually started runner is canceled.\nThe runner will gracefully stop working.";
        assert_eq!(classify_log(log, false), "infra-broken");
    }

    #[test]
    fn infra506_classify_flake_by_rerun() {
        // A log that looks like a real-bug but the same workflow passed later.
        let log = "FAILED tests::my_test\nerror: test failed";
        assert_eq!(classify_log(log, true), "flake");
    }

    #[test]
    fn infra506_classify_flake_oom_kill() {
        let log = "Killed\nsignal: killed\ncargo: build failed";
        assert_eq!(classify_log(log, false), "flake");
    }

    #[test]
    fn infra506_classify_test_coupling_snapshot() {
        let log = "snapshot mismatch for `tests/snapshots/my_output.snap`\n--- old\n+++ new\n-old line\n+new line\nrun with UPDATE_EXPECT=1 to update snapshots";
        assert_eq!(classify_log(log, false), "test-coupling");
    }

    #[test]
    fn infra506_classify_test_coupling_snap_file() {
        let log = "thread 'tests::render_html' panicked at 'assertion failed'\nexpected contents in file tests/golden/render.snap\nnote: run cargo test -- --update-snapshots to regenerate";
        assert_eq!(classify_log(log, false), "test-coupling");
    }

    #[test]
    fn infra506_classify_real_bug_clippy() {
        let log = "error[E0308]: mismatched types\n  --> src/main.rs:42:5\nerror: aborting due to previous error";
        assert_eq!(classify_log(log, false), "real-bug");
    }

    #[test]
    fn infra506_classify_real_bug_panic() {
        let log = "thread 'tests::it_works' panicked at 'assertion `left == right` failed'\n  left: 1\n right: 2\nnote: run with RUST_BACKTRACE=1";
        assert_eq!(classify_log(log, false), "real-bug");
    }

    // ── Unit: extract_sample_lines ─────────────────────────────────────────

    #[test]
    fn infra506_sample_lines_extracts_errors() {
        let log = "Building...\nerror: mismatched types\n  --> src/lib.rs:5\nFinished with errors";
        let samples = extract_sample_lines(log);
        assert!(!samples.is_empty());
        assert!(samples[0].to_lowercase().contains("error"));
    }

    #[test]
    fn infra506_sample_lines_deduplicates() {
        let log = "error: same error\nerror: same error\nerror: same error";
        let samples = extract_sample_lines(log);
        // Dedup means we see this only once.
        assert_eq!(samples.len(), 1);
    }

    // ── Unit: render ───────────────────────────────────────────────────────

    #[test]
    fn infra506_render_text_shows_classes() {
        let report = CiReport {
            since_seconds: 86400,
            total_runs_checked: 50,
            failed_runs: 12,
            entries: vec![
                CiEntry {
                    class: "real-bug".into(),
                    count: 7,
                    sample_lines: vec!["error[E0308]: mismatched types".into()],
                },
                CiEntry {
                    class: "flake".into(),
                    count: 3,
                    sample_lines: vec![],
                },
                CiEntry {
                    class: "infra-broken".into(),
                    count: 2,
                    sample_lines: vec![],
                },
            ],
        };
        let text = report.render_text();
        assert!(text.contains("CI Summary"));
        assert!(text.contains("real-bug"));
        assert!(text.contains("flake"));
        assert!(text.contains("infra-broken"));
        assert!(text.contains("Failure rate: 24%"), "got: {}", text);
    }

    #[test]
    fn infra506_render_text_empty_is_healthy() {
        let report = CiReport {
            since_seconds: 86400,
            total_runs_checked: 10,
            failed_runs: 0,
            entries: vec![],
        };
        let text = report.render_text();
        assert!(text.contains("CI healthy"));
    }

    #[test]
    fn infra506_render_json_is_parseable() {
        let report = CiReport {
            since_seconds: 3600,
            total_runs_checked: 5,
            failed_runs: 2,
            entries: vec![CiEntry {
                class: "real-bug".into(),
                count: 2,
                sample_lines: vec!["error: build failed".into()],
            }],
        };
        let json = report.render_json();
        assert!(json.starts_with('{'));
        assert!(json.contains(r#""since_seconds":3600"#));
        assert!(json.contains(r#""failed_runs":2"#));
        assert!(json.contains(r#""class":"real-bug""#));
        assert!(json.contains(r#""count":2"#));
    }

    // ── Unit: parse_run_list ───────────────────────────────────────────────

    #[test]
    fn infra506_parse_run_list_basic() {
        let json = r#"[{"databaseId":1234,"name":"CI","conclusion":"failure","createdAt":"2026-05-06T12:00:00Z","headBranch":"main"},{"databaseId":5678,"name":"CI","conclusion":"success","createdAt":"2026-05-06T13:00:00Z","headBranch":"main"}]"#;
        let runs = parse_run_list(json);
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].id, 1234);
        assert_eq!(runs[0].conclusion, "failure");
        assert_eq!(runs[1].id, 5678);
        assert_eq!(runs[1].conclusion, "success");
    }

    #[test]
    fn infra506_parse_run_list_empty() {
        let runs = parse_run_list("[]");
        assert!(runs.is_empty());
    }

    // ── Unit: failure_rate_pct + emit_ambient_alert ────────────────────────

    #[test]
    fn infra511_failure_rate_pct_correct() {
        let r = CiReport {
            since_seconds: 86400,
            total_runs_checked: 50,
            failed_runs: 12,
            entries: vec![],
        };
        assert_eq!(r.failure_rate_pct(), 24);
    }

    #[test]
    fn infra511_failure_rate_pct_zero_total() {
        let r = CiReport::default();
        assert_eq!(r.failure_rate_pct(), 0);
    }

    #[test]
    fn infra511_emit_alert_under_threshold_no_write() {
        let r = CiReport {
            since_seconds: 604800,
            total_runs_checked: 20,
            failed_runs: 1, // 5% — under 10% threshold
            entries: vec![],
        };
        let dir = std::env::temp_dir().join(format!("infra511_test_{}", std::process::id()));
        let path = dir.join("ambient.jsonl");
        let emitted = r.emit_ambient_alert(10, &path);
        assert!(!emitted, "should not emit when under threshold");
        assert!(!path.exists(), "file should not be created");
    }

    #[test]
    fn infra511_emit_alert_over_threshold_writes_jsonl() {
        let r = CiReport {
            since_seconds: 604800,
            total_runs_checked: 50,
            failed_runs: 12, // 24% — over 10%
            entries: vec![CiEntry {
                class: "real-bug".into(),
                count: 8,
                sample_lines: vec![],
            }],
        };
        let dir = std::env::temp_dir().join(format!("infra511_alert_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("ambient.jsonl");
        let emitted = r.emit_ambient_alert(10, &path);
        assert!(emitted, "should emit when over threshold");
        let contents = std::fs::read_to_string(&path).unwrap();
        assert!(
            contents.contains("\"kind\":\"ci_health\""),
            "got: {}",
            contents
        );
        assert!(
            contents.contains("\"event\":\"ALERT\""),
            "got: {}",
            contents
        );
        assert!(
            contents.contains("\"failure_rate_pct\":24"),
            "got: {}",
            contents
        );
        assert!(
            contents.contains("\"top_class\":\"real-bug\""),
            "got: {}",
            contents
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── Plumbing: gh run list round-trip ───────────────────────────────────

    #[test]
    fn infra506_plumbing_gh_run_list_no_panic() {
        // Calls the real `gh` binary. Skips gracefully when gh is unavailable
        // or not authenticated — we only care that the code path doesn't panic.
        let json = gh_run_list(5);
        // Either gh returned valid JSON or an empty string — both are fine.
        // If it returned JSON, parse_run_list must not panic.
        let _runs = parse_run_list(&json);
    }
}
