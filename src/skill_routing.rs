//! META-078: Skill-aware routing decision engine (stub skills DB).
//!
//! First implementation of the routing layer described in
//! docs/design/SKILL_AWARE_ROUTING_SCHEMA.md (META-077). This slice proves
//! the scoring + selection + emission plumbing end-to-end against a
//! self-contained candidate list ("stub skills DB") — wiring the selector
//! up to real `CapabilityManifest` publishes (INFRA-1825) is future work
//! (META-081 integration slice), same relationship META-076 has to the
//! real lease/PR/gap-dependency graphs it will eventually consume.

use std::fs;
use std::io::Write as IoWrite;

use anyhow::{Context, Result};
use serde::Serialize;

/// Coarse task shape, derived by the caller from the gap's title + touched
/// file paths. Mirrors the 6-value enum in the schema doc.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskType {
    RustImpl,
    DocsOnly,
    ShellOnly,
    CiOnly,
    Mixed,
    Unknown,
}

impl TaskType {
    fn as_str(self) -> &'static str {
        match self {
            TaskType::RustImpl => "rust_impl",
            TaskType::DocsOnly => "docs_only",
            TaskType::ShellOnly => "shell_only",
            TaskType::CiOnly => "ci_only",
            TaskType::Mixed => "mixed",
            TaskType::Unknown => "unknown",
        }
    }
}

/// A candidate agent, as read from the (stub) skills DB. Real inputs will
/// come from published `CapabilityManifest`s (INFRA-1825); today the caller
/// supplies this list directly.
#[derive(Debug, Clone)]
pub struct RoutingCandidate {
    pub session: String,
    pub skills: Vec<String>,
    pub freshness_age_s: u64,
    pub current_load_gaps: u32,
}

/// Why `selected_session` won, per the schema's 4-value taxonomy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SelectionReason {
    SkillSuperset,
    BestPartialMatch,
    FallbackRoundRobin,
    NoMatch,
}

impl SelectionReason {
    fn as_str(self) -> &'static str {
        match self {
            SelectionReason::SkillSuperset => "skill_superset",
            SelectionReason::BestPartialMatch => "best_partial_match",
            SelectionReason::FallbackRoundRobin => "fallback_round_robin",
            SelectionReason::NoMatch => "no_match",
        }
    }
}

/// A scored candidate, as it appears in the emitted `candidates` array.
#[derive(Debug, Clone, Serialize)]
pub struct ScoredCandidate {
    pub session: String,
    pub skills: Vec<String>,
    pub match_score: f64,
    pub freshness_age_s: u64,
    pub current_load_gaps: u32,
}

/// The outcome of one routing decision, ready to emit as `routing_decision`.
#[derive(Debug, Clone)]
pub struct RoutingResult {
    pub gap_id: String,
    pub task_type: TaskType,
    pub required_skills: Vec<String>,
    pub candidates: Vec<ScoredCandidate>,
    pub selected_session: Option<String>,
    pub selection_reason: SelectionReason,
}

/// Jaccard similarity between `required` and `have`: `|∩| / |∪|`.
/// Per the schema doc: `required = []` short-circuits to 1.0 for every
/// candidate before this function is even called.
fn jaccard(required: &[String], have: &[String]) -> f64 {
    let union_size = required
        .iter()
        .chain(have.iter())
        .collect::<std::collections::HashSet<_>>()
        .len();
    if union_size == 0 {
        return 1.0;
    }
    let intersection_size = required.iter().filter(|s| have.contains(s)).count();
    intersection_size as f64 / union_size as f64
}

/// Order candidates by the schema's tie-breaker: highest score, then
/// freshest (lowest `freshness_age_s`), then least loaded, then
/// lexicographic session — deterministic across routers.
fn better_candidate(a: &ScoredCandidate, b: &ScoredCandidate) -> std::cmp::Ordering {
    b.match_score
        .partial_cmp(&a.match_score)
        .unwrap_or(std::cmp::Ordering::Equal)
        .then(a.freshness_age_s.cmp(&b.freshness_age_s))
        .then(a.current_load_gaps.cmp(&b.current_load_gaps))
        .then(a.session.cmp(&b.session))
}

/// Select the best-matching candidate for `gap_id`, or fall back to
/// round-robin routing when skills data is unavailable (AC #3): either no
/// candidates were supplied, or `required_skills` is empty, or every
/// candidate has an empty skill set (stub DB not populated for anyone yet).
pub fn select_route(
    gap_id: impl Into<String>,
    task_type: TaskType,
    required_skills: Vec<String>,
    mut candidates: Vec<RoutingCandidate>,
) -> RoutingResult {
    let gap_id = gap_id.into();

    if candidates.is_empty() {
        return RoutingResult {
            gap_id,
            task_type,
            required_skills,
            candidates: Vec::new(),
            selected_session: None,
            selection_reason: SelectionReason::NoMatch,
        };
    }

    let skills_data_unavailable =
        required_skills.is_empty() || candidates.iter().all(|c| c.skills.is_empty());

    candidates.sort_by(|a, b| a.session.cmp(&b.session));

    let mut scored: Vec<ScoredCandidate> = candidates
        .into_iter()
        .map(|c| {
            let match_score = if skills_data_unavailable {
                1.0
            } else {
                jaccard(&required_skills, &c.skills)
            };
            ScoredCandidate {
                session: c.session,
                skills: c.skills,
                match_score,
                freshness_age_s: c.freshness_age_s,
                current_load_gaps: c.current_load_gaps,
            }
        })
        .collect();

    scored.sort_by(better_candidate);

    let best = &scored[0];
    let (selected_session, selection_reason) = if skills_data_unavailable {
        (
            Some(best.session.clone()),
            SelectionReason::FallbackRoundRobin,
        )
    } else if best.match_score <= 0.0 {
        (None, SelectionReason::NoMatch)
    } else {
        let required_set: std::collections::HashSet<_> = required_skills.iter().collect();
        let have_set: std::collections::HashSet<_> = best.skills.iter().collect();
        let is_superset = required_set.is_subset(&have_set);
        (
            Some(best.session.clone()),
            if is_superset {
                SelectionReason::SkillSuperset
            } else {
                SelectionReason::BestPartialMatch
            },
        )
    };

    RoutingResult {
        gap_id,
        task_type,
        required_skills,
        candidates: scored,
        selected_session,
        selection_reason,
    }
}

fn ambient_log_path() -> String {
    std::env::var("CHUMP_AMBIENT_LOG").unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string())
}

fn append_ambient_line(entry: &serde_json::Value) -> Result<()> {
    let ambient_path = ambient_log_path();
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
        .with_context(|| format!("opening ambient log at {ambient_path}"))?;
    writeln!(file, "{}", entry).with_context(|| format!("writing ambient log at {ambient_path}"))
}

/// Emit `kind=routing_decision` (schema `skill-routing-v1`) for `result`,
/// and — when `selection_reason == no_match` — the companion
/// `kind=skill_routing_no_match` event for operator visibility.
pub fn emit_routing_decision_event(result: &RoutingResult, router_session: &str) -> Result<()> {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let candidates: Vec<_> = result
        .candidates
        .iter()
        .map(|c| {
            serde_json::json!({
                "session": c.session,
                "skills": c.skills,
                "match_score": c.match_score,
                "freshness_age_s": c.freshness_age_s,
                "current_load_gaps": c.current_load_gaps,
            })
        })
        .collect();

    let entry = serde_json::json!({
        "ts": ts,
        "kind": "routing_decision",
        "schema_version": "skill-routing-v1",
        "gap_id": result.gap_id,
        "task_type": result.task_type.as_str(),
        "required_skills": result.required_skills,
        "candidates": candidates,
        "selected_session": result.selected_session,
        "selection_reason": result.selection_reason.as_str(),
        "session": router_session,
    });
    append_ambient_line(&entry)?;

    if result.selection_reason == SelectionReason::NoMatch && !result.required_skills.is_empty() {
        let available_skill_sets: Vec<_> = result.candidates.iter().map(|c| &c.skills).collect();
        let no_match_entry = serde_json::json!({
            "ts": ts,
            "kind": "skill_routing_no_match",
            "gap_id": result.gap_id,
            "required_skills": result.required_skills,
            "available_skill_sets": available_skill_sets,
            "session": router_session,
        });
        append_ambient_line(&no_match_entry)?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::TempDir;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn candidate(session: &str, skills: &[&str], freshness: u64, load: u32) -> RoutingCandidate {
        RoutingCandidate {
            session: session.to_string(),
            skills: skills.iter().map(|s| s.to_string()).collect(),
            freshness_age_s: freshness,
            current_load_gaps: load,
        }
    }

    #[test]
    fn exact_skill_match_wins_as_superset() {
        let candidates = vec![
            candidate(
                "generalist",
                &["rust", "docs", "shell", "ci", "python"],
                5,
                0,
            ),
            candidate("specialist", &["rust", "tokio", "sqlite"], 5, 0),
        ];
        let result = select_route(
            "INFRA-1",
            TaskType::RustImpl,
            vec!["rust".into(), "tokio".into(), "sqlite".into()],
            candidates,
        );

        assert_eq!(result.selected_session.as_deref(), Some("specialist"));
        assert_eq!(result.selection_reason, SelectionReason::SkillSuperset);
    }

    #[test]
    fn partial_match_wins_over_no_match() {
        let candidates = vec![
            candidate("docs-only", &["docs"], 5, 0),
            candidate("rust-ish", &["rust"], 5, 0),
        ];
        let result = select_route(
            "INFRA-2",
            TaskType::RustImpl,
            vec!["rust".into(), "tokio".into()],
            candidates,
        );

        assert_eq!(result.selected_session.as_deref(), Some("rust-ish"));
        assert_eq!(result.selection_reason, SelectionReason::BestPartialMatch);
    }

    #[test]
    fn zero_overlap_across_all_candidates_is_no_match() {
        let candidates = vec![candidate("docs-only", &["docs"], 5, 0)];
        let result = select_route(
            "INFRA-3",
            TaskType::RustImpl,
            vec!["rust".into()],
            candidates,
        );

        assert_eq!(result.selected_session, None);
        assert_eq!(result.selection_reason, SelectionReason::NoMatch);
    }

    #[test]
    fn empty_required_skills_falls_back_to_round_robin() {
        let candidates = vec![
            candidate("fresher", &["rust"], 1, 2),
            candidate("busier", &["rust"], 1, 0),
        ];
        let result = select_route("INFRA-4", TaskType::Unknown, vec![], candidates);

        assert_eq!(result.selection_reason, SelectionReason::FallbackRoundRobin);
        // freshness tie -> lowest load wins
        assert_eq!(result.selected_session.as_deref(), Some("busier"));
    }

    #[test]
    fn missing_skills_data_falls_back_to_round_robin() {
        let candidates = vec![
            candidate("agent-a", &[], 10, 1),
            candidate("agent-b", &[], 2, 1),
        ];
        let result = select_route(
            "INFRA-5",
            TaskType::Unknown,
            vec!["rust".into()],
            candidates,
        );

        assert_eq!(result.selection_reason, SelectionReason::FallbackRoundRobin);
        // no skills data at all -> tie-break on freshness
        assert_eq!(result.selected_session.as_deref(), Some("agent-b"));
    }

    #[test]
    fn no_candidates_is_no_match() {
        let result = select_route("INFRA-6", TaskType::Unknown, vec!["rust".into()], vec![]);
        assert_eq!(result.selected_session, None);
        assert_eq!(result.selection_reason, SelectionReason::NoMatch);
    }

    #[test]
    fn emits_routing_decision_event_to_ambient_log() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);

        let candidates = vec![candidate("specialist", &["rust", "sqlite"], 5, 0)];
        let result = select_route(
            "INFRA-7",
            TaskType::RustImpl,
            vec!["rust".into()],
            candidates,
        );
        emit_routing_decision_event(&result, "router-session").unwrap();

        let contents = fs::read_to_string(&ambient_path).unwrap();
        assert!(contents.contains("\"kind\":\"routing_decision\""));
        assert!(contents.contains("\"schema_version\":\"skill-routing-v1\""));
        assert!(contents.contains("\"selected_session\":\"specialist\""));
        assert!(contents.contains("\"selection_reason\":\"skill_superset\""));

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }

    #[test]
    fn no_match_also_emits_companion_event() {
        let _guard = ENV_LOCK.lock().unwrap();
        let dir = TempDir::new().unwrap();
        let ambient_path = dir.path().join("ambient.jsonl");
        std::env::set_var("CHUMP_AMBIENT_LOG", &ambient_path);

        let candidates = vec![candidate("docs-only", &["docs"], 5, 0)];
        let result = select_route(
            "INFRA-8",
            TaskType::RustImpl,
            vec!["rust".into()],
            candidates,
        );
        emit_routing_decision_event(&result, "router-session").unwrap();

        let contents = fs::read_to_string(&ambient_path).unwrap();
        assert!(contents.contains("\"kind\":\"routing_decision\""));
        assert!(contents.contains("\"kind\":\"skill_routing_no_match\""));

        std::env::remove_var("CHUMP_AMBIENT_LOG");
    }
}
