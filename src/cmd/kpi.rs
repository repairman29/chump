use anyhow::Result;
use crate::{repo_path, kpi_report};
use std::io::Write;

pub async fn run(args: &[String]) -> Result<()> {
    if args.get(1).map(String::as_str) == Some("kpi")
        && args.get(2).map(String::as_str) == Some("report")
    {
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let window_days = flag("--tokens-per-ship")
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(7);
        let want_json = args.iter().any(|a| a == "--json");
        let want_pdf = args.iter().any(|a| a == "--pdf");
        let only_tokens = args.iter().any(|a| a == "--tokens-per-ship");
        let want_impact = args.iter().any(|a| a == "--impact");
        let want_agents = args.iter().any(|a| a == "--agents");

        let repo_root = repo_path::repo_root();

        // FLEET-048: --impact shows gap impact ratings section only.
        if want_impact {
            let section = kpi_report::build_impact_section(&repo_root);
            if want_json {
                println!("{}", section.render_json());
            } else {
                print!("{}", section.render_text());
            }
            return Ok(());
        }

        // FLEET-044: --agents shows per-agent throughput from .chump/metrics/.
        if want_agents {
            let date_arg = flag("--date");
            let section =
                kpi_report::build_agent_throughput_section(&repo_root, date_arg.as_deref());
            if want_json {
                println!("{}", section.render_json());
            } else {
                print!("{}", section.render_text());
            }
            return Ok(());
        }

        if only_tokens {
            // Backward-compat: only the tokens-per-ship section.
            let report = kpi_report::build_report(&repo_root, window_days);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
        } else {
            let report = kpi_report::build_full_report(&repo_root, window_days);
            let output = if want_json {
                report.render_json()
            } else {
                report.render_text()
            };

            if want_pdf {
                // Pipe markdown through pandoc for a grant-ready PDF.
                let md = report.render_text();
                let mut child = match std::process::Command::new("pandoc")
                    .args(["-f", "markdown", "-o", "chump-kpi-report.pdf"])
                    .stdin(std::process::Stdio::piped())
                    .spawn()
                {
                    Ok(c) => c,
                    Err(e) => {
                        eprintln!("chump kpi report: --pdf requested but pandoc not found: {e}");
                        eprintln!("Falling back to stdout:");
                        print!("{output}");
                        return Ok(());
                    }
                };
                if let Some(mut stdin) = child.stdin.take() {
                    let _ = stdin.write_all(md.as_bytes());
                }
                let _ = child.wait();
                println!("Wrote chump-kpi-report.pdf");
            } else {
                print!("{output}");
            }
        }
        return Ok(());
    }
    Ok(())
}
