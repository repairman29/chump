//! INFRA-3508 (COTG-S.1): `chump source-resolve "<capability keyword>"` —
//! CLI surface for `crate::sourcing_resolver::resolve_sourcing`. Prints the
//! verdict (DONE-HERE / HALF-DONE-HERE / EXISTS-IN-ARSENAL / EXISTS-IN-WORLD /
//! NOT-FOUND) with receipts.
//!
//! Usage: `chump source-resolve "<keyword>" [--repo-root <path>] [--arsenal-json <path>]`
//!
//! Wired ahead of implement (AC2): the `improve` Flow (`src/improve.rs` Stage 2
//! DEDUP) calls `sourcing_resolver::resolve_sourcing` directly before spawning
//! the implement agent, so this CLI is the operator/debug surface over the same
//! resolver function, not a second implementation.

use crate::sourcing_resolver::{resolve_sourcing, SourcingVerdict};
use std::path::PathBuf;

pub fn run(args: &[String]) -> i32 {
    let mut keyword: Option<String> = None;
    let mut repo_root: Option<PathBuf> = None;
    let mut arsenal_json: Option<PathBuf> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--repo-root" => {
                i += 1;
                if i < args.len() {
                    repo_root = Some(PathBuf::from(&args[i]));
                }
            }
            "--arsenal-json" => {
                i += 1;
                if i < args.len() {
                    arsenal_json = Some(PathBuf::from(&args[i]));
                }
            }
            other if keyword.is_none() => keyword = Some(other.to_string()),
            _ => {}
        }
        i += 1;
    }

    let Some(keyword) = keyword else {
        eprintln!(
            "Usage: chump source-resolve \"<capability keyword>\" [--repo-root <path>] [--arsenal-json <path>]"
        );
        return 2;
    };

    let repo_root = repo_root.unwrap_or_else(|| PathBuf::from("."));
    let arsenal_json =
        arsenal_json.unwrap_or_else(|| repo_root.join("docs/arsenal/GLOBAL_ARSENAL.json"));

    let resolution = resolve_sourcing(&keyword, &repo_root, &arsenal_json);

    println!(
        "[source-resolve] keyword=\"{keyword}\" verdict={}",
        resolution.verdict.as_str()
    );
    for receipt in &resolution.receipts {
        println!("  receipt: tier={} {}", receipt.tier, receipt.detail);
    }
    if matches!(resolution.verdict, SourcingVerdict::NotFound) {
        println!("  (no prior art found in repo, arsenal, or world — BUILD is warranted)");
    }

    0
}
