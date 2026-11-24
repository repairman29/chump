//! Runtime server modes (`--web`, `--discord`, `--acp`, `--rpc`), MCP, leases, KPI, and REPL.

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

pub(crate) async fn dispatch_runtime_tail(args: Vec<String>) -> Result<()> {
    // `chump cost record-pr` (INFRA-405) — record per-PR cost metrics (tokens, USD, duration).
    // Called by bot-merge.sh at PR creation time to build a telemetry ledger.
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

    // `chump cost-watch [--budget X] [--hard-cap] [--json]` (INFRA-608)
    // Running tally of Anthropic spend vs per-cycle budget. Reads session_end
    // token-cost rows from ambient.jsonl, groups by model, projects monthly,
    // and emits 🔴 when today's spend exceeds the daily budget threshold.
    // --hard-cap exits 1 when over budget (blocks fleet spawn).
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
                    .and_then(|s| s.parse().ok())
            })
            .unwrap_or(5.0_f64);
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

    // `chump cost-check [--gap-id ID] [--model MODEL]` (INFRA-877)
    // Check daily spend against CHUMP_DAILY_BUDGET_USD and emit cost_quota_warning
    // or cost_quota_exceeded events to ambient.jsonl.  Exit 0 = ok, 1 = warning,
    // 2 = exceeded (spawn should be blocked).
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

    // `chump kpi report` (INFRA-617) — exec-summary view of mission progress.
    // Sections: ship rate trend (1d/7d/30d), mission grade history, cost savings
    // vs Anthropic-only baseline, top productizations by leverage, tokens-per-ship.
    // Flags:
    //   --tokens-per-ship N   only show tokens-per-ship section (backward compat)
    //   --json                machine-readable JSON output
    //   --pdf                 pipe markdown through pandoc for grant pitches
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
        let want_claims = args.iter().any(|a| a == "--claims");
        let want_integration = args.iter().any(|a| a == "--integration");
        let want_mission_binary = args.iter().any(|a| a == "--mission-binary");
        let want_debt_index = args.iter().any(|a| a == "--debt-index");
        let want_shell_invariant_writers = args.iter().any(|a| a == "--shell-invariant-writers");
        let no_gate = args.iter().any(|a| a == "--no-gate");
        let want_ci_pickup = args.iter().any(|a| a == "--ci-pickup");

        let repo_root = repo_path::repo_root();

        // CREDIBLE-1509: --shell-invariant-writers shows the R6.4 gauge only —
        // the invariant-boundary gate's violator file count + reading date.
        // --no-gate never runs the ~20s gate (fast callers such as fleet-brief).
        if want_shell_invariant_writers {
            let section =
                kpi_report::build_shell_invariant_writers_section_with(&repo_root, !no_gate);
            if want_json {
                println!("{}", section.render_json());
            } else {
                print!("{}", section.render_text());
            }
            return Ok(());
        }

        // CREDIBLE-1512: --ci-pickup shows runner pickup-latency p50/p95 per hour
        // + ci_runs_queued. With --emit-if-starved, writes kind=ci_runner_starved
        // to ambient.jsonl when the trailing-30-min p50 exceeds 10 min (the
        // detector that pages the operator on hosted-runner starvation). A
        // periodic launchd/cron job runs `--ci-pickup --emit-if-starved`; the
        // data is collected out-of-band by scripts/ci/ci-pickup-collect.sh.
        if want_ci_pickup {
            let window_hours = flag("--window")
                .and_then(|w| {
                    let w = w.trim();
                    if let Some(h) = w.strip_suffix('h') {
                        h.parse::<u64>().ok()
                    } else if let Some(d) = w.strip_suffix('d') {
                        d.parse::<u64>().ok().map(|d| d.saturating_mul(24))
                    } else {
                        w.parse::<u64>().ok()
                    }
                })
                .unwrap_or(24);
            let report =
                chump_kpi_report::ci_pickup::build_ci_pickup_report(&repo_root, window_hours);
            if args.iter().any(|a| a == "--emit-if-starved") {
                match chump_kpi_report::ci_pickup::emit_runner_starved_if_needed(
                    &repo_root, &report,
                ) {
                    Ok(true) => eprintln!("chump kpi report: emitted kind=ci_runner_starved"),
                    Ok(false) => {}
                    Err(e) => eprintln!("chump kpi report: ci_runner_starved emit failed: {e}"),
                }
            }
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            return Ok(());
        }

        // MISSION-066: --mission-binary shows ① THE BINARY repeatability —
        // the current/longest zero-touch-BEAST-merge streak recorded by
        // scripts/dev/mission-scoreboard.sh's mission_binary_check events.
        if want_mission_binary {
            let section = kpi_report::build_mission_binary_section(&repo_root);
            if want_json {
                println!("{}", section.render_json());
            } else {
                print!("{}", section.render_text());
            }
            return Ok(());
        }

        // INFRA-2143: --integration shows the integration-cycle dashboard
        // (ship velocity / CI efficiency / quality / external costs).
        // --window accepts "24h", "7d", "30d" (bare digits treated as days);
        // default window is 7d.
        if want_integration {
            let window_hours = flag("--window")
                .map(|w| {
                    let w = w.trim();
                    if let Some(h) = w.strip_suffix('h') {
                        h.parse::<u64>().unwrap_or(168)
                    } else if let Some(d) = w.strip_suffix('d') {
                        d.parse::<u64>().unwrap_or(7).saturating_mul(24)
                    } else {
                        w.parse::<u64>().unwrap_or(7).saturating_mul(24)
                    }
                })
                .unwrap_or(168);
            let section = kpi_report::build_integration_cycle_section(&repo_root, window_hours);
            if want_json {
                println!("{}", section.render_json());
            } else {
                print!("{}", section.render_text());
            }
            return Ok(());
        }

        // CREDIBLE-208: --claims shows claim-lint bust-rate per model.
        if want_claims {
            let section = kpi_report::build_claim_bust_section(&repo_root);
            if want_json {
                println!("{}", section.render_json());
            } else {
                print!("{}", section.render_text());
            }
            return Ok(());
        }

        // CREDIBLE-357: --debt-index shows the crown gauge (live_pct/debt/
        // top-5 dormant-by-Crit) + next_best_action candidate list.
        if want_debt_index {
            let section = kpi_report::build_debt_index_section(&repo_root);
            if want_json {
                println!("{}", section.render_json());
            } else {
                print!("{}", section.render_text());
            }
            return Ok(());
        }

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
            // CREDIBLE-1525: emit kind=admin_merge_executed for each newly-detected
            // admin merge (deduped by PR number), so floor_temp and consumers see
            // the same signal the counter is built from.
            match chump_kpi_report::admin_merges::emit_admin_merge_events(
                &repo_root,
                &report.admin_merges,
            ) {
                Ok(n) if n > 0 => {
                    eprintln!("chump kpi report: emitted {n} kind=admin_merge_executed")
                }
                Ok(_) => {}
                Err(e) => eprintln!("chump kpi report: admin_merge_executed emit failed: {e}"),
            }
            let output = if want_json {
                report.render_json()
            } else {
                // CREDIBLE-1493 (Phase R R7): the gauges below carry their
                // calibration score on top.
                format!(
                    "{}\n{}",
                    commands::calibrate::banner_line(),
                    report.render_text()
                )
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
                    use std::io::Write;
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

    // `chump dispatch route <GAP-ID>` (COG-035) — print the candidate cascade
    // the dispatcher would walk for a given gap. Reads priority/effort from
    // .chump/state.db and the routing table from docs/dispatch/routing.yaml
    // (falls back to the hardcoded table when YAML is missing).
    if args.get(1).map(String::as_str) == Some("dispatch")
        && args.get(2).map(String::as_str) == Some("route")
    {
        let gap_id = match args.get(3) {
            Some(s) if !s.is_empty() => s.clone(),
            _ => {
                eprintln!("Usage: chump dispatch route <GAP-ID>");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
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

        let task_class = chump_orchestrator::dispatch::task_class_for_gap_id(&row.id);
        let cands = chump_orchestrator::dispatch::select_candidates_for_gap(
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

    // `chump dispatch scoreboard` (COG-036) — print aggregated dispatch
    // outcomes per (task_class, backend, model, provider_pfx) route. Reads
    // from `routing_outcomes` in `.chump/state.db`, which the orchestrator
    // monitor appends to on every terminal DispatchOutcome.
    if args.get(1).map(String::as_str) == Some("dispatch")
        && args.get(2).map(String::as_str) == Some("scoreboard")
    {
        let repo_root = repo_path::repo_root();
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

    // `chump brain` (INFRA-1773) — unified read surface over the three
    // stores an agent's "brain" is scattered across today: memory_db
    // (sessions/chump_memory.db `chump_memory` table, semantic facts),
    // reflection_db (same DB, `chump_reflections`/`chump_improvement_targets`
    // tables, postmortem lessons), and routing_outcomes (`.chump/state.db`,
    // per-backend dispatch scoreboard — the "per-bot" slice). `chump dispatch
    // scoreboard` already exposes routing_outcomes standalone; `brain`'s job
    // is the *unified* view so an operator doesn't have to remember three
    // separate subcommands to answer "what does the fleet know and how well
    // is each bot doing." Mutation (the gap title's "mutate" half) is
    // intentionally out of scope for this first cut — every mutation path
    // here already has a dedicated, reviewed entrypoint (`memory_brain` tool,
    // `save_reflection`, the orchestrator monitor's routing_outcomes
    // writer) and a generic `chump brain set` would just be an unreviewed
    // side door onto the same tables. Incremental path to the "mega-brain"
    // stretch goal in the gap title: add write verbs here once a concrete
    // cross-store mutation need shows up, not speculatively.
    if args.get(1).map(String::as_str) == Some("brain") {
        let want_json = args.iter().any(|a| a == "--json");
        match args.get(2).map(String::as_str) {
            Some("status") | None => {
                let mem_count = memory_db::count().unwrap_or(-1);
                let reflection_counts = reflection_db::outcome_class_counts().unwrap_or_default();
                let repo_root = repo_path::repo_root();
                let per_backend: Vec<(String, u64, u64, u64)> =
                    match gap_store::GapStore::open(&repo_root) {
                        Ok(store) => {
                            let mut agg: std::collections::BTreeMap<String, (u64, u64, u64)> =
                                std::collections::BTreeMap::new();
                            if let Ok(entries) = store.routing_scoreboard() {
                                for e in entries {
                                    let slot = agg.entry(e.backend.clone()).or_default();
                                    slot.0 += e.successes;
                                    slot.1 += e.failures;
                                    slot.2 += e.total;
                                }
                            }
                            agg.into_iter().map(|(k, (s, f, t))| (k, s, f, t)).collect()
                        }
                        Err(_) => Vec::new(),
                    };

                if want_json {
                    let reflections_json: Vec<_> = reflection_counts
                        .iter()
                        .map(|(k, v)| serde_json::json!({"outcome_class": k, "count": v}))
                        .collect();
                    let backends_json: Vec<_> = per_backend
                        .iter()
                        .map(|(backend, s, f, t)| {
                            serde_json::json!({
                                "backend": backend, "successes": s, "failures": f, "total": t
                            })
                        })
                        .collect();
                    let out = serde_json::json!({
                        "memory_count": mem_count,
                        "reflections_by_outcome": reflections_json,
                        "routing_by_backend": backends_json,
                    });
                    println!("{}", serde_json::to_string_pretty(&out)?);
                } else {
                    println!("chump brain status");
                    println!();
                    println!(
                        "memory_db (chump_memory)      : {} row(s)",
                        if mem_count < 0 {
                            "unavailable".to_string()
                        } else {
                            mem_count.to_string()
                        }
                    );
                    println!("reflection_db (chump_reflections):");
                    if reflection_counts.is_empty() {
                        println!("  (no reflections recorded yet)");
                    }
                    for (class, n) in &reflection_counts {
                        println!("  {class:<12}: {n}");
                    }
                    println!("routing_outcomes (per bot/backend):");
                    if per_backend.is_empty() {
                        println!("  (no routing outcomes recorded yet)");
                    }
                    for (backend, s, f, t) in &per_backend {
                        let rate = if *t > 0 {
                            (*s as f64 / *t as f64) * 100.0
                        } else {
                            0.0
                        };
                        println!("  {backend:<14}: {s} ok / {f} fail / {t} total ({rate:.1}%)");
                    }
                }
                return Ok(());
            }
            Some("query") => {
                let store_name = match args.get(3) {
                    Some(s) => s.as_str(),
                    None => {
                        eprintln!("Usage: chump brain query <memory|reflections|routing> [--limit N] [--bot NAME] [--json]");
                        std::process::exit(2);
                    }
                };
                let limit: usize = args
                    .iter()
                    .position(|a| a == "--limit")
                    .and_then(|i| args.get(i + 1))
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(20);
                let bot_filter = args
                    .iter()
                    .position(|a| a == "--bot")
                    .and_then(|i| args.get(i + 1))
                    .cloned();

                match store_name {
                    "memory" => {
                        let mut rows = memory_db::load_all().unwrap_or_default();
                        rows.truncate(limit);
                        if want_json {
                            println!("{}", serde_json::to_string_pretty(&rows)?);
                        } else if rows.is_empty() {
                            println!("(no memory rows)");
                        } else {
                            for r in &rows {
                                println!(
                                    "[{}] ({}) {} — {}",
                                    r.id,
                                    r.memory_type,
                                    r.ts,
                                    r.content.chars().take(100).collect::<String>()
                                );
                            }
                        }
                    }
                    "reflections" => {
                        let rows =
                            reflection_db::recent_reflections_brief(limit).unwrap_or_default();
                        if want_json {
                            println!("{}", serde_json::to_string_pretty(&rows)?);
                        } else if rows.is_empty() {
                            println!("(no reflections)");
                        } else {
                            for r in &rows {
                                println!(
                                    "[{}] ({}) {} — {}",
                                    r.id,
                                    r.outcome_class,
                                    r.created_at,
                                    r.intended_goal.chars().take(100).collect::<String>()
                                );
                            }
                        }
                    }
                    "routing" => {
                        let repo_root = repo_path::repo_root();
                        let store = match gap_store::GapStore::open(&repo_root) {
                            Ok(s) => s,
                            Err(e) => {
                                eprintln!("chump brain query routing: cannot open state.db: {e:#}");
                                std::process::exit(1);
                            }
                        };
                        let mut entries = store.routing_scoreboard().unwrap_or_default();
                        if let Some(bot) = &bot_filter {
                            entries.retain(|e| &e.backend == bot);
                        }
                        entries.truncate(limit);
                        if want_json {
                            let json: Vec<_> = entries
                                .iter()
                                .map(|e| {
                                    serde_json::json!({
                                        "task_class": e.task_class,
                                        "backend": e.backend,
                                        "model": e.model,
                                        "provider_pfx": e.provider_pfx,
                                        "successes": e.successes,
                                        "failures": e.failures,
                                        "total": e.total,
                                        "success_rate": e.success_rate,
                                        "avg_cost_usd": e.avg_cost_usd,
                                        "route_score": e.route_score,
                                        "last_seen": e.last_seen,
                                    })
                                })
                                .collect();
                            println!("{}", serde_json::to_string_pretty(&json)?);
                        } else if entries.is_empty() {
                            println!("(no routing outcomes)");
                        } else {
                            for e in &entries {
                                println!(
                                    "{:<10}{:<14}{:<40}{:>6} ok {:>6} fail  {:.1}%",
                                    if e.task_class.is_empty() {
                                        "-"
                                    } else {
                                        &e.task_class
                                    },
                                    e.backend,
                                    if e.model.is_empty() { "-" } else { &e.model },
                                    e.successes,
                                    e.failures,
                                    e.success_rate * 100.0,
                                );
                            }
                        }
                    }
                    other => {
                        eprintln!(
                            "chump brain query: unknown store '{other}' (expected memory|reflections|routing)"
                        );
                        std::process::exit(2);
                    }
                }
                return Ok(());
            }
            Some(other) => {
                eprintln!("chump brain: unknown subcommand '{other}' (expected status|query)");
                std::process::exit(2);
            }
        }
    }

    // `chump dispatch simulate <task_class> <count>` (COG-037) — sample
    // the Thompson-flag-enabled candidate cascade `count` times for a
    // synthetic gap of the given task_class and print a histogram of
    // which arm came first. Lets operators sanity-check the sampler's
    // decisions on whatever scoreboard data is currently in
    // `.chump/state.db`. Always runs the Thompson path regardless of
    // whether `cog_037` is in `CHUMP_FLAGS` — `simulate` is the
    // diagnostic for the sampler itself.
    //
    // task_class examples: `research` (EVAL-/RESEARCH-prefixed gaps),
    // `dispatch` (other), or `-` for "no task_class" (matches the v1
    // default cascade only).
    if args.get(1).map(String::as_str) == Some("dispatch")
        && args.get(2).map(String::as_str) == Some("simulate")
    {
        let task_class = match args.get(3) {
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

        // Build a synthetic gap id whose task_class_for_gap_id() answer
        // matches the requested task_class. The dispatch crate's
        // task_class_for_gap_id only recognises EVAL-/RESEARCH- prefixes
        // today, so map "research" → "EVAL-SIM" and any other token → a
        // non-prefixed id (yielding task_class=None).
        let synthetic_gap_id = match task_class.as_str() {
            "research" => "EVAL-SIM-COG-037",
            "-" | "" | "none" => "INFRA-SIM-COG-037",
            _ => "INFRA-SIM-COG-037",
        };

        // Use a synthetic priority/effort that exercises the default
        // cascade (P2/m → no special route) so the simulator focuses on
        // the sampler, not the YAML routing rules. Operators who want to
        // simulate a specific route can edit routing.yaml first.
        let priority = "P2";
        let effort = "m";

        // Fixed seed so two consecutive `simulate` runs print identical
        // histograms (helpful for diffing scoreboard changes). Override
        // via `CHUMP_SIMULATE_SEED` for variance probing.
        let seed: u64 = std::env::var("CHUMP_SIMULATE_SEED")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0xC06_037);

        use chump_orchestrator::dispatch::select_candidates_for_gap_with_rng;
        use rand::SeedableRng;
        use std::collections::BTreeMap;

        let mut rng = rand::rngs::StdRng::seed_from_u64(seed);
        let mut hist: BTreeMap<String, (usize, String)> = BTreeMap::new();
        // Sniff the cascade once so we can label the histogram with the
        // arm's `why` rationale alongside the signature.
        let preview = select_candidates_for_gap_with_rng(
            &repo_root,
            synthetic_gap_id,
            priority,
            effort,
            &mut rand::rngs::StdRng::seed_from_u64(seed),
        );
        if preview.is_empty() {
            println!(
                "No candidates produced for task_class={task_class} (synthetic gap {synthetic_gap_id}, P2/m). \
                 Check docs/dispatch/routing.yaml."
            );
            return Ok(());
        }
        for c in &preview {
            hist.entry(c.signature()).or_insert((0, c.why.clone()));
        }

        for _ in 0..count {
            let cands = select_candidates_for_gap_with_rng(
                &repo_root,
                synthetic_gap_id,
                priority,
                effort,
                &mut rng,
            );
            if let Some(first) = cands.first() {
                hist.entry(first.signature())
                    .or_insert((0, first.why.clone()))
                    .0 += 1;
            }
        }

        println!(
            "Thompson simulate: task_class={task_class}, gap={synthetic_gap_id}, \
             priority={priority}, effort={effort}, trials={count}, seed={seed}"
        );
        println!();
        println!(
            "{:<5}{:<46}{:>8}{:>8}  why",
            "rank", "signature (backend|model|provider)", "picks", "rate%"
        );
        let mut rows: Vec<(String, usize, String)> = hist
            .into_iter()
            .map(|(sig, (n, why))| (sig, n, why))
            .collect();
        rows.sort_by_key(|b| std::cmp::Reverse(b.1));
        for (i, (sig, n, why)) in rows.iter().enumerate() {
            let pct = (*n as f64) * 100.0 / (count as f64);
            println!("{:<5}{:<46}{:>8}{:>7.1}%  {}", i + 1, sig, n, pct, why);
        }
        return Ok(());
    }

    // `chump dispatch cost-report` (INFRA-405) — print per-PR cost telemetry.
    // Reads from .chump/pr_costs.db and outputs TSV with optional per-model/per-domain aggregation.
    if args.get(1).map(String::as_str) == Some("dispatch")
        && args.get(2).map(String::as_str) == Some("cost-report")
    {
        let per_model = args.iter().any(|a| a == "--per-model");
        let per_domain = args.iter().any(|a| a == "--per-domain");

        let repo_root = repo_path::repo_root();
        let records = match cost_tracker::query_pr_costs(&repo_root) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("chump dispatch cost-report: {e:#}");
                std::process::exit(1);
            }
        };

        if records.is_empty() {
            println!("no PR cost records found");
            return Ok(());
        }

        if per_domain {
            use std::collections::HashMap;
            let mut by_domain: HashMap<String, (i64, i64, f64, i64)> = HashMap::new();
            for r in &records {
                let domain = r.gap_id.split('-').next().unwrap_or("unknown").to_string();
                let entry = by_domain.entry(domain).or_insert((0, 0, 0.0, 0));
                entry.0 += r.tokens_in;
                entry.1 += r.tokens_out;
                entry.2 += r.usd_cost;
                entry.3 += 1;
            }
            let mut items: Vec<_> = by_domain.into_iter().collect();
            items.sort_by(|a, b| a.0.cmp(&b.0));
            println!("domain\ttokens_in\ttokens_out\tusd_cost\tpr_count");
            for (domain, (in_tokens, out_tokens, cost, count)) in items {
                println!(
                    "{}\t{}\t{}\t{:.4}\t{}",
                    domain, in_tokens, out_tokens, cost, count
                );
            }
        } else if per_model {
            use std::collections::HashMap;
            let mut by_model: HashMap<String, (i64, i64, f64, i64)> = HashMap::new();
            for r in &records {
                let entry = by_model.entry(r.model.clone()).or_insert((0, 0, 0.0, 0));
                entry.0 += r.tokens_in;
                entry.1 += r.tokens_out;
                entry.2 += r.usd_cost;
                entry.3 += 1;
            }
            let mut items: Vec<_> = by_model.into_iter().collect();
            items.sort_by(|a, b| a.0.cmp(&b.0));
            println!("model\ttokens_in\ttokens_out\tusd_cost\tpr_count");
            for (model, (in_tokens, out_tokens, cost, count)) in items {
                println!(
                    "{}\t{}\t{}\t{:.4}\t{}",
                    model, in_tokens, out_tokens, cost, count
                );
            }
        } else {
            println!("pr\tgap\tmodel\ttokens_in\ttokens_out\tusd_cost\tduration_secs\tbackend");
            for r in &records {
                println!(
                    "{}\t{}\t{}\t{}\t{}\t{:.4}\t{}\t{}",
                    r.pr_number,
                    r.gap_id,
                    r.model,
                    r.tokens_in,
                    r.tokens_out,
                    r.usd_cost,
                    r.duration_secs,
                    r.backend
                );
            }
        }
        return Ok(());
    }

    // `chump dispatch` with no/unknown subcommand — print help.
    if args.get(1).map(String::as_str) == Some("dispatch") {
        eprintln!("Usage: chump dispatch <subcommand>");
        eprintln!();
        eprintln!("  route       <GAP-ID>            print the candidate cascade for a gap");
        eprintln!(
            "  scoreboard                      aggregate dispatch outcomes (COG-036) by route"
        );
        eprintln!(
            "  simulate    <task_class> <N>    sample the Thompson cascade N times (COG-037)"
        );
        eprintln!("  cost-report [--per-model|--per-domain]  per-PR cost telemetry (INFRA-405)");
        std::process::exit(2);
    }

    // `chump --pick-gap` (INFRA-DISPATCH-POLICY) — policy-aware gap selector.
    //
    // Reads docs/gaps.yaml + .chump-locks/ + CHUMP_DISPATCH_CAPACITY and runs
    // the musher dispatch policy to find the single best gap to dispatch next.
    // Prints the gap ID to stdout, or "none" if all gaps are blocked (capacity
    // full, all live-claimed, deps unmet, or backlog empty).
    //
    // Intended for use in shell scripts and the musher dispatcher:
    //   GAP=$(chump --pick-gap) && [ "$GAP" != "none" ] && scripts/coord/gap-claim.sh "$GAP"
    //
    // Exit codes: 0 always (even when result is "none") — callers check stdout.
    if args.iter().any(|a| a == "--pick-gap") {
        use chump_orchestrator::{dispatch_capacity, done_ids, load_gaps, pick_gap};
        use std::collections::HashSet;

        let repo_root = repo_path::repo_root();
        let gaps_path = repo_root.join("docs/gaps.yaml");
        let all = match load_gaps(&gaps_path) {
            Ok(g) => g,
            Err(e) => {
                eprintln!("chump --pick-gap: could not load gaps.yaml: {e:#}");
                std::process::exit(1);
            }
        };
        let done = done_ids(&all);

        // Collect live-claimed gap IDs from .chump-locks/ (gap_id + INFRA-021 pending_new_gap.id).
        let active_leases = agent_lease::list_active();
        let mut live_claimed: HashSet<String> = active_leases
            .iter()
            .filter_map(|l| l.gap_id.clone())
            .collect();
        for lease in &active_leases {
            if let Some(p) = &lease.pending_new_gap {
                live_claimed.insert(p.id.clone());
            }
        }
        let active_count = live_claimed.len();

        let capacity = dispatch_capacity();
        match pick_gap(&all, &done, &live_claimed, active_count, capacity) {
            Some(gap) => println!("{}", gap.id),
            None => println!("none"),
        }
        return Ok(());
    }

    // `chump --execute-gap <GAP-ID>` (COG-025) — unattended single-gap
    // dispatch mode. Used by `chump-orchestrator` when
    // CHUMP_DISPATCH_BACKEND=chump-local. Drives the multi-turn agent loop
    // through whatever provider OPENAI_API_BASE+OPENAI_MODEL resolve to
    // (Together free tier, mistral.rs, Ollama, hosted OpenAI). The
    // entire purpose is cost-routing autonomous PR shipping off Anthropic.
    //
    // Caller contract: gap is already claimed in the current worktree,
    // CHUMP_DISPATCH_DEPTH=1 is set in env, OPENAI_* env points at the
    // desired backend. Prints the agent's final reply to stdout (monitor
    // parses for PR number); exit-code 1 on agent-loop failure, 2 on
    // usage error.
    if let Some(pos) = args.iter().position(|a| a == "--execute-gap") {
        let gap_id = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if gap_id.is_empty() || gap_id.starts_with("--") {
            eprintln!("Usage: chump --execute-gap <GAP-ID>");
            std::process::exit(2);
        }
        config_validation::validate_config();
        // INFRA-843: read required_model from gap registry and override
        // FLEET_MODEL so execute_gap picks up the right model tier.
        // Falls back to FLEET_MODEL env then default sonnet if unset.
        let mut external_repo_target: Option<String> = None;
        {
            let repo_root = repo_path::repo_root();
            if let Ok(store) = gap_store::GapStore::open(&repo_root) {
                if let Ok(Some(g)) = store.get(gap_id) {
                    if !g.required_model.is_empty() {
                        let prev = std::env::var("FLEET_MODEL").ok();
                        std::env::set_var("FLEET_MODEL", &g.required_model);
                        eprintln!(
                            "[execute-gap] INFRA-843: required_model={} (was {:?})",
                            g.required_model,
                            prev.as_deref().unwrap_or("unset")
                        );
                    }
                    external_repo_target = external_repo_target_from_skills(&g.skills_required);
                }
            }
        }
        // MISSION-046: a gap tagged `external_repo:OWNER/REPO` cannot be executed
        // by the internal agent loop (it runs in the Chump worktree). Route to
        // `chump improve OWNER/REPO --apply`, which clones the target, implements
        // in the clone, opens a PR on the EXTERNAL repo, and verify-merges. Without
        // this, the mesh-worker's `--execute-gap` silently runs the internal loop
        // against the wrong repo — the #1 blocker to the first BEAST-MODE merge.
        if let Some(owner_repo) = external_repo_target {
            eprintln!(
                "[execute-gap] MISSION-046: gap {gap_id} is external_repo:{owner_repo} -> routing to `chump improve {owner_repo} --apply`"
            );
            // EFFECTIVE-353: pass `--gap <ID>` so improve works the ACTUAL filed
            // gap — not whatever its generic scout / GREEN-FIRST doctrine picks.
            // Without this, `chump --execute-gap PRODUCT-143` silently ran the
            // scout and worked unrelated work; the filed gap never got touched.
            let code = improve::run(&[
                owner_repo,
                "--gap".to_string(),
                gap_id.to_string(),
                "--apply".to_string(),
            ]);
            std::process::exit(code);
        }
        match execute_gap::execute_gap(gap_id).await {
            Ok(reply) => {
                print!("{reply}");
                // INFRA-2055: emit gap_shipped on every clean exit so wizard-daemon
                // gets an explicit signal instead of heuristic-guessing from PID death.
                // Parse the PR number from the agent reply (best-effort; empty = not found).
                let pr_number = execute_gap::parse_pr_number_from_reply(&reply);
                let commit_sha = execute_gap::current_head_sha();
                execute_gap::emit_terminal_outcome(&execute_gap::ExecuteGapOutcome::Shipped {
                    gap_id: gap_id.to_string(),
                    pr_number,
                    commit_sha,
                });
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump --execute-gap {gap_id}: {e:#}");
                // INFRA-302 blocker (1): classify the error so the
                // orchestrator's stderr-tailer can distinguish
                // billing-exhausted (402 / credit_limit class) from
                // generic failures and decide whether to respawn the
                // dispatched child against the next routing-table
                // candidate. See the `Exit codes` section in the
                // execute_gap.rs module docs for the full contract.
                let kind = execute_gap::classify_execute_gap_error(&e);
                if let Some(marker) = kind.stderr_marker() {
                    eprintln!("{marker}");
                }
                // INFRA-2055: emit gap_blocked on EVERY error exit so wizard-daemon
                // gets an explicit terminal signal instead of guessing from PID death.
                let reason = format!("{e:#}");
                let recoverable_by = match kind {
                    execute_gap::ExecuteGapErrorKind::BillingExhausted => "fix_billing",
                    execute_gap::ExecuteGapErrorKind::TransportUnreachable => "restart_daemon",
                    execute_gap::ExecuteGapErrorKind::Other => "manual_rescue",
                };
                execute_gap::emit_terminal_outcome(&execute_gap::ExecuteGapOutcome::Blocked {
                    gap_id: gap_id.to_string(),
                    reason,
                    recoverable_by: recoverable_by.to_string(),
                });
                std::process::exit(kind.exit_code());
            }
        }
    }

    // INFRA-060 (M2): `chump --plan <GAP-ID>` — run the plan-mode gate
    // standalone (no agent loop, no provider call). Writes
    // `.chump-plans/<gap>.md` and exits 0 (proceed) / 1 (abort: queue too
    // crowded) / 2 (usage). Useful for hand-testing, for `bot-merge.sh` to
    // regenerate a stale plan, and to dogfood the gate on the same PR
    // that introduces it.
    if let Some(pos) = args.iter().position(|a| a == "--plan") {
        let gap_id = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if gap_id.is_empty() || gap_id.starts_with("--") {
            eprintln!("Usage: chump --plan <GAP-ID>");
            std::process::exit(2);
        }
        let repo_root = repo_path::repo_root();
        match plan_mode::run_plan_mode(gap_id, &repo_root) {
            Ok(plan_mode::PlanOutcome::Proceed { plan_path }) => {
                if let Some(p) = plan_path {
                    println!("{}", p.display());
                }
                std::process::exit(0);
            }
            Ok(plan_mode::PlanOutcome::Abort { reason, conflicts }) => {
                eprintln!("plan-mode abort: {reason}");
                eprintln!("conflicts: {conflicts:?}");
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("plan-mode error: {e:#}");
                std::process::exit(2);
            }
        }
    }

    // `chump --doctor` — self-diagnosis. Runs before any validate_config() so it
    // works even when the setup is broken. Exit 0 if all ok, 1 if any Fail.
    // `--json` for machine-readable output.
    if args.iter().any(|a| a == "--doctor") {
        let report = doctor::run_all_checks().await;
        // INFRA-877: append budget quota line to human output
        let exit_code = if args.iter().any(|a| a == "--json") {
            doctor::print_json_report(&report)
        } else {
            let code = doctor::print_human_report(&report);
            let quota_line = cost_ledger::doctor_line(&repo_path::repo_root());
            println!("  cost: {quota_line}");
            // Exit non-zero if quota exceeded (spend > 100%)
            let quota = cost_ledger::check_quota(&repo_path::repo_root(), "", "", false);
            if quota.is_exceeded() {
                1
            } else {
                code
            }
        };
        std::process::exit(exit_code);
    }

    let preflight = args.iter().any(|a| a == "--preflight");
    if preflight {
        let script = repo_path::repo_root().join("scripts/ci/chump-preflight.sh");
        if !script.is_file() {
            eprintln!(
                "chump --preflight: missing {} (set CHUMP_REPO/CHUMP_HOME or run from repo clone)",
                script.display()
            );
            std::process::exit(1);
        }
        let forward: Vec<&str> = args
            .iter()
            .skip(1)
            .filter(|a| *a != "--preflight")
            .map(|s| s.as_str())
            .collect();
        let status = std::process::Command::new("bash")
            .arg(script.as_os_str())
            .args(&forward)
            .current_dir(repo_path::repo_root())
            .status();
        match status {
            Ok(s) => std::process::exit(s.code().unwrap_or(1)),
            Err(e) => {
                eprintln!("chump --preflight: could not run bash: {}", e);
                std::process::exit(1);
            }
        }
    }
    tracing_init::init();

    // `chump --plugins-list` — list all discovered on-disk plugins and their search paths.
    // Works without validate_config() so it's useful for diagnosing plugin setup.
    if args.iter().any(|a| a == "--plugins-list") {
        plugin::print_plugins_list();
        return Ok(());
    }
    // `chump --plugins-install <path>` — copy a local plugin directory to ~/.chump/plugins/.
    if let Some(pos) = args.iter().position(|a| a == "--plugins-install") {
        let path = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if path.is_empty() {
            eprintln!("Usage: chump --plugins-install <path-to-plugin-directory>");
            std::process::exit(1);
        }
        match plugin::plugins_install(path) {
            Ok(name) => {
                println!(
                    "Installed plugin '{name}' to {}",
                    plugin::user_plugins_dir().join(&name).display()
                );
                return Ok(());
            }
            Err(e) => {
                eprintln!("Error: {e:#}");
                std::process::exit(1);
            }
        }
    }
    // `chump --plugins-uninstall <name>` — remove a user plugin by name.
    if let Some(pos) = args.iter().position(|a| a == "--plugins-uninstall") {
        let name = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if name.is_empty() {
            eprintln!("Usage: chump --plugins-uninstall <plugin-name>");
            std::process::exit(1);
        }
        match plugin::plugins_uninstall(name) {
            Ok(()) => {
                println!("Uninstalled plugin '{name}'.");
                return Ok(());
            }
            Err(e) => {
                eprintln!("Error: {e:#}");
                std::process::exit(1);
            }
        }
    }
    // `chump --plugins-disable <name>` — mark a plugin as disabled.
    if let Some(pos) = args.iter().position(|a| a == "--plugins-disable") {
        let name = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if name.is_empty() {
            eprintln!("Usage: chump --plugins-disable <plugin-name>");
            std::process::exit(1);
        }
        match plugin::plugins_disable(name) {
            Ok(()) => {
                println!("Plugin '{name}' disabled.");
                return Ok(());
            }
            Err(e) => {
                eprintln!("Error: {e:#}");
                std::process::exit(1);
            }
        }
    }
    // `chump --plugins-enable <name>` — re-enable a previously disabled plugin.
    if let Some(pos) = args.iter().position(|a| a == "--plugins-enable") {
        let name = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if name.is_empty() {
            eprintln!("Usage: chump --plugins-enable <plugin-name>");
            std::process::exit(1);
        }
        match plugin::plugins_enable(name) {
            Ok(()) => {
                println!("Plugin '{name}' enabled.");
                return Ok(());
            }
            Err(e) => {
                eprintln!("Error: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump mcp list [--installed] [--json]` (PRODUCT-061 / INFRA-744)
    //
    // Default: if chump-mcp.json exists, show the declarative config (INFRA-744).
    //          Otherwise fall back to the registry catalog.
    // --installed: print discovered installed binaries (PATH/user-config/system).
    // --json: machine-readable output for either mode.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "list").unwrap_or(false)
    {
        let installed = args.iter().any(|a| a == "--installed");
        let json = args.iter().any(|a| a == "--json");
        let repo_root = crate::repo_path::repo_root();

        if installed {
            let servers = mcp_discovery::discover_mcp_servers();
            tracing::info!(count = servers.len(), "mcp list --installed");
            mcp_discovery::print_mcp_list(&servers, json);
        } else {
            // INFRA-744: prefer declarative config over registry scan.
            let mcp_config = mcp_discovery::read_mcp_config(&repo_root);
            if !mcp_config.mcp_servers.is_empty() {
                let entries = mcp_discovery::resolve_config_status(&mcp_config);
                tracing::info!(count = entries.len(), "mcp list config");
                mcp_discovery::print_mcp_config_list(&entries, json);
            } else {
                let entries = mcp_discovery::read_registry(&repo_root);
                tracing::info!(count = entries.len(), "mcp list registry");
                mcp_discovery::print_registry(&entries, json);
            }
        }
        return Ok(());
    }

    // `chump mcp restart <name>` (INFRA-744) — kill and restart a configured server.
    //
    // Looks up the server in chump-mcp.json, then signals its process to restart.
    // For now, this prints the command needed to re-launch the server so the
    // operator or process supervisor can act. Full PID tracking is tracked in
    // a follow-up gap.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "restart").unwrap_or(false)
    {
        let name = args.get(3).map(String::as_str).unwrap_or("");
        if name.is_empty() || name.starts_with('-') {
            eprintln!("Usage: chump mcp restart <name>");
            eprintln!("       (run `chump mcp list` to see configured servers)");
            std::process::exit(2);
        }
        let repo_root = crate::repo_path::repo_root();
        let mcp_config = mcp_discovery::read_mcp_config(&repo_root);
        if let Some(entry) = mcp_config.mcp_servers.get(name) {
            if !entry.enabled {
                eprintln!("Server '{name}' is disabled in chump-mcp.json — enable it first.");
                std::process::exit(1);
            }
            let mut cmd_parts = vec![mcp_discovery::expand_command(&entry.command)];
            cmd_parts.extend(entry.args.clone());
            println!("Restart '{name}': {}", cmd_parts.join(" "));
            println!();
            println!(
                "Note: chump mcp restart currently prints the launch command.\n\
                 PID tracking for live restart will be added in a follow-up gap.\n\
                 To restart now, kill the running process and re-run the command above."
            );
        } else if mcp_config.mcp_servers.is_empty() {
            eprintln!(
                "No chump-mcp.json found. Create one to declare servers, then use\n\
                 'chump mcp restart <name>' to restart a specific server."
            );
            std::process::exit(1);
        } else {
            eprintln!("Server '{name}' not found in chump-mcp.json.");
            eprintln!();
            eprintln!("Configured servers:");
            for n in mcp_config.mcp_servers.keys() {
                eprintln!("  {n}");
            }
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump mcp install <name> [--no-install]` (PRODUCT-062)
    //
    // Looks up <name> in registry/mcp-servers.toml, runs `cargo install <package>`
    // (unless binary already on PATH or --no-install), and adds to chump-mcp.json.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "install").unwrap_or(false)
    {
        let name = args.get(3).map(String::as_str).unwrap_or("");
        if name.is_empty() || name.starts_with('-') {
            eprintln!("Usage: chump mcp install <name> [--no-install]");
            eprintln!("       (run 'chump mcp list' to see available servers)");
            std::process::exit(2);
        }
        let no_install = args.iter().any(|a| a == "--no-install");
        let repo_root = crate::repo_path::repo_root();

        match mcp_discovery::install_mcp_server(&repo_root, &repo_root, name, no_install) {
            Ok(mcp_discovery::InstallOutcome::AlreadyInstalled) => {
                println!("Server '{name}' binary already on PATH — added to chump-mcp.json.");
            }
            Ok(mcp_discovery::InstallOutcome::CargoInstalled) => {
                println!("Installed '{name}' and added to chump-mcp.json.");
                println!("Run 'chump mcp list' to verify.");
            }
            Ok(mcp_discovery::InstallOutcome::ConfigOnly) => {
                println!("Added '{name}' to chump-mcp.json (--no-install: binary not installed).");
                println!("Install the binary manually, then run 'chump mcp list' to verify.");
            }
            Err(e) => {
                eprintln!("chump mcp install: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump mcp remove <name>` (PRODUCT-062) — remove server from chump-mcp.json.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "remove").unwrap_or(false)
    {
        let name = args.get(3).map(String::as_str).unwrap_or("");
        if name.is_empty() || name.starts_with('-') {
            eprintln!("Usage: chump mcp remove <name>");
            std::process::exit(2);
        }
        let repo_root = crate::repo_path::repo_root();
        match mcp_discovery::remove_mcp_server(&repo_root, name) {
            Ok(true) => {
                println!("Removed '{name}' from chump-mcp.json.");
                println!("To uninstall the binary: cargo uninstall chump-mcp-{name}");
            }
            Ok(false) => {
                eprintln!("Server '{name}' not found in chump-mcp.json.");
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("chump mcp remove: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump mcp enable <name>` (INFRA-MCP-DISCOVERY) — add a discovered MCP server
    // to the active Chump config.
    //
    // TODO: full implementation. Chump's MCP servers are currently discovered at
    // runtime from CHUMP_MCP_SERVERS_DIR (see mcp_bridge::mcp_servers_dir()) or
    // supplied per-session by ACP clients. There is no persistent per-user config
    // file that stores a set of "enabled" servers; the bridge auto-discovers whatever
    // is in the configured directory. Once a persistent ~/.config/chump/config.toml
    // (or equivalent) exists, `mcp enable` should write the server binary path there.
    // Until then, print a clear message directing the user to place the binary on PATH
    // or in CHUMP_MCP_SERVERS_DIR.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "enable").unwrap_or(false)
    {
        let name = args.get(3).map(String::as_str).unwrap_or("");
        if name.is_empty() || name.starts_with('-') {
            eprintln!("Usage: chump mcp enable <name>");
            eprintln!("       (run `chump mcp list` to see available servers)");
            std::process::exit(2);
        }

        // Look up the server in discovered list
        let servers = mcp_discovery::discover_mcp_servers();
        if let Some(s) = servers.iter().find(|s| s.name == name) {
            println!(
                "Server '{name}' is already discoverable via {} at {}",
                s.source.label(),
                s.path.display()
            );
            println!();
            println!(
                "It will be picked up automatically by the MCP bridge (CHUMP_MCP_SERVERS_DIR)."
            );
            println!("If it is not appearing in `chump mcp list`, check CHUMP_MCP_SERVERS_DIR:");
            println!("  CHUMP_MCP_SERVERS_DIR defaults to <repo>/target/release/");
            println!("  Set it to a directory containing chump-mcp-* binaries to override.");
        } else {
            eprintln!("Server '{name}' not found in any discovery location.");
            eprintln!();
            eprintln!("To install it, place the `chump-mcp-{name}` binary in one of:");
            let user_dir = mcp_discovery::user_config_dir();
            eprintln!("  - A directory on your PATH");
            eprintln!("  - {}", user_dir.display());
            eprintln!("  - /usr/local/bin/");
            eprintln!("Then re-run `chump mcp list` to verify.");
            eprintln!();
            eprintln!("Note: persistent `mcp enable` config storage is not yet implemented.");
            eprintln!("      (INFRA-MCP-DISCOVERY TODO — needs a ~/.config/chump/config.toml)");
            std::process::exit(1);
        }
        return Ok(());
    }

    if args.iter().any(|a| a == "--vector6-verify") {
        config_validation::validate_config();
        return vector6_verify::run().await;
    }
    if args.iter().any(|a| a == "--vector7-swarm-verify") {
        config_validation::validate_config();
        return vector7_swarm_verify::run().await;
    }
    let check_config = args.get(1).map(|s| s == "--check-config").unwrap_or(false);
    if check_config {
        config_validation::validate_config();
        introspect_tool::verify_audit_chain();
        return Ok(());
    }

    // `chump eval run` — EVAL-009: load all eval cases, run each through ChumpAgent,
    // score with check_all_properties (or the async judge variant when
    // CHUMP_EVAL_WITH_JUDGE=1), persist results via save_eval_run, then exit with
    // code 0 if all cases passed or 1 if any failed.
    // battle-qa.sh --with-judge calls this before rendering its judge summary.
    if args.get(1).map(|s| s == "eval").unwrap_or(false)
        && args.get(2).map(|s| s == "run").unwrap_or(false)
    {
        config_validation::validate_config();
        let exit_code = run_eval_runner().await;
        std::process::exit(exit_code);
    }

    // --reflect-ab: EVAL-008 — A/B accuracy comparison of reflect_heuristic vs
    // reflect_via_provider on the labeled episode dataset.
    // Usage: chump --reflect-ab [--reflect-ab-episodes <path>]
    // Set CHUMP_REFLECTION_AB_WITH_LLM=1 to include the provider leg; the run
    // fails loud if the flag is set but no provider is reachable.
    if args.iter().any(|a| a == "--reflect-ab") {
        let episodes_path = args.windows(2).find_map(|w| {
            if w[0] == "--reflect-ab-episodes" {
                Some(std::path::PathBuf::from(&w[1]))
            } else {
                None
            }
        });
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        rt.block_on(async {
            run_reflection_ab_mode(episodes_path).await;
        });
        return Ok(());
    }

    // --eval-judge: seed eval cases, run each LlmJudge property against the configured
    // provider, persist scores to logs/judge-scores.json, print per-category summary.
    // Invoked by `battle-qa.sh --with-judge` for EVAL-005.
    if args.iter().any(|a| a == "--eval-judge") {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        rt.block_on(async {
            run_eval_judge_mode().await;
        });
        return Ok(());
    }

    // --eval-run (EVAL-009): full eval runner. Iterates all chump_eval_cases,
    // runs each through the provider, scores with check_all_properties (and
    // _with_judge_async when CHUMP_EVAL_WITH_JUDGE=1, closing EVAL-007),
    // persists EvalRunResult rows to chump_eval_runs (closing the persistence
    // gap that left battle-qa.sh's summary section reading an empty table).
    // Exit code 0 if every case passes its structural properties, 1 otherwise.
    if args.iter().any(|a| a == "--eval-run") {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let exit_code = rt.block_on(async { run_eval_run_mode().await });
        std::process::exit(exit_code);
    }

    // --eval-reflection (EVAL-008): A/B-grade reflect_via_provider vs
    // reflect_heuristic on tests/fixtures/reflection_episodes.json. Loads the
    // labeled dataset, runs both reflectors against each episode, computes
    // accuracy + confusion matrix per ErrorPattern, and reports pass/fail
    // against the +15% acceptance gate.
    if args.iter().any(|a| a == "--eval-reflection") {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let exit_code = rt.block_on(async { run_eval_reflection_mode().await });
        std::process::exit(exit_code);
    }

    // Also run startup audit check in interactive/discord/default mode
    introspect_tool::verify_audit_chain();

    let reap_leases_mode = args.get(1).map(|s| s == "--reap-leases").unwrap_or(false);
    if reap_leases_mode {
        // Deterministic maintenance: clear expired leases and optionally requeue stuck in_progress tasks.
        // This is intentionally non-LLM and cron-friendly.
        config_validation::validate_config();
        if !task_db::task_available() {
            eprintln!("Task DB not available (sessions dir?)");
            return Ok(());
        }
        let no_requeue = args.iter().any(|a| a == "--no-requeue");
        let stuck_secs = std::env::var("CHUMP_TASK_STUCK_SECS")
            .ok()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .filter(|&n| n >= 60)
            .unwrap_or(1800);
        let cleared = task_db::task_reap_expired_leases().unwrap_or(0);
        let requeued = if no_requeue {
            0
        } else {
            task_db::task_requeue_stuck_in_progress(stuck_secs).unwrap_or(0)
        };
        println!(
            "reap_leases: cleared={} requeued={} stuck_secs={} no_requeue={}",
            cleared, requeued, stuck_secs, no_requeue
        );
        let agent_reaped = agent_lease::reap_expired();
        if agent_reaped > 0 {
            println!("reap_leases: agent_leases_reaped={}", agent_reaped);
        }
        return Ok(());
    }
    // `--leases`: show active agent path leases from `.chump-locks/`.
    let leases_mode = args.get(1).map(|s| s == "--leases").unwrap_or(false);
    if leases_mode {
        let active = agent_lease::list_active();
        if active.is_empty() {
            println!("No active agent leases.");
        } else {
            println!(
                "{} active agent lease(s) (this session: {}):",
                active.len(),
                agent_lease::current_session_id()
            );
            for l in active {
                println!(
                    "  {} expires {} heartbeat {} ({} path{})",
                    l.session_id,
                    l.expires_at,
                    l.heartbeat_at,
                    l.paths.len(),
                    if l.paths.len() == 1 { "" } else { "s" }
                );
                for p in &l.paths {
                    println!("    - {}", p);
                }
                if !l.purpose.is_empty() {
                    println!("    purpose: {}", l.purpose);
                }
                if !l.worktree.is_empty() {
                    println!("    worktree: {}", l.worktree);
                }
            }
        }
        return Ok(());
    }

    // --claim / --release / --heartbeat: shell access to the lease system.
    // Lets scripts, external agents (Cursor via shell wrapper, cron jobs)
    // participate in path-lease coordination without writing JSON by hand.
    // See docs/process/AGENT_COORDINATION.md for the full cheatsheet.
    let claim_mode = args.get(1).map(|s| s == "--claim").unwrap_or(false);
    if claim_mode {
        let paths_arg = args
            .iter()
            .find_map(|a| a.strip_prefix("--paths="))
            .unwrap_or("");
        if paths_arg.is_empty() {
            eprintln!("--claim requires --paths=<comma-separated paths>");
            std::process::exit(2);
        }
        let ttl_secs: u64 = args
            .iter()
            .find_map(|a| a.strip_prefix("--ttl-secs="))
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(agent_lease::DEFAULT_TTL_SECS);
        let purpose = args
            .iter()
            .find_map(|a| a.strip_prefix("--purpose="))
            .unwrap_or("(unspecified)");
        let paths: Vec<&str> = paths_arg
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        if paths.is_empty() {
            eprintln!("--paths= must contain at least one non-empty path");
            std::process::exit(2);
        }
        match agent_lease::claim_paths(&paths, ttl_secs, purpose) {
            Ok(lease) => {
                println!(
                    "claimed session_id={} expires_at={} ({} path{})",
                    lease.session_id,
                    lease.expires_at,
                    lease.paths.len(),
                    if lease.paths.len() == 1 { "" } else { "s" }
                );
                for p in &lease.paths {
                    println!("  - {}", p);
                }
                return Ok(());
            }
            Err(e) => {
                eprintln!("claim failed: {}", e);
                std::process::exit(2);
            }
        }
    }

    let release_mode = args.get(1).map(|s| s == "--release").unwrap_or(false);
    if release_mode {
        // Release a lease by session ID.
        //
        // INFRA-1026: support both --lease <SESSION_ID> (space-separated) and
        // --session-id=<SESSION_ID> (original equals-prefix form). Previously
        // only --session-id= was parsed, so `chump --release --lease <id>`
        // silently ignored <id> and released the current session instead.
        //
        // Lookup precedence: --lease <id> > --session-id=<id> > current session.
        // When --lease or --session-id= is given and the session doesn't exist
        // in the active lease list, exit 1 with a clear message (no silent fallback).
        let override_id_eq = args.iter().find_map(|a| a.strip_prefix("--session-id="));
        let override_id_lease = args.windows(2).find_map(|w| {
            if w[0] == "--lease" {
                Some(w[1].as_str())
            } else {
                None
            }
        });
        let (target_id, explicit_target) = if let Some(id) = override_id_lease {
            (id.to_string(), true)
        } else if let Some(id) = override_id_eq {
            (id.to_string(), true)
        } else {
            (agent_lease::current_session_id(), false)
        };

        let force_release = args.iter().any(|a| a == "--force");

        // Validate explicit targets exist before acting.
        let active = agent_lease::list_active();
        if explicit_target && !active.iter().any(|l| l.session_id == target_id) {
            eprintln!(
                "chump --release: no such session '{}' in active leases.",
                target_id
            );
            eprintln!(
                "  Active sessions: {}",
                if active.is_empty() {
                    "(none)".to_string()
                } else {
                    active
                        .iter()
                        .map(|l| l.session_id.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                }
            );
            eprintln!("  Use 'chump --leases' to list all active sessions.");
            std::process::exit(1);
        }

        // INFRA-1043: when no explicit --lease / --session-id, print what we're
        // about to release and ask for confirmation (unless --force is given).
        // This prevents accidentally releasing the wrong session.
        if !explicit_target && !force_release {
            let current_id = agent_lease::current_session_id();
            let matching_lease = active.iter().find(|l| l.session_id == current_id);
            let gap_str = matching_lease
                .and_then(|l| l.gap_id.as_deref())
                .unwrap_or("(unknown)");
            let age_str = matching_lease
                .map(|l| {
                    if l.taken_at.is_empty() {
                        "unknown age".to_string()
                    } else {
                        // Parse taken_at to compute age
                        chrono::DateTime::parse_from_rfc3339(&l.taken_at)
                            .map(|t| {
                                let secs = (chrono::Utc::now() - t.with_timezone(&chrono::Utc))
                                    .num_seconds();
                                if secs < 120 {
                                    format!("{}s old", secs)
                                } else {
                                    format!("{}m old", secs / 60)
                                }
                            })
                            .unwrap_or_else(|_| "unknown age".to_string())
                    }
                })
                .unwrap_or_else(|| "unknown age".to_string());

            eprintln!(
                "About to release session_id={} (gap={}, {}). \
                 Use --force to skip this confirmation.",
                target_id, gap_str, age_str
            );
            eprintln!("  Confirm? [y/N] ");
            let mut input = String::new();
            if std::io::stdin().read_line(&mut input).is_err()
                || !input.trim().eq_ignore_ascii_case("y")
            {
                eprintln!("Release cancelled.");
                std::process::exit(0);
            }
        }

        let stub = agent_lease::Lease {
            session_id: target_id.clone(),
            paths: vec![],
            taken_at: String::new(),
            expires_at: String::new(),
            heartbeat_at: String::new(),
            purpose: String::new(),
            worktree: String::new(),
            gap_id: None,
            pending_new_gap: None,
            branch: None,
        };
        // Resolve gap_id for the ambient event before release
        let release_gap_id = active
            .iter()
            .find(|l| l.session_id == target_id)
            .and_then(|l| l.gap_id.clone())
            .unwrap_or_default();
        let release_source = if explicit_target {
            "explicit"
        } else {
            "current"
        };

        match agent_lease::release(&stub) {
            Ok(()) => {
                println!("released session_id={}", target_id);
                tracing::info!(
                    session_id = %target_id,
                    explicit_target = explicit_target,
                    "lease released via --release"
                );
                // INFRA-1043: emit ambient event for release observability
                let ambient_path = repo_path::repo_root()
                    .join(".chump-locks")
                    .join("ambient.jsonl");
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
                let _ = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&ambient_path)
                    .and_then(|mut f| {
                        use std::io::Write;
                        writeln!(
                            f,
                            "{{\"ts\":\"{ts}\",\"kind\":\"session_released\",\
                             \"session_id\":\"{target_id}\",\"gap_id\":\"{release_gap_id}\",\
                             \"source\":\"{release_source}\"}}"
                        )
                    });
                // INFRA-1116 AC6: emit intent_retracted so other sessions' overlap
                // gates treat this session as inactive immediately on release.
                atomic_claim::emit_intent_retracted(&ambient_path, &release_gap_id, &target_id);

                // RESILIENT-103: the JSON sidecar is now gone, but `chump claim`
                // writes a lease to THREE stores — the JSON sidecar, the state.db
                // `leases` row, and (when NATS is up) a NATS-KV atomic claim.
                // Release must clear all three or the lease lingers in the other two
                // and blocks re-claim of the gap (the triple-store split that forced
                // a 3-command manual recovery: sqlite DELETE + git branch -D +
                // chump-coord release).
                let release_repo_root = repo_path::repo_root();
                match atomic_claim::release_db_lease(
                    &release_repo_root,
                    &target_id,
                    &release_gap_id,
                ) {
                    Ok(n) if n > 0 => tracing::info!(
                        rows = n,
                        session_id = %target_id,
                        gap_id = %release_gap_id,
                        "cleared state.db lease row(s) on release (RESILIENT-103)"
                    ),
                    Ok(_) => {}
                    Err(e) => {
                        eprintln!("warning: failed to clear state.db lease on release: {}", e)
                    }
                }
                // NATS-KV leg: best-effort `chump-coord release <gap>`. NATS is
                // optional (offline fallback), so a failure here is non-fatal — the
                // KV claim TTL-expires on its own; this just makes recovery instant.
                if !release_gap_id.is_empty() {
                    let coord = std::env::current_exe()
                        .ok()
                        .and_then(|p| p.parent().map(|d| d.join("chump-coord")))
                        .filter(|p| p.exists())
                        .unwrap_or_else(|| std::path::PathBuf::from("chump-coord"));
                    let _ = std::process::Command::new(&coord)
                        .arg("release")
                        .arg(&release_gap_id)
                        .current_dir(&release_repo_root)
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .status();
                }
                return Ok(());
            }
            Err(e) => {
                eprintln!("release failed: {}", e);
                std::process::exit(2);
            }
        }
    }

    let heartbeat_mode = args.get(1).map(|s| s == "--heartbeat").unwrap_or(false);
    if heartbeat_mode {
        // Refresh this session's lease heartbeat. With --extend-secs=N, also
        // push expires_at forward by N seconds (subject to MAX_TTL clamp).
        let extend = args
            .iter()
            .find_map(|a| a.strip_prefix("--extend-secs="))
            .and_then(|s| s.trim().parse::<u64>().ok());
        let my_id = agent_lease::current_session_id();
        let active = agent_lease::list_active();
        let mut mine = match active.into_iter().find(|l| l.session_id == my_id) {
            Some(l) => l,
            None => {
                eprintln!(
                    "no active lease for session_id={} — claim one first (chump --claim --paths=...)",
                    my_id
                );
                std::process::exit(2);
            }
        };
        match agent_lease::heartbeat(&mut mine, extend) {
            Ok(()) => {
                println!(
                    "heartbeat session_id={} heartbeat_at={} expires_at={}",
                    mine.session_id, mine.heartbeat_at, mine.expires_at
                );
                return Ok(());
            }
            Err(e) => {
                eprintln!("heartbeat failed: {}", e);
                std::process::exit(2);
            }
        }
    }

    let notify_mode = args.get(1).map(|s| s == "--notify").unwrap_or(false);
    if notify_mode {
        // Send stdin as a DM to CHUMP_READY_DM_USER_ID (used by mabel-farmer.sh and scripts).
        let mut message = String::new();
        if std::io::stdin().read_to_string(&mut message).is_ok() && !message.trim().is_empty() {
            discord_dm::send_dm_if_configured(message.trim()).await;
        }
        return Ok(());
    }
    let chump_due_mode = args.get(1).map(|s| s == "--chump-due").unwrap_or(false);
    if chump_due_mode {
        // Heartbeat script: print first due scheduled prompt to stdout and mark it fired. No model run.
        if let Ok(due) = schedule_db::schedule_due() {
            if let Some((id, prompt, _ctx)) = due.into_iter().next() {
                let _ = schedule_db::schedule_mark_fired(id);
                print!("{}", prompt);
            }
        }
        return Ok(());
    }
    let warm_probe_mode = args.get(1).map(|s| s == "--warm-probe").unwrap_or(false);
    if warm_probe_mode {
        provider_cascade::warm_probe_all().await;
        return Ok(());
    }

    // --curate: run the memory curation pass (expire + dedupe + decay + optional LLM summarization).
    // Gated on CHUMP_MEMORY_LLM_SUMMARIZE=1 for the inference-backed summarization tier.
    // Cron-friendly: exits 0 on success with a structured log line; exits non-zero on DB error.
    let curate_mode = args.iter().any(|a| a == "--curate");
    if curate_mode {
        if !memory_db::db_available() {
            eprintln!("[curate] memory DB not available — skipping");
            return Ok(());
        }
        let llm_enabled = std::env::var("CHUMP_MEMORY_LLM_SUMMARIZE")
            .map(|v| v.trim() == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        let provider: Option<Box<dyn axonerai::provider::Provider + Send + Sync>> = if llm_enabled {
            Some(provider_cascade::build_provider())
        } else {
            None
        };
        let provider_ref: Option<&dyn axonerai::provider::Provider> = provider
            .as_ref()
            .map(|p| p.as_ref() as &dyn axonerai::provider::Provider);
        let report = memory_db::curate_all_async(provider_ref).await?;
        println!(
            "curate: expired={} deduped={} decayed={} summaries_created={} episodics_summarized={}",
            report.expired,
            report.deduped_exact,
            report.decayed,
            report.summaries_created,
            report.episodics_summarized,
        );
        return Ok(());
    }

    // MEM-005: one-shot episode-to-blackboard extraction pass.
    if args.iter().any(|a| a == "--extract-episodes") {
        let written = episode_extractor::extract_episodes_to_blackboard().await?;
        println!("extract-episodes: wrote {written} fact(s) to blackboard");
        return Ok(());
    }

    // COG-014: AB harness lesson seeding.
    //   --seed-ab-lessons <path>    load lessons JSON and seed into reflection DB
    //   --seed-ab-lessons clear     delete all ab_seed:* reflections
    if let Some(pos) = args.iter().position(|a| a == "--seed-ab-lessons") {
        let arg = args.get(pos + 1).map(|s| s.as_str()).unwrap_or("");
        if arg == "clear" {
            let n = reflection_db::clear_ab_seed_lessons()?;
            println!("seed-ab-lessons clear: removed {n} seeded reflection(s)");
        } else if arg.is_empty() {
            eprintln!("Usage: chump --seed-ab-lessons <path-to-lessons.json>");
            eprintln!("       chump --seed-ab-lessons clear");
            std::process::exit(2);
        } else {
            let path = std::path::Path::new(arg);
            let n = reflection_db::seed_ab_lessons_from_file(path)?;
            println!("seed-ab-lessons: seeded {n} directive(s) from {arg}");
        }
        return Ok(());
    }

    let autonomy_once = args.iter().any(|a| a == "--autonomy-once" || a == "--once");
    if autonomy_once {
        config_validation::validate_config();
        let why = args.iter().any(|a| a == "--why");
        if why {
            eprintln!("{}", provider_cascade::cascade_why());
        }
        let quiet = args.iter().any(|a| a == "--quiet");
        let assignee_from_env = std::env::var("CHUMP_AUTONOMY_ASSIGNEE").ok();
        let assignee = args
            .windows(2)
            .find(|w| w[0] == "--assignee")
            .map(|w| w[1].as_str())
            .or(assignee_from_env.as_deref())
            .unwrap_or("chump");
        let t0_once = std::time::Instant::now();
        let out = autonomy_loop::autonomy_once(assignee).await?;
        println!(
            "status={} task_id={:?} detail={}",
            out.status, out.task_id, out.detail
        );
        if !quiet {
            let elapsed = t0_once.elapsed().as_secs_f64();
            let slot = provider_cascade::get_last_used_slot().unwrap_or_default();
            gen::print_cost_summary(elapsed, 0, out.detail.len(), &slot);
        }
        return Ok(());
    }

    let rpc_mode = args.iter().any(|a| a == "--rpc");
    if rpc_mode {
        config_validation::validate_config();
        return rpc_mode::run_rpc_loop().await;
    }

    // ACP (Agent Client Protocol) stdio mode — JSON-RPC for Zed, JetBrains IDEs, and
    // any ACP-compatible client. See src/acp_server.rs.
    let acp_mode = args.iter().any(|a| a == "--acp");
    if acp_mode {
        config_validation::validate_config();
        mcp_bridge::init().await;
        plugin::initialize_discovered(&[]);
        return acp_server::run_acp_stdio().await;
    }

    let web_mode = args.iter().any(|a| a == "--web");
    let discord_mode = args.iter().any(|a| a == "--discord");
    let telegram_mode = args.iter().any(|a| a == "--telegram");
    let slack_mode = args.iter().any(|a| a == "--slack");
    let chump_mode = args.get(1).map(|s| s == "--chump").unwrap_or(false);

    // COMP-004b / AGT-004: Telegram bot. Long-poll loop reading TELEGRAM_BOT_TOKEN
    // from .env. Mirrors --discord but uses the new MessagingAdapter
    // trait (COMP-004a). Validates the token via getMe at startup.
    // AGT-004 wires the shared platform_router queue so each incoming
    // message is dispatched in its own tokio task rather than inline.
    if telegram_mode {
        use crate::messaging::MessagingAdapter;
        eprintln!("Chump version {}", version::chump_version());
        config_validation::validate_config();
        mcp_bridge::init().await;
        plugin::initialize_discovered(&[]);
        let (tx, rx) = platform_router::make_queue();
        // Drain the queue in a background task; the loop runs until all
        // InputQueue senders are dropped (i.e. when the adapter shuts down).
        tokio::spawn(platform_router::run_message_loop(rx));
        let adapter = telegram::TelegramAdapter::from_env().await?.with_queue(tx);
        // Direct call (not via MessagingHub) because the hub is for outbound
        // routing — inbound for a single platform is just adapter.start().
        adapter.start().await?;
        return Ok(());
    }

    // COMP-004c: Slack bot via Socket Mode. Requires SLACK_BOT_TOKEN (xoxb-...)
    // and SLACK_APP_TOKEN (xapp-...). Same platform_router queue pattern as Telegram.
    // Socket Mode avoids the need for a public webhook URL — suitable for
    // local dev, home servers, and any deployment where Slack can't reach you.
    if slack_mode {
        use crate::messaging::MessagingAdapter;
        eprintln!("Chump version {}", version::chump_version());
        config_validation::validate_config();
        mcp_bridge::init().await;
        plugin::initialize_discovered(&[]);
        let (tx, rx) = platform_router::make_queue();
        tokio::spawn(platform_router::run_message_loop(rx));
        let adapter = slack::SlackAdapter::from_env().await?.with_queue(tx);
        adapter.start().await?;
        return Ok(());
    }

    if web_mode && !discord_mode {
        config_validation::validate_config();
        mcp_bridge::init().await;
        plugin::initialize_discovered(&[]);
        let port = args
            .windows(2)
            .find(|w| w[0] == "--port")
            .and_then(|w| w[1].parse::<u16>().ok())
            .or_else(|| {
                env::var("CHUMP_WEB_PORT")
                    .ok()
                    .and_then(|p| p.trim().parse().ok())
            })
            .unwrap_or(3000);
        return web_server::start_web_server(port).await;
    }

    config_validation::validate_config();
    mcp_bridge::init().await;
    plugin::initialize_discovered(&[]);

    if discord_mode {
        // SECURITY-004 Path B: Discord gateway is opt-in at compile-time.
        // Default builds drop serenity (and the vulnerable
        // rustls-webpki 0.102.x chain). Build with `--features discord`
        // to enable.
        #[cfg(not(feature = "discord"))]
        {
            return Err(anyhow::anyhow!(
                "Discord mode requires building with `--features discord`. \
                 Default builds exclude serenity to avoid the SECURITY-004 \
                 vulnerable rustls-webpki 0.102.8 chain. Rebuild with \
                 `cargo build --release --features discord` (still vulnerable \
                 until serenity v0.13 ships) or wait for upstream fix."
            ));
        }

        #[cfg(feature = "discord")]
        {
            // PRODUCT-014: opt-in env gate. Discord mode also requires
            // CHUMP_DISCORD_ENABLED=1 in addition to a token, so deployments
            // can ship the binary with a token in .env without auto-attaching
            // to Discord on every start.
            let enabled = env::var("CHUMP_DISCORD_ENABLED")
                .map(|v| v.trim() == "1")
                .unwrap_or(false);
            if !enabled {
                return Err(anyhow::anyhow!(
                    "Discord mode requires CHUMP_DISCORD_ENABLED=1 (PRODUCT-014 opt-in). \
                 Set the env var and re-run with --discord."
                ));
            }
            // SECURITY-005 CLOSED 2026-08-09 (RESILIENT-266). The gate that
            // stood here required CHUMP_ALLOW_DISCORD_RUSTLS=1 because serenity
            // pulled tokio-tungstenite 0.21 -> rustls 0.22 -> rustls-webpki
            // 0.102.8 (RUSTSEC-2026-0104 HIGH: DoS via panic on malformed CRL
            // BIT STRING).
            //
            // It is removed rather than bypassed, because the vulnerable crate
            // is no longer in the graph at all. Cargo.toml's serenity dep had
            // explicitly opted into "rustls_backend"; it now uses
            // "native_tls_backend", which drops the entire vulnerable chain.
            //
            // Neither version route could have worked, and both were tried:
            // a [patch] to 0.103 cannot satisfy rustls 0.22's ^0.102, and
            // `cargo update --precise` has nowhere to go because 0.102.8 IS the
            // newest 0.102.x — there is no fixed release in that line.
            //
            // Verified: `cargo tree -i rustls-webpki@0.102.8 --features discord`
            // returns "did not match any packages", and Cargo.lock now carries
            // only rustls-webpki 0.101.7 and 0.103.13. That is the exact
            // removal condition the old gate named for itself.
            //
            // TRADE-OFF, recorded so it is not rediscovered: native-tls pulls
            // openssl 0.10.81 / openssl-sys 0.9.117 / security-framework 3.7.0.
            // macOS uses Security.framework; LINUX NEEDS SYSTEM OPENSSL, which
            // rustls did not. If the Linux fleet node fails to build the
            // discord feature, that is why — and the fix is a build dep, not a
            // revert to a known-vulnerable chain.
            eprintln!("Chump version {}", version::chump_version());
            if let Some(port) = env::var("CHUMP_HEALTH_PORT")
                .ok()
                .and_then(|p| p.parse::<u16>().ok())
            {
                tokio::spawn(health_server::run(port));
            }
            let token = env::var("DISCORD_TOKEN")
                .map_err(|_| anyhow::anyhow!("DISCORD_TOKEN must be set for Discord mode"))?;
            let token = normalize_discord_token(token.trim());
            if let Err(e) = discord::run(&token).await {
                return Err(anyhow::anyhow!(
                    "{}",
                    crate::chump_log::redact(&e.to_string())
                ));
            }
            return Ok(());
        } // end #[cfg(feature = "discord")] block
    }

    // `chump start <plain-language ask>` (EFFECTIVE-330 / COTG-0.0)
    //
    // The front-door router: classifies a plain-language ask into one of
    // CREATE/IMPROVE/RESCUE/COMPREHEND/INGEST with a confidence + one-line
    // confirm-back. Never auto-executes the routed engine — this command's
    // job is the routing decision + confirmation, not dispatch. A person (or
    // a wrapping script) confirms, then runs the printed engine command
    // themselves. Ambiguous/mixed intent is surfaced as a question, never
    // silently guessed (front-door doc AC2).
    if args.get(1).map(String::as_str) == Some("start") {
        let repo_root = repo_path::repo_root();
        let Some(text) = args.get(2).filter(|a| !a.starts_with("--")) else {
            eprintln!("Usage: chump start \"<what you're trying to do, in plain language>\"");
            std::process::exit(1);
        };
        let result = front_door::classify(text);
        let confirm = front_door::confirm_line(&result);
        front_door::emit_route_event(&repo_root, text, &result);

        if args.iter().any(|a| a == "--json") {
            let json = match &result {
                front_door::RouteResult::Confident { mode, confidence } => serde_json::json!({
                    "status": "confident",
                    "mode": mode.label(),
                    "confidence": confidence,
                    "engine_command": mode.engine_command(),
                    "confirm": confirm,
                }),
                front_door::RouteResult::Ambiguous { candidates } => serde_json::json!({
                    "status": "ambiguous",
                    "candidates": candidates.iter().map(|(m, s)| serde_json::json!({"mode": m.label(), "score": s})).collect::<Vec<_>>(),
                    "confirm": confirm,
                }),
            };
            println!(
                "{}",
                serde_json::to_string_pretty(&json).unwrap_or_default()
            );
        } else {
            println!("{confirm}");
            if let front_door::RouteResult::Confident { mode, .. } = &result {
                println!("  → run: {}", mode.engine_command());
            }
        }
        return Ok(());
    }

    // `chump trek "<plain job>" [--yes] [--json]` (INFRA-3656, RIBBON-01)
    //
    // The auto-execute front-door entrypoint: classifies like `chump start`
    // above, but under --yes ACTUALLY dispatches the routed engine in-process
    // (CREATE -> bootstrap, IMPROVE -> swe, INGEST -> ingest) and emits
    // trek_start + trek_outcome. Ambiguous asks; diagnosis-only routes
    // (Rescue/Comprehend) exit non-zero honestly rather than faking success.
    if args.get(1).map(String::as_str) == Some("trek") {
        let repo_root = repo_path::repo_root();
        let mission_store = chump_coord::mission::FileBackedMissionStore::default_root();

        // `chump trek --list` (INFRA-3658, RIBBON-03): read every persisted
        // Mission record back so a walked-away operator can see what past
        // trek runs produced.
        if args.get(2).map(String::as_str) == Some("--list") {
            use chump_coord::mission::MissionStore;
            match mission_store.list() {
                Ok(mut ids) => {
                    ids.sort();
                    if ids.is_empty() {
                        println!("(no trek runs recorded yet)");
                    } else {
                        for id in ids {
                            match mission_store.load(&id) {
                                Ok(pm) => println!("{}", trek::format_mission_summary(&pm)),
                                Err(e) => eprintln!("trek --list: {id}: {e:#}"),
                            }
                        }
                    }
                }
                Err(e) => {
                    eprintln!("trek --list: {e:#}");
                    std::process::exit(1);
                }
            }
            return Ok(());
        }

        // `chump trek status <mission-id>` (INFRA-3658, RIBBON-03).
        if args.get(2).map(String::as_str) == Some("status") {
            use chump_coord::mission::MissionStore;
            let Some(id) = args.get(3) else {
                eprintln!("Usage: chump trek status <mission-id>");
                std::process::exit(1);
            };
            match mission_store.load(id) {
                Ok(pm) => println!("{}", trek::format_mission_detail(&pm)),
                Err(e) => {
                    eprintln!("trek status: {e:#}");
                    std::process::exit(1);
                }
            }
            return Ok(());
        }

        let Some(job) = args.get(2).filter(|a| !a.starts_with("--")) else {
            eprintln!("Usage: chump trek \"<what you're trying to do, in plain language>\" [--yes] [--json]");
            std::process::exit(1);
        };
        let yes = args.iter().any(|a| a == "--yes");
        let json = args.iter().any(|a| a == "--json");
        let spawner = trek::RealEngineSpawner;
        let outcome = trek::run_trek(&repo_root, job, yes, &spawner, &mission_store);
        if json {
            let j = match &outcome {
                trek::TrekOutcome::Landed { mode, exit_code } => serde_json::json!({
                    "status": "landed", "mode": mode, "engine_exit_code": exit_code,
                }),
                trek::TrekOutcome::NeedsConfirmation { question } => serde_json::json!({
                    "status": "needs_confirmation", "question": question,
                }),
                trek::TrekOutcome::Ambiguous { question } => serde_json::json!({
                    "status": "ambiguous", "question": question,
                }),
                trek::TrekOutcome::DiagnosisOnly { mode, message } => serde_json::json!({
                    "status": "diagnosis_only", "mode": mode, "message": message,
                }),
            };
            println!("{}", serde_json::to_string_pretty(&j).unwrap_or_default());
        } else {
            match &outcome {
                trek::TrekOutcome::Landed { mode, exit_code } => {
                    println!("trek: {mode} landed (engine exit {exit_code})");
                }
                trek::TrekOutcome::NeedsConfirmation { question } => println!("{question}"),
                trek::TrekOutcome::Ambiguous { question } => println!("{question}"),
                trek::TrekOutcome::DiagnosisOnly { message, .. } => eprintln!("{message}"),
            }
        }
        std::process::exit(outcome.exit_code());
    }

    // `chump orchestrate [<intent>]` (INFRA-598 / INFRA-798)
    //
    // With no positional args: Opus-driven conversational loop (INFRA-598).
    // With a positional arg: single-shot intent parse + command print (INFRA-798).
    //
    // Single-shot: chump orchestrate "list P1 gaps"
    //   → parses intent, prints resolved chump command as JSON, emits ambient event.
    //   → exits 0 regardless of whether intent was recognized (Unknown prints a comment).
    if args.get(1).map(String::as_str) == Some("orchestrate") {
        let repo_root = repo_path::repo_root();

        // Resume mode: chump orchestrate --resume <session-id>  (INFRA-1366)
        if args.get(2).map(String::as_str) == Some("--resume") {
            let session_id = match args.get(3) {
                Some(id) if !id.starts_with('-') => id.clone(),
                _ => {
                    eprintln!("Usage: chump orchestrate --resume <session-id>");
                    std::process::exit(1);
                }
            };
            match orchestrate::resume(&repo_root, &session_id).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    eprintln!("chump orchestrate --resume: {e:#}");
                    std::process::exit(1);
                }
            }
        }

        // Single-shot mode when a positional text arg follows "orchestrate".
        // INFRA-1452: when pattern match returns Unknown, auto-fallback to LLM.
        if let Some(text) = args.get(2).filter(|a| !a.starts_with("--")) {
            let text = text.clone();

            // --confirm-budget may appear anywhere after the intent text.
            let confirm_budget = args[3..].iter().any(|a| a == "--confirm-budget");
            if confirm_budget {
                // Forward to budget checker via env var so helper stays pure.
                std::env::set_var("CHUMP_INTENT_LLM_CONFIRM_BUDGET", "1");
            }

            let op = intent_parser::parse_intent(&text);

            // ── LLM auto-fallback when stub pattern didn't recognize the intent ──
            if matches!(&op, intent_parser::IntentOp::Unknown { .. }) {
                if intent_parser::llm_provider_configured() {
                    // Check daily budget envelope.
                    match intent_parser::intent_llm_budget_check(&repo_root) {
                        intent_parser::BudgetStatus::Exceeded { spend, cap } => {
                            eprintln!(
                                "hint: intent_parse_llm: daily budget exceeded \
                                 (spent ${spend:.4}, cap ${cap:.4}) — \
                                 re-run with --confirm-budget to override"
                            );
                            // Fall through to print intent_parse_unknown below.
                        }
                        intent_parser::BudgetStatus::Ok { per_call } => {
                            // CI/test stub: CHUMP_INTENT_LLM_STUB_CMD bypasses the real call.
                            let stub_cmd = std::env::var("CHUMP_INTENT_LLM_STUB_CMD").ok();
                            let (resolved, provider_name) = if let Some(cmd) = stub_cmd {
                                (Some(cmd), "stub".to_string())
                            } else {
                                // Real LLM call via provider cascade.
                                let prompt = intent_parser::format_intent_prompt(&text);
                                let provider = crate::provider_cascade::build_provider();
                                let msgs = vec![axonerai::provider::Message {
                                    role: "user".into(),
                                    content: prompt,
                                }];
                                match provider.complete(msgs, None, Some(256), None).await {
                                    Ok(resp) => {
                                        let text_out = resp.text.unwrap_or_default();
                                        let cmd = intent_parser::parse_llm_response(&text_out);
                                        (cmd, "cascade".to_string())
                                    }
                                    Err(_) => (None, "cascade".to_string()),
                                }
                            };

                            if let Some(cmd) = resolved {
                                println!(
                                    "{{\"intent\":{text:?},\"command\":{cmd:?},\
                                     \"kind\":\"intent_parse_llm\",\"provider\":{provider_name:?}}}"
                                );
                                intent_parser::emit_intent_llm_event(
                                    &text,
                                    &cmd,
                                    &provider_name,
                                    &repo_root,
                                );
                                intent_parser::record_intent_llm_spend(&repo_root, per_call);
                                return Ok(());
                            }
                            // LLM returned no TOOL: line — fall through to Unknown output.
                        }
                    }
                } else {
                    // No provider configured: print hint to stderr, still emit event.
                    eprintln!("hint: set ANTHROPIC_API_KEY to enable freeform intents");
                }
            }

            let cmd = op.to_chump_command();
            println!(
                "{{\"intent\":{text:?},\"command\":{cmd:?},\"kind\":\"{}\"}}",
                op.ambient_kind()
            );
            intent_parser::emit_intent_event(&op, &repo_root);
            return Ok(());
        }

        match orchestrate::run(&repo_root).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump orchestrate: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump gen <task>` (INFRA-593 / COG-054) — user-facing single-shot coding task.
    //
    // Uses the provider cascade to apply a natural-language change to the current
    // working directory, runs `cargo check`, and commits the result. This is the
    // front-door command for the offline-LLM mission: `chump gen "add a /health
    // endpoint to my axum server"`.
    //
    // Stub mode for CI: set CHUMP_GEN_STUB_FILE=<rel-path> to skip the LLM call
    // and prepend a comment line to the named file instead.
    if args.get(1).map(String::as_str) == Some("gen") {
        let task = match args.get(2) {
            Some(t) if !t.starts_with('-') => t.clone(),
            _ => {
                eprintln!("Usage: chump gen <task> [--work-dir PATH] [--local]");
                eprintln!();
                eprintln!("  chump gen \"add a /health endpoint to my axum server\"");
                eprintln!("  chump gen --local \"add a /health endpoint\"");
                eprintln!();
                eprintln!("Uses the provider cascade to make the change, runs cargo check,");
                eprintln!("and commits the result. Use --local to force the local Ollama");
                eprintln!("provider and bypass the cloud cascade.");
                std::process::exit(2);
            }
        };
        let work_dir = if let Some(d) = args
            .iter()
            .position(|a| a == "--work-dir")
            .and_then(|i| args.get(i + 1))
        {
            std::path::PathBuf::from(d)
        } else {
            std::env::current_dir().unwrap_or_else(|_| repo_path::repo_root())
        };
        let quiet = args.iter().any(|a| a == "--quiet");
        let local = args.iter().any(|a| a == "--local");
        let opts = gen::GenOptions {
            task,
            work_dir,
            quiet,
            local,
        };
        match gen::run(opts).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump gen: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump review` (CREDIBLE-174 / CREDIBLE-181) — structurally review-only
    // agent dispatch. Investigates a diff with read/search tools but cannot
    // invoke write_file, patch_file, run_cli, git, or cargo — a finding
    // cannot be silently patched over by the same call that found it.
    if args.get(1).map(String::as_str) == Some("review") {
        let work_dir = if let Some(d) = args
            .iter()
            .position(|a| a == "--work-dir")
            .and_then(|i| args.get(i + 1))
        {
            std::path::PathBuf::from(d)
        } else {
            std::env::current_dir().unwrap_or_else(|_| repo_path::repo_root())
        };
        let staged = args.iter().any(|a| a == "--staged");
        let quiet = args.iter().any(|a| a == "--quiet");
        let opts = review_dispatch::ReviewOptions {
            work_dir,
            staged,
            quiet,
        };
        match review_dispatch::run(opts).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump review: {e:#}");
                std::process::exit(1);
            }
        }
    }

    if chump_mode {
        eprintln!("Chump version {}", version::chump_version());
        if let Some(port) = env::var("CHUMP_HEALTH_PORT")
            .ok()
            .and_then(|p| p.parse::<u16>().ok())
        {
            tokio::spawn(health_server::run(port));
        }
        let (agent, ready_session) = agent_factory::build_chump_agent_cli()?;
        let running_session = ready_session.start();
        let single_message = args
            .get(2)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        if let Some(msg) = single_message {
            if let Err(e) = limits::check_message_len(&msg) {
                eprintln!("{}", e);
                return Ok(());
            }
            let is_ship = std::env::var("CHUMP_HEARTBEAT_TYPE").as_deref() == Ok("ship");
            if is_ship {
                memory_brain_tool::ship_round_reset_log_append_flag();
            }
            if crate::precision_controller::battle_benchmark_env_on() {
                let label =
                    std::env::var("CHUMP_BATTLE_LABEL").unwrap_or_else(|_| "cli_battle".into());
                crate::precision_controller::battle_benchmark_begin(&label);
            }
            let mut reply = match agent.run(&msg).await {
                Ok(o) => o.reply,
                Err(e) => {
                    crate::precision_controller::battle_benchmark_finalize("");
                    return Err(e);
                }
            };
            let sanity_err = limits::sanity_check_reply(&reply).err();
            if let Some(ref why) = sanity_err {
                eprintln!("Reply failed sanity check: {}", why);
                // For ship heartbeat rounds, retry once on empty/whitespace reply so the round can complete with a valid reply.
                let is_empty_or_whitespace =
                    why == "reply is empty" || why == "reply is only whitespace";
                if is_ship && is_empty_or_whitespace {
                    let retry_msg = "Your previous reply was empty. If you already appended to the project log, reply exactly: Done. Otherwise append to the project log then reply: Done.";
                    if let Ok(retry_out) = agent.run(retry_msg).await {
                        if limits::sanity_check_reply(&retry_out.reply).is_ok() {
                            reply = retry_out.reply;
                        } else {
                            provider_cascade::record_slot_failure(
                                &provider_cascade::get_last_used_slot()
                                    .unwrap_or_else(|| "unknown".into()),
                            );
                            reply = "Reply failed sanity check; not applying.".to_string();
                        }
                    } else {
                        provider_cascade::record_slot_failure(
                            &provider_cascade::get_last_used_slot()
                                .unwrap_or_else(|| "unknown".into()),
                        );
                        reply = "Reply failed sanity check; not applying.".to_string();
                    }
                } else {
                    provider_cascade::record_slot_failure(
                        &provider_cascade::get_last_used_slot().unwrap_or_else(|| "unknown".into()),
                    );
                    reply = "Reply failed sanity check; not applying.".to_string();
                }
            }
            // Ship round must end with one append to a project log; if the model didn't, append directly (no second model round).
            if is_ship && !memory_brain_tool::ship_round_had_project_log_append() {
                let round =
                    std::env::var("CHUMP_HEARTBEAT_ROUND").unwrap_or_else(|_| "?".to_string());
                match memory_brain_tool::ensure_ship_round_log_append(&round) {
                    Ok(msg) => reply = msg,
                    Err(e) => reply = format!("{} (fallback append failed: {})", reply, e),
                }
            }
            println!("{}", reply);
            if crate::precision_controller::battle_benchmark_env_on() {
                crate::precision_controller::battle_benchmark_finalize(&reply);
            }
            if let Some(notify_msg) = chump_log::take_pending_notify() {
                discord_dm::send_dm_if_configured(&notify_msg).await;
            }
            running_session.close();
            return Ok(());
        }
        println!("Chump CLI (full tools + soul). Type 'quit' or 'exit' to stop.\n");
        // If stdin is piped (not a TTY), run a single turn from stdin and exit.
        if !io::stdin().is_terminal() {
            let mut input = String::new();
            if io::stdin().read_to_string(&mut input).is_ok() && !input.trim().is_empty() {
                match agent.run(input.trim()).await {
                    Ok(outcome) => println!("{}", outcome.reply),
                    Err(e) => eprintln!("Error: {}", e),
                }
                running_session.close();
                return Ok(());
            }
        }
        let stdin = io::stdin();
        let mut input = String::new();
        loop {
            print!("You: ");
            io::stdout().flush()?;
            input.clear();
            stdin.read_line(&mut input)?;
            let line = input.trim();
            if line.is_empty() {
                continue;
            }
            if line.eq_ignore_ascii_case("quit") || line.eq_ignore_ascii_case("exit") {
                running_session.close();
                println!("Bye.");
                break;
            }
            if let Err(e) = limits::check_message_len(line) {
                eprintln!("{}", e);
                continue;
            }
            match agent.run(line).await {
                Ok(outcome) => {
                    let mut r = outcome.reply;
                    if let Err(why) = limits::sanity_check_reply(&r) {
                        eprintln!("Reply failed sanity check: {}", why);
                        provider_cascade::record_slot_failure(
                            &provider_cascade::get_last_used_slot()
                                .unwrap_or_else(|| "unknown".into()),
                        );
                        r = "Reply failed sanity check; not applying.".to_string();
                    }
                    println!("{}", r);
                }
                Err(e) => eprintln!("Error: {}", e),
            }
            if let Some(notify_msg) = chump_log::take_pending_notify() {
                discord_dm::send_dm_if_configured(&notify_msg).await;
            }
        }
        return Ok(());
    }

    let provider: Box<dyn axonerai::provider::Provider> = provider_cascade::build_provider();

    let registry = ToolRegistry::new();
    // Inject Qwen3 /no_think directive when thinking mode isn't explicitly
    // requested. Qwen3 emits <think>...</think> blocks by default, which burn
    // the completion token budget and cause dogfood loops to fail silently.
    let thinking_enabled = std::env::var("CHUMP_THINKING")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let cascade_active = std::env::var("CHUMP_CASCADE_ENABLED")
        .map(|v| v == "1")
        .unwrap_or(false);
    let think_directive = if !cascade_active && !thinking_enabled {
        "/no_think\n"
    } else if !cascade_active {
        "/think\n"
    } else {
        ""
    };
    let system_prompt = Some(format!("{}You are a helpful assistant.", think_directive));

    let single_message = args
        .get(1)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    if let Some(msg) = single_message {
        // CREDIBLE-134 / CREDIBLE-110: a bare subcommand-shaped word reaching
        // this catch-all (with or without trailing args, e.g. `chump farmer
        // bogus` or `chump cron list`) is an unknown/typo'd subcommand —
        // every real subcommand (and help/--help/--version) returned
        // earlier. Error with usage + a non-zero exit instead of silently
        // routing to the model (which printed a hallucinated LLM-prose reply
        // and exited 0 — a scripting AND interactive footgun: a typo'd
        // `chump <cmd> [args...]` "succeeds" and the trailing args are
        // silently dropped since only args[1] is ever sent to the model).
        // Freeform NL is gated behind an explicit entrypoint: `--chump
        // "<msg>"` / `-p "<msg>"` (see `chump_mode` above), or — as a
        // legacy fallback — a single quoted multi-word arg containing
        // whitespace (e.g. chump "summarize today's ships").
        if !msg.contains(char::is_whitespace)
            && msg.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            && msg
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
        {
            if args.len() > 2 {
                eprintln!(
                    "chump: unknown subcommand '{msg}' (args {:?} ignored)",
                    &args[2..]
                );
            } else {
                eprintln!("chump: unknown subcommand '{msg}'");
            }
            eprintln!(
                "Run `chump help` for available commands, or quote a full question \
                 for a freeform query (e.g. chump \"summarize today's ships\")."
            );
            std::process::exit(2);
        }
        if let Err(e) = limits::check_message_len(&msg) {
            eprintln!("{}", e);
            return Ok(());
        }
        let agent = Agent::new(provider, registry, system_prompt, None);
        let mut reply = agent.run(&msg).await?;
        if let Err(why) = limits::sanity_check_reply(&reply) {
            eprintln!("Reply failed sanity check: {}", why);
            provider_cascade::record_slot_failure(
                &provider_cascade::get_last_used_slot().unwrap_or_else(|| "unknown".into()),
            );
            reply = "Reply failed sanity check; not applying.".to_string();
        }
        println!("{}", reply);
        return Ok(());
    }

    // Interactive mode: keep session so conversation has context
    let session_dir = repo_path::runtime_base().join("sessions");
    let _ = std::fs::create_dir_all(&session_dir);
    let session_manager = FileSessionManager::new("repl".to_string(), session_dir)?;
    let agent = Agent::new(provider, registry, system_prompt, Some(session_manager));

    println!("Chat with the agent (local model). Type 'quit' or 'exit' to stop.\n");
    let stdin = io::stdin();
    let mut input = String::new();
    loop {
        print!("You: ");
        io::stdout().flush()?;
        input.clear();
        stdin.read_line(&mut input)?;
        let line = input.trim();
        if line.is_empty() {
            continue;
        }
        if line.eq_ignore_ascii_case("quit") || line.eq_ignore_ascii_case("exit") {
            println!("Bye.");
            break;
        }
        if let Err(e) = limits::check_message_len(line) {
            eprintln!("{}", e);
            continue;
        }
        match agent.run(line).await {
            Ok(mut r) => {
                if let Err(why) = limits::sanity_check_reply(&r) {
                    eprintln!("Reply failed sanity check: {}", why);
                    provider_cascade::record_slot_failure(
                        &provider_cascade::get_last_used_slot().unwrap_or_else(|| "unknown".into()),
                    );
                    r = "Reply failed sanity check; not applying.".to_string();
                }
                println!("{}", r);
            }
            Err(e) => eprintln!("Error: {}", e),
        }
    }
    Ok(())
}
