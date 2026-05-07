//! INFRA-599: 4-pillar mission scorecard.
//!
//! `chump mission-grade` computes per-pillar gap counts (pickable,
//! in_flight, shipped_24h) and emits a `kind=mission_grade` ambient event.
//! Designed to run every 30 min via launchd so operators never have to ask
//! "are we on mission?" manually.
//!
//! Pillar classification: gap titles must begin with one of:
//!   EFFECTIVE: | CREDIBLE: | RESILIENT: | ZERO-WASTE:
//! (case-insensitive). Untagged gaps are excluded from pillar counts.

use std::path::Path;

pub const PILLAR_PREFIXES: [(&str, &str); 4] = [
    ("EFFECTIVE:", "effective"),
    ("CREDIBLE:", "credible"),
    ("RESILIENT:", "resilient"),
    ("ZERO-WASTE:", "zero_waste"),
];

#[derive(Debug, Default, Clone)]
pub struct PillarCounts {
    pub count_pickable: u64,
    pub count_in_flight: u64,
    pub count_shipped_24h: u64,
}

#[derive(Debug, Default, Clone)]
pub struct MissionGradeReport {
    pub effective: PillarCounts,
    pub credible: PillarCounts,
    pub resilient: PillarCounts,
    pub zero_waste: PillarCounts,
    pub ts: String,
}

fn classify_pillar(title: &str) -> Option<usize> {
    let up = title.to_uppercase();
    for (i, (prefix, _)) in PILLAR_PREFIXES.iter().enumerate() {
        if up.starts_with(prefix) {
            return Some(i);
        }
    }
    None
}

fn collect_active_lease_gap_ids(repo_root: &Path) -> Vec<String> {
    let lock_dir = repo_root.join(".chump-locks");
    let mut ids = Vec::new();
    let Ok(entries) = std::fs::read_dir(&lock_dir) else {
        return ids;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !name.ends_with(".json") || name.starts_with('.') || name.contains("cooldown") {
            continue;
        }
        let contents = std::fs::read_to_string(&path).unwrap_or_default();
        if let Some(gap_id) = extract_field(&contents, "gap_id") {
            if !gap_id.is_empty() {
                ids.push(gap_id);
            }
        }
    }
    ids
}

pub fn build_report(repo_root: &Path) -> MissionGradeReport {
    let mut report = MissionGradeReport {
        ts: current_iso8601(),
        ..Default::default()
    };

    let gs = match crate::gap_store::GapStore::open(repo_root) {
        Ok(g) => g,
        Err(_) => return report,
    };

    let now = current_unix();
    let cutoff_24h = now.saturating_sub(24 * 3600);
    let active_leases = collect_active_lease_gap_ids(repo_root);

    let mut pillars = [
        PillarCounts::default(),
        PillarCounts::default(),
        PillarCounts::default(),
        PillarCounts::default(),
    ];

    if let Ok(open_gaps) = gs.list(Some("open")) {
        for gap in &open_gaps {
            if let Some(idx) = classify_pillar(&gap.title) {
                if active_leases.contains(&gap.id) {
                    pillars[idx].count_in_flight += 1;
                } else {
                    pillars[idx].count_pickable += 1;
                }
            }
        }
    }

    if let Ok(done_gaps) = gs.list(Some("done")) {
        for gap in &done_gaps {
            if let Some(closed) = gap.closed_at {
                if closed as u64 >= cutoff_24h {
                    if let Some(idx) = classify_pillar(&gap.title) {
                        pillars[idx].count_shipped_24h += 1;
                    }
                }
            }
        }
    }

    report.effective = pillars[0].clone();
    report.credible = pillars[1].clone();
    report.resilient = pillars[2].clone();
    report.zero_waste = pillars[3].clone();
    report
}

pub fn emit(repo_root: &Path, report: &MissionGradeReport) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let json = report.render_event_json();
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", json);
    }
}

impl MissionGradeReport {
    pub fn render_event_json(&self) -> String {
        format!(
            r#"{{"ts":"{ts}","kind":"mission_grade","effective":{{"count_pickable":{ep},"count_in_flight":{ei},"count_shipped_24h":{es}}},"credible":{{"count_pickable":{cp},"count_in_flight":{ci},"count_shipped_24h":{cs}}},"resilient":{{"count_pickable":{rp},"count_in_flight":{ri},"count_shipped_24h":{rs}}},"zero_waste":{{"count_pickable":{zp},"count_in_flight":{zi},"count_shipped_24h":{zs}}}}}"#,
            ts = self.ts,
            ep = self.effective.count_pickable,
            ei = self.effective.count_in_flight,
            es = self.effective.count_shipped_24h,
            cp = self.credible.count_pickable,
            ci = self.credible.count_in_flight,
            cs = self.credible.count_shipped_24h,
            rp = self.resilient.count_pickable,
            ri = self.resilient.count_in_flight,
            rs = self.resilient.count_shipped_24h,
            zp = self.zero_waste.count_pickable,
            zi = self.zero_waste.count_in_flight,
            zs = self.zero_waste.count_shipped_24h,
        )
    }

    pub fn render_json(&self) -> String {
        self.render_event_json()
    }

    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Mission Grade (4-Pillar Scorecard) ═══\n");
        out.push_str(&format!(
            "  {:<12} {:>10} {:>10} {:>14}\n",
            "Pillar", "Pickable", "In-flight", "Shipped(24h)"
        ));
        out.push_str(&format!(
            "  {:<12} {:>10} {:>10} {:>14}\n",
            "EFFECTIVE",
            self.effective.count_pickable,
            self.effective.count_in_flight,
            self.effective.count_shipped_24h
        ));
        out.push_str(&format!(
            "  {:<12} {:>10} {:>10} {:>14}\n",
            "CREDIBLE",
            self.credible.count_pickable,
            self.credible.count_in_flight,
            self.credible.count_shipped_24h
        ));
        out.push_str(&format!(
            "  {:<12} {:>10} {:>10} {:>14}\n",
            "RESILIENT",
            self.resilient.count_pickable,
            self.resilient.count_in_flight,
            self.resilient.count_shipped_24h
        ));
        out.push_str(&format!(
            "  {:<12} {:>10} {:>10} {:>14}\n",
            "ZERO-WASTE",
            self.zero_waste.count_pickable,
            self.zero_waste.count_in_flight,
            self.zero_waste.count_shipped_24h
        ));

        // Threshold alerts: any pillar with shipped_24h=0 is a warning.
        let starved: Vec<&str> = [
            (self.effective.count_shipped_24h == 0, "EFFECTIVE"),
            (self.credible.count_shipped_24h == 0, "CREDIBLE"),
            (self.resilient.count_shipped_24h == 0, "RESILIENT"),
            (self.zero_waste.count_shipped_24h == 0, "ZERO-WASTE"),
        ]
        .iter()
        .filter_map(|(zero, name)| if *zero { Some(*name) } else { None })
        .collect();

        if !starved.is_empty() {
            out.push_str(&format!(
                "\n  ALERT: shipped_24h=0 for: {}\n",
                starved.join(", ")
            ));
        }
        out.push_str(&format!("\n  Generated: {}\n", self.ts));
        out
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

fn current_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let out = std::process::Command::new("date")
        .args(["-u", "-r", &secs.to_string(), "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok());
    if let Some(s) = out {
        return s.trim().to_string();
    }
    // Fallback: GNU date
    let out2 = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok());
    out2.map(|s| s.trim().to_string())
        .unwrap_or_else(|| format!("{}", secs))
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":""#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

// ── Unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_classify_effective() {
        assert_eq!(classify_pillar("EFFECTIVE: ship faster"), Some(0));
    }

    #[test]
    fn test_classify_credible() {
        assert_eq!(classify_pillar("CREDIBLE: add scorecard"), Some(1));
    }

    #[test]
    fn test_classify_resilient() {
        assert_eq!(classify_pillar("RESILIENT: watchdog restart"), Some(2));
    }

    #[test]
    fn test_classify_zero_waste() {
        assert_eq!(classify_pillar("ZERO-WASTE: trim budget"), Some(3));
    }

    #[test]
    fn test_classify_untagged() {
        assert_eq!(classify_pillar("fix login bug"), None);
    }

    #[test]
    fn test_render_event_json_contains_kind() {
        let report = MissionGradeReport {
            ts: "2026-05-06T17:00:00Z".to_string(),
            ..Default::default()
        };
        let json = report.render_event_json();
        assert!(json.contains(r#""kind":"mission_grade""#));
        assert!(json.contains(r#""effective""#));
        assert!(json.contains(r#""zero_waste""#));
        assert!(json.contains(r#""count_pickable""#));
        assert!(json.contains(r#""count_shipped_24h""#));
    }

    #[test]
    fn test_render_text_alert_on_zero_shipped() {
        let report = MissionGradeReport {
            ts: "2026-05-06T17:00:00Z".to_string(),
            effective: PillarCounts {
                count_pickable: 2,
                count_in_flight: 1,
                count_shipped_24h: 0,
            },
            ..Default::default()
        };
        let text = report.render_text();
        assert!(text.contains("ALERT"));
        assert!(text.contains("EFFECTIVE"));
    }

    #[test]
    fn test_render_text_no_alert_when_all_shipped() {
        let report = MissionGradeReport {
            ts: "2026-05-06T17:00:00Z".to_string(),
            effective: PillarCounts {
                count_pickable: 1,
                count_in_flight: 0,
                count_shipped_24h: 1,
            },
            credible: PillarCounts {
                count_pickable: 0,
                count_in_flight: 1,
                count_shipped_24h: 2,
            },
            resilient: PillarCounts {
                count_pickable: 1,
                count_in_flight: 0,
                count_shipped_24h: 1,
            },
            zero_waste: PillarCounts {
                count_pickable: 2,
                count_in_flight: 0,
                count_shipped_24h: 3,
            },
        };
        let text = report.render_text();
        assert!(!text.contains("ALERT"));
    }
}
