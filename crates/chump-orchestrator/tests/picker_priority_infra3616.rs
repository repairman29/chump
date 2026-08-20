//! INFRA-3616: the fleet's live gap picker MUST honor priority as the PRIMARY
//! sort key, with mission-bias as a within-priority-band tiebreaker.
//!
//! The live fleet worker (`scripts/dispatch/worker.sh`) selects work by piping
//! the open-gap set through `scripts/dispatch/_pick_and_claim_gap.py`. Before
//! this fix that picker sorted on `(-affinity_score, effective_prio, ...)` where
//! `effective_prio = max(prio_rank - rebalance_boost, 0)` folded the FLEET-046
//! rebalance boost INTO priority — letting a boosted/affinity-matched P1 tie and
//! then beat a real P0. Operator-marked P0s and the active mission sat unworked
//! while the fleet ground low-priority gaps (observed live: P1 MISSION-055 was
//! picked over P0 INFRA-3616, the keystone gap that this very fix lands).
//!
//! These tests drive the ACTUAL live picker (in dry-run mode, so no lease is
//! written) and assert the post-fix ordering invariants. They run under the
//! standard `cargo test` lane, so CI exercises the real script — not a Rust
//! re-implementation of it.
//!
//! Proof bars (see the gap AC):
//!   A. Priority order: a mix of pickable P0/P1/P2/P3 gaps → the P0 leads.
//!   B. Mission bias:  two equal-priority gaps, one linked to the active mission
//!      outcome and one not → the mission-linked one leads.

use std::io::Write;
use std::path::PathBuf;
use std::process::Command;

/// Absolute path to the live picker script under test. This test lives in the
/// chump-orchestrator crate, so the repo root is two levels up from the crate
/// manifest dir (crates/chump-orchestrator → repo root).
fn picker_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../scripts/dispatch/_pick_and_claim_gap.py")
}

/// True when a `python3` interpreter is on PATH. CI runners have one (the
/// pipeline pip-installs pyyaml), but we skip gracefully off-CI rather than
/// hard-fail a machine with no python3.
fn python3_available() -> bool {
    Command::new("python3")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Run the live picker in dry-run mode over `gaps_json` and return the gap id it
/// would pick. `active_mission` sets `CHUMP_ACTIVE_MISSION`; rebalance and
/// affinity are disabled so the test isolates the priority + mission ordering
/// (the picker's ORDER-independent invariants) from ship-history heuristics.
fn pick(gaps_json: &str, active_mission: &str, priority_filter: &str) -> String {
    let script = picker_path();
    assert!(
        script.exists(),
        "picker script missing at {}",
        script.display()
    );

    // Isolated temp workspace: gap JSON input + a lock/repo dir with no state.db
    // (so get_ship_history() returns [] and no rebalance boost is computed).
    // Unique per invocation — tests run in parallel and must not share the gap
    // file or lock dir (an early version raced and every test read the same
    // clobbered gaps.json).
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let uniq = COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!(
        "i3616-picker-{}-{}-{}",
        std::process::id(),
        uniq,
        nanos
    ));
    let _ = std::fs::create_dir_all(&dir);
    let gap_file = dir.join("gaps.json");
    let mut f = std::fs::File::create(&gap_file).expect("write gap file");
    f.write_all(gaps_json.as_bytes()).expect("write gaps");
    let lock_dir = dir.join("locks");
    let _ = std::fs::create_dir_all(&lock_dir);

    let out = Command::new("python3")
        .arg(&script)
        .env("GAP_JSON_FILE", &gap_file)
        .env("CHUMP_FLEET_DRY_RUN", "1")
        .env("CHUMP_SESSION_ID", "i3616-test")
        .env("CHUMP_LOCK_DIR", &lock_dir)
        .env("REPO_ROOT", &dir)
        .env("CHUMP_REBALANCE", "0")
        .env("CHUMP_AFFINITY", "0")
        .env("FLEET_MODEL", "opus") // unconstrained: no effort-tier gate in the way
        .env("FLEET_PRIORITY_FILTER", priority_filter)
        .env("CHUMP_ACTIVE_MISSION", active_mission)
        .output()
        .expect("run picker");
    assert!(
        out.status.success(),
        "picker exited non-zero: stderr={}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// Build a minimal open-gap JSON row. Fields mirror `chump gap list --json`.
fn gap(
    id: &str,
    domain: &str,
    priority: &str,
    effort: &str,
    outcome: &str,
    created_at: i64,
) -> String {
    gap_with_deps(id, domain, priority, effort, outcome, created_at, &[])
}

/// Same as `gap`, but with an explicit `depends_on` list — needed for the
/// INFRA-3612 effective-priority propagation tests below.
fn gap_with_deps(
    id: &str,
    domain: &str,
    priority: &str,
    effort: &str,
    outcome: &str,
    created_at: i64,
    depends_on: &[&str],
) -> String {
    let deps_json = depends_on
        .iter()
        .map(|d| format!("\"{d}\""))
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"id":"{id}","domain":"{domain}","title":"{id} title","priority":"{priority}","effort":"{effort}","status":"open","depends_on":[{deps_json}],"notes":"","skills_required":"","preferred_backend":"","preferred_machine":"","required_model":"","outcome_id":"{outcome}","created_at":{created_at}}}"#
    )
}

/// Proof A: given a mix of open, pickable gaps at P0/P1/P2/P3, the picker's
/// next-pickable returns the P0 — a P0 before any P1/P2/P3. The P0 is declared
/// LAST and given the newest created_at so nothing but priority can float it up.
#[test]
fn infra3616_picker_returns_p0_before_lower_priority() {
    if !python3_available() {
        eprintln!("skipping: python3 not available");
        return;
    }
    let gaps = format!(
        "[{},{},{},{}]",
        gap("AAA-100", "CREDIBLE", "P3", "xs", "", 1),
        gap("AAA-101", "CREDIBLE", "P2", "xs", "", 2),
        gap("AAA-102", "CREDIBLE", "P1", "xs", "", 3),
        gap("ZZZ-999", "INFRA", "P0", "m", "RUN-INSTALL", 9_999), // last + newest
    );
    let picked = pick(&gaps, "RUN-INSTALL", "P0,P1,P2,P3");
    assert_eq!(
        picked, "ZZZ-999",
        "a P0 must be picked before any lower-priority gap (got {picked})"
    );
}

/// Proof A (corollary): with the P0 removed, the strict P1 > P2 > P3 order holds.
#[test]
fn infra3616_picker_orders_p1_over_p2_over_p3() {
    if !python3_available() {
        eprintln!("skipping: python3 not available");
        return;
    }
    let gaps = format!(
        "[{},{},{}]",
        gap("AAA-100", "CREDIBLE", "P3", "xs", "", 1),
        gap("AAA-101", "CREDIBLE", "P2", "xs", "", 2),
        gap("AAA-102", "CREDIBLE", "P1", "xs", "", 3),
    );
    let picked = pick(&gaps, "RUN-INSTALL", "P0,P1,P2,P3");
    assert_eq!(picked, "AAA-102", "P1 must lead P2/P3 (got {picked})");
}

/// Proof B: two EQUAL-priority pickable gaps, one linked to the active mission
/// outcome (RUN-INSTALL) and one not — the mission-linked one ranks first.
/// Mission-linkage must only break ties WITHIN a priority band, never cross it,
/// so both gaps are P1 here.
#[test]
fn infra3616_picker_mission_bias_within_priority_band() {
    if !python3_available() {
        eprintln!("skipping: python3 not available");
        return;
    }
    // Non-mission gap declared FIRST and older, so only mission-bias can float
    // the mission gap above it.
    let gaps = format!(
        "[{},{}]",
        gap("AAA-200", "CREDIBLE", "P1", "s", "", 1), // not mission-linked
        gap("BBB-201", "CREDIBLE", "P1", "s", "RUN-INSTALL", 2), // mission-linked
    );
    let picked = pick(&gaps, "RUN-INSTALL", "P0,P1,P2,P3");
    assert_eq!(
        picked, "BBB-201",
        "the mission-linked gap must lead an equal-priority non-mission gap (got {picked})"
    );
}

/// Proof B (guard): mission-bias must NOT cross a priority tier. A P0 non-mission
/// gap still beats a P1 mission-linked gap — priority dominates mission.
#[test]
fn infra3616_priority_dominates_mission_across_tiers() {
    if !python3_available() {
        eprintln!("skipping: python3 not available");
        return;
    }
    let gaps = format!(
        "[{},{}]",
        gap("AAA-300", "INFRA", "P0", "m", "", 1), // P0, NOT mission-linked
        gap("BBB-301", "MISSION", "P1", "s", "RUN-INSTALL", 2), // P1, mission-linked
    );
    let picked = pick(&gaps, "RUN-INSTALL", "P0,P1,P2,P3");
    assert_eq!(
        picked, "AAA-300",
        "a substrate P0 must beat a mission P1 — mission is a tiebreak, not a tier-jump (got {picked})"
    );
}

/// INFRA-3612: effective_priority propagation. A P3 that a P0 depends_on
/// must be picked BEFORE unrelated P1/P2 gaps — the blocker inherits the
/// max priority of what it transitively unblocks (via unblocks()), not
/// just its own nominal band. The P0 itself is declared with a
/// `depends_on` on the P3, so the P0 never becomes a candidate directly
/// (unresolved deps keep it filtered) — proving the propagation reaches
/// the picker only through the blocker, exactly the "P0 waits behind all
/// P1s while its own prereq sits unworked" deadlock the gap AC names.
#[test]
fn infra3612_blocker_inherits_effective_priority_of_blocked_p0() {
    if !python3_available() {
        eprintln!("skipping: python3 not available");
        return;
    }
    let gaps = format!(
        "[{},{},{},{}]",
        gap("AAA-100", "CREDIBLE", "P1", "xs", "", 1), // unrelated P1, oldest
        gap("BBB-101", "CREDIBLE", "P2", "xs", "", 2), // unrelated P2
        gap("CCC-200", "CREDIBLE", "P3", "xs", "", 3), // P3, no deps of its own — the pickable leaf blocker
        gap_with_deps("ZZZ-999", "INFRA", "P0", "m", "", 4, &["CCC-200"]), // P0 blocked on the P3
    );
    let picked = pick(&gaps, "", "P0,P1,P2,P3");
    assert_eq!(
        picked, "CCC-200",
        "a P3 that a P0 depends_on must be picked before unrelated P1/P2 gaps (got {picked})"
    );
}

/// INFRA-3612 (corollary): effective priority is transitive through a
/// multi-hop chain — a P3 that unblocks a P2 that unblocks a P0 still
/// inherits the P0's rank, not just the immediate P2's.
#[test]
fn infra3612_effective_priority_is_transitive() {
    if !python3_available() {
        eprintln!("skipping: python3 not available");
        return;
    }
    let gaps = format!(
        "[{},{},{},{}]",
        gap("AAA-100", "CREDIBLE", "P1", "xs", "", 1), // unrelated P1
        gap("CCC-200", "CREDIBLE", "P3", "xs", "", 2), // P3, no deps of its own — the pickable leaf blocker
        gap_with_deps("BBB-201", "CREDIBLE", "P2", "xs", "", 3, &["CCC-200"]), // P2, blocked on the P3
        gap_with_deps("ZZZ-999", "INFRA", "P0", "m", "", 4, &["BBB-201"]), // P0, blocked on the P2 (2 hops from the P3)
    );
    let picked = pick(&gaps, "", "P0,P1,P2,P3");
    assert_eq!(
        picked, "CCC-200",
        "a P3 two hops from a P0 must still inherit the P0's effective priority (got {picked})"
    );
}
