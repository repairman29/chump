//! Operations, health, audit, node, skill, outcome, and repo CLI subcommands.

#[allow(unused_imports)]
use super::*;
#[allow(unused_imports)]
use crate::*;
#[allow(unused_imports)]
use anyhow::{Context as _, Result};
#[allow(unused_imports)]
use axonerai::agent::Agent;
#[allow(unused_imports)]
use axonerai::file_session_manager::FileSessionManager;
#[allow(unused_imports)]
use axonerai::tool::ToolRegistry;
#[allow(unused_imports)]
use std::env;
#[allow(unused_imports)]
use std::io::{self, IsTerminal, Read, Write};

pub(crate) async fn dispatch_ops(args: Vec<String>) -> Result<()> {
    if args.get(1).map(String::as_str) == Some("completion") {
        let shell = args.get(2).map(String::as_str).unwrap_or("zsh");
        match shell {
            "zsh" => {
                print!("{}", completion::zsh());
                return Ok(());
            }
            "bash" => {
                print!("{}", completion::bash());
                return Ok(());
            }
            "fish" => {
                print!("{}", completion::fish());
                return Ok(());
            }
            other => {
                eprintln!("chump completion: unknown shell {other:?}");
                eprintln!("Usage: chump completion [zsh|bash|fish]");
                eprintln!();
                eprintln!("Install examples:");
                eprintln!("  zsh:  chump completion zsh > $(brew --prefix)/share/zsh/site-functions/_chump");
                eprintln!("  bash: chump completion bash >> ~/.bashrc");
                eprintln!("  fish: chump completion fish > ~/.config/fish/completions/chump.fish");
                std::process::exit(2);
            }
        }
    }

    // `chump lesson-grade <GAP-ID> --pr <N>` (COG-043) — for each
    // `lessons_shown` event tied to this gap+session in ambient.jsonl,
    // score the directive's keywords against the PR's diff + body and
    // emit `lesson_applied` / `lesson_not_applied` events. Best-effort:
    // missing PR or network errors degrade to no-op, never panic.
    //
    // Called from bot-merge.sh after auto-close. Operators can also
    // run it manually post-hoc on any closed PR.
    if args.get(1).map(String::as_str) == Some("lesson-grade") {
        let gap_id = args.get(2).cloned().unwrap_or_else(|| {
            eprintln!("Usage: chump lesson-grade <GAP-ID> --pr <N>");
            std::process::exit(2);
        });
        if gap_id.starts_with("--") {
            eprintln!("Usage: chump lesson-grade <GAP-ID> --pr <N>");
            std::process::exit(2);
        }
        let lg_flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1).cloned())
        };
        let pr_number: u64 = match lg_flag("--pr") {
            Some(s) => s.parse().unwrap_or_else(|_| {
                eprintln!("chump lesson-grade: --pr expects an integer (got {s:?})");
                std::process::exit(2);
            }),
            None => {
                eprintln!("Usage: chump lesson-grade <GAP-ID> --pr <N>");
                std::process::exit(2);
            }
        };
        let session_filter = lg_flag("--session"); // optional — defaults to all sessions for the gap
        let repo_root = repo_path::repo_root();
        let graded = run_lesson_grade(&repo_root, &gap_id, pr_number, session_filter.as_deref());
        match graded {
            Ok(counts) => {
                println!(
                    "lesson-grade {}: applied={} not_applied={} skipped={}",
                    gap_id, counts.0, counts.1, counts.2
                );
                return Ok(());
            }
            Err(e) => {
                // Best-effort — print the warning but exit 0 so we don't
                // break bot-merge.sh's auto-close flow.
                eprintln!("chump lesson-grade: warning: {e:#}");
                return Ok(());
            }
        }
    }

    // `chump audit aha-sweep [--json] [--window-days N] [--emit]` (INFRA-1370).
    // Walks every kind in EVENT_REGISTRY.yaml, reads its effect_metric +
    // expected_min_per_day declarations (INFRA-1371), and compares against the
    // last-N-days emit count in .chump-locks/ambient.jsonl. Surfaces "registered
    // but silent" kinds (alert) and "below floor" kinds (warn) as
    // kind=audit_finding events. Exit non-zero on any alert.
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
            println!("  query             query the per-action audit log (INFRA-1842, CP-010)");
            println!("  retention         delete audit_log rows older than a cutoff (INFRA-1842)");
            println!();
            println!("Run 'chump audit <subcommand> --help' for options.");
            return Ok(());
        }
        // `chump audit query [filters] [--json]` (INFRA-1842, CP-010) — queryable
        // per-action audit log. See docs/arsenal/cross-pollination/CP-010-beast-mode-audit-logger.md.
        if sub == "query" {
            let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
            if rest.iter().any(|a| *a == "--help" || *a == "help") {
                println!("Usage: chump audit query [filters] [--json]");
                println!();
                println!("Options:");
                println!("  --actor <id>          filter by actor (session id or login)");
                println!("  --action <name>        filter by action name (e.g. gap.shipped)");
                println!(
                    "  --resource <class>     filter by resource class (gap | pr | lease | config)"
                );
                println!(
                    "  --resource-id <id>     filter by specific resource id (e.g. INFRA-1842)"
                );
                println!("  --since <duration|iso> 24h | 7d | 1m | 0s | RFC-3339 timestamp");
                println!("  --until <duration|iso> same syntax as --since");
                println!("  --limit N              truncate result (default 100)");
                println!("  --json                 structured JSON output (default: pretty table)");
                return Ok(());
            }
            let want_json = rest.contains(&"--json");
            let mut filter = audit_log::QueryFilter::default();
            let mut it = rest.iter().peekable();
            while let Some(a) = it.next() {
                match *a {
                    "--actor" => filter.actor = it.next().map(|s| s.to_string()),
                    "--action" => filter.action = it.next().map(|s| s.to_string()),
                    "--resource" => filter.resource = it.next().map(|s| s.to_string()),
                    "--resource-id" => filter.resource_id = it.next().map(|s| s.to_string()),
                    "--since" => {
                        if let Some(v) = it.next() {
                            match audit_log::resolve_time_bound(v) {
                                Ok(ts) => filter.since = Some(ts),
                                Err(e) => {
                                    eprintln!("chump audit query: bad --since value: {e}");
                                    std::process::exit(2);
                                }
                            }
                        }
                    }
                    "--until" => {
                        if let Some(v) = it.next() {
                            match audit_log::resolve_time_bound(v) {
                                Ok(ts) => filter.until = Some(ts),
                                Err(e) => {
                                    eprintln!("chump audit query: bad --until value: {e}");
                                    std::process::exit(2);
                                }
                            }
                        }
                    }
                    "--limit" => {
                        if let Some(v) = it.next() {
                            filter.limit = v.parse().ok();
                        }
                    }
                    _ => {}
                }
            }
            let repo_root = repo_path::repo_root();
            let conn = match audit_log::open(&repo_root) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("chump audit query: {e}");
                    std::process::exit(1);
                }
            };
            let entries = match audit_log::query(&conn, &filter) {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("chump audit query: {e}");
                    std::process::exit(1);
                }
            };
            if want_json {
                println!(
                    "{}",
                    serde_json::json!({ "count": entries.len(), "entries": entries })
                );
            } else {
                println!(
                    "{:<28} {:<22} {:<24} {:<10} resource_id",
                    "ts", "actor", "action", "result"
                );
                for e in &entries {
                    println!(
                        "{:<28} {:<22} {:<24} {:<10} {}",
                        e.ts,
                        e.actor,
                        e.action,
                        e.result.as_str(),
                        e.resource_id.clone().unwrap_or_default()
                    );
                }
                println!("{} entries", entries.len());
            }
            return Ok(());
        }
        // `chump audit retention --older-than <duration> [--dry-run] [--json]` (INFRA-1842).
        if sub == "retention" {
            let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
            if rest.iter().any(|a| *a == "--help" || *a == "help") || rest.is_empty() {
                println!(
                    "Usage: chump audit retention --older-than <duration> [--dry-run] [--json]"
                );
                println!();
                println!("Deletes audit_log rows with ts older than the cutoff. No automatic");
                println!("rotation — operator/cron invoked, mirrors BEAST-MODE's clearLogs().");
                return Ok(());
            }
            let want_json = rest.contains(&"--json");
            let mut older_than: Option<String> = None;
            let mut it = rest.iter().peekable();
            while let Some(a) = it.next() {
                if *a == "--older-than" {
                    older_than = it.next().map(|s| s.to_string());
                }
            }
            let older_than = match older_than {
                Some(v) => v,
                None => {
                    eprintln!("chump audit retention: --older-than is required");
                    std::process::exit(2);
                }
            };
            let cutoff = match audit_log::resolve_time_bound(&older_than) {
                Ok(ts) => ts,
                Err(e) => {
                    eprintln!("chump audit retention: bad --older-than value: {e}");
                    std::process::exit(2);
                }
            };
            let repo_root = repo_path::repo_root();
            let conn = match audit_log::open(&repo_root) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("chump audit retention: {e}");
                    std::process::exit(1);
                }
            };
            let report = match audit_log::clear_older_than(&conn, &cutoff) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("chump audit retention: {e}");
                    std::process::exit(1);
                }
            };
            if want_json {
                println!(
                    "{}",
                    serde_json::json!({ "removed": report.removed, "remaining": report.remaining })
                );
            } else {
                println!(
                    "removed {} rows older than {}, {} remaining",
                    report.removed, cutoff, report.remaining
                );
            }
            return Ok(());
        }
        // `chump audit _test_seed ...` — hidden subcommand for synthetic audit
        // entries, gated on CHUMP_TEST_MODE=1, matching the pattern used by
        // scripts/ci/test-gap-audit-priorities.sh's fixture seeding.
        if sub == "_test_seed" {
            if std::env::var("CHUMP_TEST_MODE").as_deref() != Ok("1") {
                eprintln!("chump audit _test_seed: only available with CHUMP_TEST_MODE=1");
                std::process::exit(2);
            }
            let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
            let mut actor = "test-actor".to_string();
            let mut action = "test.action".to_string();
            let mut resource: Option<String> = None;
            let mut resource_id: Option<String> = None;
            let mut it = rest.iter().peekable();
            while let Some(a) = it.next() {
                match *a {
                    "--actor" => actor = it.next().map(|s| s.to_string()).unwrap_or(actor),
                    "--action" => action = it.next().map(|s| s.to_string()).unwrap_or(action),
                    "--resource" => resource = it.next().map(|s| s.to_string()),
                    "--resource-id" => resource_id = it.next().map(|s| s.to_string()),
                    _ => {}
                }
            }
            let mut entry = audit_log::AuditEntry::new(&actor, &action);
            if let (Some(r), Some(rid)) = (resource, resource_id) {
                entry = entry.with_resource(&r, &rid);
            }
            let repo_root = repo_path::repo_root();
            let conn = match audit_log::open(&repo_root) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("chump audit _test_seed: {e}");
                    std::process::exit(1);
                }
            };
            if let Err(e) = audit_log::log_action(&conn, &entry) {
                eprintln!("chump audit _test_seed: {e}");
                std::process::exit(1);
            }
            println!("{}", entry.id);
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
            println!("  --json               output JSON instead of text");
            println!("  --window-days N      look back window in days (default 7)");
            println!("  --flag-silent-self   also warn on effect_metric=self kinds with 0 emits");
            println!("  --emit               write kind=audit_finding to ambient.jsonl for non-ok findings");
            println!();
            println!("Exits non-zero when any finding has severity=alert.");
            return Ok(());
        }
        let want_json = rest.contains(&"--json");
        let flag_silent_self = rest.contains(&"--flag-silent-self");
        let do_emit = rest.contains(&"--emit");
        let window_days: u64 = {
            let mut it = rest.iter().peekable();
            let mut n = 7u64;
            while let Some(a) = it.next() {
                if *a == "--window-days" {
                    if let Some(v) = it.next() {
                        if let Ok(parsed) = v.parse::<u64>() {
                            n = parsed.clamp(1, 90);
                        }
                    }
                }
            }
            n
        };
        let repo_root = repo_path::repo_root();
        let cfg = audit::SweepConfig {
            repo_root: repo_root.clone(),
            window: std::time::Duration::from_secs(window_days * 24 * 3600),
            flag_silent_self,
        };
        let findings = match audit::sweep_event_registry(&cfg) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("chump audit aha-sweep: {}", e);
                std::process::exit(1);
            }
        };
        if do_emit {
            if let Err(e) = audit::emit_findings(&repo_root, &findings) {
                eprintln!("chump audit aha-sweep: emit warning: {}", e);
            }
        }
        if want_json {
            println!("{}", audit::render_json(&findings));
        } else {
            print!("{}", audit::render_text(&findings));
        }
        let any_alert = findings
            .iter()
            .any(|f| f.severity == audit::AuditSeverity::Alert);
        if any_alert {
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump mission-grade [--json]` (INFRA-599) — auto-emit 4-pillar scorecard.
    // Counts pickable, in_flight, and shipped_24h gaps per pillar
    // (EFFECTIVE/CREDIBLE/RESILIENT/ZERO-WASTE, identified by title prefix),
    // emits kind=mission_grade to ambient.jsonl, and prints to stdout.
    if args.get(1).map(String::as_str) == Some("mission-grade") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump mission-grade [--json]");
            println!();
            println!("Current pillar grades: EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE.");
            println!("Emits kind=mission_grade to ambient.jsonl on each run.");
            println!();
            println!("Options:");
            println!("  --json   output in JSON format");
            println!();
            println!("Example:");
            println!("  chump mission-grade");
            println!("  chump mission-grade --json");
            return Ok(());
        }
        let want_json = args.iter().any(|a| a == "--json");
        let repo_root = repo_path::repo_root();
        let report = mission_grade::build_report(&repo_root);
        mission_grade::emit(&repo_root, &report);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        if report.any_low_grade() {
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump upgrade [--dry-run]` (INFRA-1504) — upgrade the chump binary.
    // Detects install method (brew / cargo / manual) and runs the right upgrade.
    if args.get(1).map(String::as_str) == Some("upgrade") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump upgrade [--dry-run]");
            println!();
            println!("Detects how chump was installed and runs the appropriate upgrade:");
            println!("  brew:   brew upgrade chump");
            println!("  cargo:  cargo install --force chump");
            println!("  manual: prints instructions to download a new release");
            println!();
            println!("Options:");
            println!("  --dry-run  show the upgrade command without running it");
            return Ok(());
        }
        let dry_run = args.iter().any(|a| a == "--dry-run");
        fleet_health::run_upgrade(dry_run);
        return Ok(());
    }

    // `chump health [--json] [--watch]` (INFRA-644) — composite fleet health
    // score (0-100) rolling up fleet-status, waste-tally, cost-watch,
    // mission-grade, pr-stuck, version-skew, auth, and ghost-gaps.
    // Emits kind=fleet_health to ambient.jsonl on each run.
    if args.get(1).map(String::as_str) == Some("health") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump health [--json] [--watch] [--slo-check] [--temp]");
            println!();
            println!("Composite fleet health score (0-100) rolling up fleet-status, waste-tally,");
            println!("cost-watch, mission-grade, pr-stuck, version-skew, auth, and ghost-gaps.");
            println!("Emits kind=fleet_health to ambient.jsonl on each run.");
            println!();
            println!("Options:");
            println!("  --json       output in JSON format");
            println!("  --watch      refresh every 30 s (clear screen between runs)");
            println!("  --slo-check  exit non-zero if any SLO is breached");
            println!("  --temp       INFRA-1992: report floor-temperature only (COLD/WARM/HOT)");
            println!();
            println!("Example:");
            println!("  chump health");
            println!("  chump health --slo-check   # use in CI");
            println!("  chump health --temp        # one-word floor-temp signal");
            println!("  chump health --temp --json # full floor-temp report with component counts");
            return Ok(());
        }
        let want_json = args.iter().any(|a| a == "--json");
        let watch = args.iter().any(|a| a == "--watch");
        let slo_check = args.iter().any(|a| a == "--slo-check");
        let want_temp = args.iter().any(|a| a == "--temp");
        let repo_root = repo_path::repo_root();

        // INFRA-1992 (THE FLOOR Phase 1): floor-temperature signal.
        // Reads ambient.jsonl over trailing 24h, counts hot event kinds
        // (hook_silent_passthrough + ci_failure_cluster + admin_merge_executed),
        // returns COLD/WARM/HOT. Emits kind=floor_temp on each invocation.
        if want_temp {
            let ambient = floor_temp::ambient_path_for(&repo_root);
            let mut report = floor_temp::compute(&ambient, floor_temp::DEFAULT_WINDOW_SECS);
            // CREDIBLE-1525 (AC3): surface the same admin_merges_7d number
            // `chump kpi report` computes, via the same calculator.
            report.admin_merges_7d = Some(
                chump_kpi_report::admin_merges::build_admin_merges_section(&repo_root)
                    .admin_merges_7d,
            );
            floor_temp::emit_floor_temp(&report);
            if want_json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&report).unwrap_or_else(|_| "{}".to_string())
                );
            } else {
                println!("{}", report.temp_str);
                eprintln!(
                    "  ({} hot events in trailing {}h)",
                    report.total_hot_events,
                    report.window_secs / 3600
                );
                if let Some(n) = report.admin_merges_7d {
                    eprintln!("  admin_merges_7d: {n}");
                }
                eprintln!("  {}", report.recommendation);
            }
            // Exit code: HOT → 2, WARM → 1, COLD → 0 (so CI/workers can react).
            let code = match report.temp {
                floor_temp::FloorTemp::Cold => 0,
                floor_temp::FloorTemp::Warm => 1,
                floor_temp::FloorTemp::Hot => 2,
            };
            std::process::exit(code);
        }

        if slo_check {
            let results = fleet_health::check_slos(&repo_root);
            if want_json {
                println!("{}", fleet_health::render_slo_json(&results));
            } else {
                print!("{}", fleet_health::render_slo_text(&results));
            }
            if results.iter().any(|r| r.breached) {
                std::process::exit(1);
            }
            return Ok(());
        }

        loop {
            let report = fleet_health::build_report(&repo_root);
            fleet_health::emit(&repo_root, &report);
            // Emit kind=session_rescue for any new rescues found (INFRA-667).
            let rescues = rescue_tally::scan_rescues(&repo_root, 24);
            rescue_tally::emit_rescue_events(&repo_root, &rescues);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            if !watch {
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(30));
            // Clear terminal for next iteration.
            print!("\x1b[2J\x1b[H");
            let _ = std::io::stdout().flush();
        }
        return Ok(());
    }

    // RESILIENT-1692: `chump organ pause|resume <unit>` — record/remove unit in
    // paused-timers.txt and stop/disable or enable/start via systemctl.
    if args.get(1).map(String::as_str) == Some("organ") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(organ_cmd::run(&sub_args));
    }

    // RESILIENT-1614: `chump node pause|resume` — enforce paused mode as an invariant.
    // Writes CHUMP_NODE_MODE to node.env and emits lifecycle events that organs check.
    if args.get(1).map(String::as_str) == Some("node") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");

        // RESILIENT-1653: one usage printer shared by `node --help`, `node pause
        // --help`, and `node resume --help`. --help/--dry-run make ZERO writes.
        let print_node_usage = || {
            println!("Usage: chump node pause [--reason \"<reason>\"] [--dry-run]");
            println!("       chump node resume [--dry-run]");
            println!("       chump node is-paused   (exit 0 paused, 1 not paused; no writes)");
            println!();
            println!("Pause and resume the node. When paused, work organs (node-converge,");
            println!("organ-reconcile, organ-deploy, paramedic, process-organ-heal,");
            println!("self-doctor, worker loop) check the mode first and exit 0 without");
            println!("installing, enabling, or restarting anything.");
            println!();
            println!("Pause writes CHUMP_NODE_MODE=paused to node.env, writes the node pause");
            println!("sentinel <state_dir>/.chump/fleet-paused (carrying REASON=), and emits");
            println!("kind=node_paused. That node sentinel is a DIFFERENT file from the");
            println!("ci-health-gate kill switch <repo>/.chump/fleet-paused (a HARD RED), so a");
            println!("verb-paused node still ships already-claimed work (RESILIENT-1652/1653).");
            println!();
            println!("Resume writes CHUMP_NODE_MODE=work-ready, removes the node pause sentinel,");
            println!("and emits kind=node_resumed.");
            println!();
            println!("--help prints this; --dry-run makes no writes.");
            println!();
            println!("Examples:");
            println!("  chump node pause --reason \"maintenance window\"");
            println!("  chump node resume");
        };

        if subcmd == "--help" || subcmd == "help" || subcmd == "-h" {
            print_node_usage();
            return Ok(());
        }

        match subcmd {
            "pause" => {
                // RESILIENT-1653 AC1: --help prints usage (zero writes); an
                // unknown flag is a usage error (exit 2), NEVER a pause with a
                // default reason; --dry-run makes no writes.
                let rest = &args[3..];
                if rest
                    .iter()
                    .any(|a| a == "--help" || a == "-h" || a == "help")
                {
                    print_node_usage();
                    return Ok(());
                }
                let mut reason: Option<String> = None;
                let mut dry_run = false;
                let mut i = 0;
                while i < rest.len() {
                    match rest[i].as_str() {
                        "--dry-run" => {
                            dry_run = true;
                            i += 1;
                        }
                        "--reason" => match rest.get(i + 1) {
                            Some(v) if !v.starts_with("--") => {
                                reason = Some(v.clone());
                                i += 2;
                            }
                            _ => {
                                eprintln!("chump node pause: --reason requires a value");
                                eprintln!(
                                    "Usage: chump node pause [--reason \"<reason>\"] [--dry-run]"
                                );
                                std::process::exit(2);
                            }
                        },
                        other => {
                            eprintln!("chump node pause: unknown flag '{other}'");
                            eprintln!(
                                "Usage: chump node pause [--reason \"<reason>\"] [--dry-run]"
                            );
                            std::process::exit(2);
                        }
                    }
                }
                let reason = reason.unwrap_or_else(|| "operator requested".to_string());
                let reason = reason.as_str();
                if dry_run {
                    println!("[dry-run] would pause node with reason: {reason}");
                    println!(
                        "[dry-run] would set CHUMP_NODE_MODE=paused in node.env, write the node \
                         pause sentinel <state_dir>/.chump/fleet-paused (REASON=), and emit \
                         kind=node_paused (NOT the <repo>/.chump kill switch; no writes performed)"
                    );
                    return Ok(());
                }

                let state = match node_mode::NodeModeState::new(None) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("chump node pause: {e:#}");
                        std::process::exit(1);
                    }
                };

                match state.pause(reason) {
                    Ok(()) => {
                        // RESILIENT-1615: a user-scope pause alone was the cuphead
                        // trap — a second, system-scope install kept its work
                        // organs running and undid every pause. Enumerate BOTH
                        // scopes (systemctl --user + system, or mac launchd) and
                        // REFUSE to report PAUSED while any work organ is still
                        // active in either scope.
                        println!("Node paused with reason: {}", reason);
                        let probe = chump_provision::Probe::from_env();
                        let foreign = chump_provision::scopes_live::report_scopes(&probe);
                        if foreign > 0 {
                            eprintln!(
                                "\n  ✗ NOT FULLY PAUSED: {foreign} work organ(s) active in ANOTHER scope.\n    \
                                 The sentinel + CHUMP_NODE_MODE=paused are written, but those organs\n    \
                                 never see this scope's sentinel and will undo the pause (the cuphead\n    \
                                 second-scope defect). Disable the other scope's units (e.g. a second\n    \
                                 /root/.chumpnode install) before trusting this node as PAUSED.\n    \
                                 Inspect with: chump node scopes"
                            );
                            std::process::exit(3);
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump node pause: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "resume" => {
                // RESILIENT-1653 AC1: --help prints usage (zero writes); an
                // unknown flag is a usage error (exit 2); --dry-run makes no
                // writes. resume takes no positional args or --reason.
                let rest = &args[3..];
                if rest
                    .iter()
                    .any(|a| a == "--help" || a == "-h" || a == "help")
                {
                    print_node_usage();
                    return Ok(());
                }
                let mut dry_run = false;
                for a in rest {
                    match a.as_str() {
                        "--dry-run" => dry_run = true,
                        other => {
                            eprintln!("chump node resume: unknown flag '{other}'");
                            eprintln!("Usage: chump node resume [--dry-run]");
                            std::process::exit(2);
                        }
                    }
                }
                if dry_run {
                    println!(
                        "[dry-run] would resume node: set CHUMP_NODE_MODE=work-ready in \
                         node.env and emit kind=node_resumed (no writes performed)"
                    );
                    return Ok(());
                }

                let state = match node_mode::NodeModeState::new(None) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("chump node resume: {e:#}");
                        std::process::exit(1);
                    }
                };

                match state.resume() {
                    Ok(()) => {
                        println!("Node resumed");
                        // RESILIENT-1615: enumerate both scopes informationally so
                        // the operator sees which organs are coming back and in
                        // which scope (a second-scope install shows up here too).
                        let probe = chump_provision::Probe::from_env();
                        let _ = chump_provision::scopes_live::report_scopes(&probe);
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump node resume: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "is-paused" => {
                // RESILIENT-1652/1653 (task 3): a READ-ONLY predicate verb —
                // exit 0 = paused, exit 1 = not paused, NO writes. node-converge's
                // `_nc_paused` calls this so the shell honours the ONE Rust
                // predicate instead of its own divergent rule. --help prints
                // usage (exit 0); any other flag is a usage error (exit 2) so it
                // is never confused with the 0/1 pause verdict.
                let rest = &args[3..];
                // CREDIBLE-015: keep the help detection off a single
                // `--help || … help` line (use matches!, no `||`) so the
                // unknown-flag error eprintln below — a legitimate stderr error
                // path — isn't misread by the help-consistency heuristic as a
                // --help block that should use println.
                let wants_help = rest
                    .iter()
                    .any(|a| matches!(a.as_str(), "--help" | "-h" | "help"));
                if wants_help {
                    print_node_usage();
                    return Ok(());
                }
                if let Some(bad) = rest.iter().find(|a| a.starts_with('-')) {
                    eprintln!("chump node is-paused: unknown flag '{bad}'");
                    eprintln!("Usage: chump node is-paused   (exit 0 paused, 1 not paused)");
                    std::process::exit(2);
                }
                let state = match node_mode::NodeModeState::new(None) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("chump node is-paused: {e:#}");
                        std::process::exit(2);
                    }
                };
                match state.is_paused() {
                    Ok(true) => std::process::exit(0),
                    Ok(false) => std::process::exit(1),
                    Err(e) => {
                        eprintln!("chump node is-paused: {e:#}");
                        std::process::exit(2);
                    }
                }
            }
            _ => {
                eprintln!("Usage: chump node pause [--reason \"<reason>\"] [--dry-run]");
                eprintln!("       chump node resume [--dry-run]");
                eprintln!("       chump node is-paused");
                std::process::exit(2);
            }
        }
    }

    // INFRA-1613: `chump skill <subcmd>` — operator-facing CLI for skill management.
    // Exposes list/view/health/record-outcome/tap-add without requiring an
    // agent loop session. Skills live in chump-brain/skills/<name>/SKILL.md;
    // reliability stats come from chump_skills SQLite table (skill_db.rs).
    if args.get(1).map(String::as_str) == Some("skill") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("list");
        let want_json = args.iter().any(|a| a == "--json");

        if subcmd == "--help" || subcmd == "help" || subcmd == "-h" {
            println!("Usage: chump skill <subcommand> [options]");
            println!();
            println!("Subcommands:");
            println!("  list [--json]              List all installed skills");
            println!("  view NAME                  Show full SKILL.md for NAME");
            println!("  health [--name NAME] [--min-uses N]");
            println!("                             Wilson CI ranking per skill");
            println!("  record-outcome NAME true|false");
            println!("                             Record a success/failure outcome");
            println!("  tap-add URL                Install skills from a GitHub repo");
            println!(
                "  bundle install             Tap skills-bundle/* into the brain (INFRA-1615)"
            );
            println!();
            println!("Skills live in: chump-brain/skills/<name>/SKILL.md");
            println!("Override: CHUMP_BRAIN_PATH env var");
            return Ok(());
        }

        match subcmd {
            "bundle" => {
                let bundle_subcmd = args.get(3).map(String::as_str).unwrap_or("");
                if bundle_subcmd != "install" {
                    eprintln!("Usage: chump skill bundle install");
                    std::process::exit(2);
                }
                let repo_root = repo_path::repo_root();
                match crate::skills::install_bundle(&repo_root) {
                    Ok(installed) if installed.is_empty() => {
                        println!(
                            "chump skill bundle install: nothing to install (already present or no skills-bundle/ found)"
                        );
                    }
                    Ok(installed) => {
                        println!(
                            "Installed {} seed skill(s): {}",
                            installed.len(),
                            installed.join(", ")
                        );
                    }
                    Err(e) => {
                        eprintln!("chump skill bundle install: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "list" => {
                match crate::skills::list_skills() {
                    Ok(skills) if skills.is_empty() => {
                        if want_json {
                            println!("[]");
                        } else {
                            println!(
                                "No skills installed. Use skill_manage action=create to add one."
                            );
                        }
                    }
                    Ok(skills) => {
                        if want_json {
                            // Build JSON array from skill frontmatter + reliability stats.
                            let mut items: Vec<serde_json::Value> =
                                Vec::with_capacity(skills.len());
                            for s in &skills {
                                let (rel, n) =
                                    crate::skill_db::skill_reliability(&s.frontmatter.name)
                                        .unwrap_or((0.5, 0));
                                let rec =
                                    crate::skill_db::list_skill_records().ok().and_then(|recs| {
                                        recs.into_iter().find(|r| r.name == s.frontmatter.name)
                                    });
                                let last_used = rec.as_ref().and_then(|r| r.last_used_at.clone());
                                let version = s.frontmatter.version;
                                let platforms = &s.frontmatter.platforms;
                                let meta = serde_json::json!({
                                    "tags": s.frontmatter.metadata.tags,
                                    "category": s.frontmatter.metadata.category,
                                    "requires_toolsets": s.frontmatter.metadata.requires_toolsets,
                                });
                                items.push(serde_json::json!({
                                    "name": s.frontmatter.name,
                                    "description": s.frontmatter.description,
                                    "version": version,
                                    "platforms": platforms,
                                    "metadata": meta,
                                    "reliability_p": rel,
                                    "sample_n": n,
                                    "last_used_at": last_used,
                                }));
                            }
                            println!(
                                "{}",
                                serde_json::to_string_pretty(&items)
                                    .unwrap_or_else(|_| "[]".to_string())
                            );
                        } else {
                            println!("Installed skills ({}):", skills.len());
                            for s in &skills {
                                println!("  {}", s.summary_line());
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("chump skill list: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "view" => {
                let name = match args.get(3) {
                    Some(n) => n.as_str(),
                    None => {
                        eprintln!("Usage: chump skill view NAME");
                        std::process::exit(2);
                    }
                };
                match crate::skills::load_skill(name) {
                    Ok(skill) => {
                        let (rel, n) = crate::skill_db::skill_reliability(name).unwrap_or((0.5, 0));
                        if n > 0 {
                            println!(
                                "# Skill: {} (v{})\n",
                                skill.frontmatter.name, skill.frontmatter.version
                            );
                            println!("**Description:** {}", skill.frontmatter.description);
                            println!("**Reliability:** {:.1}% over {} uses\n", rel * 100.0, n);
                            println!("---\n");
                        } else {
                            println!(
                                "# Skill: {} (v{})\n",
                                skill.frontmatter.name, skill.frontmatter.version
                            );
                            println!("**Description:** {}", skill.frontmatter.description);
                            println!("**Reliability:** no usage data yet\n");
                            println!("---\n");
                        }
                        print!("{}", skill.body);
                    }
                    Err(e) => {
                        eprintln!("chump skill view: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "health" => {
                // Optional filters: --name NAME, --min-uses N
                let name_filter: Option<String> = {
                    let mut v = None;
                    let mut it = args.iter().skip(3);
                    while let Some(a) = it.next() {
                        if a == "--name" {
                            v = it.next().cloned();
                            break;
                        }
                    }
                    v
                };
                let min_uses: u64 = {
                    let mut v = 0u64;
                    let mut it = args.iter().skip(3);
                    while let Some(a) = it.next() {
                        if a == "--min-uses" {
                            if let Some(n) = it.next().and_then(|s| s.parse().ok()) {
                                v = n;
                            }
                            break;
                        }
                    }
                    v
                };
                match crate::skill_metrics::skill_health_ranking() {
                    Ok(ranking) => {
                        let filtered: Vec<_> = ranking
                            .into_iter()
                            .filter(|h| name_filter.as_deref().is_none_or(|n| h.name == n))
                            .filter(|h| h.use_count >= min_uses)
                            .collect();
                        if want_json {
                            println!(
                                "{}",
                                serde_json::to_string_pretty(&filtered)
                                    .unwrap_or_else(|_| "[]".to_string())
                            );
                        } else if filtered.is_empty() {
                            println!("No skills matching the filter.");
                        } else {
                            println!(
                                "{:<30} {:>6} {:>6} {:>12} {:>10} {:>8}",
                                "name", "uses", "rel%", "ci_lower-upper", "composite", "days_old"
                            );
                            println!("{}", "-".repeat(80));
                            for h in &filtered {
                                let days = h
                                    .days_since_last_use
                                    .map(|d| d.to_string())
                                    .unwrap_or_else(|| "never".to_string());
                                println!(
                                    "{:<30} {:>6} {:>5.1}% [{:>5.1}%–{:>5.1}%] {:>10.3} {:>8}",
                                    h.name,
                                    h.use_count,
                                    h.reliability * 100.0,
                                    h.confidence_lower * 100.0,
                                    h.confidence_upper * 100.0,
                                    h.composite_score,
                                    days,
                                );
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("chump skill health: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "record-outcome" => {
                let name = match args.get(3) {
                    Some(n) => n.as_str(),
                    None => {
                        eprintln!("Usage: chump skill record-outcome NAME true|false");
                        std::process::exit(2);
                    }
                };
                let success_str = match args.get(4) {
                    Some(s) => s.as_str(),
                    None => {
                        eprintln!("Usage: chump skill record-outcome NAME true|false");
                        std::process::exit(2);
                    }
                };
                let success = match success_str {
                    "true" | "1" | "yes" => true,
                    "false" | "0" | "no" => false,
                    other => {
                        eprintln!("chump skill record-outcome: expected true|false, got {other:?}");
                        std::process::exit(2);
                    }
                };
                match crate::skill_db::record_skill_outcome(name, success) {
                    Ok(()) => {
                        let (rel, uses) =
                            crate::skill_db::skill_reliability(name).unwrap_or((0.5, 0));
                        println!(
                            "Recorded {} for '{}'. Reliability: {:.1}% over {} uses.",
                            if success { "success" } else { "failure" },
                            name,
                            rel * 100.0,
                            uses
                        );
                    }
                    Err(e) => {
                        eprintln!("chump skill record-outcome: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "tap-add" => {
                let url = match args.get(3) {
                    Some(u) => u.as_str(),
                    None => {
                        eprintln!("Usage: chump skill tap-add URL");
                        eprintln!(
                            "  URL: https://github.com/owner/repo (must have a skills/ directory)"
                        );
                        std::process::exit(2);
                    }
                };
                // Call handle_tap_add directly (pub since INFRA-1613).
                match crate::skill_tool::handle_tap_add(url).await {
                    Ok(msg) => println!("{msg}"),
                    Err(e) => {
                        eprintln!("chump skill tap-add: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            other => {
                eprintln!("chump skill: unknown subcommand '{other}'");
                eprintln!("Valid: list, view, health, record-outcome, tap-add, bundle install");
                eprintln!("Run 'chump skill --help' for usage.");
                std::process::exit(2);
            }
        }
    }

    // INFRA-1696 (META-066 phase 3): `chump content-bots <subcmd>` operator
    // surface for the Content Bots Suite (PMM, DocuBot, Evangelist, CopyBot).
    // Reads docs/agents/content-bots/bots.yaml + the toggle resolver from
    // INFRA-1700 (src/content_bots.rs).
    if args.get(1).map(String::as_str) == Some("content-bots") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("list");
        let json = args.iter().any(|a| a == "--json");
        let repo_root = repo_path::repo_root();
        let bots_yaml = repo_root.join("docs/agents/content-bots/bots.yaml");

        if !bots_yaml.exists() {
            eprintln!(
                "chump content-bots: bots.yaml not found at {}",
                bots_yaml.display()
            );
            eprintln!("  Foundation gap INFRA-1690 must ship before this command works.");
            std::process::exit(2);
        }

        // Minimal bots.yaml reader — parse `bot_id:`, `tier:`, `model_tier:`,
        // `default_enabled:` per entry. Avoid pulling serde_yaml dep just for
        // this read; bots.yaml is operator-curated and small.
        let raw = std::fs::read_to_string(&bots_yaml).unwrap_or_default();
        #[derive(Debug, Default)]
        struct BotEntry {
            bot_id: String,
            tier: String,
            model_tier: String,
            default_enabled: bool,
        }
        let mut bots: Vec<BotEntry> = Vec::new();
        let mut cur = BotEntry::default();
        let mut in_bots = false;
        for line in raw.lines() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("bots:") {
                in_bots = true;
                continue;
            }
            if !in_bots {
                continue;
            }
            if trimmed.starts_with("- bot_id:") {
                if !cur.bot_id.is_empty() {
                    bots.push(std::mem::take(&mut cur));
                }
                cur.bot_id = trimmed.trim_start_matches("- bot_id:").trim().to_string();
            } else if let Some(v) = trimmed.strip_prefix("tier:") {
                cur.tier = v.trim().to_string();
            } else if let Some(v) = trimmed.strip_prefix("model_tier:") {
                cur.model_tier = v.split_whitespace().next().unwrap_or("").to_string();
            } else if let Some(v) = trimmed.strip_prefix("default_enabled:") {
                cur.default_enabled = v.split_whitespace().next() == Some("true");
            }
        }
        if !cur.bot_id.is_empty() {
            bots.push(cur);
        }

        match subcmd {
            "list" => {
                let enabled = content_bots::enabled_set(&repo_root);
                if json {
                    println!("[");
                    for (i, b) in bots.iter().enumerate() {
                        let en = enabled.contains(&b.bot_id) || b.default_enabled;
                        println!(
                            "  {{\"bot_id\": \"{}\", \"tier\": \"{}\", \"model_tier\": \"{}\", \"enabled\": {}}}{}",
                            b.bot_id,
                            b.tier,
                            b.model_tier,
                            en,
                            if i + 1 == bots.len() { "" } else { "," }
                        );
                    }
                    println!("]");
                } else {
                    println!("{:<14} {:<12} {:<6} ENABLED", "BOT_ID", "TIER", "MODEL");
                    for b in &bots {
                        let en = enabled.contains(&b.bot_id) || b.default_enabled;
                        let mark = if en { "✓" } else { "·" };
                        let src = if enabled.contains(&b.bot_id) {
                            " (config|env)"
                        } else if b.default_enabled {
                            " (default)"
                        } else {
                            ""
                        };
                        println!(
                            "{:<14} {:<12} {:<6} {}{}",
                            b.bot_id, b.tier, b.model_tier, mark, src
                        );
                    }
                    println!();
                    println!(
                        "Toggle: CHUMP_CONTENT_BOTS=<csv> (env) or [content_bots] enabled in .chump-config.toml"
                    );
                }
                return Ok(());
            }
            _ => {
                eprintln!("chump content-bots: unknown subcommand '{}'", subcmd);
                eprintln!("  Available: list [--json]");
                std::process::exit(2);
            }
        }
    }

    // MISSION-008 / MISSION-030: `chump outcome <sub>` — first-class Outcome object commands.
    // INFRA-3480 / EFFECTIVE-357: chump intake "<plain-language problem>" [--json] [--create]
    // CREATE-mode conversational intake — plain-language restatement, 1-3
    // clarifying questions, and a proposed definition-of-done. Never emits
    // software jargon (structurally enforced in VisionIntakeContract::validate).
    // With --create: writes an outcome row, then — only when chump-perception
    // scores the raw input below the ambiguity threshold — files ONE
    // structured umbrella gap with real acceptance criteria via the existing
    // roadmap-from-vision pipeline (EFFECTIVE-357). Above the threshold,
    // intake stops at the clarifying questions instead of guessing AC.
    if args.get(1).map(String::as_str) == Some("intake") {
        let json_out = args.iter().any(|a| a == "--json");
        let create = args.iter().any(|a| a == "--create");
        let text = args
            .iter()
            .skip(2)
            .find(|a| !a.starts_with("--"))
            .cloned()
            .unwrap_or_else(|| {
                eprintln!("Usage: chump intake \"<plain-language problem>\" [--json] [--create]");
                eprintln!(
                    "  --create   Write an outcome row, and (if the input isn't too ambiguous) \
                     a structured gap with real acceptance criteria"
                );
                std::process::exit(2);
            });
        if let Err(e) = vision_intake::run(&text, json_out, create).await {
            eprintln!("chump intake: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // chump outcome new|create --id X --title T [--priority P] [--dod D]
    // chump outcome list [--status open|done] [--json]
    // chump outcome show <id> [--json]
    // chump outcome status <id> [--json]   (alias for show)
    // chump outcome link <GAP-ID> --outcome <OUTCOME-ID>
    // chump outcome unlink <GAP-ID>
    // chump outcome bootstrap              (seed canonical mission outcomes)
    // chump outcome backfill [--dry-run] [--apply]
    // ADVISORY ONLY — outcome rollup never gates or blocks a child gap from closing.
    if args.get(1).map(String::as_str) == Some("outcome") {
        let sub = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump outcome: {e:#}");
                std::process::exit(1);
            }
        };
        // Inline flag helper valid for this block (flag closure defined later in main).
        let oflag = |name: &str| -> Option<String> {
            args.windows(2)
                .find(|w| w[0] == name)
                .and_then(|w| w.get(1))
                .cloned()
        };
        let json_out = args.iter().any(|a| a == "--json");
        match sub {
            "new" | "create" => {
                let id = oflag("--id").unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome new --id X --title T [--priority P] [--dod D]");
                    std::process::exit(2);
                });
                let title = oflag("--title").unwrap_or_else(|| {
                    eprintln!("chump outcome new: --title required");
                    std::process::exit(2);
                });
                let priority = oflag("--priority")
                    .or_else(|| oflag("--p"))
                    .unwrap_or_else(|| "P2".into());
                let dod = oflag("--dod")
                    .or_else(|| oflag("--definition-of-done"))
                    .unwrap_or_default();
                match store.create_outcome(&id, &title, &priority, &dod) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"id":"{id}","title":"{title}","priority":"{priority}","created":true}}"#
                            );
                        } else {
                            println!(
                                "outcome {} created (advisory — never gates child close)",
                                id
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome new: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "list" => {
                let status_filter = oflag("--status");
                let outcomes = store.list_outcomes().unwrap_or_default();
                let outcomes: Vec<_> = outcomes
                    .into_iter()
                    .filter(|o| {
                        status_filter
                            .as_deref()
                            .map(|s| o.status == s)
                            .unwrap_or(true)
                    })
                    .collect();
                if json_out {
                    // Build gap-count per outcome for richer output.
                    let all_gaps = store.list(None).unwrap_or_default();
                    let items: Vec<String> = outcomes
                        .iter()
                        .map(|o| {
                            let gap_count = all_gaps
                                .iter()
                                .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                                .count();
                            let open_count = all_gaps
                                .iter()
                                .filter(|g| {
                                    g.outcome_id.as_deref() == Some(o.id.as_str())
                                        && g.status == "open"
                                })
                                .count();
                            format!(
                                r#"{{"id":"{}","title":"{}","priority":"{}","status":"{}","gap_count":{},"open_count":{}}}"#,
                                o.id,
                                o.title.replace('"', "\\\""),
                                o.priority,
                                o.status,
                                gap_count,
                                open_count,
                            )
                        })
                        .collect();
                    println!("[{}]", items.join(","));
                } else {
                    if outcomes.is_empty() {
                        println!(
                            "(no outcomes registered — use `chump outcome bootstrap` or `chump outcome create`)"
                        );
                    }
                    let all_gaps = store.list(None).unwrap_or_default();
                    for o in &outcomes {
                        let gap_count = all_gaps
                            .iter()
                            .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                            .count();
                        println!(
                            "{} [{}] {} — {} ({} gaps)",
                            o.id, o.priority, o.status, o.title, gap_count
                        );
                    }
                }
            }
            // MISSION-030: `show` = detailed view of one outcome + its linked gaps.
            "show" | "status" => {
                let oid = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome show <outcome-id> [--json]");
                    std::process::exit(2);
                });
                match store.outcome_status(&oid) {
                    Ok(Some(r)) => {
                        if json_out {
                            // Include linked gaps in JSON.
                            let linked = store.gaps_for_outcome(&oid).unwrap_or_default();
                            let gaps_json: Vec<String> = linked
                                .iter()
                                .map(|g| {
                                    format!(
                                        r#"{{"id":"{}","title":"{}","status":"{}","priority":"{}"}}"#,
                                        g.id,
                                        g.title.replace('"', "\\\""),
                                        g.status,
                                        g.priority,
                                    )
                                })
                                .collect();
                            let jtbd_json = if r.outcome.jtbd_who.is_some()
                                || r.outcome.jtbd_struggling_moment.is_some()
                                || r.outcome.jtbd_done_signal.is_some()
                            {
                                format!(
                                    r#","jtbd":{{"who":"{}","struggling_moment":"{}","done_signal":"{}"}}"#,
                                    r.outcome
                                        .jtbd_who
                                        .as_deref()
                                        .unwrap_or("")
                                        .replace('"', "\\\""),
                                    r.outcome
                                        .jtbd_struggling_moment
                                        .as_deref()
                                        .unwrap_or("")
                                        .replace('"', "\\\""),
                                    r.outcome
                                        .jtbd_done_signal
                                        .as_deref()
                                        .unwrap_or("")
                                        .replace('"', "\\\""),
                                )
                            } else {
                                String::new()
                            };
                            println!(
                                r#"{{"outcome_id":"{}","title":"{}","priority":"{}","status":"{}","definition_of_done":"{}","total":{},"open":{},"done":{},"other":{},"advisory":true,"gaps":[{}]{}}}"#,
                                r.outcome.id,
                                r.outcome.title.replace('"', "\\\""),
                                r.outcome.priority,
                                r.outcome.status,
                                r.outcome.definition_of_done.replace('"', "\\\""),
                                r.total,
                                r.open,
                                r.done,
                                r.other,
                                gaps_json.join(","),
                                jtbd_json,
                            );
                        } else {
                            println!("=== Outcome: {} ===", r.outcome.id);
                            println!("Title    : {}", r.outcome.title);
                            println!("Priority : {}", r.outcome.priority);
                            println!("Status   : {}", r.outcome.status);
                            if !r.outcome.definition_of_done.is_empty() {
                                println!("DoD      : {}", r.outcome.definition_of_done);
                            }
                            if r.outcome.jtbd_who.is_some()
                                || r.outcome.jtbd_struggling_moment.is_some()
                                || r.outcome.jtbd_done_signal.is_some()
                            {
                                println!();
                                println!("Job to be done:");
                                if let Some(who) = &r.outcome.jtbd_who {
                                    println!("  Who              : {}", who);
                                }
                                if let Some(m) = &r.outcome.jtbd_struggling_moment {
                                    println!("  Struggling moment: {}", m);
                                }
                                if let Some(s) = &r.outcome.jtbd_done_signal {
                                    println!("  Done signal      : {}", s);
                                }
                            }
                            println!();
                            println!("Child gaps (advisory rollup — never gates close):");
                            println!(
                                "  total: {}  open: {}  done: {}  other: {}",
                                r.total, r.open, r.done, r.other
                            );
                            if r.total > 0 {
                                let pct = (r.done as f64 / r.total as f64 * 100.0) as usize;
                                println!("  progress: {}%", pct);
                            }
                            let linked = store.gaps_for_outcome(&oid).unwrap_or_default();
                            if !linked.is_empty() {
                                println!();
                                println!("Linked gaps:");
                                for g in &linked {
                                    println!(
                                        "  {} [{}] {} — {}",
                                        g.id, g.priority, g.status, g.title
                                    );
                                }
                            }
                        }
                    }
                    Ok(None) => {
                        eprintln!("chump outcome show: outcome '{}' not found", oid);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump outcome show: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // MISSION-030: `link <GAP-ID> --outcome <OUTCOME-ID>` — set gaps.outcome_id.
            "link" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome link <GAP-ID> --outcome <OUTCOME-ID>");
                    std::process::exit(2);
                });
                let oid = oflag("--outcome").unwrap_or_else(|| {
                    eprintln!("chump outcome link: --outcome required");
                    std::process::exit(2);
                });
                // Verify outcome exists before linking.
                match store.get_outcome(&oid) {
                    Ok(None) => {
                        eprintln!(
                            "chump outcome link: outcome '{}' not found — create it first",
                            oid
                        );
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump outcome link: {e:#}");
                        std::process::exit(1);
                    }
                    Ok(Some(_)) => {}
                }
                let update = gap_store::GapFieldUpdate {
                    outcome_id: Some(oid.clone()),
                    ..Default::default()
                };
                match store.set_fields(&gap_id, update) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"gap_id":"{gap_id}","outcome_id":"{oid}","linked":true}}"#
                            );
                        } else {
                            println!("{} linked to outcome {}", gap_id, oid);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome link: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // MISSION-030: `unlink <GAP-ID>` — clear gaps.outcome_id.
            "unlink" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome unlink <GAP-ID>");
                    std::process::exit(2);
                });
                let update = gap_store::GapFieldUpdate {
                    outcome_id: Some(String::new()), // empty = set NULL
                    ..Default::default()
                };
                match store.set_fields(&gap_id, update) {
                    Ok(()) => {
                        if json_out {
                            println!(r#"{{"gap_id":"{gap_id}","outcome_id":null,"linked":false}}"#);
                        } else {
                            println!("{} unlinked from outcome", gap_id);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome unlink: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // MISSION-030: `bootstrap` — seed canonical mission outcomes (idempotent).
            // MISSION-043: also seeds 4 pillar outcomes (CREDIBLE/EFFECTIVE/RESILIENT/ZERO-WASTE).
            "bootstrap" => {
                // Canonical outcomes per docs/MISSION.md and gap dispatch context.
                // Each entry: (id, title, priority, dod)
                let canonical: &[(&str, &str, &str, &str)] = &[
                    (
                        "MISSION-010",
                        "self-coordinating fleet (BEAST proof)",
                        "P0",
                        "Fleet ships PRs to external repos without human in the loop; \
                         BEAST-MODE overnight proof completed.",
                    ),
                    (
                        "MISSION-012",
                        "self-deploy: auto-deploy daemon keeps installed binary on origin/main",
                        "P0",
                        "Binary on each fleet node always tracks origin/main; \
                         no manual pull required after a ship.",
                    ),
                    (
                        "MISSION-032",
                        "scale to 100s-to-10000s of external repos",
                        "P1",
                        "Phase B: repos table + external claims + per-repo mission scoreboard; \
                         Phase C: multi-tenant with repo_scope.",
                    ),
                    (
                        "META-067",
                        "three demo-able 2026 outcomes: net-new bootstrap / repo takeover / autonomous throughput",
                        "P1",
                        "Demo 1: zero-to-first-PR on a blank repo; \
                         Demo 2: Chump takes over an existing repo; \
                         Demo 3: sustained autonomous throughput.",
                    ),
                    // MISSION-043: four pillar outcomes — one per quality pillar.
                    (
                        "CREDIBLE-000",
                        "Credible: measurable, verifiable, trustworthy",
                        "P1",
                        "Every CREDIBLE-* gap traces to honest measurement (no proxy metrics, \
                         no silent failures). Reality-check gate (CREDIBLE-090) is the keystone.",
                    ),
                    (
                        "EFFECTIVE-000",
                        "Effective: user-facing capability, real-world impact",
                        "P1",
                        "Every EFFECTIVE-* gap moves a user-visible surface forward \
                         (CLI, PWA, docs that reach humans). META-067 demo outcomes are \
                         canonical evidence.",
                    ),
                    (
                        "RESILIENT-000",
                        "Resilient: self-healing, no fragile single points of failure",
                        "P1",
                        "Every RESILIENT-* gap removes a halt-class or recovers from one. \
                         Fleet recovers from any halt with no human terminal.",
                    ),
                    (
                        "ZERO-WASTE-000",
                        "Zero-waste: no idle agents, no duplicated work, no shelved capability",
                        "P1",
                        "Every ZERO-WASTE-* gap removes a waste class. \
                         Substrate doesn't accumulate without being used.",
                    ),
                ];
                let mut created = 0usize;
                let mut already = 0usize;
                for (id, title, priority, dod) in canonical {
                    // Check existence first (create_outcome is idempotent via INSERT OR IGNORE).
                    let exists = store.get_outcome(id).unwrap_or(None).is_some();
                    match store.create_outcome(id, title, priority, dod) {
                        Ok(()) => {
                            if exists {
                                already += 1;
                                if !json_out {
                                    println!("  {} already exists (skipped)", id);
                                }
                            } else {
                                created += 1;
                                if !json_out {
                                    println!("  {} created: {}", id, title);
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!("chump outcome bootstrap: error creating {}: {}", id, e);
                        }
                    }
                }
                if json_out {
                    println!(
                        r#"{{"created":{},"already_existed":{},"total":{}}}"#,
                        created,
                        already,
                        canonical.len()
                    );
                } else {
                    println!();
                    println!(
                        "bootstrap complete: {} created, {} already existed ({} total)",
                        created,
                        already,
                        canonical.len()
                    );
                }
            }
            // MISSION-030: `backfill [--dry-run] [--apply]` — auto-link open gaps to outcomes.
            "backfill" => {
                let dry_run = !args.iter().any(|a| a == "--apply");
                if dry_run {
                    println!("[outcome backfill] DRY RUN — use --apply to commit changes");
                }

                let outcomes = store.list_outcomes().unwrap_or_default();
                if outcomes.is_empty() {
                    eprintln!(
                        "chump outcome backfill: no outcomes registered. Run `chump outcome bootstrap` first."
                    );
                    std::process::exit(1);
                }

                let all_gaps = match store.list(None) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump outcome backfill: {e:#}");
                        std::process::exit(1);
                    }
                };

                // Build outcome-id set for fast lookup.
                let outcome_ids: std::collections::HashSet<&str> =
                    outcomes.iter().map(|o| o.id.as_str()).collect();

                // Backfill heuristics (applied in order; first match wins):
                // 1. Exact-prefix: gap.id == outcome.id → link directly.
                //    (e.g. MISSION-030 → MISSION-010 as scaffolding)
                //    Actually: for gaps whose id STARTS with same prefix as any outcome.
                //    Concretely: MISSION-* gaps → MISSION-010 (the umbrella mission).
                // 2. Title contains outcome id → link to that outcome.
                // 3. Description contains "MISSION-XXX umbrella" / "Tier-1 of MISSION-XXX"
                //    → link to named outcome id if registered.
                // 4. Title/description contains "BEAST" or "BEAST-MODE" → MISSION-010.
                // 5. Title/description contains "META-067" → META-067.
                // Default: skip (don't guess).

                // Counters per outcome.
                let mut counts: std::collections::HashMap<&str, usize> =
                    outcomes.iter().map(|o| (o.id.as_str(), 0usize)).collect();
                let mut skipped = 0usize;
                let mut already_linked = 0usize;
                let mut changes: Vec<(String, String)> = Vec::new(); // (gap_id, outcome_id)

                for g in &all_gaps {
                    // Don't overwrite existing links.
                    if g.outcome_id.as_deref().map(|s| !s.is_empty()) == Some(true) {
                        already_linked += 1;
                        continue;
                    }

                    let id_uc = g.id.to_uppercase();
                    let title_uc = g.title.to_uppercase();
                    let desc_uc = g.description.to_uppercase();

                    let mut assigned: Option<&str> = None;

                    // Heuristic 1: gap id IS a registered outcome → self-link.
                    if outcome_ids.contains(g.id.as_str()) {
                        assigned = Some(g.id.as_str());
                    }

                    // Heuristic 2: gap title contains a registered outcome id.
                    if assigned.is_none() {
                        for oid in &outcome_ids {
                            if title_uc.contains(&oid.to_uppercase()) {
                                assigned = Some(oid);
                                break;
                            }
                        }
                    }

                    // Heuristic 3: description contains "umbrella" or "Tier-1 of" phrase
                    // referring to a registered outcome id.
                    if assigned.is_none() {
                        for oid in &outcome_ids {
                            let needle = oid.to_uppercase();
                            let paren_prefix = format!("({needle} ");
                            let paren_slice = format!("({needle} SLICE");
                            if desc_uc.contains(&format!("{needle} UMBRELLA"))
                                || desc_uc.contains(&format!("TIER-1 OF {needle}"))
                                || desc_uc.contains(paren_prefix.as_str())
                                || desc_uc.contains(paren_slice.as_str())
                                || desc_uc.contains(&format!("{needle} PHASE"))
                            {
                                assigned = Some(oid);
                                break;
                            }
                        }
                    }

                    // Heuristic 4: BEAST / BEAST-MODE → MISSION-010.
                    if assigned.is_none()
                        && outcome_ids.contains("MISSION-010")
                        && (title_uc.contains("BEAST") || desc_uc.contains("BEAST"))
                    {
                        assigned = Some("MISSION-010");
                    }

                    // Heuristic 5: META-067 in title or description → META-067.
                    if assigned.is_none()
                        && outcome_ids.contains("META-067")
                        && (title_uc.contains("META-067") || desc_uc.contains("META-067"))
                    {
                        assigned = Some("META-067");
                    }

                    // Heuristic 6: MISSION-* prefix gap ids → MISSION-010 umbrella
                    // (since MISSION-010 is the fleet self-coordination master mission).
                    if assigned.is_none()
                        && id_uc.starts_with("MISSION-")
                        && outcome_ids.contains("MISSION-010")
                    {
                        assigned = Some("MISSION-010");
                    }

                    // Heuristic 7 (MISSION-043): domain-prefix → pillar outcome.
                    // Only fires when the pillar outcome is registered (idempotent /
                    // graceful fallback when bootstrap wasn't run yet).
                    if assigned.is_none() {
                        if id_uc.starts_with("CREDIBLE-") && outcome_ids.contains("CREDIBLE-000") {
                            assigned = Some("CREDIBLE-000");
                        } else if id_uc.starts_with("EFFECTIVE-")
                            && outcome_ids.contains("EFFECTIVE-000")
                        {
                            assigned = Some("EFFECTIVE-000");
                        } else if id_uc.starts_with("RESILIENT-")
                            && outcome_ids.contains("RESILIENT-000")
                        {
                            assigned = Some("RESILIENT-000");
                        } else if (id_uc.starts_with("ZERO-WASTE-") || id_uc.starts_with("ZERO-"))
                            && outcome_ids.contains("ZERO-WASTE-000")
                        {
                            assigned = Some("ZERO-WASTE-000");
                        }
                    }

                    // Heuristic 8 (MISSION-043): INFRA-* and META-* → MISSION-010.
                    // INFRA gaps are fleet infrastructure gaps; they collectively implement
                    // the self-coordinating-fleet mission. META-* gaps are fleet PM/process
                    // gaps that support mission coordination. Both route to MISSION-010
                    // as the umbrella fleet-mission outcome.
                    // Only fires when MISSION-010 is registered.
                    if assigned.is_none()
                        && outcome_ids.contains("MISSION-010")
                        && (id_uc.starts_with("INFRA-") || id_uc.starts_with("META-"))
                    {
                        assigned = Some("MISSION-010");
                    }

                    match assigned {
                        Some(oid) => {
                            changes.push((g.id.clone(), oid.to_string()));
                            *counts.entry(oid).or_default() += 1;
                        }
                        None => {
                            skipped += 1;
                        }
                    }
                }

                // Report plan.
                println!("Backfill plan:");
                for o in &outcomes {
                    let c = counts.get(o.id.as_str()).copied().unwrap_or(0);
                    if c > 0 {
                        println!("  {} ← {} gap(s)", o.id, c);
                    }
                }
                println!("  already linked: {}", already_linked);
                println!("  unmatched (skipped): {}", skipped);
                println!("  total to link: {}", changes.len());

                if dry_run {
                    println!();
                    println!("[dry-run] no changes written. Re-run with --apply to commit.");
                    return Ok(());
                }

                // Apply.
                let mut applied = 0usize;
                let mut errors = 0usize;
                for (gid, oid) in &changes {
                    let update = gap_store::GapFieldUpdate {
                        outcome_id: Some(oid.clone()),
                        ..Default::default()
                    };
                    match store.set_fields(gid, update) {
                        Ok(()) => {
                            applied += 1;
                        }
                        Err(e) => {
                            eprintln!("  WARN: could not link {} → {}: {}", gid, oid, e);
                            errors += 1;
                        }
                    }
                }
                println!();
                if json_out {
                    println!(
                        r#"{{"applied":{},"errors":{},"already_linked":{},"skipped":{}}}"#,
                        applied, errors, already_linked, skipped
                    );
                } else {
                    println!("applied {} link(s), {} error(s)", applied, errors);
                    // Emit ambient event for observability.
                    let lock_dir = repo_root.join(".chump-locks");
                    let ambient = lock_dir.join("ambient.jsonl");
                    let ts = std::process::Command::new("date")
                        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                        .output()
                        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                        .unwrap_or_default();
                    // scanner-anchor: outcome_backfill_completed (MISSION-030)
                    let event = format!(
                        r#"{{"ts":"{ts}","kind":"outcome_backfill_completed","applied":{applied},"errors":{errors},"skipped":{skipped}}}"#,
                    );
                    let _ = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&ambient)
                        .and_then(|mut f| {
                            use std::io::Write;
                            writeln!(f, "{}", event)
                        });
                }
            }
            // RESILIENT-254: `park <outcome-id> --reason "..."` — declare that
            // an outcome with open, non-moving children is parked ON PURPOSE.
            // Excludes it from the L5-SLO-2 commitment-rot breach so a
            // deliberate decision doesn't train the operator to ignore SLOs.
            "park" => {
                let oid = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome park <outcome-id> --reason \"...\"");
                    std::process::exit(2);
                });
                let reason = oflag("--reason").unwrap_or_else(|| {
                    eprintln!("chump outcome park: --reason required (why is this on hold?)");
                    std::process::exit(2);
                });
                match store.park_outcome(&oid, &reason) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"outcome_id":"{oid}","status":"parked","park_reason":"{}"}}"#,
                                reason.replace('"', "\\\"")
                            );
                        } else {
                            println!("{} parked: {}", oid, reason);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome park: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "unpark" => {
                let oid = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome unpark <outcome-id>");
                    std::process::exit(2);
                });
                match store.unpark_outcome(&oid) {
                    Ok(()) => {
                        if json_out {
                            println!(r#"{{"outcome_id":"{oid}","status":"open"}}"#);
                        } else {
                            println!("{} unparked (status: open)", oid);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome unpark: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            _ => {
                println!("Usage: chump outcome <sub> [args]");
                println!();
                println!("Subcommands:");
                println!("  create --id X --title T [--priority P] [--dod D]");
                println!("  list [--status open|done] [--json]");
                println!("  show <outcome-id> [--json]");
                println!("  link <gap-id> --outcome <outcome-id>");
                println!("  unlink <gap-id>");
                println!(
                    "  park <outcome-id> --reason \"...\"   (RESILIENT-254: exempt from L5-SLO-2)"
                );
                println!("  unpark <outcome-id>");
                println!("  bootstrap   (seed 8 outcomes: MISSION-010/012/032 + META-067 + 4 pillar outcomes)");
                println!("  backfill [--dry-run] [--apply]");
                println!();
                println!(
                    "ADVISORY: outcome rollup never gates or blocks a child gap from closing."
                );
            }
        }
        return Ok(());
    }

    // MISSION-033: `chump repos <sub>` — first-class repo index commands.
    // chump repos list [--status active|paused|archived] [--json]
    // chump repos show <owner/repo> [--json]
    // chump repos add <owner/repo> [--cascade-tier T] [--status S]
    // chump repos set <owner/repo> --cascade-tier T | --status S | --last-clone-at N | ...
    // chump repos rm <owner/repo>
    //
    // Derived index: repos table is populated by auto-upsert on `chump gap import`
    // for every external_repo:* tag in gaps.skills_required. Manual add also supported.
    if args.get(1).map(String::as_str) == Some("repos") {
        let sub = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump repos: {e:#}");
                std::process::exit(1);
            }
        };
        let rflag = |name: &str| -> Option<String> {
            args.windows(2)
                .find(|w| w[0] == name)
                .and_then(|w| w.get(1))
                .cloned()
        };
        let json_out = args.iter().any(|a| a == "--json");

        match sub {
            "list" => {
                let status_filter = rflag("--status");
                let repos = match store.list_repos(status_filter.as_deref()) {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("chump repos list: {e:#}");
                        std::process::exit(1);
                    }
                };
                if json_out {
                    let items: Vec<String> = repos
                        .iter()
                        .map(|r| {
                            let gap_count = store.repo_gap_count(&r.id).unwrap_or(0);
                            format!(
                                r#"{{"id":"{}","owner":"{}","name":"{}","added_at":{},"last_scan_at":{},"last_clone_at":{},"last_ship_at":{},"cascade_tier":"{}","status":"{}","gap_count":{}}}"#,
                                r.id.replace('"', "\\\""),
                                r.owner.replace('"', "\\\""),
                                r.name.replace('"', "\\\""),
                                r.added_at,
                                r.last_scan_at.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
                                r.last_clone_at.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
                                r.last_ship_at.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
                                r.cascade_tier,
                                r.status,
                                gap_count,
                            )
                        })
                        .collect();
                    println!("[{}]", items.join(","));
                } else {
                    if repos.is_empty() {
                        println!("(no repos registered — run `chump gap import` or `chump repos add <owner/repo>`)");
                    }
                    for r in &repos {
                        let gap_count = store.repo_gap_count(&r.id).unwrap_or(0);
                        println!(
                            "{} [{}] {} | last_scan={} | last_clone={} | gaps={}",
                            r.id,
                            r.cascade_tier,
                            r.status,
                            r.last_scan_at
                                .map(|v| v.to_string())
                                .unwrap_or_else(|| "never".into()),
                            r.last_clone_at
                                .map(|v| v.to_string())
                                .unwrap_or_else(|| "never".into()),
                            gap_count,
                        );
                    }
                }
            }
            "show" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump repos show <owner/repo> [--json]");
                    std::process::exit(2);
                });
                match store.get_repo(&repo_id) {
                    Ok(Some(r)) => {
                        let gap_count = store.repo_gap_count(&r.id).unwrap_or(0);
                        if json_out {
                            println!(
                                r#"{{"id":"{}","owner":"{}","name":"{}","added_at":{},"last_scan_at":{},"last_clone_at":{},"last_ship_at":{},"cascade_tier":"{}","status":"{}","gap_count":{}}}"#,
                                r.id.replace('"', "\\\""),
                                r.owner.replace('"', "\\\""),
                                r.name.replace('"', "\\\""),
                                r.added_at,
                                r.last_scan_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "null".into()),
                                r.last_clone_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "null".into()),
                                r.last_ship_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "null".into()),
                                r.cascade_tier,
                                r.status,
                                gap_count,
                            );
                        } else {
                            println!("=== Repo: {} ===", r.id);
                            println!("Owner        : {}", r.owner);
                            println!("Name         : {}", r.name);
                            println!("Cascade tier : {}", r.cascade_tier);
                            println!("Status       : {}", r.status);
                            println!("Added at     : {}", r.added_at);
                            println!(
                                "Last scan    : {}",
                                r.last_scan_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "never".into())
                            );
                            println!(
                                "Last clone   : {}",
                                r.last_clone_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "never".into())
                            );
                            println!(
                                "Last ship    : {}",
                                r.last_ship_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "never".into())
                            );
                            println!("Linked gaps  : {}", gap_count);
                        }
                    }
                    Ok(None) => {
                        eprintln!("chump repos show: '{}' not found", repo_id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump repos show: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "add" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!(
                        "Usage: chump repos add <owner/repo> [--cascade-tier T] [--status S]"
                    );
                    std::process::exit(2);
                });
                let slash = repo_id.find('/').unwrap_or_else(|| {
                    eprintln!(
                        "chump repos add: id must be 'owner/repo', got '{}'",
                        repo_id
                    );
                    std::process::exit(2);
                });
                let owner = &repo_id[..slash];
                let name = &repo_id[slash + 1..];
                if owner.is_empty() || name.is_empty() {
                    eprintln!("chump repos add: owner and name must be non-empty");
                    std::process::exit(2);
                }
                let cascade_tier = rflag("--cascade-tier").unwrap_or_else(|| "dogfood".into());
                let status = rflag("--status").unwrap_or_else(|| "active".into());
                match store.add_repo(&repo_id, owner, name, &cascade_tier, &status) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"id":"{repo_id}","cascade_tier":"{cascade_tier}","status":"{status}","added":true}}"#
                            );
                        } else {
                            println!(
                                "repo {} added (tier={}, status={})",
                                repo_id, cascade_tier, status
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("chump repos add: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "set" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump repos set <owner/repo> [--cascade-tier T] [--status S] [--last-scan-at N] [--last-clone-at N] [--last-ship-at N]");
                    std::process::exit(2);
                });
                let cascade_tier = rflag("--cascade-tier");
                let status = rflag("--status");
                let last_scan_at = rflag("--last-scan-at").and_then(|v| v.parse::<i64>().ok());
                let last_clone_at = rflag("--last-clone-at").and_then(|v| v.parse::<i64>().ok());
                let last_ship_at = rflag("--last-ship-at").and_then(|v| v.parse::<i64>().ok());
                match store.set_repo_fields(
                    &repo_id,
                    cascade_tier.as_deref(),
                    status.as_deref(),
                    last_scan_at,
                    last_clone_at,
                    last_ship_at,
                ) {
                    Ok(true) => {
                        if json_out {
                            println!(r#"{{"id":"{repo_id}","updated":true}}"#);
                        } else {
                            println!("repo {} updated", repo_id);
                        }
                    }
                    Ok(false) => {
                        eprintln!("chump repos set: '{}' not found — add it first", repo_id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump repos set: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "rm" | "remove" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump repos rm <owner/repo>");
                    std::process::exit(2);
                });
                match store.remove_repo(&repo_id) {
                    Ok(true) => {
                        if json_out {
                            println!(r#"{{"id":"{repo_id}","removed":true}}"#);
                        } else {
                            println!("repo {} removed", repo_id);
                        }
                    }
                    Ok(false) => {
                        eprintln!("chump repos rm: '{}' not found", repo_id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump repos rm: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            _ => {
                println!("Usage: chump repos <sub> [args]");
                println!();
                println!("Subcommands:");
                println!("  list [--status active|paused|archived] [--json]");
                println!("  show <owner/repo> [--json]");
                println!("  add <owner/repo> [--cascade-tier T] [--status S]");
                println!("  set <owner/repo> [--cascade-tier T] [--status S]");
                println!("         [--last-scan-at EPOCH] [--last-clone-at EPOCH] [--last-ship-at EPOCH]");
                println!("  rm <owner/repo>");
                println!();
                println!("Derived index: repos rows are auto-upserted from external_repo:* tags");
                println!("in gaps.skills_required on `chump gap import`. Lifecycle is decoupled");
                println!("from gaps — removing a gap does NOT remove its repo row.");
                println!();
                println!("Daemon-callable: `chump repos set <id> --last-clone-at EPOCH` works");
                println!("without a TTY (used by MISSION-035 clone GC and MISSION-038 scheduler).");
            }
        }
        return Ok(());
    }

    // `chump roadmap-status [--json] [--exit-on-drift] [--top-starved N]`
    // INFRA-606: reads docs/ROADMAP.md, shows 🟢/🟡/🔴 progress per weekly outcome.
    // INFRA-1145: adds starved_outcomes, untraced_p0, pillar_coverage, --exit-on-drift.

    Box::pin(pr_roadmap_modes::dispatch_pr_roadmap(args)).await
}
