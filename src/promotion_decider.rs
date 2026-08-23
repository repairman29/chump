//! INFRA-3663 — recurrence-counted capability-promotion loop (advisory v0).
//!
//! A generic, storage-agnostic decision function: given a stream of
//! recurrence observations for a candidate (a capability, pattern, or
//! detector class that keeps showing up), decide whether the candidate has
//! recurred often enough — and succeeded often enough when it did — to be
//! *advisory-recommended* for promotion.
//!
//! v0 is advisory-only: `decide()` never mutates any state and never
//! performs a promotion itself. It returns a verdict per candidate; the
//! caller (a human, a curator loop, or a future v1 that wires this into
//! `finding_class_tiers`-style storage) decides whether to act on it.
//! This mirrors the read-then-decide split already used by
//! `chump-inventory::class_stats` / `promote_class`, generalized so any
//! future recurrence source (ambient events, capability files, lesson
//! captures) can reuse the same decision core without a DB dependency.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One observed recurrence of a candidate capability.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecurrenceObservation {
    pub candidate_id: String,
    pub success: bool,
}

/// Thresholds gating an advisory promotion recommendation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PromotionThresholds {
    /// Minimum number of distinct recurrences before promotion is even
    /// considered — a single lucky success is not a pattern.
    pub min_occurrences: usize,
    /// Minimum success ratio (successes / occurrences) required.
    pub min_success_ratio: f64,
}

impl Default for PromotionThresholds {
    fn default() -> Self {
        // Mirrors chump-inventory's PROMOTE_MIN_REVIEWED(10) / 0.70 calibration
        // bar, scaled down for v0 advisory use (lower occurrence floor since
        // this loop has no reviewed/unreviewed split yet).
        PromotionThresholds {
            min_occurrences: 5,
            min_success_ratio: 0.70,
        }
    }
}

/// Advisory verdict for one candidate — never enacted automatically.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PromotionAdvisory {
    pub candidate_id: String,
    pub occurrences: usize,
    pub success_count: usize,
    pub success_ratio: f64,
    pub recommend_promote: bool,
    pub reason: String,
}

/// Aggregate `observations` by `candidate_id` and decide an advisory verdict
/// for each one against `thresholds`. Output is sorted by `candidate_id` for
/// deterministic reporting.
pub fn decide(
    observations: &[RecurrenceObservation],
    thresholds: &PromotionThresholds,
) -> Vec<PromotionAdvisory> {
    let mut counts: BTreeMap<&str, (usize, usize)> = BTreeMap::new();
    for obs in observations {
        let entry = counts.entry(obs.candidate_id.as_str()).or_insert((0, 0));
        entry.0 += 1;
        if obs.success {
            entry.1 += 1;
        }
    }

    counts
        .into_iter()
        .map(|(candidate_id, (occurrences, success_count))| {
            let success_ratio = if occurrences == 0 {
                0.0
            } else {
                success_count as f64 / occurrences as f64
            };

            let meets_occurrences = occurrences >= thresholds.min_occurrences;
            let meets_ratio = success_ratio >= thresholds.min_success_ratio;
            let recommend_promote = meets_occurrences && meets_ratio;

            let reason = if recommend_promote {
                format!(
                    "recurred {occurrences}x (>= {}) at {:.0}% success (>= {:.0}%) — advisory: promote",
                    thresholds.min_occurrences,
                    success_ratio * 100.0,
                    thresholds.min_success_ratio * 100.0
                )
            } else if !meets_occurrences {
                format!(
                    "only recurred {occurrences}x, needs >= {} before promotion is considered",
                    thresholds.min_occurrences
                )
            } else {
                format!(
                    "recurred {occurrences}x but only {:.0}% success, needs >= {:.0}%",
                    success_ratio * 100.0,
                    thresholds.min_success_ratio * 100.0
                )
            };

            PromotionAdvisory {
                candidate_id: candidate_id.to_string(),
                occurrences,
                success_count,
                success_ratio,
                recommend_promote,
                reason,
            }
        })
        .collect()
}

/// Parse `RecurrenceObservation`s out of newline-delimited JSON text (e.g. an
/// ambient-log slice). Malformed lines are silently skipped so a corrupted or
/// unrelated event mixed into the stream can't crash the decider — this is
/// an advisory read path, not a source of truth.
pub fn parse_jsonl(text: &str) -> Vec<RecurrenceObservation> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() {
                return None;
            }
            serde_json::from_str::<RecurrenceObservation>(line).ok()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs(id: &str, success: bool) -> RecurrenceObservation {
        RecurrenceObservation {
            candidate_id: id.into(),
            success,
        }
    }

    #[test]
    fn below_occurrence_floor_is_not_recommended() {
        let observations = vec![obs("cap-a", true), obs("cap-a", true)];
        let advisories = decide(&observations, &PromotionThresholds::default());
        assert_eq!(advisories.len(), 1);
        assert!(!advisories[0].recommend_promote);
        assert_eq!(advisories[0].occurrences, 2);
        assert!(advisories[0].reason.contains("needs >="));
    }

    #[test]
    fn below_success_ratio_is_not_recommended_even_with_enough_occurrences() {
        // 5 occurrences (meets floor), but only 2/5 = 40% success (< 70%).
        let observations = vec![
            obs("cap-b", true),
            obs("cap-b", true),
            obs("cap-b", false),
            obs("cap-b", false),
            obs("cap-b", false),
        ];
        let advisories = decide(&observations, &PromotionThresholds::default());
        assert_eq!(advisories.len(), 1);
        assert!(!advisories[0].recommend_promote);
        assert!((advisories[0].success_ratio - 0.4).abs() < 1e-9);
    }

    #[test]
    fn meets_both_floors_is_recommended() {
        // 5 occurrences, 4/5 = 80% success (>= 70%).
        let observations = vec![
            obs("cap-c", true),
            obs("cap-c", true),
            obs("cap-c", true),
            obs("cap-c", true),
            obs("cap-c", false),
        ];
        let advisories = decide(&observations, &PromotionThresholds::default());
        assert_eq!(advisories.len(), 1);
        assert!(advisories[0].recommend_promote);
        assert_eq!(advisories[0].success_count, 4);
        assert!(advisories[0].reason.contains("promote"));
    }

    #[test]
    fn multiple_candidates_are_independently_decided() {
        let observations = vec![
            obs("cap-strong", true),
            obs("cap-strong", true),
            obs("cap-strong", true),
            obs("cap-strong", true),
            obs("cap-strong", true),
            obs("cap-weak", false),
            obs("cap-weak", true),
        ];
        let advisories = decide(&observations, &PromotionThresholds::default());
        assert_eq!(advisories.len(), 2);
        let strong = advisories
            .iter()
            .find(|a| a.candidate_id == "cap-strong")
            .unwrap();
        let weak = advisories
            .iter()
            .find(|a| a.candidate_id == "cap-weak")
            .unwrap();
        assert!(strong.recommend_promote);
        assert!(!weak.recommend_promote);
    }

    #[test]
    fn empty_input_yields_no_advisories() {
        let advisories = decide(&[], &PromotionThresholds::default());
        assert!(advisories.is_empty());
    }

    #[test]
    fn custom_thresholds_are_respected() {
        let observations = vec![obs("cap-d", true), obs("cap-d", true)];
        let lenient = PromotionThresholds {
            min_occurrences: 2,
            min_success_ratio: 1.0,
        };
        let advisories = decide(&observations, &lenient);
        assert!(advisories[0].recommend_promote);
    }

    #[test]
    fn parse_jsonl_skips_malformed_lines() {
        let text = "{\"candidate_id\":\"cap-e\",\"success\":true}\n\
                     not json at all\n\
                     \n\
                     {\"candidate_id\":\"cap-e\",\"success\":false}\n";
        let parsed = parse_jsonl(text);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].candidate_id, "cap-e");
        assert!(parsed[0].success);
        assert!(!parsed[1].success);
    }

    #[test]
    fn advisories_are_sorted_by_candidate_id() {
        let observations = vec![obs("zeta", true), obs("alpha", true)];
        let advisories = decide(&observations, &PromotionThresholds::default());
        assert_eq!(advisories[0].candidate_id, "alpha");
        assert_eq!(advisories[1].candidate_id, "zeta");
    }
}
