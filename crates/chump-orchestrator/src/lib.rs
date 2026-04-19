//! chump-orchestrator — AUTO-013 MVP step 1.
//!
//! See `docs/AUTO-013-ORCHESTRATOR-DESIGN.md` for the full design. This crate
//! is intentionally tiny: a YAML loader and a single `pickable_gaps` filter
//! function. Subprocess spawn, monitor loop, and reflection writes land in
//! follow-up PRs (AUTO-013-A..D in the design doc).
//!
//! The dry-run binary is the demo surface for now — it reads `docs/gaps.yaml`
//! and prints `WOULD DISPATCH:` lines for each gap that the picker selects.

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
}
