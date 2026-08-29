//! src/umbrella_progress.rs — META-291: structural-work-rate measurement.
//!
//! `chump health --structural-pr-rate [--window Nd]` answers "of the PRs we
//! actually shipped in the last N days, what fraction closed a structural
//! (fleet-plumbing) gap vs. a user-facing/product one?" It scans
//! `ambient.jsonl` for `kind=ship_grade` events (emitted by every ship,
//! carrying `gap_id`) inside the window, resolves each gap_id's `domain`
//! via the canonical gap store, and buckets `INFRA`/`META` as "structural".
//!
//! Feeds META-290's plumbing-bias trigger and the weekly
//! `kind=structural_work_digest` emitted by
//! `scripts/coord/umbrella-progress-audit.sh digest`.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use chrono::{DateTime, Utc};

use chump_gap_store::GapStore;

#[derive(Debug, Clone, serde::Serialize)]
pub struct StructuralRateReport {
    pub window_days: u64,
    pub total_shipped: u64,
    pub structural_shipped: u64,
    pub rate_pct: f64,
}

impl StructuralRateReport {
    /// True when there is data AND the rate is below the 25% floor (AC#3).
    pub fn breached(&self) -> bool {
        self.total_shipped > 0 && self.rate_pct < 25.0
    }

    pub fn render_text(&self) -> String {
        format!(
            "structural PR rate ({}d window): {:.1}% ({}/{} shipped PRs closed an INFRA/META gap)",
            self.window_days, self.rate_pct, self.structural_shipped, self.total_shipped
        )
    }

    pub fn render_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string())
    }
}

/// Domains treated as "structural" (fleet-plumbing) rather than
/// user-facing/product work. Kept narrow and explicit — INFRA/META are the
/// two domains CLAUDE.md itself reserves for fleet-internal work; any other
/// domain (PWA, PRODUCT, etc.) counts as an outcome-facing ship.
fn is_structural_domain(domain: &str) -> bool {
    matches!(domain.trim().to_uppercase().as_str(), "INFRA" | "META")
}

fn parse_rfc3339_secs(s: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc).timestamp())
}

fn extract_str_field(line: &str, field: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    value.get(field)?.as_str().map(|s| s.to_string())
}

/// Compute the structural PR-ship rate over the trailing `window_days`.
///
/// Reads `ship_grade` ambient events for shipped-gap ids, then resolves
/// each id's domain via the gap store (a gap remains queryable after
/// shipping — status flips to done/shipped but the row is not deleted).
/// Gap ids that no longer resolve (pruned/ghost) are skipped — they don't
/// count toward either bucket, matching "of the PRs we can still identify".
pub fn structural_pr_rate(repo_root: &Path, window_days: u64) -> StructuralRateReport {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let now = Utc::now().timestamp();
    let cutoff = now - (window_days as i64) * 86_400;

    let mut total: u64 = 0;
    let mut structural: u64 = 0;
    let mut domain_cache: HashMap<String, Option<String>> = HashMap::new();

    let store = GapStore::open(repo_root).ok();

    if let Ok(contents) = fs::read_to_string(&ambient_path) {
        for line in contents.lines() {
            if !line.contains("\"ship_grade\"") {
                continue;
            }
            let Some(ts) = extract_str_field(line, "ts") else {
                continue;
            };
            let Some(ts_secs) = parse_rfc3339_secs(&ts) else {
                continue;
            };
            if ts_secs < cutoff {
                continue;
            }
            let Some(gap_id) = extract_str_field(line, "gap_id") else {
                continue;
            };

            let domain = domain_cache.entry(gap_id.clone()).or_insert_with(|| {
                store
                    .as_ref()
                    .and_then(|s| s.get(&gap_id).ok().flatten())
                    .map(|g| g.domain)
            });

            let Some(domain) = domain else {
                continue;
            };

            total += 1;
            if is_structural_domain(domain) {
                structural += 1;
            }
        }
    }

    let rate_pct = if total > 0 {
        (structural as f64 / total as f64) * 100.0
    } else {
        0.0
    };

    StructuralRateReport {
        window_days,
        total_shipped: total,
        structural_shipped: structural,
        rate_pct,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    fn tempdir() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "umbrella-progress-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(d.join(".chump-locks")).unwrap();
        d
    }

    fn write_ambient(root: &Path, lines: &[String]) {
        let mut f = fs::File::create(root.join(".chump-locks/ambient.jsonl")).unwrap();
        for l in lines {
            writeln!(f, "{l}").unwrap();
        }
    }

    #[test]
    fn empty_ambient_yields_zero_total_not_breached() {
        let root = tempdir();
        write_ambient(&root, &[]);
        let report = structural_pr_rate(&root, 14);
        assert_eq!(report.total_shipped, 0);
        assert!(!report.breached());
    }

    #[test]
    fn is_structural_domain_covers_infra_and_meta_only() {
        assert!(is_structural_domain("INFRA"));
        assert!(is_structural_domain("meta"));
        assert!(!is_structural_domain("PWA"));
        assert!(!is_structural_domain("PRODUCT"));
    }

    #[test]
    fn old_events_outside_window_are_excluded() {
        let root = tempdir();
        let old_ts = (Utc::now() - chrono::Duration::days(30)).to_rfc3339();
        write_ambient(
            &root,
            &[format!(
                r#"{{"kind":"ship_grade","ts":"{old_ts}","gap_id":"INFRA-1"}}"#
            )],
        );
        let report = structural_pr_rate(&root, 14);
        assert_eq!(report.total_shipped, 0);
    }
}
