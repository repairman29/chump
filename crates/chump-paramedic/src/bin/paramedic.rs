//! INFRA-1645: standalone `paramedic` binary entry point.
//!
//! Today this only wires up `--smoke-test` (AC §3) — a quick, network-free
//! observability check independent of the full `chump` CLI. The triage/
//! execute/daemon subcommands are reached via `chump paramedic ...`
//! (src/main.rs), which links this crate's lib target directly.

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--smoke-test") {
        match chump_paramedic::paramedic::smoke_test() {
            Ok(()) => std::process::exit(0),
            Err(e) => {
                eprintln!("paramedic smoke-test failed: {e:#}");
                std::process::exit(1);
            }
        }
    } else {
        eprintln!("usage: paramedic --smoke-test");
        std::process::exit(2);
    }
}
