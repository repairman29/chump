//! observability.rs — INFRA-1649 (re-do of INFRA-1598)
//!
//! Structured event emission shared by verify-gauntlet commands
//! (`chump verify-claim-branch` today; `chump external verify-merge` is the
//! natural next consumer). A single JSON line summarizing how a verify
//! command finished: `status` (success/failure/timeout), `duration_ms`,
//! `cost_estimate` (wall-clock cost, `duration_seconds * COST_PER_SECOND`,
//! configurable via `CHUMP_COST_PER_SECOND`), and `failure_class`
//! (transient/permanent/none).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Success,
    Failure,
    Timeout,
}

impl Status {
    pub fn as_str(&self) -> &'static str {
        match self {
            Status::Success => "success",
            Status::Failure => "failure",
            Status::Timeout => "timeout",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    Transient,
    Permanent,
    None,
}

impl FailureClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            FailureClass::Transient => "transient",
            FailureClass::Permanent => "permanent",
            FailureClass::None => "none",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ObservabilityEvent {
    pub status: Status,
    pub duration_ms: u128,
    pub cost_estimate: f64,
    pub failure_class: FailureClass,
}

/// Default cost-per-second used when `CHUMP_COST_PER_SECOND` is unset —
/// a conservative rough estimate, not billing-accurate; the env override
/// exists precisely so callers with a real cost model can supply one.
const DEFAULT_COST_PER_SECOND: f64 = 0.0006;

pub fn cost_per_second() -> f64 {
    std::env::var("CHUMP_COST_PER_SECOND")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|v| v.is_finite() && *v >= 0.0)
        .unwrap_or(DEFAULT_COST_PER_SECOND)
}

pub fn build_event(
    status: Status,
    duration_ms: u128,
    failure_class: FailureClass,
) -> ObservabilityEvent {
    let duration_seconds = duration_ms as f64 / 1000.0;
    let cost_estimate = duration_seconds * cost_per_second();
    ObservabilityEvent {
        status,
        duration_ms,
        cost_estimate,
        failure_class,
    }
}

pub fn to_json_line(ev: &ObservabilityEvent) -> String {
    format!(
        "{{\"status\":\"{}\",\"duration_ms\":{},\"cost_estimate\":{:.6},\"failure_class\":\"{}\"}}",
        ev.status.as_str(),
        ev.duration_ms,
        ev.cost_estimate,
        ev.failure_class.as_str()
    )
}

/// Print the JSON observability line to stdout — the one required by
/// AC1 of INFRA-1649, unconditional on any other output the caller does.
pub fn print_json_line(ev: &ObservabilityEvent) {
    println!("{}", to_json_line(ev));
}

/// Log the cost line to stderr per AC4 of INFRA-1649.
pub fn log_cost(ev: &ObservabilityEvent) {
    eprintln!("cost reported: ${:.6}", ev.cost_estimate);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cost_estimate_scales_with_duration_and_env_rate() {
        std::env::set_var("CHUMP_COST_PER_SECOND", "2.0");
        let ev = build_event(Status::Success, 1500, FailureClass::None);
        std::env::remove_var("CHUMP_COST_PER_SECOND");
        assert!((ev.cost_estimate - 3.0).abs() < 1e-9);
    }

    #[test]
    fn json_line_contains_required_keys() {
        let ev = build_event(Status::Timeout, 42, FailureClass::Transient);
        let line = to_json_line(&ev);
        assert!(line.contains("\"status\":\"timeout\""));
        assert!(line.contains("\"duration_ms\":42"));
        assert!(line.contains("\"cost_estimate\":"));
        assert!(line.contains("\"failure_class\":\"transient\""));
    }
}
