//! Gap-value scorer — INFRA-1816.
//!
//! Vendored from `repairman29/echeo` at commit
//! `afbe64d6ddea1a89a486015eac1d9584b26d785f`, `src/matchmaker.rs::calculate_ship_velocity_score`
//! (lines 51-106). See `docs/arsenal/cross-pollination/CP-005-echeo-ship-velocity-score.md`
//! for the full harvest brief and gap-vs-need mapping.
//!
//! Adaptations vs. the echeo original:
//!   1. Base distance fn = Jaccard string-overlap of skills (v0) instead of embedding
//!      cosine similarity — no Ollama/embedding-cache dependency for this gap.
//!   2. Added a recency term over a `RoutingOutcome` window (echeo has no equivalent —
//!      echeo matches code capabilities to bounties once, it doesn't track worker history).
//!   3. Renamed terms into Chump's gap/worker domain (`Need` -> `GapRow`,
//!      `EmbeddedCapability` -> `WorkerCapabilities`).
//!
//! This module is the substrate for INFRA-1764 (skill-aware routing). INFRA-1764's
//! picker calls `calculate_gap_value_score` directly rather than computing its own
//! competing score.

use chump_gap_store::GapRow;

/// Per-worker routing capabilities used as the scoring input.
#[derive(Debug, Clone, Default)]
pub struct WorkerCapabilities {
    pub session_id: String,
    /// e.g. ["rust", "sqlite", "macos"]
    pub skills: Vec<String>,
    /// e.g. ["rust", "python"]
    pub languages: Vec<String>,
    /// e.g. "INFRA" | "FLEET" | "DOC"
    pub last_ship_class: Option<String>,
}

/// A single past routing decision, used for the recency term.
#[derive(Debug, Clone)]
pub struct RoutingOutcome {
    /// Domain prefix at routing time (e.g. "INFRA").
    pub gap_class: String,
    pub worker_session: String,
    pub shipped_ok: bool,
    /// Age of the outcome in hours; only outcomes within the recency window count.
    pub age_hours: u32,
}

/// echeo's threshold gate (`match_need`, matchmaker.rs:122): sub-threshold matches
/// are dropped entirely, before scoring.
const SIMILARITY_THRESHOLD: f32 = 0.3;
const LANGUAGE_BOOST: f32 = 0.10;
const DOMAIN_BOOST: f32 = 0.05;
const RECENCY_BOOST: f32 = 0.05;
const RECENCY_WINDOW_HOURS: u32 = 24;

fn parse_skills_required(skills_required: &str) -> Vec<String> {
    // gap_store persists skills_required either as a comma-separated string or a
    // JSON array string (picker fixtures use `["rust","sqlite"]`); accept both.
    let trimmed = skills_required.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    if let Ok(parsed) = serde_json::from_str::<Vec<String>>(trimmed) {
        return parsed.into_iter().map(|s| s.to_lowercase()).collect();
    }
    trimmed
        .split(',')
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Jaccard overlap of two skill sets, in `0.0..=1.0`. Empty-vs-empty is 0.0 (no
/// signal either way, not a perfect match).
fn jaccard_overlap(a: &[String], b: &[String]) -> f32 {
    use std::collections::HashSet;
    let set_a: HashSet<&String> = a.iter().collect();
    let set_b: HashSet<&String> = b.iter().collect();
    if set_a.is_empty() || set_b.is_empty() {
        return 0.0;
    }
    let intersection = set_a.intersection(&set_b).count();
    let union = set_a.union(&set_b).count();
    if union == 0 {
        0.0
    } else {
        intersection as f32 / union as f32
    }
}

/// Port of echeo's `calculate_ship_velocity_score` (matchmaker.rs:53-106) into
/// Chump's gap/worker domain. Returns `(score, reasons)` where `score` is clamped
/// to `0.0..=1.0` and `reasons` accrues in emission order (base -> language ->
/// domain -> recency), mirroring echeo's audit-trail ordering.
pub fn calculate_gap_value_score(
    gap: &GapRow,
    worker_caps: &WorkerCapabilities,
    recent_outcomes: &[RoutingOutcome],
) -> (f32, Vec<String>) {
    let gap_skills = parse_skills_required(&gap.skills_required);
    let worker_skills: Vec<String> = worker_caps
        .skills
        .iter()
        .map(|s| s.to_lowercase())
        .collect();

    let base = jaccard_overlap(&gap_skills, &worker_skills);
    let mut score = base;
    let mut reasons = Vec::new();

    if base > 0.7 {
        reasons.push(format!("High skill overlap ({:.0}%)", base * 100.0));
    } else if base > 0.5 {
        reasons.push(format!("Moderate skill overlap ({:.0}%)", base * 100.0));
    }

    // Language boost — echeo matchmaker.rs:75-83.
    let gap_domain_lower = gap.domain.to_lowercase();
    let language_match = worker_caps
        .languages
        .iter()
        .any(|lang| gap_skills.iter().any(|s| s == &lang.to_lowercase()));
    if language_match {
        score += LANGUAGE_BOOST;
        if let Some(lang) = worker_caps
            .languages
            .iter()
            .find(|lang| gap_skills.iter().any(|s| s == &lang.to_lowercase()))
        {
            reasons.push(format!("Language match: {lang}"));
        }
    }

    // Domain boost — echeo's kind boost (matchmaker.rs:85-95), reinterpreted as
    // "worker's last ship class matches this gap's domain".
    if worker_caps
        .last_ship_class
        .as_deref()
        .map(|c| c.to_lowercase() == gap_domain_lower)
        .unwrap_or(false)
    {
        score += DOMAIN_BOOST;
        reasons.push(format!("Domain match: {}", gap.domain));
    }

    // Recency term — new vs. echeo, encodes INFRA-1764's "historical-best-performer"
    // intent. Filtered to this worker + this gap's domain, within the recency window.
    let relevant: Vec<&RoutingOutcome> = recent_outcomes
        .iter()
        .filter(|o| {
            o.worker_session == worker_caps.session_id
                && o.gap_class.to_lowercase() == gap_domain_lower
                && o.age_hours <= RECENCY_WINDOW_HOURS
        })
        .collect();
    if !relevant.is_empty() {
        let all_ok = relevant.iter().all(|o| o.shipped_ok);
        if all_ok {
            score += RECENCY_BOOST;
            reasons.push(format!(
                "Recent {} ship success ({}h ago)",
                gap.domain,
                relevant.iter().map(|o| o.age_hours).min().unwrap_or(0)
            ));
        } else {
            score -= RECENCY_BOOST;
            reasons.push(format!("Recent {} ship failure", gap.domain));
        }
    }

    // Clamp — echeo caps at 1.0 only (matchmaker.rs:97-98); Chump also floors at
    // 0.0 since the recency term can go negative.
    score = score.clamp(0.0, 1.0);

    if score <= SIMILARITY_THRESHOLD {
        reasons.clear();
    }

    (score, reasons)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gap(domain: &str, skills_required: &str) -> GapRow {
        GapRow {
            id: "TEST-1".to_string(),
            domain: domain.to_string(),
            title: "test gap".to_string(),
            description: String::new(),
            priority: "P1".to_string(),
            effort: "s".to_string(),
            status: "open".to_string(),
            acceptance_criteria: String::new(),
            depends_on: "[]".to_string(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at: None,
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: None,
            skills_required: skills_required.to_string(),
            preferred_backend: String::new(),
            preferred_machine: String::new(),
            estimated_minutes: String::new(),
            required_model: String::new(),
            shipped_in: None,
            outcome_id: None,
            evidence: None,
        }
    }

    #[test]
    fn full_match_clamps_at_one() {
        let g = gap("INFRA", "rust,sqlite");
        let worker = WorkerCapabilities {
            session_id: "w1".to_string(),
            skills: vec![
                "rust".to_string(),
                "sqlite".to_string(),
                "macos".to_string(),
            ],
            languages: vec!["rust".to_string()],
            last_ship_class: Some("INFRA".to_string()),
        };
        let outcomes = vec![RoutingOutcome {
            gap_class: "INFRA".to_string(),
            worker_session: "w1".to_string(),
            shipped_ok: true,
            age_hours: 2,
        }];
        let (score, reasons) = calculate_gap_value_score(&g, &worker, &outcomes);
        assert!(score >= 0.85 && score <= 1.0, "score={score}");
        assert!(reasons.iter().any(|r| r.contains("Language")));
        assert!(reasons.iter().any(|r| r.contains("Domain")));
        assert!(reasons.iter().any(|r| r.contains("Recent")));
    }

    #[test]
    fn mismatch_scores_below_threshold_with_no_reasons() {
        let g = gap("DOC", "python,markdown");
        let worker = WorkerCapabilities {
            session_id: "w1".to_string(),
            skills: vec!["rust".to_string()],
            languages: vec!["rust".to_string()],
            last_ship_class: Some("INFRA".to_string()),
        };
        let (score, reasons) = calculate_gap_value_score(&g, &worker, &[]);
        assert!(score < SIMILARITY_THRESHOLD, "score={score}");
        assert!(reasons.is_empty());
    }

    #[test]
    fn deterministic_same_inputs_same_score() {
        let g = gap("INFRA", "rust,sqlite");
        let worker = WorkerCapabilities {
            session_id: "w1".to_string(),
            skills: vec!["rust".to_string(), "sqlite".to_string()],
            languages: vec!["rust".to_string()],
            last_ship_class: None,
        };
        let (s1, _) = calculate_gap_value_score(&g, &worker, &[]);
        let (s2, _) = calculate_gap_value_score(&g, &worker, &[]);
        assert_eq!(s1, s2);
    }
}
