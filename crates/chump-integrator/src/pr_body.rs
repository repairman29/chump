//! # pr_body — INFRA-2135 / C7
//!
//! Generates the integration PR body and title from a cycle manifest.
//!
//! ## PR title format
//!
//! ```text
//! integration-{date} ({N} gaps): {comma-sep short titles, max 150 chars truncated}
//! ```
//!
//! ## PR body format
//!
//! Rendered from `scripts/dev/integration-pr-template.md` with `{placeholder}`
//! substitutions. Falls back to an inline template if the file is missing (e.g.
//! in CI without the full repo checkout).
//!
//! ## Cross-references
//!
//! - INFRA-2135 — this gap's AC (C7)
//! - INFRA-2130 — daemon lifecycle (calls `generate_pr_body` at step 6a)
//! - INFRA-2136 — C8 SHIP step that will `gh pr create` with this body

use crate::cycle::merge_branch::{IntegrationBranchOutcome, MergedGap};
use crate::cycle::GapCandidate;
use std::path::Path;

/// Summary for a single merged gap used in the PR body table.
#[derive(Debug, Clone)]
pub struct MergedGapRow {
    pub gap_id: String,
    pub title: String,
    pub merge_sha: String,
    pub author: String,
    pub estimated_loc: usize,
    pub class: String,
}

/// A quarantined gap (conflict aborted before merge).
#[derive(Debug, Clone)]
pub struct QuarantinedGapRow {
    pub gap_id: String,
    pub reason: String,
}

/// Input data needed to render the PR body.
#[derive(Debug, Clone)]
pub struct IntegrationPrInput {
    /// e.g. "integration-2026-05-29-1430"
    pub cycle_name: String,
    /// Why the cycle was triggered (e.g. "volume_threshold reached")
    pub trigger_reason: String,
    /// ISO-8601 timestamp when the cycle started.
    pub started_at: String,
    /// Duration string for preflight (e.g. "42s")
    pub preflight_duration: String,
    /// Successfully merged gaps.
    pub merged_rows: Vec<MergedGapRow>,
    /// Quarantined gaps (conflict or preflight failure).
    pub quarantined_rows: Vec<QuarantinedGapRow>,
}

impl IntegrationPrInput {
    /// Build from a cycle manifest + merge outcome.
    pub fn from_cycle(
        cycle_name: &str,
        trigger_reason: &str,
        started_at: &str,
        preflight_duration: &str,
        candidates: &[GapCandidate],
        outcome: &IntegrationBranchOutcome,
    ) -> Self {
        let merged_rows = outcome
            .merged_gaps
            .iter()
            .map(|mg: &MergedGap| {
                let candidate = candidates
                    .iter()
                    .find(|c| c.gap_id == mg.gap_id)
                    .cloned()
                    .unwrap_or_else(|| GapCandidate {
                        gap_id: mg.gap_id.clone(),
                        title: mg.gap_id.clone(),
                        priority: "?".to_string(),
                        ready_at: String::new(),
                        queue_age_s: 0,
                        estimated_loc: 0,
                        branch: String::new(),
                        author: None,
                        tags: String::new(),
                    });
                MergedGapRow {
                    gap_id: mg.gap_id.clone(),
                    title: candidate.title.clone(),
                    merge_sha: mg.merge_sha[..8.min(mg.merge_sha.len())].to_string(),
                    author: candidate
                        .author
                        .clone()
                        .unwrap_or_else(|| "unknown".to_string()),
                    estimated_loc: candidate.estimated_loc,
                    class: class_from_gap_id(&mg.gap_id),
                }
            })
            .collect();

        let quarantined_rows = outcome
            .conflicts
            .iter()
            .map(|c| QuarantinedGapRow {
                gap_id: c.gap_id.clone(),
                reason: format!(
                    "merge conflict in: {}",
                    if c.conflicted_files.is_empty() {
                        "(unknown files)".to_string()
                    } else {
                        c.conflicted_files.join(", ")
                    }
                ),
            })
            .collect();

        IntegrationPrInput {
            cycle_name: cycle_name.to_string(),
            trigger_reason: trigger_reason.to_string(),
            started_at: started_at.to_string(),
            preflight_duration: preflight_duration.to_string(),
            merged_rows,
            quarantined_rows,
        }
    }
}

/// Generate the PR title string.
///
/// Format: `integration-{date} ({N} gaps): {comma-sep short titles, max 150 chars truncated}`
pub fn generate_pr_title(input: &IntegrationPrInput) -> String {
    let n = input.merged_rows.len();
    let prefix = format!(
        "{} ({} gap{}): ",
        input.cycle_name,
        n,
        if n == 1 { "" } else { "s" }
    );

    // Build comma-sep titles, then truncate to 150 chars total for the titles portion.
    let titles: Vec<&str> = input.merged_rows.iter().map(|r| r.title.as_str()).collect();
    let joined = titles.join(", ");

    // Max 150 chars for the titles portion.
    const TITLE_MAX: usize = 150;
    let titles_portion = if joined.len() > TITLE_MAX {
        let truncated = &joined[..TITLE_MAX];
        // Walk back to last full character boundary.
        let end = truncated
            .rfind(", ")
            .unwrap_or(TITLE_MAX.min(truncated.len()));
        format!("{}…", &joined[..end])
    } else {
        joined
    };

    format!("{}{}", prefix, titles_portion)
}

/// Generate the PR body markdown string from the template.
///
/// Reads `scripts/dev/integration-pr-template.md` from `repo_root` and
/// substitutes all `{placeholder}` tokens. Falls back to the inline template
/// if the file is missing.
pub fn generate_pr_body(input: &IntegrationPrInput, repo_root: &Path) -> String {
    let template = load_template(repo_root);
    render_template(&template, input)
}

// ── template loading ──────────────────────────────────────────────────────────

fn load_template(repo_root: &Path) -> String {
    let template_path = repo_root.join("scripts/dev/integration-pr-template.md");
    std::fs::read_to_string(&template_path).unwrap_or_else(|_| INLINE_TEMPLATE.to_string())
}

/// Inline fallback template (mirrors `scripts/dev/integration-pr-template.md`).
const INLINE_TEMPLATE: &str = r#"## Integration cycle: {cycle_name}

**Triggered by:** {trigger_reason}
**Started:** {started_at}
**Preflight:** green in {preflight_duration}

### Gaps shipped ({gap_count})

| Gap | Commit | Author | LOC | Class |
|-----|--------|--------|-----|-------|
{gap_rows}

### Quarantined (if any)

| Gap | Reason |
|-----|--------|
{quarantine_rows}

🤖 Integration cycle shipped by chump-integrator-daemon
"#;

// ── rendering ─────────────────────────────────────────────────────────────────

fn render_template(template: &str, input: &IntegrationPrInput) -> String {
    // Build gap rows.
    let gap_rows = if input.merged_rows.is_empty() {
        "| (none) | — | — | — | — |".to_string()
    } else {
        input
            .merged_rows
            .iter()
            .map(|r| {
                format!(
                    "| {} | {} | {} | {} | {} |",
                    r.gap_id, r.merge_sha, r.author, r.estimated_loc, r.class
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    };

    // Build quarantine rows.
    let quarantine_rows = if input.quarantined_rows.is_empty() {
        "| (none) | — |".to_string()
    } else {
        input
            .quarantined_rows
            .iter()
            .map(|r| format!("| {} | {} |", r.gap_id, r.reason))
            .collect::<Vec<_>>()
            .join("\n")
    };

    template
        .replace("{cycle_name}", &input.cycle_name)
        .replace("{trigger_reason}", &input.trigger_reason)
        .replace("{started_at}", &input.started_at)
        .replace("{preflight_duration}", &input.preflight_duration)
        .replace("{gap_count}", &input.merged_rows.len().to_string())
        .replace("{gap_rows}", &gap_rows)
        .replace("{quarantine_rows}", &quarantine_rows)
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Derive a class label from a gap ID prefix (e.g. "INFRA-2135" → "INFRA").
fn class_from_gap_id(gap_id: &str) -> String {
    gap_id.split('-').next().unwrap_or("UNKNOWN").to_string()
}

// ── Tests ──────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cycle::merge_branch::{ConflictRecord, IntegrationBranchOutcome, MergedGap};
    use crate::cycle::GapCandidate;

    fn make_candidate(gap_id: &str, title: &str, author: Option<&str>, loc: usize) -> GapCandidate {
        GapCandidate {
            gap_id: gap_id.to_string(),
            title: title.to_string(),
            priority: "P1".to_string(),
            ready_at: "2026-05-29T14:00:00Z".to_string(),
            queue_age_s: 120,
            estimated_loc: loc,
            branch: format!("chump/{}", gap_id.to_lowercase()),
            author: author.map(str::to_string),
            tags: String::new(),
        }
    }

    fn sample_input() -> IntegrationPrInput {
        let candidates = vec![
            make_candidate(
                "INFRA-2135",
                "Batched-Under trailer",
                Some("Dev <dev@test.com>"),
                80,
            ),
            make_candidate(
                "INFRA-2136",
                "SHIP step live mode",
                Some("Alice <alice@test.com>"),
                120,
            ),
        ];
        let outcome = IntegrationBranchOutcome {
            merged_gaps: vec![
                MergedGap {
                    gap_id: "INFRA-2135".to_string(),
                    parent_sha: "abc12345".to_string(),
                    merge_sha: "def67890".to_string(),
                },
                MergedGap {
                    gap_id: "INFRA-2136".to_string(),
                    parent_sha: "def67890".to_string(),
                    merge_sha: "feed1234".to_string(),
                },
            ],
            conflicts: vec![],
        };
        IntegrationPrInput::from_cycle(
            "integration-2026-05-29-1430",
            "volume_threshold reached",
            "2026-05-29T14:30:00Z",
            "38s",
            &candidates,
            &outcome,
        )
    }

    #[test]
    fn test_pr_title_format() {
        let input = sample_input();
        let title = generate_pr_title(&input);
        assert!(
            title.starts_with("integration-2026-05-29-1430 (2 gaps):"),
            "unexpected title: {title}"
        );
        assert!(
            title.contains("Batched-Under trailer"),
            "missing gap title in: {title}"
        );
    }

    #[test]
    fn test_pr_title_truncated() {
        let mut candidates: Vec<GapCandidate> = (0..20)
            .map(|i| {
                make_candidate(
                    &format!("INFRA-{:04}", i),
                    &format!(
                        "A very long gap title that will force truncation number {}",
                        i
                    ),
                    None,
                    50,
                )
            })
            .collect();

        // keep candidate count sane
        candidates.truncate(15);

        let merged_gaps: Vec<MergedGap> = candidates
            .iter()
            .enumerate()
            .map(|(i, c)| MergedGap {
                gap_id: c.gap_id.clone(),
                parent_sha: format!("sha{i}a"),
                merge_sha: format!("sha{i}b1234"),
            })
            .collect();

        let outcome = IntegrationBranchOutcome {
            merged_gaps,
            conflicts: vec![],
        };

        let input = IntegrationPrInput::from_cycle(
            "integration-2026-05-29-1430",
            "volume_threshold reached",
            "2026-05-29T14:30:00Z",
            "45s",
            &candidates,
            &outcome,
        );

        let title = generate_pr_title(&input);
        // The titles portion after the prefix must be <= 150 chars plus the ellipsis.
        let prefix_len = "integration-2026-05-29-1430 (15 gaps): ".len();
        assert!(
            title.len() <= prefix_len + 150 + 3, // +3 for "…"
            "title too long: {} chars: {title}",
            title.len()
        );
        assert!(
            title.ends_with('…') || title.len() <= prefix_len + 150,
            "should truncate: {title}"
        );
    }

    #[test]
    fn test_pr_body_contains_required_fields() {
        let input = sample_input();
        let body = generate_pr_body(&input, std::path::Path::new("/nonexistent_repo_root"));

        // Required fields per AC.
        assert!(
            body.contains("integration-2026-05-29-1430"),
            "missing cycle_name"
        );
        assert!(
            body.contains("volume_threshold reached"),
            "missing trigger_reason"
        );
        assert!(body.contains("2026-05-29T14:30:00Z"), "missing started_at");
        assert!(body.contains("38s"), "missing preflight_duration");
        assert!(body.contains("INFRA-2135"), "missing gap_id row");
        assert!(body.contains("INFRA-2136"), "missing gap_id row");
        assert!(
            body.contains("chump-integrator-daemon"),
            "missing bot attribution"
        );
        assert!(body.contains("Gaps shipped"), "missing Gaps shipped header");
    }

    #[test]
    fn test_pr_body_quarantine_section() {
        let candidates = vec![make_candidate("INFRA-9001", "conflict gap", None, 40)];
        let outcome = IntegrationBranchOutcome {
            merged_gaps: vec![],
            conflicts: vec![ConflictRecord {
                gap_id: "INFRA-9001".to_string(),
                conflicted_files: vec!["src/lib.rs".to_string()],
            }],
        };
        let input = IntegrationPrInput::from_cycle(
            "integration-2026-05-29-1430",
            "volume_threshold reached",
            "2026-05-29T14:30:00Z",
            "12s",
            &candidates,
            &outcome,
        );
        let body = generate_pr_body(&input, std::path::Path::new("/nonexistent_repo_root"));
        assert!(body.contains("INFRA-9001"), "missing quarantine gap_id");
        assert!(
            body.contains("src/lib.rs"),
            "missing conflicted file in reason"
        );
    }

    #[test]
    fn test_class_from_gap_id() {
        assert_eq!(class_from_gap_id("INFRA-2135"), "INFRA");
        assert_eq!(class_from_gap_id("META-124"), "META");
        assert_eq!(class_from_gap_id("CREDIBLE-001"), "CREDIBLE");
        assert_eq!(class_from_gap_id("plain"), "plain");
    }
}
