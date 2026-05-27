//! `chump-gap-architect` — Rust port of `scripts/coord/gap-architect.py`'s
//! **decomposition path** (Phase 1 of INFRA-2000 / META-107).
//!
//! ## Scope
//!
//! Phase 1 surfaces:
//!
//! - `--decompose <GAP-ID>`  build the decomposition prompt for a gap.
//! - `--dry-run`             print the prompt only (no LLM call).
//! - `--apply`               call the LLM (via `ClaudeBinaryClient`) and
//!                            print the parsed sub-gap candidates.
//!
//! The Python tool's open-gap-pool sprint planning path (its "default"
//! invocation that hits Anthropic SDK directly, dedups across the whole
//! registry, and ships a PR) is out of scope. When invoked without
//! `--decompose`, the shim falls back to the Python body.

use std::process::ExitCode;

use chump_gap_store::maintenance::architect::{ClaudeBinaryClient, DecomposeMode, GapArchitect};
use chump_gap_store::maintenance::resolve_repo_root;

fn usage() {
    eprintln!("usage: chump-gap-architect --decompose <GAP-ID> [--dry-run | --apply]");
}

fn main() -> ExitCode {
    let raw_args: Vec<String> = std::env::args().skip(1).collect();
    let mut gap_id: Option<String> = None;
    let mut dry_run = false;
    let mut apply = false;

    let mut i = 0;
    while i < raw_args.len() {
        match raw_args[i].as_str() {
            "--decompose" => {
                gap_id = raw_args.get(i + 1).cloned();
                i += 2;
                continue;
            }
            "--dry-run" => {
                dry_run = true;
            }
            "--apply" => {
                apply = true;
            }
            "-h" | "--help" => {
                usage();
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("[chump-gap-architect] unknown flag: {}", other);
                usage();
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let gid = match gap_id {
        Some(g) if !g.is_empty() => g,
        _ => {
            eprintln!(
                "[chump-gap-architect] Phase 1 requires --decompose <GAP-ID>. \
                 Unset CHUMP_GAP_MAINTENANCE_RUST to run the Python sprint-planner path."
            );
            usage();
            return ExitCode::from(2);
        }
    };
    let mode = if apply {
        DecomposeMode::Apply
    } else if dry_run {
        DecomposeMode::DryRun
    } else {
        // Default to dry-run — safer for a shim caller.
        DecomposeMode::DryRun
    };

    let root = match resolve_repo_root() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[chump-gap-architect] resolve_repo_root failed: {}", e);
            return ExitCode::from(2);
        }
    };

    let architect = GapArchitect::new(&root, ClaudeBinaryClient::default());

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("[chump-gap-architect] runtime: {}", e);
            return ExitCode::from(2);
        }
    };
    let result = rt.block_on(architect.decompose(&gid, mode));
    match result {
        Ok(sub_gaps) => {
            if matches!(mode, DecomposeMode::DryRun) {
                // build_prompt already printed to stderr from
                // architect.decompose's dry-run branch.
                return ExitCode::SUCCESS;
            }
            match serde_yaml::to_string(&sub_gaps) {
                Ok(yaml) => {
                    println!("{}", yaml);
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("[chump-gap-architect] yaml render: {}", e);
                    ExitCode::from(1)
                }
            }
        }
        Err(e) => {
            eprintln!("[chump-gap-architect] decompose failed: {}", e);
            ExitCode::from(1)
        }
    }
}
