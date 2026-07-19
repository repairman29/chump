//! Standard L1 mission set for the 0→1 onboard loop (EFFECTIVE-199).
//!
//! This module defines the five L1 "Foundation" missions that the 0→1 audit
//! auto-injects into the foundation queue for any onboarded external repo.
//!
//! # What "L1" means
//!
//! L1 missions are **objective** — each criterion either passes or fails, no
//! judgment required.  They must all complete before the audit starts any L2
//! (Fulfillment) or L3 (Realization) work.
//!
//! See the doctrine doc at:
//!   `docs/design/ONBOARD_0TO1_DOCTRINE.md`
//!
//! # Consuming this module (later gap)
//!
//! The 0→1 audit (`chump onboard --audit`, a later gap) reads
//! `STANDARD_L1_MISSIONS` to seed the foundation queue.  Each entry maps to a
//! `ProposedGap` (see `crates/chump-handoff/src/external_repo_schema.rs`) with:
//!   - `domain` = "INFRA"
//!   - `priority` = P1 (foundation work, not P0 — only true unblockers are P0)
//!   - `effort` = S (each is a small, bounded change)
//!   - `confidence` = High (these are objective checks, not inferences)
//!   - `layer` tag = "L1" (stored in `skills_required` or a dedicated `layer` field)
//!
//! The audit skips any mission whose `done_criterion` is already satisfied in
//! the target repo (e.g. CI already exists → `ci-gates-every-pr` is skipped).

// ── Types ─────────────────────────────────────────────────────────────────

/// A single entry in the standard L1 foundation queue.
///
/// Instances live as `&'static StandardMission` — there is no heap allocation
/// and no serde dependency in this module.  The consuming audit converts these
/// to `ProposedGap` records when it builds the mission portfolio.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StandardMission {
    /// Stable identifier used as the gap title prefix and for deduplication.
    /// Format: kebab-case, no spaces.
    pub id: &'static str,
    /// Human-readable title following Chump pillar-prefix convention.
    pub title: &'static str,
    /// Doctrine layer — always "L1" for this set.
    pub layer: &'static str,
    /// A single, testable statement of what "done" looks like for this mission.
    /// The 0→1 audit uses this as the `acceptance_criteria_draft[0]`.
    pub done_criterion: &'static str,
}

// ── The five standard L1 missions ─────────────────────────────────────────

/// The canonical five L1 Foundation missions injected for every onboarded repo.
///
/// Order matters: the audit queues them in this order within `sequence: 0`
/// (L1 layer), resolving ties by position.  The ordering reflects a natural
/// dependency: you want a working build before you can reliably run tests; you
/// want passing tests before you gate PRs on them; clean secrets and deps are
/// prerequisites for both.
pub const STANDARD_L1_MISSIONS: &[StandardMission] = &[
    StandardMission {
        id: "build-clean-from-checkout",
        title: "INFRA: clean build from a fresh checkout — no undeclared deps or manual steps",
        layer: "L1",
        done_criterion: "Running the documented build command on a clean clone succeeds \
                         without requiring any manual setup steps beyond what the README \
                         or CONTRIBUTING.md describes.",
    },
    StandardMission {
        id: "deps-resolve",
        title: "INFRA: all declared dependencies resolve from the lock file",
        layer: "L1",
        done_criterion: "The package manager lock file is present and `install` / `fetch` \
                         completes successfully in CI on a cold cache, with no missing or \
                         conflicting dependencies.",
    },
    StandardMission {
        id: "tests-run-in-ci",
        title: "INFRA: test suite runs and passes in CI",
        layer: "L1",
        done_criterion: "The CI workflow runs the project's test suite and all tests pass; \
                         a subsequent PR that introduces a failing test causes CI to go red.",
    },
    StandardMission {
        id: "ci-gates-every-pr",
        title: "INFRA: CI is required on every PR — no merge path bypasses it",
        layer: "L1",
        done_criterion: "The default branch has branch protection (or equivalent) requiring \
                         at least one CI status check to pass before a PR can be merged.",
    },
    StandardMission {
        id: "no-secrets-committed",
        title: "CREDIBLE: no credentials, tokens, or private keys in the repository",
        layer: "L1",
        done_criterion: "A secret-scanning pass (truffleHog, gitleaks, or equivalent) finds \
                         zero high-confidence credential matches in the full commit history \
                         and at HEAD.",
    },
];

// ── README-claim mission (L2 boundary, included here for completeness) ────

/// The fifth standard mission is the bridge between L1 and L2: every claim in
/// the README must have a corresponding passing test.  It is defined here so
/// the audit can reference it, but it is tagged L2 because it requires reading
/// and interpreting the README (not purely objective).
///
/// The 0→1 audit treats this as the first L2 seed, not part of the L1 queue.
pub const README_CLAIM_HAS_TEST: StandardMission = StandardMission {
    id: "every-readme-claim-has-a-test",
    title: "EFFECTIVE: every documented feature in the README has a working, passing test",
    layer: "L2",
    done_criterion: "For each feature, command, or API surface described as working in the \
                     README, there exists at least one automated test that would fail if \
                     that feature were removed or broken.",
};

// ── Helpers ────────────────────────────────────────────────────────────────

/// Return all five L1 missions as a slice.
///
/// This is the canonical entry point for the 0→1 audit.  Callers should use
/// this function (rather than referencing `STANDARD_L1_MISSIONS` directly) so
/// that a future version can merge in repo-specific overrides cleanly.
pub fn l1_missions() -> &'static [StandardMission] {
    STANDARD_L1_MISSIONS
}

/// Return the single README-claim L2 seed mission.
pub fn readme_claim_mission() -> StandardMission {
    README_CLAIM_HAS_TEST
}

// ── EFFECTIVE-201: Mission check results ───────────────────────────────────

/// Result of checking one L1 mission against a specific repo clone.
#[derive(Debug, Clone)]
pub enum MissionCheckResult {
    /// The mission is already satisfied — do NOT emit a gap.
    Met,
    /// The mission is not satisfied — emit an L1 ProposedGap.
    Unmet {
        /// Human-readable explanation of why the gate is unmet.
        why: String,
        /// File (or pseudo-path) used as evidence.
        evidence_path: String,
        /// Short verbatim excerpt or description of the evidence.
        excerpt: String,
    },
}

/// Run all L1 mission checks against the given repo clone directory.
///
/// Returns one `MissionCheckResult` per mission in the same order as the
/// input slice. All checks are heuristic and intentionally over-inclusive
/// (err toward Unmet) — the verify-merge bar is the backstop for false
/// positives.
pub fn check_l1_missions(
    clone_dir: &std::path::Path,
    missions: &[StandardMission],
) -> Vec<MissionCheckResult> {
    missions
        .iter()
        .map(|m| check_one_mission(clone_dir, m.id))
        .collect()
}

fn check_one_mission(clone_dir: &std::path::Path, id: &str) -> MissionCheckResult {
    match id {
        "build-clean-from-checkout" | "deps-resolve" => check_build_manifest(clone_dir),
        "tests-run-in-ci" => check_tests_in_ci_workflow(clone_dir),
        "ci-gates-every-pr" => check_pr_trigger_in_ci(clone_dir),
        "no-secrets-committed" => check_no_secrets_in_tracked_files(clone_dir),
        _ => MissionCheckResult::Met, // unknown id — don't emit a spurious gap
    }
}

/// Check (build-clean-from-checkout, deps-resolve): is a build manifest present?
fn check_build_manifest(clone_dir: &std::path::Path) -> MissionCheckResult {
    let manifests = [
        "Cargo.toml",
        "package.json",
        "pyproject.toml",
        "setup.py",
        "go.mod",
        "Makefile",
        "pom.xml",
        "build.gradle",
    ];
    for m in &manifests {
        if clone_dir.join(m).exists() {
            return MissionCheckResult::Met;
        }
    }
    MissionCheckResult::Unmet {
        why: "no recognisable build manifest found".to_string(),
        evidence_path: "(repo root)".to_string(),
        excerpt: "Cargo.toml / package.json / pyproject.toml / go.mod / Makefile absent"
            .to_string(),
    }
}

/// Check (tests-run-in-ci): does any CI workflow run a test command?
fn check_tests_in_ci_workflow(clone_dir: &std::path::Path) -> MissionCheckResult {
    let workflows_dir = clone_dir.join(".github").join("workflows");
    if !workflows_dir.exists() {
        return MissionCheckResult::Unmet {
            why: "no .github/workflows directory — CI is not configured".to_string(),
            evidence_path: ".github/workflows/".to_string(),
            excerpt: "directory absent".to_string(),
        };
    }

    let test_keywords = [
        "cargo test",
        "npm test",
        "yarn test",
        "pytest",
        "go test",
        "make test",
        "npm run test",
        "python -m pytest",
        "bundle exec rspec",
        "mvn test",
        "gradle test",
    ];

    let yml_files: Vec<_> = std::fs::read_dir(&workflows_dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| {
                    matches!(
                        p.extension().and_then(|e| e.to_str()),
                        Some("yml") | Some("yaml")
                    )
                })
                .collect()
        })
        .unwrap_or_default();

    if yml_files.is_empty() {
        return MissionCheckResult::Unmet {
            why: "no YAML workflow files in .github/workflows/".to_string(),
            evidence_path: ".github/workflows/".to_string(),
            excerpt: "directory empty".to_string(),
        };
    }

    for path in &yml_files {
        if let Ok(content) = std::fs::read_to_string(path) {
            if test_keywords.iter().any(|kw| content.contains(kw)) {
                return MissionCheckResult::Met;
            }
        }
    }

    MissionCheckResult::Unmet {
        why: "CI workflow files found but none run a test command".to_string(),
        evidence_path: ".github/workflows/".to_string(),
        excerpt: format!(
            "{} workflow file(s) present, none contain: {}",
            yml_files.len(),
            test_keywords[..3].join(", ")
        ),
    }
}

/// Check (ci-gates-every-pr): does any CI workflow trigger on pull_request?
fn check_pr_trigger_in_ci(clone_dir: &std::path::Path) -> MissionCheckResult {
    let workflows_dir = clone_dir.join(".github").join("workflows");
    if !workflows_dir.exists() {
        return MissionCheckResult::Unmet {
            why: "no .github/workflows — CI cannot gate PRs".to_string(),
            evidence_path: ".github/workflows/".to_string(),
            excerpt: "directory absent".to_string(),
        };
    }

    let yml_files: Vec<_> = std::fs::read_dir(&workflows_dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| {
                    matches!(
                        p.extension().and_then(|e| e.to_str()),
                        Some("yml") | Some("yaml")
                    )
                })
                .collect()
        })
        .unwrap_or_default();

    for path in &yml_files {
        if let Ok(content) = std::fs::read_to_string(path) {
            if content.contains("pull_request") {
                return MissionCheckResult::Met;
            }
        }
    }

    if yml_files.is_empty() {
        return MissionCheckResult::Unmet {
            why: "no CI workflow files found".to_string(),
            evidence_path: ".github/workflows/".to_string(),
            excerpt: "directory empty".to_string(),
        };
    }

    MissionCheckResult::Unmet {
        why: "no workflow has a pull_request trigger — PRs are not gated by CI".to_string(),
        evidence_path: ".github/workflows/".to_string(),
        excerpt: "no `pull_request:` trigger in any workflow".to_string(),
    }
}

/// Check (no-secrets-committed): scan tracked files for common secret patterns.
fn check_no_secrets_in_tracked_files(clone_dir: &std::path::Path) -> MissionCheckResult {
    use std::process::Command;

    let out = Command::new("git")
        .args(["-C", &clone_dir.to_string_lossy(), "ls-files"])
        .output();

    let files: Vec<String> = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .map(|l| l.to_string())
            .filter(|f| {
                let ext = std::path::Path::new(f)
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("");
                !matches!(
                    ext,
                    "png"
                        | "jpg"
                        | "jpeg"
                        | "gif"
                        | "svg"
                        | "ico"
                        | "woff"
                        | "woff2"
                        | "ttf"
                        | "eot"
                        | "pdf"
                        | "zip"
                        | "gz"
                        | "tar"
                        | "exe"
                        | "bin"
                )
            })
            .take(200)
            .collect(),
        _ => return MissionCheckResult::Met, // git not available — skip
    };

    let patterns: &[(&str, &str)] = &[
        ("AKIA", "AWS access key ID (AKIA…)"),
        ("ghp_", "GitHub PAT (ghp_…)"),
        ("ghs_", "GitHub server token (ghs_…)"),
        ("glpat-", "GitLab PAT (glpat-…)"),
        ("sk-ant-", "Anthropic API key (sk-ant-…)"),
    ];

    for rel in &files {
        let content = match std::fs::read_to_string(clone_dir.join(rel)) {
            Ok(c) if c.len() <= 200_000 => c,
            _ => continue,
        };
        for (pattern, label) in patterns {
            if content.contains(pattern) {
                return MissionCheckResult::Unmet {
                    why: format!("possible secret pattern committed: {label}"),
                    evidence_path: rel.clone(),
                    excerpt: format!("contains `{pattern}`"),
                };
            }
        }
    }

    MissionCheckResult::Met
}

// ── Unit tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_l1_missions_have_correct_layer() {
        for m in l1_missions() {
            assert_eq!(
                m.layer, "L1",
                "mission '{}' must be tagged L1, got '{}'",
                m.id, m.layer
            );
        }
    }

    #[test]
    fn no_empty_fields() {
        for m in l1_missions() {
            assert!(!m.id.is_empty(), "mission id must not be empty");
            assert!(
                !m.title.is_empty(),
                "mission '{}' title must not be empty",
                m.id
            );
            assert!(
                !m.done_criterion.is_empty(),
                "mission '{}' done_criterion must not be empty",
                m.id
            );
        }
        let readme = readme_claim_mission();
        assert!(!readme.id.is_empty());
        assert!(!readme.done_criterion.is_empty());
    }

    #[test]
    fn five_l1_missions_defined() {
        assert_eq!(
            l1_missions().len(),
            5,
            "expected exactly 5 L1 standard missions"
        );
    }

    #[test]
    fn readme_claim_is_l2() {
        assert_eq!(readme_claim_mission().layer, "L2");
    }

    #[test]
    fn ids_are_unique() {
        let ids: Vec<&str> = l1_missions().iter().map(|m| m.id).collect();
        let mut seen = std::collections::HashSet::new();
        for id in &ids {
            assert!(seen.insert(id), "duplicate mission id: {id}");
        }
    }

    #[test]
    fn titles_start_with_pillar_prefix() {
        let valid_prefixes = ["INFRA:", "EFFECTIVE:", "CREDIBLE:", "RESILIENT:", "DOC:"];
        for m in l1_missions() {
            let has_prefix = valid_prefixes.iter().any(|p| m.title.starts_with(p));
            assert!(
                has_prefix,
                "mission '{}' title must start with a pillar prefix (INFRA:, EFFECTIVE:, etc.); \
                 got: '{}'",
                m.id, m.title
            );
        }
    }
}
