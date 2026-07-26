use anyhow::Result;
use crate::{repo_path, cost_tracker, cost_watch, cost_ledger};

pub async fn run(args: &[String]) -> Result<()> {
    // `chump cost record-pr`
    if args.get(1).map(String::as_str) == Some("cost")
        && args.get(2).map(String::as_str) == Some("record-pr")
    {
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };

        let pr_number = match flag("--pr").and_then(|s| s.parse::<i64>().ok()) {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump cost record-pr --pr N --gap GAP --model MODEL");
                eprintln!("                             [--tokens-in I] [--tokens-out O]");
                eprintln!(
                    "                             [--usd U] [--duration-secs D] [--backend B]"
                );
                std::process::exit(2);
            }
        };

        let gap_id = flag("--gap").unwrap_or_else(|| "unknown".to_string());
        let model = flag("--model").unwrap_or_else(|| "unknown".to_string());
        let tokens_in = flag("--tokens-in")
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        let tokens_out = flag("--tokens-out")
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        let usd_cost = flag("--usd")
            .and_then(|s| s.parse::<f64>().ok())
            .unwrap_or(0.0);
        let duration_secs = flag("--duration-secs")
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        let backend = flag("--backend").unwrap_or_else(|| "unknown".to_string());

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;

        let repo_root = repo_path::repo_root();
        let record = cost_tracker::PrCostRecord {
            pr_number,
            gap_id,
            model,
            tokens_in,
            tokens_out,
            usd_cost,
            duration_secs,
            shipped_at: now,
            backend,
        };

        match cost_tracker::record_pr_cost(&repo_root, &record) {
            Ok(()) => {
                println!("recorded PR {} cost metrics", pr_number);
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump cost record-pr: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump cost-watch`
    if args.get(1).map(String::as_str) == Some("cost-watch") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump cost-watch [--budget USD] [--hard-cap] [--json]");
            println!();
            println!("Real-time inference spend and per-slot breakdown. Reads cost records");
            println!("written by 'chump cost record-pr'. Compares against daily budget.");
            println!();
            println!("Options:");
            println!(
                "  --budget USD   daily budget in USD  [default: $5.00 or CHUMP_DAILY_BUDGET]"
            );
            println!("  --hard-cap     exit 1 if today's spend exceeds budget");
            println!("  --json         output in JSON format");
            println!();
            println!("Example:");
            println!("  chump cost-watch");
            println!("  chump cost-watch --budget 10.0 --hard-cap");
            return Ok(());
        }
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let budget_usd = flag("--budget")
            .and_then(|s| s.parse::<f64>().ok())
            .or_else(|| {
                std::env::var("CHUMP_DAILY_BUDGET")
                    .ok()
                    .and_then(|s| s.parse::<f64>().ok())
            })
            .unwrap_or(5.0);
        let hard_cap = args.iter().any(|a| a == "--hard-cap");
        let want_json = args.iter().any(|a| a == "--json");

        let repo_root = repo_path::repo_root();
        let report = cost_watch::build_report(&repo_root, budget_usd);

        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }

        if hard_cap && report.over_budget {
            eprintln!(
                "chump cost-watch: 🔴 hard-cap triggered — today's spend ${:.4} exceeds budget ${:.2}/day",
                report.today_spend_usd, budget_usd
            );
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump cost-check`
    if args.get(1).map(String::as_str) == Some("cost-check") {
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let gap_id = flag("--gap-id").unwrap_or_else(|| "unknown".to_string());
        let model = flag("--model").unwrap_or_else(|| "unknown".to_string());
        let repo_root = repo_path::repo_root();
        let status = cost_ledger::check_quota(&repo_root, &gap_id, &model, true);
        let pct = status.budget_used_pct();
        let label = status.label();
        match &status {
            cost_ledger::QuotaStatus::Exceeded {
                spend_usd,
                budget_usd,
                ..
            } => {
                eprintln!(
                    "chump cost-check: EXCEEDED  ${:.4} of ${:.2} ({:.1}%)",
                    spend_usd, budget_usd, pct
                );
                std::process::exit(2);
            }
            cost_ledger::QuotaStatus::Warning {
                spend_usd,
                budget_usd,
                ..
            } => {
                eprintln!(
                    "chump cost-check: WARNING   ${:.4} of ${:.2} ({:.1}%)",
                    spend_usd, budget_usd, pct
                );
                std::process::exit(1);
            }
            cost_ledger::QuotaStatus::Ok {
                spend_usd,
                budget_usd,
                ..
            } => {
                eprintln!(
                    "chump cost-check: ok        ${:.4} of ${:.2} ({:.1}%)",
                    spend_usd, budget_usd, pct
                );
            }
        }
        eprintln!("chump cost-check: status={label}  budget_used_pct={pct:.1}%");
        return Ok(());
    }

    Ok(())
}
