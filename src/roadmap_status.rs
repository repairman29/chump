//! INFRA-606: roadmap-status — reads docs/ROADMAP.md, shows progress against weekly outcomes.
//!
//! `chump roadmap-status [--json]` parses docs/ROADMAP.md for Week N outcomes + gap refs,
//! cross-references against the gap registry (state.db), and emits a 🟢/🟡/🔴 progress table.

use std::path::Path;

#[derive(Debug, Default, Clone)]
pub struct RoadmapGap {
    pub id: String,
    pub is_placeholder: bool,
    pub status: String, // "shipped" | "in_flight" | "open" | "not_filed"
    pub closed_pr: Option<i64>,
}

#[derive(Debug, Default, Clone)]
pub struct WeekOutcome {
    pub week: u32,
    pub week_title: String,
    pub outcome: String,
    pub gaps: Vec<RoadmapGap>,
}

#[derive(Debug, Default, Clone)]
pub struct RoadmapStatusReport {
    pub weeks: Vec<WeekOutcome>,
    pub ts: String,
}

pub fn parse_roadmap(content: &str) -> Vec<WeekOutcome> {
    let mut weeks: Vec<WeekOutcome> = Vec::new();
    let mut current_week: Option<WeekOutcome> = None;
    let mut in_implementing = false;

    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("## Week ") {
            if let Some(w) = current_week.take() {
                weeks.push(w);
            }
            let parts: Vec<&str> = rest.splitn(2, " \u{2014} ").collect();
            let week_num: u32 = parts[0].trim().parse().unwrap_or(0);
            let week_title = parts.get(1).copied().unwrap_or("").to_string();
            current_week = Some(WeekOutcome {
                week: week_num,
                week_title,
                ..Default::default()
            });
            in_implementing = false;
            continue;
        }

        let w = match current_week.as_mut() {
            Some(w) => w,
            None => continue,
        };

        if line.contains("**Outcome.**") {
            w.outcome = line.replace("**Outcome.**", "").trim().to_string();
            continue;
        }

        if line.contains("**Implementing gaps") {
            in_implementing = true;
            continue;
        }

        if line.starts_with("**Out of scope") || line.starts_with("**Acceptance") {
            in_implementing = false;
            continue;
        }

        if in_implementing && line.starts_with("- **") {
            if let Some(id) = extract_gap_id(line) {
                let is_placeholder = id.contains("NEW")
                    || id.contains("XXX")
                    || id.contains('-') && {
                        let suffix = id.split_once('-').map(|x| x.1).unwrap_or("");
                        suffix == "NEW" || suffix == "XXX"
                    };
                w.gaps.push(RoadmapGap {
                    is_placeholder,
                    status: if is_placeholder {
                        "not_filed".to_string()
                    } else {
                        "open".to_string()
                    },
                    id,
                    closed_pr: None,
                });
            }
        }
    }

    if let Some(w) = current_week {
        weeks.push(w);
    }

    weeks
}

fn extract_gap_id(line: &str) -> Option<String> {
    let after = line.strip_prefix("- **")?;
    let end = after.find("**")?;
    let id = after[..end].trim();
    if id.contains('-') {
        Some(id.to_string())
    } else {
        None
    }
}

pub fn build_report(repo_root: &Path) -> RoadmapStatusReport {
    let roadmap_path = repo_root.join("docs").join("ROADMAP.md");
    let content = std::fs::read_to_string(&roadmap_path).unwrap_or_default();
    let mut weeks = parse_roadmap(&content);

    if let Ok(gs) = crate::gap_store::GapStore::open(repo_root) {
        let all_open = gs.list(Some("open")).unwrap_or_default();
        let all_done = gs.list(Some("done")).unwrap_or_default();

        for week in &mut weeks {
            for gap in &mut week.gaps {
                if gap.is_placeholder {
                    continue;
                }
                if let Some(row) = all_done.iter().find(|r| r.id == gap.id) {
                    gap.status = "shipped".to_string();
                    gap.closed_pr = row.closed_pr;
                } else if all_open.iter().any(|r| r.id == gap.id) {
                    gap.status = "open".to_string();
                }
                // gaps not found in either list stay "open" (conservative)
            }
        }
    }

    RoadmapStatusReport {
        weeks,
        ts: current_iso8601(),
    }
}

fn outcome_status_icon(week: &WeekOutcome) -> &'static str {
    if week.gaps.is_empty() {
        return "🟡";
    }
    let total = week.gaps.len();
    let shipped = week.gaps.iter().filter(|g| g.status == "shipped").count();
    let in_flight = week.gaps.iter().filter(|g| g.status == "in_flight").count();

    if shipped == total {
        "🟢"
    } else if shipped + in_flight == 0 {
        "🔴"
    } else {
        "🟡"
    }
}

impl RoadmapStatusReport {
    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Roadmap Status ═══\n\n");

        for week in &self.weeks {
            let icon = outcome_status_icon(week);
            out.push_str(&format!(
                "{} Week {} — {}\n",
                icon, week.week, week.week_title
            ));
            if !week.outcome.is_empty() {
                out.push_str(&format!("   Outcome: {}\n", week.outcome));
            }

            let shipped: Vec<_> = week.gaps.iter().filter(|g| g.status == "shipped").collect();
            let in_flight: Vec<_> = week
                .gaps
                .iter()
                .filter(|g| g.status == "in_flight")
                .collect();
            let open: Vec<_> = week.gaps.iter().filter(|g| g.status == "open").collect();
            let not_filed: Vec<_> = week
                .gaps
                .iter()
                .filter(|g| g.status == "not_filed")
                .collect();

            out.push_str(&format!(
                "   Gaps: {} shipped, {} in-flight, {} open, {} not-filed\n",
                shipped.len(),
                in_flight.len(),
                open.len(),
                not_filed.len()
            ));

            for g in &shipped {
                let pr = g.closed_pr.map(|p| format!(" (#{p})")).unwrap_or_default();
                out.push_str(&format!("   \u{2705} {} shipped{}\n", g.id, pr));
            }
            for g in &in_flight {
                out.push_str(&format!("   \u{1f504} {} in-flight\n", g.id));
            }
            for g in &open {
                out.push_str(&format!("   \u{2b1c} {} open\n", g.id));
            }
            for g in &not_filed {
                out.push_str(&format!(
                    "   \u{1f4cb} {} (placeholder \u{2014} not filed)\n",
                    g.id
                ));
            }
            out.push('\n');
        }

        out.push_str(&format!("Generated: {}\n", self.ts));
        out
    }

    pub fn render_json(&self) -> String {
        let mut weeks_json: Vec<String> = Vec::new();
        for week in &self.weeks {
            let icon = outcome_status_icon(week);
            let shipped = week.gaps.iter().filter(|g| g.status == "shipped").count();
            let in_flight = week.gaps.iter().filter(|g| g.status == "in_flight").count();
            let open = week.gaps.iter().filter(|g| g.status == "open").count();
            let not_filed = week.gaps.iter().filter(|g| g.status == "not_filed").count();

            let gaps_json: Vec<String> = week
                .gaps
                .iter()
                .map(|g| {
                    let pr = g
                        .closed_pr
                        .map(|p| format!(r#","closed_pr":{p}"#))
                        .unwrap_or_default();
                    format!(
                        r#"{{"id":"{}","is_placeholder":{},"status":"{}"{}}}"#,
                        g.id, g.is_placeholder, g.status, pr
                    )
                })
                .collect();

            weeks_json.push(format!(
                r#"{{"week":{week},"week_title":"{wt}","outcome":"{oc}","status_icon":"{icon}","shipped":{shipped},"in_flight":{in_flight},"open":{open},"not_filed":{not_filed},"gaps":[{gaps}]}}"#,
                week = week.week,
                wt = escape_json(&week.week_title),
                oc = escape_json(&week.outcome),
                icon = icon,
                shipped = shipped,
                in_flight = in_flight,
                open = open,
                not_filed = not_filed,
                gaps = gaps_json.join(","),
            ));
        }

        format!(
            r#"{{"ts":"{ts}","kind":"roadmap_status","weeks":[{weeks}]}}"#,
            ts = self.ts,
            weeks = weeks_json.join(","),
        )
    }
}

fn escape_json(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
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
    let out2 = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok());
    out2.map(|s| s.trim().to_string())
        .unwrap_or_else(|| secs.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = "## Week 1 \u{2014} User-facing front door (May 6 \u{2192} 13)\n\n**Outcome.** A solo dev with Ollama can run chump gen and get a working PR.\n\n**Implementing gaps:**\n- **INFRA-100** \u{2014} gap one (P0 m, pickable)\n- **INFRA-101** \u{2014} gap two (P1 s, in flight #1000)\n- **INFRA-NEW** \u{2014} gap three \u{2014} to be filed\n\n---\n\n## Week 2 \u{2014} Credible evidence (May 14 \u{2192} 21)\n\n**Outcome.** Published numbers showing whether the cognition stack helps.\n\n**Implementing gaps:**\n- **EVAL-200** \u{2014} eval gap (P1 m, pickable)\n- **INFRA-XXX** \u{2014} placeholder gap \u{2014} to be filed\n";

    #[test]
    fn test_parse_week_count() {
        let weeks = parse_roadmap(FIXTURE);
        assert_eq!(weeks.len(), 2);
    }

    #[test]
    fn test_parse_week1_gap_ids() {
        let weeks = parse_roadmap(FIXTURE);
        assert_eq!(weeks[0].week, 1);
        let ids: Vec<&str> = weeks[0].gaps.iter().map(|g| g.id.as_str()).collect();
        assert!(ids.contains(&"INFRA-100"));
        assert!(ids.contains(&"INFRA-101"));
        assert!(ids.contains(&"INFRA-NEW"));
    }

    #[test]
    fn test_placeholder_detection() {
        let weeks = parse_roadmap(FIXTURE);
        let new_gap = weeks[0].gaps.iter().find(|g| g.id == "INFRA-NEW").unwrap();
        assert!(new_gap.is_placeholder);
        let real_gap = weeks[0].gaps.iter().find(|g| g.id == "INFRA-100").unwrap();
        assert!(!real_gap.is_placeholder);
    }

    #[test]
    fn test_outcome_text_extracted() {
        let weeks = parse_roadmap(FIXTURE);
        assert!(weeks[0].outcome.contains("solo dev"));
    }

    #[test]
    fn test_icon_red_all_open() {
        let week = WeekOutcome {
            week: 1,
            week_title: "test".to_string(),
            outcome: String::new(),
            gaps: vec![RoadmapGap {
                id: "INFRA-1".to_string(),
                is_placeholder: false,
                status: "open".to_string(),
                closed_pr: None,
            }],
        };
        assert_eq!(outcome_status_icon(&week), "🔴");
    }

    #[test]
    fn test_icon_green_all_shipped() {
        let week = WeekOutcome {
            week: 1,
            week_title: "test".to_string(),
            outcome: String::new(),
            gaps: vec![RoadmapGap {
                id: "INFRA-1".to_string(),
                is_placeholder: false,
                status: "shipped".to_string(),
                closed_pr: Some(1234),
            }],
        };
        assert_eq!(outcome_status_icon(&week), "🟢");
    }

    #[test]
    fn test_icon_yellow_partial() {
        let week = WeekOutcome {
            week: 1,
            week_title: "test".to_string(),
            outcome: String::new(),
            gaps: vec![
                RoadmapGap {
                    id: "INFRA-1".to_string(),
                    is_placeholder: false,
                    status: "shipped".to_string(),
                    closed_pr: None,
                },
                RoadmapGap {
                    id: "INFRA-2".to_string(),
                    is_placeholder: false,
                    status: "open".to_string(),
                    closed_pr: None,
                },
            ],
        };
        assert_eq!(outcome_status_icon(&week), "🟡");
    }

    #[test]
    fn test_render_json_required_fields() {
        let report = RoadmapStatusReport {
            weeks: vec![],
            ts: "2026-05-06T17:00:00Z".to_string(),
        };
        let json = report.render_json();
        assert!(json.contains(r#""kind":"roadmap_status""#));
        assert!(json.contains(r#""weeks""#));
        assert!(json.contains(r#""ts""#));
    }

    #[test]
    fn test_render_text_week_headers() {
        let weeks = parse_roadmap(FIXTURE);
        let report = RoadmapStatusReport {
            weeks,
            ts: "2026-05-06T17:00:00Z".to_string(),
        };
        let text = report.render_text();
        assert!(text.contains("Week 1"));
        assert!(text.contains("Week 2"));
    }

    #[test]
    fn test_render_text_not_filed_label() {
        let weeks = parse_roadmap(FIXTURE);
        let report = RoadmapStatusReport {
            weeks,
            ts: "2026-05-06T17:00:00Z".to_string(),
        };
        let text = report.render_text();
        assert!(
            text.contains("not-filed") || text.contains("not_filed") || text.contains("not filed")
        );
    }

    #[test]
    fn test_week2_xxx_placeholder() {
        let weeks = parse_roadmap(FIXTURE);
        let xxx = weeks[1].gaps.iter().find(|g| g.id == "INFRA-XXX").unwrap();
        assert!(xxx.is_placeholder);
        assert_eq!(xxx.status, "not_filed");
    }
}
