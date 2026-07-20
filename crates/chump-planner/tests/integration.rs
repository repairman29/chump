//! Integration + force-fire tests for chump-planner v0.1.
//!
//! Three layers:
//!   1. End-to-end on the live `docs/gaps/` directory — assert "things parse
//!      and a plan comes back", not specific orderings (corpus shifts daily).
//!   2. Force-fire fixtures: forged cycle, reconciliation backlog, pillar
//!      cap at 51%. These are the gate-manifest pattern from CREDIBLE-050 —
//!      the planner must surface each signal exactly as specified.
//!   3. Snapshot-ish ordering tests against handcrafted fixture sets so
//!      regressions in the scoring formula are obvious.

use chump_planner::{
    build_plan, collect_reconcile, load_gaps_dir, score::TelemetryInputs, DependencyGraph,
    PlanRequest, Weights,
};
use std::collections::HashMap;
use std::path::PathBuf;
use tempfile::TempDir;

fn write_gap(dir: &std::path::Path, id: &str, yaml: &str) {
    let path = dir.join(format!("{id}.yaml"));
    std::fs::write(&path, yaml).unwrap();
}

fn today() -> chrono::NaiveDate {
    chrono::NaiveDate::from_ymd_opt(2026, 5, 13).unwrap()
}

#[test]
fn live_gaps_dir_loads_without_panic() {
    // Locate the live docs/gaps relative to CARGO_MANIFEST_DIR (works in
    // both `cargo test` and CI without hard-coding paths).
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let gaps_dir = manifest
        .parent()
        .and_then(|p| p.parent())
        .map(|p| p.join("docs/gaps"))
        .expect("workspace root");
    if !gaps_dir.exists() {
        eprintln!("skipping live-dir test: {} missing", gaps_dir.display());
        return;
    }
    // ZERO-WASTE-020: the per-gap YAML mirrors are retired — the live dir now
    // holds only the tombstone README. The load-without-panic contract still
    // matters (empty/README-only dir must not error); the >50 corpus
    // assertion moved to the fixture-based tests.
    let gaps = load_gaps_dir(&gaps_dir).expect("live gaps directory must parse");
    if gaps.is_empty() {
        eprintln!(
            "live gaps dir is mirror-free (post-ZERO-WASTE-020): load OK, graph checks skipped"
        );
        return;
    }

    let graph = DependencyGraph::build(&gaps);
    // Reconcile collection must not panic on the live corpus.
    let _ = collect_reconcile(&gaps);
    // Topo may return a cycle error — but it must never panic.
    let _ = graph.topo_order();

    let plan = build_plan(
        &gaps,
        &graph,
        &PlanRequest::default(),
        &TelemetryInputs::default(),
        today(),
        &Weights::default(),
    );
    assert!(!plan.is_empty(), "live corpus produced empty plan");
}

#[test]
fn force_fire_forged_cycle_surfaces_member_set() {
    let tmp = TempDir::new().unwrap();
    write_gap(
        tmp.path(),
        "INFRA-A",
        "- id: INFRA-A\n  domain: INFRA\n  title: a\n  status: open\n  priority: P1\n  effort: s\n  depends_on: [INFRA-C]\n",
    );
    write_gap(
        tmp.path(),
        "INFRA-B",
        "- id: INFRA-B\n  domain: INFRA\n  title: b\n  status: open\n  priority: P1\n  effort: s\n  depends_on: [INFRA-A]\n",
    );
    write_gap(
        tmp.path(),
        "INFRA-C",
        "- id: INFRA-C\n  domain: INFRA\n  title: c\n  status: open\n  priority: P1\n  effort: s\n  depends_on: [INFRA-B]\n",
    );
    let gaps = load_gaps_dir(tmp.path()).unwrap();
    let graph = DependencyGraph::build(&gaps);
    let err = graph.topo_order().unwrap_err();
    let mut members: Vec<String> = err.gaps.iter().map(|g| g.0.clone()).collect();
    members.sort();
    assert_eq!(members, vec!["INFRA-A", "INFRA-B", "INFRA-C"]);
    // Identity is stable + 64-char hex (SHA-256).
    let ident = err.identity();
    assert_eq!(ident.len(), 64);
    assert!(ident.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn force_fire_reconciliation_gate_breaches_above_threshold() {
    let tmp = TempDir::new().unwrap();
    for i in 0..12 {
        let id = format!("INFRA-R{i:02}");
        let yaml = format!(
            "- id: {id}\n  domain: INFRA\n  title: stale closure\n  status: open\n  priority: P2\n  effort: s\n  closed_pr: {pr}\n",
            id = id,
            pr = 5000 + i
        );
        write_gap(tmp.path(), &id, &yaml);
    }
    let gaps = load_gaps_dir(tmp.path()).unwrap();
    let r = collect_reconcile(&gaps);
    assert_eq!(r.count(), 12);
    assert!(r.breaches(10));
    assert!(!r.breaches(20));

    // Reconcile entries must NOT appear in the plan output.
    let graph = DependencyGraph::build(&gaps);
    let plan = build_plan(
        &gaps,
        &graph,
        &PlanRequest::default(),
        &TelemetryInputs::default(),
        today(),
        &Weights::default(),
    );
    assert!(
        plan.is_empty(),
        "reconcile-pending gaps must not enter the plan"
    );
}

#[test]
fn force_fire_pillar_cap_penalty_at_51_pct() {
    // Hand-build the score input: one P1 gap in a domain that occupies
    // 51% of the pool. Penalty must appear in the breakdown exactly once.
    use chump_planner::Gap;

    let yaml = r#"
- id: INFRA-T
  domain: INFRA
  title: t
  status: open
  priority: P1
  effort: s
"#;
    let g: Gap = chump_planner::gap::load_str(yaml).unwrap();
    let graph = DependencyGraph::build(std::slice::from_ref(&g));
    let open = [g.id.clone()].into_iter().collect();

    let mut share = HashMap::new();
    share.insert(chump_planner::Domain::Infra, 0.51);
    let telem = TelemetryInputs {
        pillar_share: Some(&share),
        ..Default::default()
    };
    let s = chump_planner::score::score(&g, &graph, &open, &telem, today(), &Weights::default());

    let cap = s
        .breakdown
        .iter()
        .find(|(k, _)| *k == "pillar_cap")
        .expect("pillar_cap not in breakdown");
    assert_eq!(cap.1, -200.0);
}

#[test]
fn force_fire_blocked_gap_excluded_by_default() {
    let tmp = TempDir::new().unwrap();
    write_gap(
        tmp.path(),
        "BLOCKER",
        "- id: BLOCKER\n  domain: INFRA\n  title: blocker\n  status: open\n  priority: P0\n  effort: m\n",
    );
    write_gap(
        tmp.path(),
        "BLOCKED",
        "- id: BLOCKED\n  domain: INFRA\n  title: blocked\n  status: open\n  priority: P0\n  effort: s\n  depends_on: [BLOCKER]\n",
    );
    let gaps = load_gaps_dir(tmp.path()).unwrap();
    let graph = DependencyGraph::build(&gaps);
    let plan = build_plan(
        &gaps,
        &graph,
        &PlanRequest::default(),
        &TelemetryInputs::default(),
        today(),
        &Weights::default(),
    );
    let ids: Vec<String> = plan.iter().map(|p| p.gap.id.0.clone()).collect();
    assert!(ids.contains(&"BLOCKER".to_string()));
    assert!(
        !ids.contains(&"BLOCKED".to_string()),
        "blocked gap leaked into plan: {ids:?}"
    );

    // With --include-blocked, both surface.
    let req = PlanRequest {
        include_blocked: true,
        ..Default::default()
    };
    let plan2 = build_plan(
        &gaps,
        &graph,
        &req,
        &TelemetryInputs::default(),
        today(),
        &Weights::default(),
    );
    let ids2: Vec<String> = plan2.iter().map(|p| p.gap.id.0.clone()).collect();
    assert!(ids2.contains(&"BLOCKED".to_string()));
}

#[test]
fn force_fire_unblocking_bonus_lifts_p1_above_isolated_p0_when_chain_is_deep() {
    // P1 sits atop a chain of seven P1 dependents — closing it unblocks
    // them all. A standalone P0 with no dependents and M effort sits below.
    let tmp = TempDir::new().unwrap();
    write_gap(
        tmp.path(),
        "P0-LONE",
        "- id: P0-LONE\n  domain: INFRA\n  title: lone P0\n  status: open\n  priority: P0\n  effort: m\n",
    );
    write_gap(
        tmp.path(),
        "P1-ROOT",
        "- id: P1-ROOT\n  domain: INFRA\n  title: root\n  status: open\n  priority: P1\n  effort: xs\n",
    );
    for i in 0..7 {
        let id = format!("DEP-{i}");
        let yaml = format!(
            "- id: {id}\n  domain: INFRA\n  title: dep\n  status: open\n  priority: P1\n  effort: s\n  depends_on: [P1-ROOT]\n",
            id = id
        );
        write_gap(tmp.path(), &id, &yaml);
    }
    let gaps = load_gaps_dir(tmp.path()).unwrap();
    let graph = DependencyGraph::build(&gaps);
    let plan = build_plan(
        &gaps,
        &graph,
        &PlanRequest {
            respect_pillar_cap: false, // isolate the unblocking signal
            ..Default::default()
        },
        &TelemetryInputs::default(),
        today(),
        &Weights::default(),
    );
    let ids: Vec<String> = plan.iter().map(|p| p.gap.id.0.clone()).collect();
    let root_idx = ids.iter().position(|x| x == "P1-ROOT").unwrap();
    let p0_idx = ids.iter().position(|x| x == "P0-LONE").unwrap();
    assert!(
        root_idx < p0_idx,
        "P1-ROOT (with 7 unblockers) should outrank P0-LONE — got order {ids:?}"
    );
}
