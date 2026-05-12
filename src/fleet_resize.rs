// fleet_resize.rs — INFRA-650: fleet auto-prune-down controller
//
// Evaluates 4 conditions that trigger a scale-down, then optionally applies
// the resize. The inverse of the INFRA-518 expansion gate (which scales up).
// Together they form a closed-loop fleet-sizing controller.
//
// Conditions (any triggers resize-down):
//   A. Queue-empty: queue has 0 pickable gaps + 0 in-flight leases for 30+ min
//   B. Cost-watch: daily cost hard-cap at 80% with < 4h remaining in the day
//   C. Flat ship rate: no PR merged in 60 min despite N > 1 workers
//   D. Autonomous-mode: operator absent > 24h → floor at 1 worker

use std::path::Path;
use std::time::{Duration, SystemTime};

#[derive(Debug, PartialEq)]
pub enum ResizeTrigger {
    QueueEmpty,
    CostCapApproaching,
    FlatShipRate,
    OperatorAbsent,
}

#[derive(Debug)]
pub struct ResizeDecision {
    pub trigger: ResizeTrigger,
    pub rationale: String,
    pub current_size: u32,
    pub recommended_size: u32,
}

/// Check condition A: queue empty for > 30 min.
/// Returns `Some(decision)` if the fleet should shrink.
pub fn check_queue_empty(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    if current_size <= 1 {
        return None;
    }

    // Read the .chump/queue-empty-since timestamp if present.
    let marker = repo_root.join(".chump/queue-empty-since");
    let since = std::fs::read_to_string(&marker)
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .map(|unix| SystemTime::UNIX_EPOCH + Duration::from_secs(unix));

    let threshold = Duration::from_secs(30 * 60); // 30 min

    if let Some(since_time) = since {
        if since_time.elapsed().unwrap_or_default() >= threshold {
            return Some(ResizeDecision {
                trigger: ResizeTrigger::QueueEmpty,
                rationale: format!(
                    "queue empty for >30 min (marker: {}); no pickable gaps or in-flight leases",
                    marker.display()
                ),
                current_size,
                recommended_size: 0,
            });
        }
    }

    None
}

/// Check condition B: daily cost approaching hard-cap (80%) with < 4h left.
/// Returns `Some(decision)` if the fleet should shrink.
pub fn check_cost_cap(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    if current_size <= 1 {
        return None;
    }

    let cost_file = repo_root.join(".chump/daily-cost.json");
    let raw = std::fs::read_to_string(&cost_file).ok()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;

    let spent = v["spent_usd"].as_f64().unwrap_or(0.0);
    let budget = v["budget_usd"].as_f64().unwrap_or(f64::MAX);
    if budget <= 0.0 || spent / budget < 0.80 {
        return None;
    }

    // Check hours remaining in day (UTC).
    let now = chrono::Utc::now();
    let end_of_day = now.date_naive().succ_opt()?.and_hms_opt(0, 0, 0)?.and_utc();
    let hours_left = (end_of_day - now).num_hours();
    if hours_left >= 4 {
        return None;
    }

    Some(ResizeDecision {
        trigger: ResizeTrigger::CostCapApproaching,
        rationale: format!(
            "daily cost at {:.0}% of budget ({spent:.2}/{budget:.2} USD) with only {hours_left}h left",
            (spent / budget) * 100.0,
        ),
        current_size,
        recommended_size: current_size / 2,
    })
}

/// Check condition C: no PR merged in 60 min despite N > 1 workers.
/// Returns `Some(decision)` if the fleet should shrink.
pub fn check_flat_ship_rate(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    if current_size <= 1 {
        return None;
    }

    // Read last merge timestamp from ambient.jsonl.
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let raw = std::fs::read_to_string(&ambient).ok()?;

    let threshold_secs = 60 * 60_u64; // 60 min
    let now_secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    // Find most recent pr_merged event.
    let last_merge = raw
        .lines()
        .rev()
        .take(500)
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .find(|v| v["kind"] == "pr_merged" || v["kind"] == "gap_shipped")
        .and_then(|v| v["ts"].as_str().map(str::to_string));

    let last_merge_secs = last_merge
        .and_then(|ts| {
            chrono::DateTime::parse_from_rfc3339(&ts)
                .ok()
                .map(|dt| dt.timestamp() as u64)
        })
        .unwrap_or(0);

    if last_merge_secs == 0 || now_secs.saturating_sub(last_merge_secs) < threshold_secs {
        return None;
    }

    Some(ResizeDecision {
        trigger: ResizeTrigger::FlatShipRate,
        rationale: format!(
            "no PR merged in 60+ min with {current_size} workers; ship rate has stalled"
        ),
        current_size,
        recommended_size: current_size.saturating_sub(1).max(1),
    })
}

/// Check condition D: operator absent > 24h in autonomous mode.
/// Returns `Some(decision)` if the fleet should shrink to 1.
pub fn check_operator_absent(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    if current_size <= 1 {
        return None;
    }

    // Read autonomous mode flag.
    let auto_flag = repo_root.join(".chump/autonomous-mode");
    if !auto_flag.exists() {
        return None;
    }

    // Read last operator activity timestamp.
    let activity_file = repo_root.join(".chump/last-operator-activity");
    let last_secs = std::fs::read_to_string(&activity_file)
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(0);

    if last_secs == 0 {
        return None;
    }

    let now_secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let absent_secs = now_secs.saturating_sub(last_secs);
    let threshold = 24 * 3600_u64;

    if absent_secs < threshold {
        return None;
    }

    Some(ResizeDecision {
        trigger: ResizeTrigger::OperatorAbsent,
        rationale: format!(
            "operator absent {:.1}h in autonomous-mode; reducing to minimum fleet size",
            absent_secs as f64 / 3600.0
        ),
        current_size,
        recommended_size: 1,
    })
}

/// Run all 4 checks; return the first triggered decision (lowest recommended_size wins on tie).
pub fn evaluate(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    let mut decisions: Vec<ResizeDecision> = Vec::new();

    if let Some(d) = check_queue_empty(repo_root, current_size) {
        decisions.push(d);
    }
    if let Some(d) = check_cost_cap(repo_root, current_size) {
        decisions.push(d);
    }
    if let Some(d) = check_flat_ship_rate(repo_root, current_size) {
        decisions.push(d);
    }
    if let Some(d) = check_operator_absent(repo_root, current_size) {
        decisions.push(d);
    }

    // Pick the most aggressive shrink (lowest recommended_size).
    decisions.into_iter().min_by_key(|d| d.recommended_size)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn setup() -> TempDir {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join(".chump")).unwrap();
        fs::create_dir_all(tmp.path().join(".chump-locks")).unwrap();
        tmp
    }

    #[test]
    fn test_queue_empty_no_marker() {
        let tmp = setup();
        // No marker file → no trigger
        assert!(check_queue_empty(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_queue_empty_fresh_marker() {
        let tmp = setup();
        // Marker set just now → not expired
        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        fs::write(tmp.path().join(".chump/queue-empty-since"), now.to_string()).unwrap();
        assert!(check_queue_empty(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_queue_empty_expired_marker() {
        let tmp = setup();
        // Marker set 31 min ago → triggers
        let old = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (31 * 60);
        fs::write(tmp.path().join(".chump/queue-empty-since"), old.to_string()).unwrap();
        let d = check_queue_empty(tmp.path(), 3);
        assert!(d.is_some());
        assert_eq!(d.unwrap().trigger, ResizeTrigger::QueueEmpty);
    }

    #[test]
    fn test_queue_empty_single_worker() {
        let tmp = setup();
        let old = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (31 * 60);
        fs::write(tmp.path().join(".chump/queue-empty-since"), old.to_string()).unwrap();
        // Already at 1 worker → no further shrink
        assert!(check_queue_empty(tmp.path(), 1).is_none());
    }

    #[test]
    fn test_flat_ship_rate_no_ambient() {
        let tmp = setup();
        assert!(check_flat_ship_rate(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_flat_ship_rate_recent_merge() {
        let tmp = setup();
        // Write a recent pr_merged event
        let now_str = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let line = format!("{{\"ts\":\"{now_str}\",\"kind\":\"pr_merged\",\"pr\":1}}\n");
        fs::write(tmp.path().join(".chump-locks/ambient.jsonl"), line).unwrap();
        // Recent merge → no trigger
        assert!(check_flat_ship_rate(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_flat_ship_rate_stale_merge() {
        let tmp = setup();
        // Write a stale pr_merged event (75 min ago)
        let stale_dt = chrono::Utc::now() - chrono::Duration::minutes(75);
        let stale_str = stale_dt.format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let line = format!("{{\"ts\":\"{stale_str}\",\"kind\":\"pr_merged\",\"pr\":1}}\n");
        fs::write(tmp.path().join(".chump-locks/ambient.jsonl"), line).unwrap();
        let d = check_flat_ship_rate(tmp.path(), 3);
        assert!(d.is_some());
        assert_eq!(d.unwrap().trigger, ResizeTrigger::FlatShipRate);
    }

    #[test]
    fn test_operator_absent_no_flag() {
        let tmp = setup();
        assert!(check_operator_absent(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_operator_absent_triggered() {
        let tmp = setup();
        fs::write(tmp.path().join(".chump/autonomous-mode"), "1").unwrap();
        let old = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (25 * 3600); // 25h ago
        fs::write(
            tmp.path().join(".chump/last-operator-activity"),
            old.to_string(),
        )
        .unwrap();
        let d = check_operator_absent(tmp.path(), 3);
        assert!(d.is_some());
        let d = d.unwrap();
        assert_eq!(d.trigger, ResizeTrigger::OperatorAbsent);
        assert_eq!(d.recommended_size, 1);
    }

    #[test]
    fn test_evaluate_no_triggers() {
        let tmp = setup();
        assert!(evaluate(tmp.path(), 2).is_none());
    }

    #[test]
    fn test_evaluate_picks_lowest_recommended() {
        let tmp = setup();
        // Trigger both queue-empty (→ 0) and flat-ship (→ 2)
        let old_ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (31 * 60);
        fs::write(
            tmp.path().join(".chump/queue-empty-since"),
            old_ts.to_string(),
        )
        .unwrap();

        let stale_dt = chrono::Utc::now() - chrono::Duration::minutes(75);
        let stale_str = stale_dt.format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let line = format!("{{\"ts\":\"{stale_str}\",\"kind\":\"pr_merged\",\"pr\":1}}\n");
        fs::write(tmp.path().join(".chump-locks/ambient.jsonl"), line).unwrap();

        // evaluate should pick queue-empty (recommended_size=0, lowest)
        let d = evaluate(tmp.path(), 3).unwrap();
        assert_eq!(d.trigger, ResizeTrigger::QueueEmpty);
        assert_eq!(d.recommended_size, 0);
    }
}
