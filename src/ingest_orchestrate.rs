//! `chump ingest <repo-path> --confirm-mutations` — INFRA-1784 (INFRA-1746
//! phase 5): orchestrates phases 1b-4 (Librarian, Cartographer, Evangelist,
//! Systematizer) in sequence, writes a takeover certificate, proposes up to
//! 5 follow-up gaps from the combined findings, and records a PR-attempt
//! stub for the future auto-PR pipeline.
//!
//! ## Scope (v1)
//!
//! All four phases are static, read-only scans (INFRA-1780/1781/1782/1783)
//! with `cost_usd_cents=0`, so `total_cost_usd_cents` is always 0 in v1 —
//! the budget check exists so it starts enforcing the moment a phase adds a
//! real LLM/API call. Auto-PR opening (real `git`/`gh` mutation against the
//! target repo) is deliberately **out of scope for v1**: `prs_attempted`
//! stays 0 in the `ingest_complete` event rather than mutating the
//! target's git history without a code-generation pipeline behind it.
//! That is a follow-up gap, not a silent gap in this one.
//!
//! ## Sequencing + failure taxonomy
//!
//! Phases run in order; the first failure aborts the remaining phases
//! (partial artifacts already written by earlier phases are left in place —
//! they're independently useful). Each phase's own `FailureClass` maps
//! straight through: **permanent** (bad path, not-a-git-repo, invalid
//! budget — operator action required, don't retry) vs **transient** (IO
//! error mid-scan/write — safe to retry). `ingest_orchestrate_failed` carries
//! both `phase` (which phase aborted) and `failure_class`/`transient` from
//! that phase's error.

use std::path::{Path, PathBuf};
use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    /// A phase reported a bad/missing target path. Not retryable without
    /// operator action.
    PathNotFound,
    /// A phase hit a filesystem error mid-scan or while writing its
    /// artifact. Retryable.
    IoError,
    /// Combined phase cost exceeded `budget_usd`. Not retryable without
    /// raising the budget.
    BudgetExceeded,
}

impl FailureClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            FailureClass::PathNotFound => "path_not_found",
            FailureClass::IoError => "io_error",
            FailureClass::BudgetExceeded => "budget_exceeded",
        }
    }

    pub fn transient(&self) -> bool {
        matches!(self, FailureClass::IoError)
    }
}

#[derive(Debug)]
pub struct OrchestrateError {
    pub phase: &'static str,
    pub class: FailureClass,
    pub message: String,
}

impl std::fmt::Display for OrchestrateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}: {}: {}",
            self.phase,
            self.class.as_str(),
            self.message
        )
    }
}

pub struct OrchestrateConfig {
    pub target_repo: PathBuf,
    pub budget_usd: f64,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ProposedGap {
    pub title: String,
    pub priority: &'static str,
    pub effort: &'static str,
    pub confidence: &'static str,
    pub rationale: String,
    pub source_of_evidence: String,
}

#[derive(Debug)]
pub struct OrchestrateReport {
    pub target_repo: PathBuf,
    pub phases_completed: Vec<&'static str>,
    pub total_cost_usd_cents: u64,
    pub elapsed_ms: u128,
    pub certificate_path: PathBuf,
    pub gaps_proposed: Vec<ProposedGap>,
    pub prs_attempted: usize,
}

/// Run phases 1b-4 in sequence, write the takeover certificate + proposed
/// gaps, and record the (deferred-v1) PR-attempt stub. Aborts on the first
/// phase failure; artifacts already written by earlier phases are kept.
pub fn run(cfg: &OrchestrateConfig) -> Result<OrchestrateReport, OrchestrateError> {
    let start = Instant::now();
    let mut phases_completed: Vec<&'static str> = Vec::new();
    let mut total_cost_usd_cents: u64 = 0;

    let librarian_cfg = crate::ingest_librarian::LibrarianConfig {
        target_repo: cfg.target_repo.clone(),
        budget_usd: cfg.budget_usd,
    };
    let librarian_report =
        crate::ingest_librarian::run_sweep(&librarian_cfg).map_err(|e| OrchestrateError {
            phase: "librarian",
            class: map_librarian_class(e.class),
            message: e.message,
        })?;
    crate::ingest_librarian::write_triage_report(&librarian_report).map_err(|e| {
        OrchestrateError {
            phase: "librarian",
            class: map_librarian_class(e.class),
            message: e.message,
        }
    })?;
    total_cost_usd_cents += librarian_report.cost_usd_cents;
    phases_completed.push("librarian");
    check_budget(cfg.budget_usd, total_cost_usd_cents, "librarian")?;

    let cartograph_cfg = crate::cartographer::CartographConfig {
        target_repo: cfg.target_repo.clone(),
    };
    let cartograph_report =
        crate::cartographer::run_scan(&cartograph_cfg).map_err(|e| OrchestrateError {
            phase: "cartographer",
            class: map_cartograph_class(e.class),
            message: e.message,
        })?;
    crate::cartographer::write_architecture_md(&cartograph_report).map_err(|e| {
        OrchestrateError {
            phase: "cartographer",
            class: map_cartograph_class(e.class),
            message: e.message,
        }
    })?;
    total_cost_usd_cents += cartograph_report.cost_usd_cents;
    phases_completed.push("cartographer");
    check_budget(cfg.budget_usd, total_cost_usd_cents, "cartographer")?;

    let evangelist_cfg = crate::evangelist::EvangelistConfig {
        target_repo: cfg.target_repo.clone(),
    };
    let evangelist_report =
        crate::evangelist::run_scan(&evangelist_cfg).map_err(|e| OrchestrateError {
            phase: "evangelist",
            class: map_evangelist_class(e.class),
            message: e.message,
        })?;
    crate::evangelist::write_hidden_gems_md(&evangelist_report).map_err(|e| OrchestrateError {
        phase: "evangelist",
        class: map_evangelist_class(e.class),
        message: e.message,
    })?;
    total_cost_usd_cents += evangelist_report.cost_usd_cents;
    phases_completed.push("evangelist");
    check_budget(cfg.budget_usd, total_cost_usd_cents, "evangelist")?;

    let systematizer_cfg = crate::systematizer::SystematizerConfig {
        target_repo: cfg.target_repo.clone(),
    };
    let systematizer_report =
        crate::systematizer::run_scan(&systematizer_cfg).map_err(|e| OrchestrateError {
            phase: "systematizer",
            class: map_systematizer_class(e.class),
            message: e.message,
        })?;
    crate::systematizer::write_capabilities_registry_json(&systematizer_report).map_err(|e| {
        OrchestrateError {
            phase: "systematizer",
            class: map_systematizer_class(e.class),
            message: e.message,
        }
    })?;
    total_cost_usd_cents += systematizer_report.cost_usd_cents;
    phases_completed.push("systematizer");
    check_budget(cfg.budget_usd, total_cost_usd_cents, "systematizer")?;

    let elapsed_ms = start.elapsed().as_millis();

    let gaps_proposed = propose_gaps(&librarian_report);

    let certificate_path = write_certificate(
        &cfg.target_repo,
        &cartograph_report,
        &librarian_report,
        &evangelist_report,
        &systematizer_report,
        total_cost_usd_cents,
        elapsed_ms,
        gaps_proposed.len(),
    )
    .map_err(|e| OrchestrateError {
        phase: "certificate",
        class: FailureClass::IoError,
        message: e.to_string(),
    })?;

    write_proposed_gaps(&cfg.target_repo, &gaps_proposed).map_err(|e| OrchestrateError {
        phase: "propose_gaps",
        class: FailureClass::IoError,
        message: e.to_string(),
    })?;

    // Auto-PR stage: deliberately deferred to v1's PR-candidate stub — see
    // module doc. `prs_attempted` stays 0 until a code-generation pipeline
    // exists to back real branch/push/PR-create calls.
    let prs_attempted = 0usize;

    Ok(OrchestrateReport {
        target_repo: cfg.target_repo.clone(),
        phases_completed,
        total_cost_usd_cents,
        elapsed_ms,
        certificate_path,
        gaps_proposed,
        prs_attempted,
    })
}

fn check_budget(
    budget_usd: f64,
    total_cost_usd_cents: u64,
    phase: &'static str,
) -> Result<(), OrchestrateError> {
    let spent_usd = total_cost_usd_cents as f64 / 100.0;
    if spent_usd > budget_usd {
        return Err(OrchestrateError {
            phase,
            class: FailureClass::BudgetExceeded,
            message: format!(
                "cumulative cost ${spent_usd:.2} exceeded budget ${budget_usd:.2} after phase '{phase}'"
            ),
        });
    }
    Ok(())
}

fn map_librarian_class(c: crate::ingest_librarian::FailureClass) -> FailureClass {
    use crate::ingest_librarian::FailureClass as L;
    match c {
        L::PathNotFound | L::NotAGitRepo | L::InvalidBudget => FailureClass::PathNotFound,
        L::IoError => FailureClass::IoError,
    }
}

fn map_cartograph_class(c: crate::cartographer::FailureClass) -> FailureClass {
    use crate::cartographer::FailureClass as C;
    match c {
        C::PathNotFound => FailureClass::PathNotFound,
        C::IoError => FailureClass::IoError,
    }
}

fn map_evangelist_class(c: crate::evangelist::FailureClass) -> FailureClass {
    use crate::evangelist::FailureClass as E;
    match c {
        E::PathNotFound => FailureClass::PathNotFound,
        E::IoError => FailureClass::IoError,
    }
}

fn map_systematizer_class(c: crate::systematizer::FailureClass) -> FailureClass {
    use crate::systematizer::FailureClass as S;
    match c {
        S::PathNotFound => FailureClass::PathNotFound,
        S::IoError => FailureClass::IoError,
    }
}

/// Derive up to 5 candidate gaps from the Librarian's findings — the only
/// phase 1b-4 output with clear actionability signal in v1 (dead code /
/// duplicated scripts). Deterministic, no LLM call, so it's cheap enough to
/// always run inside the budget already spent on the librarian sweep.
fn propose_gaps(librarian_report: &crate::ingest_librarian::LibrarianReport) -> Vec<ProposedGap> {
    let mut gaps = Vec::new();
    for candidate in &librarian_report.dead_code_candidates {
        if gaps.len() >= 5 {
            break;
        }
        gaps.push(ProposedGap {
            title: format!(
                "ZERO-WASTE: verify and remove possibly-dead code at {}",
                candidate.path
            ),
            priority: "P2",
            effort: "xs",
            confidence: "low",
            rationale: format!(
                "Librarian's dead-code heuristic found no other file in the tree referencing '{}' by stem — false positives are expected, so this needs a human/agent grep-confirm before deletion.",
                candidate.stem
            ),
            source_of_evidence: ".chump-ingest/triage.md#dead-code-candidates".to_string(),
        });
    }
    for group in &librarian_report.redundant_scripts {
        if gaps.len() >= 5 {
            break;
        }
        gaps.push(ProposedGap {
            title: format!(
                "ZERO-WASTE: deduplicate {} byte-identical scripts",
                group.paths.len()
            ),
            priority: "P2",
            effort: "xs",
            confidence: "med",
            rationale: format!(
                "Librarian found byte-identical content (after trailing-whitespace trim) across: {}.",
                group.paths.join(", ")
            ),
            source_of_evidence: ".chump-ingest/triage.md#redundant-scripts".to_string(),
        });
    }
    gaps
}

#[allow(clippy::too_many_arguments)]
fn write_certificate(
    target_repo: &Path,
    cartograph_report: &crate::cartographer::CartographReport,
    librarian_report: &crate::ingest_librarian::LibrarianReport,
    evangelist_report: &crate::evangelist::EvangelistReport,
    systematizer_report: &crate::systematizer::SystematizerReport,
    total_cost_usd_cents: u64,
    elapsed_ms: u128,
    gaps_proposed_count: usize,
) -> std::io::Result<PathBuf> {
    let entry_points: Vec<serde_json::Value> = cartograph_report
        .entry_points
        .iter()
        .map(|e| serde_json::json!({"path": e.path, "language": e.language, "note": e.note}))
        .collect();
    let hot_paths: Vec<serde_json::Value> = cartograph_report
        .hot_paths
        .iter()
        .map(|h| serde_json::json!({"path": h.path, "lines": h.lines}))
        .collect();
    // v1 test-surface heuristic: count entry points / hot paths whose path
    // contains "test" — a real coverage map is a follow-up gap, not a
    // silent gap here (see module doc).
    let test_file_count = cartograph_report
        .hot_paths
        .iter()
        .filter(|h| h.path.contains("test"))
        .count();

    let certificate = serde_json::json!({
        "target_repo": target_repo.display().to_string(),
        "entry_points": entry_points,
        "hot_paths": hot_paths,
        "test_surface": {
            "heuristic": "hot_paths entries whose path contains 'test'",
            "test_file_count": test_file_count,
        },
        "dependency_graph": {
            "note": "not built in v1 — static scans (INFRA-1780/1781/1782/1783) don't parse import graphs; deferred to a follow-up gap",
            "edges": [],
        },
        "findings_summary": {
            "dead_code_candidates": librarian_report.dead_code_candidates.len(),
            "redundant_script_groups": librarian_report.redundant_scripts.len(),
            "hidden_gem_scripts": evangelist_report.scripts.len(),
            "config_knobs": evangelist_report.config_knobs.len(),
            "capabilities_registered": systematizer_report.entries.len(),
        },
        "gaps_proposed": gaps_proposed_count,
        "ingestion_cost_usd_cents": total_cost_usd_cents,
        "ingestion_elapsed_min": elapsed_ms as f64 / 60_000.0,
    });

    let dir = target_repo.join(".chump-ingest");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("certificate.json");
    std::fs::write(&path, serde_json::to_string_pretty(&certificate)?)?;
    Ok(path)
}

fn write_proposed_gaps(target_repo: &Path, gaps: &[ProposedGap]) -> std::io::Result<PathBuf> {
    let dir = target_repo.join(".chump-ingest");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("proposed-gaps.json");
    std::fs::write(&path, serde_json::to_string_pretty(gaps)?)?;
    Ok(path)
}

fn emit_ambient(chump_repo_root: &Path, payload: serde_json::Value) {
    let ambient_path = chump_repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    if let Ok(mut out) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = writeln!(out, "{}", payload);
    }
}

pub fn emit_started(chump_repo_root: &Path, target_repo: &Path) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        // scanner-anchor: "kind":"ingest_orchestrate_started"
        serde_json::json!({
            "ts": ts,
            "kind": "ingest_orchestrate_started",
            "target_repo": target_repo.display().to_string(),
        }),
    );
}

pub fn emit_completed(chump_repo_root: &Path, report: &OrchestrateReport) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        // scanner-anchor: "kind":"ingest_complete"
        serde_json::json!({
            "ts": ts,
            "kind": "ingest_complete",
            "target_repo_path": report.target_repo.display().to_string(),
            "phases_completed": report.phases_completed,
            "prs_attempted": report.prs_attempted,
            "prs_green_first_pass": 0,
            "gaps_proposed": report.gaps_proposed.len(),
            "total_cost_usd_cents": report.total_cost_usd_cents,
            "elapsed_min": report.elapsed_ms as f64 / 60_000.0,
        }),
    );
}

pub fn emit_failed(chump_repo_root: &Path, target_repo: &Path, err: &OrchestrateError) {
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    emit_ambient(
        chump_repo_root,
        // scanner-anchor: "kind":"ingest_orchestrate_failed"
        serde_json::json!({
            "ts": ts,
            "kind": "ingest_orchestrate_failed",
            "target_repo": target_repo.display().to_string(),
            "phase": err.phase,
            "failure_class": err.class.as_str(),
            "transient": err.class.transient(),
            "message": err.message,
        }),
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn init_git_repo(dir: &Path) {
        Command::new("git")
            .arg("init")
            .arg("-q")
            .arg(dir)
            .status()
            .unwrap();
    }

    #[test]
    fn orchestrate_runs_all_phases_and_writes_certificate() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("target-repo");
        std::fs::create_dir_all(&target).unwrap();
        init_git_repo(&target);
        std::fs::write(target.join("main.rs"), "fn main() {}\n").unwrap();

        let cfg = OrchestrateConfig {
            target_repo: target.clone(),
            budget_usd: 10.0,
        };
        let report = run(&cfg).expect("orchestrate should succeed on a valid target");
        assert_eq!(
            report.phases_completed,
            vec!["librarian", "cartographer", "evangelist", "systematizer"]
        );
        assert_eq!(report.total_cost_usd_cents, 0);
        assert!(report.certificate_path.exists());
        assert!(target.join(".chump-ingest/triage.md").exists());
        assert!(target.join("docs/ARCHITECTURE.md").exists());
        assert!(target.join("docs/HIDDEN_GEMS.md").exists());
        assert!(target.join("docs/CAPABILITIES_REGISTRY.json").exists());
        assert!(target.join(".chump-ingest/proposed-gaps.json").exists());
        assert_eq!(report.prs_attempted, 0);
    }

    #[test]
    fn orchestrate_fails_fast_on_missing_target() {
        let cfg = OrchestrateConfig {
            target_repo: PathBuf::from("/nonexistent/definitely-not-a-repo"),
            budget_usd: 10.0,
        };
        let err = run(&cfg).expect_err("missing target must fail");
        assert_eq!(err.phase, "librarian");
        assert_eq!(err.class, FailureClass::PathNotFound);
        assert!(!err.class.transient());
    }
}
