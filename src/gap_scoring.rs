// INFRA-1816: gap-value scorer, vendored from repairman29/echeo.
//
// Vendored from repairman29/echeo at commit afbe64d6ddea1a89a486015eac1d9584b26d785f
// Original: src/matchmaker.rs::calculate_ship_velocity_score (lines 51-106)
// Adaptations: (1) base distance fn = Jaccard skill-string overlap (v0)
//              instead of embedding cosine similarity, (2) added a recency
//              term over a RoutingOutcome window, (3) renamed terms to
//              Chump's gap/worker domain. Full mapping table + rationale:
//              docs/arsenal/cross-pollination/CP-005-echeo-ship-velocity-score.md
//
// Substrate for INFRA-1764 (skill-aware routing): the picker calls
// `calculate_gap_value_score` per (gap, worker) candidate and sorts
// descending. This module owns the score; INFRA-1764 must not compute a
// competing one.
//
// #[allow(dead_code)] until INFRA-1764 wires the picker call site.
#![allow(dead_code)]

use chump_gap_store::GapRow;

/// A worker's declared skills/capabilities for affinity scoring.
#[derive(Debug, Clone, Default)]
pub struct WorkerCapabilities {
    pub session_id: String,
    /// e.g. ["rust", "sqlite", "macos"]
    pub skills: Vec<String>,
    /// e.g. ["rust", "python"]
    pub languages: Vec<String>,
    /// e.g. Some("INFRA")
    pub last_ship_class: Option<String>,
}

/// A single historical routing outcome, used for the recency term.
#[derive(Debug, Clone)]
pub struct RoutingOutcome {
    /// Domain prefix at routing time, e.g. "INFRA".
    pub gap_class: String,
    pub worker_session: String,
    pub shipped_ok: bool,
    pub age_hours: u32,
}

/// Parse a gap's `skills_required` field (JSON array or comma-separated
/// string, both forms appear in the wild — see gap_store parsing) into a
/// lowercased Vec<String>.
fn parse_skills(raw: &str) -> Vec<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    if trimmed.starts_with('[') {
        if let Ok(list) = serde_json::from_str::<Vec<String>>(trimmed) {
            return list.into_iter().map(|s| s.to_lowercase()).collect();
        }
    }
    trimmed
        .split(',')
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Jaccard overlap of two skill sets: |A ∩ B| / |A ∪ B|, in 0.0..=1.0.
/// Mirrors echeo's cosine-similarity base term (v0 substitute — no
/// embedding infra required; see CP-005 v0-vs-v1 tradeoff).
fn jaccard_overlap(a: &[String], b: &[String]) -> f32 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let set_a: std::collections::HashSet<&String> = a.iter().collect();
    let set_b: std::collections::HashSet<&String> = b.iter().collect();
    let intersection = set_a.intersection(&set_b).count();
    let union = set_a.union(&set_b).count();
    if union == 0 {
        0.0
    } else {
        intersection as f32 / union as f32
    }
}

/// Calculate a gap-value score for a (gap, worker) pair in 0.0..=1.0.
///
/// Boost shape mirrors echeo's `calculate_ship_velocity_score`:
///   base (skill-set overlap) + language boost (0.10) + domain boost (0.05)
///   + recency term (±0.05), clamped to 0.0..=1.0.
pub fn calculate_gap_value_score(
    gap: &GapRow,
    worker_caps: &WorkerCapabilities,
    recent_outcomes: &[RoutingOutcome],
) -> (f32, Vec<String>) {
    let mut reasons = Vec::new();

    let gap_skills = parse_skills(&gap.skills_required);
    let base = jaccard_overlap(&gap_skills, &worker_caps.skills);
    let mut score = base;

    if base > 0.7 {
        reasons.push(format!("High skill overlap ({:.0}%)", base * 100.0));
    } else if base > 0.3 {
        reasons.push(format!("Moderate skill overlap ({:.0}%)", base * 100.0));
    }

    // Language boost: any worker language appears among the gap's
    // required skills.
    let language_match = worker_caps
        .languages
        .iter()
        .any(|lang| gap_skills.iter().any(|s| s == &lang.to_lowercase()));
    if language_match {
        score += 0.10;
        reasons.push("Language match".to_string());
    }

    // Domain boost: worker's last shipped class matches this gap's domain.
    let domain_match = worker_caps
        .last_ship_class
        .as_deref()
        .map(|c| c.eq_ignore_ascii_case(&gap.domain))
        .unwrap_or(false);
    if domain_match {
        score += 0.05;
        reasons.push(format!("Domain match: {}", gap.domain));
    }

    // Recency term: recent outcomes for this worker in this gap's domain
    // nudge the score up (shipped_ok) or down (failed), capped at ±0.05
    // total regardless of outcome count (anti-gaming, per CP-005 risk
    // section).
    let relevant: Vec<&RoutingOutcome> = recent_outcomes
        .iter()
        .filter(|o| {
            o.worker_session == worker_caps.session_id
                && o.gap_class.eq_ignore_ascii_case(&gap.domain)
        })
        .collect();
    if !relevant.is_empty() {
        let ok_count = relevant.iter().filter(|o| o.shipped_ok).count();
        let fail_count = relevant.len() - ok_count;
        let recency_delta = if ok_count >= fail_count { 0.05 } else { -0.05 };
        score += recency_delta;
        if recency_delta > 0.0 {
            reasons.push(format!(
                "Recent {} ships in {} (recency boost)",
                ok_count, gap.domain
            ));
        } else {
            reasons.push(format!(
                "Recent {} failures in {} (recency penalty)",
                fail_count, gap.domain
            ));
        }
    }

    score = score.clamp(0.0, 1.0);

    (score, reasons)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synthetic_gap() -> GapRow {
        GapRow {
            id: "TEST-1".to_string(),
            domain: "INFRA".to_string(),
            title: "synthetic".to_string(),
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
            skills_required: "[\"rust\",\"sqlite\"]".to_string(),
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
    fn matching_gap_scores_high() {
        let gap = synthetic_gap();
        let worker = WorkerCapabilities {
            session_id: "worker-1".to_string(),
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
            worker_session: "worker-1".to_string(),
            shipped_ok: true,
            age_hours: 2,
        }];

        let (score, reasons) = calculate_gap_value_score(&gap, &worker, &outcomes);

        // base Jaccard = 2/3 ≈ 0.667, +0.10 language, +0.05 domain, +0.05 recency
        assert!(
            (0.85..=0.95).contains(&score),
            "expected score in 0.85..=0.95, got {score}"
        );
        assert!(reasons.iter().any(|r| r.contains("overlap")));
        assert!(reasons.iter().any(|r| r.contains("Language")));
        assert!(reasons.iter().any(|r| r.contains("Domain")));
        assert!(reasons
            .iter()
            .any(|r| r.contains("recency") || r.contains("boost")));
    }

    #[test]
    fn mismatched_gap_scores_low() {
        let mut gap = synthetic_gap();
        gap.domain = "DOC".to_string();
        gap.skills_required = "[\"python\"]".to_string();
        let worker = WorkerCapabilities {
            session_id: "worker-2".to_string(),
            skills: vec!["rust".to_string()],
            languages: vec!["rust".to_string()],
            last_ship_class: Some("INFRA".to_string()),
        };

        let (score, reasons) = calculate_gap_value_score(&gap, &worker, &[]);

        assert!(score < 0.3, "expected score < 0.3, got {score}");
        assert!(
            reasons.is_empty(),
            "expected no reasons to fire, got {reasons:?}"
        );
    }

    #[test]
    fn score_clamps_at_one() {
        let gap = synthetic_gap();
        let worker = WorkerCapabilities {
            session_id: "worker-3".to_string(),
            skills: vec!["rust".to_string(), "sqlite".to_string()],
            languages: vec!["rust".to_string()],
            last_ship_class: Some("INFRA".to_string()),
        };
        let outcomes = vec![RoutingOutcome {
            gap_class: "INFRA".to_string(),
            worker_session: "worker-3".to_string(),
            shipped_ok: true,
            age_hours: 1,
        }];

        let (score, _reasons) = calculate_gap_value_score(&gap, &worker, &outcomes);

        // base Jaccard = 1.0 (identical sets) + 0.10 + 0.05 + 0.05 = 1.20 -> clamp
        assert!(
            (score - 1.0).abs() < f32::EPSILON,
            "expected clamp to 1.0, got {score}"
        );
    }

    #[test]
    fn deterministic_repeat_calls() {
        let gap = synthetic_gap();
        let worker = WorkerCapabilities {
            session_id: "worker-4".to_string(),
            skills: vec!["rust".to_string()],
            languages: vec![],
            last_ship_class: None,
        };

        let (score_a, _) = calculate_gap_value_score(&gap, &worker, &[]);
        let (score_b, _) = calculate_gap_value_score(&gap, &worker, &[]);

        assert_eq!(score_a, score_b, "same inputs must produce same score");
    }
}
