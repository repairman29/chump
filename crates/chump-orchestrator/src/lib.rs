//! chump-orchestrator — AUTO-013 MVP steps 1+2.
//!
//! See `docs/AUTO-013-ORCHESTRATOR-DESIGN.md` for the full design. Step 1
//! shipped the gap-picker (`pickable_gaps`) + dry-run binary. Step 2 (this
//! PR) adds [`dispatch`] — subprocess-spawn for dispatched subagents.
//! Monitor loop + reflection writes are steps 3-4.
//!
//! INFRA-DISPATCH-POLICY adds [`pick_gap`] — the policy-aware single-gap
//! selector used by `chump --pick-gap`. Unlike [`pickable_gaps`] (which is
//! stateless), `pick_gap` reads live lease state and the `CHUMP_DISPATCH_CAPACITY`
//! cap, then sorts eligible gaps by priority ASC / effort ASC.

pub mod dispatch;
pub mod monitor;
pub mod reflect;
pub mod self_test;

use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashSet;
use std::path::Path;

/// A minimal view of a gap entry from `docs/gaps.yaml`.
///
/// We only deserialize the fields the picker needs. Extra fields in the YAML
/// (description, source_doc, closed_date, etc.) are ignored by serde so the
/// schema can evolve without breaking us.
#[derive(Debug, Clone, Deserialize)]
pub struct Gap {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub priority: String,
    #[serde(default)]
    pub effort: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub depends_on: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct GapsFile {
    #[serde(default)]
    gaps: Vec<Gap>,
}

/// Parse a gaps.yaml file from disk. Tolerant of unknown fields.
pub fn load_gaps(path: &Path) -> Result<Vec<Gap>> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading gaps file at {}", path.display()))?;
    let parsed: GapsFile = serde_yaml::from_str(&text)
        .with_context(|| format!("parsing YAML at {}", path.display()))?;
    Ok(parsed.gaps)
}

/// Collect IDs of gaps already shipped (status == "done").
pub fn done_ids(all: &[Gap]) -> HashSet<String> {
    all.iter()
        .filter(|g| g.status == "done")
        .map(|g| g.id.clone())
        .collect()
}

/// MVP picker. Filters open gaps to those a robot orchestrator can safely
/// auto-dispatch, in input order, capped at `n`.
///
/// Rules (simplest possible heuristic — design doc Q-and-A doesn't lock this
/// down for the MVP and reflection-driven tuning lands in AUTO-013-A):
///
/// 1. status == "open"
/// 2. priority is "P1" or "P2" (skip P3+ until the loop is trusted)
/// 3. effort != "xl" (XL gaps need human breakdown — see design doc §4)
/// 4. all `depends_on` IDs are in `done_ids`
/// 5. take first N in declared order
///
/// This is deliberately stupid. Reflection-driven priority tuning is AUTO-013-A.
pub fn pickable_gaps<'a>(all: &'a [Gap], n: usize, done_ids: &HashSet<String>) -> Vec<&'a Gap> {
    all.iter()
        .filter(|g| g.status == "open")
        .filter(|g| g.priority == "P1" || g.priority == "P2")
        .filter(|g| g.effort != "xl")
        .filter(|g| g.depends_on.iter().flatten().all(|d| done_ids.contains(d)))
        .take(n)
        .collect()
}

// ── INFRA-DISPATCH-POLICY: policy-aware single-gap picker ────────────────────

/// Numeric rank for a priority string. Lower = higher urgency.
/// Unknown strings sort last (u8::MAX).
fn priority_rank(p: &str) -> u8 {
    match p {
        "P1" => 1,
        "P2" => 2,
        "P3" => 3,
        "P4" => 4,
        _ => u8::MAX,
    }
}

/// Numeric rank for an effort string. Lower = smaller / faster.
/// Unknown strings sort last (u8::MAX).
fn effort_rank(e: &str) -> u8 {
    match e {
        "xs" => 0,
        "s" => 1,
        "m" => 2,
        "l" => 3,
        "xl" => 4,
        _ => u8::MAX,
    }
}

/// Read `CHUMP_DISPATCH_CAPACITY` from env, defaulting to 3.
pub fn dispatch_capacity() -> usize {
    std::env::var("CHUMP_DISPATCH_CAPACITY")
        .ok()
        .and_then(|s| s.trim().parse::<usize>().ok())
        .unwrap_or(3)
}

/// Policy-aware single-gap picker — the heart of `chump --pick-gap`.
///
/// # Arguments
///
/// * `all` — all gaps loaded from `docs/gaps.yaml`
/// * `done_ids` — set of gap IDs whose `status == "done"` (satisfied deps)
/// * `live_claimed` — set of gap IDs currently held by a live lease in
///   `.chump-locks/`. The caller is responsible for scanning the lease
///   files and passing the live `gap_id` values here.
/// * `active_count` — number of currently active (live-leased) dispatches
///   that count against the capacity cap.
/// * `capacity` — maximum concurrent dispatches allowed (`CHUMP_DISPATCH_CAPACITY`).
///
/// # Selection rules (in order)
///
/// 1. `status == "open"` — done/closed gaps are ineligible.
/// 2. `live_claimed` skip — gap already has a live lease in `.chump-locks/`.
/// 3. Dependency check — every ID in `depends_on` must be in `done_ids`.
/// 4. Capacity cap — if `active_count >= capacity`, return `None`.
/// 5. Sort by `priority` ASC (P1 first) then `effort` ASC (small first).
/// 6. Return the first gap after sorting, or `None` if none are eligible.
pub fn pick_gap<'a>(
    all: &'a [Gap],
    done_ids: &HashSet<String>,
    live_claimed: &HashSet<String>,
    active_count: usize,
    capacity: usize,
) -> Option<&'a Gap> {
    // Rule 4: capacity gate — bail before any sorting work.
    if active_count >= capacity {
        return None;
    }

    let mut eligible: Vec<&Gap> = all
        .iter()
        // Rule 1: open only
        .filter(|g| g.status == "open")
        // Rule 2: not live-claimed
        .filter(|g| !live_claimed.contains(&g.id))
        // Rule 3: all dependencies done
        .filter(|g| {
            g.depends_on
                .iter()
                .flatten()
                .all(|dep| done_ids.contains(dep))
        })
        .collect();

    // Rule 5: sort by priority ASC, then effort ASC (prefer small+urgent)
    eligible.sort_by_key(|g| (priority_rank(&g.priority), effort_rank(&g.effort)));

    // Rule 6: return top candidate
    eligible.into_iter().next()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn g(id: &str, prio: &str, effort: &str, status: &str, deps: Option<Vec<&str>>) -> Gap {
        Gap {
            id: id.into(),
            title: format!("title for {id}"),
            priority: prio.into(),
            effort: effort.into(),
            status: status.into(),
            depends_on: deps.map(|v| v.into_iter().map(String::from).collect()),
        }
    }

    #[test]
    fn picks_open_p1_first_n() {
        let gaps = vec![
            g("A", "P1", "m", "open", None),
            g("B", "P1", "m", "open", None),
            g("C", "P1", "m", "open", None),
        ];
        let done = HashSet::new();
        let picked = pickable_gaps(&gaps, 2, &done);
        assert_eq!(picked.len(), 2);
        assert_eq!(picked[0].id, "A");
        assert_eq!(picked[1].id, "B");
    }

    #[test]
    fn skips_done_and_p3_and_xl() {
        let gaps = vec![
            g("DONE", "P1", "m", "done", None),
            g("P3-LO", "P3", "m", "open", None),
            g("XL", "P1", "xl", "open", None),
            g("OK", "P2", "l", "open", None),
        ];
        let done = done_ids(&gaps);
        let picked = pickable_gaps(&gaps, 5, &done);
        assert_eq!(picked.len(), 1);
        assert_eq!(picked[0].id, "OK");
    }

    #[test]
    fn respects_unmet_dependency() {
        let gaps = vec![
            g("BLOCKER", "P1", "m", "open", None),
            g("DEPENDENT", "P1", "m", "open", Some(vec!["BLOCKER"])),
        ];
        let done = done_ids(&gaps);
        let picked = pickable_gaps(&gaps, 5, &done);
        // BLOCKER is open (not done) so DEPENDENT is filtered out; only BLOCKER picks.
        assert_eq!(picked.len(), 1);
        assert_eq!(picked[0].id, "BLOCKER");
    }

    #[test]
    fn met_dependency_unblocks() {
        let gaps = vec![
            g("BLOCKER", "P1", "m", "done", None),
            g("DEPENDENT", "P1", "m", "open", Some(vec!["BLOCKER"])),
        ];
        let done = done_ids(&gaps);
        let picked = pickable_gaps(&gaps, 5, &done);
        assert_eq!(picked.len(), 1);
        assert_eq!(picked[0].id, "DEPENDENT");
    }

    #[test]
    fn n_zero_returns_empty() {
        let gaps = vec![g("A", "P1", "m", "open", None)];
        let picked = pickable_gaps(&gaps, 0, &HashSet::new());
        assert!(picked.is_empty());
    }

    #[test]
    fn empty_input_returns_empty() {
        let picked = pickable_gaps(&[], 5, &HashSet::new());
        assert!(picked.is_empty());
    }

    #[test]
    fn multiple_unmet_deps_all_required() {
        let gaps = vec![
            g("A", "P1", "m", "done", None),
            g("B", "P1", "m", "open", None), // open, not done
            g("C", "P1", "m", "open", Some(vec!["A", "B"])),
        ];
        let done = done_ids(&gaps);
        let picked = pickable_gaps(&gaps, 5, &done);
        // C requires both A and B done; B is still open → C filtered.
        let ids: Vec<&str> = picked.iter().map(|g| g.id.as_str()).collect();
        assert_eq!(ids, vec!["B"]);
    }

    // ── INFRA-DISPATCH-POLICY: pick_gap tests ────────────────────────────

    fn no_live() -> HashSet<String> {
        HashSet::new()
    }

    #[test]
    fn pick_gap_returns_none_when_capacity_full() {
        let gaps = vec![g("A", "P1", "s", "open", None)];
        let done = HashSet::new();
        // active_count == capacity → blocked
        let result = pick_gap(&gaps, &done, &no_live(), 3, 3);
        assert!(
            result.is_none(),
            "capacity=3 active=3 should block dispatch"
        );
    }

    #[test]
    fn pick_gap_returns_none_when_all_live_claimed() {
        let gaps = vec![
            g("A", "P1", "s", "open", None),
            g("B", "P2", "m", "open", None),
        ];
        let done = HashSet::new();
        let live: HashSet<String> = ["A".to_string(), "B".to_string()].into();
        let result = pick_gap(&gaps, &done, &live, 0, 3);
        assert!(result.is_none(), "all gaps live-claimed → none available");
    }

    #[test]
    fn pick_gap_skips_live_claimed_gap() {
        let gaps = vec![
            g("A", "P1", "s", "open", None),
            g("B", "P2", "m", "open", None),
        ];
        let done = HashSet::new();
        let live: HashSet<String> = ["A".to_string()].into();
        let result = pick_gap(&gaps, &done, &live, 0, 3).expect("B should be picked");
        assert_eq!(result.id, "B", "A is live-claimed; B should be selected");
    }

    #[test]
    fn pick_gap_dependency_blocking() {
        // C depends on B which is still open — C must not be picked.
        let gaps = vec![
            g("B", "P1", "m", "open", None),
            g("C", "P1", "s", "open", Some(vec!["B"])),
        ];
        let done: HashSet<String> = HashSet::new(); // B not done
        let result = pick_gap(&gaps, &done, &no_live(), 0, 3).expect("B should be picked");
        assert_eq!(result.id, "B", "C has unmet dep; B should be selected");
    }

    #[test]
    fn pick_gap_dependency_unblocked_when_dep_done() {
        let gaps = vec![
            g("B", "P1", "m", "done", None),
            g("C", "P1", "s", "open", Some(vec!["B"])),
        ];
        let done = done_ids(&gaps); // B is done
        let result = pick_gap(&gaps, &done, &no_live(), 0, 3).expect("C should be picked");
        assert_eq!(result.id, "C", "B is done; C's dep is met");
    }

    #[test]
    fn pick_gap_priority_ordering() {
        // P2 and P1 — P1 should win regardless of insertion order.
        let gaps = vec![
            g("LOW", "P2", "s", "open", None),
            g("HIGH", "P1", "l", "open", None),
        ];
        let done = HashSet::new();
        let result = pick_gap(&gaps, &done, &no_live(), 0, 3).expect("should pick");
        assert_eq!(result.id, "HIGH", "P1 should beat P2");
    }

    #[test]
    fn pick_gap_effort_ordering_within_same_priority() {
        // Two P1 gaps — the smaller effort (s) should win.
        let gaps = vec![
            g("BIG", "P1", "l", "open", None),
            g("SMALL", "P1", "s", "open", None),
        ];
        let done = HashSet::new();
        let result = pick_gap(&gaps, &done, &no_live(), 0, 3).expect("should pick");
        assert_eq!(result.id, "SMALL", "s effort beats l within same priority");
    }

    #[test]
    fn pick_gap_none_when_all_done() {
        let gaps = vec![g("A", "P1", "s", "done", None)];
        let done = done_ids(&gaps);
        let result = pick_gap(&gaps, &done, &no_live(), 0, 3);
        assert!(result.is_none(), "all done → nothing to pick");
    }

    #[test]
    fn pick_gap_capacity_allows_when_below_cap() {
        let gaps = vec![g("A", "P1", "s", "open", None)];
        let done = HashSet::new();
        // active_count=2, capacity=3 — still one slot free
        let result = pick_gap(&gaps, &done, &no_live(), 2, 3);
        assert!(
            result.is_some(),
            "active=2 < capacity=3 should allow dispatch"
        );
        assert_eq!(result.unwrap().id, "A");
    }

    #[test]
    fn dispatch_capacity_default_is_3() {
        std::env::remove_var("CHUMP_DISPATCH_CAPACITY");
        assert_eq!(dispatch_capacity(), 3);
    }

    #[test]
    fn dispatch_capacity_respects_env() {
        std::env::set_var("CHUMP_DISPATCH_CAPACITY", "5");
        let cap = dispatch_capacity();
        std::env::remove_var("CHUMP_DISPATCH_CAPACITY");
        assert_eq!(cap, 5);
    }
}
