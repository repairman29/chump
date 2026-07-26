use anyhow::{Context, Result};
use crate::{repo_path, dispatch as dispatch_mod};
use chump_gap_store as gap_store;
use chump_orchestrator::dispatch as orchestrator_dispatch;

pub async fn run(args: &[String]) -> Result<()> {
    if args.get(1).map(String::as_str) != Some("dispatch") {
        return Ok(());
    }

    let subcmd = args.get(2).map(String::as_str).unwrap_or("");
    let repo_root = repo_path::repo_root();

    if subcmd == "route" {
        let gap_id = match args.get(3) {
            Some(s) if !s.is_empty() => s.clone(),
            _ => {
                eprintln!("Usage: chump dispatch route <GAP-ID>");
                std::process::exit(2);
            }
        };
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump dispatch route: cannot open state.db: {e:#}");
                std::process::exit(1);
            }
        };
        let row = match store.get(&gap_id) {
            Ok(Some(r)) => r,
            Ok(None) => {
                eprintln!("chump dispatch route: gap {gap_id} not found in .chump/state.db");
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("chump dispatch route: lookup failed: {e:#}");
                std::process::exit(1);
            }
        };
        let task_class = orchestrator_dispatch::task_class_for_gap_id(&row.id);
        let cands = orchestrator_dispatch::select_candidates_for_gap(
            &repo_root,
            &row.id,
            &row.priority,
            &row.effort,
        );
        println!("GAP        : {}", row.id);
        println!("priority   : {}", row.priority);
        println!("effort     : {}", row.effort);
        println!("task_class : {}", task_class.unwrap_or("-"));
        println!();
        println!(
            "{:<3}{:<14}{:<53}{:<10}why",
            "#", "backend", "model", "provider"
        );
        for (i, c) in cands.iter().enumerate() {
            println!(
                "{:<3}{:<14}{:<53}{:<10}{}",
                i + 1,
                c.backend.label(),
                c.model.as_deref().unwrap_or("-"),
                c.provider_pfx.as_deref().unwrap_or("-"),
                c.why,
            );
        }
        return Ok(());
    }

    if subcmd == "scoreboard" {
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump dispatch scoreboard: cannot open state.db: {e:#}");
                std::process::exit(1);
            }
        };
        let entries = match store.routing_scoreboard() {
            Ok(v) => v,
            Err(e) => {
                eprintln!("chump dispatch scoreboard: query failed: {e:#}");
                std::process::exit(1);
            }
        };
        if entries.is_empty() {
            println!("No routing outcomes recorded yet.");
            return Ok(());
        }
        println!(
            "{:<10}{:<14}{:<40}{:<10}{:>6}{:>6}{:>8}{:>10}{:>8}{:>20}",
            "class",
            "backend",
            "model",
            "provider",
            "succ",
            "fail",
            "rate%",
            "avg_cost",
            "score",
            "last_seen"
        );
        for e in &entries {
            println!(
                "{:<10}{:<14}{:<40}{:<10}{:>6}{:>6}{:>7.1}%{:>9.4}${:>7.2} {:>20}",
                if e.task_class.is_empty() {
                    "-"
                } else {
                    &e.task_class
                },
                e.backend,
                if e.model.is_empty() { "-" } else { &e.model },
                if e.provider_pfx.is_empty() {
                    "-"
                } else {
                    &e.provider_pfx
                },
                e.successes,
                e.failures,
                e.success_rate * 100.0,
                e.avg_cost_usd,
                e.route_score,
                e.last_seen
            );
        }
        return Ok(());
    }

    if subcmd == "simulate" {
        let task_class_arg = match args.get(3) {
            Some(s) if !s.is_empty() => s.clone(),
            _ => {
                eprintln!("Usage: chump dispatch simulate <task_class> <count>");
                eprintln!("  task_class: research | dispatch | - (no class)");
                std::process::exit(2);
            }
        };
        let count: usize = match args.get(4).and_then(|s| s.parse().ok()) {
            Some(n) if n > 0 => n,
            _ => {
                eprintln!("Usage: chump dispatch simulate <task_class> <count>");
                eprintln!("  count must be a positive integer");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
        let synthetic_gap_id = match task_class_arg.as_str() {
            "research" => "EVAL-SIM-COG-037",
            _ => "INFRA-SIM-COG-037",
        };
        let priority = "P2";
        let effort = "m";
        let seed: u64 = std::env::var("CHUMP_SIMULATE_SEED")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(42);

        let report = orchestrator_dispatch::simulate_cascade_usage(
            &repo_root,
            synthetic_gap_id,
            priority,
            effort,
            count,
            seed,
        );
        println!("{}", report.render_text());
        return Ok(());
    }

    // Core dispatch logic
    let DISPATCH_SUBCOMMANDS: &[&str] = &["route", "scoreboard", "simulate", "cost-report"];
    if !DISPATCH_SUBCOMMANDS.contains(&subcmd) {
        let gap_id = match args.get(2) {
            Some(g) if !g.starts_with('-') => g.clone(),
            _ => {
                eprintln!(
                    "Usage: chump dispatch <GAP-ID> [--auto-merge] [--skip-tests] [--paths X,Y] [--backend BACKEND] [--model M] [--prompt P]"
                );
                std::process::exit(2);
            }
        };
        let auto_merge = args.iter().any(|a| a == "--auto-merge");
        let skip_tests = args.iter().any(|a| a == "--skip-tests");
        let paths = args
            .iter()
            .position(|a| a == "--paths")
            .and_then(|i| args.get(i + 1))
            .cloned();
        let backend = args
            .iter()
            .position(|a| a == "--backend")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .or_else(|| std::env::var("CHUMP_DISPATCH_BACKEND").ok())
            .unwrap_or_else(|| "interactive".into());
        let model = args
            .iter()
            .position(|a| a == "--model")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_default();
        let prompt = args
            .iter()
            .position(|a| a == "--prompt")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_default();
        let work = match backend.as_str() {
            "interactive" | "claude" /* alias */ => dispatch_mod::WorkBackend::Interactive,
            "headless" => dispatch_mod::WorkBackend::Headless {
                model: model.clone(),
                prompt: prompt.clone(),
            },
            "exec-gap" | "chump-local" /* alias */ => dispatch_mod::WorkBackend::ExecGap,
            other => {
                eprintln!(
                    "chump dispatch: unknown --backend {other:?}; expected one of: interactive, headless, exec-gap"
                );
                std::process::exit(2);
            }
        };
        let opts = dispatch_mod::DispatchOptions {
            gap_id: &gap_id,
            work,
            auto_merge,
            skip_tests,
            paths: paths.as_deref(),
            repo_root: repo_root.clone(),
        };
        match dispatch_mod::run(opts) {
            Ok(outcome) => {
                println!(
                    "[dispatch] {} branch={} duration={}s",
                    outcome.gap_id, outcome.branch, outcome.duration_secs
                );
                match outcome.result {
                    dispatch_mod::ShipResult::Shipped { pr_number } => {
                        println!("[dispatch] shipped PR #{pr_number}");
                        return Ok(());
                    }
                    dispatch_mod::ShipResult::Blocked { reason } => {
                        eprintln!("[dispatch] blocked: {reason}");
                        std::process::exit(1);
                    }
                    dispatch_mod::ShipResult::Aborted { error } => {
                        eprintln!("[dispatch] aborted: {error}");
                        std::process::exit(1);
                    }
                }
            }
            Err(e) => {
                eprintln!("[dispatch] failed: {e:#}");
                std::process::exit(1);
            }
        }
    }

    Ok(())
}
