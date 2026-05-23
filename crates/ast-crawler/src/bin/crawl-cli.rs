//! crawl-cli — INFRA-1722 thin CLI wrapper over `chump_ast_crawler::crawl_repo`.
//!
//! Emits the full `CodebaseShape` as JSON on stdout so shell-based generators
//! (the ARCHITECTURE.md / CAPABILITIES_REGISTRY companions) can consume it
//! without re-implementing tree-sitter parsing in bash.
//!
//! Usage:
//!   cargo run --quiet -p chump-ast-crawler --bin crawl-cli -- <repo-root>
//!
//! Exit codes:
//!   0  shape written to stdout (UTF-8 JSON)
//!   2  bad usage (missing repo-root arg)
//!   3  crawl_repo returned an error (typically IO)
//!
//! Stable contract: keep stdout machine-parseable JSON only; route diagnostics
//! to stderr so callers can capture output with `--quiet` cleanly.
//!
//! Tracked: INFRA-1722 (this gap) consumes INFRA-1719 (crawler).

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let repo_root = match args.next() {
        Some(s) => PathBuf::from(s),
        None => {
            eprintln!("usage: crawl-cli <repo-root>");
            return ExitCode::from(2);
        }
    };
    if !repo_root.is_dir() {
        eprintln!("crawl-cli: not a directory: {}", repo_root.display());
        return ExitCode::from(2);
    }
    match chump_ast_crawler::crawl_repo(&repo_root) {
        Ok(shape) => {
            // Pretty JSON keeps cat/jq friendly while staying compact enough
            // for a 1k-file repo. (~50 KiB for a 50-file shape.)
            match serde_json::to_string(&shape) {
                Ok(s) => {
                    println!("{s}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("crawl-cli: serde error: {e:#}");
                    ExitCode::from(3)
                }
            }
        }
        Err(e) => {
            eprintln!("crawl-cli: crawl_repo failed: {e:#}");
            ExitCode::from(3)
        }
    }
}
