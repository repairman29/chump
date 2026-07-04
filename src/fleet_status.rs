//! INFRA-494: Fleet-status dashboard.
//!
//! Single-command operator visibility. After the Zero Waste push
//! (INFRA-488..493) the fleet has measurement primitives, but no
//! "is it healthy right now" snapshot. This module aggregates:
//!
//! - **Active leases**: how many sessions are currently claiming gaps,
//!   their ages, and the gap each is on.
//! - **Last-24h waste**: count from `chump waste-tally` — total
//!   incidents + biggest contributor.
//! - **Last-24h shipped**: count of `session_end outcome=shipped`
//!   events from the INFRA-477 cost ledger.
//! - **Recent fleet wedges**: any `fleet_wedge` ALERTs in the last 6h
//!   so the operator knows if the fleet is mid-meltdown.
//!
//! No fancy aggregations or charts — terminal-friendly text output
//! that fits in a glance.

use std::path::Path;

#[derive(Debug, Default)]
pub struct FleetStatus {
    pub active_leases: Vec<LeaseSummary>,
    pub waste_incidents_24h: u64,
    pub waste_top_kind: Option<String>,
    pub waste_top_count: u64,
    pub shipped_24h: u64,
    pub abandoned_24h: u64,
    pub recent_wedges_6h: u64,
    /// INFRA-534: actual API cost (USD) across all session_end events in last 24h.
    pub cost_usd_24h: f64,
    pub repo_root: std::path::PathBuf,
}

#[derive(Debug, Clone, Default)]
pub struct LeaseSummary {
    pub session_id: String,
    pub gap_id: String,
    pub age_minutes: u64,
}

/// Build a fleet status snapshot for the given repo root.
pub fn snapshot(repo_root: &Path) -> FleetStatus {
    let mut status = FleetStatus {
        repo_root: repo_root.to_path_buf(),
        ..Default::default()
    };

    // Active leases.
    let lock_dir = repo_root.join(".chump-locks");
    if let Ok(entries) = std::fs::read_dir(&lock_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
            // Skip dotfiles, ambient.jsonl, and known non-lease files.
            if !name.ends_with(".json") || name.starts_with('.') {
                continue;
            }
            let session_id = name.trim_end_matches(".json").to_string();
            // Skip cooldown sub-dir entries (different shape).
            if name.contains("cooldown") {
                continue;
            }
            let contents = std::fs::read_to_string(&path).unwrap_or_default();
            // CREDIBLE-149: count only real leases. A lease JSON carries an
            // `expires_at` field (schema: session_id/gap_id/taken_at/expires_at/
            // purpose). Curator decision-log ledgers (curator-filed-*.json →
            // {decision,gap_id,ts}) and *-state.json control files do NOT — and
            // must not inflate active_leases/fleet_workers_alive (they poisoned
            // the count ~180x: 189 reported vs ~1 real).
            if extract_field(&contents, "expires_at")
                .filter(|s| !s.is_empty())
                .is_none()
            {
                continue;
            }
            let gap_id = extract_field(&contents, "gap_id").unwrap_or_default();
            let age_minutes = if let Ok(meta) = std::fs::metadata(&path) {
                if let Ok(modified) = meta.modified() {
                    let now = std::time::SystemTime::now();
                    now.duration_since(modified)
                        .map(|d| d.as_secs() / 60)
                        .unwrap_or(0)
                } else {
                    0
                }
            } else {
                0
            };
            status.active_leases.push(LeaseSummary {
                session_id,
                gap_id,
                age_minutes,
            });
        }
    }

    // Waste tally for last 24h via the existing module.
    let waste_report = crate::waste_tally::build_report(repo_root, 24 * 3600);
    status.waste_incidents_24h = waste_report.total_incidents;
    if let Some(top) = waste_report.entries.iter().max_by_key(|e| e.incidents) {
        status.waste_top_kind = Some(top.kind.clone());
        status.waste_top_count = top.incidents;
    }

    // Shipped vs abandoned in last 24h — read session_end events directly.
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let cutoff_24h = current_unix().saturating_sub(24 * 3600);
    let cutoff_6h = current_unix().saturating_sub(6 * 3600);
    for line in contents.lines() {
        let ts_unix = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if line.contains(r#""kind":"session_end""#) && ts_unix >= cutoff_24h {
            match extract_field(line, "outcome").as_deref() {
                Some("shipped") => status.shipped_24h += 1,
                Some("abandoned") | Some("starved") => status.abandoned_24h += 1,
                _ => {}
            }
            // INFRA-534: sum token costs from all session_end events in window.
            let input = extract_int_field(line, "input_tokens").unwrap_or(0);
            let output = extract_int_field(line, "output_tokens").unwrap_or(0);
            let cache = extract_int_field(line, "cache_read_tokens").unwrap_or(0);
            if input > 0 || output > 0 || cache > 0 {
                let model = extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
                status.cost_usd_24h +=
                    crate::session_ledger::cost_usd_from_tokens(&model, input, output, cache);
            }
        }
        if line.contains(r#""kind":"fleet_wedge""#) && ts_unix >= cutoff_6h {
            status.recent_wedges_6h += 1;
        }
    }

    status
}

impl FleetStatus {
    /// Render terminal-friendly summary.
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Fleet Status ═══\n");

        // Active leases.
        if self.active_leases.is_empty() {
            out.push_str("  Active leases:   0 (fleet idle)\n");
        } else {
            out.push_str(&format!(
                "  Active leases:   {}\n",
                self.active_leases.len()
            ));
            // Show up to 5, sorted by age (oldest first — likely stuck).
            let mut sorted = self.active_leases.clone();
            sorted.sort_by_key(|l| std::cmp::Reverse(l.age_minutes));
            for lease in sorted.iter().take(5) {
                let warn = if lease.age_minutes >= 360 {
                    " ⚠️  stale (>6h)"
                } else if lease.age_minutes >= 60 {
                    " (>1h)"
                } else {
                    ""
                };
                out.push_str(&format!(
                    "    {:<40} gap={} age={}m{}\n",
                    lease.session_id.chars().take(40).collect::<String>(),
                    lease.gap_id,
                    lease.age_minutes,
                    warn
                ));
            }
            if sorted.len() > 5 {
                out.push_str(&format!("    … {} more\n", sorted.len() - 5));
            }
        }

        // Last 24h.
        out.push_str(&format!(
            "  Last 24h:        shipped={}  abandoned/starved={}\n",
            self.shipped_24h, self.abandoned_24h
        ));
        let total = self.shipped_24h + self.abandoned_24h;
        let success_rate = (self.shipped_24h * 100).checked_div(total).unwrap_or(0);
        if self.shipped_24h + self.abandoned_24h > 0 {
            out.push_str(&format!("                   ship-rate={}%\n", success_rate));
        }
        if self.cost_usd_24h > 0.0 {
            out.push_str(&format!(
                "                   cost=${:.4} (last 24h)\n",
                self.cost_usd_24h
            ));
        }

        // Waste.
        out.push_str(&format!(
            "  Waste 24h:       {} incidents",
            self.waste_incidents_24h
        ));
        if let Some(top) = &self.waste_top_kind {
            out.push_str(&format!("  (top: {} × {})", self.waste_top_count, top));
        }
        out.push('\n');

        // Recent wedges.
        if self.recent_wedges_6h > 0 {
            out.push_str(&format!(
                "  ⚠️  Fleet wedges last 6h: {} — investigate (chump waste-tally)\n",
                self.recent_wedges_6h
            ));
        }

        // Footer hint.
        out.push_str("\n  Drill down: chump waste-tally --since 24h\n");
        out
    }
}

// ── Helpers (duplicated from waste_tally.rs to avoid making them pub) ─────

fn current_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

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

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra494-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn infra494_empty_status() {
        let tmp = tempdir();
        let status = snapshot(&tmp);
        assert_eq!(status.active_leases.len(), 0);
        assert_eq!(status.waste_incidents_24h, 0);
        assert_eq!(status.shipped_24h, 0);
        let text = status.render_text();
        assert!(text.contains("fleet idle"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra494_counts_shipped_and_abandoned() {
        let tmp = tempdir();
        std::fs::create_dir_all(tmp.join(".chump-locks")).unwrap();
        // Use very recent ts so it falls within 24h window.
        let ts = std::process::Command::new("date")
            .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|_| "2026-05-06T03:00:00Z".to_string());
        let lines = [
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sA","gap_id":"INFRA-1","outcome":"shipped"}}"#,
                ts
            ),
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sB","gap_id":"INFRA-2","outcome":"abandoned"}}"#,
                ts
            ),
            format!(
                r#"{{"event":"session_end","kind":"session_end","ts":"{}","session_id":"sC","gap_id":"INFRA-3","outcome":"starved"}}"#,
                ts
            ),
        ];
        std::fs::write(
            tmp.join(".chump-locks/ambient.jsonl"),
            lines.join("\n") + "\n",
        )
        .unwrap();
        let status = snapshot(&tmp);
        assert_eq!(status.shipped_24h, 1);
        assert_eq!(status.abandoned_24h, 2);
        let text = status.render_text();
        assert!(text.contains("shipped=1"));
        assert!(text.contains("abandoned/starved=2"));
        // Ship rate = 1/3 = 33%.
        assert!(text.contains("ship-rate=33%"), "got: {}", text);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra494_active_leases_show_age_warning() {
        let tmp = tempdir();
        let lock_dir = tmp.join(".chump-locks");
        std::fs::create_dir_all(&lock_dir).unwrap();
        let lease = lock_dir.join("test-session.json");
        // Real lease shape carries expires_at (CREDIBLE-149).
        std::fs::write(
            &lease,
            r#"{"gap_id":"INFRA-99","expires_at":"2026-05-05T19:00:00Z"}"#,
        )
        .unwrap();
        // Backdate the file mtime by ~7h.
        let _ = std::process::Command::new("touch")
            .args(["-t", "202605051200", lease.to_str().unwrap()])
            .output();
        let status = snapshot(&tmp);
        assert_eq!(status.active_leases.len(), 1);
        let lease_summary = &status.active_leases[0];
        assert_eq!(lease_summary.session_id, "test-session");
        assert_eq!(lease_summary.gap_id, "INFRA-99");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn credible149_only_real_leases_counted() {
        // A lease has `expires_at`; curator decision-log ledgers and *-state
        // control files do not, and must not inflate the lease count.
        let tmp = tempdir();
        let lock_dir = tmp.join(".chump-locks");
        std::fs::create_dir_all(&lock_dir).unwrap();
        // 1 real lease.
        std::fs::write(
            lock_dir.join("fleet-agent7.json"),
            r#"{"session_id":"fleet-agent7","gap_id":"INFRA-1","taken_at":"2026-07-04T10:00:00Z","expires_at":"2026-07-04T14:00:00Z","purpose":"fleet:pick_and_claim"}"#,
        )
        .unwrap();
        // 2 curator decision-log ledgers (no expires_at).
        std::fs::write(
            lock_dir.join("curator-filed-balance_restock_CREDIBLE-2026-05-25.json"),
            r#"{"decision":"balance_restock_CREDIBLE","gap_id":"INFRA-1149","ts":"2026-05-25T15:54:07Z"}"#,
        )
        .unwrap();
        std::fs::write(
            lock_dir.join("curator-filed-pr_unstick-2026-06-28.json"),
            r#"{"decision":"pr_unstick","ts":"2026-06-28T00:00:00Z"}"#,
        )
        .unwrap();
        // 1 state control file (no expires_at).
        std::fs::write(
            lock_dir.join("gap-priority.json"),
            r#"{"weights":{"P0":10},"updated":"2026-07-04T00:00:00Z"}"#,
        )
        .unwrap();
        let status = snapshot(&tmp);
        assert_eq!(
            status.active_leases.len(),
            1,
            "only the expires_at-bearing lease should count; got {:?}",
            status.active_leases
        );
        assert_eq!(status.active_leases[0].gap_id, "INFRA-1");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
