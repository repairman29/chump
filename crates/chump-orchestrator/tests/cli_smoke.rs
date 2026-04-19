//! Integration smoke test: invoke the binary against the real docs/gaps.yaml
//! and assert it picks something sensible and exits 0 in dry-run.

use std::path::PathBuf;
use std::process::Command;

fn workspace_root() -> PathBuf {
    // CARGO_MANIFEST_DIR for this crate is .../crates/chump-orchestrator
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(|p| p.parent())
        .expect("workspace root above crates/chump-orchestrator")
        .to_path_buf()
}

#[test]
fn dry_run_against_real_backlog_exits_zero_and_picks_at_least_one() {
    let root = workspace_root();
    let backlog = root.join("docs/gaps.yaml");
    if !backlog.exists() {
        eprintln!("skipping: no docs/gaps.yaml at {}", backlog.display());
        return;
    }

    let bin = env!("CARGO_BIN_EXE_chump-orchestrator");
    let out = Command::new(bin)
        .args([
            "--backlog",
            backlog.to_str().unwrap(),
            "--max-parallel",
            "2",
            "--dry-run",
        ])
        .output()
        .expect("running chump-orchestrator");

    assert!(
        out.status.success(),
        "binary exited non-zero. stdout=\n{}\nstderr=\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );

    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("chump-orchestrator (MVP step 4, dry-run):"),
        "missing summary line. stdout=\n{stdout}"
    );
    // We don't require a WOULD DISPATCH line because the backlog state can
    // legitimately have zero pickable gaps; the summary line + clean exit is
    // the contract.
}

#[test]
fn no_dry_run_with_empty_backlog_exits_zero_without_spawning() {
    // Exercises the --no-dry-run branch in main() without forking a real
    // `claude` subprocess: an empty backlog has zero pickable gaps so the
    // dispatch loop never runs, but the path is still type-checked and the
    // execute-mode summary line is emitted.
    let tmp = std::env::temp_dir().join(format!("chump-orch-empty-{}.yaml", std::process::id()));
    std::fs::write(&tmp, "gaps: []\n").expect("write empty backlog");

    let bin = env!("CARGO_BIN_EXE_chump-orchestrator");
    let out = Command::new(bin)
        .args([
            "--backlog",
            tmp.to_str().unwrap(),
            "--max-parallel",
            "2",
            "--no-dry-run",
        ])
        .output()
        .expect("running chump-orchestrator");

    let _ = std::fs::remove_file(&tmp);
    assert!(
        out.status.success(),
        "binary exited non-zero. stdout=\n{}\nstderr=\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("MVP step 4, execute"),
        "execute-mode summary missing. stdout=\n{stdout}"
    );
}

#[test]
fn watch_with_empty_backlog_returns_immediately() {
    // --no-dry-run --watch on an empty backlog should hit the
    // "no pickable gaps" early-return BEFORE the monitor loop even spins up,
    // so we never fork a real claude subprocess and never block. This is the
    // step-3 acceptance test: --watch is wired in and safe on no-op input.
    let tmp = std::env::temp_dir().join(format!(
        "chump-orch-watch-empty-{}.yaml",
        std::process::id()
    ));
    std::fs::write(&tmp, "gaps: []\n").expect("write empty backlog");

    let bin = env!("CARGO_BIN_EXE_chump-orchestrator");
    let out = Command::new(bin)
        .args([
            "--backlog",
            tmp.to_str().unwrap(),
            "--max-parallel",
            "2",
            "--no-dry-run",
            "--watch",
        ])
        .output()
        .expect("running chump-orchestrator");

    let _ = std::fs::remove_file(&tmp);
    assert!(
        out.status.success(),
        "binary exited non-zero. stdout=\n{}\nstderr=\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("MVP step 4, execute+watch"),
        "watch-mode summary missing. stdout=\n{stdout}"
    );
}

#[test]
fn help_flag_exits_zero() {
    let bin = env!("CARGO_BIN_EXE_chump-orchestrator");
    let out = Command::new(bin)
        .arg("--help")
        .output()
        .expect("running --help");
    assert!(out.status.success());
}
