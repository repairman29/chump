//! INFRA-488: Zero Waste mission pillar — track and measure fleet waste.
//!
//! The mission is now: build *credible, effective, resilient,* AND
//! *zero-waste* agents. This module is the primitive measurement layer.
//!
//! The taxonomy uses event kinds already emitted into
//! `.chump-locks/ambient.jsonl` by various subsystems — no new
//! emissions in this MVP. Future gaps extend the taxonomy by tagging
//! more events with `event=ALERT` and one of the kinds below.
//!
//! ## Waste taxonomy (existing event kinds, classified)
//!
//! | Kind                    | Source         | Cost it represents               |
//! |-------------------------|----------------|----------------------------------|
//! | `fleet_wedge`           | INFRA-483      | claude -p 0-byte cycle (~600s)  |
//! | `fleet_starved`         | INFRA-315      | idle worker, no pickable work   |
//! | `lease_expired_server`  | reaper         | session abandoned mid-work      |
//! | `reaper_silent`         | INFRA-120      | reaper job missed its cadence    |
//! | `queue_stuck`           | merge-queue    | PR queue jammed                 |
//! | `ambient_oversize`      | INFRA-122      | rotation didn't run              |
//! | `pr_stuck`              | INFRA-307      | PR stalled needing attention    |
//! | `silent_agent`          | coord          | live session stopped heartbeat  |
//! | `lease_overlap`         | coord          | two sessions claim same files   |
//! | `edit_burst`            | coord          | rapid mutations, rebase risk    |
//!
//! ## Output
//!
//! `chump waste-tally [--since 24h] [--json]` prints a per-kind tally
//! plus rough cost estimates where measurable (e.g. `fleet_wedge`
//! events have `cooldown_secs` field — sum them).

use std::collections::BTreeMap;
use std::path::Path;

/// Per-kind aggregate across the time window.
#[derive(Debug, Clone, Default)]
pub struct WasteEntry {
    pub kind: String,
    pub count: u64,
    /// Sum of any `cooldown_secs`/`elapsed_seconds` field on these events.
    /// Best-effort — not all kinds carry a cost number.
    pub estimated_cost_secs: u64,
}

#[derive(Debug, Clone, Default)]
pub struct WasteReport {
    pub since_seconds: u64,
    pub total_events: u64,
    pub entries: Vec<WasteEntry>,
}

/// The set of `kind` values we classify as waste. Order matches the
/// taxonomy table in the module-level docs.
pub const WASTE_KINDS: &[&str] = &[
    "fleet_wedge",
    "fleet_starved",
    "lease_expired_server",
    "reaper_silent",
    "queue_stuck",
    "ambient_oversize",
    "pr_stuck",
    "silent_agent",
    "lease_overlap",
    "edit_burst",
];

/// Build a waste report for the given time window. `since_secs` is the
/// lookback window; events older than `now - since_secs` are excluded.
pub fn build_report(repo_root: &Path, since_secs: u64) -> WasteReport {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now = current_unix();
    let cutoff = now.saturating_sub(since_secs);

    let mut by_kind: BTreeMap<String, WasteEntry> = BTreeMap::new();
    let mut total_in_window = 0u64;

    for line in contents.lines() {
        // Only inspect lines that look like JSON ALERT events.
        if !line.contains(r#""event":"ALERT""#) && !line.contains(r#""kind":""#) {
            continue;
        }
        let kind = extract_field(line, "kind").unwrap_or_default();
        if !WASTE_KINDS.iter().any(|&k| k == kind) {
            continue;
        }
        // Time-window filter: events without parseable ts are kept (be
        // generous; under-counting is worse than over-counting).
        if let Some(ts) = extract_field(line, "ts") {
            if let Some(unix) = parse_iso8601_to_unix(&ts) {
                if unix < cutoff {
                    continue;
                }
            }
        }
        total_in_window += 1;
        let cost = extract_int_field(line, "cooldown_secs")
            .or_else(|| extract_int_field(line, "elapsed_seconds"))
            .unwrap_or(0);
        let entry = by_kind.entry(kind.clone()).or_insert_with(|| WasteEntry {
            kind: kind.clone(),
            count: 0,
            estimated_cost_secs: 0,
        });
        entry.count += 1;
        entry.estimated_cost_secs = entry.estimated_cost_secs.saturating_add(cost);
    }

    WasteReport {
        since_seconds: since_secs,
        total_events: total_in_window,
        entries: by_kind.into_values().collect(),
    }
}

impl WasteReport {
    /// Render a human-readable summary for the terminal.
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        let hours = self.since_seconds / 3600;
        out.push_str(&format!(
            "═══ Zero Waste Report ═══ (last {} h, total {} waste events)\n",
            hours.max(1),
            self.total_events
        ));
        if self.entries.is_empty() {
            out.push_str("  (no waste events in window — fleet healthy 🎉)\n");
            return out;
        }
        // Sort by count descending for visibility.
        let mut sorted = self.entries.clone();
        sorted.sort_by_key(|e| std::cmp::Reverse(e.count));
        for e in &sorted {
            if e.estimated_cost_secs > 0 {
                let mins = e.estimated_cost_secs / 60;
                out.push_str(&format!(
                    "  {:>6} × {:24}  ~{}m est. cost\n",
                    e.count, e.kind, mins
                ));
            } else {
                out.push_str(&format!("  {:>6} × {}\n", e.count, e.kind));
            }
        }
        let total_mins: u64 = sorted.iter().map(|e| e.estimated_cost_secs).sum::<u64>() / 60;
        if total_mins > 0 {
            out.push_str(&format!(
                "  ─────────────────────────────\n  Estimated wasted compute: ~{}m\n",
                total_mins
            ));
        }
        out
    }

    /// Render as JSON for tooling consumption.
    pub fn render_json(&self) -> String {
        let entries_json: Vec<String> = self
            .entries
            .iter()
            .map(|e| {
                format!(
                    r#"{{"kind":"{}","count":{},"estimated_cost_secs":{}}}"#,
                    json_escape(&e.kind),
                    e.count,
                    e.estimated_cost_secs
                )
            })
            .collect();
        format!(
            r#"{{"since_seconds":{},"total_events":{},"entries":[{}]}}"#,
            self.since_seconds,
            self.total_events,
            entries_json.join(",")
        )
    }
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn current_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Parse ISO-8601 "YYYY-MM-DDTHH:MM:SSZ" via date(1). Permissive: returns
/// None on any failure; caller should fall through.
fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    let out = std::process::Command::new("date")
        .args(["-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", s, "+%s"])
        .output()
        .ok()?;
    if out.status.success() {
        return String::from_utf8_lossy(&out.stdout).trim().parse().ok();
    }
    let out2 = std::process::Command::new("date")
        .args(["-u", "-d", s, "+%s"])
        .output()
        .ok()?;
    if !out2.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out2.stdout).trim().parse().ok()
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":""#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
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

fn extract_int_field(line: &str, field: &str) -> Option<u64> {
    let needle = format!(r#""{}":"#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
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

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra488-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn write_ambient(root: &Path, lines: &[&str]) {
        let lock_dir = root.join(".chump-locks");
        std::fs::create_dir_all(&lock_dir).unwrap();
        let path = lock_dir.join("ambient.jsonl");
        std::fs::write(&path, lines.join("\n") + "\n").unwrap();
    }

    #[test]
    fn infra488_empty_window_is_healthy() {
        let tmp = tempdir();
        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_events, 0);
        let text = report.render_text();
        assert!(text.contains("fleet healthy"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra488_classifies_known_waste_kinds() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let l1 = format!(
            r#"{{"event":"ALERT","kind":"fleet_wedge","ts":"{}","gap_id":"INFRA-1","cooldown_secs":14400}}"#,
            now_iso
        );
        let l2 = format!(
            r#"{{"event":"ALERT","kind":"fleet_starved","ts":"{}"}}"#,
            now_iso
        );
        let l3 = format!(
            r#"{{"event":"ALERT","kind":"lease_expired_server","ts":"{}"}}"#,
            now_iso
        );
        // Non-waste kind — should be ignored.
        let l4 = format!(
            r#"{{"event":"ALERT","kind":"file_edit","ts":"{}"}}"#,
            now_iso
        );
        write_ambient(&tmp, &[l1.as_str(), l2.as_str(), l3.as_str(), l4.as_str()]);
        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_events, 3, "only 3 of 4 lines are waste");
        let kinds: Vec<&str> = report.entries.iter().map(|e| e.kind.as_str()).collect();
        assert!(kinds.contains(&"fleet_wedge"));
        assert!(kinds.contains(&"fleet_starved"));
        assert!(kinds.contains(&"lease_expired_server"));
        // fleet_wedge has cooldown_secs=14400 — picked up as cost.
        let wedge = report
            .entries
            .iter()
            .find(|e| e.kind == "fleet_wedge")
            .unwrap();
        assert_eq!(wedge.estimated_cost_secs, 14400);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra488_excludes_events_outside_window() {
        let tmp = tempdir();
        // Old timestamp — way outside any reasonable window.
        let old = r#"{"event":"ALERT","kind":"fleet_wedge","ts":"2020-01-01T00:00:00Z","cooldown_secs":3600}"#;
        write_ambient(&tmp, &[old]);
        // 1-hour window — old event excluded.
        let report = build_report(&tmp, 3600);
        assert_eq!(report.total_events, 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra488_render_text_shows_cost_estimate() {
        let report = WasteReport {
            since_seconds: 86400,
            total_events: 2,
            entries: vec![WasteEntry {
                kind: "fleet_wedge".into(),
                count: 2,
                estimated_cost_secs: 28800, // 8 hours
            }],
        };
        let text = report.render_text();
        assert!(text.contains("Zero Waste Report"));
        assert!(text.contains("fleet_wedge"));
        assert!(text.contains("~480m est. cost"), "got: {}", text);
        assert!(text.contains("Estimated wasted compute"));
    }

    #[test]
    fn infra488_render_json_is_parseable() {
        let report = WasteReport {
            since_seconds: 86400,
            total_events: 1,
            entries: vec![WasteEntry {
                kind: "fleet_starved".into(),
                count: 5,
                estimated_cost_secs: 0,
            }],
        };
        let json = report.render_json();
        // Quick structural checks — not full parser.
        assert!(json.starts_with("{"));
        assert!(json.contains(r#""since_seconds":86400"#));
        assert!(json.contains(r#""total_events":1"#));
        assert!(json.contains(r#""kind":"fleet_starved""#));
        assert!(json.contains(r#""count":5"#));
    }

    #[test]
    fn infra488_taxonomy_has_all_documented_kinds() {
        // Smoke test: the taxonomy table in module docs lists 10 kinds.
        // If a future commit adds/removes a kind, the constant is the
        // single source of truth.
        assert_eq!(WASTE_KINDS.len(), 10);
    }

    fn chrono_now_iso() -> String {
        // Use date(1) — same as the production helper.
        std::process::Command::new("date")
            .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "2026-05-05T20:00:00Z".to_string())
    }
}
