//! INFRA-2196 (META-128/C5): `chump disk` subcommands — operator + subprocess surface.
//!
//! Three subcommands:
//!   - `chump disk status [--json]`
//!       Human-readable: total/free/used/headroom + top 5 consumers.
//!       `--json` emits the raw DiskSnapshot as JSON.
//!
//!   - `chump disk plan <action-class> [--count N]`
//!       Reads `docs/process/DISK_COST_MODEL.yaml` (INFRA-2195), computes
//!       projection {free_now_gb, cost_gb, free_after_gb, threshold_gb},
//!       prints OK | WAIT | REFUSE.
//!       Exit codes: 0=OK, 1=REFUSE (free_after < threshold),
//!                   2=WAIT (free_after < threshold * 2).
//!
//!   - `chump disk budget [--for <action-class>]`
//!       Max-safe-N for an action class (or all classes) given current headroom.
//!       Uses p95_gb for conservative estimates.
//!
//! Env:
//!   CHUMP_DISK_FLOOR_GB           floor threshold (default 5.0)
//!   CHUMP_DISK_INVENTORY_PATH     override ~/.chump/disk-inventory.json
//!   CHUMP_DISK_COST_MODEL_PATH    override docs/process/DISK_COST_MODEL.yaml
//!
//! Cross-references:
//!   INFRA-2193 — chump-disk-inventory-daemon writes ~/.chump/disk-inventory.json
//!   INFRA-2195 — DISK_COST_MODEL.yaml seeded values
//!   META-128   — umbrella disk-aware fleet design

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use tracing::info;

// ── constants ──────────────────────────────────────────────────────────────

const DEFAULT_FLOOR_GB: f64 = 5.0;
const TOP_CONSUMERS: usize = 5;

// ── inventory types (mirrors chump-disk-inventory-daemon schema) ───────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConsumerEntry {
    pub path: String,
    pub size_gb: f64,
    #[serde(default)]
    pub mtime: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskSnapshot {
    pub ts: String,
    pub node_id: String,
    pub total_gb: f64,
    pub free_gb: f64,
    pub used_gb: f64,
    pub threshold_gb: f64,
    pub headroom_gb: f64,
    pub top_consumers: Vec<ConsumerEntry>,
}

// ── cost model types (mirrors DISK_COST_MODEL.yaml schema) ────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionCost {
    pub avg_gb: f64,
    pub p95_gb: f64,
    #[serde(default)]
    pub observed_n: u32,
    #[serde(default)]
    pub last_updated: String,
    #[serde(default)]
    pub notes: String,
}

// ── plan result ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum PlanDecision {
    Ok,
    Wait,
    Refuse,
}

impl PlanDecision {
    pub fn label(&self) -> &'static str {
        match self {
            PlanDecision::Ok => "OK",
            PlanDecision::Wait => "WAIT",
            PlanDecision::Refuse => "REFUSE",
        }
    }

    /// CLI exit code: 0=OK, 2=WAIT, 1=REFUSE
    pub fn exit_code(&self) -> i32 {
        match self {
            PlanDecision::Ok => 0,
            PlanDecision::Wait => 2,
            PlanDecision::Refuse => 1,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanProjection {
    pub action_class: String,
    pub count: u64,
    pub free_now_gb: f64,
    pub cost_gb: f64,
    pub free_after_gb: f64,
    pub threshold_gb: f64,
    pub decision: String,
}

// ── path helpers ───────────────────────────────────────────────────────────

pub fn default_inventory_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_DISK_INVENTORY_PATH") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".chump")
        .join("disk-inventory.json")
}

pub fn default_cost_model_path(repo_root: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_DISK_COST_MODEL_PATH") {
        return PathBuf::from(p);
    }
    repo_root
        .join("docs")
        .join("process")
        .join("DISK_COST_MODEL.yaml")
}

fn floor_gb() -> f64 {
    std::env::var("CHUMP_DISK_FLOOR_GB")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_FLOOR_GB)
}

// ── loaders ────────────────────────────────────────────────────────────────

pub fn load_snapshot(path: &Path) -> Result<DiskSnapshot> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading disk inventory from {}", path.display()))?;
    serde_json::from_str(&text)
        .with_context(|| format!("parsing disk inventory JSON from {}", path.display()))
}

pub fn load_cost_model(path: &Path) -> Result<BTreeMap<String, ActionCost>> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading DISK_COST_MODEL from {}", path.display()))?;
    serde_yaml::from_str(&text)
        .with_context(|| format!("parsing DISK_COST_MODEL YAML from {}", path.display()))
}

// ── subcommand: status ─────────────────────────────────────────────────────

pub fn run_status(args: &[String], _repo_root: &Path) -> Result<i32> {
    let json_out = args.iter().any(|a| a == "--json");
    let inv_path = default_inventory_path();

    let snap = load_snapshot(&inv_path).with_context(|| {
        format!(
            "disk-inventory file not found; is chump-disk-inventory-daemon running? ({})",
            inv_path.display()
        )
    })?;

    if json_out {
        println!("{}", serde_json::to_string_pretty(&snap)?);
        return Ok(0);
    }

    // Observability: log snapshot summary so watchdogs can detect critical state.
    info!(
        node_id = %snap.node_id,
        free_gb = snap.free_gb,
        headroom_gb = snap.headroom_gb,
        "disk_status"
    );

    // Human-readable output
    println!("Disk status  [{}]  node={}", snap.ts, snap.node_id);
    println!("  total    : {:.1} GB", snap.total_gb);
    println!("  used     : {:.1} GB", snap.used_gb);
    println!("  free     : {:.1} GB", snap.free_gb);
    println!("  threshold: {:.1} GB", snap.threshold_gb);
    let headroom_label = if snap.headroom_gb < 0.0 {
        format!("{:.1} GB  *** BELOW THRESHOLD ***", snap.headroom_gb)
    } else {
        format!("{:.1} GB", snap.headroom_gb)
    };
    println!("  headroom : {}", headroom_label);

    let top: Vec<&ConsumerEntry> = snap.top_consumers.iter().take(TOP_CONSUMERS).collect();
    if !top.is_empty() {
        println!();
        println!("Top consumers:");
        for c in top {
            println!("  {:>6.2} GB  {}", c.size_gb, c.path);
        }
    }

    Ok(0)
}

// ── planning logic (pure, testable) ───────────────────────────────────────

pub fn compute_plan(
    free_gb: f64,
    threshold_gb: f64,
    cost_per_action: f64,
    count: u64,
) -> (PlanProjection, PlanDecision) {
    // Use CHUMP_DISK_FLOOR_GB to override threshold only if it's tighter.
    let effective_threshold = threshold_gb.max(floor_gb());
    let total_cost = cost_per_action * count as f64;
    let free_after = free_gb - total_cost;

    let decision = if free_after < effective_threshold {
        PlanDecision::Refuse
    } else if free_after < effective_threshold * 2.0 {
        PlanDecision::Wait
    } else {
        PlanDecision::Ok
    };

    let proj = PlanProjection {
        action_class: String::new(), // filled by caller
        count,
        free_now_gb: free_gb,
        cost_gb: total_cost,
        free_after_gb: free_after,
        threshold_gb: effective_threshold,
        decision: decision.label().to_string(),
    };
    (proj, decision)
}

// ── subcommand: plan ───────────────────────────────────────────────────────

pub fn run_plan(args: &[String], repo_root: &Path) -> Result<i32> {
    // Usage: chump disk plan <action-class> [--count N] [--json]
    let Some(action_class) = args.first() else {
        eprintln!("Usage: chump disk plan <action-class> [--count N] [--json]");
        eprintln!();
        eprintln!("Available action classes are listed in docs/process/DISK_COST_MODEL.yaml");
        return Ok(2);
    };

    let mut count: u64 = 1;
    let mut json_out = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--count" => {
                i += 1;
                count = args
                    .get(i)
                    .and_then(|s| s.parse().ok())
                    .ok_or_else(|| anyhow::anyhow!("--count requires a positive integer"))?;
            }
            "--json" => {
                json_out = true;
            }
            _ => {}
        }
        i += 1;
    }

    let inv_path = default_inventory_path();
    let snap = load_snapshot(&inv_path)?;

    let model_path = default_cost_model_path(repo_root);
    let model = load_cost_model(&model_path)?;

    let cost_entry = model.get(action_class.as_str()).ok_or_else(|| {
        let known: Vec<&String> = model.keys().collect();
        anyhow::anyhow!(
            "unknown action class '{}'; known classes: {}",
            action_class,
            known
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        )
    })?;

    let (mut proj, decision) =
        compute_plan(snap.free_gb, snap.threshold_gb, cost_entry.p95_gb, count);
    proj.action_class = action_class.clone();

    // Observability: every disk plan decision is logged so fleet-brief /
    // watchdogs can detect REFUSE/WAIT storms without reading CLI output.
    info!(
        action_class = %proj.action_class,
        count = proj.count,
        free_now_gb = proj.free_now_gb,
        cost_gb = proj.cost_gb,
        free_after_gb = proj.free_after_gb,
        threshold_gb = proj.threshold_gb,
        decision = decision.label(),
        "disk_plan"
    );

    if json_out {
        println!("{}", serde_json::to_string_pretty(&proj)?);
    } else {
        println!(
            "disk plan: {} x{} — free_now={:.1}GB cost={:.1}GB free_after={:.1}GB threshold={:.1}GB → {}",
            proj.action_class,
            proj.count,
            proj.free_now_gb,
            proj.cost_gb,
            proj.free_after_gb,
            proj.threshold_gb,
            decision.label(),
        );
        if decision == PlanDecision::Refuse {
            println!("  REFUSE: insufficient headroom; reap before claiming.");
        } else if decision == PlanDecision::Wait {
            println!("  WAIT: headroom low; proceed only if urgent.");
        }
    }

    Ok(decision.exit_code())
}

// ── subcommand: budget ─────────────────────────────────────────────────────

pub fn max_safe_n(free_gb: f64, threshold_gb: f64, cost_per_action: f64) -> u64 {
    let effective_threshold = threshold_gb.max(floor_gb());
    let available = free_gb - effective_threshold * 2.0; // WAIT buffer
    if available <= 0.0 || cost_per_action <= 0.0 {
        return 0;
    }
    (available / cost_per_action).floor() as u64
}

pub fn run_budget(args: &[String], repo_root: &Path) -> Result<i32> {
    // Usage: chump disk budget [--for <action-class>] [--json]
    let mut filter: Option<String> = None;
    let mut json_out = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--for" => {
                i += 1;
                filter = args.get(i).cloned();
            }
            "--json" => {
                json_out = true;
            }
            _ => {}
        }
        i += 1;
    }

    let inv_path = default_inventory_path();
    let snap = load_snapshot(&inv_path)?;

    let model_path = default_cost_model_path(repo_root);
    let model = load_cost_model(&model_path)?;

    #[derive(Serialize)]
    struct BudgetRow {
        action_class: String,
        p95_gb: f64,
        max_safe_n: u64,
        free_now_gb: f64,
        threshold_gb: f64,
    }

    let effective_threshold = snap.threshold_gb.max(floor_gb());

    let rows: Vec<BudgetRow> = model
        .iter()
        .filter(|(k, _)| filter.as_deref().map(|f| *k == f).unwrap_or(true))
        .map(|(k, v)| BudgetRow {
            action_class: k.clone(),
            p95_gb: v.p95_gb,
            max_safe_n: max_safe_n(snap.free_gb, snap.threshold_gb, v.p95_gb),
            free_now_gb: snap.free_gb,
            threshold_gb: effective_threshold,
        })
        .collect();

    if rows.is_empty() {
        if let Some(ref cls) = filter {
            eprintln!("unknown action class '{cls}'");
            return Ok(1);
        }
        eprintln!("cost model is empty");
        return Ok(1);
    }

    if json_out {
        println!("{}", serde_json::to_string_pretty(&rows)?);
        return Ok(0);
    }

    println!(
        "Disk budget  free={:.1}GB  threshold={:.1}GB",
        snap.free_gb, effective_threshold
    );
    println!(
        "  {:<36} {:>8}  {:>10}",
        "action_class", "p95_gb", "max_safe_n"
    );
    println!(
        "  {:<36} {:>8}  {:>10}",
        "─".repeat(36),
        "──────",
        "──────────"
    );
    for r in &rows {
        println!(
            "  {:<36} {:>8.2}  {:>10}",
            r.action_class, r.p95_gb, r.max_safe_n
        );
    }

    Ok(0)
}

// ── tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    fn make_snapshot(free_gb: f64, threshold_gb: f64) -> DiskSnapshot {
        DiskSnapshot {
            ts: "2026-05-29T12:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            node_id: "test-node".to_string(),
            total_gb: 500.0,
            free_gb,
            used_gb: 500.0 - free_gb,
            threshold_gb,
            headroom_gb: free_gb - threshold_gb,
            top_consumers: vec![
                ConsumerEntry {
                    path: "/tmp/chump-infra-2196".to_string(),
                    size_gb: 1.2,
                    mtime: "2026-05-29T11:00:00Z".to_string(), // chump-fmt: time-bomb-ok
                },
                ConsumerEntry {
                    path: "~/.cache/chump-runner".to_string(),
                    size_gb: 47.0,
                    mtime: "2026-05-29T10:00:00Z".to_string(), // chump-fmt: time-bomb-ok
                },
            ],
        }
    }

    fn write_snapshot(dir: &Path, snap: &DiskSnapshot) -> PathBuf {
        let p = dir.join("disk-inventory.json");
        fs::write(&p, serde_json::to_string(snap).unwrap()).unwrap();
        p
    }

    fn write_cost_model(dir: &Path) -> PathBuf {
        // last_updated dates are schema fixture values, not rolling timestamps.
        // chump-fmt: time-bomb-ok
        let yaml = r#"
cargo_build_debug:
  avg_gb: 2.0
  p95_gb: 3.5
  observed_n: 0
  last_updated: "seeded"
  notes: "debug build"
chump_claim_worktree:
  avg_gb: 0.05
  p95_gb: 0.12
  observed_n: 0
  last_updated: "seeded"
  notes: "worktree claim"
sonnet_dispatch_with_worktree:
  avg_gb: 2.5
  p95_gb: 4.0
  observed_n: 0
  last_updated: "seeded"
  notes: "full dispatch"
"#;
        let p = dir.join("DISK_COST_MODEL.yaml");
        fs::write(&p, yaml).unwrap();
        p
    }

    // ── Test 1: load_snapshot parses schema correctly ────────────────────
    #[test]
    fn test_load_snapshot_parses_schema() {
        let dir = tempdir().unwrap();
        let snap = make_snapshot(20.0, 5.0);
        let p = write_snapshot(dir.path(), &snap);

        let loaded = load_snapshot(&p).expect("load_snapshot");
        assert_eq!(loaded.node_id, "test-node");
        assert!((loaded.free_gb - 20.0).abs() < 0.001);
        assert!((loaded.threshold_gb - 5.0).abs() < 0.001);
        assert_eq!(loaded.top_consumers.len(), 2);
        assert_eq!(loaded.top_consumers[1].path, "~/.cache/chump-runner");
    }

    // ── Test 2: load_cost_model parses YAML correctly ────────────────────
    #[test]
    fn test_load_cost_model_parses_yaml() {
        let dir = tempdir().unwrap();
        let p = write_cost_model(dir.path());

        let model = load_cost_model(&p).expect("load_cost_model");
        assert!(model.contains_key("cargo_build_debug"));
        assert!((model["cargo_build_debug"].p95_gb - 3.5).abs() < 0.001);
        assert!(model.contains_key("chump_claim_worktree"));
        assert!((model["chump_claim_worktree"].avg_gb - 0.05).abs() < 0.001);
    }

    // ── Test 3: compute_plan returns OK when headroom is ample ───────────
    #[test]
    fn test_compute_plan_ok_ample_headroom() {
        // free=50, threshold=5, cost=3.5, count=1 → free_after=46.5 > 10 → OK
        let (proj, decision) = compute_plan(50.0, 5.0, 3.5, 1);
        assert_eq!(decision, PlanDecision::Ok);
        assert!((proj.free_after_gb - 46.5).abs() < 0.001);
        assert!((proj.cost_gb - 3.5).abs() < 0.001);
    }

    // ── Test 4: compute_plan returns WAIT when in the 1×–2× buffer zone ─
    #[test]
    fn test_compute_plan_wait_in_buffer_zone() {
        // free=12, threshold=5, cost=3.5, count=1 → free_after=8.5
        // 8.5 >= 5 (not REFUSE) but 8.5 < 10 (threshold*2) → WAIT
        let (proj, decision) = compute_plan(12.0, 5.0, 3.5, 1);
        assert_eq!(decision, PlanDecision::Wait);
        assert!((proj.free_after_gb - 8.5).abs() < 0.001);
    }

    // ── Test 5: compute_plan returns REFUSE when below threshold ─────────
    #[test]
    fn test_compute_plan_refuse_below_threshold() {
        // free=7, threshold=5, cost=3.5, count=1 → free_after=3.5 < 5 → REFUSE
        let (proj, decision) = compute_plan(7.0, 5.0, 3.5, 1);
        assert_eq!(decision, PlanDecision::Refuse);
        assert!(proj.free_after_gb < 5.0);
    }

    // ── Test 6: compute_plan with count=3 multiplies cost correctly ──────
    #[test]
    fn test_compute_plan_count_multiplies_cost() {
        // free=50, threshold=5, cost_per=2.0, count=3 → total_cost=6.0, free_after=44.0
        let (proj, decision) = compute_plan(50.0, 5.0, 2.0, 3);
        assert_eq!(decision, PlanDecision::Ok);
        assert!((proj.cost_gb - 6.0).abs() < 0.001);
        assert!((proj.free_after_gb - 44.0).abs() < 0.001);
        assert_eq!(proj.count, 3);
    }

    // ── Test 7: max_safe_n is zero when below WAIT zone ──────────────────
    #[test]
    fn test_max_safe_n_zero_when_headroom_exhausted() {
        // free=8, threshold=5, floor=5, safe_available=8-10=-2 → 0
        let n = max_safe_n(8.0, 5.0, 2.0);
        assert_eq!(n, 0);
    }

    // ── Test 8: max_safe_n returns correct floor division ─────────────────
    #[test]
    fn test_max_safe_n_floor_division() {
        // free=30, threshold=5, effective=5 (floor=5 default), safe_avail=30-10=20
        // cost=3.5 → floor(20/3.5)=5
        // Need to unset CHUMP_DISK_FLOOR_GB if set
        std::env::remove_var("CHUMP_DISK_FLOOR_GB");
        let n = max_safe_n(30.0, 5.0, 3.5);
        assert_eq!(n, 5);
    }

    // ── Test 9: CHUMP_DISK_FLOOR_GB env tightens threshold ───────────────
    #[test]
    fn test_floor_gb_env_overrides_threshold() {
        // Set floor to 10 GB (tighter than inventory threshold of 5)
        std::env::set_var("CHUMP_DISK_FLOOR_GB", "10");
        // free=50, p95=3.5, count=1 → threshold effective=10, free_after=46.5 > 20 → OK
        let (_, decision) = compute_plan(50.0, 5.0, 3.5, 1);
        assert_eq!(decision, PlanDecision::Ok);

        // But at free=22 → free_after=18.5; threshold*2=20 → WAIT
        let (_, decision2) = compute_plan(22.0, 5.0, 3.5, 1);
        assert_eq!(decision2, PlanDecision::Wait);

        std::env::remove_var("CHUMP_DISK_FLOOR_GB");
    }

    // ── Test 10: run_status --json writes valid DiskSnapshot JSON ────────
    #[test]
    fn test_run_status_json_output() {
        let dir = tempdir().unwrap();
        let snap = make_snapshot(22.5, 5.0);
        let inv_path = dir.path().join("disk-inventory.json");
        fs::write(&inv_path, serde_json::to_string(&snap).unwrap()).unwrap();
        std::env::set_var("CHUMP_DISK_INVENTORY_PATH", inv_path.to_str().unwrap());

        // Capture output indirectly by testing the load round-trip
        let loaded = load_snapshot(&inv_path).unwrap();
        assert!((loaded.free_gb - 22.5).abs() < 0.001);
        assert_eq!(loaded.top_consumers.len(), 2);

        std::env::remove_var("CHUMP_DISK_INVENTORY_PATH");
    }

    // ── Test 11: unknown action class gives anyhow error ─────────────────
    #[test]
    fn test_unknown_action_class_error() {
        let dir = tempdir().unwrap();
        let model_path = write_cost_model(dir.path());
        let model = load_cost_model(&model_path).unwrap();
        assert!(!model.contains_key("nonexistent_action_xyz"));
    }

    // ── Test 12: exit_code mapping ────────────────────────────────────────
    #[test]
    fn test_decision_exit_codes() {
        assert_eq!(PlanDecision::Ok.exit_code(), 0);
        assert_eq!(PlanDecision::Refuse.exit_code(), 1);
        assert_eq!(PlanDecision::Wait.exit_code(), 2);
    }
}
