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
//! | `session_abandoned`     | INFRA-477/492  | session ended without shipping  |
//! | `session_starved`       | INFRA-477/492  | session timed out (rc=124)      |
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
    /// INFRA-489: number of unique incidents after deduplicating by
    /// (kind, entity). A single stuck reaper that re-emits every 30min
    /// for 12h shows as `count=24, incidents=1`. `incidents` is the
    /// headline metric going forward; `count` is preserved for
    /// forensics. Equals `count` when no entity can be extracted.
    pub incidents: u64,
    /// Sum of any `cooldown_secs`/`elapsed_seconds` field on these events.
    /// Best-effort — not all kinds carry a cost number.
    pub estimated_cost_secs: u64,
}

#[derive(Debug, Clone, Default)]
pub struct WasteReport {
    pub since_seconds: u64,
    pub total_events: u64,
    /// INFRA-489: total unique incidents (deduplicated). Always
    /// `<= total_events`. The 7-day baseline measured 169 events but
    /// only ~50 unique incidents — the rest were re-fired alerts on
    /// the same problem.
    pub total_incidents: u64,
    pub entries: Vec<WasteEntry>,
}

/// The set of `kind` values we classify as waste. Order matches the
/// taxonomy table in the module-level docs.
///
/// **INFRA-493:** synthetic kinds `session_abandoned` and
/// `session_starved` are also counted — these are derived from
/// INFRA-477's `session_end` events filtered by `outcome`. They have
/// no event line literally tagged `kind=session_abandoned`; the
/// classifier promotes `event=session_end` + `outcome=abandoned` into
/// that synthetic kind for tally purposes.
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
    "session_abandoned", // INFRA-493 synthetic — from session_end outcome=abandoned
    "session_starved",   // INFRA-493 synthetic — from session_end outcome=starved
];

/// Build a waste report for the given time window. `since_secs` is the
/// lookback window; events older than `now - since_secs` are excluded.
///
/// **INFRA-489:** also computes per-kind unique incidents by
/// deduplicating against an entity key extracted from each event. Most
/// re-fire alerts (reaper_silent every 30min, silent_agent every cycle)
/// share the same entity, so a 12h-stuck reaper collapses from 24
/// alerts to 1 incident. The entity comes from any of `session`,
/// `reaper`, `pr`, `gap_id`, `agent` — whichever the event carries.
/// Falls back to a per-event unique key (counts as its own incident)
/// when no entity field is present.
pub fn build_report(repo_root: &Path, since_secs: u64) -> WasteReport {
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now = current_unix();
    let cutoff = now.saturating_sub(since_secs);

    use std::collections::HashSet;
    let mut by_kind: BTreeMap<String, (WasteEntry, HashSet<String>)> = BTreeMap::new();
    let mut total_in_window = 0u64;
    let mut anon_seq: u64 = 0;

    for line in contents.lines() {
        // Only inspect lines that look like JSON ALERT events OR the
        // INFRA-477 session_end events (INFRA-493 promotes those with
        // outcome=abandoned|starved into synthetic waste kinds).
        let is_alert = line.contains(r#""event":"ALERT""#) || line.contains(r#""kind":""#);
        let is_session_end = line.contains(r#""kind":"session_end""#);
        if !is_alert && !is_session_end {
            continue;
        }

        // INFRA-493: classify session_end by outcome before the WASTE_KINDS
        // filter. session_end events themselves are not waste — only the
        // ones with outcome=abandoned|starved are.
        let raw_kind = extract_field(line, "kind").unwrap_or_default();
        let kind = if raw_kind == "session_end" {
            match extract_field(line, "outcome").as_deref() {
                Some("abandoned") => "session_abandoned".to_string(),
                Some("starved") => "session_starved".to_string(),
                _ => continue, // outcome=shipped is not waste; skip.
            }
        } else {
            raw_kind
        };
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

        // INFRA-489: kind-aware entity extraction. The naive "first
        // session field wins" approach picks the WATCHER (the coord
        // process emitting the alert), not the entity the alert is
        // ABOUT. silent_agent and lease_expired_server hide the actual
        // session in the `note` field's "session=X" substring; the
        // top-level `session` field is just the coord watcher and is
        // identical across all alerts.
        let entity = match kind.as_str() {
            "silent_agent" | "lease_expired_server" | "lease_overlap" | "edit_burst" => {
                // Entity is in the note's session= substring; gap_id is
                // a fallback for events that omit session.
                extract_session_from_note(line).or_else(|| extract_field(line, "gap_id"))
            }
            "reaper_silent" => extract_field(line, "reaper"),
            "pr_stuck" => extract_int_field(line, "pr")
                .map(|n| n.to_string())
                .or_else(|| {
                    // Legacy text form: '#1115 DIRTY ...'
                    let note = extract_field(line, "note").unwrap_or_default();
                    if note.starts_with('#') {
                        let end = note.find(' ').unwrap_or(note.len());
                        Some(note[..end].to_string())
                    } else {
                        None
                    }
                }),
            "fleet_wedge" | "fleet_starved" => {
                extract_field(line, "gap_id").or_else(|| extract_field(line, "agent"))
            }
            // INFRA-493: synthetic kinds — session_id is the entity.
            "session_abandoned" | "session_starved" => extract_field(line, "session_id")
                .or_else(|| extract_field(line, "session"))
                .or_else(|| extract_field(line, "gap_id")),
            // queue_stuck, ambient_oversize, silent_agent's siblings:
            // fall through to the generic search.
            _ => extract_field(line, "session")
                .or_else(|| extract_field(line, "reaper"))
                .or_else(|| extract_int_field(line, "pr").map(|n| n.to_string()))
                .or_else(|| extract_field(line, "gap_id"))
                .or_else(|| extract_field(line, "agent"))
                .or_else(|| extract_session_from_note(line)),
        }
        .unwrap_or_else(|| {
            anon_seq += 1;
            format!("__anon_{}", anon_seq)
        });

        let bucket = by_kind.entry(kind.clone()).or_insert_with(|| {
            (
                WasteEntry {
                    kind: kind.clone(),
                    count: 0,
                    incidents: 0,
                    estimated_cost_secs: 0,
                },
                HashSet::new(),
            )
        });
        bucket.0.count += 1;
        bucket.0.estimated_cost_secs = bucket.0.estimated_cost_secs.saturating_add(cost);
        bucket.1.insert(entity);
    }

    // Realize incidents = unique entity count.
    let mut total_incidents = 0u64;
    let entries: Vec<WasteEntry> = by_kind
        .into_values()
        .map(|(mut e, set)| {
            e.incidents = set.len() as u64;
            total_incidents += e.incidents;
            e
        })
        .collect();

    WasteReport {
        since_seconds: since_secs,
        total_events: total_in_window,
        total_incidents,
        entries,
    }
}

/// Parse the legacy free-text `note` field for `session=<id>`. Coord ALERTs
/// emit JSON like `{"kind":"silent_agent","note":"session=infra-470-fix gap=..."}` —
/// the entity for dedup is hidden inside `note`.
fn extract_session_from_note(line: &str) -> Option<String> {
    let note = extract_field(line, "note")?;
    let needle = "session=";
    let start = note.find(needle)? + needle.len();
    let rest = &note[start..];
    let end = rest
        .find(|c: char| c.is_whitespace() || c == ',')
        .unwrap_or(rest.len());
    if end == 0 {
        return None;
    }
    Some(rest[..end].to_string())
}

impl WasteReport {
    /// Render a human-readable summary for the terminal.
    /// INFRA-489: headlines unique incidents (deduped by entity), with
    /// raw event count shown alongside in parentheses for forensic
    /// transparency. The 7-day baseline of 169 events compressed to ~50
    /// incidents — the rest were re-fired alerts on the same problem.
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        let hours = self.since_seconds / 3600;
        out.push_str(&format!(
            "═══ Zero Waste Report ═══ (last {} h, {} incidents from {} alerts)\n",
            hours.max(1),
            self.total_incidents,
            self.total_events
        ));
        if self.entries.is_empty() {
            out.push_str("  (no waste events in window — fleet healthy 🎉)\n");
            return out;
        }
        // Sort by incidents descending — re-fired alerts shouldn't dominate.
        let mut sorted = self.entries.clone();
        sorted.sort_by_key(|e| std::cmp::Reverse(e.incidents));
        for e in &sorted {
            let inflation = if e.incidents > 0 && e.count > e.incidents {
                format!(" (×{} alerts)", e.count)
            } else {
                String::new()
            };
            if e.estimated_cost_secs > 0 {
                let mins = e.estimated_cost_secs / 60;
                out.push_str(&format!(
                    "  {:>4} × {:24}{}  ~{}m est. cost\n",
                    e.incidents, e.kind, inflation, mins
                ));
            } else {
                out.push_str(&format!("  {:>4} × {}{}\n", e.incidents, e.kind, inflation));
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
    /// INFRA-489: each entry now carries `incidents` (deduped) alongside
    /// `count` (raw); top level adds `total_incidents`.
    pub fn render_json(&self) -> String {
        let entries_json: Vec<String> = self
            .entries
            .iter()
            .map(|e| {
                format!(
                    r#"{{"kind":"{}","count":{},"incidents":{},"estimated_cost_secs":{}}}"#,
                    json_escape(&e.kind),
                    e.count,
                    e.incidents,
                    e.estimated_cost_secs
                )
            })
            .collect();
        format!(
            r#"{{"since_seconds":{},"total_events":{},"total_incidents":{},"entries":[{}]}}"#,
            self.since_seconds,
            self.total_events,
            self.total_incidents,
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
        // INFRA-489: use ..Default::default() so new fields don't churn
        // every test site (lesson from INFRA-482).
        let report = WasteReport {
            since_seconds: 86400,
            total_events: 2,
            total_incidents: 2,
            entries: vec![WasteEntry {
                kind: "fleet_wedge".into(),
                count: 2,
                incidents: 2,
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
            total_incidents: 1,
            entries: vec![WasteEntry {
                kind: "fleet_starved".into(),
                count: 5,
                incidents: 1,
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
    fn infra489_dedup_collapses_refired_alerts() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        // Same reaper re-fires 5 times, plus one different reaper.
        let mut lines = Vec::new();
        for _ in 0..5 {
            lines.push(format!(
                r#"{{"event":"ALERT","kind":"reaper_silent","reaper":"pr","ts":"{}","age_hours":6}}"#,
                now_iso
            ));
        }
        lines.push(format!(
            r#"{{"event":"ALERT","kind":"reaper_silent","reaper":"worktree","ts":"{}","age_hours":4}}"#,
            now_iso
        ));
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_events, 6);
        assert_eq!(
            report.total_incidents, 2,
            "5+1 alerts collapse to 2 unique reapers"
        );
        let entry = report
            .entries
            .iter()
            .find(|e| e.kind == "reaper_silent")
            .unwrap();
        assert_eq!(entry.count, 6);
        assert_eq!(entry.incidents, 2);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra489_dedup_extracts_session_from_note_field() {
        // silent_agent ALERTs put the entity in the legacy `note` field.
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let lines: Vec<String> = (0..3)
            .map(|_| format!(
                r#"{{"event":"ALERT","kind":"silent_agent","ts":"{}","note":"session=infra-470-fix gap=INFRA-470 last_event_age=701m"}}"#,
                now_iso
            ))
            .chain(std::iter::once(format!(
                r#"{{"event":"ALERT","kind":"silent_agent","ts":"{}","note":"session=infra-471-fix gap=INFRA-471 last_event_age=620m"}}"#,
                now_iso
            )))
            .collect();
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        assert_eq!(report.total_events, 4);
        let entry = report
            .entries
            .iter()
            .find(|e| e.kind == "silent_agent")
            .unwrap();
        assert_eq!(entry.count, 4);
        assert_eq!(entry.incidents, 2, "2 unique sessions despite 4 alerts");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra489_render_text_shows_inflation_marker() {
        let report = WasteReport {
            since_seconds: 86400,
            total_events: 40,
            total_incidents: 1,
            entries: vec![WasteEntry {
                kind: "reaper_silent".into(),
                count: 40,
                incidents: 1,
                estimated_cost_secs: 0,
            }],
        };
        let text = report.render_text();
        // Headline shows incidents AND alert count.
        assert!(text.contains("1 incidents from 40 alerts"));
        // Per-entry shows the inflation marker.
        assert!(text.contains("(×40 alerts)"));
    }

    #[test]
    fn infra488_taxonomy_has_all_documented_kinds() {
        // INFRA-493: 10 original + 2 session-end synthetic = 12.
        assert_eq!(WASTE_KINDS.len(), 12);
    }

    #[test]
    fn infra493_session_end_abandoned_classified_as_waste() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        let lines = [
            // shipped session — should NOT count as waste
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-A","gap_id":"INFRA-1","outcome":"shipped","elapsed_seconds":600}}"#,
                now_iso
            ),
            // abandoned session — counts as waste
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-B","gap_id":"INFRA-2","outcome":"abandoned","elapsed_seconds":300}}"#,
                now_iso
            ),
            // starved (timeout) — counts as waste
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-C","gap_id":"INFRA-3","outcome":"starved","elapsed_seconds":600}}"#,
                now_iso
            ),
        ];
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        // 2 waste events (abandoned + starved); shipped excluded.
        assert_eq!(report.total_events, 2);
        let kinds: Vec<&str> = report.entries.iter().map(|e| e.kind.as_str()).collect();
        assert!(kinds.contains(&"session_abandoned"));
        assert!(kinds.contains(&"session_starved"));
        // Cost summed from elapsed_seconds.
        let abandoned = report
            .entries
            .iter()
            .find(|e| e.kind == "session_abandoned")
            .unwrap();
        assert_eq!(abandoned.estimated_cost_secs, 300);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra493_session_end_dedupes_by_session_id() {
        let tmp = tempdir();
        let now_iso = chrono_now_iso();
        // Same session abandoned twice (shouldn't happen but test the dedup).
        let lines: Vec<String> = (0..3)
            .map(|i| format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sess-X","gap_id":"INFRA-{}","outcome":"abandoned","elapsed_seconds":100}}"#,
                now_iso, i
            ))
            .collect();
        write_ambient(&tmp, &lines.iter().map(String::as_str).collect::<Vec<_>>());
        let report = build_report(&tmp, 86400);
        let abandoned = report
            .entries
            .iter()
            .find(|e| e.kind == "session_abandoned")
            .unwrap();
        assert_eq!(abandoned.count, 3);
        assert_eq!(
            abandoned.incidents, 1,
            "same session_id collapses to 1 incident"
        );
        let _ = std::fs::remove_dir_all(&tmp);
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
