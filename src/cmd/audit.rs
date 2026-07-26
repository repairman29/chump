use anyhow::Result;
use crate::{repo_path, ingest_librarian, audit as audit_mod};
use serde_json;

pub async fn run(args: &[String]) -> Result<()> {
    if args.get(1).map(String::as_str) == Some("audit") {
        let sub = args.get(2).map(String::as_str).unwrap_or("--help");
        if sub == "--help" || sub == "help" || sub.is_empty() {
            println!("Usage: chump audit <subcommand> [options]");
            println!();
            println!("Subcommands:");
            println!(
                "  aha-sweep         walk code/runtime/effect triangle for every registered kind"
            );
            println!(
                "  librarian-sweep   dead-code + redundant-script triage for an ingest target repo"
            );
            println!();
            println!("Run 'chump audit <subcommand> --help' for options.");
            return Ok(());
        }
        if sub == "librarian-sweep" {
            let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
            if rest.is_empty() || rest.iter().any(|a| *a == "--help" || *a == "help") {
                println!(
                    "Usage: chump audit librarian-sweep <target-repo> [--budget-usd N] [--json]"
                );
                println!();
                println!(
                    "INFRA-1781 (INFRA-1746 phase 1b). Read-only static sweep of <target-repo>:"
                );
                println!("flags dead-code candidates (source stem never referenced elsewhere) and");
                println!(
                    "redundant scripts (byte-identical content under scripts/ or *.sh). Writes"
                );
                println!(
                    "<target-repo>/.chump-ingest/triage.md. Zero LLM/API calls (cost_usd_cents=0)."
                );
                println!();
                println!("Options:");
                println!("  --budget-usd N   accepted for interface parity with later ingest phases (default 10.0)");
                println!("  --json           output JSON instead of the markdown report");
                std::process::exit(if rest.is_empty() { 2 } else { 0 });
            }
            let want_json = rest.contains(&"--json");
            let budget_usd: f64 = {
                let mut it = rest.iter().peekable();
                let mut n = 10.0f64;
                while let Some(a) = it.next() {
                    if *a == "--budget-usd" {
                        if let Some(v) = it.next() {
                            if let Ok(parsed) = v.parse::<f64>() {
                                n = parsed;
                            }
                        }
                    }
                }
                n
            };
            let target_repo = std::path::PathBuf::from(rest[0]);
            let chump_repo_root = repo_path::repo_root();
            let cfg = ingest_librarian::LibrarianConfig {
                target_repo: target_repo.clone(),
                budget_usd,
            };
            ingest_librarian::emit_started(&chump_repo_root, &target_repo);
            let report = match ingest_librarian::run_sweep(&cfg) {
                Ok(r) => r,
                Err(e) => {
                    ingest_librarian::emit_failed(&chump_repo_root, &target_repo, &e);
                    eprintln!("chump audit librarian-sweep: {}", e);
                    std::process::exit(1);
                }
            };
            if let Err(e) = ingest_librarian::write_triage_report(&report) {
                ingest_librarian::emit_failed(&chump_repo_root, &target_repo, &e);
                eprintln!("chump audit librarian-sweep: {}", e);
                std::process::exit(1);
            }
            ingest_librarian::emit_completed(&chump_repo_root, &report);
            if want_json {
                println!(
                    "{}",
                    serde_json::json!({
                        "target_repo": report.target_repo.display().to_string(),
                        "files_scanned": report.files_scanned,
                        "dead_code_candidate_count": report.dead_code_candidates.len(),
                        "redundant_script_group_count": report.redundant_scripts.len(),
                        "cost_usd_cents": report.cost_usd_cents,
                        "elapsed_ms": report.elapsed_ms,
                        "truncated": report.truncated,
                    })
                );
            } else {
                print!("{}", ingest_librarian::render_markdown(&report));
                println!(
                    "triage report written to {}",
                    target_repo.join(".chump-ingest/triage.md").display()
                );
            }
            return Ok(());
        }
        if sub != "aha-sweep" {
            eprintln!("chump audit: unknown subcommand '{}'", sub);
            eprintln!("Run 'chump audit --help' for the list.");
            std::process::exit(2);
        }
        let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
        if rest.iter().any(|a| *a == "--help" || *a == "help") {
            println!("Usage: chump audit aha-sweep [--json] [--window-days N] [--flag-silent-self] [--emit]");
            println!();
            println!("Walks every kind in EVENT_REGISTRY.yaml and verifies the recent ambient");
            println!("stream actually contains emits consistent with the declared effect_metric +");
            println!("expected_min_per_day floor.");
            println!();
            println!("Options:");
            println!("  --json               output machine-readable JSON (INFRA-1371)");
            println!("  --window-days N      scan the last N days (default: 7)");
            println!("  --flag-silent-self   emit finding events for types with expected_min=0");
            println!("                       that haven't emitted recently (off by default)");
            println!("  --emit               emit kind=audit_finding for every non-ok kind");
            return Ok(());
        }

        let window_days = rest
            .iter()
            .position(|a| *a == "--window-days")
            .and_then(|i| rest.get(i + 1))
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(7);
        let want_json = rest.contains(&"--json");
        let flag_silent_self = rest.contains(&"--flag-silent-self");
        let should_emit = rest.contains(&"--emit");

        let repo_root = repo_path::repo_root();
        let config = audit_mod::SweepConfig {
            repo_root: repo_root.clone(),
            window: std::time::Duration::from_secs(window_days * 24 * 3600),
            flag_silent_self,
        };

        let findings = match audit_mod::sweep_event_registry(&config) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("chump audit aha-sweep failed: {e:#}");
                std::process::exit(1);
            }
        };
        if should_emit {
            let _ = audit_mod::emit_findings(&repo_root, &findings);
        }
        if want_json {
            println!("{}", audit_mod::render_json(&findings));
        } else {
            print!("{}", audit_mod::render_text(&findings));
        }
        let any_alert = findings
            .iter()
            .any(|f| f.severity == audit_mod::AuditSeverity::Alert);
        if any_alert {
            std::process::exit(1);
        }
        return Ok(());
    }

    Ok(())
}
