//! Thin CLI entrypoint for `cargo run --bin paramedic -- --smoke-test`
//! (INFRA-1645 AC §3). The `daemon`/`triage`/`execute` subcommands are
//! reached via the main `chump` binary (`chump paramedic ...`); this bin
//! exists only so the smoke-test can run standalone without the 190k-line
//! `chump` binary compiling first.

use std::path::PathBuf;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let repo_root = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));

    if args.iter().any(|a| a == "--smoke-test") {
        chump_paramedic::paramedic::smoke_test(&repo_root)?;
        return Ok(());
    }

    eprintln!("usage: paramedic --smoke-test");
    std::process::exit(2);
}
