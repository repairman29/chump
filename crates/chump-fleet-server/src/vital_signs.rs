//! `GET /api/vital-signs` (RESILIENT-1088 cockpit) — unauthenticated read of
//! the fleet's vital-signs contract plus the **continuous** autonomous
//! ship-rate, so the daily cockpit's zero-touch and p_full_trek lead gauges
//! stop rendering permanent grey.
//!
//! Two dark sources fed these tiles before:
//!   * The zero-touch tile read `autonomous_ship_rate_regression` ambient
//!     events — but that emitter only fires on a >10pp *drop*
//!     (`scripts/dispatch/autonomous-ship-rate.sh`), so on a healthy fleet no
//!     event exists and the tile is grey forever. The *continuous* rate is
//!     appended every run to `~/.chump/metrics/autonomous-ship-rate.jsonl`;
//!     this route reads the newest row.
//!   * The p_full_trek / pillar gauges come from `vital-signs.sh`
//!     (`~/.chump/vital-signs.json`, the shared `render-vital-signs.sh`
//!     contract). This route serves that JSON verbatim.
//!
//! Both are **read-only, count/gauge-only**, safe on the tailnet bind per
//! `docs/process/COCKPIT.md` §2. Neither source is fabricated: when a file is
//! absent (its organ isn't deployed on this node yet — e.g. the vital-signs
//! collector, or the durability gauge #4604 that would light hours-unattended)
//! the corresponding block reports `available:false` and the tile stays
//! honest-grey, naming what must ship.

use serde::Serialize;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// CREDIBLE-047 baseline zero-touch rate (%), the line the tile colors against.
pub const AUTONOMY_BASELINE_PCT: f64 = 12.5;

/// Top-level response for `GET /api/vital-signs`.
#[derive(Debug, Serialize)]
pub struct VitalSignsResponse {
    /// Server wall-clock (ms) — the tile's age stamp.
    pub generated_ms: i64,
    /// True when `vital-signs.json` was found and parsed.
    pub available: bool,
    /// The `vital-signs.json` document verbatim (`p_full_trek`, `signs[]`,
    /// `capability_lifecycle`, …), or null when the collector hasn't run here.
    pub vital_signs: Option<Value>,
    /// Continuous autonomous ship-rate, read independently of vital-signs.json.
    pub autonomy: AutonomyPulse,
    /// Provenance / dark-source reason for the vital-signs block.
    pub note: String,
}

/// Continuous zero-touch pulse from the metrics ledger. Fields are `Option` so
/// a dark ledger renders null (grey), never a fabricated 0.
#[derive(Debug, Serialize, Default)]
pub struct AutonomyPulse {
    /// True when the metrics ledger was found and a row parsed.
    pub available: bool,
    /// `autonomous_rate × 100` from the newest ledger row.
    pub rate_pct: Option<f64>,
    /// Fleet-filed merged PRs in the window.
    pub fleet_filed: Option<i64>,
    /// Fleet-filed PRs that merged with zero operator touch.
    pub fleet_filed_autonomous: Option<i64>,
    /// Total merged PRs the window scanned.
    pub total_prs: Option<i64>,
    /// The row's date (`YYYY-MM-DD`).
    pub date: Option<String>,
    /// CREDIBLE-047 baseline the tile colors against.
    pub baseline_pct: f64,
    /// Provenance / dark-source reason.
    pub note: String,
}

/// Persons-served read for `GET /api/mission` (north-star tile). Sourced from
/// the `outcomes_delivered` vital sign — the contract's canonical
/// "things reaching a person" proxy. `value` is `null` until a real
/// delivery-to-a-person signal is wired, so the tile stays honest-grey.
#[derive(Debug, Serialize)]
pub struct PersonsServed {
    /// The north-star count, or null when uninstrumented (today: null).
    pub persons_served: Option<f64>,
    /// What would light it up (the sign's `basis`), so grey is self-explaining.
    pub basis: String,
    /// Where the number came from.
    pub source: String,
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn home_chump() -> Option<PathBuf> {
    std::env::var("HOME")
        .ok()
        .filter(|h| !h.is_empty())
        .map(|h| PathBuf::from(h).join(".chump"))
}

/// First path in `candidates` that exists on disk, if any.
fn first_existing(candidates: &[PathBuf]) -> Option<PathBuf> {
    candidates.iter().find(|p| p.is_file()).cloned()
}

/// Candidate locations for `vital-signs.json`: the repo dot-dir first (test /
/// co-located), then the run-user `$HOME/.chump` default `vital-signs.sh`
/// writes to.
fn vital_signs_candidates(repo_root: &Path) -> Vec<PathBuf> {
    let mut v = vec![repo_root.join(".chump").join("vital-signs.json")];
    if let Some(h) = home_chump() {
        v.push(h.join("vital-signs.json"));
    }
    v
}

/// Candidate locations for the autonomous-ship-rate ledger.
fn autonomy_candidates(repo_root: &Path) -> Vec<PathBuf> {
    let mut v = vec![repo_root
        .join(".chump")
        .join("metrics")
        .join("autonomous-ship-rate.jsonl")];
    if let Some(h) = home_chump() {
        v.push(h.join("metrics").join("autonomous-ship-rate.jsonl"));
    }
    v
}

/// Parse the newest usable row from an `autonomous-ship-rate.jsonl` body.
/// Scans bottom-up for the first line carrying an `autonomous_rate`. Pure so
/// the ledger-shape contract is unit-testable without disk.
pub fn parse_autonomy_ledger(body: &str) -> AutonomyPulse {
    for line in body.lines().rev() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(rate) = v.get("autonomous_rate").and_then(Value::as_f64) else {
            continue;
        };
        return AutonomyPulse {
            available: true,
            rate_pct: Some(rate * 100.0),
            fleet_filed: v.get("fleet_filed").and_then(Value::as_i64),
            fleet_filed_autonomous: v.get("fleet_filed_autonomous").and_then(Value::as_i64),
            total_prs: v.get("total_prs").and_then(Value::as_i64),
            date: v.get("date").and_then(Value::as_str).map(str::to_string),
            baseline_pct: AUTONOMY_BASELINE_PCT,
            note: "newest row of autonomous-ship-rate.jsonl (CREDIBLE-047)".into(),
        };
    }
    AutonomyPulse {
        available: false,
        baseline_pct: AUTONOMY_BASELINE_PCT,
        note: "no parseable row in autonomous-ship-rate.jsonl".into(),
        ..Default::default()
    }
}

fn read_autonomy(repo_root: &Path) -> AutonomyPulse {
    match first_existing(&autonomy_candidates(repo_root)) {
        Some(path) => match std::fs::read_to_string(&path) {
            Ok(body) => parse_autonomy_ledger(&body),
            Err(e) => AutonomyPulse {
                available: false,
                baseline_pct: AUTONOMY_BASELINE_PCT,
                note: format!("autonomous-ship-rate.jsonl unreadable: {e}"),
                ..Default::default()
            },
        },
        None => AutonomyPulse {
            available: false,
            baseline_pct: AUTONOMY_BASELINE_PCT,
            note: "no autonomous-ship-rate.jsonl — run scripts/dispatch/autonomous-ship-rate.sh"
                .into(),
            ..Default::default()
        },
    }
}

/// Build the full `GET /api/vital-signs` response for `repo_root`.
pub fn build_response(repo_root: &Path) -> VitalSignsResponse {
    let generated_ms = now_ms();
    let autonomy = read_autonomy(repo_root);

    match first_existing(&vital_signs_candidates(repo_root)) {
        Some(path) => match std::fs::read_to_string(&path) {
            Ok(body) => match serde_json::from_str::<Value>(&body) {
                Ok(v) => VitalSignsResponse {
                    generated_ms,
                    available: true,
                    vital_signs: Some(v),
                    autonomy,
                    note: format!("vital-signs.json @ {}", path.display()),
                },
                Err(e) => VitalSignsResponse {
                    generated_ms,
                    available: false,
                    vital_signs: None,
                    autonomy,
                    note: format!("vital-signs.json malformed: {e}"),
                },
            },
            Err(e) => VitalSignsResponse {
                generated_ms,
                available: false,
                vital_signs: None,
                autonomy,
                note: format!("vital-signs.json unreadable: {e}"),
            },
        },
        None => VitalSignsResponse {
            generated_ms,
            available: false,
            vital_signs: None,
            autonomy,
            note: "no vital-signs.json — vital-signs collector not deployed on this node".into(),
        },
    }
}

/// Extract persons-served (the `outcomes_delivered` sign's value) from a
/// vital-signs document. Pure so the contract is unit-testable.
pub fn extract_persons_served(vital: &Value) -> PersonsServed {
    let sign = vital
        .get("signs")
        .and_then(Value::as_array)
        .and_then(|signs| {
            signs
                .iter()
                .find(|s| s.get("key").and_then(Value::as_str) == Some("outcomes_delivered"))
        });
    match sign {
        Some(s) => PersonsServed {
            persons_served: s.get("value").and_then(Value::as_f64),
            basis: s
                .get("basis")
                .and_then(Value::as_str)
                .unwrap_or("outcomes_delivered vital sign")
                .to_string(),
            source: "vital-signs.json · outcomes_delivered".into(),
        },
        None => PersonsServed {
            persons_served: None,
            basis: "outcomes_delivered sign absent — vital-signs collector not deployed here"
                .into(),
            source: "vital-signs.json · outcomes_delivered".into(),
        },
    }
}

/// Read persons-served for `GET /api/mission`. Honest-null when vital-signs is
/// dark or the sign is uninstrumented (today: null everywhere).
pub fn read_persons_served(repo_root: &Path) -> PersonsServed {
    match first_existing(&vital_signs_candidates(repo_root))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|b| serde_json::from_str::<Value>(&b).ok())
    {
        Some(v) => extract_persons_served(&v),
        None => PersonsServed {
            persons_served: None,
            basis: "no delivery-to-a-person signal yet; needs a deploy-to-user / giveaway-told \
                    ambient event keyed to an external human (COCKPIT.md north star)"
                .into(),
            source: "vital-signs.json · outcomes_delivered".into(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_autonomy_takes_newest_row_with_rate() {
        let body = "\
{\"date\":\"2026-09-08\",\"total_prs\":50,\"fleet_filed\":40,\"fleet_filed_autonomous\":10,\"autonomous_rate\":0.250}
{\"date\":\"2026-09-09\",\"total_prs\":52,\"fleet_filed\":44,\"fleet_filed_autonomous\":22,\"autonomous_rate\":0.500}
";
        let p = parse_autonomy_ledger(body);
        assert!(p.available);
        assert_eq!(p.rate_pct, Some(50.0));
        assert_eq!(p.fleet_filed, Some(44));
        assert_eq!(p.fleet_filed_autonomous, Some(22));
        assert_eq!(p.date.as_deref(), Some("2026-09-09"));
        assert_eq!(p.baseline_pct, AUTONOMY_BASELINE_PCT);
    }

    #[test]
    fn parse_autonomy_skips_trailing_garbage_line() {
        let body = "\
{\"date\":\"2026-09-09\",\"autonomous_rate\":0.4}
not-json-at-all
";
        let p = parse_autonomy_ledger(body);
        assert!(p.available);
        assert_eq!(p.rate_pct, Some(40.0));
    }

    #[test]
    fn parse_autonomy_empty_is_unavailable() {
        let p = parse_autonomy_ledger("\n  \n");
        assert!(!p.available);
        assert!(p.rate_pct.is_none());
        assert_eq!(p.baseline_pct, AUTONOMY_BASELINE_PCT);
    }

    #[test]
    fn extract_persons_served_reads_outcomes_value() {
        let v = serde_json::json!({
            "signs": [
                {"key": "merge_throughput", "value": 53},
                {"key": "outcomes_delivered", "value": 3, "basis": "3 delivery events"}
            ]
        });
        let p = extract_persons_served(&v);
        assert_eq!(p.persons_served, Some(3.0));
        assert!(p.basis.contains("delivery"));
    }

    #[test]
    fn extract_persons_served_null_when_sign_uninstrumented() {
        // The real, current shape: outcomes_delivered present but value null.
        let v = serde_json::json!({
            "signs": [
                {"key": "outcomes_delivered", "value": serde_json::Value::Null,
                 "basis": "uninstrumented: no delivery-to-a-person signal exists yet"}
            ]
        });
        let p = extract_persons_served(&v);
        assert!(p.persons_served.is_none());
        assert!(p.basis.contains("uninstrumented"));
    }

    #[test]
    fn extract_persons_served_null_when_sign_absent() {
        let v = serde_json::json!({"signs": []});
        let p = extract_persons_served(&v);
        assert!(p.persons_served.is_none());
    }

    #[test]
    fn build_response_missing_files_is_available_false_not_a_panic() {
        // A repo root with no .chump and (almost certainly) no matching $HOME
        // ledger — the vital block must be dark, never a fabricated gauge.
        let r = build_response(Path::new("/nonexistent-repo-root-xyz-123"));
        assert!(!r.available);
        assert!(r.vital_signs.is_none());
    }
}
