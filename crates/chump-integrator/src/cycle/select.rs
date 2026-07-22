//! # cycle::select — INFRA-2171 / C2a
//!
//! Candidate selection from the NATS work-board (with state.db fallback).
//!
//! ## Selection algorithm
//!
//! 1. Read all entries from the NATS work-board with `status=ready_to_ship`
//!    AND `mode=batched`. Falls back to querying `state.db` directly if NATS
//!    is unavailable.
//! 2. Skip gaps tagged `external_repo:` (Mode D — handled by target curator).
//! 3. Sort: priority ascending (P0 first), then `queue_age_s` descending
//!    (oldest first) as tiebreaker.
//! 4. Cap to `max_batch` candidates.
//! 5. Cap by `loc_budget`: accumulate estimated LOC; drop candidates once
//!    budget would be exceeded.
//! 6. Return the final `Vec<GapCandidate>`.
//!
//! ## Cross-references
//!
//! - INFRA-2171 — this gap's AC
//! - INFRA-2130 — parent C2 (lifecycle skeleton)
//! - INFRA-2113 — picker filter that strips external_repo: tag

use chrono::Utc;

use super::GapCandidate;

/// An abstraction over the gap source so unit tests can inject synthetic data
/// without a real NATS connection or state.db.
pub trait WorkBoard {
    /// Return all gaps currently eligible for integration.
    /// Implementations must filter for `status=ready_to_ship` and
    /// `mode=batched` before returning.
    fn eligible_gaps(&self) -> Vec<WorkBoardEntry>;
}

/// One entry from the work-board (either NATS KV or state.db).
#[derive(Debug, Clone)]
pub struct WorkBoardEntry {
    pub gap_id: String,
    pub title: String,
    /// "P0" | "P1" | "P2" | "P3"
    pub priority: String,
    /// RFC3339 timestamp when the gap became ready_to_ship.
    pub ready_at: String,
    /// Estimated LOC (from gap notes heuristic; 0 if unknown).
    pub estimated_loc: usize,
    /// Branch name for this gap.
    pub branch: String,
    /// Comma-separated tags from gap notes (e.g. "external_repo:acme/foo").
    pub tags: String,
    /// Git author of the originating branch (for Co-Authored-By).
    pub author: Option<String>,
}

impl WorkBoardEntry {
    /// True if this gap should be skipped (Mode D — external repo).
    pub fn is_external_repo(&self) -> bool {
        self.tags
            .split(',')
            .any(|t| t.trim().starts_with("external_repo:"))
    }

    /// Compute age in seconds relative to now.
    pub fn queue_age_s(&self) -> u64 {
        let now = Utc::now().timestamp() as u64;
        chrono::DateTime::parse_from_rfc3339(&self.ready_at)
            .map(|dt| now.saturating_sub(dt.timestamp() as u64))
            .unwrap_or(0)
    }
}

/// Select candidates from the work-board, applying all filters and caps.
///
/// # Arguments
/// - `workboard` — source of eligible gap entries
/// - `max_batch` — hard cap on number of candidates returned
/// - `loc_budget` — max total estimated LOC across the batch
///
/// # Returns
/// Sorted, capped `Vec<GapCandidate>` ready for the MERGE step.
pub fn select_candidates(
    workboard: &dyn WorkBoard,
    max_batch: usize,
    loc_budget: usize,
) -> Vec<GapCandidate> {
    let mut entries: Vec<WorkBoardEntry> = workboard
        .eligible_gaps()
        .into_iter()
        .filter(|e| !e.is_external_repo())
        .collect();

    // Sort: P0 first, then oldest queue_age (longest wait) first.
    entries.sort_by(|a, b| {
        let pa = priority_ord(&a.priority);
        let pb = priority_ord(&b.priority);
        pa.cmp(&pb)
            .then_with(|| b.queue_age_s().cmp(&a.queue_age_s()))
    });

    let mut selected = Vec::new();
    let mut accumulated_loc: usize = 0;

    for entry in entries {
        if selected.len() >= max_batch {
            break;
        }
        let loc = entry.estimated_loc;
        if accumulated_loc + loc > loc_budget && !selected.is_empty() {
            // Would exceed budget; skip (but keep trying smaller gaps).
            continue;
        }
        accumulated_loc += loc;
        let age_s = entry.queue_age_s();
        selected.push(GapCandidate {
            gap_id: entry.gap_id,
            title: entry.title,
            priority: entry.priority,
            ready_at: entry.ready_at,
            queue_age_s: age_s,
            estimated_loc: loc,
            branch: entry.branch,
            author: entry.author,
            tags: entry.tags,
        });
    }

    selected
}

fn priority_ord(p: &str) -> u8 {
    match p {
        "P0" => 0,
        "P1" => 1,
        "P2" => 2,
        "P3" => 3,
        _ => 4,
    }
}

// ─── state.db fallback ───────────────────────────────────────────────────────

/// A `WorkBoard` implementation backed by `chump-gap-store` (state.db).
///
/// Used when NATS is unavailable. Queries for gaps with `status=ready_to_ship`.
pub struct StateDbWorkBoard {
    pub entries: Vec<WorkBoardEntry>,
}

impl StateDbWorkBoard {
    /// Build from a list of `GapRow`s (caller filters by status).
    pub fn from_gap_rows(rows: Vec<chump_gap_store::GapRow>) -> Self {
        let entries = rows
            .into_iter()
            .map(|row| {
                // CREDIBLE-158: prefer the actual branch recorded by bot-merge
                // Mode A ("branch:<name>" token in notes). The slug guess below
                // matches almost no real branch and dead-lettered the queue.
                let recorded_branch = row
                    .notes
                    .split_whitespace()
                    .find(|w| w.starts_with("branch:") && w.len() > 7)
                    .map(|w| w[7..].to_string());
                let branch = recorded_branch.unwrap_or_else(|| {
                    // Fallback: derive branch name from gap ID slug.
                    let slug = row
                        .title
                        .to_lowercase()
                        .chars()
                        .map(|c| if c.is_alphanumeric() { c } else { '-' })
                        .collect::<String>();
                    let slug = slug.trim_matches('-').to_string();
                    format!(
                        "chump/{}-{}",
                        row.id.to_lowercase(),
                        &slug[..slug.len().min(30)]
                    )
                });

                // Extract LOC estimate from notes if present ("loc:NNN").
                let estimated_loc = row
                    .notes
                    .split_whitespace()
                    .find(|w| w.starts_with("loc:"))
                    .and_then(|w| w[4..].parse().ok())
                    .unwrap_or(200); // default heuristic

                // Extract tags (notes may contain "external_repo:..." etc.)
                let tags = row
                    .notes
                    .split_whitespace()
                    .filter(|w| w.contains(':'))
                    .collect::<Vec<_>>()
                    .join(",");

                WorkBoardEntry {
                    gap_id: row.id,
                    title: row.title,
                    priority: row.priority,
                    ready_at: chrono::DateTime::from_timestamp(row.created_at, 0)
                        .unwrap_or_else(|| Utc::now())
                        .to_rfc3339(),
                    estimated_loc,
                    branch,
                    tags,
                    author: None,
                }
            })
            .collect();
        Self { entries }
    }
}

impl WorkBoard for StateDbWorkBoard {
    fn eligible_gaps(&self) -> Vec<WorkBoardEntry> {
        self.entries.clone()
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(gap_id: &str, priority: &str, age_s: u64, loc: usize, tags: &str) -> WorkBoardEntry {
        let ready_at = chrono::DateTime::from_timestamp(
            (Utc::now().timestamp() as u64).saturating_sub(age_s) as i64,
            0,
        )
        .unwrap()
        .to_rfc3339();
        WorkBoardEntry {
            gap_id: gap_id.to_string(),
            title: format!("Gap {}", gap_id),
            priority: priority.to_string(),
            ready_at,
            estimated_loc: loc,
            branch: format!("chump/{}", gap_id.to_lowercase()),
            tags: tags.to_string(),
            author: None,
        }
    }

    struct MockBoard(Vec<WorkBoardEntry>);
    impl WorkBoard for MockBoard {
        fn eligible_gaps(&self) -> Vec<WorkBoardEntry> {
            self.0.clone()
        }
    }

    #[test]
    fn test_p0_first_sort() {
        let board = MockBoard(vec![
            entry("INFRA-002", "P1", 100, 100, ""),
            entry("INFRA-001", "P0", 50, 100, ""),
            entry("INFRA-003", "P2", 200, 100, ""),
        ]);
        let result = select_candidates(&board, 10, 10_000);
        assert_eq!(result[0].gap_id, "INFRA-001");
        assert_eq!(result[0].priority, "P0");
    }

    #[test]
    fn test_queue_time_tiebreak() {
        // Two P1 gaps — older one (higher age_s) should come first.
        let board = MockBoard(vec![
            entry("INFRA-NEW", "P1", 10, 100, ""),
            entry("INFRA-OLD", "P1", 500, 100, ""),
        ]);
        let result = select_candidates(&board, 10, 10_000);
        assert_eq!(result[0].gap_id, "INFRA-OLD");
    }

    #[test]
    fn test_max_batch_cap() {
        let board = MockBoard(
            (0..20)
                .map(|i| entry(&format!("INFRA-{:03}", i), "P1", 100, 50, ""))
                .collect(),
        );
        let result = select_candidates(&board, 5, 10_000);
        assert_eq!(result.len(), 5);
    }

    #[test]
    fn test_loc_budget_cap() {
        let board = MockBoard(vec![
            entry("INFRA-001", "P1", 100, 600, ""),
            entry("INFRA-002", "P1", 90, 600, ""),
            entry("INFRA-003", "P1", 80, 600, ""),
        ]);
        // Budget 1500: fits INFRA-001 (600) + INFRA-002 (600) = 1200, then
        // INFRA-003 would push to 1800 — skip.
        let result = select_candidates(&board, 10, 1500);
        assert_eq!(result.len(), 2);
        assert!(result.iter().all(|c| c.gap_id != "INFRA-003"));
    }

    #[test]
    fn test_external_repo_skip() {
        let board = MockBoard(vec![
            entry("INFRA-001", "P1", 100, 100, "external_repo:acme/foo"),
            entry("INFRA-002", "P1", 100, 100, ""),
        ]);
        let result = select_candidates(&board, 10, 10_000);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].gap_id, "INFRA-002");
    }

    #[test]
    fn test_empty_queue() {
        let board = MockBoard(vec![]);
        let result = select_candidates(&board, 10, 10_000);
        assert!(result.is_empty());
    }

    #[test]
    fn test_tags_propagate_into_gap_candidate() {
        // Regression: tags string on WorkBoardEntry must reach the resulting
        // GapCandidate so daemon safety rails (has_do_not_batch_label) can read it.
        let board = MockBoard(vec![entry("INFRA-001", "P1", 100, 100, "do-not-batch,foo")]);
        let result = select_candidates(&board, 10, 10_000);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].tags, "do-not-batch,foo");
    }

    #[test]
    fn test_loc_budget_zero_loc_entries_always_fit() {
        // Gaps with estimated_loc=0 should never block on budget.
        let board = MockBoard(vec![
            entry("INFRA-001", "P1", 100, 0, ""),
            entry("INFRA-002", "P1", 90, 0, ""),
            entry("INFRA-003", "P1", 80, 0, ""),
        ]);
        let result = select_candidates(&board, 10, 1);
        // All have loc=0; accumulated stays at 0, never exceeds budget=1.
        assert_eq!(result.len(), 3);
    }
}
