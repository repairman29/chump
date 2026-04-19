//! chump-orchestrator binary — AUTO-013 MVP steps 1+2.
//!
//! Usage:
//!   chump-orchestrator [--backlog PATH] [--max-parallel N] [--dry-run|--no-dry-run]
//!                      [--repo-root PATH] [--base-ref REF]
//!
//! Defaults: --backlog docs/gaps.yaml --max-parallel 2 --dry-run.
//! `--dry-run` prints WOULD DISPATCH lines (step 1 behaviour).
//! `--no-dry-run` (a.k.a. --execute) actually spawns `claude` subprocesses
//! per gap via `dispatch::dispatch_gap`. The orchestrator returns immediately
//! after spawn — the monitor loop that waits for outcomes is step 3.

use anyhow::{bail, Context, Result};
use chump_orchestrator::dispatch::{dispatch_gap, dispatch_paths};
use chump_orchestrator::{done_ids, load_gaps, pickable_gaps};
use std::path::PathBuf;

struct Args {
    backlog: PathBuf,
    max_parallel: usize,
    dry_run: bool,
    repo_root: Option<PathBuf>,
    base_ref: String,
}

fn parse_args() -> Result<Args> {
    let mut backlog = PathBuf::from("docs/gaps.yaml");
    let mut max_parallel: usize = 2;
    let mut dry_run = true;
    let mut repo_root: Option<PathBuf> = None;
    let mut base_ref = String::from("origin/main");

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
            "--no-dry-run" | "--execute" => dry_run = false,
            "--repo-root" => {
                repo_root =
                    Some(PathBuf::from(iter.next().ok_or_else(|| {
                        anyhow::anyhow!("--repo-root requires a path")
                    })?));
            }
            "--base-ref" => {
                base_ref = iter
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--base-ref requires a ref"))?;
            }
            "-h" | "--help" => {
                println!(
                    "chump-orchestrator [--backlog PATH] [--max-parallel N]\n\
                     \x20                  [--dry-run | --no-dry-run]\n\
                     \x20                  [--repo-root PATH] [--base-ref REF]\n\
                     \n\
                     --dry-run (default):  print WOULD DISPATCH lines, no subprocess.\n\
                     --no-dry-run:         actually spawn `claude` subprocesses per gap.\n\
                     \n\
                     Step 2 only spawns and returns; monitor loop is step 3.\n\
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
        repo_root,
        base_ref,
    })
}

/// Best-effort repo-root resolution. Caller may override via --repo-root;
/// otherwise we ask git.
fn resolve_repo_root(explicit: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(p) = explicit {
        return Ok(p);
    }
    let out = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .context("running git rev-parse --show-toplevel")?;
    if !out.status.success() {
        bail!("git rev-parse --show-toplevel failed; pass --repo-root explicitly");
    }
    let s = String::from_utf8(out.stdout).context("git rev-parse output not utf-8")?;
    Ok(PathBuf::from(s.trim()))
}

fn main() -> Result<()> {
    let args = parse_args()?;

    let all = load_gaps(&args.backlog)?;
    let done = done_ids(&all);
    let open_count = all.iter().filter(|g| g.status == "open").count();
    let picked = pickable_gaps(&all, args.max_parallel, &done);

    let mode = if args.dry_run { "dry-run" } else { "execute" };
    println!(
        "chump-orchestrator (MVP step 2, {mode}): {} total gaps, {} open, {} done; would dispatch {} of max-parallel {}",
        all.len(),
        open_count,
        done.len(),
        picked.len(),
        args.max_parallel,
    );

    if picked.is_empty() {
        eprintln!("note: no pickable gaps. Either backlog is exhausted or all open P1/P2 gaps are XL or dependency-blocked.");
        return Ok(());
    }

    if args.dry_run {
        for gap in &picked {
            // Use the same path-derivation as the dispatcher so the dry-run
            // line matches what `--no-dry-run` would actually create.
            let (wt, _branch) = dispatch_paths(std::path::Path::new("."), &gap.id);
            println!(
                "WOULD DISPATCH: {gid} (prio={prio} effort={eff}) in {wt}  -- {title}",
                gid = gap.id,
                prio = gap.priority,
                eff = gap.effort,
                wt = wt.display(),
                title = gap.title,
            );
        }
        return Ok(());
    }

    // --no-dry-run: actually spawn.
    let repo_root = resolve_repo_root(args.repo_root)?;
    let mut spawn_failures = 0usize;
    for gap in &picked {
        match dispatch_gap(gap, &repo_root, &args.base_ref) {
            Ok(handle) => {
                let pid = handle
                    .child_pid
                    .map(|p| p.to_string())
                    .unwrap_or_else(|| "<no-pid>".to_string());
                println!(
                    "DISPATCHED: {gid} in {wt} as PID {pid}",
                    gid = handle.gap_id,
                    wt = handle.worktree_path.display(),
                );
                // Drop the handle. `std::process::Child::drop` does NOT kill
                // the child — it just doesn't reap it. The OS handles cleanup
                // when the orchestrator exits. The monitor loop that takes
                // ownership lands in step 3.
                drop(handle);
            }
            Err(e) => {
                spawn_failures += 1;
                eprintln!("DISPATCH-FAILED: {gid}: {e:#}", gid = gap.id);
            }
        }
    }

    if spawn_failures > 0 {
        bail!("{spawn_failures} of {} dispatches failed", picked.len());
    }
    Ok(())
}
