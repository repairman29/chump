//! INFRA-1645: standalone `paramedic` binary entrypoint.
//!
//! The normal path into paramedic is `chump paramedic <subcommand>` (see
//! `src/main.rs`). This bin exists so `--smoke-test` — a quick
//! observability check — can be run standalone without building the full
//! ~190k-line `chump` binary crate.

use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    let mut dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        if dir.join(".git").exists() {
            return dir;
        }
        if !dir.pop() {
            return std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--smoke-test") {
        let root = repo_root();
        if let Err(e) = chump_paramedic::llm_resilience::smoke_test(Path::new(&root)) {
            eprintln!("paramedic --smoke-test failed: {e:#}");
            std::process::exit(1);
        }
        return;
    }

    eprintln!("Usage: paramedic --smoke-test");
    eprintln!("(Full triage/execute/daemon subcommands live behind `chump paramedic ...`.)");
    std::process::exit(1);
}
