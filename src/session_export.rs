//! INFRA-616: `chump session-export` / `chump session-resume` — multi-session handoff.
//!
//! `session-export` emits `~/.chump/sessions/<session-id>.md` with:
//! - ships landed (gaps with `session_end outcome=shipped` for this session)
//! - gaps filed during the session (gap IDs seen in `session_start` events)
//! - pillar-grade trajectory (open gap counts per mission pillar)
//! - handoff-priority items (open P0/P1 gaps)
//! - notable findings from ambient.jsonl `notable_finding` events
//!
//! `session-resume <session-id>` reads that file and prints it to stdout so the
//! Opus orchestrator can inject it at the top of a new session's context.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// One shipped gap recorded in the export.
#[derive(Debug, Clone)]
pub struct ShippedGap {
    pub gap_id: String,
    pub title: String,
    pub elapsed_seconds: u64,
    pub cost_usd: f64,
}

/// One gap filed during the session.
#[derive(Debug, Clone)]
pub struct FiledGap {
    pub gap_id: String,
    pub title: String,
    pub priority: String,
    pub pillar: String,
}

/// Handoff-priority open gap.
#[derive(Debug, Clone)]
pub struct HandoffGap {
    pub gap_id: String,
    pub title: String,
    pub priority: String,
    pub effort: String,
}

/// Full session export payload.
#[derive(Debug, Default)]
pub struct SessionExport {
    pub session_id: String,
    pub exported_at: String,
    pub ships_landed: Vec<ShippedGap>,
    pub gaps_filed: Vec<FiledGap>,
    /// open gap count per pillar tag (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE, MISSION, OTHER)
    pub pillar_grade: BTreeMap<String, usize>,
    pub handoff_items: Vec<HandoffGap>,
    pub notable_findings: Vec<String>,
}

impl SessionExport {
    /// Render as a Markdown file suitable for injection into a new session's context.
    pub fn render_md(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "# Chump Session Export — {}\n\nExported: {}\n\n",
            self.session_id, self.exported_at
        ));

        // Ships landed
        out.push_str("## Ships Landed\n\n");
        if self.ships_landed.is_empty() {
            out.push_str("_(none this session)_\n");
        } else {
            for s in &self.ships_landed {
                let cost_str = if s.cost_usd > 0.0 {
                    format!("  cost=${:.4}", s.cost_usd)
                } else {
                    String::new()
                };
                let elapsed = if s.elapsed_seconds > 0 {
                    format!("  elapsed={}s", s.elapsed_seconds)
                } else {
                    String::new()
                };
                out.push_str(&format!(
                    "- **{}** — {}{}{}\n",
                    s.gap_id, s.title, elapsed, cost_str
                ));
            }
        }

        // Gaps filed
        out.push_str("\n## Gaps Filed\n\n");
        if self.gaps_filed.is_empty() {
            out.push_str("_(none this session)_\n");
        } else {
            for g in &self.gaps_filed {
                out.push_str(&format!(
                    "- **{}** [{}] [{}] — {}\n",
                    g.gap_id, g.priority, g.pillar, g.title
                ));
            }
        }

        // Pillar grade
        out.push_str("\n## Pillar Grade (open gaps at export)\n\n");
        let pillars = [
            "EFFECTIVE",
            "CREDIBLE",
            "RESILIENT",
            "ZERO-WASTE",
            "MISSION",
            "OTHER",
        ];
        for p in &pillars {
            let count = self.pillar_grade.get(*p).copied().unwrap_or(0);
            out.push_str(&format!("- {}: {}\n", p, count));
        }

        // Notable findings
        out.push_str("\n## Notable Findings\n\n");
        if self.notable_findings.is_empty() {
            out.push_str("_(none recorded)_\n");
        } else {
            for f in &self.notable_findings {
                out.push_str(&format!("- {}\n", f));
            }
        }

        // Handoff priority
        out.push_str("\n## Handoff Priority (open P0/P1 at export)\n\n");
        if self.handoff_items.is_empty() {
            out.push_str("_(no open P0/P1 gaps)_\n");
        } else {
            for h in &self.handoff_items {
                out.push_str(&format!(
                    "- **{}** [{}] [{}] — {}\n",
                    h.gap_id, h.priority, h.effort, h.title
                ));
            }
        }

        out.push_str("\n---\n_Resume with: `chump session-resume ");
        out.push_str(&self.session_id);
        out.push_str("`_\n");
        out
    }
}

/// Default path for a session export file: `~/.chump/sessions/<session-id>.md`
pub fn export_path(session_id: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".chump")
        .join("sessions")
        .join(format!("{}.md", session_id))
}

/// Build a `SessionExport` by scanning `ambient.jsonl` and the gap store.
pub fn build_export(session_id: &str, repo_root: &Path) -> SessionExport {
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let ambient = std::fs::read_to_string(&ambient_path).unwrap_or_default();

    // Collect gap_ids that had session_start or session_end for this session.
    let mut session_gaps_started: Vec<String> = Vec::new();
    let mut ships_landed: Vec<(String, u64, f64)> = Vec::new(); // (gap_id, elapsed, cost)
    let mut notable_findings: Vec<String> = Vec::new();

    for line in ambient.lines() {
        // Ships landed: session_end with our session_id and outcome=shipped.
        if line.contains(r#""kind":"session_end""#)
            && line.contains(&format!(r#""session_id":"{}""#, session_id))
        {
            if let Some(gap_id) = extract_field(line, "gap_id") {
                let outcome = extract_field(line, "outcome").unwrap_or_default();
                if outcome == "shipped" {
                    let elapsed = extract_u64(line, "elapsed_seconds").unwrap_or(0);
                    let input = extract_u64(line, "input_tokens").unwrap_or(0);
                    let output = extract_u64(line, "output_tokens").unwrap_or(0);
                    let cache = extract_u64(line, "cache_read_tokens").unwrap_or(0);
                    let model =
                        extract_field(line, "model").unwrap_or_else(|| "unknown".to_string());
                    let cost =
                        crate::session_ledger::cost_usd_from_tokens(&model, input, output, cache);
                    ships_landed.push((gap_id, elapsed, cost));
                }
            }
        }

        // Gaps started this session.
        if line.contains(r#""kind":"session_start""#)
            && line.contains(&format!(r#""session_id":"{}""#, session_id))
        {
            if let Some(gap_id) = extract_field(line, "gap_id") {
                if !session_gaps_started.contains(&gap_id) {
                    session_gaps_started.push(gap_id);
                }
            }
        }

        // Notable findings.
        if line.contains(r#""kind":"notable_finding""#)
            && line.contains(&format!(r#""session_id":"{}""#, session_id))
        {
            if let Some(msg) = extract_field(line, "message")
                .or_else(|| extract_field(line, "finding"))
                .or_else(|| extract_field(line, "text"))
            {
                notable_findings.push(msg);
            }
        }
    }

    // Open the gap store for rich title/priority/pillar data.
    let store = crate::gap_store::GapStore::open(repo_root).ok();

    // Resolve titles for shipped gaps.
    let ships: Vec<ShippedGap> = ships_landed
        .into_iter()
        .map(|(gap_id, elapsed, cost)| {
            let title = store
                .as_ref()
                .and_then(|s| s.get(&gap_id).ok().flatten())
                .map(|r| r.title.clone())
                .unwrap_or_default();
            ShippedGap {
                gap_id,
                title,
                elapsed_seconds: elapsed,
                cost_usd: cost,
            }
        })
        .collect();

    // Resolve filed gaps (those we started this session).
    let gaps_filed: Vec<FiledGap> = session_gaps_started
        .into_iter()
        .filter_map(|gap_id| {
            let row = store.as_ref()?.get(&gap_id).ok()??;
            let pillar = pillar_for_title(&row.title);
            Some(FiledGap {
                gap_id,
                title: row.title.clone(),
                priority: row.priority.clone(),
                pillar,
            })
        })
        .collect();

    // Pillar grade: count open gaps per pillar.
    let mut pillar_grade: BTreeMap<String, usize> = BTreeMap::new();
    if let Some(s) = &store {
        if let Ok(open_gaps) = s.list(Some("open")) {
            for row in &open_gaps {
                let p = pillar_for_title(&row.title);
                *pillar_grade.entry(p).or_insert(0) += 1;
            }
        }
    }

    // Handoff items: open P0 and P1 gaps.
    let handoff_items: Vec<HandoffGap> = store
        .as_ref()
        .and_then(|s| s.list(Some("open")).ok())
        .unwrap_or_default()
        .into_iter()
        .filter(|r| r.priority == "P0" || r.priority == "P1")
        .map(|r| HandoffGap {
            gap_id: r.id.clone(),
            title: r.title.clone(),
            priority: r.priority.clone(),
            effort: r.effort.clone(),
        })
        .collect();

    let exported_at = current_iso8601();

    SessionExport {
        session_id: session_id.to_string(),
        exported_at,
        ships_landed: ships,
        gaps_filed,
        pillar_grade,
        handoff_items,
        notable_findings,
    }
}

/// Determine the mission pillar from a gap title prefix tag.
fn pillar_for_title(title: &str) -> String {
    let t = title.to_uppercase();
    if t.starts_with("EFFECTIVE:") {
        "EFFECTIVE".to_string()
    } else if t.starts_with("CREDIBLE:") {
        "CREDIBLE".to_string()
    } else if t.starts_with("RESILIENT:") {
        "RESILIENT".to_string()
    } else if t.starts_with("ZERO-WASTE:") {
        "ZERO-WASTE".to_string()
    } else if t.starts_with("MISSION:") {
        "MISSION".to_string()
    } else {
        "OTHER".to_string()
    }
}

fn current_iso8601() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // Format as YYYY-MM-DDTHH:MM:SSZ without chrono.
    let s = secs;
    let sec = s % 60;
    let min = (s / 60) % 60;
    let hour = (s / 3600) % 24;
    let days = s / 86_400;
    // Julian-day conversion (same as cost_watch).
    let j = days as i64 + 2_440_588;
    let f = j + 1401 + ((((4 * j + 274_277) / 146_097) * 3) / 4) - 38;
    let e = 4 * f + 3;
    let g = (e % 1461) / 4;
    let h = 5 * g + 2;
    let day = (h % 153) / 5 + 1;
    let month = (h / 153 + 2) % 12 + 1;
    let year = e / 1461 - 4716 + (14 - month) / 12;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, min, sec
    )
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":"#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = line[start..].trim_start();
    if let Some(inner) = rest.strip_prefix('"') {
        let end = inner.find('"')?;
        Some(inner[..end].to_string())
    } else {
        let end = rest.find([',', '}']).unwrap_or(rest.len());
        let v = rest[..end].trim().to_string();
        if v == "null" {
            None
        } else {
            Some(v)
        }
    }
}

fn extract_u64(line: &str, field: &str) -> Option<u64> {
    extract_field(line, field)?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pillar_for_title() {
        assert_eq!(pillar_for_title("EFFECTIVE: foo bar"), "EFFECTIVE");
        assert_eq!(pillar_for_title("CREDIBLE: baz"), "CREDIBLE");
        assert_eq!(pillar_for_title("RESILIENT: x"), "RESILIENT");
        assert_eq!(pillar_for_title("ZERO-WASTE: y"), "ZERO-WASTE");
        assert_eq!(pillar_for_title("MISSION: z"), "MISSION");
        assert_eq!(pillar_for_title("some gap without prefix"), "OTHER");
    }

    #[test]
    fn test_render_md_round_trip() {
        let mut export = SessionExport {
            session_id: "test-session-42".to_string(),
            exported_at: "2026-05-06T12:00:00Z".to_string(),
            ..Default::default()
        };
        export.ships_landed.push(ShippedGap {
            gap_id: "INFRA-1".to_string(),
            title: "EFFECTIVE: test gap".to_string(),
            elapsed_seconds: 600,
            cost_usd: 0.05,
        });
        export.gaps_filed.push(FiledGap {
            gap_id: "INFRA-2".to_string(),
            title: "CREDIBLE: another gap".to_string(),
            priority: "P1".to_string(),
            pillar: "CREDIBLE".to_string(),
        });
        export.pillar_grade.insert("EFFECTIVE".to_string(), 3);
        export.pillar_grade.insert("OTHER".to_string(), 10);
        export.handoff_items.push(HandoffGap {
            gap_id: "INFRA-99".to_string(),
            title: "MISSION: urgent thing".to_string(),
            priority: "P0".to_string(),
            effort: "s".to_string(),
        });
        export
            .notable_findings
            .push("cache hit rate dropped below 40%".to_string());

        let md = export.render_md();
        assert!(md.contains("test-session-42"));
        assert!(md.contains("INFRA-1"));
        assert!(md.contains("INFRA-2"));
        assert!(md.contains("INFRA-99"));
        assert!(md.contains("cache hit rate dropped below 40%"));
        assert!(md.contains("chump session-resume test-session-42"));
    }

    #[test]
    fn test_build_export_empty_ambient() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".chump-locks")).unwrap();
        let export = build_export("sess-xyz", dir.path());
        assert_eq!(export.session_id, "sess-xyz");
        assert!(export.ships_landed.is_empty());
        assert!(export.gaps_filed.is_empty());
        assert!(export.notable_findings.is_empty());
    }

    #[test]
    fn test_build_export_reads_ships() {
        use std::io::Write as W;
        let dir = tempfile::tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        std::fs::create_dir_all(&locks).unwrap();
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(locks.join("ambient.jsonl"))
            .unwrap();
        writeln!(f, r#"{{"kind":"session_end","ts":"2026-05-06T10:00:00Z","session_id":"sess-abc","gap_id":"INFRA-5","outcome":"shipped","elapsed_seconds":300,"input_tokens":0,"output_tokens":0,"cache_read_tokens":0}}"#).unwrap();
        writeln!(f, r#"{{"kind":"session_end","ts":"2026-05-06T10:01:00Z","session_id":"sess-abc","gap_id":"INFRA-6","outcome":"abandoned","elapsed_seconds":60,"input_tokens":0,"output_tokens":0,"cache_read_tokens":0}}"#).unwrap();
        let export = build_export("sess-abc", dir.path());
        // Only shipped gaps land in ships_landed.
        assert_eq!(export.ships_landed.len(), 1);
        assert_eq!(export.ships_landed[0].gap_id, "INFRA-5");
        assert_eq!(export.ships_landed[0].elapsed_seconds, 300);
    }
}
