use chump_atomic_claim::atomic_claim::{emit_claim_completed, last_claim_completed};

fn main() {
    let smoke = std::env::args().any(|a| a == "--smoke");
    if !smoke {
        eprintln!("usage: chump-debug-helper --smoke [--emit]");
        std::process::exit(2);
    }
    let root = std::env::current_dir().unwrap_or_default();
    if std::env::args().any(|a| a == "--emit") {
        emit_claim_completed(&root, "DEBUG-0", "success", 0, "none");
    }
    match last_claim_completed(&root) {
        Some(v) => println!(
            "last claim: gap={} outcome={} cost_ms={} failure_class={}",
            v["gap_id"].as_str().unwrap_or("?"),
            v["outcome"].as_str().unwrap_or("?"),
            v["cost_ms"],
            v["failure_class"].as_str().unwrap_or("?"),
        ),
        None => println!("last claim: none recorded"),
    }
}
