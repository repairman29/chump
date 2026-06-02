//! INFRA-2399: `chump add-raw-gh-allowlist` — author-time helper to register a
//! script in scripts/ci/raw-gh-allowlist.txt so the cache-first mandate CI gate
//! (INFRA-1274) doesn't fire on the next PR.
//!
//! Usage:
//!   chump add-raw-gh-allowlist <script-path> --migration-gap <ID>
//!
//! <script-path> is a relative path from the repo root, e.g.
//!   scripts/coord/my-new-script.sh
//!
//! --migration-gap is required: it records the gap ID that will eventually
//! migrate this script to use the cache layer. This is the audit trail.
//!
//! Appends:
//!   <script-path>    # migration gap: <ID>
//!
//! Idempotent: if the script path is already present, exits 0.
//!
//! NOTE: This allowlist is a temporary escape hatch, not a permanent home.
//! The migration gap must be filed and tracked; raw-gh-allowlist.txt entries
//! should shrink over time, not grow.

use std::io::Write;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("CHUMP_REPO_ROOT") {
        return PathBuf::from(r);
    }
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let cargo = dir.join("Cargo.toml");
        if cargo.exists() {
            if let Ok(c) = std::fs::read_to_string(&cargo) {
                if c.contains("[workspace]") {
                    return dir;
                }
            }
        }
        if !dir.pop() {
            break;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Check if the script path is already in the allowlist.
fn already_listed(content: &str, script_path: &str) -> bool {
    for line in content.lines() {
        let entry = line.split('#').next().map(str::trim).unwrap_or("");
        if entry == script_path {
            return true;
        }
    }
    false
}

fn append_allowlist(path: &Path, script_path: &str, migration_gap: &str) -> anyhow::Result<()> {
    let mut f = std::fs::OpenOptions::new().append(true).open(path)?;
    writeln!(f, "{script_path}    # migration gap: {migration_gap}")?;
    Ok(())
}

pub fn run(args: &[String]) -> i32 {
    let mut script_path = String::new();
    let mut migration_gap = String::new();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--migration-gap" => {
                i += 1;
                if i < args.len() {
                    migration_gap = args[i].clone();
                }
            }
            "--help" | "-h" => {
                println!("Usage: chump add-raw-gh-allowlist <script-path> --migration-gap <ID>");
                println!();
                println!("Registers a script in scripts/ci/raw-gh-allowlist.txt.");
                println!("--migration-gap is required: the gap that will migrate this script");
                println!("to use the cache-first layer (INFRA-1274 mandate).");
                println!();
                println!("WARNING: this allowlist should shrink, not grow. Only use when");
                println!("raw gh calls are genuinely unavoidable (e.g. GitHub Admin API,");
                println!("write mutations not covered by cache abstraction).");
                return 0;
            }
            arg if !arg.starts_with('-') && script_path.is_empty() => {
                script_path = arg.to_string();
            }
            _ => {}
        }
        i += 1;
    }

    if script_path.is_empty() {
        eprintln!("error: <script-path> is required");
        eprintln!("Usage: chump add-raw-gh-allowlist <script-path> --migration-gap <ID>");
        return 2;
    }
    if migration_gap.is_empty() {
        eprintln!("error: --migration-gap <ID> is required");
        eprintln!("Every raw-gh allowlist entry must have a migration gap on file.");
        return 2;
    }

    let root = repo_root();
    let allowlist_path = root.join("scripts/ci/raw-gh-allowlist.txt");

    if !allowlist_path.exists() {
        eprintln!(
            "error: raw-gh-allowlist.txt not found at {}",
            allowlist_path.display()
        );
        return 1;
    }

    let content = match std::fs::read_to_string(&allowlist_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[add-raw-gh-allowlist] error reading allowlist: {e}");
            return 1;
        }
    };

    if already_listed(&content, &script_path) {
        println!("[add-raw-gh-allowlist] {script_path} already in raw-gh-allowlist.txt — skipping");
        return 0;
    }

    if let Err(e) = append_allowlist(&allowlist_path, &script_path, &migration_gap) {
        eprintln!("[add-raw-gh-allowlist] error appending: {e}");
        return 1;
    }

    println!("[add-raw-gh-allowlist] added {script_path} with migration gap {migration_gap}");
    println!("[add-raw-gh-allowlist] WARNING: raw-gh-allowlist should shrink over time.");
    println!("[add-raw-gh-allowlist] File the migration gap {migration_gap} if not already done.");
    0
}
