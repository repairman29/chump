//! MISSION-095: per-mission-step agent cost tracking + operator telemetry reporting.
//!
//! An agent runner executing a multi-step mission calls [`MissionCostTracker::record_step`]
//! after each step to log token usage and wall-clock duration, then calls
//! [`MissionCostTracker::report`] on mission completion (or failure) to aggregate the
//! total estimated cost and emit it to the operator telemetry log (`ambient.jsonl`)
//! and console.

use std::path::Path;

/// Token usage + duration for a single mission step.
#[derive(Debug, Clone, PartialEq)]
pub struct StepCost {
    pub step_name: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub duration_ms: u64,
}

/// Accumulates [`StepCost`] entries across a multi-step agent mission.
#[derive(Debug, Clone, Default)]
pub struct MissionCostTracker {
    pub mission_id: String,
    pub steps: Vec<StepCost>,
}

/// Default per-million-token rates (USD), overridable via env to match the
/// active model — mirrors `CHUMP_COST_INPUT_PER_MTK` / `CHUMP_COST_OUTPUT_PER_MTK`
/// used by `src/cost_ledger.rs` / `cost_watch.rs`.
const DEFAULT_INPUT_PER_MTK: f64 = 3.0;
const DEFAULT_OUTPUT_PER_MTK: f64 = 15.0;

impl MissionCostTracker {
    pub fn new(mission_id: impl Into<String>) -> Self {
        Self {
            mission_id: mission_id.into(),
            steps: Vec::new(),
        }
    }

    /// Record token usage and duration for one completed mission step.
    pub fn record_step(
        &mut self,
        step_name: impl Into<String>,
        input_tokens: u64,
        output_tokens: u64,
        duration_ms: u64,
    ) {
        self.steps.push(StepCost {
            step_name: step_name.into(),
            input_tokens,
            output_tokens,
            duration_ms,
        });
    }

    pub fn total_input_tokens(&self) -> u64 {
        self.steps.iter().map(|s| s.input_tokens).sum()
    }

    pub fn total_output_tokens(&self) -> u64 {
        self.steps.iter().map(|s| s.output_tokens).sum()
    }

    pub fn total_tokens(&self) -> u64 {
        self.total_input_tokens() + self.total_output_tokens()
    }

    pub fn total_duration_ms(&self) -> u64 {
        self.steps.iter().map(|s| s.duration_ms).sum()
    }

    pub fn step_count(&self) -> usize {
        self.steps.len()
    }

    /// Estimated total cost (USD) across all recorded steps, using per-mtok
    /// rates from `CHUMP_COST_INPUT_PER_MTK` / `CHUMP_COST_OUTPUT_PER_MTK`
    /// when set, else the built-in defaults.
    pub fn estimated_cost_usd(&self) -> f64 {
        let input_rate = std::env::var("CHUMP_COST_INPUT_PER_MTK")
            .ok()
            .and_then(|v| v.trim().parse::<f64>().ok())
            .unwrap_or(DEFAULT_INPUT_PER_MTK);
        let output_rate = std::env::var("CHUMP_COST_OUTPUT_PER_MTK")
            .ok()
            .and_then(|v| v.trim().parse::<f64>().ok())
            .unwrap_or(DEFAULT_OUTPUT_PER_MTK);
        (self.total_input_tokens() as f64 / 1_000_000.0) * input_rate
            + (self.total_output_tokens() as f64 / 1_000_000.0) * output_rate
    }

    /// One-line human-readable summary for console output.
    pub fn summary_line(&self, status: &str) -> String {
        format!(
            "mission {} {}: {} steps, {} tokens ({} in / {} out), {}ms total, est. ${:.4}",
            self.mission_id,
            status,
            self.step_count(),
            self.total_tokens(),
            self.total_input_tokens(),
            self.total_output_tokens(),
            self.total_duration_ms(),
            self.estimated_cost_usd(),
        )
    }

    /// Report cost metrics to the operator telemetry log (`ambient.jsonl`) and
    /// console. Call on mission completion or failure; `status` should be
    /// `"completed"` or `"failed"`.
    ///
    /// Returns the summary line that was printed to console.
    pub fn report(&self, repo_root: &Path, status: &str) -> String {
        let line = self.summary_line(status);
        println!("{line}");
        tracing::info!(
            mission_id = %self.mission_id,
            status = %status,
            steps = self.step_count(),
            total_tokens = self.total_tokens(),
            duration_ms = self.total_duration_ms(),
            estimated_cost_usd = self.estimated_cost_usd(),
            "mission cost report"
        );
        self.emit_ambient_event(repo_root, status);
        line
    }

    fn emit_ambient_event(&self, repo_root: &Path, status: &str) {
        let ambient = repo_root.join(".chump-locks/ambient.jsonl");
        let ts = utc_now_iso8601();
        let payload = format!(
            r#"{{"ts":"{ts}","kind":"mission_cost_report","mission_id":"{mission_id}","status":"{status}","steps":{steps},"input_tokens":{input_tokens},"output_tokens":{output_tokens},"duration_ms":{duration_ms},"estimated_cost_usd":{cost:.6}}}"#,
            mission_id = json_escape(&self.mission_id),
            status = json_escape(status),
            steps = self.step_count(),
            input_tokens = self.total_input_tokens(),
            output_tokens = self.total_output_tokens(),
            duration_ms = self.total_duration_ms(),
            cost = self.estimated_cost_usd(),
        );
        let _ = std::fs::create_dir_all(ambient.parent().unwrap_or(Path::new(".")));
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient)
        {
            use std::io::Write;
            let _ = writeln!(f, "{payload}");
        }
    }
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
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
    let mut days = ts;
    let mut year = 1970u64;
    loop {
        let year_days = if is_leap(year) { 366 } else { 365 };
        if days < year_days {
            break;
        }
        days -= year_days;
        year += 1;
    }
    let month_lens: [u64; 12] = [
        31,
        if is_leap(year) { 29 } else { 28 },
        31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
    ];
    let mut month = 1u64;
    for len in month_lens {
        if days < len {
            break;
        }
        days -= len;
        month += 1;
    }
    (year, month, days + 1, h, mi, s)
}

fn is_leap(y: u64) -> bool {
    y % 400 == 0 || (y % 4 == 0 && y % 100 != 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_tracker_has_zero_totals() {
        let t = MissionCostTracker::new("MISSION-095-test");
        assert_eq!(t.total_input_tokens(), 0);
        assert_eq!(t.total_output_tokens(), 0);
        assert_eq!(t.total_tokens(), 0);
        assert_eq!(t.total_duration_ms(), 0);
        assert_eq!(t.step_count(), 0);
        assert!((t.estimated_cost_usd() - 0.0).abs() < 1e-9);
    }

    #[test]
    fn single_step_records_correctly() {
        let mut t = MissionCostTracker::new("m1");
        t.record_step("step-a", 100, 50, 1234);
        assert_eq!(t.step_count(), 1);
        assert_eq!(t.total_input_tokens(), 100);
        assert_eq!(t.total_output_tokens(), 50);
        assert_eq!(t.total_tokens(), 150);
        assert_eq!(t.total_duration_ms(), 1234);
    }

    #[test]
    fn multi_step_aggregation_sums_across_steps() {
        let mut t = MissionCostTracker::new("m2");
        t.record_step("plan", 1_000, 200, 500);
        t.record_step("execute", 5_000, 1_500, 3_000);
        t.record_step("verify", 800, 100, 750);

        assert_eq!(t.step_count(), 3);
        assert_eq!(t.total_input_tokens(), 1_000 + 5_000 + 800);
        assert_eq!(t.total_output_tokens(), 200 + 1_500 + 100);
        assert_eq!(t.total_tokens(), 1_000 + 5_000 + 800 + 200 + 1_500 + 100);
        assert_eq!(t.total_duration_ms(), 500 + 3_000 + 750);
    }

    #[test]
    fn estimated_cost_uses_env_rates_when_set() {
        std::env::set_var("CHUMP_COST_INPUT_PER_MTK", "2.0");
        std::env::set_var("CHUMP_COST_OUTPUT_PER_MTK", "10.0");

        let mut t = MissionCostTracker::new("m3");
        // 1,000,000 input tokens -> $2.00 ; 500,000 output tokens -> $5.00
        t.record_step("s1", 1_000_000, 500_000, 100);
        let cost = t.estimated_cost_usd();

        std::env::remove_var("CHUMP_COST_INPUT_PER_MTK");
        std::env::remove_var("CHUMP_COST_OUTPUT_PER_MTK");

        assert!((cost - 7.0).abs() < 1e-6, "expected $7.00, got ${cost}");
    }

    #[test]
    fn estimated_cost_zero_tokens_is_zero() {
        let t = MissionCostTracker::new("m4");
        assert_eq!(t.estimated_cost_usd(), 0.0);
    }

    #[test]
    fn summary_line_contains_status_and_mission_id() {
        let mut t = MissionCostTracker::new("MISSION-095");
        t.record_step("step1", 10, 5, 42);
        let line = t.summary_line("completed");
        assert!(line.contains("MISSION-095"), "got: {line}");
        assert!(line.contains("completed"), "got: {line}");
        assert!(line.contains("1 steps"), "got: {line}");
    }

    #[test]
    fn report_emits_ambient_event_with_required_fields() {
        let dir = tempfile::tempdir().unwrap();
        let mut t = MissionCostTracker::new("MISSION-095");
        t.record_step("plan", 100, 20, 111);
        t.record_step("execute", 900, 300, 222);
        t.report(dir.path(), "completed");

        let content = std::fs::read_to_string(dir.path().join(".chump-locks/ambient.jsonl"))
            .unwrap_or_default();
        assert!(
            content.contains("mission_cost_report"),
            "missing kind in: {content}"
        );
        assert!(
            content.contains(r#""mission_id":"MISSION-095""#),
            "missing mission_id: {content}"
        );
        assert!(
            content.contains(r#""status":"completed""#),
            "missing status: {content}"
        );
        assert!(content.contains(r#""steps":2"#), "missing steps: {content}");
        assert!(
            content.contains(r#""input_tokens":1000"#),
            "missing aggregated input_tokens: {content}"
        );
        assert!(
            content.contains(r#""output_tokens":320"#),
            "missing aggregated output_tokens: {content}"
        );
        assert!(
            content.contains(r#""duration_ms":333"#),
            "missing aggregated duration_ms: {content}"
        );
        assert!(
            content.contains("estimated_cost_usd"),
            "missing cost field: {content}"
        );
    }

    #[test]
    fn report_on_failure_records_failed_status() {
        let dir = tempfile::tempdir().unwrap();
        let mut t = MissionCostTracker::new("MISSION-095-fail");
        t.record_step("plan", 50, 10, 5);
        t.report(dir.path(), "failed");

        let content = std::fs::read_to_string(dir.path().join(".chump-locks/ambient.jsonl"))
            .unwrap_or_default();
        assert!(
            content.contains(r#""status":"failed""#),
            "missing failed status: {content}"
        );
    }
}
