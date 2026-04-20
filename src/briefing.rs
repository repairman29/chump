//! MEM-007 — `chump --briefing <GAP-ID>` agent context-query.
//!
//! Returns a structured briefing for "what should I know before working on
//! gap X?". Pairs with MEM-006 (`load_spawn_lessons`) which injects lessons
//! systemically at spawn time. MEM-007 is the explicit per-gap query path,
//! intended to be run by an agent right after `gap-preflight.sh` and before
//! `gap-claim.sh`.
//!
//! Sources read:
//! - `docs/gaps.yaml` for the gap entry (title, acceptance, depends_on, ...)
//! - `chump_improvement_targets` (via `reflection_db`) for relevant lessons
//! - `.chump-locks/ambient.jsonl` for recent peripheral-vision events
//! - `docs/STRATEGY_VS_GOOSE.md`, `docs/CHUMP_FACULTY_MAP.md`,
//!   `docs/RESEARCH_PLAN_2026Q3.md`, `docs/CONSCIOUSNESS_AB_RESULTS.md`,
//!   `docs/CHUMP_RESEARCH_BRIEF.md` for cross-references that mention the
//!   gap ID
//! - `gh pr list --search <gap-id> --state closed` for prior PRs (best-effort,
//!   silently skipped if `gh` is unavailable)

use crate::reflection::ImprovementTarget;
use crate::reflection_db;
use crate::repo_path;
use std::fs;
use std::path::Path;
use std::process::Command;

/// Strategic docs scanned for cross-references. Order matters for output
/// stability in tests.
const STRATEGIC_DOCS: &[&str] = &[
    "docs/CHUMP_FACULTY_MAP.md",
    "docs/STRATEGY_VS_GOOSE.md",
    "docs/RESEARCH_PLAN_2026Q3.md",
    "docs/CONSCIOUSNESS_AB_RESULTS.md",
    "docs/CHUMP_RESEARCH_BRIEF.md",
];

/// One structured briefing for a gap.
#[derive(Debug, Clone)]
pub struct GapBriefing {
    pub gap_id: String,
    pub gap_title: String,
    pub gap_acceptance: Option<String>,
    pub gap_priority: String,
    pub gap_effort: String,
    pub gap_domain: String,
    pub depends_on: Vec<String>,
    pub relevant_reflections: Vec<ImprovementTarget>,
    pub recent_ambient_events: Vec<String>,
    pub strategic_doc_refs: Vec<String>,
    pub similar_closed_prs: Vec<u32>,
    /// INFRA-AGENT-ESCALATION: escalation ALERT events from ambient.jsonl for
    /// this gap from the last 24 hours. Each entry is a raw JSON line.
    pub escalation_events: Vec<String>,
    /// `true` when the gap was not found in `docs/gaps.yaml`. Renderer prints
    /// a clear error in this case rather than a misleading half-empty briefing.
    pub gap_not_found: bool,
}

/// Build a briefing for the given gap ID. Returns `gap_not_found = true` when
/// the gap is missing from `docs/gaps.yaml` (no error — agents may pass typos).
pub fn build_briefing(gap_id: &str) -> GapBriefing {
    let gap_id = gap_id.trim().to_string();
    let root = repo_path::repo_root();
    let gaps_path = root.join("docs/gaps.yaml");

    let parsed = match fs::read_to_string(&gaps_path) {
        Ok(s) => parse_gap(&s, &gap_id),
        Err(_) => None,
    };

    let Some(parsed) = parsed else {
        return GapBriefing {
            gap_id,
            gap_title: String::new(),
            gap_acceptance: None,
            gap_priority: String::new(),
            gap_effort: String::new(),
            gap_domain: String::new(),
            depends_on: Vec::new(),
            relevant_reflections: Vec::new(),
            recent_ambient_events: Vec::new(),
            strategic_doc_refs: Vec::new(),
            similar_closed_prs: Vec::new(),
            escalation_events: Vec::new(),
            gap_not_found: true,
        };
    };

    let relevant_reflections = query_relevant_reflections(&parsed.domain, 5);

    let ambient_path = root.join(".chump-locks/ambient.jsonl");
    let recent_ambient_events = filter_ambient(&ambient_path, &parsed.domain, 20);

    let strategic_doc_refs = scan_strategic_docs(&root, &gap_id);

    let similar_closed_prs = find_similar_prs(&gap_id);

    let escalation_events = filter_escalation_events(&ambient_path, &gap_id, 24 * 3600);

    GapBriefing {
        gap_id,
        gap_title: parsed.title,
        gap_acceptance: parsed.acceptance,
        gap_priority: parsed.priority,
        gap_effort: parsed.effort,
        gap_domain: parsed.domain,
        depends_on: parsed.depends_on,
        relevant_reflections,
        recent_ambient_events,
        strategic_doc_refs,
        similar_closed_prs,
        escalation_events,
        gap_not_found: false,
    }
}

/// Parsed gap fields used by the briefing. Keep this struct private to the
/// module — external callers go through `build_briefing`.
struct ParsedGap {
    title: String,
    acceptance: Option<String>,
    priority: String,
    effort: String,
    domain: String,
    depends_on: Vec<String>,
}

/// Tiny line-based YAML parser tuned for `docs/gaps.yaml`'s shape. Avoids
/// pulling serde_yaml into the briefing module's hot path and keeps test
/// fixtures small. Recognizes:
/// - `  - id: <ID>` start of a gap entry
/// - `    title: "..."` / `    title: ...`
/// - `    priority: ...`
/// - `    effort: ...`
/// - `    domain: ...`
/// - `    acceptance: >` followed by indented continuation lines
/// - `    depends_on:` followed by `      - <ID>` lines
///
/// Returns the FIRST matching gap entry in the file. Skips quotation marks
/// when present.
fn parse_gap(yaml: &str, target_id: &str) -> Option<ParsedGap> {
    let target_id = target_id.trim();
    let mut lines = yaml.lines().peekable();
    while let Some(line) = lines.next() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("- id:") {
            let id = strip_quotes(rest.trim());
            if id != target_id {
                continue;
            }
            // Found the entry; consume until the next `- id:` at the same
            // indent (2 spaces) or EOF.
            let mut title = String::new();
            let mut acceptance: Option<String> = None;
            let mut priority = String::new();
            let mut effort = String::new();
            let mut domain = String::new();
            let mut depends_on: Vec<String> = Vec::new();

            while let Some(peek) = lines.peek() {
                let peek_trim = peek.trim_start();
                // Next entry — stop.
                if peek_trim.starts_with("- id:") && peek.starts_with("  - ") {
                    break;
                }
                let line = lines.next().unwrap();
                let t = line.trim_start();
                if let Some(v) = t.strip_prefix("title:") {
                    title = strip_quotes(v.trim()).to_string();
                } else if let Some(v) = t.strip_prefix("priority:") {
                    priority = strip_quotes(v.trim()).to_string();
                } else if let Some(v) = t.strip_prefix("effort:") {
                    effort = strip_quotes(v.trim()).to_string();
                } else if let Some(v) = t.strip_prefix("domain:") {
                    domain = strip_quotes(v.trim()).to_string();
                } else if let Some(v) = t.strip_prefix("acceptance:") {
                    let v = v.trim();
                    if v == ">" || v == "|" {
                        // Multi-line scalar — collect indented continuation.
                        let mut buf = String::new();
                        while let Some(p) = lines.peek() {
                            // Stop on next field (4-space indented key:) or
                            // next entry.
                            let pt = p.trim_start();
                            if pt.is_empty() {
                                lines.next();
                                continue;
                            }
                            // A new top-level field at the same 4-space indent
                            // looks like `<key>:` with no leading list marker.
                            // Heuristic: if the line is indented exactly 4
                            // spaces and contains a `:` before any space, it's
                            // a sibling field — stop.
                            let leading = p.len() - p.trim_start().len();
                            if leading <= 4 && pt.contains(':') && !pt.starts_with('-') {
                                let key = pt.split(':').next().unwrap_or("");
                                if !key.contains(' ') && !key.is_empty() {
                                    break;
                                }
                            }
                            // Stop on next entry.
                            if pt.starts_with("- id:") && p.starts_with("  - ") {
                                break;
                            }
                            if !buf.is_empty() {
                                buf.push(' ');
                            }
                            buf.push_str(pt);
                            lines.next();
                        }
                        if !buf.is_empty() {
                            acceptance = Some(buf);
                        }
                    } else if !v.is_empty() {
                        acceptance = Some(strip_quotes(v).to_string());
                    }
                } else if t.starts_with("depends_on:") {
                    while let Some(p) = lines.peek() {
                        let pt = p.trim_start();
                        if let Some(dep) = pt.strip_prefix("- ") {
                            // Strip inline comments.
                            let dep = dep.split('#').next().unwrap_or("").trim();
                            let dep = strip_quotes(dep);
                            if !dep.is_empty() {
                                depends_on.push(dep.to_string());
                            }
                            lines.next();
                        } else {
                            break;
                        }
                    }
                }
            }

            return Some(ParsedGap {
                title,
                acceptance,
                priority,
                effort,
                domain,
                depends_on,
            });
        }
    }
    None
}

fn strip_quotes(s: &str) -> &str {
    let s = s.trim();
    let s = s.strip_prefix('"').unwrap_or(s);
    let s = s.strip_suffix('"').unwrap_or(s);
    let s = s.strip_prefix('\'').unwrap_or(s);
    s.strip_suffix('\'').unwrap_or(s)
}

/// Query `chump_improvement_targets` for lessons whose scope matches the
/// gap's domain. Recency × frequency ranking, mirrors `load_spawn_lessons`.
/// Empty domain returns the global top-N.
pub fn query_relevant_reflections(domain: &str, limit: usize) -> Vec<ImprovementTarget> {
    reflection_db::load_spawn_lessons(domain, limit)
}

/// Read the tail of `ambient.jsonl` and keep the most recent `limit` lines
/// whose JSON body mentions the gap's domain (case-insensitive substring on
/// `path`/`cmd`/`gap_id` fields). Stays substring-based so we don't pull
/// serde_json just for filtering.
pub fn filter_ambient(path: &Path, domain: &str, limit: usize) -> Vec<String> {
    let Ok(contents) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let domain_norm = domain.trim().to_lowercase();
    let domain_paths = domain_path_hints(&domain_norm);

    let mut hits: Vec<String> = contents
        .lines()
        .filter(|line| {
            let lower = line.to_lowercase();
            // Always keep ALERT lines — they're cross-cutting peripheral
            // vision regardless of domain.
            if lower.contains("\"kind\":\"alert\"") || lower.contains("alert ") {
                return true;
            }
            if domain_norm.is_empty() {
                return true;
            }
            if lower.contains(&domain_norm) {
                return true;
            }
            domain_paths.iter().any(|p| lower.contains(p))
        })
        .map(|s| s.to_string())
        .collect();

    if hits.len() > limit {
        let start = hits.len() - limit;
        hits = hits.split_off(start);
    }
    hits
}

/// INFRA-AGENT-ESCALATION: scan ambient.jsonl for escalation ALERT events that
/// reference `gap_id` and were emitted within `within_secs` seconds of now.
/// Returns raw JSON lines, most-recent last, capped at 20.
pub fn filter_escalation_events(path: &Path, gap_id: &str, within_secs: u64) -> Vec<String> {
    let Ok(contents) = fs::read_to_string(path) else {
        return Vec::new();
    };
    // Cutoff timestamp: now minus within_secs. We do a simple string comparison
    // against ISO-8601 UTC timestamps (lexicographically ordered when zero-padded).
    let cutoff_ts = {
        use std::time::{SystemTime, UNIX_EPOCH};
        let now_secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let cutoff = now_secs.saturating_sub(within_secs);
        let secs = cutoff % 60;
        let mins = (cutoff / 60) % 60;
        let hours = (cutoff / 3600) % 24;
        let days_total = cutoff / 86400;
        // Approximate calendar date from epoch seconds (good enough for 24h window
        // comparisons; leap seconds / DST don't affect the substring filter).
        // We just need a lexicographically comparable ISO prefix.
        let year_approx = 1970 + days_total / 365;
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            year_approx, 1, 1, hours, mins, secs
        )
    };

    let gap_id_lower = gap_id.to_lowercase();
    let mut hits: Vec<String> = contents
        .lines()
        .filter(|line| {
            let lower = line.to_lowercase();
            // Must be an escalation ALERT.
            if !lower.contains("\"kind\":\"escalation\"") {
                return false;
            }
            // Must reference this gap.
            if !lower.contains(&gap_id_lower) {
                return false;
            }
            // Must be recent: extract "ts":"<value>" and compare lexicographically.
            if let Some(ts_start) = line.find("\"ts\":\"") {
                let rest = &line[ts_start + 6..];
                if let Some(ts_end) = rest.find('"') {
                    let ts = &rest[..ts_end];
                    return ts >= cutoff_ts.as_str();
                }
            }
            // If we can't parse the timestamp, include conservatively.
            true
        })
        .map(|s| s.to_string())
        .collect();

    if hits.len() > 20 {
        let start = hits.len() - 20;
        hits = hits.split_off(start);
    }
    hits
}

/// Heuristic mapping from a gap domain to file-path substrings worth
/// matching in ambient events. Conservative — only well-known domains; an
/// unknown domain falls back to bare substring match on the domain string.
fn domain_path_hints(domain: &str) -> Vec<&'static str> {
    match domain {
        "memory" => vec!["src/reflection", "src/memory", "src/briefing"],
        "eval" => vec![
            "scripts/ab-harness",
            "docs/consciousness_ab_results",
            "src/eval",
        ],
        "coordination" => vec![".chump-locks", "scripts/gap-", "scripts/bot-merge"],
        "infra" => vec!["scripts/", ".github/workflows", "docs/merge_queue"],
        "tools" => vec!["src/tools", "_tool.rs"],
        "messaging" => vec!["src/discord", "src/slack", "src/messaging_adapters"],
        "product" => vec!["docs/strategy", "docs/research_plan"],
        _ => Vec::new(),
    }
}

/// Grep strategic docs for cross-references to the gap ID. Returns one entry
/// per matching `(doc_path, line_excerpt)` pair, capped at 10.
pub fn scan_strategic_docs(root: &Path, gap_id: &str) -> Vec<String> {
    let mut hits = Vec::new();
    for rel in STRATEGIC_DOCS {
        let path = root.join(rel);
        let Ok(contents) = fs::read_to_string(&path) else {
            continue;
        };
        for (i, line) in contents.lines().enumerate() {
            if line.contains(gap_id) {
                let excerpt = line.trim();
                let excerpt = if excerpt.len() > 140 {
                    format!("{}…", &excerpt[..140])
                } else {
                    excerpt.to_string()
                };
                hits.push(format!("{}:{} — {}", rel, i + 1, excerpt));
                if hits.len() >= 10 {
                    return hits;
                }
            }
        }
    }
    hits
}

/// Best-effort `gh pr list --search <gap-id> --state closed` lookup.
/// Returns an empty vec if `gh` isn't installed, isn't authed, or times out.
pub fn find_similar_prs(gap_id: &str) -> Vec<u32> {
    let output = Command::new("gh")
        .args([
            "pr", "list", "--state", "closed", "--search", gap_id, "--limit", "10", "--json",
            "number",
        ])
        .output();
    let Ok(out) = output else { return Vec::new() };
    if !out.status.success() {
        return Vec::new();
    }
    let body = String::from_utf8_lossy(&out.stdout);
    // Tiny parse — avoid pulling serde_json. Body looks like
    // `[{"number":151},{"number":156}]`.
    let mut prs = Vec::new();
    for chunk in body.split("\"number\":").skip(1) {
        let digits: String = chunk.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(n) = digits.parse::<u32>() {
            prs.push(n);
        }
    }
    prs
}

/// Render the briefing as agent-readable markdown.
pub fn render_markdown(b: &GapBriefing) -> String {
    if b.gap_not_found {
        return format!(
            "# Briefing: {gid}\n\n**Gap not found in docs/gaps.yaml.** Check the ID or run `grep -n '{gid}' docs/gaps.yaml`.\n",
            gid = b.gap_id
        );
    }
    let mut out = String::new();
    out.push_str(&format!("# Briefing: {} — {}\n\n", b.gap_id, b.gap_title));
    out.push_str(&format!(
        "- **Domain:** {}\n- **Priority:** {}\n- **Effort:** {}\n",
        if b.gap_domain.is_empty() {
            "(none)"
        } else {
            &b.gap_domain
        },
        if b.gap_priority.is_empty() {
            "(none)"
        } else {
            &b.gap_priority
        },
        if b.gap_effort.is_empty() {
            "(none)"
        } else {
            &b.gap_effort
        },
    ));
    if !b.depends_on.is_empty() {
        out.push_str(&format!("- **Depends on:** {}\n", b.depends_on.join(", ")));
    }
    out.push('\n');

    out.push_str("## Acceptance criteria\n\n");
    match &b.gap_acceptance {
        Some(a) => {
            out.push_str(a);
            out.push_str("\n\n");
        }
        None => out.push_str("_(none recorded)_\n\n"),
    }

    out.push_str("## Top relevant reflections (chump_improvement_targets)\n\n");
    if b.relevant_reflections.is_empty() {
        out.push_str("_(no reflections matched this gap's domain — first agent on this beat)_\n\n");
    } else {
        for r in &b.relevant_reflections {
            let scope = r.scope.as_deref().unwrap_or("(global)");
            out.push_str(&format!(
                "- [{:?}] {} — _{}_\n",
                r.priority, r.directive, scope
            ));
        }
        out.push('\n');
    }

    out.push_str("## Recent ambient events (peripheral vision)\n\n");
    if b.recent_ambient_events.is_empty() {
        out.push_str("_(no recent events touching this gap's domain)_\n\n");
    } else {
        for ev in &b.recent_ambient_events {
            out.push_str(&format!("- `{}`\n", ev));
        }
        out.push('\n');
    }

    out.push_str("## Strategic doc cross-references\n\n");
    if b.strategic_doc_refs.is_empty() {
        out.push_str("_(no mentions in FACULTY_MAP / STRATEGY_VS_GOOSE / RESEARCH_PLAN / AB_RESULTS / RESEARCH_BRIEF)_\n\n");
    } else {
        for r in &b.strategic_doc_refs {
            out.push_str(&format!("- {}\n", r));
        }
        out.push('\n');
    }

    out.push_str("## Escalation events (last 24h)\n\n");
    if b.escalation_events.is_empty() {
        out.push_str("_(no escalation events for this gap in the last 24h)_\n\n");
    } else {
        out.push_str(
            "> **ALERT** — a previous agent was stuck on this gap. Review before starting.\n\n",
        );
        for ev in &b.escalation_events {
            out.push_str(&format!("- `{}`\n", ev));
        }
        out.push('\n');
    }

    out.push_str("## Similar closed PRs\n\n");
    if b.similar_closed_prs.is_empty() {
        out.push_str("_(no closed PRs found via `gh pr list --search`)_\n\n");
    } else {
        let list: Vec<String> = b
            .similar_closed_prs
            .iter()
            .map(|n| format!("#{n}"))
            .collect();
        out.push_str(&list.join(", "));
        out.push_str("\n\n");
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = r#"
gaps:
  - id: MEM-007
    title: "Agent context-query — what should I know"
    domain: memory
    priority: P2
    effort: m
    status: open
    description: >
      Test gap entry.
    acceptance: >
      (1) chump --briefing returns markdown.
      (2) CLAUDE.md updated.
    depends_on:
      - MEM-006
      - COG-024
    notes: >
      pairs with MEM-006

  - id: EVAL-030
    title: "Some other gap"
    domain: eval
    priority: P3
    effort: s
    status: open
    acceptance: >
      Single-line acceptance.
"#;

    #[test]
    fn parse_gap_finds_target() {
        let g = parse_gap(FIXTURE, "MEM-007").expect("found");
        assert_eq!(g.title, "Agent context-query — what should I know");
        assert_eq!(g.domain, "memory");
        assert_eq!(g.priority, "P2");
        assert_eq!(g.effort, "m");
        assert!(g
            .acceptance
            .as_deref()
            .unwrap()
            .contains("CLAUDE.md updated"));
        assert_eq!(g.depends_on, vec!["MEM-006", "COG-024"]);
    }

    #[test]
    fn parse_gap_finds_second_entry() {
        let g = parse_gap(FIXTURE, "EVAL-030").expect("found");
        assert_eq!(g.domain, "eval");
        assert!(g.acceptance.as_deref().unwrap().contains("Single-line"));
        assert!(g.depends_on.is_empty());
    }

    #[test]
    fn parse_gap_returns_none_when_missing() {
        assert!(parse_gap(FIXTURE, "NONEXISTENT-999").is_none());
    }

    #[test]
    fn strip_quotes_handles_double_and_single() {
        assert_eq!(strip_quotes("\"hello\""), "hello");
        assert_eq!(strip_quotes("'world'"), "world");
        assert_eq!(strip_quotes("bare"), "bare");
    }

    #[test]
    fn filter_ambient_keeps_domain_matches_and_alerts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        let body = r#"{"kind":"file_edit","path":"src/reflection_db.rs","sha":"a"}
{"kind":"file_edit","path":"src/unrelated.rs","sha":"b"}
{"kind":"alert","msg":"lease overlap"}
{"kind":"file_edit","path":"src/memory_db.rs","sha":"c"}
"#;
        fs::write(&path, body).unwrap();
        let out = filter_ambient(&path, "memory", 10);
        // 3 hits: reflection (path hint), alert, memory_db (path hint).
        assert_eq!(out.len(), 3, "got {:?}", out);
        assert!(out.iter().any(|l| l.contains("reflection_db")));
        assert!(out.iter().any(|l| l.contains("memory_db")));
        assert!(out.iter().any(|l| l.contains("alert")));
    }

    #[test]
    fn filter_ambient_caps_at_limit() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        let mut body = String::new();
        for i in 0..50 {
            body.push_str(&format!(
                "{{\"kind\":\"file_edit\",\"path\":\"src/reflection_db_{i}.rs\"}}\n"
            ));
        }
        fs::write(&path, body).unwrap();
        let out = filter_ambient(&path, "memory", 5);
        assert_eq!(out.len(), 5);
        // Should be the LAST 5 (most recent).
        assert!(out.last().unwrap().contains("reflection_db_49"));
    }

    #[test]
    fn filter_ambient_missing_file_returns_empty() {
        let out = filter_ambient(Path::new("/nonexistent/ambient.jsonl"), "memory", 10);
        assert!(out.is_empty());
    }

    #[test]
    fn scan_strategic_docs_finds_gap_id() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs");
        fs::create_dir(&docs).unwrap();
        fs::write(
            docs.join("CHUMP_FACULTY_MAP.md"),
            "# Map\n\nMEM-007 closes the per-gap learning loop.\nUnrelated line.\n",
        )
        .unwrap();
        let hits = scan_strategic_docs(dir.path(), "MEM-007");
        assert_eq!(hits.len(), 1);
        assert!(hits[0].contains("CHUMP_FACULTY_MAP.md"));
        assert!(hits[0].contains("MEM-007"));
        assert!(hits[0].contains(":3"));
    }

    #[test]
    fn scan_strategic_docs_caps_at_10() {
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs");
        fs::create_dir(&docs).unwrap();
        let mut body = String::new();
        for i in 0..20 {
            body.push_str(&format!("MEM-007 mention {i}\n"));
        }
        fs::write(docs.join("CHUMP_FACULTY_MAP.md"), body).unwrap();
        let hits = scan_strategic_docs(dir.path(), "MEM-007");
        assert_eq!(hits.len(), 10);
    }

    #[test]
    fn render_markdown_for_not_found_is_clear() {
        let b = GapBriefing {
            gap_id: "BOGUS-1".into(),
            gap_title: String::new(),
            gap_acceptance: None,
            gap_priority: String::new(),
            gap_effort: String::new(),
            gap_domain: String::new(),
            depends_on: Vec::new(),
            relevant_reflections: Vec::new(),
            recent_ambient_events: Vec::new(),
            strategic_doc_refs: Vec::new(),
            similar_closed_prs: Vec::new(),
            escalation_events: Vec::new(),
            gap_not_found: true,
        };
        let md = render_markdown(&b);
        assert!(md.contains("BOGUS-1"));
        assert!(md.to_lowercase().contains("not found"));
    }

    #[test]
    fn render_markdown_includes_all_sections() {
        let b = GapBriefing {
            gap_id: "MEM-007".into(),
            gap_title: "Agent context-query".into(),
            gap_acceptance: Some("(1) outputs markdown.".into()),
            gap_priority: "P2".into(),
            gap_effort: "m".into(),
            gap_domain: "memory".into(),
            depends_on: vec!["MEM-006".into()],
            relevant_reflections: Vec::new(),
            recent_ambient_events: vec!["{\"kind\":\"file_edit\"}".into()],
            strategic_doc_refs: vec!["docs/CHUMP_FACULTY_MAP.md:42 — MEM-007".into()],
            similar_closed_prs: vec![123, 145],
            escalation_events: Vec::new(),
            gap_not_found: false,
        };
        let md = render_markdown(&b);
        assert!(md.contains("# Briefing: MEM-007"));
        assert!(md.contains("## Acceptance criteria"));
        assert!(md.contains("## Top relevant reflections"));
        assert!(md.contains("## Recent ambient events"));
        assert!(md.contains("## Strategic doc cross-references"));
        assert!(md.contains("## Escalation events (last 24h)"));
        assert!(md.contains("## Similar closed PRs"));
        assert!(md.contains("#123"));
        assert!(md.contains("**Depends on:** MEM-006"));
    }

    #[test]
    fn render_markdown_shows_escalation_alert_when_events_present() {
        let b = GapBriefing {
            gap_id: "FOO-001".into(),
            gap_title: "Test gap".into(),
            gap_acceptance: None,
            gap_priority: "P1".into(),
            gap_effort: "s".into(),
            gap_domain: "infra".into(),
            depends_on: Vec::new(),
            relevant_reflections: Vec::new(),
            recent_ambient_events: Vec::new(),
            strategic_doc_refs: Vec::new(),
            similar_closed_prs: Vec::new(),
            escalation_events: vec![
                r#"{"ts":"2026-04-20T00:00:00Z","session":"s","event":"ALERT","kind":"escalation","gap_id":"FOO-001","stuck_at":"cargo check fails","last_error":"borrow checker","suggested_action":"human review needed"}"#.into(),
            ],
            gap_not_found: false,
        };
        let md = render_markdown(&b);
        assert!(md.contains("## Escalation events (last 24h)"));
        assert!(md.contains("ALERT"));
        assert!(md.contains("stuck_at"));
    }

    #[test]
    fn filter_escalation_events_returns_matching_events() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ambient.jsonl");
        // Use a timestamp far in the future to ensure within_secs is always satisfied.
        let body = concat!(
            r#"{"ts":"2099-01-01T00:00:00Z","event":"ALERT","kind":"escalation","gap_id":"FOO-001","stuck_at":"test error","last_error":"e","suggested_action":"review"}"#,
            "\n",
            r#"{"ts":"2099-01-01T00:00:00Z","event":"ALERT","kind":"escalation","gap_id":"BAR-002","stuck_at":"other error","last_error":"e","suggested_action":"review"}"#,
            "\n",
            r#"{"ts":"2099-01-01T00:00:00Z","event":"file_edit","kind":"other","gap_id":"FOO-001","path":"src/foo.rs"}"#,
            "\n",
        );
        fs::write(&path, body).unwrap();
        // within_secs large enough to catch 2099 timestamps from 2026.
        let hits = filter_escalation_events(&path, "FOO-001", 999_999_999);
        assert_eq!(hits.len(), 1, "got {:?}", hits);
        assert!(hits[0].contains("FOO-001"));
        assert!(hits[0].contains("escalation"));
    }

    #[test]
    fn filter_escalation_events_missing_file_returns_empty() {
        let hits =
            filter_escalation_events(Path::new("/nonexistent/ambient.jsonl"), "FOO-001", 86400);
        assert!(hits.is_empty());
    }

    #[test]
    fn build_briefing_for_unknown_gap_marks_not_found() {
        let b = build_briefing("DEFINITELY-NOT-A-REAL-GAP-9999");
        assert!(b.gap_not_found);
        assert!(b.gap_title.is_empty());
    }

    #[test]
    fn domain_path_hints_known_domains() {
        assert!(!domain_path_hints("memory").is_empty());
        assert!(!domain_path_hints("eval").is_empty());
        assert!(domain_path_hints("totally-unknown").is_empty());
    }
}
