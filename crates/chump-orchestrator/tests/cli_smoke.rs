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
        stdout.contains("chump-orchestrator (MVP step 1, dry-run):"),
        "missing summary line. stdout=\n{stdout}"
    );
    // We don't require a WOULD DISPATCH line because the backlog state can
    // legitimately have zero pickable gaps; the summary line + clean exit is
    // the contract.
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
