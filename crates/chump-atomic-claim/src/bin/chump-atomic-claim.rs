//! META-208: standalone CLI entrypoint for the atomic-claim crate.
//! Today's only subcommand is `flake-import`, wired for
//! `cargo run --bin chump-atomic-claim -- flake-import --input <path>`.

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("flake-import") => run_flake_import(&args[2..]),
        _ => {
            eprintln!("usage: chump-atomic-claim flake-import --input <nextest-output.json>");
            ExitCode::FAILURE
        }
    }
}

fn run_flake_import(rest: &[String]) -> ExitCode {
    let mut input: Option<PathBuf> = None;
    let mut i = 0;
    while i < rest.len() {
        if rest[i] == "--input" && i + 1 < rest.len() {
            input = Some(PathBuf::from(&rest[i + 1]));
            i += 2;
        } else {
            i += 1;
        }
    }
    let Some(input) = input else {
        eprintln!("flake-import: missing required --input <path>");
        return ExitCode::FAILURE;
    };
    let repo_root = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    match chump_atomic_claim::atomic_claim::run_flake_import(&repo_root, &input) {
        Ok(n) => {
            println!("flake-import: {} flaky test row(s) recorded", n);
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("flake-import failed: {e:#}");
            ExitCode::FAILURE
        }
    }
}
