//! Standalone `chump-demo` binary. Thin wrapper over `chump_demo::run` — the
//! same entry point the main `chump` binary calls for `chump demo`
//! (INFRA-2391).

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(chump_demo::run(&args));
}
