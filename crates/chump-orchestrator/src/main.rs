//! chump-orchestrator binary — AUTO-013 MVP step 1 (dry-run picker only).
//!
//! Usage:
//!   chump-orchestrator [--backlog PATH] [--max-parallel N] [--dry-run]
//!
//! Defaults: --backlog docs/gaps.yaml --max-parallel 2 --dry-run (the only
//! supported mode in this MVP). Subprocess spawn lands in step 2.

use anyhow::{bail, Result};
use chump_orchestrator::{done_ids, load_gaps, pickable_gaps};
use std::path::PathBuf;

struct Args {
    backlog: PathBuf,
    max_parallel: usize,
    dry_run: bool,
}

fn parse_args() -> Result<Args> {
    let mut backlog = PathBuf::from("docs/gaps.yaml");
    let mut max_parallel: usize = 2;
    let mut dry_run = true;

    let mut iter = std::env::args().skip(1);
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--backlog" => {
                backlog = PathBuf::from(
                    iter.next()
                        .ok_or_else(|| anyhow::anyhow!("--backlog requires a path"))?,
                );
            }
            "--max-parallel" => {
                let v = iter
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--max-parallel requires N"))?;
                max_parallel = v.parse()?;
            }
            "--dry-run" => dry_run = true,
            "--no-dry-run" => dry_run = false,
            "-h" | "--help" => {
                println!(
                    "chump-orchestrator [--backlog PATH] [--max-parallel N] [--dry-run]\n\
                     \n\
                     MVP step 1: reads gaps.yaml, prints WOULD DISPATCH lines for\n\
                     gaps it would dispatch. Subprocess spawn lands in step 2.\n\
                     See docs/AUTO-013-ORCHESTRATOR-DESIGN.md."
                );
                std::process::exit(0);
            }
            other => bail!("unknown argument: {other} (try --help)"),
        }
    }

    Ok(Args {
        backlog,
        max_parallel,
        dry_run,
    })
}

fn main() -> Result<()> {
    let args = parse_args()?;

    if !args.dry_run {
        bail!("--no-dry-run requested but subprocess spawn is not implemented in MVP step 1. See docs/AUTO-013-ORCHESTRATOR-DESIGN.md.");
    }

    let all = load_gaps(&args.backlog)?;
    let done = done_ids(&all);
    let open_count = all.iter().filter(|g| g.status == "open").count();
    let picked = pickable_gaps(&all, args.max_parallel, &done);

    println!(
        "chump-orchestrator (MVP step 1, dry-run): {} total gaps, {} open, {} done; would dispatch {} of max-parallel {}",
        all.len(),
        open_count,
        done.len(),
        picked.len(),
        args.max_parallel,
    );

    for (i, gap) in picked.iter().enumerate() {
        let worktree = format!(
            ".claude/worktrees/{}",
            gap.id.to_ascii_lowercase().replace('_', "-")
        );
        println!(
            "WOULD DISPATCH: {gid} (prio={prio} effort={eff}) in {wt}  -- {title}",
            gid = gap.id,
            prio = gap.priority,
            eff = gap.effort,
            wt = worktree,
            title = gap.title,
        );
        let _ = i;
    }

    if picked.is_empty() {
        eprintln!("note: no pickable gaps. Either backlog is exhausted or all open P1/P2 gaps are XL or dependency-blocked.");
    }

    Ok(())
}
