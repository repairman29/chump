use anyhow::Result;
use crate::{repo_path, pr_explain, pr_fix_clippy, pr_triage, pr_ac_coverage, pr_rescue, paramedic};

pub async fn run(args: &[String]) -> Result<()> {
    let repo_root = repo_path::repo_root();

    // `chump pr-rescue` (INFRA-1714)
    if args.get(1).map(String::as_str) == Some("pr-rescue") {
        let mut once = false;
        let mut dry_run = false;
        let mut pr: Option<u32> = None;
        let mut explain: Option<u32> = None;
        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--once" => once = true,
                "--dry-run" => dry_run = true,
                "--pr" => {
                    i += 1;
                    if i < args.len() {
                        pr = args[i].parse().ok();
                    }
                }
                "--explain" => {
                    i += 1;
                    if i < args.len() {
                        explain = args[i].parse().ok();
                    }
                }
                "--help" | "-h" => {
                    println!("chump pr-rescue [--once] [--pr N] [--dry-run] [--explain N]");
                    return Ok(());
                }
                _ => {}
            }
            i += 1;
        }

        if let Some(n) = explain {
            let config = pr_rescue::RescueConfig {
                dry_run: true,
                repo_root: repo_root.clone(),
            };
            pr_rescue::explain(n, &config);
            return Ok(());
        }

        let config = pr_rescue::RescueConfig {
            dry_run,
            repo_root,
        };
        if once {
            pr_rescue::run_once(pr, &config);
        } else {
            pr_rescue::run_loop(&config);
        }
        return Ok(());
    }

    // `chump paramedic` (INFRA-1375)
    if args.get(1).map(String::as_str) == Some("paramedic") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
        let dry_run = args.iter().any(|a| a == "--dry-run");
        if subcmd == "help" || args.iter().any(|a| a == "--help") {
            println!("Usage: chump paramedic <triage|execute|daemon> [options]");
            return Ok(());
        }
        let interval_secs = args.iter()
            .position(|a| a == "--interval-secs")
            .and_then(|i| args.get(i + 1))
            .and_then(|v| v.parse().ok())
            .unwrap_or(600);
        let budget_secs = args.iter()
            .position(|a| a == "--budget-secs")
            .and_then(|i| args.get(i + 1))
            .and_then(|v| v.parse().ok())
            .unwrap_or(900);
        let plan_file = args.iter()
            .position(|a| a == "--plan")
            .and_then(|i| args.get(i + 1))
            .cloned();

        let cfg = paramedic::ParamedicConfig {
            dry_run,
            interval_secs,
            budget_secs,
            repo_root,
        };

        match subcmd {
            "triage" => {
                let report = paramedic::run_triage(&cfg)?;
                println!("{}", serde_json::to_string_pretty(&report)?);
            }
            "execute" => {
                paramedic::run_execute(&cfg, plan_file.as_deref())?;
            }
            "daemon" => {
                paramedic::run_daemon(&cfg)?;
            }
            _ => {
                eprintln!("chump paramedic: unknown subcommand '{}'", subcmd);
                std::process::exit(2);
            }
        }
        return Ok(());
    }

    // `chump pr` subcommands
    if args.get(1).map(String::as_str) == Some("pr") {
        let sub = args.get(2).map(String::as_str).unwrap_or("help");
        match sub {
            "explain-block" => {
                let pr_number: u64 = args.get(3).and_then(|s| s.parse().ok()).expect("PR# required");
                let json_out = args.iter().any(|a| a == "--json");
                pr_explain::run(pr_number, json_out)?;
            }
            "fix-clippy" => {
                let pr_number: u64 = args.get(3).and_then(|s| s.parse().ok()).expect("PR# required");
                let dry_run = args.iter().any(|a| a == "--dry-run");
                let r = pr_fix_clippy::fix_clippy(pr_number, &repo_root, dry_run)?;
                if !r.dry_run {
                    println!("chump pr fix-clippy: PR #{} fixed", r.pr_number);
                }
            }
            "triage" => {
                let opts = pr_triage::TriageOptions {
                    rerun_flakes: args.iter().any(|a| a == "--rerun-flakes"),
                    rebase_dirty: args.iter().any(|a| a == "--rebase-dirty"),
                    json: args.iter().any(|a| a == "--json"),
                };
                let report = pr_triage::run_triage(&opts)?;
                if opts.json {
                    print!("{}", pr_triage::render_json(&report));
                } else {
                    print!("{}", pr_triage::render_text(&report));
                }
            }
            "ac-coverage" => {
                let pr_number: u64 = args.get(3).and_then(|s| s.parse().ok()).expect("PR# required");
                let result = pr_ac_coverage::run(pr_number)?;
                println!("{}", pr_ac_coverage::render_json(&result));
                if result.status == pr_ac_coverage::CoverageStatus::Miss
                    && std::env::var("CHUMP_AC_GATE_ADVISORY").as_deref() != Ok("true")
                {
                    std::process::exit(1);
                }
            }
            _ => {
                println!("Usage: chump pr <explain-block|fix-clippy|triage|ac-coverage> [args]");
            }
        }
        return Ok(());
    }

    Ok(())
}
