//! chump-orchestrator — AUTO-013 MVP steps 1+2.
//!
//! See `docs/architecture/AUTO-013-ORCHESTRATOR-DESIGN.md` for the full design. Step 1
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
pub mod routing;
pub mod self_test;
pub mod thompson;

pub use routing::{Candidate, RoutingTable};

use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashSet;
use std::path::Path;

/// A minimal view of a gap entry from `docs/gaps.yaml`.
///
/// We only deserialize the fields the picker needs. Extra fields in the YAML
/// (description, source_doc, etc.) are ignored by serde so the schema can
/// evolve without breaking us.
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
    /// Gap kind: "user" (default) or "system". System gaps are perpetual
    /// background tasks; user gaps are one-shot work items. INFRA-930.
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub depends_on: Option<Vec<String>>,
    /// ISO date string set when the gap is shipped (e.g. "2026-05-10").
    /// Used by the domain-bias logic (FLEET-045) to order recent ships.
    #[serde(default)]
    pub closed_date: Option<String>,
    /// INFRA-1259: acceptance criteria. Stored as the YAML-parsed shape (list
    /// of strings or a single string). The picker filters out gaps whose AC
    /// is vague via [`is_vague_acceptance_criteria`].
    #[serde(default)]
    pub acceptance_criteria: Option<serde_yaml::Value>,
}

/// INFRA-1259: mirrors `chump-gap-store::is_vague_acceptance_criteria`. Kept
/// in-crate because `chump-gap-store` deliberately has zero internal deps on
/// other Chump crates (see its Cargo.toml comment).
///
/// A gap is vague iff every AC item is a placeholder (empty, TODO/FIXME/XXX/
/// STUB/?, or shorter than 24 chars).
pub fn is_vague_acceptance_criteria(value: Option<&serde_yaml::Value>) -> bool {
    let v = match value {
        Some(v) => v,
        None => return true,
    };
    let items: Vec<String> = match v {
        serde_yaml::Value::Null => return true,
        serde_yaml::Value::String(s) => {
            // Could be the JSON-stringified array form from state.db dumps.
            let t = s.trim();
            if t.is_empty() {
                return true;
            }
            if let Ok(arr) = serde_json::from_str::<Vec<String>>(t) {
                arr
            } else {
                vec![t.to_string()]
            }
        }
        serde_yaml::Value::Sequence(seq) => seq
            .iter()
            .filter_map(|x| match x {
                serde_yaml::Value::String(s) => Some(s.clone()),
                serde_yaml::Value::Number(n) => Some(n.to_string()),
                serde_yaml::Value::Mapping(m) => {
                    // Some YAML embeds key:value pairs — stringify roughly.
                    Some(format!("{:?}", m))
                }
                _ => None,
            })
            .collect(),
        _ => return true,
    };
    if items.is_empty() {
        return true;
    }
    items.iter().all(|i| is_placeholder_ac_item(i))
}

fn is_placeholder_ac_item(s: &str) -> bool {
    let t = s.trim();
    if t.is_empty() {
        return true;
    }
    let up = t.to_uppercase();
    if up.starts_with("TODO")
        || up.starts_with("FIXME")
        || up.starts_with("XXX")
        || up.starts_with("STUB")
        || up.starts_with("?")
    {
        return true;
    }
    t.chars().count() < 24
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

/// Extract the domain prefix from a gap ID (e.g., `"INFRA"` from `"INFRA-123"`).
/// Falls back to the full ID if there is no `-` separator.
fn gap_domain(id: &str) -> &str {
    id.split_once('-').map(|(prefix, _)| prefix).unwrap_or(id)
}

/// Compute the fraction of the last `window` done gaps whose domain equals
/// `domain`. Done gaps are sorted by `closed_date` descending so the most
/// recently shipped gaps are counted first. When `closed_date` is absent the
/// gap sorts after all dated gaps (YAML insertion order as a tiebreak).
///
/// Returns 0.0 when there are no done gaps in the window (no signal → no bias).
pub fn domain_concentration(all: &[Gap], domain: &str, window: usize) -> f64 {
    let mut done: Vec<&Gap> = all.iter().filter(|g| g.status == "done").collect();
    // Sort by closed_date desc; gaps without a date sort last.
    done.sort_by(|a, b| {
        b.closed_date
            .as_deref()
            .unwrap_or("")
            .cmp(a.closed_date.as_deref().unwrap_or(""))
    });
    let recent: Vec<&Gap> = done.into_iter().take(window).collect();
    if recent.is_empty() {
        return 0.0;
    }
    let count = recent
        .iter()
        .filter(|g| gap_domain(&g.id) == domain)
        .count();
    count as f64 / recent.len() as f64
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
/// * `kind_filter` — filter by gap kind: `"user"` (default), `"system"`, or `"any"`.
///
/// # Selection rules (in order)
///
/// 1. `status == "open"` or `"perpetual"` — done/closed gaps are ineligible.
/// 2. `kind` matches `kind_filter` — system gaps are perpetual, user gaps are one-shot.
/// 3. `live_claimed` skip — gap already has a live lease in `.chump-locks/`.
/// 4. Dependency check — every ID in `depends_on` must be in `done_ids`.
/// 5. Capacity cap — if `active_count >= capacity`, return `None`.
/// 6. Sort by `priority` ASC (P1 first) then `effort` ASC (small first).
/// 7. Return the first gap after sorting, or `None` if none are eligible.
///
/// INFRA-930: added to fix unresolved import error in main.rs.
pub fn pick_gap_with_kind<'a>(
    all: &'a [Gap],
    done_ids: &HashSet<String>,
    live_claimed: &HashSet<String>,
    active_count: usize,
    capacity: usize,
    kind_filter: &str,
) -> Option<&'a Gap> {
    // Rule 5: capacity gate — bail before any sorting work.
    if active_count >= capacity {
        return None;
    }

    let mut eligible: Vec<&Gap> = all
        .iter()
        // Rule 1: open or perpetual (user gaps are "open"; system gaps are "perpetual")
        .filter(|g| g.status == "open" || g.status == "perpetual")
        // Rule 2: kind filter
        .filter(|g| match kind_filter {
            "user" => g.kind.is_empty() || g.kind == "user",
            "system" => g.kind == "system",
            _ => true, // "any" — no filter
        })
        // Rule 3: not live-claimed
        .filter(|g| !live_claimed.contains(&g.id))
        // Rule 4: all dependencies done
        .filter(|g| {
            g.depends_on
                .iter()
                .flatten()
                .all(|dep| done_ids.contains(dep))
        })
        // INFRA-1259: rule 4.5 — skip vague-AC gaps (would just block the
        // worker on claim-time gate). Logged once per skipped gap per cycle
        // so the picker stays auditable.
        .filter(|g| {
            let vague = is_vague_acceptance_criteria(g.acceptance_criteria.as_ref());
            if vague {
                tracing::info!(
                    gap_id = %g.id,
                    "picker_skipped_vague_ac: gap has placeholder AC; refile with concrete criteria"
                );
            }
            !vague
        })
        .collect();

    // Rule 6: sort by domain bias, then priority ASC, then effort ASC.
    //
    // FLEET-045: when >CHUMP_PICKER_BIAS_THRESHOLD (default 80%) of the last
    // CHUMP_PICKER_BIAS_WINDOW (default 10) shipped gaps belong to the INFRA
    // domain, add a sort penalty to INFRA gaps so the picker naturally reaches
    // for PRODUCT/EFFECTIVE work next. The penalty is 1 (vs 0 for non-INFRA),
    // so INFRA gaps remain pickable when there is nothing else — the bias
    // nudges but does not block.
    let bias_threshold: f64 = std::env::var("CHUMP_PICKER_BIAS_THRESHOLD")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0.80_f64);
    let bias_window: usize = std::env::var("CHUMP_PICKER_BIAS_WINDOW")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(10_usize);
    let infra_ratio = domain_concentration(all, "INFRA", bias_window);
    let bias_active = infra_ratio > bias_threshold;
    if bias_active {
        tracing::info!(
            infra_ratio = infra_ratio,
            bias_threshold = bias_threshold,
            bias_window = bias_window,
            "fleet045: domain-bias active — INFRA concentration {:.0}% > threshold {:.0}%; \
             deprioritizing INFRA gaps this pick",
            infra_ratio * 100.0,
            bias_threshold * 100.0,
        );
    }

    eligible.sort_by_key(|g| {
        let domain_penalty: u8 = if bias_active && gap_domain(&g.id) == "INFRA" {
            1
        } else {
            0
        };
        (
            domain_penalty,
            priority_rank(&g.priority),
            effort_rank(&g.effort),
        )
    });

    // Rule 7: return top candidate
    eligible.into_iter().next()
}

/// Backward-compatible single-gap picker — delegates to [`pick_gap_with_kind`] with
/// `kind_filter = "user"` so existing callers are unaffected.
pub fn pick_gap<'a>(
    all: &'a [Gap],
    done_ids: &HashSet<String>,
    live_claimed: &HashSet<String>,
    active_count: usize,
    capacity: usize,
) -> Option<&'a Gap> {
    pick_gap_with_kind(all, done_ids, live_claimed, active_count, capacity, "user")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    fn g(id: &str, prio: &str, effort: &str, status: &str, deps: Option<Vec<&str>>) -> Gap {
        Gap {
            id: id.into(),
            title: format!("title for {id}"),
            priority: prio.into(),
            effort: effort.into(),
            status: status.into(),
            kind: String::new(), // default: user gap
            depends_on: deps.map(|v| v.into_iter().map(String::from).collect()),
            closed_date: None,
            // INFRA-1259: every test fixture gets a substantive AC so the
            // vague-AC filter doesn't drop it. Tests that exercise the
            // vague-AC path build their own Gap explicitly.
            acceptance_criteria: Some(serde_yaml::Value::Sequence(vec![
                serde_yaml::Value::String("the test fixture provides a substantive AC line".into()),
            ])),
        }
    }

    fn g_done(id: &str, closed: &str) -> Gap {
        Gap {
            id: id.into(),
            title: format!("title for {id}"),
            priority: "P1".into(),
            effort: "s".into(),
            status: "done".into(),
            kind: String::new(),
            depends_on: None,
            closed_date: Some(closed.into()),
            acceptance_criteria: None, // done gaps aren't picked anyway
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

    // ── INFRA-1259: vague-AC filter ──────────────────────────────────────
    #[test]
    fn pick_gap_skips_vague_ac() {
        // A has a stub AC ("ac_gate_check") → must be skipped.
        // B has a real AC and lower priority — it should still win.
        let a_vague = Gap {
            id: "A".into(),
            title: "vague".into(),
            priority: "P1".into(),
            effort: "s".into(),
            status: "open".into(),
            kind: String::new(),
            depends_on: None,
            closed_date: None,
            acceptance_criteria: Some(serde_yaml::Value::Sequence(vec![
                serde_yaml::Value::String("ac_gate_check".into()),
            ])),
        };
        let b_real = g("B", "P2", "m", "open", None);
        let gaps = vec![a_vague, b_real];
        let result =
            pick_gap(&gaps, &HashSet::new(), &no_live(), 0, 3).expect("B should be picked");
        assert_eq!(
            result.id, "B",
            "A's AC is vague (single stub); picker should skip it"
        );
    }

    #[test]
    fn is_vague_helper_classifies_correctly() {
        assert!(is_vague_acceptance_criteria(None));
        assert!(is_vague_acceptance_criteria(Some(&serde_yaml::Value::Null)));
        assert!(is_vague_acceptance_criteria(Some(
            &serde_yaml::Value::String("".into())
        )));
        assert!(is_vague_acceptance_criteria(Some(
            &serde_yaml::Value::String("ac_gate_check".into())
        )));
        assert!(is_vague_acceptance_criteria(Some(
            &serde_yaml::Value::Sequence(vec![serde_yaml::Value::String("TODO write it".into())])
        )));
        // Substantive (>= 24 chars) → not vague
        assert!(!is_vague_acceptance_criteria(Some(
            &serde_yaml::Value::String(
                "the picker filters vague AC entries from the candidate set".into()
            )
        )));
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
    #[serial(dispatch_capacity)]
    fn dispatch_capacity_default_is_3() {
        std::env::remove_var("CHUMP_DISPATCH_CAPACITY");
        assert_eq!(dispatch_capacity(), 3);
    }

    #[test]
    #[serial(dispatch_capacity)]
    fn dispatch_capacity_respects_env() {
        std::env::set_var("CHUMP_DISPATCH_CAPACITY", "5");
        let cap = dispatch_capacity();
        std::env::remove_var("CHUMP_DISPATCH_CAPACITY");
        assert_eq!(cap, 5);
    }

    // ── FLEET-045: domain-bias tests ─────────────────────────────────────

    #[test]
    fn fleet045_gap_domain_extracts_prefix() {
        assert_eq!(gap_domain("INFRA-123"), "INFRA");
        assert_eq!(gap_domain("PRODUCT-074"), "PRODUCT");
        assert_eq!(gap_domain("COG-040"), "COG");
        assert_eq!(gap_domain("FLEET-045"), "FLEET");
        assert_eq!(gap_domain("NO_DASH"), "NO_DASH");
    }

    #[test]
    fn fleet045_domain_concentration_all_infra() {
        let gaps = vec![
            g_done("INFRA-1", "2026-05-10"),
            g_done("INFRA-2", "2026-05-09"),
            g_done("INFRA-3", "2026-05-08"),
            g_done("PRODUCT-1", "2026-05-07"),
        ];
        // Window 3: last 3 done = INFRA-1, INFRA-2, INFRA-3 → 100% INFRA
        let ratio = domain_concentration(&gaps, "INFRA", 3);
        assert!(
            (ratio - 1.0).abs() < f64::EPSILON,
            "all 3 recent = INFRA → ratio 1.0, got {ratio}"
        );
    }

    #[test]
    fn fleet045_domain_concentration_mixed() {
        let gaps = vec![
            g_done("INFRA-1", "2026-05-10"),
            g_done("INFRA-2", "2026-05-09"),
            g_done("PRODUCT-1", "2026-05-08"),
            g_done("INFRA-3", "2026-05-07"),
            g_done("PRODUCT-2", "2026-05-06"),
        ];
        // Window 5: 3 INFRA out of 5 = 0.6
        let ratio = domain_concentration(&gaps, "INFRA", 5);
        assert!((ratio - 0.6).abs() < 1e-9, "3/5 = 0.6, got {ratio}");
    }

    #[test]
    fn fleet045_domain_concentration_no_done_gaps() {
        let gaps = vec![
            g("INFRA-1", "P1", "s", "open", None),
            g("PRODUCT-1", "P1", "s", "open", None),
        ];
        let ratio = domain_concentration(&gaps, "INFRA", 10);
        assert_eq!(ratio, 0.0, "no done gaps → ratio 0.0 (no bias)");
    }

    #[test]
    #[serial(picker_bias)]
    fn fleet045_bias_demotes_infra_when_threshold_exceeded() {
        // 9 recent INFRA ships → 90% > default 80% threshold.
        // With bias active, PRODUCT-1 (P2) should beat INFRA-999 (P1).
        std::env::remove_var("CHUMP_PICKER_BIAS_THRESHOLD");
        std::env::remove_var("CHUMP_PICKER_BIAS_WINDOW");
        let mut gaps: Vec<Gap> = (1..=9)
            .map(|i| g_done(&format!("INFRA-{i}"), &format!("2026-05-{i:02}")))
            .collect();
        gaps.push(g("INFRA-999", "P1", "s", "open", None));
        gaps.push(g("PRODUCT-1", "P2", "s", "open", None));
        let done = done_ids(&gaps);
        let result = pick_gap(&gaps, &done, &no_live(), 0, 3).expect("should pick");
        assert_eq!(
            result.id, "PRODUCT-1",
            "bias should demote INFRA-999 (P1) below PRODUCT-1 (P2) when INFRA > 80%"
        );
        std::env::remove_var("CHUMP_PICKER_BIAS_THRESHOLD");
        std::env::remove_var("CHUMP_PICKER_BIAS_WINDOW");
    }

    #[test]
    #[serial(picker_bias)]
    fn fleet045_bias_inactive_when_below_threshold() {
        // Only 5 of 10 recent ships are INFRA (50%) — below 80% threshold.
        // Normal priority ordering should apply: INFRA-999 (P1) beats PRODUCT-1 (P2).
        std::env::remove_var("CHUMP_PICKER_BIAS_THRESHOLD");
        std::env::remove_var("CHUMP_PICKER_BIAS_WINDOW");
        let mut gaps: Vec<Gap> = (1..=5)
            .map(|i| g_done(&format!("INFRA-{i}"), &format!("2026-05-{i:02}")))
            .collect();
        for i in 6..=10 {
            gaps.push(g_done(&format!("PRODUCT-{i}"), &format!("2026-05-{i:02}")));
        }
        gaps.push(g("INFRA-999", "P1", "s", "open", None));
        gaps.push(g("PRODUCT-99", "P2", "s", "open", None));
        let done = done_ids(&gaps);
        let result = pick_gap(&gaps, &done, &no_live(), 0, 3).expect("should pick");
        assert_eq!(
            result.id, "INFRA-999",
            "bias should not fire at 50% INFRA — P1 beats P2 normally"
        );
        std::env::remove_var("CHUMP_PICKER_BIAS_THRESHOLD");
        std::env::remove_var("CHUMP_PICKER_BIAS_WINDOW");
    }

    #[test]
    #[serial(picker_bias)]
    fn fleet045_bias_infra_only_queue_still_picks() {
        // Even with bias active, if only INFRA gaps are open, we still pick one.
        std::env::remove_var("CHUMP_PICKER_BIAS_THRESHOLD");
        std::env::remove_var("CHUMP_PICKER_BIAS_WINDOW");
        let mut gaps: Vec<Gap> = (1..=9)
            .map(|i| g_done(&format!("INFRA-{i}"), &format!("2026-05-{i:02}")))
            .collect();
        gaps.push(g("INFRA-999", "P1", "s", "open", None));
        let done = done_ids(&gaps);
        let result =
            pick_gap(&gaps, &done, &no_live(), 0, 3).expect("bias must not block all gaps");
        assert_eq!(
            result.id, "INFRA-999",
            "INFRA-only queue still picks under bias"
        );
        std::env::remove_var("CHUMP_PICKER_BIAS_THRESHOLD");
        std::env::remove_var("CHUMP_PICKER_BIAS_WINDOW");
    }

    #[test]
    #[serial(picker_bias)]
    fn fleet045_custom_threshold_env() {
        // Set threshold to 0.5 — 6/10 INFRA should trigger bias.
        std::env::set_var("CHUMP_PICKER_BIAS_THRESHOLD", "0.5");
        std::env::set_var("CHUMP_PICKER_BIAS_WINDOW", "10");
        let mut gaps: Vec<Gap> = (1..=6)
            .map(|i| g_done(&format!("INFRA-{i}"), &format!("2026-05-{i:02}")))
            .collect();
        for i in 7..=10 {
            gaps.push(g_done(&format!("COG-{i}"), &format!("2026-05-{i:02}")));
        }
        gaps.push(g("INFRA-999", "P1", "s", "open", None));
        gaps.push(g("COG-99", "P2", "s", "open", None));
        let done = done_ids(&gaps);
        let result = pick_gap(&gaps, &done, &no_live(), 0, 3).expect("should pick");
        assert_eq!(
            result.id, "COG-99",
            "threshold=0.5 + 60% INFRA should bias away from INFRA-999"
        );
        std::env::remove_var("CHUMP_PICKER_BIAS_THRESHOLD");
        std::env::remove_var("CHUMP_PICKER_BIAS_WINDOW");
    }
}
