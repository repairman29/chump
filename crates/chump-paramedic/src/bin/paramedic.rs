//! INFRA-1645: standalone `paramedic` binary.
//!
//! Exists so `--smoke-test` can be run without compiling the full `chump`
//! bin crate (same build-speed rationale as the chump-paramedic lib split,
//! EFFECTIVE-404). The full triage/execute/daemon subcommands are wired
//! into the main `chump` binary via `chump paramedic <subcommand>`
//! (src/main.rs) — this bin only exposes the LLM-resilience smoke test.

use chump_paramedic::paramedic;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--smoke-test") {
        let repo_root = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
        match paramedic::run_smoke_test(&repo_root) {
            Ok(event) => {
                println!("{}", serde_json::to_string(&event).unwrap_or_default());
                std::process::exit(0);
            }
            Err(e) => {
                eprintln!("paramedic smoke-test failed: {e:#}");
                std::process::exit(1);
            }
        }
    } else {
        println!("Usage: paramedic --smoke-test");
        println!("(full triage/execute/daemon subcommands: `chump paramedic <subcommand>`)");
    }
}
