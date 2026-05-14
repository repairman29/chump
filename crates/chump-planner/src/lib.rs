//! chump-planner — rank, graph, and recommend the gap backlog.
//!
//! v0.1 scope: parse `docs/gaps/*.yaml`, build a hard-dependency graph from
//! the structured `depends_on` field, score every open gap with a flattened
//! linear formula (intra-tier signals can cross tier boundaries), surface a
//! `status:open + closed_pr` reconciliation gate, and emit an ordered
//! dispatch plan as a human-readable table.
//!
//! Out of scope here (v0.2+): telemetry inputs (pillar_share / waste_rate /
//! roadmap_refs are zeroed in defaults), Mermaid / JSON output, the
//! `--explain` mode, and integration with `gap-claim.sh` / ambient events.

pub mod gap;
pub mod graph;
pub mod output;
pub mod parse;
pub mod plan;
pub mod reconcile;
pub mod score;

pub use gap::{Domain, Effort, Gap, GapId, Priority, Status};
pub use graph::{CycleError, DependencyGraph, Reference, ReferenceSource, Relation};
pub use plan::{build_plan, PlanItem, PlanRequest};
pub use reconcile::{collect_reconcile, ReconcileEntry, ReconcileReport};
pub use score::{score, Scored, Weights};

use anyhow::Result;
use std::path::Path;

/// Load every `*.yaml` file in a gaps directory into a `Vec<Gap>`.
/// Files that fail to parse are surfaced as `tracing::warn!` events and
/// skipped — a single malformed file must never block the whole planner.
pub fn load_gaps_dir(dir: &Path) -> Result<Vec<Gap>> {
    let mut gaps = Vec::new();
    let read_dir =
        std::fs::read_dir(dir).map_err(|e| anyhow::anyhow!("read_dir {}: {e}", dir.display()))?;
    for entry in read_dir {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("yaml") {
            continue;
        }
        match gap::load_file(&path) {
            Ok(g) => gaps.push(g),
            Err(e) => {
                tracing::warn!(path = %path.display(), error = %e, "skipping malformed gap yaml");
            }
        }
    }
    gaps.sort_by(|a, b| a.id.0.cmp(&b.id.0));
    Ok(gaps)
}
