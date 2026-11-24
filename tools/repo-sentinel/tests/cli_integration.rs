use std::fs;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

static TEMP_DIR_COUNTER: AtomicUsize = AtomicUsize::new(0);

fn get_temp_dir() -> String {
    let id = TEMP_DIR_COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("/tmp/repo-sentinel-test-{}-{}", std::process::id(), id)
}

#[test]
fn test_cli_help_and_version() {
    let output = Command::new(env!("CARGO_BIN_EXE_repo-sentinel"))
        .arg("--help")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(0));

    let output = Command::new(env!("CARGO_BIN_EXE_repo-sentinel"))
        .arg("--version")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&output.stdout).contains("0.1.0"));
}

#[test]
fn test_cli_scan_redacts_secret_and_fails_gate() {
    let dir = get_temp_dir();
    fs::create_dir_all(&dir).unwrap();
    let env_path = format!("{}/.env.bak", dir);
    fs::write(
        &env_path,
        format!("{}{}{}", "sk_", "live_", "9876543210abcdef1234"),
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_repo-sentinel"))
        .arg("scan")
        .arg(&dir)
        .arg("--json")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));

    let parsed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(parsed["passed_gate"], false);
    assert!(!String::from_utf8_lossy(&output.stdout).contains("9876543210abcdef"));
}

#[test]
fn test_cli_harden_apply_and_hook() {
    let dir = get_temp_dir();
    fs::create_dir_all(&dir).unwrap();
    Command::new("git")
        .arg("init")
        .current_dir(&dir)
        .status()
        .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_repo-sentinel"))
        .arg("harden")
        .arg(&dir)
        .arg("--apply")
        .arg("--install-hook")
        .arg("--json")
        .output()
        .unwrap();
    assert!(output.status.success());

    let gitignore = fs::read_to_string(format!("{}/.gitignore", dir)).unwrap();
    assert!(gitignore.contains("*.bak"));
    assert!(gitignore.contains(".env*"));
    assert!(fs::metadata(format!("{}/.git/hooks/pre-commit", dir)).is_ok());
}

#[test]
fn test_cli_portfolio_clean() {
    let root = get_temp_dir();
    fs::create_dir_all(&root).unwrap();
    let repo_dir = format!("{}/repo", root);
    fs::create_dir_all(&repo_dir).unwrap();
    Command::new("git")
        .arg("init")
        .current_dir(&repo_dir)
        .status()
        .unwrap();
    fs::write(format!("{}/LICENSE", repo_dir), "MIT License").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_repo-sentinel"))
        .arg("portfolio")
        .arg(&root)
        .arg("--json")
        .output()
        .unwrap();
    assert!(output.status.success());

    let parsed: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(parsed["clean_repos"], 1);
}
