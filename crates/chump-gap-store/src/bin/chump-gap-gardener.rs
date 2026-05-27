//! `chump-gap-gardener` — Rust port of `scripts/coord/gap-gardener.py`'s
//! **audit half** (Phase 1 of INFRA-2000 / META-107).
//!
//! ## Scope
//!
//! Phase 1 ports the PM-health audit (P0 budget, vague pickable count,
//! pillar coverage). The Python tool's seeding-and-PR-creation path is
//! out of scope — when invoked without `--check`/`--audit`/`--json`,
//! the shim falls back to the Python body. When invoked with one of
//! those flags, the Rust binary runs and exits.
//!
//! ## Flags
//!
//! - `--check`        — equivalent to `audit-priorities`: non-zero exit
//!                       on any audit invariant breach.
//! - `--audit`        — same as `--check` but pretty-prints.
//! - `--json`         — emit the audit as compact JSON to stdout.
//! - `--min-depth N`  — accepted but no-op for audit; the Python tool's
//!                       queue-fill check needs the full seeding path.

use std::process::ExitCode;

use chump_gap_store::maintenance::gardener::GapGardener;
use chump_gap_store::maintenance::resolve_repo_root;

fn usage() {
    eprintln!("usage: chump-gap-gardener [--check | --audit | --json]");
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let want_check = args.iter().any(|a| a == "--check");
    let want_audit = args.iter().any(|a| a == "--audit");
    let want_json = args.iter().any(|a| a == "--json");

    if !want_check && !want_audit && !want_json {
        // Phase 1: seeding-path stays in Python. Signal to caller.
        eprintln!(
            "[chump-gap-gardener] Phase 1 only ports --check / --audit / --json. \
             Unset CHUMP_GAP_MAINTENANCE_RUST or pass --check/--audit/--json."
        );
        usage();
        return ExitCode::from(2);
    }

    let root = match resolve_repo_root() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[chump-gap-gardener] resolve_repo_root failed: {}", e);
            return ExitCode::from(2);
        }
    };
    let gardener = GapGardener::new(&root);
    let report = match gardener.audit() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[chump-gap-gardener] audit failed: {:#}", e);
            return ExitCode::from(2);
        }
    };

    if want_json {
        let v = report.to_json();
        println!("{}", serde_json::to_string(&v).unwrap_or_default());
    } else {
        print!("{}", report.render());
    }

    if (want_check || want_audit) && report.failing() {
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}
