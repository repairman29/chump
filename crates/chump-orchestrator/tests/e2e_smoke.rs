//! AUTO-013 step 5 — end-to-end smoke against the synthetic backlog.
//!
//! This is the MVP-completion gate per the design doc §4 acceptance #1
//! ("drains 4-gap backlog, exits 0 when both PRs land") and #5
//! ("E2E smoke on noop synthetic backlog in <10 min" — we tighten that to
//! <10 seconds since the loop is fully mocked).
//!
//! The harness lives in `chump_orchestrator::self_test::run_self_test`; this
//! integration test just exercises it against the on-disk fixture and binds
//! the acceptance assertions.

use chump_orchestrator::self_test::run_self_test;
use std::path::PathBuf;
use std::time::Duration;

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("workspace root above crates/chump-orchestrator")
        .join("docs/test-fixtures/synthetic-backlog.yaml")
}

fn unique_scratch() -> PathBuf {
    std::env::temp_dir().join(format!(
        "chump-e2e-smoke-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

#[test]
fn synthetic_backlog_drains_to_all_shipped_under_10s() {
    let backlog = fixture_path();
    assert!(backlog.exists(), "missing fixture at {}", backlog.display());

    let scratch = unique_scratch();
    let report = run_self_test(&backlog, scratch.clone(), 2)
        .expect("orchestrator self-test must complete cleanly");

    // 1. Every gap shipped.
    assert_eq!(
        report.rows.len(),
        4,
        "expected 4 dispatched outcomes, got {} ({:?})",
        report.rows.len(),
        report.rows
    );
    let shipped = report
        .rows
        .iter()
        .filter(|r| {
            matches!(
                r.outcome,
                chump_orchestrator::monitor::DispatchOutcome::Shipped(_)
            )
        })
        .count();
    assert_eq!(shipped, 4, "expected all 4 shipped, got {shipped}");

    // 2. One reflection per gap.
    assert_eq!(
        report.reflections.len(),
        4,
        "expected 4 reflection rows, got {}",
        report.reflections.len()
    );
    for r in &report.reflections {
        assert_eq!(
            r.outcome, "shipped",
            "every reflection must record outcome=shipped, got {} for {}",
            r.outcome, r.gap_id
        );
        assert!(r.pr_number.is_some(), "shipped reflection missing PR #");
        assert_eq!(r.gap_domain, "synth", "domain prefix must be 'synth'");
    }

    // 3. Four dummy files on disk under the scratch dir.
    assert_eq!(
        report.dummy_files.len(),
        4,
        "expected 4 dummy files in {}, got {}",
        report.scratch_dir.display(),
        report.dummy_files.len()
    );
    for gap in ["SYNTH-001", "SYNTH-002", "SYNTH-003", "SYNTH-004"] {
        let p = report.scratch_dir.join(gap);
        assert!(
            p.exists(),
            "expected dummy file {} (one per dispatched gap)",
            p.display()
        );
    }

    // 4. The composite passed() helper agrees.
    assert!(
        report.passed(),
        "report.passed() must return true: {report:?}"
    );

    // 5. Wall-time budget.
    assert!(
        report.elapsed < Duration::from_secs(10),
        "wall time {:?} exceeded 10-second budget",
        report.elapsed
    );

    // Cleanup is best-effort.
    let _ = std::fs::remove_dir_all(&scratch);
}

#[test]
fn cli_self_test_flag_exits_zero() {
    // Belt-and-braces: invoking the binary with --self-test must complete
    // and exit zero. This binds the human-facing self-test contract.
    let bin = env!("CARGO_BIN_EXE_chump-orchestrator");
    let out = std::process::Command::new(bin)
        .arg("--self-test")
        .output()
        .expect("running --self-test");

    assert!(
        out.status.success(),
        "chump-orchestrator --self-test exited non-zero. stdout=\n{}\nstderr=\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("self-test PASSED"),
        "expected 'self-test PASSED' in stdout, got:\n{stdout}"
    );
}
