//! Integration cycle sub-modules.
//!
//! Each module corresponds to one lifecycle step:
//!
//! - [`select`]       — INFRA-2171 / C2a: candidate selection from work-board
//! - [`merge_branch`] — INFRA-2172 / C2b: git fetch + merge --no-ff per candidate

pub mod merge_branch;
pub mod select;

use chrono::Utc;
use serde::{Deserialize, Serialize};

/// A single gap candidate selected for integration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GapCandidate {
    /// Gap ID, e.g. "INFRA-2130".
    pub gap_id: String,
    /// Gap title (human-readable summary).
    pub title: String,
    /// Priority string: "P0" | "P1" | "P2" | "P3".
    pub priority: String,
    /// When the gap entered ready_to_ship status (RFC3339).
    pub ready_at: String,
    /// Age in seconds since ready_at (computed at selection time).
    pub queue_age_s: u64,
    /// Estimated LOC for this gap (from gap notes or heuristic).
    pub estimated_loc: usize,
    /// Branch name: "chump/<gap-id>-<slug>" or bare gap-id fallback.
    pub branch: String,
    /// Original author (for Co-Authored-By trailer).
    pub author: Option<String>,
    /// Comma-separated tags from gap notes (e.g. "do-not-batch,external_repo:acme/foo").
    /// Mirrors `WorkBoardEntry.tags`; consumed by daemon safety rails such as
    /// `has_do_not_batch_label`.
    #[serde(default)]
    pub tags: String,
}

impl GapCandidate {
    /// Return a numeric priority value for sorting (lower = higher priority).
    pub fn priority_ord(&self) -> u8 {
        match self.priority.as_str() {
            "P0" => 0,
            "P1" => 1,
            "P2" => 2,
            "P3" => 3,
            _ => 4,
        }
    }
}

/// Metadata attached to a completed integration cycle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CycleManifest {
    /// Unique cycle ID (UUID v4 short form).
    pub cycle_id: String,
    /// UTC timestamp when the cycle was initiated.
    pub started_at: String,
    /// Candidates selected for this cycle.
    pub candidates: Vec<GapCandidate>,
    /// Total estimated LOC across all candidates.
    pub total_loc: usize,
}

impl CycleManifest {
    /// Create a new manifest from a list of candidates.
    pub fn new(cycle_id: String, candidates: Vec<GapCandidate>) -> Self {
        let total_loc = candidates.iter().map(|c| c.estimated_loc).sum();
        Self {
            cycle_id,
            started_at: Utc::now().to_rfc3339(),
            candidates,
            total_loc,
        }
    }

    /// Return a summary line for dry-run logging.
    pub fn dry_run_summary(&self) -> String {
        let ids: Vec<&str> = self.candidates.iter().map(|c| c.gap_id.as_str()).collect();
        format!(
            "WOULD HAVE SHIPPED {} gaps: {}",
            self.candidates.len(),
            ids.join(", ")
        )
    }
}
