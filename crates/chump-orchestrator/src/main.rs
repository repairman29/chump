//! chump-orchestrator binary — AUTO-013 MVP steps 1+2+3.
//!
//! Usage:
//!   chump-orchestrator [--backlog PATH] [--max-parallel N] [--dry-run|--no-dry-run]
//!                      [--repo-root PATH] [--base-ref REF] [--watch]
//!
//! Defaults: --backlog docs/gaps.yaml --max-parallel 2 --dry-run.
//! `--dry-run` prints WOULD DISPATCH lines (step 1 behaviour).
//! `--no-dry-run` (a.k.a. --execute) actually spawns `claude` subprocesses
//! per gap via `dispatch::dispatch_gap`. Without `--watch`, the orchestrator
//! returns immediately after spawn (step 2 behaviour). With `--watch`
//! (step 3), it runs the [`monitor`](chump_orchestrator::monitor) loop and
//! prints a summary table when every dispatched subagent reaches a terminal
//! outcome.

use anyhow::{bail, Context, Result};
use chump_orchestrator::dispatch::{dispatch_gap, dispatch_paths, DispatchHandle};
use chump_orchestrator::monitor::{default_monitor, watch_entries, DispatchOutcome};
use chump_orchestrator::reflect::{NoopReflectionWriter, ReflectionWriter, SqliteReflectionWriter};
use chump_orchestrator::self_test::run_self_test;
use chump_orchestrator::{done_ids, load_gaps, pickable_gaps};
use std::collections::HashMap;
use std::path::PathBuf;

struct Args {
    backlog: PathBuf,
    max_parallel: usize,
    dry_run: bool,
    repo_root: Option<PathBuf>,
    base_ref: String,
    watch: bool,
    /// AUTO-013 step 4: when true, skip writing dispatch reflections.
    /// Default false (writes go to `<repo_root>/sessions/chump_memory.db`).
    no_reflect: bool,
    /// AUTO-013 step 5: when true, run the in-process synthetic E2E smoke
    /// against `docs/test-fixtures/synthetic-backlog.yaml` and exit. Lets a
    /// human verify the orchestrator loop without spending real cloud calls.
    self_test: bool,
}

fn parse_args() -> Result<Args> {
    let mut backlog = PathBuf::from("docs/gaps.yaml");
    let mut max_parallel: usize = 2;
    let mut dry_run = true;
    let mut repo_root: Option<PathBuf> = None;
    let mut base_ref = String::from("origin/main");
    let mut watch = false;
    let mut no_reflect = false;
    let mut self_test = false;

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
            "--watch" | "--blocking" => watch = true,
            "--no-reflect" => no_reflect = true,
            "--self-test" => self_test = true,
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
                     \x20                  [--dry-run | --no-dry-run] [--watch]\n\
                     \x20                  [--repo-root PATH] [--base-ref REF]\n\
                     \n\
                     --dry-run (default):  print WOULD DISPATCH lines, no subprocess.\n\
                     --no-dry-run:         actually spawn `claude` subprocesses per gap.\n\
                     --watch:              after dispatch, run the monitor loop until\n\
                     \x20                    every subagent reaches a terminal outcome.\n\
                     --no-reflect:         skip writing per-outcome reflections to\n\
                     \x20                    sessions/chump_memory.db (test/dry-run only).\n\
                     --self-test:          run in-process synthetic 4-gap E2E (no\n\
                     \x20                    real claude/gh calls) and exit. Step-5 smoke.\n\
                     \n\
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
        watch,
        no_reflect,
        self_test,
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

    if args.self_test {
        // AUTO-013 step 5: in-process synthetic E2E. No real claude/gh calls.
        // The fixture lives at <repo_root>/docs/test-fixtures/synthetic-backlog.yaml.
        let repo_root = resolve_repo_root(args.repo_root.clone())?;
        let backlog = repo_root.join("docs/test-fixtures/synthetic-backlog.yaml");
        let scratch = std::env::temp_dir().join(format!(
            "chump-orchestrator-self-test-{}",
            std::process::id()
        ));
        eprintln!(
            "[orchestrator] --self-test: backlog={} scratch={}",
            backlog.display(),
            scratch.display()
        );
        let report = run_self_test(&backlog, scratch.clone(), args.max_parallel)?;
        // Snapshot pass/fail BEFORE we clean up the scratch dir — `passed()`
        // does an `exists()` check on the dummy files and would flip to
        // false the moment we remove them.
        let passed = report.passed();
        println!(
            "self-test {verdict}: rows={n_rows} reflections={n_refl} dummy_files={n_dummy} elapsed={ms}ms",
            verdict = if passed { "PASSED" } else { "FAILED" },
            n_rows = report.rows.len(),
            n_refl = report.reflections.len(),
            n_dummy = report.dummy_files.len(),
            ms = report.elapsed.as_millis(),
        );
        for row in &report.rows {
            println!(
                "  {gap:12} {branch:30} {outcome:?}",
                gap = row.gap_id,
                branch = row.branch,
                outcome = row.outcome
            );
        }
        let _ = std::fs::remove_dir_all(&scratch);
        if !passed {
            bail!("self-test acceptance criteria not met");
        }
        return Ok(());
    }

    let all = load_gaps(&args.backlog)?;
    let done = done_ids(&all);
    let open_count = all.iter().filter(|g| g.status == "open").count();
    let picked = pickable_gaps(&all, args.max_parallel, &done);

    let mode = if args.dry_run {
        "dry-run"
    } else if args.watch {
        "execute+watch"
    } else {
        "execute"
    };
    println!(
        "chump-orchestrator (MVP complete, {mode}): {} total gaps, {} open, {} done; would dispatch {} of max-parallel {}",
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
    let mut handles: Vec<DispatchHandle> = Vec::with_capacity(picked.len());
    let mut efforts: HashMap<String, String> = HashMap::new();
    for gap in &picked {
        efforts.insert(gap.id.clone(), gap.effort.clone());
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
                handles.push(handle);
            }
            Err(e) => {
                spawn_failures += 1;
                eprintln!("DISPATCH-FAILED: {gid}: {e:#}", gid = gap.id);
            }
        }
    }

    if !args.watch {
        // Step-2 semantics: drop handles, exit. The OS reaps the children
        // when the orchestrator exits; the monitor loop is opt-in.
        drop(handles);
        if spawn_failures > 0 {
            bail!("{spawn_failures} of {} dispatches failed", picked.len());
        }
        return Ok(());
    }

    // --watch (step 3): run the monitor until every dispatched subagent
    // reaches a terminal outcome, then print a summary table.
    let entries = watch_entries(handles, &efforts);
    let writer: Box<dyn ReflectionWriter> = if args.no_reflect {
        eprintln!("[orchestrator] --no-reflect set: skipping reflection writes.");
        Box::new(NoopReflectionWriter)
    } else {
        let w = SqliteReflectionWriter::for_repo(&repo_root);
        eprintln!(
            "[orchestrator] reflection writes will land in {}/sessions/chump_memory.db",
            repo_root.display()
        );
        Box::new(w)
    };
    let monitor = default_monitor(entries, &repo_root).with_reflection_writer(writer);
    let runtime = tokio::runtime::Runtime::new().context("building tokio runtime")?;
    let outcomes = runtime.block_on(monitor.watch_until_done());

    println!("\n=== monitor summary ({} entries) ===", outcomes.len());
    let mut shipped = 0usize;
    let mut killed = 0usize;
    let mut stalled = 0usize;
    let mut ci_failed = 0usize;
    for (branch, outcome) in &outcomes {
        match outcome {
            DispatchOutcome::Shipped(n) => {
                shipped += 1;
                println!("  SHIPPED   {branch}  PR #{n}");
            }
            DispatchOutcome::Stalled => {
                stalled += 1;
                println!("  STALLED   {branch}  (no PR within soft deadline)");
            }
            DispatchOutcome::Killed(reason) => {
                killed += 1;
                println!("  KILLED    {branch}  {reason}");
            }
            DispatchOutcome::CiFailed(n) => {
                ci_failed += 1;
                println!("  CI-FAILED {branch}  PR #{n}");
            }
        }
    }
    println!(
        "shipped={shipped}  ci_failed={ci_failed}  stalled={stalled}  killed={killed}  spawn_failures={spawn_failures}"
    );

    if spawn_failures > 0 {
        bail!(
            "{spawn_failures} of {} dispatches failed at spawn time",
            picked.len()
        );
    }
    Ok(())
}
