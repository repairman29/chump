//! EFFECTIVE-1408 (EFFECTIVE-374 slice): allowlist + leverage-tier gate for
//! portfolio sweeps.
//!
//! The posse outward NO-GO (2026-08-04, binding) says sweep tooling only
//! ever touches OWNED repos. Every future sweep organ (posse crawls, almanac
//! fluff-audits, etc.) must call `gate_and_prioritize` on its candidate list
//! BEFORE issuing a single network request or scan: unowned repos are
//! stripped out and logged as a NO-GO, and survivors are ordered by
//! opportunity-library leverage tier (4-star+ swept first) per EFFECTIVE-374.

use crate::ambient_emit::{emit, EmitArgs};
use crate::repo_allowlist;
use std::path::Path;

/// Minimum leverage tier considered "4-star+" for sweep prioritization.
pub const FOUR_STAR_TIER: u8 = 4;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SweepCandidate {
    /// owner/name
    pub repo: String,
    /// opportunity-library leverage tier, 0-5 stars
    pub star_tier: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RejectedCandidate {
    pub repo: String,
    pub reason: String,
}

#[derive(Debug, Clone, Default)]
pub struct GateResult {
    /// Owned repos only, sorted 4-star+ (and generally highest tier) first.
    pub allowed: Vec<SweepCandidate>,
    /// Foreign/unowned repos, strictly rejected before any scan runs.
    pub rejected: Vec<RejectedCandidate>,
}

/// Strictly validate `candidates` against the owned-repo allowlist and order
/// survivors by leverage tier. No candidate that fails the allowlist check is
/// ever included in `allowed` — callers must not scan/network anything until
/// they have this function's `allowed` list in hand.
pub fn gate_and_prioritize(candidates: Vec<SweepCandidate>) -> GateResult {
    let mut allowed = Vec::new();
    let mut rejected = Vec::new();

    for candidate in candidates {
        if repo_allowlist::allowlist_contains(&candidate.repo) {
            allowed.push(candidate);
        } else {
            let reason = format!(
                "NO-GO: {} is not in the owned-repo allowlist (posse outward NO-GO, \
                 2026-08-04, binding) — refusing before any network request or scan",
                candidate.repo
            );
            rejected.push(RejectedCandidate {
                repo: candidate.repo,
                reason,
            });
        }
    }

    // Highest leverage tier first; stable sort preserves relative order of
    // repos that share a tier.
    allowed.sort_by(|a, b| b.star_tier.cmp(&a.star_tier));

    GateResult { allowed, rejected }
}

/// Emit one `kind=sweep_target_rejected` ambient event per rejection so the
/// NO-GO is a durable, auditable log entry rather than a transient stderr line.
pub fn log_rejections(repo_root: &Path, rejected: &[RejectedCandidate]) {
    for r in rejected {
        let _ = emit(&EmitArgs {
            kind: "sweep_target_rejected".to_string(),
            fields: vec![
                ("repo".to_string(), r.repo.clone()),
                ("reason".to_string(), r.reason.clone()),
            ],
            ambient_override: Some(repo_root.join(".chump-locks/ambient.jsonl")),
            ..Default::default()
        });
        eprintln!("chump portfolio-sweep-gate: {}", r.reason);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(repo: &str, star_tier: u8) -> SweepCandidate {
        SweepCandidate {
            repo: repo.to_string(),
            star_tier,
        }
    }

    #[test]
    fn rejects_repos_outside_env_allowlist() {
        std::env::set_var("CHUMP_GITHUB_REPOS", "repairman29/owned-one");
        let result = gate_and_prioritize(vec![
            candidate("repairman29/owned-one", 3),
            candidate("stranger/foreign", 5),
        ]);
        assert_eq!(result.allowed.len(), 1);
        assert_eq!(result.allowed[0].repo, "repairman29/owned-one");
        assert_eq!(result.rejected.len(), 1);
        assert_eq!(result.rejected[0].repo, "stranger/foreign");
        assert!(result.rejected[0].reason.contains("NO-GO"));
        std::env::remove_var("CHUMP_GITHUB_REPOS");
    }

    #[test]
    fn empty_allowlist_rejects_everything() {
        std::env::remove_var("CHUMP_GITHUB_REPOS");
        let result = gate_and_prioritize(vec![candidate("anyone/anything", 5)]);
        assert!(result.allowed.is_empty());
        assert_eq!(result.rejected.len(), 1);
    }

    #[test]
    fn prioritizes_four_star_plus_first() {
        std::env::set_var(
            "CHUMP_GITHUB_REPOS",
            "repairman29/low,repairman29/high,repairman29/mid",
        );
        let result = gate_and_prioritize(vec![
            candidate("repairman29/low", 1),
            candidate("repairman29/high", 5),
            candidate("repairman29/mid", 4),
        ]);
        let ordered: Vec<&str> = result.allowed.iter().map(|c| c.repo.as_str()).collect();
        assert_eq!(ordered, vec!["repairman29/high", "repairman29/mid", "repairman29/low"]);
        assert!(result.allowed[0].star_tier >= FOUR_STAR_TIER);
        assert!(result.allowed[1].star_tier >= FOUR_STAR_TIER);
        std::env::remove_var("CHUMP_GITHUB_REPOS");
    }

    #[test]
    fn stable_sort_preserves_order_within_same_tier() {
        std::env::set_var("CHUMP_GITHUB_REPOS", "repairman29/a,repairman29/b,repairman29/c");
        let result = gate_and_prioritize(vec![
            candidate("repairman29/a", 4),
            candidate("repairman29/b", 4),
            candidate("repairman29/c", 4),
        ]);
        let ordered: Vec<&str> = result.allowed.iter().map(|c| c.repo.as_str()).collect();
        assert_eq!(ordered, vec!["repairman29/a", "repairman29/b", "repairman29/c"]);
        std::env::remove_var("CHUMP_GITHUB_REPOS");
    }
}
