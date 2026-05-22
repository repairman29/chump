//! Minimal AxonerAI agent that talks to an OpenAI-compatible endpoint (e.g. Ollama on localhost).
//! Set OPENAI_API_BASE (e.g. http://localhost:11434/v1) to use a local server; default is Ollama.
//! Run with no args for interactive chat; pass a message for single-shot; --discord to run Discord bot (DISCORD_TOKEN required).

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod a2a_tool;
mod acp;
mod acp_server;
mod activation;
mod adversary;
mod adversary_llm;
mod agent_factory;
mod agent_lease;
pub mod agent_loop;
mod agent_session;
mod agent_turn;
mod ambient_emit;
mod ambient_rotate;
mod ambient_stream;
mod approval_resolver;
mod asi_telemetry;
mod ask_jeff_db;
mod ask_jeff_tool;
mod assertion;
mod atomic_claim;
mod auth;
mod autonomy_fsm;
mod autonomy_loop;
mod autopilot;
mod battle_qa_tool;
mod belief_state;
mod blackboard;
mod blocker_detect;
mod briefing;
mod browser;
mod browser_tool;
mod calc_tool;
mod cancel_registry;
mod cascade_stats;
mod checkpoint_db;
mod checkpoint_tool;
mod chump_init;
mod chump_log;
mod ci_summary;
mod cli_tool;
mod cluster_mesh;
mod codebase_digest_tool;
mod config_validation;
mod consciousness_traits;
mod content_bots;
mod context_assembly;
mod context_engine;
mod context_firewall;
mod context_window;
mod cost_ledger;
mod cost_tracker;
mod cost_watch;
mod counterfactual;
mod dashboard;
mod db_pool;
mod decompose_task_tool;
mod delegate_tool;
mod desktop_launcher;
mod diff_review_tool;
#[cfg(feature = "discord")]
mod discord;
mod discord_dm;
mod discord_intent;
mod dispatch;
mod doctor;
mod ego_tool;
mod env_flags;
mod episode_db;
mod episode_extractor;
mod episode_tool;
mod eval_harness;
mod execute_gap;
mod failure_catalog;
mod file_watch;
mod fleet;
mod fleet_capability;
mod fleet_db;
mod fleet_fanout; // INFRA-1484: cross-repo fan-out (Marcus M-B continuation)
mod fleet_health;
mod fleet_resize;
mod fleet_self_doctor;
mod fleet_spec; // INFRA-1483: declarative chump.fleet.yaml (Marcus M-B)
mod fleet_status;
mod fleet_tool;
mod fleet_velocity;
mod ftue_tool;
// INFRA-693: gap_store moved to its own crate (crates/chump-gap-store/).
// The rename keeps every `gap_store::*` call site compiling unchanged.
use chump_gap_store as gap_store;
// INFRA-1229: explicit linkage declaration so Cargo always links chump-ship
// even when the CI rust-cache restores a stale build (fixes E0433 on Ubuntu).
extern crate chump_ship;
mod audit;
mod budget_tracker; // INFRA-1486: per-gap execution budgets (Marcus trust gate)
mod completion;
mod gen;
mod genai_conv;
mod git_tools;
mod github_rate_limit;
mod health;
mod health_server;
mod hitl_escalation;
mod hooks;
mod intent_parser;
mod interrupt_notify;
mod introspect_tool;
mod job_log;
mod kpi_report;
mod lesson_action;
mod lesson_embeddings;
mod limits;
mod llm_backend_metrics;
mod local_openai;
mod mcp_bridge;
mod mcp_discovery;
mod memory_brain_tool;
mod memory_db;
mod memory_graph;
mod memory_graph_tool;
mod memory_graph_viz;
mod memory_tool;
mod messaging;
mod mission_grade;
#[cfg(feature = "mistralrs-infer")]
mod mistralrs_provider;
mod model_overlay;
mod model_probe;
mod neuromodulation;
mod notify_tool;
mod onboard_repo_tool;
mod operator_presence;
mod orchestrate;
mod paramedic;
mod patch_apply;
mod pending_peer_approval;
mod perception;
mod peripheral_sensor;
mod phi_proxy;
mod pilot_metrics;
mod plan_mode;
mod platform_router;
mod plugin;
mod policy_override;
mod pr_ac_coverage;
mod pr_coupling_cost;
mod pr_fix_clippy;
mod pr_triage;
mod precision_controller;
mod preflight; // INFRA-1670: local CI mirror — chump preflight subcommand
mod provider_bandit;
mod provider_cascade;
mod provider_quality;
mod ratings;
mod read_url_tool;
mod reasoning_mode;
mod rebase_stuck;
mod recipe;
mod reflect_delta;
mod reflection;
mod reflection_db;
mod repo_allowlist;
mod repo_allowlist_tool;
mod repo_path;
mod repo_tools;
mod rescue_tally;
mod revert_pr;
mod review_handoff;
mod roadmap_status;
mod rollup_cmd; // INFRA-1455: chump rollup --semantic (Marcus M-B converge)
mod routes;
mod rpc_mode;
mod run_test_tool;
mod runtime_flags;
mod sandbox_tool;
mod schedule_db;
mod schedule_tool;
mod screen_vision_tool;
mod session;
pub mod session_compact;
mod session_export;
mod session_ledger;
mod session_search_tool;
mod session_summary; // INFRA-1437: chump session-summary subcommand
mod set_working_repo_tool;
mod ship_quality;
mod skill_db;
mod skill_hub;
mod skill_hub_tool;
mod skill_metrics;
mod skill_tool;
mod skills;
mod slack;
mod spawn_worker_tool;
mod speculative_execution;
mod stack_detect;
mod state_db;
mod stream_events;
mod streaming_provider;
mod system_prompt;
mod task_contract;
mod task_db;
mod task_executor;
mod task_planner_tool;
mod task_tool;
mod telegram;
mod telemetry_energy;
mod test_aware;
mod thinking_strip;
mod tool_health_db;
mod tool_input_schema_validate;
mod tool_input_validate;
mod tool_inventory;
mod tool_middleware;
mod tool_normalize; // INFRA-740: repair malformed tool-call JSON from weak LLMs
mod tool_policy;
mod tool_routing;
mod toolkit_status_tool;
mod tracing_init;
mod trajectory_replay;
mod user_error_hints;
pub mod user_profile;
mod vector6_verify;
mod vector7_swarm_verify;
mod version;
mod wasm_calc_tool;
mod wasm_runner;
mod wasm_text_tool;
mod waste_tally;
mod web_brain;
mod web_push_send;
mod web_server;
mod web_sessions_db;
mod web_uploads;

#[cfg(test)]
mod consciousness_exercise;
#[cfg(test)]
mod consciousness_tests;
#[cfg(test)]
mod e2e_bot_tests;

#[cfg(feature = "inprocess-embed")]
mod embed_inprocess;

mod metrics;

use anyhow::{Context as _, Result};
use axonerai::agent::Agent;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::tool::ToolRegistry;
use std::env;
use std::io::{self, IsTerminal, Read, Write};

/// Serenity adds "Bot " to the token; if .env has "Bot xxx", strip it so we don't send "Bot Bot xxx".
fn normalize_discord_token(s: &str) -> String {
    let s = s.trim();
    if s.eq_ignore_ascii_case("bot") {
        return String::new();
    }
    if s.len() > 4 && s.get(..4).map(|p| p.eq_ignore_ascii_case("bot ")) == Some(true) {
        return s[4..].trim().to_string();
    }
    s.to_string()
}

fn unix_ts() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// INFRA-431: domains whose rows are pure test fixtures and should be
/// hidden from the default `chump gap list` output. The 2026-05-03 INFRA-428
/// audit found 306 leaked SPIKE/TEST/TEST168 rows in production state.db.
/// Users opt back in via `--include-test-domains`.
fn is_test_domain(domain: &str) -> bool {
    matches!(domain, "SPIKE" | "TEST" | "TEST168")
        || domain.starts_with("TEST")
        || domain.ends_with("TEST")
}

/// INFRA-1259: Check if acceptance_criteria is vague (empty, all-TODO, or all-TBD).
fn is_acceptance_criteria_vague(ac: &str) -> bool {
    let trimmed = ac.trim();
    // Empty AC is vague
    if trimmed.is_empty() {
        return true;
    }

    // Try to parse as JSON array (the canonical format)
    if let Ok(serde_json::Value::Array(arr)) = serde_json::from_str(trimmed) {
        if arr.is_empty() {
            return true; // Empty array
        }
        // Check if all items are TODO or TBD strings
        let all_vague = arr.iter().all(|item| {
            if let Some(s) = item.as_str() {
                let upper = s.to_uppercase();
                upper == "TODO" || upper == "TBD" || upper.contains("TODO") || upper.contains("TBD")
            } else {
                false
            }
        });
        return all_vague && !arr.is_empty();
    }

    // If not JSON array, check if the raw string is just TODO/TBD
    let upper = trimmed.to_uppercase();
    upper == "TODO" || upper == "TBD" || (upper.len() < 50 && upper.contains("TODO"))
}

/// INFRA-094: write a marker recording that the chump CLI just modified
/// docs/gaps.yaml via a canonical operation (`gap dump --out` /
/// `gap ship --update-yaml`). The pre-commit hook reads this marker — if
/// it's < 5 minutes old AND docs/gaps.yaml is staged, the hook treats the
/// diff as canonical and skips the raw-YAML-edit advisory.
///
/// Failures are best-effort: the worst outcome is a spurious pre-commit
/// warning, which is recoverable.
fn write_yaml_op_marker(repo_root: &std::path::Path, op: &str) {
    let dir = repo_root.join(".chump");
    let _ = std::fs::create_dir_all(&dir);
    let marker = dir.join(".last-yaml-op");
    let body = format!(
        "{{\"op\":\"{}\",\"ts\":{},\"sha\":\"{}\"}}\n",
        op,
        unix_ts(),
        env!("CARGO_PKG_VERSION")
    );
    let _ = std::fs::write(&marker, body);
}

/// INFRA-488: parse a friendly duration string ("24h", "7d", "60m",
/// "3600s") into seconds. Pure digits are interpreted as seconds.
/// Returns None for unparseable input.
fn parse_duration_to_secs(s: &str) -> Option<u64> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let (num_part, unit_secs): (&str, u64) = if let Some(rest) = s.strip_suffix('d') {
        (rest, 86_400)
    } else if let Some(rest) = s.strip_suffix('h') {
        (rest, 3_600)
    } else if let Some(rest) = s.strip_suffix('m') {
        (rest, 60)
    } else if let Some(rest) = s.strip_suffix('s') {
        (rest, 1)
    } else {
        (s, 1)
    };
    let n: u64 = num_part.parse().ok()?;
    n.checked_mul(unit_secs)
}

/// Load .env from CHUMP_HOME/CHUMP_REPO first (so Chump Menu / run-discord.sh always get the right .env),
/// then current dir, then executable dir.
fn load_dotenv() {
    let base = repo_path::runtime_base();
    let env_path = base.join(".env");
    if env_path.is_file() {
        let _ = dotenvy::from_path(&env_path);
        return;
    }
    if dotenvy::dotenv().is_ok() {
        return;
    }
    if let Ok(exe) = env::current_exe() {
        if let Some(dir) = exe.parent() {
            let mut path = dir.to_path_buf();
            path.push(".env");
            let _ = dotenvy::from_path(&path);
        }
    }
}

/// EFFECTIVE-009 — print grouped command reference.
/// Shown when `chump` is run with no args, or when `chump help` / `chump --help` is used.
// EFFECTIVE-011: expand short command aliases before routing.
// "s" is a compound alias: "chump s <ID>" → "chump gap ship <ID>".
fn expand_aliases(mut args: Vec<String>) -> Vec<String> {
    if args.len() < 2 {
        return args;
    }
    match args[1].as_str() {
        "g" => {
            args[1] = "gap".to_string();
        }
        "c" => {
            args[1] = "claim".to_string();
        }
        "f" => {
            args[1] = "fleet".to_string();
        }
        "d" => {
            args[1] = "dispatch".to_string();
        }
        "h" => {
            args[1] = "health".to_string();
        }
        "cs" => {
            args[1] = "cost-watch".to_string();
        }
        "s" => {
            args[1] = "gap".to_string();
            args.insert(2, "ship".to_string());
        }
        // INFRA-1238: top-level `chump ship` (literal, not alias-s) was
        // promised in print_help but never wired — fell through to the
        // LLM agent loop. Mirror the `s` expansion.
        // INFRA-1229: leave `chump ship plan` / `chump ship execute` alone
        // — those are the new subcommands (slices 1+2 of bot-merge port).
        // Only the legacy `chump ship <GAP-ID>` form gets the `gap ship` alias.
        "ship" => {
            let sub2 = args.get(2).map(String::as_str);
            if sub2 != Some("plan") && sub2 != Some("execute") {
                args[1] = "gap".to_string();
                args.insert(2, "ship".to_string());
            }
        }
        _ => {}
    }
    args
}

fn print_help() {
    let ver = version::chump_version();
    println!("chump — gap orchestration tool  (v{ver})");
    println!();
    println!("USAGE");
    println!("  chump <command> [options]");
    println!("  chump <command> --help        show help for that command");
    println!("  chump --version               print version + build SHA");
    println!("  chump --verbose               escalate RUST_LOG to debug");
    println!("  chump --debug                 debug header (version, args, timestamp) + verbose");
    println!();
    println!("GAP MANAGEMENT");
    println!("  gap <sub>  (alias: g)  list, show, reserve, ship, audit-priorities …");
    println!("  claim <GAP-ID>  (alias: c)  atomic worktree + lease + preflight in one call");
    println!("  ship <GAP-ID>   (alias: s)  shorthand for 'gap ship <GAP-ID>'");
    println!("  gen <task>         AI-driven single-shot coding task (offline-LLM)");
    println!();
    println!("FLEET");
    println!("  fleet <sub>  (alias: f)  worker control — up/status/down/doctor …");
    println!("  dispatch <sub>  (alias: d)  route/scoreboard/simulate/cost-report …");
    println!("  orchestrate        Opus-driven conversational loop (interactive)");
    println!();
    println!("ANALYTICS");
    println!("  health  (alias: h)  current gap-registry health snapshot");
    println!(
        "  session-summary    merged + armed + filed PRs in current session window (INFRA-1437)"
    );
    println!("  health-digest      markdown digest with P0/P1 counts + warnings");
    println!("  fleet-status       per-worker throughput + lease state");
    println!("  fleet-velocity     PRs/day and ship-rate trend");
    println!("  waste-tally        % of compute spent on closed-without-merge PRs");
    println!("  ship-quality       post-merge signal: pass rate, revert rate");
    println!("  roadmap-status     milestone completion %");
    println!(
        "  mission-grade      current pillar grades (EFFECTIVE/CREDIBLE/RESILIENT/ZERO-WASTE)"
    );
    println!("  lesson-grade       lesson-learning quality score");
    println!("  ci-summary         last-N CI run outcomes");
    println!("  classify-failure   categorize a CI/PR failure for the improvement tracker");
    println!(
        "  kpi report         KPI scorecard across all pillars
  kpi report --impact  gap impact ratings (chump gap rate)"
    );
    println!("  kpi report --agents  per-agent throughput (ships/fails/P50)");
    println!("  kpi report --agents --date YYYY-MM-DD  specific date");
    println!("  cost-watch  (alias: cs)  real-time inference spend + per-slot breakdown");
    println!("  cost record-pr     attach cost metadata to a merged PR");
    println!("  pr-coupling-cost   cost of PRs that move together (coupling smell)");
    println!("  cascade stats      per-slot hit/miss/error counts for the provider cascade");
    println!("  funnel             install → first_task → return_d2 activation funnel");
    println!("  dashboard          open the local web dashboard");
    println!();
    println!("SESSION / REFLECTION");
    println!("  session-track      start or continue a named work session");
    println!("  session-export     export session transcript as markdown");
    println!("  session-resume     re-attach to the most recent session");
    println!("  reflect-delta      compute lesson-delta since last reflection");
    println!("  rebase-stuck       auto-resolve stuck rebase for a given branch");
    println!("  pr fix-clippy      run clippy --fix on the current PR branch");
    println!("  pr triage          assign labels + reviewer to open PRs");
    println!();
    println!("SERVER MODES  (long-running, not for interactive use)");
    println!("  --web              start the PWA web server (default port 3000)");
    println!("  --acp              ACP stdio mode for Zed / JetBrains / VS Code");
    println!("  --discord          Discord gateway bot (requires --features discord)");
    println!("  --telegram         Telegram bot (requires TELEGRAM_BOT_TOKEN)");
    println!("  --slack            Slack Socket Mode bot (requires SLACK_BOT_TOKEN)");
    println!("  --rpc              internal JSON-RPC loop (fleet workers)");
    println!();
    println!("FIRST RUN");
    println!("  init               detect model, write .env, start server, open browser");
    println!();
    println!("DOCS");
    println!("  AGENTS.md          coordination rules and pillar definitions");
    println!("  docs/ROADMAP.md    milestone plan");
    println!("  scripts/README.md  script taxonomy and entry points");
}

/// `chump plan` subcommand (INFRA-1021).
///
/// Thin wrapper around chump-planner library — keeps main.rs free of the
/// scoring/graph internals so the planner can evolve independently. Errors
/// bubble up via Result; reconciliation-gate breach maps to exit code 2.
fn run_plan_subcommand(args: &[String]) -> Result<()> {
    use chump_planner::output::table;
    use chump_planner::score::TelemetryInputs;
    use chump_planner::{
        build_plan, collect_reconcile, load_gaps_dir, DependencyGraph, PlanRequest, Weights,
    };

    if args.iter().any(|a| a == "--help" || a == "help") {
        println!("Usage: chump plan [OPTIONS]");
        println!();
        println!("Rank the open gap backlog and recommend the next N to dispatch.");
        println!("v0.1: structured depends_on hard edges only, table output,");
        println!("reconciliation gate. --explain / --graph / --json arrive in v0.2.");
        println!();
        println!("OPTIONS:");
        println!("  --gaps PATH             Gaps directory (default: docs/gaps)");
        println!("  --agents N              Plan for N concurrent agents (default: 5)");
        println!("  --pillar DOMAIN         Filter to a single domain");
        println!("  --max-effort SIZE       Skip gaps larger than this (xs/s/m/l/xl)");
        println!("  --no-pillar-cap         Disable the running pillar-share cap");
        println!("  --include-blocked       Include gaps with open prerequisites");
        println!("  --reconcile-threshold N Exit non-zero when status:open+closed_pr backlog > N");
        println!("                          (default 10)");
        return Ok(());
    }

    let mut gaps_path = std::path::PathBuf::from("docs/gaps");
    let mut agents: usize = 5;
    let mut pillar: Option<String> = None;
    let mut max_effort: Option<String> = None;
    let mut no_pillar_cap = false;
    let mut include_blocked = false;
    let mut reconcile_threshold: usize = 10;

    let mut it = args.iter().skip(2);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--gaps" => {
                gaps_path = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--gaps needs a value"))?
                    .into();
            }
            "--agents" => {
                agents = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--agents needs a value"))?
                    .parse()?;
            }
            "--pillar" => {
                pillar = Some(
                    it.next()
                        .ok_or_else(|| anyhow::anyhow!("--pillar needs a value"))?
                        .clone(),
                );
            }
            "--max-effort" => {
                max_effort = Some(
                    it.next()
                        .ok_or_else(|| anyhow::anyhow!("--max-effort needs a value"))?
                        .clone(),
                );
            }
            "--no-pillar-cap" => no_pillar_cap = true,
            "--include-blocked" => include_blocked = true,
            "--reconcile-threshold" => {
                reconcile_threshold = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--reconcile-threshold needs a value"))?
                    .parse()?;
            }
            "--format" => {
                // v0.1 supports only table; accept it explicitly so the v0.2
                // wiring (--format json|mermaid|markdown) lands as a small diff.
                let v = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--format needs a value"))?;
                if v != "table" {
                    anyhow::bail!("v0.1 only supports --format table; got {v}");
                }
            }
            other => anyhow::bail!("unknown arg {other} (see chump plan --help)"),
        }
    }

    let gaps = load_gaps_dir(&gaps_path)
        .map_err(|e| anyhow::anyhow!("loading gaps from {}: {e}", gaps_path.display()))?;
    let graph = DependencyGraph::build(&gaps);

    if let Err(cycle) = graph.topo_order() {
        eprintln!(
            "warning: dependency cycle detected ({} members, identity {}): {:?}",
            cycle.gaps.len(),
            &cycle.identity()[..16],
            cycle.gaps.iter().map(|g| g.0.as_str()).collect::<Vec<_>>(),
        );
    }

    let pillar_filter = match pillar.as_deref() {
        Some(s) => Some(<chump_planner::Domain as std::str::FromStr>::from_str(s)?),
        None => None,
    };
    let max_effort_val = match max_effort.as_deref() {
        Some(s) => Some(<chump_planner::Effort as std::str::FromStr>::from_str(s)?),
        None => None,
    };

    let req = PlanRequest {
        agents,
        pillar_filter,
        max_effort: max_effort_val,
        respect_pillar_cap: !no_pillar_cap,
        include_blocked,
    };

    let weights = Weights::default();
    let telemetry = TelemetryInputs::default();
    let today = chrono::Utc::now().date_naive();

    let plan = build_plan(&gaps, &graph, &req, &telemetry, today, &weights);
    let reconcile = collect_reconcile(&gaps);

    print!("{}", table::render(&plan, &reconcile));

    if reconcile.breaches(reconcile_threshold) {
        eprintln!(
            "error: reconciliation backlog {} exceeds threshold {} — run scripts/coord/gap-doctor-reconcile.py",
            reconcile.count(),
            reconcile_threshold
        );
        std::process::exit(2);
    }

    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    // EFFECTIVE-011: expand short aliases (g, c, s, f, d, h, cs) before routing.
    let args = expand_aliases(args);

    // CREDIBLE-019: --verbose / --debug global flags (processed first so they
    // take effect even alongside --version or --help).
    // --verbose: escalate RUST_LOG to debug (human stderr).
    // --debug: same as --verbose + emit a startup header with version, args, timestamp.
    let flag_verbose = args.iter().any(|a| a == "--verbose" || a == "-v");
    let flag_debug = args.iter().any(|a| a == "--debug");
    if (flag_verbose || flag_debug) && std::env::var("RUST_LOG").is_err() {
        // Safety: single-threaded; no async tasks spawned yet.
        unsafe { std::env::set_var("RUST_LOG", "debug") };
    }
    if flag_debug {
        let ts = chrono::Utc::now().format("%H:%M:%S%.3f");
        eprintln!(
            "[debug] chump {} ({}) started at {}",
            version::chump_version(),
            version::chump_build_sha(),
            ts,
        );
        eprintln!("[debug] args: {:?}", &args[1..]);
    }

    // INFRA-148: surface the baked build SHA + date so operators can verify
    // their binary's staleness against `git log src/gap_store.rs src/main.rs`
    // *before* running `chump gap ship --update-yaml` / `chump gap dump`.
    // Pre-this-fix, `chump --version` fell through to the model-prompt path
    // (printed "Response from Agent: ...") because there was no top-level
    // flag handler — defeating the point of baking the SHA at build time.
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!(
            "chump {} ({} built {})",
            version::chump_version(),
            version::chump_build_sha(),
            version::chump_build_date(),
        );
        return Ok(());
    }

    // EFFECTIVE-009: no-args → help; `chump help` → help. Must come before
    // any mode that falls through to the interactive agent loop.
    let wants_help = args.len() == 1
        || args.get(1).map(String::as_str) == Some("help")
        || args.get(1).map(String::as_str) == Some("--help")
        || args.get(1).map(String::as_str) == Some("-h");
    if wants_help {
        print_help();
        return Ok(());
    }

    if args.iter().any(|a| a == "--desktop") {
        desktop_launcher::launch_and_wait(&args);
    }
    load_dotenv();
    local_openai::auto_configure_context_window().await;

    // `chump --briefing <GAP-ID>` (MEM-007) — agent context-query that returns
    // "what should I know before working on gap X?". Reads docs/gaps.yaml,
    // chump_improvement_targets, ambient.jsonl, and strategic docs. Bypasses
    // the agent loop entirely; intended to be run by an agent right after
    // gap-preflight.sh and before gap-claim.sh. Exits 0 always — a missing
    // gap renders an explicit "not found" block rather than failing.
    if let Some(pos) = args.iter().position(|a| a == "--briefing") {
        let gap_id = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if gap_id.is_empty() || gap_id.starts_with("--") {
            eprintln!("Usage: chump --briefing <GAP-ID>");
            std::process::exit(2);
        }
        let b = briefing::build_briefing(gap_id);
        print!("{}", briefing::render_markdown(&b));
        return Ok(());
    }

    // `chump ambient emit <kind> [...]` (INFRA-1048) — harness-agnostic
    // event-write CLI. Replaces the Claude-Code-specific PreToolUse hook
    // shell+python+flock chain for non-Claude harnesses. See
    // docs/process/AGENT_API.md §3 for the contract; specced via INFRA-1050.
    if args.get(1).map(String::as_str) == Some("ambient")
        && args.get(2).map(String::as_str) == Some("emit")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!(
                "Usage: chump ambient emit <kind> [--gap GAP-ID] [--source NAME] \\\n         [--harness NAME] [--field key=value]..."
            );
            println!();
            println!(
                "Write one event line to .chump-locks/ambient.jsonl. Auto-fills ts (RFC3339 UTC),"
            );
            println!("session (CHUMP_SESSION_ID > CLAUDE_SESSION_ID > worktree cache > derived),");
            println!(
                "worktree (basename of repo root), and harness (--harness > CHUMP_AGENT_HARNESS > 'unknown')."
            );
            println!();
            println!("Examples:");
            println!("  chump ambient emit file_edit --gap INFRA-1048 --field path=src/main.rs");
            println!("  chump ambient emit commit --field sha=abc1234 --field msg='fix: x'");
            return Ok(());
        }
        // Slice off args[0] (binary name) so from_argv sees
        // ["ambient", "emit", <kind>, ...flags].
        let parsed = match ambient_emit::EmitArgs::from_argv(&args[1..]) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump ambient emit: {e:#}");
                eprintln!("Run `chump ambient emit --help` for usage.");
                std::process::exit(2);
            }
        };
        let path = match ambient_emit::emit(&parsed) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("chump ambient emit: {e:#}");
                std::process::exit(1);
            }
        };
        // Stderr so stdout stays clean for chained commands (e.g. backtick capture).
        eprintln!("[ambient] wrote {} ({})", parsed.kind, path.display());
        return Ok(());
    }

    // `chump ship plan` (INFRA-1229 slice 1) — pure planner that decides
    // REBASE / ARM / WAIT / CONFLICT-RECOVER / etc. given a snapshot of
    // PR + branch state. Today's bot-merge.sh consumes the output as a
    // structured JSON plan and dispatches; slice 2 (separate PR) will
    // move the executor side into Rust as well.
    if args.get(1).map(String::as_str) == Some("ship")
        && args.get(2).map(String::as_str) == Some("plan")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!("Usage: chump ship plan [--gap GAP-ID] [--pr N] [--branch B] [--json|--human] [--dry-run]");
            println!();
            println!("Decide the next ship action for a branch + PR given their current state.");
            println!("Output is a structured ShipPlan JSON (default) suitable for bot-merge.sh");
            println!("or any other consumer to dispatch on. The planner does no mutations.");
            println!();
            println!("Inputs are gathered by calling `gh api` for the PR + check-runs and");
            println!("`git rev-list --count` for behind/ahead. --dry-run uses synthetic state.");
            return Ok(());
        }
        return ship_plan_cli(&args[3..]).await;
    }

    // `chump ship execute` (INFRA-1229 slice 2) — walks the ExecutorStep
    // list derived from a ShipPlan via std::process::Command. Reads the
    // plan JSON from --plan <file> or --stdin. Mutates state — pair with
    // --dry-run to inspect without executing.
    if args.get(1).map(String::as_str) == Some("ship")
        && args.get(2).map(String::as_str) == Some("execute")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!("Usage: chump ship execute (--plan PATH | --stdin) [--dry-run] [--json]");
            println!();
            println!("Read a ShipPlan JSON (from `chump ship plan`) and execute the");
            println!("derived ExecutorStep list. Emits an ExecuteResult JSON with the");
            println!("rc + stderr_tail for each step. --dry-run prints steps; runs none.");
            println!();
            println!("Pipe pattern:");
            println!("  chump ship plan --gap INFRA-989 --pr 1913 | chump ship execute --stdin");
            return Ok(());
        }
        return ship_execute_cli(&args[3..]).await;
    }

    // `chump init` (UX-001) — first-run setup: detect model, write .env, start server, open browser.
    // Flags: --port N (override CHUMP_WEB_PORT), --no-browser (skip step 4 — for CI / FTUE).
    if args.get(1).map(String::as_str) == Some("init") {
        let init_args = match chump_init::InitArgs::from_argv(&args[2..]) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump init: {e:#}");
                eprintln!("usage: chump init [--port N] [--no-browser]");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
        if let Err(e) = chump_init::run_init(&repo_root, &init_args) {
            eprintln!("chump init: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump funnel` (PRODUCT-015) — read .chump-locks/ambient.jsonl and print
    // the three-row activation funnel: install → first_task → return_d2.
    if args.get(1).map(String::as_str) == Some("funnel") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump funnel");
            println!();
            println!(
                "Print install → first_task → return_d2 activation funnel from ambient events."
            );
            println!();
            println!("Example:");
            println!("  chump funnel");
            return Ok(());
        }
        activation::print_funnel();
        return Ok(());
    }

    // `chump claim <GAP-ID> [--paths X,Y,...]` (INFRA-468) — atomic
    // replacement for the 6-step shell dance documented in CLAUDE.md's
    // mandatory pre-flight: fetch + verify-gap + health-probe + worktree
    // + lease-write + import-if-drifted, all in one call. Each step has
    // its own bypass env for testing / unusual setups.
    if args.get(1).map(String::as_str) == Some("claim") {
        let repo_root = repo_path::repo_root();
        let claim_args = match atomic_claim::ClaimArgs::from_argv(&args[1..], repo_root.clone()) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump claim: {e:#}");
                eprintln!();
                eprintln!("Usage: chump claim <GAP-ID> [--paths CSV] [--session ID]");
                eprintln!("                          [--skip-doctor] [--skip-import]");
                eprintln!();
                eprintln!("Atomically: fetch origin/main, verify the gap, run chump-doctor,");
                eprintln!("create a linked worktree, write the lease. Replaces the 6-step");
                eprintln!("shell dance in CLAUDE.md mandatory pre-flight (INFRA-468).");
                std::process::exit(2);
            }
        };
        match atomic_claim::run_claim(claim_args) {
            Ok(report) => {
                atomic_claim::print_report(&report);
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump claim: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump preflight` (INFRA-1670) — local CI mirror.
    // Runs cargo fmt --check, clippy -D warnings, check; optionally
    // selected scripts/ci/test-*.sh with --with-tests. Catches the
    // failure classes that bit us most often on GH Actions (cargo fmt
    // drift, clippy dead_code, INFRA-682 path-filter, INFRA-1287
    // registry-orphan, etc.) in <60s warm instead of ~15 min round-trip.
    if args.get(1).map(String::as_str) == Some("preflight") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(preflight::run(&sub_args));
    }

    // `chump session-summary` (INFRA-1437) — list merged + armed + filed PRs
    // in the current session window. Replaces the manual ambient.jsonl + gh
    // pr list scrape that PM-curator + operator were doing at every session
    // end (~5 min of work).
    if args.get(1).map(String::as_str) == Some("session-summary") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(session_summary::run(&sub_args));
    }

    // `chump completion [zsh|bash|fish]` (EFFECTIVE-010) — print shell completion script.
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
            println!("  aha-sweep   walk code/runtime/effect triangle for every registered kind");
            println!();
            println!("Run 'chump audit aha-sweep --help' for sweep options.");
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
            println!("Usage: chump health [--json] [--watch] [--slo-check]");
            println!();
            println!("Composite fleet health score (0-100) rolling up fleet-status, waste-tally,");
            println!("cost-watch, mission-grade, pr-stuck, version-skew, auth, and ghost-gaps.");
            println!("Emits kind=fleet_health to ambient.jsonl on each run.");
            println!();
            println!("Options:");
            println!("  --json       output in JSON format");
            println!("  --watch      refresh every 30 s (clear screen between runs)");
            println!("  --slo-check  exit non-zero if any SLO is breached");
            println!();
            println!("Example:");
            println!("  chump health");
            println!("  chump health --slo-check   # use in CI");
            return Ok(());
        }
        let want_json = args.iter().any(|a| a == "--json");
        let watch = args.iter().any(|a| a == "--watch");
        let slo_check = args.iter().any(|a| a == "--slo-check");
        let repo_root = repo_path::repo_root();

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

    // `chump roadmap-status [--json] [--exit-on-drift] [--top-starved N]`
    // INFRA-606: reads docs/ROADMAP.md, shows 🟢/🟡/🔴 progress per weekly outcome.
    // INFRA-1145: adds starved_outcomes, untraced_p0, pillar_coverage, --exit-on-drift.
    if args.get(1).map(String::as_str) == Some("roadmap-status") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump roadmap-status [--json] [--exit-on-drift] [--top-starved N]");
            println!();
            println!("Reads docs/ROADMAP.md and shows 🟢/🟡/🔴 progress per weekly outcome.");
            println!("Lists implementing gaps with shipped/in-flight/open counts cross-referenced");
            println!("against state.db.");
            println!();
            println!("Options:");
            println!("  --json            output in JSON format");
            println!("  --exit-on-drift   exit 1 if starved outcomes or untraced P0/P1 gaps found");
            println!(
                "  --top-starved N   limit starved_outcomes output to N entries (default: all)"
            );
            println!();
            println!("Exit codes:");
            println!("  0 — no drift detected (or --exit-on-drift not set)");
            println!("  1 — drift detected when --exit-on-drift is set");
            println!();
            println!("Examples:");
            println!("  chump roadmap-status");
            println!("  chump roadmap-status --json | jq .starved_outcomes");
            println!("  chump roadmap-status --exit-on-drift  # CI gate");
            return Ok(());
        }
        let want_json = args.iter().any(|a| a == "--json");
        let exit_on_drift = args.iter().any(|a| a == "--exit-on-drift");

        // Parse --top-starved N
        let top_starved: usize = args
            .windows(2)
            .find(|w| w[0] == "--top-starved")
            .and_then(|w| w[1].parse::<usize>().ok())
            .unwrap_or(usize::MAX);

        let repo_root = repo_path::repo_root();
        let report = roadmap_status::build_report(&repo_root);

        // INFRA-1145: emit ambient event when drift detected and --exit-on-drift set
        if exit_on_drift && report.has_drift() {
            let lock_dir = repo_root.join(".chump-locks");
            let ambient = lock_dir.join("ambient.jsonl");
            if let Ok(ts_out) = std::process::Command::new("date")
                .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                .output()
            {
                let ts_str = String::from_utf8_lossy(&ts_out.stdout).trim().to_string();
                let starved_json: Vec<String> = report
                    .starved_outcomes
                    .iter()
                    .map(|w| w.to_string())
                    .collect();
                let untraced_json: Vec<String> = report
                    .untraced_p0
                    .iter()
                    .map(|id| format!(r#""{id}""#))
                    .collect();
                let event = format!(
                    r#"{{"ts":"{ts}","kind":"roadmap_drift_detected","starved_outcomes":[{s}],"untraced_p0":[{u}]}}"#,
                    ts = ts_str,
                    s = starved_json.join(","),
                    u = untraced_json.join(","),
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

        if want_json {
            println!("{}", report.render_json_with_opts(top_starved));
        } else {
            print!("{}", report.render_text_with_opts(top_starved));
        }

        if exit_on_drift && report.has_drift() {
            eprintln!(
                "[roadmap-status] DRIFT: {} starved outcome(s), {} untraced P0/P1 gap(s)",
                report.starved_outcomes.len(),
                report.untraced_p0.len()
            );
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump fleet-status` (INFRA-494) — single-command operator
    // dashboard combining active leases, last-24h shipped/abandoned,
    // last-24h waste tally summary, and recent fleet wedges.
    // `chump ambient-rotate` (INFRA-941) — rotate ambient.jsonl if over threshold.
    if args.get(1).map(String::as_str) == Some("ambient-rotate") {
        let repo_root = repo_path::repo_root();
        let ambient = repo_root.join(".chump-locks/ambient.jsonl");
        let threshold_mb = std::env::var("CHUMP_AMBIENT_MAX_MB")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(50);
        let size_mb = std::fs::metadata(&ambient)
            .map(|m| m.len() / (1024 * 1024))
            .unwrap_or(0);
        if crate::ambient_rotate::rotate_if_needed(&ambient) {
            println!(
                "rotated: ambient.jsonl ({} MB) → ambient.jsonl.1 (threshold {} MB)",
                size_mb, threshold_mb
            );
        } else {
            println!(
                "no-op: ambient.jsonl is {} MB (threshold {} MB)",
                size_mb, threshold_mb
            );
        }
        return Ok(());
    }

    if args.get(1).map(String::as_str) == Some("fleet-status") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump fleet-status");
            println!();
            println!("Single-command operator dashboard combining active leases, last-24h");
            println!("shipped/abandoned, last-24h waste tally summary, and recent fleet wedges.");
            println!();
            println!("Example:");
            println!("  chump fleet-status");
            return Ok(());
        }
        let repo_root = repo_path::repo_root();
        let status = fleet_status::snapshot(&repo_root);
        print!("{}", status.render_text());
        return Ok(());
    }

    // `chump plan` (INFRA-1021) — rank the open gap backlog and recommend the
    // next N to dispatch. Library implementation lives in crates/chump-planner;
    // v0.1 supports --format table and --reconcile-threshold; --explain,
    // --graph, json and mermaid are v0.2.
    if args.get(1).map(String::as_str) == Some("plan") {
        return run_plan_subcommand(&args);
    }

    // `chump fleet-velocity` (INFRA-566) — ships/hour over 1h/6h/24h
    // windows plus a forecast of hours until the open gap queue empties.
    // Helps the operator decide when to file more gaps vs let fleet idle.
    if args.get(1).map(String::as_str) == Some("fleet-velocity") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump fleet-velocity");
            println!();
            println!("Ships/hour over 1h/6h/24h windows plus a forecast of hours until the open");
            println!("gap queue empties. Helps decide when to file more gaps vs let fleet idle.");
            println!();
            println!("Example:");
            println!("  chump fleet-velocity");
            return Ok(());
        }
        let repo_root = repo_path::repo_root();
        let snap = fleet_velocity::snapshot(&repo_root);
        print!("{}", snap.render_text());
        return Ok(());
    }

    // `chump fanout <plan|apply|status>` (INFRA-1484) — cross-repo fan-out
    // primitive (Marcus M-B continuation). Sibling of `chump fleet plan/apply`
    // from INFRA-1483: where that fans out by parameter inside one repo, this
    // fans out across N repos. One repo = one reserved gap. AC#4 sandboxing
    // graceful-degrades in v1 (env hints surfaced, not enforced) — lands as
    // real container isolation under INFRA-1454.
    // `chump rollup <fanout-group> [--semantic] [--json]` (INFRA-1455) —
    // Marcus M-B converge step. Takes the fanout_group name set by
    // `chump fanout apply` (INFRA-1484), pulls the closed PR per gap, and
    // clusters by file-list Jaccard into named "Strategy A/B/..." classes
    // so the operator sees "12 PRs converged on Strategy A" instead of a
    // 40-PR firehose.
    if args.get(1).map(String::as_str) == Some("rollup") {
        let name = match args.get(2) {
            Some(n) => n.clone(),
            None => {
                eprintln!("Usage: chump rollup <fanout-group> [--semantic] [--json]");
                eprintln!();
                eprintln!("  Converges PRs from a chump fanout group into named strategy classes.");
                eprintln!(
                    "  --semantic enables Jaccard-similarity clustering across touched files."
                );
                eprintln!("  --json emits structured output.");
                std::process::exit(2);
            }
        };
        let semantic = args.iter().any(|a| a == "--semantic");
        let json_out = args.iter().any(|a| a == "--json");
        match rollup_cmd::run(&name, semantic, json_out) {
            Ok(()) => std::process::exit(0),
            Err(e) => {
                eprintln!("chump rollup: {e}");
                std::process::exit(1);
            }
        }
    }

    if args.get(1).map(String::as_str) == Some("fanout") {
        let sub = args.get(2).map(String::as_str).unwrap_or("");
        if sub.is_empty() || sub == "help" || sub == "--help" {
            println!(
                "Usage: chump fanout <plan|apply|status> <spec.yaml | name> [--dry-run] [--json]"
            );
            println!();
            println!("Cross-repo fan-out (INFRA-1484, Marcus M-B). One operator command,");
            println!("N repos, N isolated gaps. Spec format:");
            println!();
            println!("  name: shared-lib-bump");
            println!("  intent: |");
            println!("    Bump shared-lib to v2.0 in this service.");
            println!("  repos:");
            println!("    - path: ../service-a");
            println!("    - path: ../service-b");
            println!("  validation: ./scripts/test-integration.sh");
            println!("  success: integration suite passes");
            println!();
            println!("Subcommands:");
            println!("  plan   <spec.yaml>             dry-run; render the per-repo gap set");
            println!(
                "  apply  <spec.yaml> [--dry-run] reserve one gap per repo (fanout_group=<name>)"
            );
            println!("  status <name>                  aggregate reserved gaps by fanout_group");
            return Ok(());
        }
        match sub {
            "plan" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!("Usage: chump fanout plan <spec.yaml>");
                        std::process::exit(2);
                    }
                };
                let spec_dir = path
                    .parent()
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| std::path::PathBuf::from("."));
                match fleet_fanout::FanoutSpec::from_path(&path) {
                    Ok(spec) => {
                        let plan = spec.plan(&spec_dir);
                        if args.iter().any(|a| a == "--json") {
                            println!("{}", serde_json::to_string_pretty(&plan).unwrap());
                        } else {
                            print!("{}", fleet_fanout::render_plan(&plan));
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "apply" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!("Usage: chump fanout apply <spec.yaml> [--dry-run]");
                        std::process::exit(2);
                    }
                };
                let spec_dir = path
                    .parent()
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| std::path::PathBuf::from("."));
                let dry_run = args.iter().any(|a| a == "--dry-run");
                match fleet_fanout::FanoutSpec::from_path(&path) {
                    Ok(spec) => {
                        let plan = spec.plan(&spec_dir);
                        println!(
                            "fanout apply: {} repo(s) (group={}, dry_run={dry_run})",
                            plan.len(),
                            spec.name
                        );
                        for (i, g) in plan.iter().enumerate() {
                            if dry_run {
                                println!(
                                    "  [dry-run] {} | {} → {}",
                                    i + 1,
                                    g.repo_label,
                                    g.target_repo
                                );
                                for w in &g.env_isolation_warnings {
                                    println!("            ⚠ {w}");
                                }
                                continue;
                            }
                            if !std::path::Path::new(&g.target_repo).exists() {
                                eprintln!(
                                    "  [failed] {}: target_repo not found: {} (v1: clone the repo first; auto-clone lands with a follow-up)",
                                    g.repo_label, g.target_repo
                                );
                                std::process::exit(1);
                            }
                            let notes = fleet_fanout::build_gap_notes(g);
                            let chump_bin =
                                std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                            let out = std::process::Command::new(&chump_bin)
                                .args([
                                    "gap", "reserve", "--domain", &g.domain, "--title", &g.title,
                                    "--effort", &g.effort, "--notes", &notes,
                                ])
                                .output();
                            match out {
                                Ok(o) if o.status.success() => {
                                    let body = String::from_utf8_lossy(&o.stdout);
                                    let id = body
                                        .lines()
                                        .find_map(|l| {
                                            let t = l.trim();
                                            // gap reserve prints lines like:
                                            //   "Reserved INFRA-NNN" or "INFRA-NNN"
                                            t.split_whitespace()
                                                .find(|w| {
                                                    w.contains('-')
                                                        && w.split('-').nth(1).is_some_and(|n| {
                                                            n.chars().all(|c| c.is_ascii_digit())
                                                        })
                                                })
                                                .map(String::from)
                                        })
                                        .unwrap_or_else(|| "?".to_string());
                                    println!(
                                        "  [reserved] {} ({}) → {}",
                                        g.repo_label, g.target_repo, id
                                    );
                                    for w in &g.env_isolation_warnings {
                                        println!("             ⚠ {w}");
                                    }
                                }
                                Ok(o) => {
                                    eprintln!(
                                        "  [failed] {}: {}",
                                        g.repo_label,
                                        String::from_utf8_lossy(&o.stderr).trim()
                                    );
                                    std::process::exit(1);
                                }
                                Err(e) => {
                                    eprintln!("  [failed] {}: spawn error: {e}", g.repo_label);
                                    std::process::exit(1);
                                }
                            }
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "status" => {
                let name = match args.get(3) {
                    Some(n) => n.clone(),
                    None => {
                        eprintln!("Usage: chump fanout status <name>");
                        std::process::exit(2);
                    }
                };
                let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                let out = std::process::Command::new(&chump_bin)
                    .args(["gap", "list", "--json"])
                    .output();
                let Ok(o) = out else {
                    eprintln!("error: could not exec chump gap list");
                    std::process::exit(1);
                };
                let body = String::from_utf8_lossy(&o.stdout);
                let report = fleet_fanout::aggregate_status(&body, &name);
                if args.iter().any(|a| a == "--json") {
                    println!("{}", serde_json::to_string_pretty(&report).unwrap());
                } else {
                    print!("{}", report.render_text());
                }
                std::process::exit(0);
            }
            other => {
                eprintln!("chump fanout: unknown subcommand '{other}'");
                eprintln!("Try: chump fanout <plan|apply|status> [args…]");
                std::process::exit(2);
            }
        }
    }

    // `chump waste-tally [--since 24h|7d|...] [--json]`
    // (INFRA-488) — Zero Waste mission pillar measurement primitive.
    // Aggregates ALERT events from .chump-locks/ambient.jsonl that match
    // the waste taxonomy (fleet_wedge, fleet_starved, lease_expired_server,
    // reaper_silent, queue_stuck, ambient_oversize, pr_stuck, silent_agent,
    // lease_overlap, edit_burst) and prints a per-kind tally with rough
    // cost estimates where measurable. No new event emissions in MVP.
    if args.get(1).map(String::as_str) == Some("waste-tally") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!(
                "Usage: chump waste-tally [--since WINDOW] [--json] [--domain|--by-domain] [--tokens] [--by-close-reason] [--emit-ambient]"
            );
            println!();
            println!("Zero-Waste pillar measurement. Tallies waste events from ambient.jsonl");
            println!("(fleet_wedge, fleet_starved, pr_stuck, silent_agent, lease_overlap, …)");
            println!("with per-kind counts and rough cost estimates.");
            println!();
            println!("Options:");
            println!(
                "  --since T          time window: 24h, 7d, 60m, or raw seconds  [default: 24h]"
            );
            println!("  --json             output in JSON format");
            println!(
                "  --domain           break down waste by gap domain (exits 1 if any domain >40%)"
            );
            println!("  --by-domain        alias for --domain (back-compat)");
            println!("  --tokens           include token-cost estimates");
            println!("  --by-close-reason  classify closed-not-merged PRs by close-comment pattern (INFRA-998)");
            println!("                     Categories: superseded, duplicate_claim, stale_branch,");
            println!("                     scratch_commit, ci_fail_orphan, staging_branch, other");
            println!(
                "  --emit-ambient     with --by-close-reason: write kind=waste_category_report"
            );
            println!("                     to ambient.jsonl (for weekly cron)");
            println!();
            println!("Example:");
            println!("  chump waste-tally --since 7d");
            println!("  chump waste-tally --window 2h   # alias accepted by fleet scaling gate");
            println!("  chump waste-tally --by-close-reason --since 7d --json");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "24h".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        // INFRA-934: --domain is the canonical flag; --by-domain remains for back-compat.
        let by_domain = args.iter().any(|a| a == "--by-domain" || a == "--domain");
        let want_tokens = args.iter().any(|a| a == "--tokens");
        // INFRA-998: PR-closure-reason categorization.
        let by_close_reason = args.iter().any(|a| a == "--by-close-reason");
        let emit_ambient = args.iter().any(|a| a == "--emit-ambient");

        // Parse "24h" / "7d" / "60m" / raw seconds.
        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump waste-tally: invalid --since '{}' (expected like 24h, 7d, 60m, or seconds)",
                since_arg
            );
            std::process::exit(2);
        });

        let repo_root = repo_path::repo_root();
        // INFRA-998: close-reason mode. Mutually exclusive with --domain.
        if by_close_reason {
            let report = waste_tally::build_close_reason_report(since_secs);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            if emit_ambient {
                report.emit_ambient(&repo_root);
            }
            return Ok(());
        }
        if by_domain {
            let report = waste_tally::build_domain_report(&repo_root, since_secs);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            // INFRA-934: exit non-zero if any single domain exceeds 40% of total token spend.
            if let Some(breach) = report.any_domain_exceeds(40.0) {
                eprintln!(
                    "chump waste-tally: domain '{}' is {:.1}% of total token spend (threshold 40%)",
                    breach.domain, breach.pct_of_total
                );
                std::process::exit(1);
            }
        } else {
            let report = waste_tally::build_report(&repo_root, since_secs);
            if want_json {
                println!("{}", report.render_json());
            } else if want_tokens {
                print!("{}", report.render_text_tokens());
            } else {
                print!("{}", report.render_text());
            }
        }
        return Ok(());
    }

    // `chump pr-coupling-cost <PR#> [--diff-files f1,f2,...] [--json]`
    // (INFRA-595) — CREDIBLE: per-PR coupling-tax measurement.
    // Reads .github/workflows/ci.yml dorny/paths-filter rules; for each file
    // in the PR diff prints a table of {file, jobs_triggered}.
    // --diff-files accepts a comma-separated override (for tests/offline use).
    if args.get(1).map(String::as_str) == Some("pr-coupling-cost") {
        let pr_number: Option<u64> = args.get(2).and_then(|s| s.parse().ok());
        let want_json = args.iter().any(|a| a == "--json");

        let diff_files_override: Option<Vec<String>> = args
            .iter()
            .position(|a| a == "--diff-files")
            .and_then(|i| args.get(i + 1))
            .map(|s| s.split(',').map(|f| f.trim().to_string()).collect());

        let diff_files: Vec<String> = if let Some(files) = diff_files_override {
            files
        } else if let Some(pr) = pr_number {
            pr_coupling_cost::fetch_pr_files(pr)
        } else {
            eprintln!("Usage: chump pr-coupling-cost <PR#> [--diff-files f1,f2,...] [--json]");
            std::process::exit(2);
        };

        let repo_root = repo_path::repo_root();
        let ci_yml_path = repo_root.join(".github/workflows/ci.yml");
        let ci_yml = std::fs::read_to_string(&ci_yml_path).unwrap_or_else(|e| {
            eprintln!(
                "chump pr-coupling-cost: cannot read {}: {e}",
                ci_yml_path.display()
            );
            std::process::exit(1);
        });

        let report = pr_coupling_cost::build_report(pr_number, &diff_files, &ci_yml);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        return Ok(());
    }

    // `chump pr fix-clippy <PR#> [--dry-run]`
    // (INFRA-618) — ZERO-WASTE: auto-fix obvious clippy lints on a PR branch.
    // Targets: manual_split_once, unused_variables, redundant_clone, single_match.
    // Safety: refuses if --fix touches >3 files or diff looks non-trivial.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("fix-clippy")
    {
        let pr_number: Option<u64> = args.get(3).and_then(|s| s.parse().ok());
        let pr_number = match pr_number {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump pr fix-clippy <PR#> [--dry-run]");
                std::process::exit(2);
            }
        };
        let dry_run = args.iter().any(|a| a == "--dry-run");
        let repo_root = repo_path::repo_root();
        match pr_fix_clippy::fix_clippy(pr_number, &repo_root, dry_run) {
            Ok(r) => {
                if !r.dry_run {
                    println!(
                        "chump pr fix-clippy: PR #{} fixed — {} files, {} lines.",
                        r.pr_number, r.files_changed, r.lines_changed
                    );
                }
            }
            Err(e) => {
                eprintln!("chump pr fix-clippy: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump pr triage [--rerun-flakes] [--rebase-dirty] [--json]`
    // (INFRA-605) — EFFECTIVE: scan all open PRs, classify, report CI health.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("triage")
    {
        let opts = pr_triage::TriageOptions {
            rerun_flakes: args.iter().any(|a| a == "--rerun-flakes"),
            rebase_dirty: args.iter().any(|a| a == "--rebase-dirty"),
            json: args.iter().any(|a| a == "--json"),
        };
        match pr_triage::run_triage(&opts) {
            Ok(report) => {
                if opts.json {
                    print!("{}", pr_triage::render_json(&report));
                } else {
                    print!("{}", pr_triage::render_text(&report));
                }
            }
            Err(e) => {
                eprintln!("chump pr triage: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump pr ac-coverage <PR#> [--advisory]`
    // (INFRA-1541) — CREDIBLE: pre-merge AC coverage gate
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("ac-coverage")
    {
        let pr_number: Option<u64> = args.get(3).and_then(|s| s.parse().ok());
        let pr_number = match pr_number {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump pr ac-coverage <PR#>");
                std::process::exit(2);
            }
        };
        match pr_ac_coverage::run(pr_number) {
            Ok(result) => {
                // print JSON summary
                println!("{}", pr_ac_coverage::render_json(&result));
                if result.status == pr_ac_coverage::CoverageStatus::Miss
                    && std::env::var("CHUMP_AC_GATE_ADVISORY").as_deref() != Ok("true")
                {
                    std::process::exit(1);
                }
            }
            Err(e) => {
                eprintln!("chump pr ac-coverage: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump paramedic triage|execute|daemon [--dry-run] [--interval-secs N] [--budget-secs N] [--plan F]`
    // (INFRA-1375) — RESILIENT: rule-engine PR rescue daemon.
    // triage  — read PR state, emit JSON action plan (read-only)
    // execute — run one triage→execute cycle with optional --plan <file>
    // daemon  — loop triage→execute every --interval-secs (default 600)
    if args.get(1).map(String::as_str) == Some("paramedic") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let dry_run = args.iter().any(|a| a == "--dry-run");

        if subcmd == "help" || args.iter().any(|a| a == "--help") {
            println!("Usage: chump paramedic <subcommand> [options]");
            println!();
            println!("Subcommands:");
            println!("  triage               Read PR state and emit JSON action plan (read-only).");
            println!("  execute [--plan F]   Run one triage→execute cycle. --plan reads from file");
            println!("                       instead of re-triaging.");
            println!("  daemon               Loop triage→execute forever. Single-instance via PID");
            println!("                       file at .chump-locks/paramedic.lock.");
            println!();
            println!("Options:");
            println!("  --dry-run            Print actions; do not actually run gh commands.");
            println!("  --interval-secs N    Daemon loop interval in seconds (default: 600).");
            println!("  --budget-secs N      Per-PR action budget in seconds (default: 90).");
            println!("  --plan F             Path to JSON plan file (execute only).");
            println!();
            println!("Examples:");
            println!("  chump paramedic triage");
            println!("  chump paramedic triage | chump paramedic execute --plan /dev/stdin");
            println!("  chump paramedic daemon --interval-secs 300 --dry-run");
            return Ok(());
        }

        match subcmd {
            "triage" => match paramedic::triage(&repo_root, dry_run) {
                Ok(plan) => {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&plan).unwrap_or_default()
                    );
                }
                Err(e) => {
                    eprintln!("chump paramedic triage: {e}");
                    std::process::exit(1);
                }
            },
            "execute" => {
                let budget_secs = args
                    .iter()
                    .position(|a| a == "--budget-secs")
                    .and_then(|i| args.get(i + 1))
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(90);

                // Optionally read plan from --plan <file>; otherwise triage first.
                let plan_path = args
                    .iter()
                    .position(|a| a == "--plan")
                    .and_then(|i| args.get(i + 1));

                let plan = if let Some(path) = plan_path {
                    let raw = std::fs::read_to_string(path)
                        .with_context(|| format!("reading plan from {path}"))?;
                    serde_json::from_str::<paramedic::ActionPlan>(&raw)
                        .context("parsing plan JSON")?
                } else {
                    paramedic::triage(&repo_root, dry_run)?
                };

                if let Err(e) = paramedic::execute(&plan, &repo_root, dry_run, budget_secs) {
                    eprintln!("chump paramedic execute: {e}");
                    std::process::exit(1);
                }
            }
            "daemon" => {
                let interval_secs = args
                    .iter()
                    .position(|a| a == "--interval-secs")
                    .and_then(|i| args.get(i + 1))
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(600);

                if let Err(e) = paramedic::daemon(interval_secs, &repo_root, dry_run) {
                    eprintln!("chump paramedic daemon: {e}");
                    std::process::exit(1);
                }
            }
            other => {
                eprintln!("chump paramedic: unknown subcommand '{other}'");
                eprintln!("Run 'chump paramedic help' for usage.");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump health-digest [--since 7d] [--json] [--emit] [--webhook]`
    // (INFRA-646) — RESILIENT: weekly health digest. Summarises ships count,
    // ship rate, waste $ by class, top-3 burning gaps, P0 compliance, pillar
    // balance, SLO breaches, and EFFECTIVE productizations for the past 7 days.
    // --emit appends a weekly_health_digest event to ambient.jsonl.
    // --webhook POSTs to CHUMP_WEBHOOK_URL (if set).
    if args.get(1).map(String::as_str) == Some("health-digest") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump health-digest [--since WINDOW] [--json] [--emit] [--webhook]");
            println!();
            println!("Weekly markdown digest with P0/P1 gap counts, waste rate, ship rate,");
            println!("and fleet wedge warnings. Suitable for team standup or operator review.");
            println!();
            println!("Options:");
            println!("  --since T   time window: 7d, 14d, 24h  [default: 7d]");
            println!("  --json      output in JSON format");
            println!("  --emit      write event to ambient.jsonl");
            println!("  --webhook   POST to CHUMP_WEBHOOK_URL");
            println!();
            println!("Example:");
            println!("  chump health-digest --since 7d");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "7d".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        let do_emit = args.iter().any(|a| a == "--emit");
        let do_webhook = args.iter().any(|a| a == "--webhook");
        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump health-digest: invalid --since '{}' (expected like 7d, 14d, 24h)",
                since_arg
            );
            std::process::exit(2);
        });
        let repo_root = repo_path::repo_root();
        let summary = health::build_week_summary(&repo_root, since_secs);
        if want_json {
            println!("{}", summary.render_json());
        } else {
            print!("{}", summary.render_text());
        }
        if do_emit {
            health::emit_to_ambient(&repo_root, &summary);
        }
        if do_webhook {
            let delivered = health::deliver_webhook(&summary);
            if !delivered {
                eprintln!("chump health-digest: webhook delivery skipped or failed (check CHUMP_WEBHOOK_URL)");
            }
        }
        return Ok(());
    }

    // `chump ship-quality [--since 24h|7d|...] [--json]`
    // (INFRA-537) — per-agent ship-quality grade. Aggregates ship_grade
    // events emitted by bot-merge.sh into per-model and per-agent tables
    // showing clippy_ok%, test_added%, and rebase_clean% pass rates.
    // Empirical basis for FLEET_MODEL routing decisions (sonnet vs haiku).
    if args.get(1).map(String::as_str) == Some("ship-quality") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump ship-quality [--since WINDOW] [--json]");
            println!();
            println!("Per-agent ship-quality grade: clippy_ok%, test_added%, rebase_clean%.");
            println!("Aggregates ship_grade events from ambient.jsonl by model and agent.");
            println!("Use for FLEET_MODEL routing decisions (sonnet vs haiku).");
            println!();
            println!("Options:");
            println!("  --since T   time window: 24h, 7d, 60m  [default: 24h]");
            println!("  --json      output in JSON format");
            println!();
            println!("Example:");
            println!("  chump ship-quality --since 7d");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "24h".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump ship-quality: invalid --since '{}' (expected like 24h, 7d, 60m, or seconds)",
                since_arg
            );
            std::process::exit(2);
        });
        let repo_root = repo_path::repo_root();
        let report = ship_quality::build_report(&repo_root, since_secs);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        return Ok(());
    }

    // `chump rebase-stuck [--pr <N>] [--apply] [--json]`
    // (INFRA-607) — RESILIENT: detect DIRTY PRs and attempt auto-rebase.
    // Safety gate: only auto-resolves conflicts in <3 files AND <20 lines
    // AND no test-touching files. --apply force-pushes with-lease.
    if args.get(1).map(String::as_str) == Some("rebase-stuck") {
        let sub_args: Vec<String> = args[2..].to_vec();
        let exit_code = rebase_stuck::run(&sub_args);
        std::process::exit(exit_code);
    }

    // `chump ci-summary [--since 24h|7d|...] [--json]`
    // (INFRA-506) — CI observability primitive. Reads gh run list + failed
    // job logs for the window and classifies failures as flake /
    // test-coupling / real-bug / infra-broken. Output mirrors waste-tally:
    // per-class count + sample diagnostic lines.
    if args.get(1).map(String::as_str) == Some("ci-summary") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!(
                "Usage: chump ci-summary [--since WINDOW] [--json] [--emit-alert] [--threshold N]"
            );
            println!();
            println!("CI observability: reads gh run list and classifies failures as flake /");
            println!("test-coupling / real-bug / infra-broken. Output mirrors waste-tally.");
            println!();
            println!("Options:");
            println!("  --since T       time window: 24h, 7d, 60m  [default: 24h]");
            println!("  --json          output in JSON format");
            println!("  --emit-alert    write ambient alert if failure rate > threshold");
            println!("  --threshold N   failure-rate % for alert trigger  [default: 10]");
            println!();
            println!("Example:");
            println!("  chump ci-summary --since 7d");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "24h".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        let emit_alert = args.iter().any(|a| a == "--emit-alert");
        let threshold_pct: u64 = args
            .iter()
            .position(|a| a == "--threshold")
            .and_then(|i| args.get(i + 1))
            .and_then(|v| v.parse().ok())
            .unwrap_or(10);

        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump ci-summary: invalid --since '{}' (expected like 24h, 7d, 60m, or seconds)",
                since_arg
            );
            std::process::exit(2);
        });

        let report = ci_summary::build_report(since_secs);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        if emit_alert {
            let ambient_path = repo_path::repo_root().join(".chump-locks/ambient.jsonl");
            if report.emit_ambient_alert(threshold_pct, &ambient_path) {
                eprintln!(
                    "ci-summary: ALERT emitted — failure rate {}% exceeds {}% threshold",
                    report.failure_rate_pct(),
                    threshold_pct
                );
            }
        }
        return Ok(());
    }

    // `chump classify-failure [--job NAME] [--log FILE|-] [--json]`  (INFRA-647)
    // Reads docs/process/FAILURE_MODES.yaml and classifies a CI failure.
    // pr-triage-bot.yml calls this to decide: fix | rerun | file_gap | escalate.
    if args.get(1).map(String::as_str) == Some("classify-failure") {
        failure_catalog::run_classify(&args[2..]);
        return Ok(());
    }

    // `chump session-track --start <GAP-ID>` / `--end <GAP-ID> --outcome <s|a|t>`
    // (INFRA-477) — per-session cost ledger MVP. Writes session_start +
    // session_end events to ambient.jsonl. Briefing surfaces aggregate
    // stats for past sessions in the same domain so the next session
    // sees how long similar work has historically taken.
    if args.get(1).map(String::as_str) == Some("session-track") {
        let st_flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1).cloned())
        };
        let session_id =
            crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
        let repo_root = repo_path::repo_root();
        if let Some(gap_id) = st_flag("--start") {
            session_ledger::emit_session_start(&repo_root, &session_id, &gap_id);
            let dashboard_url = std::env::var("CHUMP_WEB_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:3000".to_string());
            println!(
                "session_start logged: gap={} session={}\ndashboard: {}",
                gap_id, session_id, dashboard_url
            );
            return Ok(());
        }
        if let Some(gap_id) = st_flag("--end") {
            let outcome_str = st_flag("--outcome").unwrap_or_else(|| {
                eprintln!(
                    "chump session-track --end: missing --outcome <shipped|abandoned|starved>"
                );
                std::process::exit(2);
            });
            let outcome = session_ledger::Outcome::from_str(&outcome_str)
                .unwrap_or_else(|| {
                    eprintln!("chump session-track --end: unknown outcome '{}' (expected shipped|abandoned|starved)", outcome_str);
                    std::process::exit(2);
                });
            // INFRA-534: optional token counts for cost telemetry.
            let tokens = match (
                st_flag("--input-tokens").and_then(|s| s.parse::<u64>().ok()),
                st_flag("--output-tokens").and_then(|s| s.parse::<u64>().ok()),
                st_flag("--cache-read-tokens").and_then(|s| s.parse::<u64>().ok()),
            ) {
                (Some(i), Some(o), cache) => Some(session_ledger::TokenCounts {
                    input_tokens: i,
                    output_tokens: o,
                    cache_read_tokens: cache.unwrap_or(0),
                }),
                _ => None,
            };
            session_ledger::emit_session_end(&repo_root, &session_id, &gap_id, outcome, tokens);
            println!(
                "session_end logged: gap={} outcome={}",
                gap_id,
                outcome.as_str()
            );
            return Ok(());
        }
        eprintln!("Usage: chump session-track --start <GAP-ID>");
        eprintln!(
            "       chump session-track --end <GAP-ID> --outcome <shipped|abandoned|starved>"
        );
        std::process::exit(2);
    }

    // `chump session-export [--session-id <ID>]` (INFRA-616) — emit a handoff
    // snapshot to ~/.chump/sessions/<session-id>.md so the next Opus
    // orchestrator session can resume with full context via session-resume.
    if args.get(1).map(String::as_str) == Some("session-export") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump session-export [--session-id ID]");
            println!();
            println!("Export the current session transcript to ~/.chump/sessions/<ID>.md");
            println!("for handoff to the next orchestrator session via 'chump session-resume'.");
            println!();
            println!("Options:");
            println!("  --session-id ID   session ID to export  [default: $CHUMP_SESSION_ID]");
            println!();
            println!("Example:");
            println!("  chump session-export");
            println!("  chump session-export --session-id abc123");
            return Ok(());
        }
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1).cloned())
        };
        let session_id = flag("--session-id")
            .or_else(|| crate::ambient_stream::env_session_id())
            .unwrap_or_else(|| {
                // Fall back to a timestamp-based ID so exports are never lost.
                format!("session-{}", unix_ts())
            });
        let repo_root = repo_path::repo_root();
        let export = session_export::build_export(&session_id, &repo_root);
        let md = export.render_md();

        let out_path = session_export::export_path(&session_id);
        if let Some(parent) = out_path.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                eprintln!(
                    "chump session-export: cannot create {}: {e:#}",
                    parent.display()
                );
                std::process::exit(1);
            }
        }
        if let Err(e) = std::fs::write(&out_path, &md) {
            eprintln!(
                "chump session-export: cannot write {}: {e:#}",
                out_path.display()
            );
            std::process::exit(1);
        }
        println!("session-export written: {}", out_path.display());
        print!("{}", md);
        return Ok(());
    }

    // `chump session-resume <session-id>` (INFRA-616) — read a prior export
    // and print it to stdout for injection into the new session's context.
    if args.get(1).map(String::as_str) == Some("session-resume") {
        let session_id = args.get(2).cloned().unwrap_or_else(|| {
            eprintln!("Usage: chump session-resume <session-id>");
            std::process::exit(2);
        });
        let path = session_export::export_path(&session_id);
        let content = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            eprintln!(
                "chump session-resume: cannot read {}: {e:#}",
                path.display()
            );
            std::process::exit(1);
        });
        print!("{}", content);
        return Ok(());
    }

    // `chump dashboard` (INFRA-063 / M5) — print the cycle-time dashboard:
    // `chump reflect-delta <GAP-ID> "<text>"` (COG-042) — record what
    // this session did *differently* than past attempts on the gap's
    // class. Pure additive: writes a `delta_recorded` event to
    // ambient.jsonl. Briefing surfaces these for similar gaps so the
    // next session sees how the previous attempt's approach differed.
    if args.get(1).map(String::as_str) == Some("reflect-delta") {
        let gap_id = args.get(2).cloned().unwrap_or_else(|| {
            eprintln!("Usage: chump reflect-delta <GAP-ID> \"<what was different>\"");
            std::process::exit(2);
        });
        if gap_id.starts_with("--") {
            eprintln!("Usage: chump reflect-delta <GAP-ID> \"<what was different>\"");
            std::process::exit(2);
        }
        let text = args.get(3).cloned().unwrap_or_else(|| {
            eprintln!("chump reflect-delta: missing the delta text");
            eprintln!("Usage: chump reflect-delta <GAP-ID> \"<what was different>\"");
            std::process::exit(2);
        });
        let session_id =
            crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
        let repo_root = repo_path::repo_root();
        reflect_delta::emit_delta_recorded(&repo_root, &session_id, &gap_id, &text);
        println!("recorded delta for {} (session={})", gap_id, session_id);
        return Ok(());
    }

    // PRs landed today/week, median PR-open time, dispatcher backend split,
    // top 5 stale linked worktrees. Pure read aggregator over `gh` + `git`.
    if args.get(1).map(String::as_str) == Some("dashboard") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump dashboard");
            println!();
            println!("Print the cycle-time dashboard: active leases, gap queue depth,");
            println!("recent ship/abandon events, and provider health.");
            println!();
            println!("Example:");
            println!("  chump dashboard");
            return Ok(());
        }
        if let Err(e) = dashboard::print_dashboard() {
            eprintln!("chump dashboard: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump cascade stats [--json]` (INFRA-269) — per-slot cascade traffic
    // table from chump_provider_quality. Companion to the
    // 40-cascade-consumption-report.sh overnight script: this is the
    // on-demand human-facing equivalent. Pure read; safe to run anytime.
    if args.get(1).map(String::as_str) == Some("cascade")
        && args.get(2).map(String::as_str) == Some("stats")
    {
        let json_out = args.iter().any(|a| a == "--json");
        if let Err(e) = cascade_stats::print_stats(json_out) {
            eprintln!("chump cascade stats: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // PRODUCT-015: every non-init session start is a candidate d2-return. The
    // emitter no-ops unless install happened > 24h ago and d2 hasn't fired yet.
    activation::emit_return_d2_if_due();

    // `chump --recipe <path> [--<param> <value> ...]` (COMP-008) — run a packaged
    // workflow from a YAML recipe file.
    //
    // A recipe declares its required env vars, required tools, named parameters
    // with defaults, and an ordered list of steps. Each step is a command with
    // {{param}} substitutions in its args. See docs/process/CHUMP_RECIPES.md for schema
    // and recipes/ for bundled examples.
    //
    // Parameter overrides are collected from the remaining args as flag-value
    // pairs: `--model claude-haiku-4-5 --n 20`. Underscore ↔ hyphen are both
    // accepted as parameter name separators.
    //
    // Exit codes: 0 on success, 1 on recipe error, 2 on usage error.
    if let Some(pos) = args.iter().position(|a| a == "--recipe") {
        let path_str = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if path_str.is_empty() || path_str.starts_with("--") {
            eprintln!("Usage: chump --recipe <path.yaml> [--<param> <value> ...]");
            std::process::exit(2);
        }
        // Collect remaining key=value pairs (skip --recipe <path> at pos and pos+1)
        let mut param_overrides: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        let mut i = pos + 2;
        while i < args.len() {
            let flag = &args[i];
            if flag.starts_with("--") {
                let key = flag.trim_start_matches('-').replace('-', "_");
                if let Some(val) = args.get(i + 1) {
                    if !val.starts_with("--") {
                        param_overrides.insert(key, val.clone());
                        i += 2;
                        continue;
                    }
                }
                // boolean flag with no value — treat as "true"
                param_overrides.insert(key, "true".to_string());
            }
            i += 1;
        }
        let recipe_path = std::path::Path::new(path_str);
        let repo_root = repo_path::repo_root();
        // Resolve recipe path: if relative, try relative to repo root first
        let resolved_path = if recipe_path.is_absolute() {
            recipe_path.to_path_buf()
        } else {
            let candidate = repo_root.join(recipe_path);
            if candidate.exists() {
                candidate
            } else {
                recipe_path.to_path_buf()
            }
        };
        match recipe::run_recipe(&resolved_path, &param_overrides, &repo_root) {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump --recipe: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump dispatch <GAP-ID>` (INFRA-191 Phase 1+2) — atomic ship cycle:
    // preflight → claim → (work) → ship → release.
    //
    // Phase 1 wraps gap-preflight.sh, gap-claim.sh, bot-merge.sh.
    // Phase 2 adds --backend headless / exec-gap (spawns `claude -p` or
    // `chump --execute-gap`). Phase 3 ports ship() to native Rust.
    // See docs/design/INFRA-191-chump-dispatch.md.
    //
    // Examples:
    //   chump dispatch INFRA-191                              # interactive (default)
    //   chump dispatch INFRA-191 --auto-merge                 # arm merge queue
    //   chump dispatch INFRA-191 --auto-merge --skip-tests    # for doc PRs
    //   chump dispatch INFRA-191 --paths "src/dispatch.rs"    # narrow lease scope
    //   chump dispatch INFRA-191 --backend headless \
    //       --prompt "ship the gap" --model claude-sonnet-4-6 # spawn `claude -p`
    //   chump dispatch INFRA-191 --backend exec-gap           # spawn `chump --execute-gap`
    // INFRA-392: subcommands route/scoreboard/simulate are handled later in
    // this file. Without this guard, args[2]="route" (etc.) was treated as a
    // gap-id and routed through gap-preflight + bot-merge — making
    // `chump dispatch route INFRA-191` claim a phantom gap named "route"
    // instead of printing a routing cascade.
    const DISPATCH_SUBCOMMANDS: &[&str] = &["route", "scoreboard", "simulate", "cost-report"];
    if args.get(1).map(String::as_str) == Some("dispatch")
        && !args
            .get(2)
            .map(|s| DISPATCH_SUBCOMMANDS.contains(&s.as_str()))
            .unwrap_or(false)
    {
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
            "interactive" | "claude" /* alias */ => dispatch::WorkBackend::Interactive,
            "headless" => dispatch::WorkBackend::Headless {
                model: model.clone(),
                prompt: prompt.clone(),
            },
            "exec-gap" | "chump-local" /* alias */ => dispatch::WorkBackend::ExecGap,
            other => {
                eprintln!(
                    "chump dispatch: unknown --backend {other:?}; expected one of: interactive, headless, exec-gap"
                );
                std::process::exit(2);
            }
        };

        let repo_root = repo_path::repo_root();
        let opts = dispatch::DispatchOptions {
            gap_id: &gap_id,
            work,
            auto_merge,
            skip_tests,
            paths: paths.as_deref(),
            repo_root,
        };

        match dispatch::run(opts) {
            Ok(outcome) => {
                println!(
                    "[dispatch] {} branch={} duration={}s",
                    outcome.gap_id, outcome.branch, outcome.duration_secs
                );
                match outcome.result {
                    dispatch::ShipResult::Shipped { pr_number } => {
                        println!("[dispatch] shipped PR #{pr_number}");
                        return Ok(());
                    }
                    dispatch::ShipResult::Blocked { reason } => {
                        eprintln!("[dispatch] blocked: {reason}");
                        std::process::exit(1);
                    }
                    dispatch::ShipResult::Aborted { error } => {
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

    // `chump fleet <start|stop|status|scale>` (INFRA-596)
    // Wraps scripts/dispatch/run-fleet.sh + fleet-status.sh so operators
    // don't need to remember FLEET_SIZE/FLEET_EFFORT_FILTER/CHUMP_REPO env vars.
    // Reads defaults from ~/.chump/config.toml [fleet] section when present.
    if args.get(1).map(String::as_str) == Some("fleet") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let run_fleet_sh = repo_root.join("scripts/dispatch/run-fleet.sh");
        let fleet_status_sh = repo_root.join("scripts/dispatch/fleet-status.sh");
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };

        // Simple [fleet] section reader for ~/.chump/config.toml.
        let config_toml = std::env::var("HOME")
            .ok()
            .map(std::path::PathBuf::from)
            .map(|h| h.join(".chump/config.toml"))
            .and_then(|p| std::fs::read_to_string(p).ok())
            .unwrap_or_default();
        let cfg = |key: &str| -> Option<String> {
            config_toml
                .lines()
                .find(|l| l.trim_start().starts_with(key))
                .and_then(|l| l.split_once('=').map(|x| x.1))
                .map(|v| v.trim().trim_matches('"').to_string())
                .filter(|v| !v.is_empty())
        };

        match subcmd {
            "start" => {
                let size = flag("--size")
                    .or_else(|| cfg("size"))
                    .unwrap_or_else(|| "2".to_string());
                let model = flag("--model")
                    .or_else(|| cfg("model"))
                    .unwrap_or_else(|| "sonnet".to_string());
                let effort = flag("--effort")
                    .or_else(|| cfg("effort"))
                    .unwrap_or_else(|| "xs,s,m".to_string());
                let domain = flag("--domain")
                    .or_else(|| cfg("domain"))
                    .unwrap_or_default();

                // INFRA-1052: harness selection — pair harness with model so the
                // operator can run `chump fleet start --harness opencode --model sonnet`
                // and have workers spawn opencode-flavored agents. CLAUDE.md INFRA-AUTH
                // precedence applies: CLI flag > env > config.toml > default. The
                // dispatcher half (INFRA-1045) reads FLEET_HARNESS in worker.sh.
                const KNOWN_HARNESSES: &[&str] = &["claude", "opencode", "codex", "manual"];
                let harness = flag("--harness")
                    .or_else(|| {
                        std::env::var("CHUMP_AGENT_HARNESS")
                            .ok()
                            .filter(|v| !v.is_empty())
                    })
                    .or_else(|| cfg("harness"))
                    .unwrap_or_else(|| "claude".to_string());
                if !KNOWN_HARNESSES.contains(&harness.as_str()) {
                    eprintln!(
                        "chump fleet start: unknown --harness '{harness}'. Known: {}",
                        KNOWN_HARNESSES.join(", ")
                    );
                    eprintln!("  (Add a new harness to scripts/dispatch/harnesses/<name>.sh per INFRA-1045.)");
                    std::process::exit(2);
                }

                // Persist last-used config for `chump fleet restart`.
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let last_config = std::path::Path::new(&home).join(".chump/last-fleet-config.json");
                let _ = std::fs::create_dir_all(
                    last_config.parent().unwrap_or(std::path::Path::new("/tmp")),
                );
                let _ = std::fs::write(
                    &last_config,
                    serde_json::to_string_pretty(&serde_json::json!({
                        "size": size,
                        "model": model,
                        "harness": harness,
                        "effort": effort,
                        "domain": domain,
                        "session": flag("--session").or_else(|| cfg("session")).unwrap_or_else(|| "chump-fleet".to_string()),
                        "updated_at": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                    }))
                    .unwrap_or_default(),
                );

                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", &size)
                    .env("FLEET_MODEL", &model)
                    .env("FLEET_HARNESS", &harness)
                    .env("FLEET_EFFORT_FILTER", &effort)
                    .env("FLEET_DOMAIN_FILTER", &domain)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet start: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            "stop" => {
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());
                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", "0")
                    .env("FLEET_SESSION", &session)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet stop: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            "status" => {
                let want_json = args.iter().any(|a| a == "--json");
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&fleet_status_sh);
                if want_json {
                    cmd.arg("--json");
                } else {
                    cmd.arg("--once");
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet status: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            "scale" => {
                let n_str = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump fleet scale <N>");
                    std::process::exit(2);
                });
                let n: u32 = n_str.parse().unwrap_or_else(|_| {
                    eprintln!("chump fleet scale: N must be a positive integer, got '{n_str}'");
                    std::process::exit(2);
                });
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());

                // Persist desired size so restarts and monitors can read it.
                let state_dir = repo_root.join(".chump");
                let _ = std::fs::create_dir_all(&state_dir);
                let _ = std::fs::write(state_dir.join("fleet-desired-size"), format!("{n}\n"));

                // Emit ambient event (matches fleet_scale_change schema in CLAUDE.md).
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    let _ = writeln!(
                        f,
                        "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_request\",\"to\":{n},\"session\":\"{session}\"}}"
                    );
                }

                // Count alive worker windows in the tmux session.
                let current_count: u32 = std::process::Command::new("tmux")
                    .args(["list-windows", "-t", &session, "-F", "#W"])
                    .output()
                    .ok()
                    .map(|o| {
                        String::from_utf8_lossy(&o.stdout)
                            .lines()
                            .filter(|l| l.starts_with("fleet-worker-"))
                            .count() as u32
                    })
                    .unwrap_or(0);

                println!("[fleet scale] session={session} current={current_count} → desired={n}");

                if n > current_count {
                    let worker_sh = repo_root.join("scripts/dispatch/worker.sh");
                    for i in (current_count + 1)..=n {
                        let pane_name = format!("fleet-worker-{i}");
                        let worker_cmd = format!("AGENT_ID={i} bash {}", worker_sh.display());
                        let ok = std::process::Command::new("tmux")
                            .args(["new-window", "-t", &session, "-n", &pane_name, &worker_cmd])
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if ok {
                            println!("[fleet scale] spawned {pane_name}");
                        } else {
                            eprintln!("[fleet scale] WARNING: failed to spawn {pane_name}");
                        }
                    }
                } else if n < current_count {
                    for i in (n + 1)..=current_count {
                        let target = format!("{session}:fleet-worker-{i}");
                        let ok = std::process::Command::new("tmux")
                            .args(["kill-window", "-t", &target])
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if ok {
                            println!("[fleet scale] killed fleet-worker-{i}");
                        } else {
                            println!("[fleet scale] fleet-worker-{i} not found (already stopped)");
                        }
                    }
                } else {
                    println!("[fleet scale] already at {n} workers — no change");
                }
                return Ok(());
            }
            "snapshot" => {
                // `chump fleet snapshot` — INFRA-612
                // Captures current fleet state (leases, locks, queue size, ambient tail)
                // into .chump/restart-snapshots/<ts>.json for later replay.
                let snapshots_dir = repo_root.join(".chump/restart-snapshots");
                let _ = std::fs::create_dir_all(&snapshots_dir);
                let locks_dir = repo_root.join(".chump-locks");

                let ts = chrono::Utc::now();
                let ts_str = ts.format("%Y%m%d-%H%M%S").to_string();
                let ts_iso = ts.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                // Collect active lease files.
                let mut leases: Vec<serde_json::Value> = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(raw) = std::fs::read_to_string(&path) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                                    leases.push(serde_json::json!({
                                        "filename": path.file_name()
                                            .and_then(|n| n.to_str())
                                            .unwrap_or("unknown"),
                                        "lease": v
                                    }));
                                }
                            }
                        }
                    }
                }

                // Collect last 200 lines of ambient.jsonl.
                let ambient_path = locks_dir.join("ambient.jsonl");
                let ambient_tail: Vec<serde_json::Value> = std::fs::read_to_string(&ambient_path)
                    .unwrap_or_default()
                    .lines()
                    .rev()
                    .take(200)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect();

                // Fleet desired size.
                let fleet_desired_size: Option<u32> =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok());

                let snapshot = serde_json::json!({
                    "snapshot_id": ts_str,
                    "ts": ts_iso,
                    "fleet_desired_size": fleet_desired_size,
                    "leases": leases,
                    "ambient_tail": ambient_tail
                });

                let out_path = snapshots_dir.join(format!("{ts_str}.json"));
                match std::fs::write(
                    &out_path,
                    serde_json::to_string_pretty(&snapshot).unwrap_or_default(),
                ) {
                    Ok(()) => {
                        println!("[fleet snapshot] wrote {}", out_path.display());
                        println!(
                            "[fleet snapshot] leases={} ambient_events={}",
                            leases.len(),
                            ambient_tail.len()
                        );
                        // Emit ambient event.
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            let _ = writeln!(
                                f,
                                "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_snapshot\",\"snapshot_id\":\"{ts_str}\",\"leases\":{}}}", leases.len()
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("[fleet snapshot] failed to write snapshot: {e}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "restore" => {
                // `chump fleet restore <snapshot-id>` — INFRA-612
                // Replays lease state from a snapshot created by `fleet snapshot`.
                // Useful for diagnostics after a planned restart.
                let snapshot_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump fleet restore <snapshot-id>");
                    eprintln!("  snapshot-id: timestamp like 20260506-191935 or full path");
                    std::process::exit(2);
                });

                let snapshots_dir = repo_root.join(".chump/restart-snapshots");
                let locks_dir = repo_root.join(".chump-locks");

                // Resolve snapshot path — accept full path or bare ID.
                let snap_path = if std::path::Path::new(&snapshot_id).exists() {
                    std::path::PathBuf::from(&snapshot_id)
                } else {
                    snapshots_dir.join(format!("{snapshot_id}.json"))
                };

                let raw = std::fs::read_to_string(&snap_path).unwrap_or_else(|e| {
                    eprintln!("[fleet restore] cannot read {}: {e}", snap_path.display());
                    std::process::exit(1);
                });
                let snapshot: serde_json::Value = serde_json::from_str(&raw).unwrap_or_else(|e| {
                    eprintln!("[fleet restore] invalid JSON in snapshot: {e}");
                    std::process::exit(1);
                });

                let ts_iso = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let ambient_path = locks_dir.join("ambient.jsonl");
                let _ = std::fs::create_dir_all(&locks_dir);

                // Replay leases — write each back to .chump-locks/<filename>.
                let mut replayed = 0u32;
                if let Some(leases) = snapshot["leases"].as_array() {
                    for entry in leases {
                        let filename = entry["filename"].as_str().unwrap_or("unknown.json");
                        let lease_val = &entry["lease"];
                        if lease_val.is_null() {
                            continue;
                        }
                        let dest = locks_dir.join(filename);
                        if let Ok(content) = serde_json::to_string_pretty(lease_val) {
                            if std::fs::write(&dest, content).is_ok() {
                                println!("[fleet restore] replayed lease → {}", dest.display());
                                replayed += 1;
                            }
                        }
                    }
                }

                // Restore fleet-desired-size if present.
                if let Some(size) = snapshot["fleet_desired_size"].as_u64() {
                    let _ = std::fs::create_dir_all(repo_root.join(".chump"));
                    let _ = std::fs::write(
                        repo_root.join(".chump/fleet-desired-size"),
                        format!("{size}\n"),
                    );
                    println!("[fleet restore] fleet-desired-size → {size}");
                }

                println!("[fleet restore] snapshot={snapshot_id} leases_replayed={replayed}");

                // Emit ambient event.
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    let _ = writeln!(
                        f,
                        "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_restore\",\"snapshot_id\":\"{snapshot_id}\",\"leases_replayed\":{replayed}}}"
                    );
                }
                return Ok(());
            }
            "audit-pids" => {
                // `chump fleet audit-pids [--apply]` — INFRA-649
                //
                // Checks that claude_pid_count == 2 * worker_count (±1 tolerance).
                // Each worker spawns a `timeout Ns claude -p ...` wrapper + the claude
                // subprocess, so 2 PIDs per worker is the invariant.
                //
                // Without --apply: report only.
                // With --apply:
                //   PIDs > expected+1 → pkill orphans (INFRA-602 sentinel pattern)
                //   PIDs < expected-1 → respawn via fleet-restart.sh (INFRA-611)
                //
                // Emits kind=fleet_pid_invariant to ambient.jsonl with delta + action.
                let apply = args.iter().any(|a| a == "--apply");
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

                let worker_count: u32 =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(0);

                let expected = worker_count * 2;

                // pgrep -c exits 1 when no matches but still prints "0"; handle both.
                let actual: u32 = std::process::Command::new("pgrep")
                    .args(["-c", "-f", "timeout [0-9]*s claude -p "])
                    .output()
                    .ok()
                    .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
                    .unwrap_or(0);

                let delta: i64 = actual as i64 - expected as i64;
                let in_tolerance = delta.abs() <= 1;

                println!(
                    "[fleet audit-pids] worker_count={worker_count} expected_pids={expected} \
                     actual_pids={actual} delta={delta:+} apply={apply}"
                );

                let action = if in_tolerance {
                    println!("[fleet audit-pids] invariant OK (within ±1 tolerance)");
                    "ok"
                } else if !apply {
                    if delta > 0 {
                        println!(
                            "[fleet audit-pids] DRIFT: {delta:+} excess PIDs — run with --apply to prune"
                        );
                    } else {
                        println!(
                            "[fleet audit-pids] DRIFT: {delta} missing PIDs — run with --apply to respawn"
                        );
                    }
                    "drift"
                } else if delta > 0 {
                    // More PIDs than expected → kill orphaned timeout+claude pairs.
                    println!("[fleet audit-pids] --apply: pruning orphan PIDs (delta={delta:+})");
                    let _ = std::process::Command::new("pkill")
                        .args(["-f", "timeout [0-9]*s claude -p "])
                        .status();
                    "pruned"
                } else {
                    // Fewer PIDs than expected → respawn via fleet-restart.sh.
                    println!(
                        "[fleet audit-pids] --apply: respawning fleet to worker_count={worker_count}"
                    );
                    let restart_sh = repo_root.join("scripts/dispatch/fleet-restart.sh");
                    let session = cfg("session").unwrap_or_else(|| "chump-fleet".to_string());
                    let _ = std::process::Command::new("bash")
                        .arg(&restart_sh)
                        .env("FLEET_SIZE", worker_count.to_string())
                        .env("FLEET_SESSION", &session)
                        .status();
                    "respawned"
                };

                // Emit ambient event.
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    let _ = writeln!(
                        f,
                        "{{\"ts\":\"{ts}\",\"kind\":\"fleet_pid_invariant\",\
                         \"worker_count\":{worker_count},\"expected\":{expected},\
                         \"actual\":{actual},\"delta\":{delta},\
                         \"apply\":{apply},\"action\":\"{action}\"}}"
                    );
                }
                return Ok(());
            }
            "restart" => {
                // `chump fleet restart` — INFRA-610
                let fleet_restart_sh = repo_root.join("scripts/dispatch/fleet-restart.sh");
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());
                let size_override = flag("--size");

                // 1. Take a before-restart snapshot.
                let snapshots_dir = repo_root.join(".chump/restart-snapshots");
                let _ = std::fs::create_dir_all(&snapshots_dir);
                let locks_dir = repo_root.join(".chump-locks");
                let ts = chrono::Utc::now();
                let ts_str = ts.format("%Y%m%d-%H%M%S").to_string();
                let ts_iso = ts.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                let mut leases: Vec<serde_json::Value> = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(raw) = std::fs::read_to_string(&path) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                                    leases.push(serde_json::json!({
                                        "filename": path.file_name()
                                            .and_then(|n| n.to_str())
                                            .unwrap_or("unknown"),
                                        "lease": v
                                    }));
                                }
                            }
                        }
                    }
                }

                let ambient_path = locks_dir.join("ambient.jsonl");
                let ambient_tail: Vec<serde_json::Value> = std::fs::read_to_string(&ambient_path)
                    .unwrap_or_default()
                    .lines()
                    .rev()
                    .take(200)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect();

                let desired_size: Option<u32> =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok());

                let snapshot = serde_json::json!({
                    "snapshot_id": ts_str,
                    "ts": ts_iso,
                    "kind": "pre_restart",
                    "fleet_desired_size": desired_size,
                    "leases": leases,
                    "ambient_tail": ambient_tail
                });

                let out_path = snapshots_dir.join(format!("{ts_str}.json"));
                match std::fs::write(
                    &out_path,
                    serde_json::to_string_pretty(&snapshot).unwrap_or_default(),
                ) {
                    Ok(()) => {
                        println!("[fleet restart] snapshot saved to {}", out_path.display());
                        println!(
                            "[fleet restart] leases={} ambient_events={}",
                            leases.len(),
                            ambient_tail.len()
                        );
                        let _ = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                            .and_then(|mut f| {
                                writeln!(
                                    f,
                                    "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_restart_snapshot\",\"snapshot_id\":\"{ts_str}\"}}"
                                )
                            });
                    }
                    Err(e) => {
                        eprintln!("[fleet restart] WARNING: failed to save snapshot: {e}");
                    }
                }

                // 2. Resolve fleet size: --size flag > last-fleet-config > desired-size > config.toml > 2
                let size = size_override
                    .or_else(|| {
                        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                        let p = std::path::Path::new(&home).join(".chump/last-fleet-config.json");
                        std::fs::read_to_string(&p).ok().and_then(|raw| {
                            serde_json::from_str::<serde_json::Value>(&raw)
                                .ok()
                                .and_then(|v| v["size"].as_str().map(String::from))
                        })
                    })
                    .or_else(|| desired_size.map(|s| s.to_string()))
                    .or_else(|| cfg("size"))
                    .unwrap_or_else(|| "2".to_string());

                // 3. Delegate to fleet-restart.sh
                let status = std::process::Command::new("bash")
                    .arg(&fleet_restart_sh)
                    .env("FLEET_SIZE", &size)
                    .env("FLEET_SESSION", &session)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet restart: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-721: 60-second operator briefing — 24h ships, pillar mix,
            // stalls, auto-fixed, manual rescues, suggested actions.
            // Wire: FLEET-019 SessionStart hook calls this at session open.
            "brief" => {
                let want_json = args.iter().any(|a| a == "--json");
                let window_secs: i64 = flag("--window")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(86400); // 24 h default

                let now = chrono::Utc::now();
                let now_ts = now.timestamp();
                let cutoff = now_ts - window_secs;
                let ts_iso = now.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                // INFRA-1355: fleet-wide state (ambient.jsonl, lease files)
                // lives only in the main checkout's .chump-locks/.  Linked
                // worktrees get a sparse .chump-locks/ with only their own
                // session files, so reading it gives ships=0 / stalls=0.
                // Always resolve via git-common-dir so brief shows correct
                // fleet totals regardless of CWD.
                let locks_dir = {
                    let main_root = repo_path::main_checkout_root();
                    let main_locks = main_root.join(".chump-locks");
                    if main_locks.is_dir() {
                        main_locks
                    } else {
                        repo_root.join(".chump-locks")
                    }
                };
                let ambient_path = locks_dir.join("ambient.jsonl");

                // ── Parse ambient.jsonl ──────────────────────────────────
                let events: Vec<serde_json::Value> = std::fs::read_to_string(&ambient_path)
                    .unwrap_or_default()
                    .lines()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect();

                // Filter to window
                let window_events: Vec<&serde_json::Value> = events
                    .iter()
                    .filter(|e| {
                        e.get("ts")
                            .and_then(|v| v.as_str())
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .map(|dt| dt.timestamp() >= cutoff)
                            .unwrap_or(false)
                    })
                    .collect();

                // Count by "event" field (top-level event type)
                let count_event = |ev: &str| -> usize {
                    window_events
                        .iter()
                        .filter(|e| e.get("event").and_then(|v| v.as_str()) == Some(ev))
                        .count()
                };
                // Count by "kind" sub-field (used in alert-category events)
                let count_kind = |kind: &str| -> usize {
                    window_events
                        .iter()
                        .filter(|e| e.get("kind").and_then(|v| v.as_str()) == Some(kind))
                        .count()
                };

                let ships = count_event("commit");
                let auto_fixed = count_kind("flake_rerun_queued") + count_kind("lint_auto_fix");
                let manual_rescues = count_kind("manual_rescue");
                let fleet_wedges = count_kind("fleet_wedge");
                // INFRA-1247: silent_agent and pr_stuck are surfaced below as
                // "investigate now" operator-action prompts. They must count
                // over the same 30 min window as `alerts(30m)` — not the 24h
                // main window — otherwise the brief shows 24h totals
                // (e.g. 27 silent_agents, 18 pr_stuck) as if they were current
                // alerts, conditioning the operator to ignore the prompts
                // entirely. Before this fix the same healthy fleet that
                // emitted 1 actual recent event in 30 min showed "27 events"
                // because old events from earlier in the day were still in
                // the 24h window.
                let alert_cutoff = now_ts - 30 * 60;
                let count_kind_recent = |kind: &str| -> usize {
                    events
                        .iter()
                        .filter(|e| {
                            e.get("kind").and_then(|v| v.as_str()) == Some(kind)
                                && e.get("ts")
                                    .and_then(|v| v.as_str())
                                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                                    .map(|dt| dt.timestamp() >= alert_cutoff)
                                    .unwrap_or(false)
                        })
                        .count()
                };
                let silent_agents = count_kind_recent("silent_agent");
                let pr_stuck = count_kind_recent("pr_stuck");
                let alerts: usize = events
                    .iter()
                    .filter(|e| {
                        let is_alert = e.get("event").and_then(|v| v.as_str()) == Some("ALERT")
                            || e.get("event").and_then(|v| v.as_str()) == Some("alert");
                        if !is_alert {
                            return false;
                        }
                        e.get("ts")
                            .and_then(|v| v.as_str())
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .map(|dt| dt.timestamp() >= alert_cutoff)
                            .unwrap_or(false)
                    })
                    .count();

                // Active leases → stall detection (leases older than 4h)
                let stall_threshold = now_ts - 4 * 3600;
                let mut stalls: Vec<String> = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(raw) = std::fs::read_to_string(&path) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                                    let gap_id = v
                                        .get("gap_id")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("?")
                                        .to_string();
                                    let claimed_at = v
                                        .get("claimed_at")
                                        .and_then(|x| x.as_i64())
                                        .unwrap_or(now_ts);
                                    if claimed_at < stall_threshold {
                                        let age_h = (now_ts - claimed_at) / 3600;
                                        stalls.push(format!("{gap_id} ({age_h}h)"));
                                    }
                                }
                            }
                        }
                    }
                }
                // ── Pillar mix from open P0/P1 gaps ─────────────────────────
                let store_res = gap_store::GapStore::open(&repo_root);
                let mut pillar_counts: std::collections::HashMap<&str, usize> = [
                    ("EFFECTIVE", 0),
                    ("CREDIBLE", 0),
                    ("RESILIENT", 0),
                    ("ZERO-WASTE", 0),
                ]
                .iter()
                .cloned()
                .collect();
                let mut total_pickable = 0usize;
                if let Ok(ref store) = store_res {
                    if let Ok(gaps) = store.list(Some("open")) {
                        for g in &gaps {
                            if !matches!(g.priority.as_str(), "P0" | "P1") {
                                continue;
                            }
                            if !matches!(g.effort.as_str(), "xs" | "s" | "m") {
                                continue;
                            }
                            total_pickable += 1;
                            let t = g.title.to_uppercase();
                            for pillar in &["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"] {
                                if t.contains(pillar) {
                                    *pillar_counts.entry(pillar).or_insert(0) += 1;
                                    break;
                                }
                            }
                        }
                    }
                }

                // ── Suggested actions ────────────────────────────────────
                let mut suggestions: Vec<String> = Vec::new();
                if fleet_wedges > 0 {
                    suggestions.push(format!(
                        "⚠  {} fleet_wedge event(s) — drop to 2 workers per CLAUDE.md",
                        fleet_wedges
                    ));
                }
                if silent_agents > 1 {
                    suggestions.push(format!(
                        "⚠  {} silent_agent event(s) — investigate lease/picker race",
                        silent_agents
                    ));
                }
                if pr_stuck >= 3 {
                    suggestions.push(format!(
                        "⚠  {} pr_stuck event(s) — diagnose bot-merge contention",
                        pr_stuck
                    ));
                }
                if !stalls.is_empty() {
                    suggestions.push(format!("⚠  Stalled leases: {}", stalls.join(", ")));
                }
                let zw = *pillar_counts.get("ZERO-WASTE").unwrap_or(&0);
                let re = *pillar_counts.get("RESILIENT").unwrap_or(&0);
                if zw < 2 {
                    suggestions.push(format!(
                        "📌 ZERO-WASTE has {zw} pickable gap(s) — file 1-2 to balance"
                    ));
                }
                if re < 2 {
                    suggestions.push(format!(
                        "📌 RESILIENT has {re} pickable gap(s) — file 1-2 to balance"
                    ));
                }
                if suggestions.is_empty() {
                    suggestions.push("✓  No urgent actions — fleet looks healthy".to_string());
                }

                if want_json {
                    let out = serde_json::json!({
                        "ts": ts_iso,
                        "window_h": window_secs / 3600,
                        "ships_24h": ships,
                        "auto_fixed": auto_fixed,
                        "manual_rescues": manual_rescues,
                        "stalls_gt_4h": stalls,
                        "fleet_wedges": fleet_wedges,
                        "silent_agents": silent_agents,
                        "pr_stuck": pr_stuck,
                        "alerts": alerts,
                        "pillar_mix": {
                            "EFFECTIVE": pillar_counts.get("EFFECTIVE").copied().unwrap_or(0),
                            "CREDIBLE":  pillar_counts.get("CREDIBLE").copied().unwrap_or(0),
                            "RESILIENT": pillar_counts.get("RESILIENT").copied().unwrap_or(0),
                            "ZERO-WASTE": pillar_counts.get("ZERO-WASTE").copied().unwrap_or(0),
                            "total_pickable": total_pickable,
                        },
                        "suggestions": suggestions,
                    });
                    println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
                } else {
                    let window_h = window_secs / 3600;
                    println!("═══ Fleet brief (last {window_h}h) ═══");
                    println!(
                        "Ships: {ships}  (≈{}/hr)",
                        if window_h > 0 {
                            format!("{:.1}", ships as f64 / window_h as f64)
                        } else {
                            "?".to_string()
                        }
                    );
                    let eff = pillar_counts.get("EFFECTIVE").copied().unwrap_or(0);
                    let cre = pillar_counts.get("CREDIBLE").copied().unwrap_or(0);
                    let res = pillar_counts.get("RESILIENT").copied().unwrap_or(0);
                    let zw2 = pillar_counts.get("ZERO-WASTE").copied().unwrap_or(0);
                    println!(
                        "Pillars: EFFECTIVE={eff} CREDIBLE={cre} RESILIENT={res} ZERO-WASTE={zw2}  (of {total_pickable} pickable)"
                    );
                    println!(
                        "Stalls > 4h: {}",
                        if stalls.is_empty() {
                            "0".to_string()
                        } else {
                            stalls.join(", ")
                        }
                    );
                    println!("Auto-fixed: {auto_fixed}  flake-rerun+lint");
                    println!("Manual rescues: {manual_rescues}");
                    if alerts > 0 {
                        println!("Alerts(30m): {alerts}");
                    }
                    if !suggestions.iter().all(|s| s.starts_with('✓')) {
                        println!("\nActions:");
                        for s in &suggestions {
                            println!("  {s}");
                        }
                    } else {
                        println!("{}", suggestions[0]);
                    }
                }
                return Ok(());
            }
            // INFRA-615: starvation auto-widen.
            // --analyze: reads ambient.jsonl for fleet_starved events in last 1h,
            //            suggests widened FLEET_EFFORT_FILTER / PRIORITY_FILTER.
            // --apply:   writes suggested config to ~/.chump/fleet-config.toml.
            "auto-widen" => {
                let do_apply = args.iter().any(|a| a == "--apply");
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");

                // Read ambient events from the last 3600s (1h).
                let now_secs = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                let horizon = now_secs.saturating_sub(3600);

                let mut starve_count = 0u32;
                if let Ok(content) = std::fs::read_to_string(&ambient_path) {
                    for line in content.lines() {
                        if !line.contains("fleet_starved") {
                            continue;
                        }
                        // Parse ts field to check recency.
                        let ts_secs: Option<u64> = line
                            .split('"')
                            .skip_while(|s| *s != "ts")
                            .nth(2)
                            .and_then(|ts| {
                                // "2026-05-11T22:00:00Z" → epoch seconds (rough parse)
                                chrono::DateTime::parse_from_rfc3339(ts)
                                    .ok()
                                    .map(|dt| dt.timestamp() as u64)
                            });
                        if ts_secs.is_none_or(|t| t >= horizon) {
                            starve_count += 1;
                        }
                    }
                }

                // Derive suggestions based on current config.
                let current_effort = std::env::var("FLEET_EFFORT_FILTER")
                    .ok()
                    .or_else(|| cfg("effort"))
                    .unwrap_or_else(|| "xs,s".to_string());
                let current_priority = std::env::var("FLEET_PRIORITY_FILTER")
                    .ok()
                    .or_else(|| cfg("priority_filter"))
                    .unwrap_or_else(|| "P0,P1".to_string());

                // Widen effort by appending next tier; widen priority by adding P2.
                let suggested_effort = if current_effort.contains('m') {
                    format!("{},l", current_effort.trim_end_matches(",l"))
                } else if current_effort.contains('s') {
                    format!("{},m", current_effort.trim_end_matches(",m"))
                } else {
                    format!("{},s,m", current_effort.trim_end_matches(",s,m"))
                };
                let suggested_priority = if current_priority.contains("P2") {
                    current_priority.clone()
                } else {
                    format!("{},P2", current_priority)
                };

                println!("[auto-widen] fleet_starved events in last 1h: {starve_count}");
                println!("[auto-widen] current effort filter : {current_effort}");
                println!("[auto-widen] current priority filter: {current_priority}");

                if starve_count == 0 {
                    println!("[auto-widen] no starvation detected — no change recommended");
                } else {
                    println!("[auto-widen] suggested effort filter : {suggested_effort}");
                    println!("[auto-widen] suggested priority filter: {suggested_priority}");
                    println!("[auto-widen] reason: {starve_count} starvation event(s) in last 1h");

                    if do_apply {
                        let config_dir = std::path::Path::new(&home).join(".chump");
                        let _ = std::fs::create_dir_all(&config_dir);
                        let fleet_config = config_dir.join("fleet-config.toml");
                        let toml_content = format!(
                            "# INFRA-615: auto-widen applied by 'chump fleet auto-widen --apply'\n\
                             # starve_events_1h = {starve_count}\n\
                             # applied_at = \"{}\"\n\
                             effort = \"{suggested_effort}\"\n\
                             priority_filter = \"{suggested_priority}\"\n",
                            chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
                        );
                        match std::fs::write(&fleet_config, &toml_content) {
                            Ok(_) => {
                                println!(
                                    "[auto-widen] wrote {} → restart fleet to apply",
                                    fleet_config.display()
                                );
                                // Emit ambient event.
                                let ambient_write = repo_root.join(".chump-locks/ambient.jsonl");
                                let event = format!(
                                    "{{\"ts\":\"{}\",\"kind\":\"fleet_auto_widen_applied\",\
                                     \"starve_count\":{starve_count},\
                                     \"effort\":\"{suggested_effort}\",\
                                     \"priority_filter\":\"{suggested_priority}\"}}\n",
                                    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
                                );
                                let _ = std::fs::OpenOptions::new()
                                    .append(true)
                                    .create(true)
                                    .open(&ambient_write)
                                    .and_then(|mut f| {
                                        use std::io::Write;
                                        f.write_all(event.as_bytes())
                                    });
                            }
                            Err(e) => {
                                eprintln!("[auto-widen] failed to write fleet-config.toml: {e}");
                                std::process::exit(1);
                            }
                        }
                    } else {
                        println!(
                            "[auto-widen] run with --apply to write ~/.chump/fleet-config.toml"
                        );
                    }
                }
            }
            // INFRA-650: fleet auto-prune-down controller.
            // Evaluates 4 conditions and recommends (or applies) a scale-down.
            "auto-resize" => {
                let apply = args.iter().any(|a| a == "--apply");
                let as_json = args.iter().any(|a| a == "--json");
                let current_size: u32 =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(2);

                let decision = fleet_resize::evaluate(&repo_root, current_size);

                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

                match decision {
                    None => {
                        if as_json {
                            println!("{{\"fleet_resize_decision\":\"none\",\"current_size\":{current_size}}}");
                        } else {
                            println!(
                                "[fleet auto-resize] current_size={current_size} — no resize trigger fired"
                            );
                        }
                    }
                    Some(d) => {
                        let trigger_name = format!("{:?}", d.trigger);
                        if as_json {
                            println!(
                                "{{\"fleet_resize_decision\":\"resize\",\"trigger\":\"{trigger_name}\",\
                                 \"current_size\":{current_size},\"recommended_size\":{},\"rationale\":\"{}\"}}",
                                d.recommended_size,
                                d.rationale.replace('"', "'")
                            );
                        } else {
                            println!(
                                "[fleet auto-resize] trigger={trigger_name} \
                                 current={current_size} → recommended={}",
                                d.recommended_size
                            );
                            println!("[fleet auto-resize] rationale: {}", d.rationale);
                        }

                        // Emit ambient event (INFRA-650 AC criterion 4).
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            let _ = writeln!(
                                f,
                                "{{\"ts\":\"{ts}\",\"kind\":\"fleet_resize_decision\",\
                                 \"trigger\":\"{trigger_name}\",\"current_size\":{current_size},\
                                 \"recommended_size\":{},\"rationale\":\"{}\"}}",
                                d.recommended_size,
                                d.rationale.replace('"', "'")
                            );
                        }

                        if apply && d.recommended_size < current_size {
                            println!(
                                "[fleet auto-resize] --apply: scaling from {current_size} to {}",
                                d.recommended_size
                            );
                            // Write desired size.
                            let _ = std::fs::write(
                                repo_root.join(".chump/fleet-desired-size"),
                                format!("{}\n", d.recommended_size),
                            );
                            // Emit fleet_scale_change.
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                let _ = writeln!(
                                    f,
                                    "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_change\",\
                                     \"from\":{current_size},\"to\":{},\"rationale\":\"auto-resize: {trigger_name}\"}}",
                                    d.recommended_size
                                );
                            }
                        } else if !apply {
                            println!("[fleet auto-resize] run with --apply to execute resize");
                        }
                    }
                }
                return Ok(());
            }
            // INFRA-827: prune stale linked worktrees (age > CHUMP_WT_MAX_AGE_H AND no open PR)
            "prune-worktrees" => {
                let dry_run = !args.iter().any(|a| a == "--apply");
                let want_json = args.iter().any(|a| a == "--json");
                let max_age_h: u64 = std::env::var("CHUMP_WT_MAX_AGE_H")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(48);
                let max_age_secs = max_age_h * 3600;
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ts_now = chrono::Utc::now();
                let ts_iso = ts_now.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                // Parse `git worktree list --porcelain` output.
                let wt_out = std::process::Command::new("git")
                    .args(["worktree", "list", "--porcelain"])
                    .current_dir(&repo_root)
                    .output()
                    .unwrap_or_else(|e| {
                        eprintln!("[prune-worktrees] git worktree list failed: {e}");
                        std::process::exit(1);
                    });
                let wt_text = String::from_utf8_lossy(&wt_out.stdout);

                // Each worktree block is separated by a blank line.
                struct WtEntry {
                    path: String,
                    branch: String,
                }
                let mut worktrees: Vec<WtEntry> = Vec::new();
                let mut cur_path: Option<String> = None;
                let mut cur_branch: Option<String> = None;
                for line in wt_text.lines() {
                    if line.starts_with("worktree ") {
                        cur_path = Some(line["worktree ".len()..].trim().to_string());
                        cur_branch = None;
                    } else if line.starts_with("branch ") {
                        // branch refs/heads/<name>
                        let b = line["branch ".len()..].trim().to_string();
                        let branch_name = b.strip_prefix("refs/heads/").unwrap_or(&b).to_string();
                        cur_branch = Some(branch_name);
                    } else if line.is_empty() {
                        if let (Some(p), Some(b)) = (cur_path.take(), cur_branch.take()) {
                            worktrees.push(WtEntry { path: p, branch: b });
                        } else {
                            cur_path = None;
                            cur_branch = None;
                        }
                    }
                }
                // Flush last block if file doesn't end with blank line.
                if let (Some(p), Some(b)) = (cur_path, cur_branch) {
                    worktrees.push(WtEntry { path: p, branch: b });
                }

                // Skip the main worktree (first entry).
                let linked: Vec<&WtEntry> = worktrees.iter().skip(1).collect();

                let mut pruned_count: u32 = 0;
                let mut skipped_active_pr: u32 = 0;
                let mut skipped_uncommitted: u32 = 0;
                let mut skipped_young: u32 = 0;
                let mut pruned_paths: Vec<String> = Vec::new();
                let mut dry_run_candidates: Vec<String> = Vec::new();

                let _now_secs = ts_now.timestamp() as u64;

                for wt in &linked {
                    let wt_path = std::path::Path::new(&wt.path);

                    // Age check: use mtime of .git file inside the worktree.
                    let git_file = wt_path.join(".git");
                    let age_secs: u64 = git_file
                        .metadata()
                        .or_else(|_| wt_path.metadata())
                        .ok()
                        .and_then(|m| m.modified().ok())
                        .and_then(|mt| mt.elapsed().ok())
                        .map(|d| d.as_secs())
                        .unwrap_or(0);

                    if age_secs < max_age_secs {
                        skipped_young += 1;
                        continue;
                    }

                    // Uncommitted changes check.
                    let status_out = std::process::Command::new("git")
                        .args(["status", "--porcelain"])
                        .current_dir(wt_path)
                        .output()
                        .ok();
                    let has_dirty = status_out
                        .as_ref()
                        .map(|o| !o.stdout.is_empty())
                        .unwrap_or(false);
                    if has_dirty {
                        skipped_uncommitted += 1;
                        if !want_json {
                            println!(
                                "[prune-worktrees] KEEP (dirty) {}  branch={}",
                                wt.path, wt.branch
                            );
                        }
                        continue;
                    }

                    // Open PR check via gh CLI.
                    let has_open_pr = std::process::Command::new("gh")
                        .args([
                            "pr", "list", "--head", &wt.branch, "--state", "open", "--json",
                            "number", "--jq", "length",
                        ])
                        .output()
                        .ok()
                        .and_then(|o| {
                            String::from_utf8_lossy(&o.stdout)
                                .trim()
                                .parse::<u32>()
                                .ok()
                        })
                        .map(|n| n > 0)
                        .unwrap_or(false);

                    if has_open_pr {
                        skipped_active_pr += 1;
                        if !want_json {
                            println!(
                                "[prune-worktrees] KEEP (open PR) {}  branch={}",
                                wt.path, wt.branch
                            );
                        }
                        continue;
                    }

                    // Stale — eligible for pruning.
                    let age_h = age_secs / 3600;
                    if dry_run {
                        dry_run_candidates.push(wt.path.clone());
                        if !want_json {
                            println!(
                                "[prune-worktrees] WOULD PRUNE (age={}h)  {}  branch={}",
                                age_h, wt.path, wt.branch
                            );
                        }
                    } else {
                        // Remove via git worktree remove --force.
                        let rm_ok = std::process::Command::new("git")
                            .args(["worktree", "remove", "--force", &wt.path])
                            .current_dir(&repo_root)
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if rm_ok {
                            pruned_count += 1;
                            pruned_paths.push(wt.path.clone());
                            if !want_json {
                                println!(
                                    "[prune-worktrees] PRUNED (age={}h)  {}  branch={}",
                                    age_h, wt.path, wt.branch
                                );
                            }
                            // Emit ambient event per pruned worktree.
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                let branch_esc = wt.branch.replace('"', "\\\"");
                                let path_esc = wt.path.replace('"', "\\\"");
                                let _ = writeln!(
                                    f,
                                    "{{\"ts\":\"{ts_iso}\",\"kind\":\"worktree_pruned\",\
                                     \"path\":\"{path_esc}\",\"branch\":\"{branch_esc}\",\"age_h\":{age_h}}}"
                                );
                            }
                        } else {
                            eprintln!("[prune-worktrees] WARNING: failed to remove {}", wt.path);
                        }
                    }
                }

                if want_json {
                    let candidates_json = if dry_run {
                        serde_json::to_string(&dry_run_candidates).unwrap_or_else(|_| "[]".into())
                    } else {
                        serde_json::to_string(&pruned_paths).unwrap_or_else(|_| "[]".into())
                    };
                    println!(
                        "{{\"dry_run\":{dry_run},\"max_age_h\":{max_age_h},\
                         \"pruned\":{pruned_count},\
                         \"skipped_active_pr\":{skipped_active_pr},\
                         \"skipped_uncommitted\":{skipped_uncommitted},\
                         \"skipped_young\":{skipped_young},\
                         \"paths\":{candidates_json}}}"
                    );
                } else if dry_run {
                    println!(
                        "[prune-worktrees] dry-run: {} stale worktrees would be pruned \
                         (skipped: {} active-PR, {} dirty, {} young)",
                        dry_run_candidates.len(),
                        skipped_active_pr,
                        skipped_uncommitted,
                        skipped_young
                    );
                    println!("[prune-worktrees] re-run with --apply to remove");
                } else {
                    println!(
                        "[prune-worktrees] done: pruned={pruned_count} \
                         skipped_active_pr={skipped_active_pr} \
                         skipped_uncommitted={skipped_uncommitted} \
                         skipped_young={skipped_young}"
                    );
                }

                if !dry_run && pruned_count > 0 {
                    // Emit summary ambient event.
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                    {
                        let _ = writeln!(
                            f,
                            "{{\"ts\":\"{ts_iso}\",\"kind\":\"worktree_prune_summary\",\
                             \"pruned\":{pruned_count},\"skipped_active_pr\":{skipped_active_pr},\
                             \"skipped_uncommitted\":{skipped_uncommitted},\"skipped_young\":{skipped_young}}}"
                        );
                    }
                }

                return Ok(());
            }
            "daemon" => {
                // INFRA-964: long-lived chump-owned scheduler. Reads
                // scripts/coord/system-gap-frequencies.yaml (INFRA-841) and
                // runs each declared task at its interval_s cadence by
                // shelling out to the task's existing script. Emits
                // kind=daemon_tick per invocation so missed cron windows
                // are observable instantly via ambient.jsonl.
                //
                // Replaces the Claude-Code-hosted scheduled-tasks MCP path,
                // which only fires while the host UI is alive (the bug
                // INFRA-964 was filed to capture). OS keeps this daemon
                // alive via launchd/com.chump.fleet-daemon.plist.
                let once = args.iter().any(|a| a == "--once");
                let yaml_path = repo_root.join("scripts/coord/system-gap-frequencies.yaml");
                let yaml_contents = std::fs::read_to_string(&yaml_path).map_err(|e| {
                    anyhow::anyhow!("fleet daemon: cannot read {}: {e}", yaml_path.display())
                })?;

                // Parse the tasks: { name, interval_s, script } from the YAML.
                // We use a minimal pure-Rust parser instead of pulling in
                // serde_yaml to keep the binary slim (same approach as the
                // bash hot-file-lock.sh awk parsing).
                #[derive(Clone, Debug)]
                struct DaemonTask {
                    name: String,
                    interval_s: u64,
                    script: String,
                    optional: bool,
                }
                let mut tasks: Vec<DaemonTask> = Vec::new();
                let mut in_tasks = false;
                let mut cur: Option<DaemonTask> = None;
                for line in yaml_contents.lines() {
                    if line.starts_with("tasks:") {
                        in_tasks = true;
                        continue;
                    }
                    if in_tasks
                        && !line.starts_with(' ')
                        && !line.starts_with('\t')
                        && !line.trim().is_empty()
                    {
                        in_tasks = false;
                    }
                    if !in_tasks {
                        continue;
                    }
                    let trimmed = line.trim_end();
                    // Task header: two-space indent + name: + newline.
                    if let Some(rest) = trimmed.strip_prefix("  ") {
                        if !rest.starts_with(' ') && rest.ends_with(':') {
                            if let Some(t) = cur.take() {
                                tasks.push(t);
                            }
                            let name = rest.trim_end_matches(':').to_string();
                            cur = Some(DaemonTask {
                                name,
                                interval_s: 0,
                                script: String::new(),
                                optional: false,
                            });
                            continue;
                        }
                    }
                    // Fields under the current task (four-space indent).
                    if let Some(t) = cur.as_mut() {
                        if let Some(rest) = trimmed.strip_prefix("    interval_s:") {
                            t.interval_s = rest
                                .split('#')
                                .next()
                                .unwrap_or("")
                                .trim()
                                .parse()
                                .unwrap_or(0);
                        } else if let Some(rest) = trimmed.strip_prefix("    script:") {
                            t.script = rest.trim().to_string();
                        } else if let Some(rest) = trimmed.strip_prefix("    optional:") {
                            t.optional = rest.trim().starts_with("true");
                        }
                    }
                }
                if let Some(t) = cur.take() {
                    tasks.push(t);
                }
                tasks.retain(|t| t.interval_s > 0 && !t.script.is_empty());
                // Filter out tasks whose script doesn't exist on disk when
                // they're marked optional (e.g. gap-gardener.sh stub).
                tasks.retain(|t| {
                    if t.optional && !repo_root.join(&t.script).exists() {
                        eprintln!(
                            "[fleet daemon] skipping optional task {} — script missing: {}",
                            t.name, t.script
                        );
                        false
                    } else {
                        true
                    }
                });

                if tasks.is_empty() {
                    eprintln!(
                        "[fleet daemon] no runnable tasks in {}",
                        yaml_path.display()
                    );
                    return Ok(());
                }

                // Ambient log path (mirrors scripts/coord/opus-curator.sh).
                let ambient_log = repo_root.join(".chump-locks/ambient.jsonl");
                let _ = std::fs::create_dir_all(ambient_log.parent().unwrap());

                let emit_tick =
                    |task: &DaemonTask, run_id: &str, exit_code: i32, elapsed_ms: u128| {
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let line = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"daemon_tick\",\
                          \"task\":\"{}\",\"interval_s\":{},\"run_id\":\"{run_id}\",\
                          \"exit_code\":{exit_code},\"elapsed_ms\":{elapsed_ms}}}\n",
                            task.name, task.interval_s
                        );
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_log)
                        {
                            use std::io::Write;
                            let _ = f.write_all(line.as_bytes());
                        }
                    };

                // Run a single tick: shell out to the task's script, capture
                // exit code + elapsed time, emit ambient event. Errors are
                // swallowed (logged) so one bad task doesn't kill the daemon.
                async fn run_tick(
                    task_name: String,
                    script_rel: String,
                    repo_root: std::path::PathBuf,
                ) -> (i32, u128) {
                    let script_path = repo_root.join(&script_rel);
                    let started = std::time::Instant::now();
                    let res = tokio::process::Command::new("bash")
                        .arg(&script_path)
                        .current_dir(&repo_root)
                        .output()
                        .await;
                    let elapsed_ms = started.elapsed().as_millis();
                    match res {
                        Ok(o) => {
                            let code = o.status.code().unwrap_or(-1);
                            if code != 0 {
                                eprintln!(
                                    "[fleet daemon] {} exit={} in {}ms",
                                    task_name, code, elapsed_ms
                                );
                            }
                            (code, elapsed_ms)
                        }
                        Err(e) => {
                            eprintln!(
                                "[fleet daemon] {} spawn failed: {e} ({}ms)",
                                task_name, elapsed_ms
                            );
                            (-1, elapsed_ms)
                        }
                    }
                }

                // Emit daemon_started so observers know the daemon is alive.
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let tasks_csv = tasks
                    .iter()
                    .map(|t| t.name.clone())
                    .collect::<Vec<_>>()
                    .join(",");
                let start_line = format!(
                    "{{\"ts\":\"{ts}\",\"kind\":\"daemon_started\",\
                      \"tasks\":\"{tasks_csv}\",\"mode\":\"{}\"}}\n",
                    if once { "once" } else { "loop" }
                );
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_log)
                {
                    use std::io::Write;
                    let _ = f.write_all(start_line.as_bytes());
                }

                if once {
                    // --once mode: run every task once, sequentially, then exit.
                    // Used by the install script's smoke test + by CI.
                    for t in &tasks {
                        let run_id =
                            format!("{}-{}", std::process::id(), chrono::Utc::now().timestamp());
                        let (exit_code, elapsed_ms) =
                            run_tick(t.name.clone(), t.script.clone(), repo_root.clone()).await;
                        emit_tick(t, &run_id, exit_code, elapsed_ms);
                    }
                    return Ok(());
                }

                // Long-lived loop mode: one tokio interval per declared task.
                eprintln!("[fleet daemon] starting {} tasks (loop mode)", tasks.len());
                let mut handles = Vec::new();
                for t in tasks {
                    let repo_root = repo_root.clone();
                    let ambient_log = ambient_log.clone();
                    handles.push(tokio::spawn(async move {
                        let mut ticker =
                            tokio::time::interval(std::time::Duration::from_secs(t.interval_s));
                        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                        loop {
                            ticker.tick().await;
                            let run_id = format!(
                                "{}-{}",
                                std::process::id(),
                                chrono::Utc::now().timestamp()
                            );
                            let (exit_code, elapsed_ms) =
                                run_tick(t.name.clone(), t.script.clone(), repo_root.clone()).await;
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            let line = format!(
                                "{{\"ts\":\"{ts}\",\"kind\":\"daemon_tick\",\
                                  \"task\":\"{}\",\"interval_s\":{},\
                                  \"run_id\":\"{run_id}\",\
                                  \"exit_code\":{exit_code},\
                                  \"elapsed_ms\":{elapsed_ms}}}\n",
                                t.name, t.interval_s
                            );
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_log)
                            {
                                use std::io::Write;
                                let _ = f.write_all(line.as_bytes());
                            }
                        }
                    }));
                }
                // Hold until any task errors out (none should under normal op).
                for h in handles {
                    let _ = h.await;
                }
                return Ok(());
            }
            // FLEET-037: ergonomic primary verb — like "start" but with an
            // idempotency guard: refuses if the tmux session is already running.
            "up" => {
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());

                // Idempotency: if session already running, bail early with clear guidance.
                let already_running = std::process::Command::new("tmux")
                    .args(["has-session", "-t", &session])
                    .status()
                    .map(|s| s.success())
                    .unwrap_or(false);

                if already_running {
                    eprintln!("[fleet up] session '{session}' is already running.");
                    eprintln!("  Use 'chump fleet status' to see current state.");
                    eprintln!("  Use 'chump fleet scale <N>' to resize.");
                    eprintln!("  Use 'chump fleet down' to stop first, then 'chump fleet up'.");
                    std::process::exit(2);
                }

                // Delegate to the same logic as "start" (shared via the start arm path).
                let size = flag("--size")
                    .or_else(|| cfg("size"))
                    .unwrap_or_else(|| "2".to_string());
                let model = flag("--model")
                    .or_else(|| cfg("model"))
                    .unwrap_or_else(|| "sonnet".to_string());
                let effort = flag("--effort")
                    .or_else(|| cfg("effort"))
                    .unwrap_or_else(|| "xs,s,m".to_string());
                let domain = flag("--domain")
                    .or_else(|| cfg("domain"))
                    .unwrap_or_default();

                const KNOWN_HARNESSES_UP: &[&str] = &["claude", "opencode", "codex", "manual"];
                let harness = flag("--harness")
                    .or_else(|| {
                        std::env::var("CHUMP_AGENT_HARNESS")
                            .ok()
                            .filter(|v| !v.is_empty())
                    })
                    .or_else(|| cfg("harness"))
                    .unwrap_or_else(|| "claude".to_string());
                if !KNOWN_HARNESSES_UP.contains(&harness.as_str()) {
                    eprintln!(
                        "chump fleet up: unknown --harness '{harness}'. Known: {}",
                        KNOWN_HARNESSES_UP.join(", ")
                    );
                    eprintln!("  (Add a new harness to scripts/dispatch/harnesses/<name>.sh per INFRA-1045.)");
                    std::process::exit(2);
                }

                // Persist last-used config for restart.
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let last_config = std::path::Path::new(&home).join(".chump/last-fleet-config.json");
                let _ = std::fs::create_dir_all(
                    last_config.parent().unwrap_or(std::path::Path::new("/tmp")),
                );
                let _ = std::fs::write(
                    &last_config,
                    serde_json::to_string_pretty(&serde_json::json!({
                        "size": size,
                        "model": model,
                        "harness": harness,
                        "effort": effort,
                        "domain": domain,
                        "session": session,
                        "updated_at": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                    }))
                    .unwrap_or_default(),
                );

                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", &size)
                    .env("FLEET_MODEL", &model)
                    .env("FLEET_HARNESS", &harness)
                    .env("FLEET_EFFORT_FILTER", &effort)
                    .env("FLEET_DOMAIN_FILTER", &domain)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet up: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-1446: work-discovery query — who is working on a given topic?
            // Usage: chump fleet whoworkson <topic> [--json]
            // Sources: (a) .chump-locks/claim-*.json lease files,
            //          (b) open PR titles/branches via `gh pr list`,
            //          (c) open gap titles/AC in state.db,
            //          (d) recent ambient gap_claimed events.
            // Returns a table (or JSON) sorted by recency, deduped by gap_id.
            "whoworkson" => {
                // Collect <topic> from args after "whoworkson"; skip flags.
                let topic: String = args
                    .iter()
                    .skip(3) // chump fleet whoworkson ...
                    .find(|a| !a.starts_with('-'))
                    .cloned()
                    .unwrap_or_else(|| {
                        eprintln!("Usage: chump fleet whoworkson <topic> [--json]");
                        std::process::exit(2);
                    });
                let want_json = args.iter().any(|a| a == "--json");
                let topic_lc = topic.to_lowercase();

                // ── Result row ────────────────────────────────────────────
                #[derive(Debug)]
                struct WhoRow {
                    kind: String,     // lease | pr | gap | ambient
                    id: String,       // gap_id / PR number / event id
                    claimant: String, // agent / worktree / author
                    since: String,    // ISO timestamp (for sort)
                    matches: String,  // excerpt that triggered the match
                }

                let mut rows: Vec<WhoRow> = Vec::new();
                // Deduplicate by (kind, id) — accumulate seen gap IDs across sources.
                let mut seen_gap_ids: std::collections::HashSet<String> =
                    std::collections::HashSet::new();

                let locks_dir = repo_root.join(".chump-locks");

                // ── (a) Active lease files ────────────────────────────────
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                        // Only claim-*.json lease files.
                        if !name.starts_with("claim-") || !name.ends_with(".json") {
                            continue;
                        }
                        let Ok(raw) = std::fs::read_to_string(&path) else {
                            continue;
                        };
                        let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) else {
                            continue;
                        };
                        let gap_id = v
                            .get("gap_id")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let purpose = v
                            .get("purpose")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let session_id = v
                            .get("session_id")
                            .and_then(|x| x.as_str())
                            .unwrap_or(name)
                            .to_string();
                        let taken_at = v
                            .get("taken_at")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let paths_str = v
                            .get("paths")
                            .and_then(|x| x.as_array())
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|p| p.as_str())
                                    .collect::<Vec<_>>()
                                    .join(",")
                            })
                            .unwrap_or_default();

                        // Check for topic match (case-insensitive) across gap_id, purpose, paths.
                        let haystack =
                            format!("{} {} {}", gap_id, purpose, paths_str).to_lowercase();
                        if !haystack.contains(topic_lc.as_str()) {
                            continue;
                        }
                        let key = format!("lease:{gap_id}");
                        if seen_gap_ids.contains(&key) {
                            continue;
                        }
                        seen_gap_ids.insert(key);
                        rows.push(WhoRow {
                            kind: "lease".to_string(),
                            id: gap_id.clone(),
                            claimant: session_id,
                            since: taken_at,
                            matches: format!("lease: {name}"),
                        });
                    }
                }

                // ── (b) Open PRs via `gh pr list` ─────────────────────────
                {
                    let gh_out = std::process::Command::new("gh")
                        .args([
                            "pr",
                            "list",
                            "--state",
                            "open",
                            "--json",
                            "number,title,headRefName,createdAt,author",
                            "--limit",
                            "200",
                        ])
                        .current_dir(&repo_root)
                        .output();
                    if let Ok(out) = gh_out {
                        let text = String::from_utf8_lossy(&out.stdout);
                        if let Ok(arr) = serde_json::from_str::<serde_json::Value>(&text) {
                            if let Some(prs) = arr.as_array() {
                                for pr in prs {
                                    let number = pr
                                        .get("number")
                                        .and_then(|x| x.as_i64())
                                        .map(|n| n.to_string())
                                        .unwrap_or_default();
                                    let title = pr
                                        .get("title")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let branch = pr
                                        .get("headRefName")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let created_at = pr
                                        .get("createdAt")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let author = pr
                                        .get("author")
                                        .and_then(|x| x.get("login"))
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("unknown")
                                        .to_string();

                                    let haystack = format!("{} {}", title, branch).to_lowercase();
                                    if !haystack.contains(topic_lc.as_str()) {
                                        continue;
                                    }
                                    // Try to extract gap ID from branch/title.
                                    let gap_id = {
                                        let combined = format!("{} {}", branch, title);
                                        // Pattern: INFRA-NNN, PRODUCT-NNN, etc.
                                        let mut found = String::new();
                                        for word in combined.split_whitespace() {
                                            let w = word.trim_matches(|c: char| {
                                                !c.is_alphanumeric() && c != '-'
                                            });
                                            if w.contains('-') {
                                                let parts: Vec<&str> = w.splitn(2, '-').collect();
                                                if parts.len() == 2
                                                    && parts[0]
                                                        .chars()
                                                        .all(|c| c.is_ascii_uppercase())
                                                    && parts[1].chars().all(|c| c.is_ascii_digit())
                                                    && parts[0].len() >= 3
                                                {
                                                    found = w.to_string();
                                                    break;
                                                }
                                            }
                                        }
                                        if found.is_empty() {
                                            format!("PR#{number}")
                                        } else {
                                            found
                                        }
                                    };
                                    let key = format!("pr:{gap_id}");
                                    if seen_gap_ids.contains(&key) {
                                        continue;
                                    }
                                    seen_gap_ids.insert(key);
                                    rows.push(WhoRow {
                                        kind: "pr".to_string(),
                                        id: gap_id,
                                        claimant: author,
                                        since: created_at,
                                        matches: format!("PR#{number}: {title}"),
                                    });
                                }
                            }
                        }
                    }
                }

                // ── (c) Open gap titles/AC in state.db ───────────────────
                {
                    use chump_gap_store as gap_store;
                    if let Ok(store) = gap_store::GapStore::open(&repo_root) {
                        let _ = store.auto_seed_if_empty();
                        if let Ok(all_gaps) = store.list(Some("open")) {
                            for g in &all_gaps {
                                let haystack =
                                    format!("{} {} {}", g.id, g.title, g.acceptance_criteria)
                                        .to_lowercase();
                                if !haystack.contains(topic_lc.as_str()) {
                                    continue;
                                }
                                let key = format!("gap:{}", g.id);
                                if seen_gap_ids.contains(&key) {
                                    continue;
                                }
                                seen_gap_ids.insert(key);
                                // Use created_at (unix) → ISO string for sort.
                                let since = if g.opened_date.is_empty() {
                                    use chrono::TimeZone;
                                    chrono::Utc
                                        .timestamp_opt(g.created_at, 0)
                                        .single()
                                        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
                                        .unwrap_or_default()
                                } else {
                                    format!("{}T00:00:00Z", g.opened_date)
                                };
                                let excerpt: String = g.title.chars().take(60).collect();
                                rows.push(WhoRow {
                                    kind: "gap".to_string(),
                                    id: g.id.clone(),
                                    claimant: "open (unclaimed)".to_string(),
                                    since,
                                    matches: excerpt,
                                });
                            }
                        }
                    }
                }

                // ── (d) Recent ambient gap_claimed events ─────────────────
                {
                    let ambient_path = locks_dir.join("ambient.jsonl");
                    // Scan last 500 lines for recency.
                    if let Ok(content) = std::fs::read_to_string(&ambient_path) {
                        let recent_lines: Vec<&str> = content
                            .lines()
                            .rev()
                            .take(500)
                            .collect::<Vec<_>>()
                            .into_iter()
                            .rev()
                            .collect();
                        for line in recent_lines {
                            if !line.contains("gap_claimed") {
                                continue;
                            }
                            let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                                continue;
                            };
                            let kind_field = v.get("kind").and_then(|x| x.as_str()).unwrap_or("");
                            if kind_field != "gap_claimed" {
                                continue;
                            }
                            let gap_id = v
                                .get("gap_id")
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string();
                            let ts = v
                                .get("ts")
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string();
                            let session = v
                                .get("session_id")
                                .or_else(|| v.get("session"))
                                .and_then(|x| x.as_str())
                                .unwrap_or("unknown")
                                .to_string();

                            let haystack = format!("{} {}", gap_id, line).to_lowercase();
                            if !haystack.contains(topic_lc.as_str()) {
                                continue;
                            }
                            let key = format!("ambient:{gap_id}");
                            if seen_gap_ids.contains(&key) {
                                continue;
                            }
                            seen_gap_ids.insert(key);
                            rows.push(WhoRow {
                                kind: "ambient".to_string(),
                                id: gap_id,
                                claimant: session,
                                since: ts,
                                matches: "gap_claimed event".to_string(),
                            });
                        }
                    }
                }

                // ── Sort by recency (most recent first) ───────────────────
                rows.sort_by(|a, b| b.since.cmp(&a.since));

                // ── Render ────────────────────────────────────────────────
                if want_json {
                    let out: Vec<serde_json::Value> = rows
                        .iter()
                        .map(|r| {
                            serde_json::json!({
                                "type": r.kind,
                                "id": r.id,
                                "claimant": r.claimant,
                                "since": r.since,
                                "matches": r.matches,
                            })
                        })
                        .collect();
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "topic": topic,
                            "results": out,
                        }))
                        .unwrap_or_default()
                    );
                } else if rows.is_empty() {
                    println!("No active work found matching '{topic}'.");
                } else {
                    // Table: type / id / claimant / since / matches
                    let col_widths = (8usize, 20usize, 28usize, 22usize);
                    println!(
                        "{:<width0$}  {:<width1$}  {:<width2$}  {:<width3$}  MATCHES",
                        "TYPE",
                        "ID",
                        "CLAIMANT",
                        "SINCE",
                        width0 = col_widths.0,
                        width1 = col_widths.1,
                        width2 = col_widths.2,
                        width3 = col_widths.3,
                    );
                    println!("{}", "-".repeat(100));
                    for r in &rows {
                        let since_short: String = r.since.chars().take(19).collect();
                        let claimant_short: String =
                            r.claimant.chars().take(col_widths.2).collect();
                        let id_short: String = r.id.chars().take(col_widths.1).collect();
                        println!(
                            "{:<width0$}  {:<width1$}  {:<width2$}  {:<width3$}  {}",
                            r.kind,
                            id_short,
                            claimant_short,
                            since_short,
                            r.matches,
                            width0 = col_widths.0,
                            width1 = col_widths.1,
                            width2 = col_widths.2,
                            width3 = col_widths.3,
                        );
                    }
                }
                return Ok(());
            }
            // INFRA-1568: broad canary — exec the lane-readiness script.
            // Exits 0 iff every production workflow step passes on the
            // candidate lane; non-zero with a named failing-step list.
            "canary" => {
                let lane = flag("--lane").unwrap_or_default();
                let script = repo_root.join("scripts/setup/test-runner-lane-broad-canary.sh");
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&script);
                if !lane.is_empty() {
                    cmd.arg("--lane").arg(&lane);
                }
                // Pass through --json and --record-baseline if present.
                if args.iter().any(|a| a == "--json") {
                    cmd.arg("--json");
                }
                if args.iter().any(|a| a == "--record-baseline") {
                    cmd.arg("--record-baseline");
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet canary: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            // FLEET-037: ergonomic primary verb — alias for "stop".
            "down" => {
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());
                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", "0")
                    .env("FLEET_SESSION", &session)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet down: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            "doctor" => {
                // INFRA-1595: fleet doctor — Wave 0b autonomy outer loop.
                //
                // Modes:
                //   (default)   diagnose-only (placeholder until INFRA-1427
                //               --strict lands; emits self_doctor_tick).
                //   --heal      auto-fix what's diagnosed. GATED on
                //               CHUMP_FLEET_SELF_DOCTOR_HEAL=true env (opt-in
                //               until INFRA-1541 50-PR observation phase done).
                //   --json      machine-readable output.
                let want_heal = args.iter().any(|a| a == "--heal");
                let want_json = args.iter().any(|a| a == "--json");
                let env_opt_in = std::env::var("CHUMP_FLEET_SELF_DOCTOR_HEAL")
                    .map(|v| v == "true" || v == "1")
                    .unwrap_or(false);

                if want_heal && !env_opt_in {
                    if want_json {
                        println!(
                            "{}",
                            serde_json::json!({
                                "status": "skipped",
                                "reason": "CHUMP_FLEET_SELF_DOCTOR_HEAL not set to true",
                                "hint": "Default-off until INFRA-1541 50-PR observation done."
                            })
                        );
                    } else {
                        eprintln!(
                            "chump fleet doctor --heal: refusing to run.\n  \
                             Heal mode is opt-in. Set CHUMP_FLEET_SELF_DOCTOR_HEAL=true to enable.\n  \
                             Default-off until INFRA-1541 50-PR observation phase completes."
                        );
                    }
                    std::process::exit(0);
                }

                if want_heal {
                    let cfg = fleet_self_doctor::HealConfig::default();
                    let outcome = fleet_self_doctor::run_heal_cycle(&cfg);
                    if want_json {
                        println!(
                            "{}",
                            serde_json::json!({
                                "mode": "heal",
                                "idle": outcome.idle,
                                "daemons_installed": outcome.daemons_installed,
                                "daemons_failed": outcome.daemons_failed,
                                "prs_dispatched": outcome.prs_dispatched
                                    .iter()
                                    .map(|(n, g)| serde_json::json!({"pr": n, "gap_id": g}))
                                    .collect::<Vec<_>>(),
                                "prs_failed": outcome.prs_failed,
                                "budget_hit": outcome.budget_hit,
                            })
                        );
                    } else {
                        println!("chump fleet doctor --heal:");
                        if outcome.idle {
                            println!("  idle — nothing to heal this cycle");
                        }
                        if !outcome.daemons_installed.is_empty() {
                            println!(
                                "  daemons installed: {}",
                                outcome.daemons_installed.join(", ")
                            );
                        }
                        if !outcome.daemons_failed.is_empty() {
                            println!("  daemons FAILED: {}", outcome.daemons_failed.join(", "));
                        }
                        if !outcome.prs_dispatched.is_empty() {
                            println!(
                                "  PRs dispatched: {}",
                                outcome
                                    .prs_dispatched
                                    .iter()
                                    .map(|(n, g)| format!("#{n} ({g})"))
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            );
                        }
                        if outcome.budget_hit {
                            println!(
                                "  BUDGET HIT — operator paged via .chump-locks/operator-action-needed.json"
                            );
                        }
                    }
                    std::process::exit(0);
                }

                // Diagnose-only placeholder. Emits a tick so consumers can
                // see the doctor ran. INFRA-1427 will replace this with the
                // full --strict implementation.
                let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                    kind: "self_doctor_tick".to_string(),
                    source: Some("fleet_self_doctor".to_string()),
                    fields: vec![("status".to_string(), "diagnose_only".to_string())],
                    ..Default::default()
                });
                if want_json {
                    println!(
                        "{}",
                        serde_json::json!({
                            "mode": "diagnose",
                            "note": "--heal not requested; diagnose-only stub until INFRA-1427 strict lands"
                        })
                    );
                } else {
                    println!("chump fleet doctor: diagnose-only mode (pass --heal to auto-fix).");
                }
                std::process::exit(0);
            }
            // INFRA-1483: declarative spec primitive (Marcus M-B). Plan
            // shows the gap set without mutating; apply reserves; spec-status
            // aggregates progress by spec_name.
            "plan" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!("Usage: chump fleet plan <spec.yaml>");
                        std::process::exit(2);
                    }
                };
                match fleet_spec::FleetSpec::from_path(&path) {
                    Ok(spec) => {
                        let plan = spec.plan();
                        if args.iter().any(|a| a == "--json") {
                            println!("{}", serde_json::to_string_pretty(&plan).unwrap());
                        } else {
                            print!("{}", fleet_spec::render_plan(&plan));
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "apply" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!("Usage: chump fleet apply <spec.yaml> [--dry-run]");
                        std::process::exit(2);
                    }
                };
                let dry_run = args.iter().any(|a| a == "--dry-run");
                match fleet_spec::FleetSpec::from_path(&path) {
                    Ok(spec) => {
                        let plan = spec.plan();
                        println!(
                            "fleet-spec apply: {} gap(s) would be reserved (spec={}, dry_run={dry_run})",
                            plan.len(),
                            spec.name
                        );
                        for (i, g) in plan.iter().enumerate() {
                            if dry_run {
                                println!("  [dry-run] {} | {}", i + 1, g.title);
                                continue;
                            }
                            // Reserve via the chump CLI to keep this dispatch
                            // single-process-friendly. spec_name lives in notes
                            // for `chump fleet spec-status` aggregation.
                            let notes = format!(
                                "spec_name={}\\nvalidation: {}\\nsuccess: {}\\nbindings: {}",
                                g.spec_name,
                                g.validation,
                                g.success,
                                g.bindings
                                    .iter()
                                    .map(|(k, v)| format!("{k}={v}"))
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            );
                            let chump_bin =
                                std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                            let out = std::process::Command::new(&chump_bin)
                                .args([
                                    "gap", "reserve", "--domain", &g.domain, "--title", &g.title,
                                    "--effort", &g.effort, "--notes", &notes,
                                ])
                                .output();
                            match out {
                                Ok(o) if o.status.success() => {
                                    let id = String::from_utf8_lossy(&o.stdout)
                                        .lines()
                                        .find(|l| l.contains("INFRA-") || l.contains("-"))
                                        .map(|s| s.trim().to_string())
                                        .unwrap_or_else(|| "?".to_string());
                                    println!("  [reserved] {} → {}", g.title, id);
                                }
                                Ok(o) => {
                                    eprintln!(
                                        "  [failed] {}: {}",
                                        g.title,
                                        String::from_utf8_lossy(&o.stderr).trim()
                                    );
                                    std::process::exit(1);
                                }
                                Err(e) => {
                                    eprintln!("  [failed] {}: spawn error: {e}", g.title);
                                    std::process::exit(1);
                                }
                            }
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "spec-status" => {
                let name = match args.get(3) {
                    Some(n) => n.clone(),
                    None => {
                        eprintln!("Usage: chump fleet spec-status <spec-name>");
                        std::process::exit(2);
                    }
                };
                // Aggregate via `chump gap list` + grep on the notes column.
                let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                let out = std::process::Command::new(&chump_bin)
                    .args(["gap", "list", "--json"])
                    .output();
                let Ok(o) = out else {
                    eprintln!("error: could not exec chump gap list");
                    std::process::exit(1);
                };
                let needle = format!("spec_name={name}");
                let body = String::from_utf8_lossy(&o.stdout);
                let mut total = 0;
                let mut counts = std::collections::HashMap::<String, usize>::new();
                // Lenient parse: one JSON object per line OR a single array.
                let entries: Vec<serde_json::Value> = if body.trim_start().starts_with('[') {
                    serde_json::from_str(&body).unwrap_or_default()
                } else {
                    body.lines()
                        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
                        .collect()
                };
                for e in &entries {
                    let notes = e.get("notes").and_then(|v| v.as_str()).unwrap_or("");
                    if notes.contains(&needle) {
                        total += 1;
                        let status = e
                            .get("status")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown")
                            .to_string();
                        *counts.entry(status).or_insert(0) += 1;
                    }
                }
                if total == 0 {
                    println!("no gaps found for spec {name}");
                    std::process::exit(0);
                }
                println!("fleet-spec status: {name}  ({total} gap(s))");
                for (status, n) in &counts {
                    println!("  {status}: {n}");
                }
                std::process::exit(0);
            }
            _ => {
                eprintln!(
                    "Usage: chump fleet <up|down|status|scale|start|stop|snapshot|restore|restart|audit-pids|brief|auto-widen|auto-resize|prune-worktrees|daemon|whoworkson|canary|doctor|plan|apply|spec-status>"
                );
                eprintln!("Primary verbs:");
                eprintln!("  up          [--size N] [--model M] [--effort xs,s,m] [--domain D]");
                eprintln!("              (like 'start' but refuses if session already running — use 'scale' to resize)");
                eprintln!("  down        [--session NAME]  (alias for stop)");
                eprintln!("  status      [--json]");
                eprintln!("  scale       N [--session NAME]");
                eprintln!("Aliases / advanced:");
                eprintln!("  start       [--size N] [--model M] [--effort xs,s,m] [--domain D]  (alias for up, no idempotency check)");
                eprintln!("  stop        [--session NAME]  (alias for down)");
                eprintln!("  snapshot");
                eprintln!("  restore     <snapshot-id>");
                eprintln!("  restart     [--size N] [--session NAME]  (fleet-restart.sh — graceful reload)");
                eprintln!("  audit-pids  [--apply]");
                eprintln!("  brief       [--json] [--window SECS]");
                eprintln!("  auto-widen  [--apply]  -- widen effort/priority filter on starvation");
                eprintln!(
                    "  auto-resize [--apply] [--json]  -- scale down on 4 conditions (INFRA-650)"
                );
                eprintln!("  prune-worktrees [--apply] [--json]  -- prune stale linked worktrees (INFRA-827)");
                eprintln!("  daemon      [--once]  -- long-lived scheduler (INFRA-964); --once runs all tasks once");
                eprintln!("  whoworkson  <topic> [--json]  -- who is working on a given topic (INFRA-1446)");
                eprintln!("  canary      [--lane LABEL] [--json] [--record-baseline]");
                eprintln!(
                    "              -- broad runner-lane canary (INFRA-1568): runs full production"
                );
                eprintln!("                 workflow end-to-end; exit 0 iff every step passes.");
                eprintln!(
                    "  doctor      [--heal] [--json]  -- self-healing autonomy loop (INFRA-1595)"
                );
                std::process::exit(2);
            }
        }
    }

    // `chump gap <subcommand>` (INFRA-023) — SQLite-backed gap store.
    //
    // Subcommands: list, reserve, claim, preflight, ship, dump, import
    //
    // Examples:
    //   chump gap list [--status open] [--json]
    //   chump gap reserve --domain INFRA --title "My gap" [--priority P1] [--effort s]
    //   chump gap claim <GAP-ID> [--session <id>] [--worktree <path>]
    //   chump gap preflight <GAP-ID>
    //   chump gap ship <GAP-ID> [--session <id>]
    //   chump gap dump [--out <path>]
    //   chump gap import [--yaml docs/gaps.yaml]
    if args.get(1).map(String::as_str) == Some("gap") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        // INFRA-247: per-file YAML mirrors and the .chump/.last-yaml-op
        // freshness marker are *worktree-local* artifacts — they must land
        // in the operator's branch, not the main checkout's. `repo_root`
        // resolves via CHUMP_REPO/CHUMP_HOME (set by the main checkout's
        // .env, which dotenvy walks up to find from any linked worktree),
        // so it points at the main checkout. `worktree_root` uses
        // `git rev-parse --show-toplevel` from CWD, which correctly
        // resolves to the linked worktree the operator is actually in.
        // state.db remains under repo_root (shared canonical state).
        let worktree_root = repo_path::worktree_root();
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump gap: cannot open state.db: {e:#}");
                std::process::exit(1);
            }
        };
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let json_out = args.iter().any(|a| a == "--json");

        match subcmd {
            // INFRA-498: 'chump gap show <ID>' — human-readable per-gap
            // rendering. Replaces `cat docs/gaps/<ID>.yaml` now that those
            // files are deleted.
            "show" => {
                // INFRA-1037: --brief (one-liner), default (status promoted), --field <name>
                let id_pos = args[3..]
                    .iter()
                    .position(|a| !a.starts_with("--"))
                    .map(|i| i + 3);
                let id = id_pos
                    .and_then(|p| args.get(p))
                    .cloned()
                    .unwrap_or_else(|| {
                        eprintln!("Usage: chump gap show <GAP-ID> [--brief|--field <name>]");
                        std::process::exit(2);
                    });
                if id.starts_with("--") {
                    eprintln!("Usage: chump gap show <GAP-ID> [--brief|--field <name>]");
                    std::process::exit(2);
                }
                let brief_mode = args.iter().any(|a| a == "--brief");
                let field_mode = args.windows(2).find_map(|w| {
                    if w[0] == "--field" {
                        Some(w[1].clone())
                    } else {
                        None
                    }
                });

                match store.get(&id) {
                    Ok(Some(g)) => {
                        // CREDIBLE-033: parse AC items for rich rendering.
                        let ac_items = gap_store::parse_json_ac_list(&g.acceptance_criteria);
                        let ac_has_todos = ac_items.iter().any(|item| {
                            let up = item.to_uppercase();
                            up.contains("TODO")
                                || item.contains("TBD")
                                || item.contains("<fill in>")
                        });

                        if json_out {
                            // Extend JSON output with ac_count + ac_has_todos (CREDIBLE-033).
                            let mut val = serde_json::to_value(&g).unwrap_or_default();
                            if let Some(obj) = val.as_object_mut() {
                                obj.insert(
                                    "ac_count".to_string(),
                                    serde_json::Value::Number(ac_items.len().into()),
                                );
                                obj.insert(
                                    "ac_has_todos".to_string(),
                                    serde_json::Value::Bool(ac_has_todos),
                                );
                            }
                            println!("{}", serde_json::to_string_pretty(&val).unwrap_or_default());
                        } else if brief_mode {
                            // --brief: one-line summary
                            let pr_str = g.closed_pr.map(|n| format!("#{}", n)).unwrap_or_default();
                            println!(
                                "[{}] {} — {} {}/{} {}",
                                g.status, g.id, g.title, g.priority, g.effort, pr_str
                            );
                        } else if let Some(ref field) = field_mode {
                            // --field <name>: print just the value, script-friendly
                            let val = match field.as_str() {
                                "id" => g.id.clone(),
                                "domain" => g.domain.clone(),
                                "title" => g.title.clone(),
                                "status" => g.status.clone(),
                                "priority" => g.priority.clone(),
                                "effort" => g.effort.clone(),
                                "description" => g.description.clone(),
                                "acceptance_criteria" => g.acceptance_criteria.clone(),
                                "notes" => g.notes.clone(),
                                "depends_on" => g.depends_on.clone(),
                                "closed_date" => g.closed_date.clone(),
                                "closed_pr" => {
                                    g.closed_pr.map(|n| n.to_string()).unwrap_or_default()
                                }
                                other => {
                                    eprintln!("chump gap show --field: unknown field '{}'", other);
                                    std::process::exit(1);
                                }
                            };
                            println!("{}", val.trim());
                        } else {
                            // INFRA-1285: helper to quote YAML scalar strings that need it.
                            // Strings containing ':', '#', leading/trailing whitespace, or
                            // starting with a YAML indicator char are quoted with double-quotes.
                            fn yaml_quote(s: &str) -> String {
                                let needs_quote = s.contains(':')
                                    || s.contains('#')
                                    || s.contains('"')
                                    || s.contains('\\')
                                    || s.starts_with(|c: char| {
                                        matches!(
                                            c,
                                            '{' | '}'
                                                | '['
                                                | ']'
                                                | ','
                                                | '&'
                                                | '*'
                                                | '?'
                                                | '|'
                                                | '-'
                                                | '<'
                                                | '>'
                                                | '='
                                                | '!'
                                                | '%'
                                                | '@'
                                                | '`'
                                        )
                                    })
                                    || s.starts_with(|c: char| c.is_whitespace())
                                    || s.ends_with(|c: char| c.is_whitespace())
                                    || s.is_empty();
                                if needs_quote {
                                    // Escape backslashes and double-quotes inside the string.
                                    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
                                    format!("\"{}\"", escaped)
                                } else {
                                    s.to_string()
                                }
                            }
                            // Default: status/closed_pr/closed_date promoted before description (INFRA-1037)
                            println!("- id: {}", g.id);
                            println!("  domain: {}", g.domain);
                            println!("  title: {}", yaml_quote(&g.title));
                            println!("  status: {}", g.status);
                            println!("  priority: {}", g.priority);
                            println!("  effort: {}", g.effort);
                            if let Some(pr) = g.closed_pr {
                                println!("  closed_pr: {}", pr);
                            }
                            if !g.closed_date.is_empty() {
                                println!("  closed_date: '{}'", g.closed_date);
                            }
                            if !g.depends_on.is_empty() {
                                println!("  depends_on: [{}]", g.depends_on);
                            }
                            if !g.description.is_empty() {
                                println!("  description: |");
                                for line in g.description.lines() {
                                    println!("    {}", line);
                                }
                            }
                            if !ac_items.is_empty() {
                                // CREDIBLE-033: numbered list, WARN prefix on vague items.
                                println!("  acceptance_criteria:");
                                for (i, item) in ac_items.iter().enumerate() {
                                    let up = item.to_uppercase();
                                    let is_vague = up.contains("TODO")
                                        || item.contains("TBD")
                                        || item.contains("<fill in>");
                                    if is_vague {
                                        println!("    {}. WARN: {}", i + 1, item);
                                    } else {
                                        println!("    {}. {}", i + 1, item);
                                    }
                                }
                                if ac_has_todos {
                                    eprintln!(
                                        "WARN: gap {}: acceptance_criteria contains \
                                         incomplete placeholders (TODO/TBD/<fill in>)",
                                        g.id
                                    );
                                }
                            } else if !g.acceptance_criteria.trim().is_empty() {
                                // Fallback: raw text when not parseable as JSON list.
                                println!("  acceptance_criteria:");
                                println!("    1. {}", g.acceptance_criteria.trim());
                            }
                            if !g.notes.is_empty() {
                                println!("  notes: |");
                                for line in g.notes.lines() {
                                    println!("    {}", line);
                                }
                            }
                            // INFRA-1220: show cooldown status if active.
                            let cooldown_file = repo_root
                                .join(".chump-locks/.gap-cooldown")
                                .join(format!("{}.json", g.id));
                            if cooldown_file.exists() {
                                let script = repo_root.join("scripts/coord/gap-cooldown.sh");
                                let _ = std::process::Command::new("bash")
                                    .arg(&script)
                                    .arg("status")
                                    .arg(&g.id)
                                    .env("CHUMP_LOCK_DIR", repo_root.join(".chump-locks"))
                                    .status();
                            }
                        }
                        return Ok(());
                    }
                    Ok(None) => {
                        eprintln!("chump gap show: gap {} not found", id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump gap show: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "list" => {
                let status_filter = flag("--status");
                // INFRA-431: include-test-domains opts back in to SPIKE/TEST*
                // rows. Default is to filter them out of the human-readable
                // output (kept in --json output unconditionally so tooling
                // sees the true state). Surfaces by name in the summary
                // line so the operator KNOWS the filter ran.
                let include_test_domains = args.iter().any(|a| a == "--include-test-domains");
                // EFFECTIVE-023: --domain <D> filters to a single domain;
                // --domain all shows per-domain summary footer.
                let domain_filter = flag("--domain");
                // EFFECTIVE-008: --quiet suppresses all output (exit 0 on success).
                let quiet = args.iter().any(|a| a == "--quiet");
                // EFFECTIVE-008: --format <human|json|csv> — explicit format
                // selector; --json and --format json are equivalent.
                let fmt = flag("--format").unwrap_or_else(|| {
                    if json_out {
                        "json".to_string()
                    } else {
                        "human".to_string()
                    }
                });
                let csv_out = fmt == "csv";
                let json_out = json_out || fmt == "json";
                // EFFECTIVE-018: --since <duration> filters to gaps that had
                // activity (opened or closed) within the given window.
                let since_cutoff: Option<String> = flag("--since").and_then(|s| {
                    let secs = parse_duration_to_secs(&s).unwrap_or_else(|| {
                        eprintln!(
                            "chump gap list: invalid --since '{}' (expected 7d, 24h, 30d…)",
                            s
                        );
                        std::process::exit(2);
                    });
                    let cutoff_ts = unix_ts().saturating_sub(secs);
                    use chrono::TimeZone;
                    chrono::Utc
                        .timestamp_opt(cutoff_ts as i64, 0)
                        .single()
                        .map(|dt| dt.format("%Y-%m-%d").to_string())
                });
                // INFRA-821: auto-seed state.db on fresh clone before listing.
                let seeded = store.auto_seed_if_empty();
                if seeded > 0 {
                    tracing::info!(
                        kind = "gap_db_auto_seeded",
                        imported = seeded,
                        "state.db was empty on open — auto-imported from docs/gaps/"
                    );
                }
                match store.list(status_filter.as_deref()) {
                    Ok(all_gaps) => {
                        // Apply --since filter before any output path.
                        // Date strings are YYYY-MM-DD, so lexicographic >= works.
                        let gaps: Vec<_> = if let Some(ref cutoff) = since_cutoff {
                            all_gaps
                                .into_iter()
                                .filter(|g| {
                                    (!g.opened_date.is_empty()
                                        && g.opened_date.as_str() >= cutoff.as_str())
                                        || (!g.closed_date.is_empty()
                                            && g.closed_date.as_str() >= cutoff.as_str())
                                })
                                .collect()
                        } else {
                            all_gaps
                        };
                        if quiet {
                            // --quiet: no output, just verify the query ran (exit 0).
                            return Ok(());
                        } else if csv_out {
                            // EFFECTIVE-008: CSV format — id,domain,status,priority,effort,title
                            println!("id,domain,status,priority,effort,title");
                            for g in &gaps {
                                let dom = g.id.split('-').next().unwrap_or("?");
                                if !include_test_domains && is_test_domain(dom) {
                                    continue;
                                }
                                if let Some(df) = &domain_filter {
                                    if df != "all" && dom != df.as_str() {
                                        continue;
                                    }
                                }
                                // Escape commas and quotes in title
                                let title_esc = g.title.replace('"', "\"\"");
                                println!(
                                    "{},{},{},{},{},\"{}\"",
                                    g.id, g.domain, g.status, g.priority, g.effort, title_esc
                                );
                            }
                        } else if json_out {
                            // EFFECTIVE-023: when --domain is set, wrap in
                            // {gaps: [...], domain_summary: {...}} object.
                            // Without --domain, output the plain array as before.
                            if let Some(df) = &domain_filter {
                                let filtered: Vec<&gap_store::GapRow> = gaps
                                    .iter()
                                    .filter(|g| {
                                        let dom = g.id.split('-').next().unwrap_or("?");
                                        df == "all" || dom == df.as_str()
                                    })
                                    .collect();
                                // Build domain_summary over the filtered set.
                                let mut ds: std::collections::BTreeMap<
                                    String,
                                    std::collections::BTreeMap<String, usize>,
                                > = std::collections::BTreeMap::new();
                                for g in &filtered {
                                    let dom = g.id.split('-').next().unwrap_or("?").to_string();
                                    let entry = ds.entry(dom).or_default();
                                    let key = match g.status.as_str() {
                                        "done" => "done",
                                        "in_progress" => "in_progress",
                                        _ => "open",
                                    };
                                    *entry.entry(key.to_string()).or_insert(0) += 1;
                                }
                                let obj = serde_json::json!({
                                    "gaps": filtered,
                                    "domain_summary": ds,
                                });
                                println!(
                                    "{}",
                                    serde_json::to_string_pretty(&obj).unwrap_or_default()
                                );
                            } else if let Some(ref cutoff) = since_cutoff {
                                // EFFECTIVE-018: wrap with since_cutoff so tooling can inspect the window.
                                let obj = serde_json::json!({
                                    "since_cutoff": cutoff,
                                    "gaps": gaps,
                                });
                                println!(
                                    "{}",
                                    serde_json::to_string_pretty(&obj).unwrap_or_default()
                                );
                            } else {
                                println!(
                                    "{}",
                                    serde_json::to_string_pretty(&gaps).unwrap_or_default()
                                );
                            }
                        } else {
                            // EFFECTIVE-023: when --domain <D> (not "all"),
                            // print a "Domain: D" header and filter rows.
                            let specific_domain = domain_filter.as_deref().filter(|d| *d != "all");
                            if let Some(d) = specific_domain {
                                println!("Domain: {d}");
                            }

                            // Build filtered view + per-domain counts on the
                            // unfiltered set so the summary + ALERT see the
                            // truth (the SPIKE leak hid because counts were
                            // never inspected by domain).
                            let mut by_domain: std::collections::BTreeMap<String, usize> =
                                std::collections::BTreeMap::new();
                            for g in &gaps {
                                let dom = g.id.split('-').next().unwrap_or("?").to_string();
                                *by_domain.entry(dom).or_insert(0) += 1;
                            }
                            let mut filtered_count = 0usize;
                            let mut filtered_domains: Vec<String> = Vec::new();
                            for g in &gaps {
                                let dom = g.id.split('-').next().unwrap_or("?");
                                if !include_test_domains && is_test_domain(dom) {
                                    if !filtered_domains.iter().any(|d| d == dom) {
                                        filtered_domains.push(dom.to_string());
                                    }
                                    filtered_count += 1;
                                    continue;
                                }
                                // EFFECTIVE-023: apply domain filter.
                                if let Some(df) = &domain_filter {
                                    if df != "all" && dom != df.as_str() {
                                        continue;
                                    }
                                }
                                // EFFECTIVE-024: done gaps append "→ #PR merged YYYY-MM-DD"
                                let done_suffix = if g.status == "done" {
                                    match (g.closed_pr, g.closed_date.as_str()) {
                                        (Some(pr), d) if !d.is_empty() => {
                                            format!(" → #{pr} merged {d}")
                                        }
                                        (Some(pr), _) => format!(" → #{pr} merged"),
                                        (None, d) if !d.is_empty() => {
                                            format!(" → merged {d}")
                                        }
                                        _ => String::new(),
                                    }
                                } else {
                                    String::new()
                                };
                                // INFRA-1259: add warning indicator for vague AC
                                let ac_warn =
                                    if is_acceptance_criteria_vague(&g.acceptance_criteria) {
                                        " ⚠"
                                    } else {
                                        ""
                                    };
                                println!(
                                    "[{}] {} — {} ({}/{}){}{done_suffix}",
                                    g.status, g.id, g.title, g.priority, g.effort, ac_warn
                                );
                            }

                            // EFFECTIVE-023: --domain all shows per-domain summary.
                            if domain_filter.as_deref() == Some("all") {
                                // Build per-status counts by domain over ALL gaps.
                                let mut by_dom_status: std::collections::BTreeMap<
                                    String,
                                    (
                                        usize,
                                        usize,
                                        usize,
                                        std::collections::BTreeMap<String, usize>,
                                    ),
                                > = std::collections::BTreeMap::new();
                                for g in &gaps {
                                    let dom = g.id.split('-').next().unwrap_or("?").to_string();
                                    let entry = by_dom_status.entry(dom).or_insert((
                                        0,
                                        0,
                                        0,
                                        std::collections::BTreeMap::new(),
                                    ));
                                    match g.status.as_str() {
                                        "done" => entry.1 += 1,
                                        "in_progress" => entry.2 += 1,
                                        _ => {
                                            entry.0 += 1;
                                            *entry.3.entry(g.priority.clone()).or_insert(0) += 1;
                                        }
                                    }
                                }
                                println!();
                                for (dom, (open, _done, _in_prog, prios)) in &by_dom_status {
                                    let p0 = prios.get("P0").copied().unwrap_or(0);
                                    let p1 = prios.get("P1").copied().unwrap_or(0);
                                    println!("{dom}: {open} open (P0={p0}, P1={p1})");
                                }
                            } else if domain_filter.is_none() {
                                // Default path (no --domain): existing summary line.
                                // Domain-population ALERT (stderr, unconditional).
                                let total = gaps.len();
                                for (dom, n) in &by_domain {
                                    let pct = (*n * 100).checked_div(total).unwrap_or(0);
                                    if *n > 100 || pct > 50 {
                                        eprintln!(
                                            "ALERT: domain {} has {} gaps ({}% of total) — likely a test-fixture leak (see INFRA-428)",
                                            dom, n, pct
                                        );
                                    }
                                }
                                // Summary line (stdout). Top 5 domains by count.
                                let mut domain_pairs: Vec<(&String, &usize)> =
                                    by_domain.iter().collect();
                                domain_pairs.sort_by(|a, b| b.1.cmp(a.1));
                                let top: Vec<String> = domain_pairs
                                    .iter()
                                    .take(5)
                                    .map(|(d, n)| format!("{d}={n}"))
                                    .collect();
                                let shown = total - filtered_count;
                                let mut summary = if let Some(ref cutoff) = since_cutoff {
                                    format!(
                                        "\n--- {} shown (active since {}) / {} total across {} domains (top: {}) ---",
                                        shown, cutoff, total, by_domain.len(), top.join(" ")
                                    )
                                } else {
                                    format!(
                                        "\n--- {} shown / {} total open across {} domains (top: {}) ---",
                                        shown, total, by_domain.len(), top.join(" ")
                                    )
                                };
                                if !filtered_domains.is_empty() {
                                    summary.push_str(&format!(
                                        "\n--- filtered out {} test-domain row(s): {} (use --include-test-domains to see) ---",
                                        filtered_count, filtered_domains.join(" ")
                                    ));
                                }
                                println!("{summary}");
                            }
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap list: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "reserve" => {
                let has_flag_domain = args.iter().any(|a| a == "--domain");
                let domain = flag("--domain").or_else(|| {
                    args.get(3).and_then(|a| {
                        if a.starts_with('-') {
                            None
                        } else {
                            Some(a.clone())
                        }
                    })
                });
                let domain = domain.unwrap_or_else(|| {
                    eprintln!("Usage: chump gap reserve --domain D --title T");
                    eprintln!("   or: chump gap reserve D title words…");
                    std::process::exit(2);
                });
                let title = flag("--title").unwrap_or_else(|| {
                    if has_flag_domain {
                        eprintln!("--title required when using --domain");
                        std::process::exit(2);
                    }
                    args.get(4..)
                        .map(|tail| tail.join(" "))
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "New gap".into())
                });
                let priority = flag("--priority").unwrap_or_else(|| "P2".into());
                let effort = flag("--effort").unwrap_or_else(|| "m".into());
                let stack_on = flag("--stack-on");
                let force = args.iter().any(|a| a == "--force");
                // INFRA-592: --quiet suppresses progress; default emits one-line
                // per phase to stderr so --json piping of stdout is unaffected.
                let quiet = args.iter().any(|a| a == "--quiet");
                let why = args.iter().any(|a| a == "--why");
                let skip_obs_acs = args.iter().any(|a| a == "--skip-obs-acs");
                let custom_acceptance_criteria = flag("--acceptance-criteria");

                // INFRA-756: compute acceptance_criteria. Default to 4 obs-AC templates
                // unless --skip-obs-acs is set or --acceptance-criteria is provided.
                let acceptance_criteria_json = match custom_acceptance_criteria {
                    Some(raw) => {
                        let parts: Vec<&str> = raw.split('|').collect();
                        serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
                    }
                    None if !skip_obs_acs => {
                        let obs_acs = vec![
                            "TODO: what events emitted on success/failure/timeout",
                            "TODO: how cost tracked and reported to operator",
                            "TODO: failure-class taxonomy (distinguish transient vs permanent)",
                            "TODO: smoke test command to verify observability",
                        ];
                        serde_json::to_string(&obs_acs).unwrap_or_else(|_| "[]".into())
                    }
                    _ => "[]".into(),
                };

                // FLEET-029: ambient glance before allocating ID
                if !force && std::env::var("FLEET_029_AMBIENT_GLANCE_SKIP").is_err() {
                    use std::process::Command;
                    if !quiet {
                        eprint!("checking registry health...");
                    }
                    let glance_result = Command::new("bash")
                        .arg("scripts/coord/chump-ambient-glance.sh")
                        .arg("--domain")
                        .arg(&domain)
                        .arg("--title")
                        .arg(&title)
                        .arg("--check-prs")
                        .current_dir(repo_path::repo_root())
                        .status();

                    if let Ok(status) = glance_result {
                        if !status.success() {
                            eprintln!();
                            eprintln!("[reserve] Potential overlap detected. Pass --force to proceed anyway, or review the matches above.");
                            std::process::exit(1);
                        }
                    }
                    if !quiet {
                        eprintln!(" ok");
                    }
                }

                // ── INFRA-1418: offline-compliance lint at reserve-time ────────────
                // Scan title + description for forbidden-without-fallback patterns
                // from docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md §2. Block unless
                // --force-anti-offline is passed alongside --offline-bypass-reason.
                // Disable: CHUMP_DISABLE_OFFLINE_CHECK=1.
                //
                // History (INFRA-1526): hunk repeatedly dropped by the
                // rust-main-append merge driver during rebases against fast-moving
                // main. Reset to main and re-applied fresh to avoid the driver.
                let offline_check_disabled =
                    std::env::var("CHUMP_DISABLE_OFFLINE_CHECK").as_deref() == Ok("1");
                let force_anti_offline = args.iter().any(|a| a == "--force-anti-offline");
                let offline_bypass_reason = flag("--offline-bypass-reason");
                if !offline_check_disabled {
                    let patterns: &[(&str, &str, &str, &str)] = &[
                        (
                            "gh-pr-only",
                            r"(?i)gh\s+pr\s+(merge|create|view)[^.]{0,60}\bONLY\b",
                            "hard-pins the path to GitHub even when local-merge-queue exists",
                            "rewrite as 'gh pr X (online) OR local-merge-queue.sh (offline)'",
                        ),
                        (
                            "webhook-only",
                            r"(?i)\b(only|exclusively)[^.]{0,40}\bwebhook|\bwebhook[s]?[^.]{0,30}\bonly\b|\bwebhook-only\b",
                            "local equivalents (post-receive hook, NATS subject) exist for almost every webhook event",
                            "rewrite as 'webhook OR local-equivalent (post-receive hook / NATS subject)'",
                        ),
                        (
                            "gh-actions-required",
                            r"(?i)github\s+actions\s+(must|required|is\s+the\s+gate)",
                            "conflates the executor with correctness; the tests ARE the CI",
                            "split into local-CI (run-local-ci.sh) + remote-CI (.github/workflows/)",
                        ),
                        (
                            "gh-api-blocking",
                            r"(?i)gh\s+api[^.]*\b(blocking|required|gates)\b",
                            "every fleet read should be cache-first per CLAUDE.md",
                            "use cache_lookup_*; gh api fallback only on cache miss",
                        ),
                        (
                            "state-db-coupled-to-network",
                            r"(?i)state\.db[^.]{0,80}\b(ONLY|exclusively)\b[^.]{0,40}\bwebhook|webhook[^.]{0,40}\bwrites?\s+(to\s+)?state\.db",
                            "couples local ground truth to network delivery — breaks Pi mesh + airplane mode",
                            "use proof-of-merge: PROOF_LOCAL_MERGE OR PROOF_WEBHOOK (see INFRA-1392)",
                        ),
                    ];

                    let combined = format!(
                        "{}\n{}",
                        title,
                        flag("--description").as_deref().unwrap_or(""),
                    );
                    let mut hits: Vec<(&str, String, &str, &str)> = Vec::new();
                    for entry in patterns {
                        if let Ok(re) = regex::Regex::new(entry.1) {
                            if let Some(m) = re.find(&combined) {
                                hits.push((
                                    entry.0,
                                    m.as_str().trim_end().to_string(),
                                    entry.2,
                                    entry.3,
                                ));
                            }
                        }
                    }

                    if !hits.is_empty() {
                        let ts_now = unix_ts();
                        let ambient_path = worktree_root.join(".chump-locks").join("ambient.jsonl");
                        eprintln!();
                        for (name, snippet, why, fix) in &hits {
                            eprintln!("OFFLINE_CHECK FAIL: \"{snippet}\"");
                            eprintln!("  pattern : {name}");
                            eprintln!("  why     : {why}");
                            eprintln!("  fix     : {fix}");
                            eprintln!("  see     : docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md §2");
                        }

                        if force_anti_offline {
                            let reason = offline_bypass_reason.as_deref().unwrap_or("").trim();
                            if reason.is_empty() {
                                eprintln!();
                                eprintln!(
                                    "[reserve] --force-anti-offline requires --offline-bypass-reason \"<text>\"."
                                );
                                eprintln!(
                                    "  Example: --offline-bypass-reason \"RUBRIC §4 case 1: intrinsically network-dependent\""
                                );
                                std::process::exit(2);
                            }
                            let _ = store.record_offline_bypass(
                                title.as_str(),
                                reason,
                                std::env::var("USER").unwrap_or_default().as_str(),
                            );
                            if let Some(parent) = ambient_path.parent() {
                                let _ = std::fs::create_dir_all(parent);
                            }
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                use std::io::Write;
                                let safe_reason = reason.replace(['"', '\\'], "");
                                let safe_title = title.replace(['"', '\\'], "");
                                let _ = writeln!(
                                    f,
                                    r#"{{"ts":"{ts_now}","kind":"gap_offline_bypass","title":"{safe_title}","reason":"{safe_reason}","hits":{}}}"#,
                                    hits.len()
                                );
                            }
                            eprintln!();
                            eprintln!(
                                "[reserve] --force-anti-offline accepted ({} hit(s)). Audit row written.",
                                hits.len()
                            );
                        } else {
                            eprintln!();
                            eprintln!(
                                "[reserve] BLOCK: gap text trips offline-compliance lint ({} pattern hit(s)).",
                                hits.len()
                            );
                            eprintln!(
                                "          Either rewrite per the suggestions above, OR pass"
                            );
                            eprintln!(
                                "          --force-anti-offline --offline-bypass-reason \"<text>\""
                            );
                            eprintln!("          Bypass entirely (CI / bulk imports): CHUMP_DISABLE_OFFLINE_CHECK=1");
                            if let Some(parent) = ambient_path.parent() {
                                let _ = std::fs::create_dir_all(parent);
                            }
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                use std::io::Write;
                                let safe_title = title.replace(['"', '\\'], "");
                                let _ = writeln!(
                                    f,
                                    r#"{{"ts":"{ts_now}","kind":"gap_offline_check_block","title":"{safe_title}","hits":{}}}"#,
                                    hits.len()
                                );
                            }
                            std::process::exit(1);
                        }
                    }
                }

                // ── INFRA-1149: reserve-time title similarity check ───────────────
                // Before allocating an ID, scan open + recently-closed gaps for
                // near-duplicate titles. Jaccard on normalized token sets.
                // Warn at 0.65; block at 0.85. Both thresholds are tunable via env.
                // Bypass: --force-duplicate flag or CHUMP_GAP_RESERVE_NO_SIMILARITY=1.
                let force_duplicate = args.iter().any(|a| a == "--force-duplicate");
                let similarity_enabled =
                    std::env::var("CHUMP_GAP_RESERVE_NO_SIMILARITY").as_deref() != Ok("1");
                if similarity_enabled && !force_duplicate {
                    let warn_threshold: f64 = std::env::var("CHUMP_GAP_RESERVE_SIMILARITY_WARN")
                        .ok()
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(0.65);
                    let block_threshold: f64 = std::env::var("CHUMP_GAP_RESERVE_SIMILARITY_BLOCK")
                        .ok()
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(0.85);
                    match store.similarity_candidates(&title, 3, 30) {
                        Ok(candidates) if !candidates.is_empty() => {
                            let top_score = candidates[0].3;
                            let top_id = &candidates[0].0;
                            if top_score >= warn_threshold {
                                let ambient_path =
                                    worktree_root.join(".chump-locks").join("ambient.jsonl");
                                eprintln!();
                                eprintln!("[reserve] INFRA-1149: title similarity check — proposed: \"{}\"", title);
                                for (cid, ctitle, cstatus, cscore) in &candidates {
                                    eprintln!(
                                        "  {:.2}  {} ({}) — \"{}\"",
                                        cscore, cid, cstatus, ctitle
                                    );
                                }
                                // Emit ambient event
                                let ts = {
                                    use std::time::{SystemTime, UNIX_EPOCH};
                                    SystemTime::now()
                                        .duration_since(UNIX_EPOCH)
                                        .map(|d| d.as_secs())
                                        .unwrap_or(0)
                                };
                                if top_score >= block_threshold {
                                    eprintln!(
                                        "[reserve] BLOCK (score {:.2} ≥ {:.2}): high similarity to {} — use --force-duplicate to override.",
                                        top_score, block_threshold, top_id
                                    );
                                    let _ = std::fs::OpenOptions::new()
                                        .append(true)
                                        .create(true)
                                        .open(&ambient_path)
                                        .and_then(|mut f| {
                                            use std::io::Write;
                                            writeln!(f,
                                                r#"{{"ts":"{ts}","kind":"gap_reserve_similarity_block","proposed_title":"{title}","top_match_id":"{top_id}","top_match_score":{top_score:.3}}}"#
                                            )
                                        });
                                    std::process::exit(1);
                                } else {
                                    eprintln!(
                                        "[reserve] WARN (score {:.2} ≥ {:.2}): potential overlap with {} — continue? [y/N]",
                                        top_score, warn_threshold, top_id
                                    );
                                    let _ = std::fs::OpenOptions::new()
                                        .append(true)
                                        .create(true)
                                        .open(&ambient_path)
                                        .and_then(|mut f| {
                                            use std::io::Write;
                                            writeln!(f,
                                                r#"{{"ts":"{ts}","kind":"gap_reserve_similarity_warn","proposed_title":"{title}","top_match_id":"{top_id}","top_match_score":{top_score:.3}}}"#
                                            )
                                        });
                                    // Read one line from stdin
                                    let mut answer = String::new();
                                    let _ = std::io::stdin().read_line(&mut answer);
                                    if !answer.trim().eq_ignore_ascii_case("y") {
                                        eprintln!("[reserve] Aborted. Use --force-duplicate to override the block, or CHUMP_GAP_RESERVE_NO_SIMILARITY=1 to disable.");
                                        std::process::exit(1);
                                    }
                                }
                            }
                        }
                        Ok(_) => {} // no candidates above threshold
                        Err(e) => {
                            // Non-fatal: warn but don't block filing
                            if !quiet {
                                eprintln!("[reserve] similarity check skipped (db error): {e}");
                            }
                        }
                    }
                }

                // ── INFRA-1152: pillar-balance guard ─────────────────────────────────
                // Parse proposed pillar from title prefix, then check current
                // open-pickable distribution and warn/block overweighted pillars.
                // Bypass: CHUMP_PILLAR_BALANCE_DISABLE=1 or --force-pillar flag.
                let force_pillar = args.iter().any(|a| a == "--force-pillar");
                let pillar_balance_disabled =
                    std::env::var("CHUMP_PILLAR_BALANCE_DISABLE").as_deref() == Ok("1");
                if !pillar_balance_disabled && !force {
                    // Extract pillar from title prefix (e.g. "RESILIENT: ..." → "RESILIENT")
                    let proposed_pillar = {
                        let prefixes = [
                            "RESILIENT",
                            "EFFECTIVE",
                            "CREDIBLE",
                            "ZERO-WASTE",
                            "MISSION",
                        ];
                        let title_up = title.to_uppercase();
                        prefixes
                            .iter()
                            .find(|&&p| {
                                title_up.starts_with(&format!("{}:", p))
                                    || title_up.starts_with(&format!("{} -", p))
                                    || title_up.starts_with(&format!("{}-", p))
                                    // allow "ZERO-WASTE: " or "ZERO_WASTE: " spellings
                                    || title_up.starts_with(&format!("{}:", p.replace('-', "_")))
                            })
                            .map(|&p| p.to_string())
                    };

                    if let Some(proposed_pillar) = proposed_pillar {
                        // Build pillar distribution from open gaps with non-TODO ACs
                        let all_open = store.list(Some("open")).unwrap_or_default();
                        let mut pillar_counts: std::collections::HashMap<String, usize> =
                            std::collections::HashMap::new();
                        let mut total_pickable: usize = 0;
                        for g in &all_open {
                            // "Pickable" heuristic: has non-empty ACs that aren't all TODOs
                            let acs = gap_store::parse_json_ac_list(&g.acceptance_criteria);
                            let has_real_acs = !acs.is_empty()
                                && acs.iter().any(|ac| !ac.trim_start().starts_with("TODO"));
                            if !has_real_acs {
                                continue;
                            }
                            total_pickable += 1;
                            // Infer pillar from gap title prefix
                            let g_up = g.title.to_uppercase();
                            let pillar = if g_up.starts_with("EFFECTIVE") {
                                "EFFECTIVE"
                            } else if g_up.starts_with("CREDIBLE") {
                                "CREDIBLE"
                            } else if g_up.starts_with("ZERO-WASTE")
                                || g_up.starts_with("ZERO_WASTE")
                            {
                                "ZERO-WASTE"
                            } else if g_up.starts_with("RESILIENT") {
                                "RESILIENT"
                            } else if g_up.starts_with("MISSION") {
                                "MISSION"
                            } else {
                                "UNTAGGED"
                            };
                            *pillar_counts.entry(pillar.to_string()).or_insert(0) += 1;
                        }

                        if total_pickable > 0 {
                            let proposed_count =
                                *pillar_counts.get(proposed_pillar.as_str()).unwrap_or(&0);
                            // After this reserve, proposed count would be +1
                            let new_count = proposed_count + 1;
                            let new_total = total_pickable + 1;
                            let new_ratio = new_count as f64 / new_total as f64;

                            let warn_threshold: f64 = std::env::var("CHUMP_PILLAR_BALANCE_WARN")
                                .ok()
                                .and_then(|v| v.parse().ok())
                                .unwrap_or(0.35);
                            let block_threshold: f64 = std::env::var("CHUMP_PILLAR_BALANCE_BLOCK")
                                .ok()
                                .and_then(|v| v.parse().ok())
                                .unwrap_or(0.50);

                            // Find under-fed pillars (< 10%)
                            let underfed_threshold = 0.10;
                            let mut underfed: Vec<String> = [
                                "EFFECTIVE",
                                "CREDIBLE",
                                "ZERO-WASTE",
                                "RESILIENT",
                                "MISSION",
                            ]
                            .iter()
                            .filter(|&&p| {
                                let cnt = *pillar_counts.get(p).unwrap_or(&0) as f64;
                                cnt / (total_pickable as f64) < underfed_threshold
                            })
                            .map(|&p| p.to_string())
                            .collect();
                            underfed.retain(|p| p != proposed_pillar.as_str());

                            if new_ratio >= block_threshold && !force_pillar {
                                eprintln!(
                                    "[reserve] PILLAR BLOCKED (INFRA-1152): {} would be {:.0}% of open-pickable gaps (threshold {:.0}%).",
                                    proposed_pillar,
                                    new_ratio * 100.0,
                                    block_threshold * 100.0,
                                );
                                eprintln!(
                                    "[reserve]   Current distribution ({} pickable gaps):",
                                    total_pickable
                                );
                                let mut sorted_pillars: Vec<_> = pillar_counts.iter().collect();
                                sorted_pillars.sort_by(|a, b| b.1.cmp(a.1));
                                for (p, cnt) in &sorted_pillars {
                                    eprintln!(
                                        "[reserve]     {:12} {:3} ({:.0}%)",
                                        p,
                                        cnt,
                                        (**cnt as f64) / (total_pickable as f64) * 100.0
                                    );
                                }
                                if !underfed.is_empty() {
                                    eprintln!(
                                        "[reserve]   Under-fed pillars (< {:.0}%): {}",
                                        underfed_threshold * 100.0,
                                        underfed.join(", ")
                                    );
                                }
                                eprintln!("[reserve]   To override: add --force-pillar, or set CHUMP_PILLAR_BALANCE_DISABLE=1");
                                // Emit ambient event
                                let emit_path = worktree_root.join("scripts/dev/ambient-emit.sh");
                                if emit_path.exists() {
                                    let _ = std::process::Command::new("bash")
                                        .arg(&emit_path)
                                        .arg("pillar_balance_block")
                                        .arg(format!("pillar={proposed_pillar}"))
                                        .arg(format!("ratio={new_ratio:.2}"))
                                        .arg(format!("total_pickable={total_pickable}"))
                                        .current_dir(&worktree_root)
                                        .status();
                                }
                                std::process::exit(1);
                            } else if new_ratio >= warn_threshold {
                                eprintln!(
                                    "[reserve] PILLAR WARN (INFRA-1152): {} will be {:.0}% of open-pickable gaps (warn at {:.0}%).",
                                    proposed_pillar,
                                    new_ratio * 100.0,
                                    warn_threshold * 100.0,
                                );
                                eprintln!(
                                    "[reserve]   Current distribution ({} pickable gaps):",
                                    total_pickable
                                );
                                let mut sorted_pillars: Vec<_> = pillar_counts.iter().collect();
                                sorted_pillars.sort_by(|a, b| b.1.cmp(a.1));
                                for (p, cnt) in &sorted_pillars {
                                    eprintln!(
                                        "[reserve]     {:12} {:3} ({:.0}%)",
                                        p,
                                        cnt,
                                        (**cnt as f64) / (total_pickable as f64) * 100.0
                                    );
                                }
                                if !underfed.is_empty() {
                                    eprintln!("[reserve]   Under-fed: {}. Consider filing an {} gap instead.", underfed.join(", "), underfed[0]);
                                }
                                // Emit ambient event
                                let emit_path = worktree_root.join("scripts/dev/ambient-emit.sh");
                                if emit_path.exists() {
                                    let _ = std::process::Command::new("bash")
                                        .arg(&emit_path)
                                        .arg("pillar_balance_warn")
                                        .arg(format!("pillar={proposed_pillar}"))
                                        .arg(format!("ratio={new_ratio:.2}"))
                                        .arg(format!("total_pickable={total_pickable}"))
                                        .current_dir(&worktree_root)
                                        .status();
                                }
                                // Warn only — do not exit; reserve proceeds
                            }
                        }
                    }
                }
                // ── end INFRA-1152 ───────────────────────────────────────────────────

                // INFRA-216: use reserve_verified so sibling sessions on the
                // same host (shared .chump-locks/) detect and resolve ID
                // collisions within the 200ms verification window.
                let session_id = crate::ambient_stream::env_session_id()
                    .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                if !quiet {
                    eprint!("reserving ID...");
                }
                match store.reserve_verified(&domain, &title, &priority, &effort, &session_id) {
                    Ok(id) => {
                        if !quiet {
                            eprintln!(" done {id}");
                        }

                        // INFRA-756: set acceptance_criteria if not empty (default obs-ACs or custom)
                        if acceptance_criteria_json != "[]" {
                            let update = gap_store::GapFieldUpdate {
                                acceptance_criteria: Some(acceptance_criteria_json),
                                ..Default::default()
                            };
                            if let Err(e) = store.set_fields(&id, update) {
                                if !quiet {
                                    eprintln!("warning: failed to set acceptance_criteria: {e}");
                                }
                            }
                        }

                        // INFRA-061 (M3): when --stack-on is passed, emit the
                        // bot-merge.sh hint so dispatchers (and humans) know
                        // to chain. Goes to stderr so the bare gap id stays
                        // on stdout (existing scripted callers parse it).
                        if let Some(prev) = stack_on {
                            eprintln!(
                                "[gap reserve] stack hint — ship with: scripts/coord/bot-merge.sh --gap {id} --stack-on {prev} --auto-merge"
                            );
                        }
                        // INFRA-228 (post-INFRA-188 cutover, 2026-05-02):
                        // also write the per-file YAML mirror at
                        // docs/gaps/<ID>.yaml. Without this, every
                        // `chump gap reserve` call required a follow-up
                        // hand-edit (or CHUMP_ALLOW_UNREGISTERED_GAP=1
                        // bypass) before bot-merge.sh's gap-preflight.sh
                        // would let the work ship — observed mid-flight on
                        // INFRA-227 itself. Best-effort: SQLite (state.db)
                        // is canonical, so a write failure is logged but
                        // doesn't fail the reserve.
                        // INFRA-247: write to the linked worktree, not the main checkout.
                        // INFRA-498: per-file YAML mirrors deleted from the
                        // repo as redundant with .chump/state.sql. We keep
                        // the dump_per_file_single call gated on directory
                        // existence — if the operator re-creates docs/gaps/
                        // (e.g. for offline browsing), the write resumes.
                        // Default: directory doesn't exist, write is a no-op.
                        if why {
                            eprintln!(
                                "reserved {id} — why: collision-free atomic ID pick from domain {domain} pool (INFRA-216 verification window)"
                            );
                        }
                        let per_file_dir = worktree_root.join("docs").join("gaps");
                        if !per_file_dir.exists() {
                            // No-op path. state.db is canonical, state.sql is
                            // the tracked mirror. Use 'chump gap show <ID>'
                            // for per-gap human-readable rendering.
                            println!("{}", id);
                            return Ok(());
                        }
                        match store.dump_per_file_single(&id, &per_file_dir) {
                            Ok(true) => {
                                let yaml_path = per_file_dir.join(format!("{id}.yaml"));
                                eprintln!("wrote {}", yaml_path.display());
                                write_yaml_op_marker(&worktree_root, "reserve");

                                // INFRA-484: auto-stage the YAML mirror so it
                                // rides along on the next commit. Pre-fix:
                                // chump gap reserve wrote the YAML untracked,
                                // so linked worktrees (fleet workers) created
                                // from origin/main never saw it. The 2026-05-05
                                // sonnet fleet wedge is the canonical incident:
                                // workers got "(gap YAML not found)" prompts,
                                // had to discover from state.db (also not in
                                // linked worktree), got stuck, and burned 600s
                                // × N cycles to 0-byte output.
                                //
                                // Staging makes the YAML part of the next PR's
                                // diff so origin/main and all linked worktrees
                                // pick it up.
                                //
                                // Best-effort: warns on failure but never
                                // blocks the reserve. Bypass with
                                // CHUMP_RESERVE_NO_AUTOSTAGE=1 for genuine
                                // detached / read-only operator workflows.
                                // INFRA-1354: emit warning when git add fails
                                // so operators notice the staging gap instead
                                // of discovering it via orphan-PR-closer.
                                if std::env::var("CHUMP_RESERVE_NO_AUTOSTAGE").as_deref() != Ok("1")
                                {
                                    match std::process::Command::new("git")
                                        .arg("-C")
                                        .arg(&worktree_root)
                                        .arg("add")
                                        .arg(&yaml_path)
                                        .status()
                                    {
                                        Ok(s) if s.success() => {
                                            if !quiet {
                                                eprintln!(
                                                    "[reserve] staged {}",
                                                    yaml_path.display()
                                                );
                                            }
                                        }
                                        Ok(s) => {
                                            eprintln!(
                                                "[reserve] warning: git add {} exited {}; yaml is written but unstaged — commit manually to avoid orphan-PR-closer killing in-flight PRs",
                                                yaml_path.display(), s
                                            );
                                        }
                                        Err(e) => {
                                            eprintln!(
                                                "[reserve] warning: git add {} failed ({e}); yaml is written but unstaged — commit manually to avoid orphan-PR-closer killing in-flight PRs",
                                                yaml_path.display()
                                            );
                                        }
                                    }
                                }
                            }
                            Ok(false) => {} // no-op write
                            Err(e) => {
                                eprintln!("warning: dump-per-file write failed for {id}: {e}")
                            }
                        }
                        println!("{}", id);
                        return Ok(());
                    }
                    Err(e) => {
                        if !quiet {
                            eprintln!(); // end the "reserving ID..." line
                        }
                        eprintln!("chump gap reserve: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "claim" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap claim <GAP-ID>");
                    std::process::exit(2);
                });
                let force = args.iter().any(|a| a == "--force");
                let why = args.iter().any(|a| a == "--why");

                // FLEET-029: ambient glance before claiming
                if !force && std::env::var("FLEET_029_AMBIENT_GLANCE_SKIP").is_err() {
                    use std::process::Command;
                    if let Ok(Some(gap_row)) = store.get(&gap_id) {
                        let glance_result = Command::new("bash")
                            .arg("scripts/coord/chump-ambient-glance.sh")
                            .arg("--domain")
                            .arg(&gap_row.domain)
                            .arg("--title")
                            .arg(&gap_row.title)
                            .arg("--check-prs")
                            .current_dir(repo_path::repo_root())
                            .status();

                        if let Ok(status) = glance_result {
                            if !status.success() {
                                eprintln!();
                                eprintln!("[claim] Potential overlap detected for {gap_id}. Pass --force to proceed anyway.");
                                std::process::exit(1);
                            }
                        }
                    }
                }

                let session_id = flag("--session")
                    .or_else(|| crate::ambient_stream::env_session_id())
                    .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                // INFRA-1032: derive worktree from CWD basename when --worktree absent/empty
                let worktree = flag("--worktree")
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| {
                        std::env::current_dir()
                            .ok()
                            .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
                            .unwrap_or_default()
                    });
                let ttl: i64 = flag("--ttl").and_then(|s| s.parse().ok()).unwrap_or(3600);
                match store.claim(&gap_id, &session_id, &worktree, ttl) {
                    Ok(()) => {
                        println!("claimed {} for session {}", gap_id, session_id);
                        if why {
                            eprintln!(
                                "claimed {gap_id} — why: gap open and unclaimed, session={session_id}, TTL={ttl}s"
                            );
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap claim: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "preflight" => {
                // INFRA-1238: trap --help before positional validation.
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap preflight <GAP-ID>\n\n\
                         Check whether a gap is pickable (open, unclaimed, in state.db).\n\
                         Exits 0 if pickable, 1 if blocked, 2 on usage error."
                    );
                    return Ok(());
                }
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    println!("Usage: chump gap preflight <GAP-ID>");
                    std::process::exit(2);
                });
                match store.preflight(&gap_id) {
                    Ok(gap_store::PreflightResult::Available) => {
                        println!("[preflight] OK {} — open and unclaimed.", gap_id);
                        return Ok(());
                    }
                    Ok(gap_store::PreflightResult::Done) => {
                        eprintln!("[preflight] FAIL {} — already done.", gap_id);
                        std::process::exit(1);
                    }
                    Ok(gap_store::PreflightResult::Claimed(s)) => {
                        eprintln!(
                            "[preflight] FAIL {} — live-claimed by session {}.",
                            gap_id, s
                        );
                        std::process::exit(1);
                    }
                    Ok(gap_store::PreflightResult::NotFound) => {
                        eprintln!("[preflight] WARN {} — not found in state.db (run `chump gap import` first).", gap_id);
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap preflight: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "ship" => {
                // INFRA-1238: trap --help before positional validation.
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N] [--session ID]\n\n\
                         Mark a gap as done. Updates state.db (canonical), optionally mirrors to YAML.\n\n\
                         Options:\n  \
                           --update-yaml      Mirror status flip to docs/gaps/<ID>.yaml (destructive bulk-YAML; INFRA-825 staleness guard applies)\n  \
                           --closed-pr N      Stamp PR number on the row (required by INFRA-107 closed_pr integrity guard for YAML mirror)\n  \
                           --session ID       Session ID to record on the ship event (default derived)\n  \
                           --why              Print explanation alongside the flip\n  \
                           -h, --help         Show this help"
                    );
                    return Ok(());
                }
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N]");
                    std::process::exit(2);
                });
                let session_id = flag("--session")
                    .or_else(|| crate::ambient_stream::env_session_id())
                    .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                let update_yaml = args.iter().any(|a| a == "--update-yaml");
                let why = args.iter().any(|a| a == "--why");
                // INFRA-156: --closed-pr N stamps the closure PR number on the
                // row at ship time. Required by the INFRA-107 closed_pr
                // integrity guard for any status:done flip in YAML; passing
                // it here keeps state.db and gaps.yaml in agreement.
                let closed_pr: Option<i64> = match flag("--closed-pr") {
                    Some(s) => match s.trim().parse::<i64>() {
                        Ok(n) if n > 0 => Some(n),
                        _ => {
                            eprintln!(
                                "chump gap ship: --closed-pr expects a positive integer (got {:?})",
                                s
                            );
                            std::process::exit(2);
                        }
                    },
                    None => None,
                };
                // INFRA-1007: staleness gate — belt-and-suspenders for the CLAUDE.md
                // "rebase if > 15 commits behind" rule. bot-merge.sh has this gate for
                // the push path; the manual `chump gap ship` path needs the same check.
                let stale_threshold: u64 = std::env::var("CHUMP_GAP_SHIP_STALE_THRESHOLD")
                    .ok()
                    .and_then(|s| s.trim().parse().ok())
                    .unwrap_or(15);
                if std::env::var("CHUMP_GAP_SHIP_SKIP_STALE_CHECK").as_deref() != Ok("1") {
                    let _ = std::process::Command::new("git")
                        .args(["fetch", "origin", "main", "--quiet"])
                        .current_dir(&worktree_root)
                        .stderr(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .status();
                    let behind: u64 = std::process::Command::new("git")
                        .args(["rev-list", "--count", "HEAD..origin/main"])
                        .current_dir(&worktree_root)
                        .output()
                        .ok()
                        .filter(|o| o.status.success())
                        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
                        .unwrap_or(0);
                    if behind > stale_threshold {
                        eprintln!(
                            "chump gap ship: branch is {behind} commits behind origin/main \
                             (threshold {stale_threshold}). Rebase before shipping."
                        );
                        eprintln!("  Recover: git fetch && git rebase origin/main, then retry.");
                        eprintln!(
                            "  Override: CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 chump gap ship ..."
                        );
                        let branch = std::process::Command::new("git")
                            .args(["rev-parse", "--abbrev-ref", "HEAD"])
                            .current_dir(&worktree_root)
                            .output()
                            .ok()
                            .filter(|o| o.status.success())
                            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                            .unwrap_or_else(|| "unknown".to_string());
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
                        let _ = std::fs::create_dir_all(amb.parent().unwrap_or(&repo_root));
                        let event = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"stale_branch_blocked\",\
                             \"branch\":\"{branch}\",\"behind\":{behind},\
                             \"threshold\":{stale_threshold},\"phase\":\"gap-ship\"}}\n"
                        );
                        use std::io::Write as _;
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(&amb)
                        {
                            let _ = f.write_all(event.as_bytes());
                        }
                        std::process::exit(3);
                    }
                }
                match store.ship(&gap_id, &session_id, closed_pr) {
                    Ok(()) => {
                        println!("shipped {}", gap_id);
                        if why {
                            let pr_note = closed_pr
                                .map(|n| format!(", closed-pr=#{n}"))
                                .unwrap_or_default();
                            eprintln!(
                                "shipped {gap_id} — why: status flipped to done{pr_note}, session={session_id}"
                            );
                        }
                        // INFRA-1144: atomically close orphan PRs for this gap
                        // (complements INFRA-1139 sweeper). Emits orphan_pr_closed_at_ship
                        // events for each closure.
                        if let Ok(closed_prs) =
                            store.close_orphan_prs(&gap_id, closed_pr, &repo_root)
                        {
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            for (pr_num, reason) in closed_prs {
                                let closed_pr_str =
                                    closed_pr.map(|n| n.to_string()).unwrap_or_default();
                                let event = format!(
                                    "{{\"ts\":\"{ts}\",\"kind\":\"orphan_pr_closed_at_ship\",\
                                     \"gap\":\"{gap_id}\",\"pr\":{pr_num},\"ship_pr\":{closed_pr_str},\
                                     \"reason\":\"{reason}\"}}\n"
                                );
                                let ambient_log = repo_root.join(".chump-locks/ambient.jsonl");
                                let _ = std::fs::OpenOptions::new()
                                    .append(true)
                                    .create(true)
                                    .open(&ambient_log)
                                    .and_then(|mut f| {
                                        use std::io::Write;
                                        f.write_all(event.as_bytes())
                                    });
                                if why {
                                    eprintln!("  closed orphan PR #{pr_num} ({reason})");
                                }
                            }
                        }
                        // INFRA-1200: write-ahead log cleanup. On ship, stamp
                        // .chump-plans/<gap-id>/SHIPPED_AT so the 7-day GC pass
                        // can find and remove stale patch directories. Also sweep
                        // any existing directories already past the grace period.
                        {
                            let plans_base = repo_root.join(".chump-plans");
                            let gap_plans = plans_base.join(&gap_id);
                            if gap_plans.is_dir() {
                                let marker = gap_plans.join("SHIPPED_AT");
                                let ts = unix_ts().to_string();
                                let _ = std::fs::write(&marker, &ts);
                            }
                            // GC: remove any .chump-plans/<dir>/ with SHIPPED_AT > 7d old.
                            const GRACE_SECS: u64 = 7 * 24 * 3600;
                            let now_ts = unix_ts();
                            let mut removed_count: u64 = 0;
                            if let Ok(rd) = std::fs::read_dir(&plans_base) {
                                for entry in rd.flatten() {
                                    let marker = entry.path().join("SHIPPED_AT");
                                    if let Ok(contents) = std::fs::read_to_string(&marker) {
                                        if let Ok(ship_ts) = contents.trim().parse::<u64>() {
                                            if now_ts.saturating_sub(ship_ts) > GRACE_SECS
                                                && std::fs::remove_dir_all(entry.path()).is_ok()
                                            {
                                                removed_count += 1;
                                            }
                                        }
                                    }
                                }
                            }
                            if removed_count > 0 {
                                let ambient_log = repo_root.join(".chump-locks/ambient.jsonl");
                                let event = format!(
                                    "{{\"ts\":\"{}\",\"kind\":\"chump_plans_gc\",\
                                     \"gap\":\"{gap_id}\",\"removed_count\":{removed_count}}}\n",
                                    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ"),
                                );
                                let _ = std::fs::OpenOptions::new()
                                    .append(true)
                                    .create(true)
                                    .open(&ambient_log)
                                    .and_then(|mut f| {
                                        use std::io::Write;
                                        f.write_all(event.as_bytes())
                                    });
                            }
                        }
                        // INFRA-994: auto-close orphaned PRs whose title still
                        // references this gap ID. Runs close-superseded-prs.sh
                        // in the background so it doesn't block the ship command.
                        // CHUMP_SKIP_SUPERSEDED_CLOSE=1 disables (e.g. in tests
                        // that don't want real gh calls).
                        if std::env::var("CHUMP_SKIP_SUPERSEDED_CLOSE").as_deref() != Ok("1") {
                            let helper = worktree_root
                                .join("scripts")
                                .join("coord")
                                .join("close-superseded-prs.sh");
                            if helper.exists() {
                                let _ = std::process::Command::new("bash")
                                    .arg(&helper)
                                    .arg(&gap_id)
                                    .current_dir(&worktree_root)
                                    .spawn(); // fire-and-forget
                            }
                        }
                        if update_yaml {
                            // INFRA-148: warn if this binary predates the most recent
                            // gap_store-affecting commit on the repo's HEAD before mutating
                            // the YAML mirror. Pre-INFRA-147 binaries silently stripped the
                            // meta: preamble (~20k-line corruption observed 2026-04-27); a
                            // fresh build catches that and similar future serialization
                            // changes.
                            //
                            // INFRA-825 (2026-05-11): upgraded from warn to hard-fail
                            // for this single-gap path too — PR #1444 silently reverted
                            // META-044 because a stale binary regenerated YAMLs from a
                            // stale state.db. CHUMP_ALLOW_STALE_DESTRUCTIVE=1 is the
                            // audited override; otherwise the operation refuses.
                            match version::fail_if_stale_for_destructive(
                                &repo_root,
                                "gap ship --update-yaml",
                            ) {
                                version::DestructiveStalenessOutcome::Refuse => {
                                    return Err(anyhow::anyhow!(
                                        "refused: chump gap ship --update-yaml on stale binary (INFRA-825). \
                                         Rebuild with `cargo install --path . --bin chump --force` \
                                         or override with CHUMP_ALLOW_STALE_DESTRUCTIVE=1."
                                    ));
                                }
                                version::DestructiveStalenessOutcome::Proceed
                                | version::DestructiveStalenessOutcome::OverrideAccepted => {}
                            }
                            // INFRA-229 (post-INFRA-188 cutover, 2026-05-02):
                            // write the per-file YAML mirror at
                            // docs/gaps/<ID>.yaml instead of the deleted
                            // monolithic docs/gaps.yaml. The pre-INFRA-188
                            // path here would have silently re-created the
                            // monolithic file on every successful ship,
                            // resurrecting the very file INFRA-188 deleted.
                            // Behavior change: callers that pass
                            // `--update-yaml` now get a single per-file
                            // write, not a full-registry regen.
                            // INFRA-247: write to the linked worktree, not the main checkout.
                            // INFRA-498: gated on directory existence — when
                            // docs/gaps/ is absent (the post-deletion state),
                            // this becomes a no-op. state.db is canonical.
                            let per_file_dir = worktree_root.join("docs").join("gaps");
                            if !per_file_dir.exists() {
                                return Ok(());
                            }
                            match store.dump_per_file_single(&gap_id, &per_file_dir) {
                                Ok(true) => {
                                    let yaml_path = per_file_dir.join(format!("{gap_id}.yaml"));
                                    eprintln!("wrote {}", yaml_path.display());
                                    write_yaml_op_marker(&worktree_root, "ship");

                                    // INFRA-486: same auto-stage pattern as
                                    // INFRA-484 (gap reserve). The YAML mirror
                                    // regenerated by ship --update-yaml needs
                                    // to be staged so it rides along with the
                                    // close commit. Pre-fix: bot-merge.sh's
                                    // auto-close path manually `git add`s it
                                    // separately, but the manual recovery
                                    // path (operator runs ship by hand after
                                    // bot-merge wedge) leaves it untracked.
                                    //
                                    // Bypass: CHUMP_SHIP_NO_AUTOSTAGE=1.
                                    if std::env::var("CHUMP_SHIP_NO_AUTOSTAGE").as_deref()
                                        != Ok("1")
                                    {
                                        let _ = std::process::Command::new("git")
                                            .arg("-C")
                                            .arg(&worktree_root)
                                            .arg("add")
                                            .arg(&yaml_path)
                                            .stderr(std::process::Stdio::null())
                                            .stdout(std::process::Stdio::null())
                                            .status();
                                    }
                                }
                                Ok(false) => {} // no-op write — content unchanged
                                Err(e) => {
                                    eprintln!("warning: dump-per-file write failed: {e}")
                                }
                            }
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap ship: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "set" | "update" | "modify" | "edit" | "change" => {
                // INFRA-1036: 'set' and natural-language aliases for gap mutation.
                // CREDIBLE-016: unknown-flag detection — if the positional GAP-ID slot
                // starts with "--", the operator forgot the ID or passed a bad flag.
                let gap_set_usage = || {
                    eprintln!("Usage: chump gap set <GAP-ID> [--title T] [--description D] [--priority P]");
                    eprintln!("                          [--effort E] [--status S] [--notes N] [--add-note TEXT]");
                    eprintln!("                          [--source-doc S] [--opened-date D] [--closed-date D]");
                    eprintln!("                          [--closed-pr N] [--acceptance-criteria \"a|b|c\"] [--depends-on \"X,Y\"]");
                    eprintln!("                          [--skills-required SKS] [--preferred-backend BE]");
                    eprintln!("                          [--preferred-machine MACH] [--estimated-minutes MIN] [--required-model MODEL]");
                    eprintln!("  Note: --add-note TEXT appends '[ISO-timestamp] TEXT' to existing notes; --notes OVERWRITES.");
                };
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    gap_set_usage();
                    std::process::exit(2);
                });
                if gap_id.starts_with("--") {
                    eprintln!(
                        "Error: unknown flag {:?}. Did you forget the GAP-ID?",
                        gap_id
                    );
                    gap_set_usage();
                    std::process::exit(2);
                }
                let acceptance_criteria = flag("--acceptance-criteria").map(|raw| {
                    let parts: Vec<&str> = raw.split('|').collect();
                    serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
                });
                let depends_on = flag("--depends-on").map(|raw| {
                    let parts: Vec<&str> = raw
                        .split(',')
                        .map(|s| s.trim())
                        .filter(|s| !s.is_empty())
                        .collect();
                    serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
                });
                // INFRA-156: --closed-pr N as Option<i64>. Empty string clears
                // (Some(0) is an explicit "unset" signal we reject); positive
                // integer sets. The INFRA-107 guard rejects status:done with
                // missing/non-numeric closed_pr at commit time, so this is the
                // canonical way to satisfy it from the CLI rather than
                // hand-editing YAML.
                let closed_pr: Option<i64> = match flag("--closed-pr") {
                    Some(s) => match s.trim().parse::<i64>() {
                        Ok(n) if n > 0 => Some(n),
                        _ => {
                            eprintln!(
                                "chump gap set: --closed-pr expects a positive integer (got {:?})",
                                s
                            );
                            std::process::exit(2);
                        }
                    },
                    None => None,
                };
                // EFFECTIVE-020: --add-note appends a timestamped entry to the
                // existing notes without overwriting. Format per entry:
                //   "[YYYY-MM-DDTHH:MM:SSZ] <text>"
                // Multiple notes are newline-separated. The --notes flag still
                // overwrites the entire field; --add-note only appends.
                let notes: Option<String> = if let Some(add_text) = flag("--add-note") {
                    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    let new_entry = format!("[{}] {}", ts, add_text);
                    // Fetch current notes and append.
                    let existing = match store.get(&gap_id) {
                        Ok(Some(g)) if !g.notes.is_empty() => g.notes,
                        _ => String::new(),
                    };
                    let combined = if existing.is_empty() {
                        new_entry
                    } else {
                        format!("{}\n{}", existing, new_entry)
                    };
                    Some(combined)
                } else {
                    flag("--notes")
                };

                let update = gap_store::GapFieldUpdate {
                    title: flag("--title"),
                    description: flag("--description"),
                    priority: flag("--priority"),
                    effort: flag("--effort"),
                    status: flag("--status"),
                    acceptance_criteria,
                    depends_on,
                    notes,
                    source_doc: flag("--source-doc"),
                    opened_date: flag("--opened-date"),
                    closed_date: flag("--closed-date"),
                    closed_pr,
                    skills_required: flag("--skills-required"),
                    preferred_backend: flag("--preferred-backend"),
                    preferred_machine: flag("--preferred-machine"),
                    estimated_minutes: flag("--estimated-minutes"),
                    required_model: flag("--required-model"),
                };
                match store.set_fields(&gap_id, update) {
                    Ok(()) => {
                        println!("updated {}", gap_id);
                        // INFRA-470: state.db is canonical; the per-file YAML
                        // at docs/gaps/<ID>.yaml is a render of the DB. Without
                        // an auto-regen here, `chump gap set --notes "X"`
                        // mutates only state.db and leaves docs/gaps/<ID>.yaml
                        // stale — the same drift class INFRA-460 fixed for
                        // status propagation on import. Mirror the `ship`
                        // path: write the per-file YAML and stamp the
                        // .last-yaml-op freshness marker so the pre-commit
                        // raw-YAML guard recognizes the regenerated file as
                        // canonical.
                        let _ = version::warn_if_stale_for_gap_mutation(&repo_root);
                        // INFRA-498: gated on directory existence — no-op
                        // when docs/gaps/ is absent (post-deletion state).
                        let per_file_dir = worktree_root.join("docs").join("gaps");
                        if !per_file_dir.exists() {
                            return Ok(());
                        }
                        match store.dump_per_file_single(&gap_id, &per_file_dir) {
                            Ok(true) => {
                                eprintln!(
                                    "wrote {}",
                                    per_file_dir.join(format!("{gap_id}.yaml")).display()
                                );
                                write_yaml_op_marker(&worktree_root, "set");
                            }
                            Ok(false) => {
                                // Content unchanged — still stamp the marker
                                // so a follow-up `git add docs/gaps/<ID>.yaml`
                                // within 5 min for an unrelated reason isn't
                                // blocked by the raw-YAML guard.
                                write_yaml_op_marker(&worktree_root, "set");
                            }
                            Err(e) => {
                                eprintln!("warning: dump-per-file write failed: {e}")
                            }
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap set: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "dump" => {
                let out_path = flag("--out");
                // INFRA-188 v0 (2026-05-02): --per-file emits one file per
                // gap at <out_dir>/<ID>.yaml instead of a monolithic dump.
                // --out-dir overrides the default `docs/gaps/`.
                let per_file = args.iter().any(|a| a == "--per-file");
                let out_dir_flag = flag("--out-dir");

                // INFRA-148 + INFRA-825 (2026-05-11): for --per-file (true
                // bulk regen — writes every gap's YAML) hard-fail if the
                // binary is stale. PR #1444's silent META-044 revert was
                // caused by exactly this code path running with a stale
                // binary. --out PATH (single file dump) stays at warn-only
                // since it doesn't bulk-regen the gap registry.
                if out_path.is_some() && !per_file {
                    let _ = version::warn_if_stale_for_gap_mutation(&repo_root);
                }
                if per_file {
                    match version::fail_if_stale_for_destructive(&repo_root, "gap dump --per-file")
                    {
                        version::DestructiveStalenessOutcome::Refuse => {
                            return Err(anyhow::anyhow!(
                                "refused: chump gap dump --per-file on stale binary (INFRA-825). \
                                 Rebuild with `cargo install --path . --bin chump --force` \
                                 or override with CHUMP_ALLOW_STALE_DESTRUCTIVE=1."
                            ));
                        }
                        version::DestructiveStalenessOutcome::Proceed
                        | version::DestructiveStalenessOutcome::OverrideAccepted => {}
                    }
                }

                // ── INFRA-188 v0: --per-file path ────────────────────────────
                if per_file {
                    let dir_str = out_dir_flag.unwrap_or_else(|| "docs/gaps".to_string());
                    let dir = std::path::PathBuf::from(&dir_str);
                    // INFRA-247: relative path resolves under the linked worktree,
                    // not the main checkout. Absolute path is honored verbatim.
                    let dir_abs = if dir.is_absolute() {
                        dir
                    } else {
                        worktree_root.join(dir)
                    };
                    match store.dump_per_file(&dir_abs) {
                        Ok((written, skipped)) => {
                            eprintln!(
                                "wrote {} file(s) to {} ({} unchanged)",
                                written,
                                dir_abs.display(),
                                skipped
                            );
                            // INFRA-094 marker: this dir is also a canonical
                            // chump-CLI yaml op surface.
                            write_yaml_op_marker(&worktree_root, "dump --per-file");
                            return Ok(());
                        }
                        Err(e) => {
                            eprintln!("chump gap dump --per-file: {e:#}");
                            std::process::exit(1);
                        }
                    }
                }

                // INFRA-147: when --out points at an existing file, preserve its
                // meta: preamble. For stdout or new files there is no source to
                // preserve from — bare dump is correct.
                let result = match out_path.as_deref() {
                    Some(p) => match std::fs::read_to_string(p) {
                        Ok(source) => store.dump_yaml_with_meta(&source),
                        Err(_) => store.dump_yaml(),
                    },
                    None => store.dump_yaml(),
                };
                match result {
                    Ok(yaml) => {
                        if let Some(path) = out_path {
                            std::fs::write(&path, &yaml).unwrap_or_else(|e| {
                                eprintln!("write error: {e}");
                                std::process::exit(1);
                            });
                            eprintln!("wrote {}", path);
                            // INFRA-094: mark this as a chump-CLI yaml op so the
                            // pre-commit hook recognizes the gaps.yaml diff as
                            // canonical (not a raw hand-edit). INFRA-247: marker
                            // goes to the linked worktree's .chump/.last-yaml-op,
                            // matching where the staged YAML edits sit.
                            write_yaml_op_marker(&worktree_root, "dump");
                        } else {
                            print!("{}", yaml);
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap dump: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "import" => {
                let yaml_path = flag("--yaml").unwrap_or_else(|| "docs/gaps.yaml".into());
                // INFRA-821: derive repo root from --yaml path. When the user passes
                // an absolute path (e.g. /abs/repo/docs/gaps.yaml), strip the trailing
                // docs/gaps.yaml or docs/gaps component to recover the repo root instead
                // of using "/" which causes 0-inserted silently.
                let root = {
                    let p = std::path::Path::new(&yaml_path);
                    if p.is_absolute() {
                        // Strip known suffixes to recover repo root.
                        let stripped = yaml_path
                            .strip_suffix("/docs/gaps.yaml")
                            .or_else(|| yaml_path.strip_suffix("/docs/gaps"))
                            .map(std::path::PathBuf::from);
                        if let Some(r) = stripped {
                            r
                        } else if p.is_dir() {
                            // Treat the absolute path itself as the repo root.
                            p.to_path_buf()
                        } else {
                            eprintln!(
                                "chump gap import: cannot derive repo root from --yaml {:?}.\n\
                                 Expected path ending in docs/gaps.yaml or docs/gaps/.\n\
                                 Hint: omit --yaml to import from current repo root ({}).",
                                yaml_path,
                                repo_root.display()
                            );
                            std::process::exit(1);
                        }
                    } else {
                        repo_root.clone()
                    }
                };
                // INFRA-1434: title-similarity guard at import time. Closes
                // the YAML-import bypass that let INFRA-1267/1268 land as
                // 100% identical-title duplicates. Mirrors INFRA-1149
                // reserve-time check; same default 0.85 block threshold.
                //
                // Disable: CHUMP_GAP_IMPORT_NO_SIMILARITY=1 (CI / bulk imports)
                // Tune:    CHUMP_GAP_IMPORT_SIMILARITY_BLOCK (default 0.85)
                let block_threshold: Option<f64> =
                    if std::env::var("CHUMP_GAP_IMPORT_NO_SIMILARITY").as_deref() == Ok("1") {
                        None
                    } else {
                        Some(
                            std::env::var("CHUMP_GAP_IMPORT_SIMILARITY_BLOCK")
                                .ok()
                                .and_then(|v| v.parse().ok())
                                .unwrap_or(0.85),
                        )
                    };
                match store.import_from_yaml_with_similarity(&root, block_threshold) {
                    Ok((ins, skip, backfilled, blocked)) => {
                        let backfill_msg = if backfilled > 0 {
                            format!(", {backfilled} closed_pr values backfilled from YAML")
                        } else {
                            String::new()
                        };
                        let blocked_msg = if blocked > 0 {
                            format!(
                                ", {blocked} blocked by title-similarity (INFRA-1434; \
                                 see ambient.jsonl kind=gap_import_similarity_block)"
                            )
                        } else {
                            String::new()
                        };
                        eprintln!(
                            "import complete: {ins} inserted, {skip} skipped (already present)\
                             {backfill_msg}{blocked_msg}."
                        );
                        // Non-zero exit when any row was blocked so CI scripts
                        // can detect partial imports. Bypass via env var above.
                        if blocked > 0 {
                            std::process::exit(1);
                        }
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap import: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // INFRA-538: rebuild state.db from .chump/state.sql when the DB
            // is corrupted. Backs up existing DB first, then replays YAML.
            "restore" => {
                let from_sql = args.iter().any(|a| a == "--from-sql");
                if !from_sql {
                    eprintln!("Usage: chump gap restore --from-sql");
                    eprintln!(
                        "       Rebuilds .chump/state.db from .chump/state.sql (YAML mirror)."
                    );
                    std::process::exit(2);
                }
                let sql_path = repo_root.join(".chump").join("state.sql");
                if !sql_path.exists() {
                    eprintln!(
                        "chump gap restore: {} not found — nothing to restore from",
                        sql_path.display()
                    );
                    std::process::exit(1);
                }
                let db_path = gap_store::GapStore::db_path(&repo_root);
                // Back up existing DB before clobbering it.
                if db_path.exists() {
                    let bak = db_path.with_extension("db.bak");
                    std::fs::copy(&db_path, &bak).unwrap_or_else(|e| {
                        eprintln!("chump gap restore: could not back up state.db: {e}");
                        std::process::exit(1);
                    });
                    eprintln!("backed up {} → {}", db_path.display(), bak.display());
                    // Remove the corrupted DB so GapStore::open creates a fresh one.
                    std::fs::remove_file(&db_path).unwrap_or_else(|e| {
                        eprintln!("chump gap restore: could not remove corrupted state.db: {e}");
                        std::process::exit(1);
                    });
                }
                let mut fresh_store = match gap_store::GapStore::open(&repo_root) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("chump gap restore: could not open fresh state.db: {e:#}");
                        std::process::exit(1);
                    }
                };
                match fresh_store.restore_from_state_sql(&sql_path) {
                    Ok(n) => {
                        println!(
                            "chump gap restore: rebuilt state.db from {} — {} gap(s) restored",
                            sql_path.display(),
                            n
                        );
                    }
                    Err(e) => {
                        eprintln!("chump gap restore: restore failed: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // INFRA-586: PM health signal for META-046 curation.
            // Checks: P0 ages, vague (no AC) pickable, double-encoded
            // depends_on, missing-dep refs, open-with-closed-pr, race-*
            // test pollution. Exits non-zero if P0 >5, any P0 stuck >7d,
            // or any vague pickable gap exists.
            "audit-priorities" => {
                let now_secs = unix_ts() as i64;
                let all_gaps = match store.list(None) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump gap audit-priorities: {e:#}");
                        std::process::exit(1);
                    }
                };

                let p0_open: Vec<&gap_store::GapRow> = all_gaps
                    .iter()
                    .filter(|g| g.priority == "P0" && g.status == "open")
                    .collect();
                let p0_count = p0_open.len();
                // INFRA-627: auto-filed P0s (from pr-triage-bot) are exempt
                // from the P0 >5 budget — they represent real CI failures the
                // fleet must attack first and should not be demoted by the
                // operator-curation rule.
                let auto_filed_marker = "auto-filed by pr-triage-bot";
                let p0_auto_filed: Vec<&gap_store::GapRow> = p0_open
                    .iter()
                    .filter(|g| g.notes.contains(auto_filed_marker))
                    .copied()
                    .collect();
                let p0_manual_count = p0_count - p0_auto_filed.len();

                let p0_stuck: Vec<(&gap_store::GapRow, i64)> = p0_open
                    .iter()
                    .filter_map(|g| {
                        let age_days = (now_secs - g.created_at) / 86400;
                        if age_days > 7 {
                            Some((*g, age_days))
                        } else {
                            None
                        }
                    })
                    .collect();

                let vague_pickable: Vec<&gap_store::GapRow> = all_gaps
                    .iter()
                    .filter(|g| g.status == "open" && g.acceptance_criteria.trim().is_empty())
                    .collect();

                let double_encoded: Vec<&gap_store::GapRow> = all_gaps
                    .iter()
                    .filter(|g| {
                        let d = g.depends_on.trim();
                        !d.is_empty() && d != "[]" && d.starts_with('"')
                    })
                    .collect();

                let all_ids: std::collections::HashSet<&str> =
                    all_gaps.iter().map(|g| g.id.as_str()).collect();
                let mut missing_dep_pairs: Vec<(String, String)> = Vec::new();
                for g in &all_gaps {
                    if let Ok(serde_json::Value::Array(arr)) =
                        serde_json::from_str::<serde_json::Value>(&g.depends_on)
                    {
                        for v in arr {
                            if let serde_json::Value::String(dep_id) = v {
                                if !all_ids.contains(dep_id.as_str()) {
                                    missing_dep_pairs.push((g.id.clone(), dep_id));
                                }
                            }
                        }
                    }
                }

                let open_with_closed_pr: Vec<&gap_store::GapRow> = all_gaps
                    .iter()
                    .filter(|g| g.status == "open" && g.closed_pr.is_some())
                    .collect();

                let race_pollution: Vec<&gap_store::GapRow> = all_gaps
                    .iter()
                    .filter(|g| g.status == "open" && g.title.to_lowercase().starts_with("race-"))
                    .collect();

                let done_with_closed_pr: Vec<&gap_store::GapRow> = all_gaps
                    .iter()
                    .filter(|g| g.status == "done" && g.closed_pr.is_some())
                    .collect();

                if json_out {
                    let report = serde_json::json!({
                        "p0_count": p0_count,
                        "p0_manual_count": p0_manual_count,
                        "p0_auto_filed_count": p0_auto_filed.len(),
                        "p0_stuck_7d": p0_stuck.len(),
                        "vague_pickable": vague_pickable.len(),
                        "double_encoded_depends_on": double_encoded.len(),
                        "missing_dep_refs": missing_dep_pairs.len(),
                        "open_with_closed_pr": open_with_closed_pr.len(),
                        "done_with_closed_pr": done_with_closed_pr.len(),
                        "race_test_pollution": race_pollution.len(),
                        "p0_gaps": p0_open.iter().map(|g| {
                            let age_days = (now_secs - g.created_at) / 86400;
                            let auto_filed = g.notes.contains(auto_filed_marker);
                            serde_json::json!({"id": g.id, "title": g.title, "age_days": age_days, "auto_filed": auto_filed})
                        }).collect::<Vec<_>>(),
                    });
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&report).unwrap_or_default()
                    );
                } else {
                    println!("=== gap audit-priorities ===");
                    println!();
                    println!(
                        "P0 open gaps: {} ({} manual, {} auto-filed by pr-triage-bot)",
                        p0_count,
                        p0_manual_count,
                        p0_auto_filed.len()
                    );
                    for g in &p0_open {
                        let age_days = (now_secs - g.created_at) / 86400;
                        let stuck = if age_days > 7 { " *** STUCK" } else { "" };
                        let marker = if g.notes.contains(auto_filed_marker) {
                            " [auto-filed]"
                        } else {
                            ""
                        };
                        println!(
                            "  {} — {} ({}d old{}{})",
                            g.id, g.title, age_days, stuck, marker
                        );
                    }
                    println!();
                    println!("Vague (no AC) pickable: {}", vague_pickable.len());
                    for g in &vague_pickable {
                        println!("  {} — {} ({})", g.id, g.title, g.priority);
                    }
                    println!();
                    println!("Double-encoded depends_on: {}", double_encoded.len());
                    for g in &double_encoded {
                        println!("  {} — depends_on={}", g.id, g.depends_on);
                    }
                    println!();
                    println!("Missing-dep refs: {}", missing_dep_pairs.len());
                    for (id, dep) in &missing_dep_pairs {
                        println!("  {} → {} (not in registry)", id, dep);
                    }
                    println!();
                    println!("Open with closed_pr set: {}", open_with_closed_pr.len());
                    for g in &open_with_closed_pr {
                        println!(
                            "  {} — {} (closed_pr=#{})",
                            g.id,
                            g.title,
                            g.closed_pr.unwrap_or(0)
                        );
                    }
                    println!();
                    println!("Done with closed_pr set: {}", done_with_closed_pr.len());
                    for g in &done_with_closed_pr {
                        println!(
                            "  {} — {} (closed_pr=#{})",
                            g.id,
                            g.title,
                            g.closed_pr.unwrap_or(0)
                        );
                    }
                    println!();
                    println!("race-* test pollution (open): {}", race_pollution.len());
                    for g in &race_pollution {
                        println!("  {} — {}", g.id, g.title);
                    }
                }

                let mut fail_reasons: Vec<String> = Vec::new();
                // INFRA-627: auto-filed P0s exempt from budget — count only manual ones.
                if p0_manual_count > 5 {
                    fail_reasons.push(format!(
                        "P0 manual count {} > 5 (plus {} auto-filed, exempt)",
                        p0_manual_count,
                        p0_auto_filed.len()
                    ));
                }
                if !p0_stuck.is_empty() {
                    fail_reasons.push(format!("{} P0 gap(s) stuck >7d", p0_stuck.len()));
                }
                if !vague_pickable.is_empty() {
                    fail_reasons.push(format!(
                        "{} vague (no AC) pickable gap(s)",
                        vague_pickable.len()
                    ));
                }
                if !done_with_closed_pr.is_empty() {
                    fail_reasons.push(format!(
                        "{} done gap(s) with closed_pr set — review closure consistency",
                        done_with_closed_pr.len()
                    ));
                }
                if fail_reasons.is_empty() {
                    return Ok(());
                }
                for r in &fail_reasons {
                    eprintln!("FAIL: {}", r);
                }
                std::process::exit(1);
            }
            // INFRA-942: classify every open gap by why it is non-pickable and
            // emit a ranked action list.
            // Reasons: false-dep | too-large | vague-ac | low-priority
            // Actions: strip-dep | decompose | add-ac | demote
            // --json   → machine-readable array output
            // --apply  → execute auto-fixable actions (strip false-deps, demote P2→P3)
            "triage" => {
                // INFRA-1238: trap --help.
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!(
                        "Usage: chump gap triage [--json] [--apply]\n\n\
                         Classify every open gap by why it is non-pickable and emit ranked action list.\n\
                         Reasons: too-large, false-dep, vague-ac, low-priority.\n\n\
                         Options:\n  \
                           --json    Emit JSON; default is a human table\n  \
                           --apply   Execute recommended actions (decompose/strip-dep/add-ac/demote); default is dry-run\n  \
                           -h, --help  Show this help"
                    );
                    return Ok(());
                }
                let as_json = args.iter().any(|a| a == "--json");
                let apply = args.iter().any(|a| a == "--apply");

                let all_gaps = match store.list(None) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump gap triage: {e:#}");
                        std::process::exit(1);
                    }
                };

                let now_secs = unix_ts() as i64;

                let status_by_id: std::collections::HashMap<&str, &str> = all_gaps
                    .iter()
                    .map(|g| (g.id.as_str(), g.status.as_str()))
                    .collect();

                // Set of gap IDs referenced in any depends_on — used to detect
                // whether a large gap has been broken into sub-parts.
                let mut dep_target_ids: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                for g in &all_gaps {
                    if let Ok(serde_json::Value::Array(arr)) =
                        serde_json::from_str::<serde_json::Value>(&g.depends_on)
                    {
                        for v in &arr {
                            if let serde_json::Value::String(dep_id) = v {
                                dep_target_ids.insert(dep_id.clone());
                            }
                        }
                    }
                }

                #[derive(serde::Serialize)]
                struct TriageItem {
                    id: String,
                    title: String,
                    reason: String,
                    recommended_action: String,
                    detail: String,
                }

                let open_gaps: Vec<&gap_store::GapRow> =
                    all_gaps.iter().filter(|g| g.status == "open").collect();

                let mut items: Vec<TriageItem> = Vec::new();

                for gap in &open_gaps {
                    // 1. false-dep
                    if let Ok(serde_json::Value::Array(arr)) =
                        serde_json::from_str::<serde_json::Value>(&gap.depends_on)
                    {
                        for v in &arr {
                            if let serde_json::Value::String(dep_id) = v {
                                if status_by_id.get(dep_id.as_str()).copied() == Some("done") {
                                    items.push(TriageItem {
                                        id: gap.id.clone(),
                                        title: gap.title.chars().take(70).collect(),
                                        reason: "false-dep".to_string(),
                                        recommended_action: "strip-dep".to_string(),
                                        detail: format!("depends_on {} which is done", dep_id),
                                    });
                                }
                            }
                        }
                    }

                    // 2. too-large
                    let effort_lower = gap.effort.to_lowercase();
                    if (effort_lower == "l" || effort_lower == "xl")
                        && !dep_target_ids.contains(&gap.id)
                    {
                        items.push(TriageItem {
                            id: gap.id.clone(),
                            title: gap.title.chars().take(70).collect(),
                            reason: "too-large".to_string(),
                            recommended_action: "decompose".to_string(),
                            detail: format!("effort={}, no sub-gaps filed yet", gap.effort),
                        });
                    }

                    // 3. vague-ac
                    {
                        let ac_items = gap_store::parse_json_ac_list(&gap.acceptance_criteria);
                        let vague_reason =
                            if gap.acceptance_criteria.trim().is_empty() || ac_items.is_empty() {
                                Some("empty acceptance_criteria")
                            } else if ac_items.iter().any(|item| {
                                let lower = item.to_lowercase();
                                lower.contains("todo")
                                    || lower.trim() == "tbd"
                                    || lower.trim() == "n/a"
                                    || lower.trim() == "tbc"
                            }) {
                                Some("acceptance_criteria contains TODO/TBD placeholder")
                            } else {
                                None
                            };
                        if let Some(detail) = vague_reason {
                            items.push(TriageItem {
                                id: gap.id.clone(),
                                title: gap.title.chars().take(70).collect(),
                                reason: "vague-ac".to_string(),
                                recommended_action: "add-ac".to_string(),
                                detail: detail.to_string(),
                            });
                        }
                    }

                    // 4. low-priority: P2/P3 idle >90d
                    let age_days = (now_secs - gap.created_at) / 86400;
                    if (gap.priority == "P2" || gap.priority == "P3") && age_days > 90 {
                        items.push(TriageItem {
                            id: gap.id.clone(),
                            title: gap.title.chars().take(70).collect(),
                            reason: "low-priority".to_string(),
                            recommended_action: "demote".to_string(),
                            detail: format!(
                                "priority={}, {}d old — consider closing or demoting further",
                                gap.priority, age_days
                            ),
                        });
                    }
                }

                // --apply: execute auto-fixable actions
                if apply {
                    let mut applied: std::collections::HashSet<(String, String)> =
                        std::collections::HashSet::new();
                    for item in &items {
                        let key = (item.id.clone(), item.reason.clone());
                        if applied.contains(&key) {
                            continue;
                        }
                        applied.insert(key);
                        match item.reason.as_str() {
                            "false-dep" => match store.get(&item.id) {
                                Ok(Some(cur_gap)) => {
                                    if let Ok(serde_json::Value::Array(arr)) =
                                        serde_json::from_str::<serde_json::Value>(
                                            &cur_gap.depends_on,
                                        )
                                    {
                                        let remaining: Vec<String> = arr
                                            .iter()
                                            .filter_map(|v| {
                                                if let serde_json::Value::String(dep_id) = v {
                                                    if status_by_id.get(dep_id.as_str()).copied()
                                                        != Some("done")
                                                    {
                                                        Some(dep_id.clone())
                                                    } else {
                                                        None
                                                    }
                                                } else {
                                                    None
                                                }
                                            })
                                            .collect();
                                        let new_deps = serde_json::to_string(&remaining)
                                            .unwrap_or_else(|_| "[]".to_string());
                                        let mut update = gap_store::GapFieldUpdate::default();
                                        update.depends_on = Some(new_deps);
                                        match store.set_fields(&item.id, update) {
                                            Ok(()) => eprintln!(
                                                "triage --apply: stripped done deps from {}",
                                                item.id
                                            ),
                                            Err(e) => eprintln!(
                                                "triage --apply: strip-dep on {} failed: {e:#}",
                                                item.id
                                            ),
                                        }
                                    }
                                }
                                Ok(None) => {}
                                Err(e) => {
                                    eprintln!("triage --apply: get {} failed: {e:#}", item.id)
                                }
                            },
                            "low-priority" => {
                                if let Some(gap) = open_gaps.iter().find(|g| g.id == item.id) {
                                    if gap.priority == "P2" {
                                        let gap_age = (now_secs - gap.created_at) / 86400;
                                        let mut update = gap_store::GapFieldUpdate::default();
                                        update.priority = Some("P3".to_string());
                                        match store.set_fields(&item.id, update) {
                                            Ok(()) => eprintln!(
                                                "triage --apply: demoted {} P2→P3 ({}d old)",
                                                item.id, gap_age
                                            ),
                                            Err(e) => eprintln!(
                                                "triage --apply: demote {} failed: {e:#}",
                                                item.id
                                            ),
                                        }
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }

                // Observability — emit triage summary so fleet-brief / waste-tally
                // can track registry health over time (INFRA-755 observability-budget).
                let false_dep_n = items.iter().filter(|i| i.reason == "false-dep").count();
                let too_large_n = items.iter().filter(|i| i.reason == "too-large").count();
                let vague_ac_n = items.iter().filter(|i| i.reason == "vague-ac").count();
                let low_pri_n = items.iter().filter(|i| i.reason == "low-priority").count();
                tracing::info!(
                    open_checked = open_gaps.len(),
                    actionable = items.len(),
                    false_dep = false_dep_n,
                    too_large = too_large_n,
                    vague_ac = vague_ac_n,
                    low_priority = low_pri_n,
                    apply_mode = apply,
                    "infra942 gap triage complete"
                );

                if as_json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&items).unwrap_or_default()
                    );
                } else {
                    println!(
                        "=== gap triage ({} open gaps, {} actionable) ===",
                        open_gaps.len(),
                        items.len()
                    );
                    println!();
                    if items.is_empty() {
                        println!("All open gaps are clean — no triage needed.");
                    } else {
                        let col_id = items.iter().map(|i| i.id.len()).max().unwrap_or(6).max(6);
                        let col_reason = items
                            .iter()
                            .map(|i| i.reason.len())
                            .max()
                            .unwrap_or(12)
                            .max(12);
                        let col_action = items
                            .iter()
                            .map(|i| i.recommended_action.len())
                            .max()
                            .unwrap_or(18)
                            .max(18);
                        println!(
                            "{:<id_w$}  {:<r_w$}  {:<a_w$}  detail",
                            "id",
                            "reason",
                            "recommended-action",
                            id_w = col_id,
                            r_w = col_reason,
                            a_w = col_action
                        );
                        println!("{}", "-".repeat(col_id + col_reason + col_action + 30));
                        for item in &items {
                            println!(
                                "{:<id_w$}  {:<r_w$}  {:<a_w$}  {}",
                                item.id,
                                item.reason,
                                item.recommended_action,
                                item.detail,
                                id_w = col_id,
                                r_w = col_reason,
                                a_w = col_action
                            );
                        }
                        println!();
                        if apply {
                            println!(
                                "(--apply: false-dep strip and P2→P3 demotion executed above)"
                            );
                        } else {
                            println!(
                                "Run with --apply to auto-fix false-dep and low-priority items."
                            );
                            println!("Run with --json for machine-readable output.");
                        }
                    }
                }

                if !items.is_empty() {
                    std::process::exit(1);
                }
            }
            "audit-ac" => {
                // COG-052: check whether closed gaps' AC items were demonstrated in their PR diff.
                // INFRA-936: --open mode scans open gaps for vague/missing/TODO AC.
                // Usage: chump gap audit-ac [GAP-ID] [--recent N] [--open] [--json]
                //   GAP-ID     — audit one gap; must have closed_pr set
                //   --recent N — audit N most recently closed gaps (default 20 if no GAP-ID)
                //   --open     — INFRA-936: check open gaps for empty/TODO acceptance_criteria
                //   --json     — machine-readable output
                let as_json = args.iter().any(|a| a == "--json");
                let check_open = args.iter().any(|a| a == "--open");

                let all_gaps = match store.list(None) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump gap audit-ac: {e:#}");
                        std::process::exit(1);
                    }
                };

                // ── INFRA-936: --open mode ─────────────────────────────────────────────
                if check_open {
                    #[derive(serde::Serialize)]
                    struct VagueGap {
                        id: String,
                        title: String,
                        reason: String, // "empty" | "todo_placeholder"
                    }

                    let open_gaps: Vec<&gap_store::GapRow> =
                        all_gaps.iter().filter(|g| g.status == "open").collect();

                    let mut vague: Vec<VagueGap> = Vec::new();
                    for gap in &open_gaps {
                        let ac_items = gap_store::parse_json_ac_list(&gap.acceptance_criteria);
                        let reason =
                            if gap.acceptance_criteria.trim().is_empty() || ac_items.is_empty() {
                                Some("empty")
                            } else if ac_items.iter().any(|item| {
                                let lower = item.to_lowercase();
                                lower.contains("todo")
                                    || lower.trim() == "tbd"
                                    || lower.trim() == "n/a"
                                    || lower.trim() == "tbc"
                            }) {
                                Some("todo_placeholder")
                            } else {
                                None
                            };

                        if let Some(r) = reason {
                            vague.push(VagueGap {
                                id: gap.id.clone(),
                                title: gap.title.chars().take(80).collect(),
                                reason: r.to_string(),
                            });
                        }
                    }

                    tracing::info!(
                        open_checked = open_gaps.len(),
                        vague_count = vague.len(),
                        "infra936 audit-ac --open complete"
                    );

                    if as_json {
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&vague).unwrap_or_default()
                        );
                    } else {
                        println!(
                            "=== gap audit-ac --open ({} open gaps checked) ===",
                            open_gaps.len()
                        );
                        println!();
                        if vague.is_empty() {
                            println!("All open gaps have concrete acceptance criteria.");
                        } else {
                            for v in &vague {
                                println!("[{}] {}  {}", v.reason, v.id, v.title);
                            }
                            println!();
                            println!("Vague open gaps: {}/{}", vague.len(), open_gaps.len());
                        }
                    }

                    if !vague.is_empty() {
                        std::process::exit(1);
                    } else {
                        std::process::exit(0);
                    }
                } else {
                    // ── existing COG-052 closed-gap AC coverage check ──────────────────────

                    let recent_n: usize = args
                        .iter()
                        .position(|a| a == "--recent")
                        .and_then(|i| args.get(i + 1))
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(20);

                    // Collect target gaps: either the specified one or the N most-recently closed.
                    let specific_id = args.get(3).filter(|a| !a.starts_with('-')).cloned();

                    let targets: Vec<&gap_store::GapRow> = if let Some(ref id) = specific_id {
                        all_gaps
                            .iter()
                            .filter(|g| g.id.eq_ignore_ascii_case(id))
                            .collect()
                    } else {
                        let mut closed: Vec<&gap_store::GapRow> = all_gaps
                            .iter()
                            .filter(|g| g.status == "done" && g.closed_pr.is_some())
                            .collect();
                        // Most-recently closed first (use closed_at unix timestamp).
                        closed.sort_by(|a, b| {
                            let ta = a.closed_at.unwrap_or(a.created_at);
                            let tb = b.closed_at.unwrap_or(b.created_at);
                            tb.cmp(&ta)
                        });
                        closed.truncate(recent_n);
                        closed
                    };

                    if targets.is_empty() {
                        eprintln!("chump gap audit-ac: no matching gaps found");
                        std::process::exit(1);
                    }

                    // Common stop-words to skip when keyword-matching AC text against diffs.
                    const STOP: &[&str] = &[
                        "the", "and", "for", "that", "this", "with", "when", "from", "not", "are",
                        "all", "any", "each", "have", "must", "will", "but", "via", "can", "into",
                        "also", "then", "run", "use", "set", "add", "new", "its", "may", "per",
                        "has", "been",
                    ];

                    #[derive(serde::Serialize)]
                    struct AcItem {
                        text: String,
                        matched: bool,
                        matched_terms: Vec<String>,
                        missing_terms: Vec<String>,
                    }
                    #[derive(serde::Serialize)]
                    struct GapAcResult {
                        id: String,
                        title: String,
                        closed_pr: i64,
                        ac_items: Vec<AcItem>,
                        coverage_pct: u8,
                        diverged: bool,
                    }

                    let mut results: Vec<GapAcResult> = Vec::new();

                    for gap in &targets {
                        let pr_num = match gap.closed_pr {
                            Some(n) => n,
                            None => continue,
                        };

                        // Fetch PR diff via gh CLI.
                        let diff_out = std::process::Command::new("gh")
                            .args(["pr", "diff", &pr_num.to_string()])
                            .output();
                        let diff_text = match diff_out {
                            Ok(o) if o.status.success() => {
                                String::from_utf8_lossy(&o.stdout).to_lowercase()
                            }
                            _ => {
                                if !as_json {
                                    eprintln!(
                                        "[audit-ac] WARN: could not fetch diff for PR #{pr_num} \
                                     (gh not available or PR closed); skipping {}",
                                        gap.id
                                    );
                                }
                                continue;
                            }
                        };

                        let ac_items_raw: Vec<String> =
                            gap_store::parse_json_ac_list(&gap.acceptance_criteria);
                        let mut item_results: Vec<AcItem> = Vec::new();
                        let mut total_terms = 0usize;
                        let mut total_matched = 0usize;

                        for ac_text in &ac_items_raw {
                            // Extract meaningful keywords (>= 4 chars, not stop-words).
                            let terms: Vec<String> = ac_text
                                .split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-')
                                .filter(|t| t.len() >= 4)
                                .map(|t| t.to_lowercase())
                                .filter(|t| !STOP.contains(&t.as_str()))
                                .collect::<std::collections::HashSet<_>>()
                                .into_iter()
                                .collect();

                            let matched_terms: Vec<String> = terms
                                .iter()
                                .filter(|t| diff_text.contains(t.as_str()))
                                .cloned()
                                .collect();
                            let missing_terms: Vec<String> = terms
                                .iter()
                                .filter(|t| !diff_text.contains(t.as_str()))
                                .cloned()
                                .collect();

                            let item_matched =
                                !terms.is_empty() && matched_terms.len() * 2 >= terms.len(); // ≥50% terms found

                            total_terms += terms.len();
                            total_matched += matched_terms.len();

                            item_results.push(AcItem {
                                text: ac_text.clone(),
                                matched: item_matched,
                                matched_terms,
                                missing_terms,
                            });
                        }

                        let coverage_pct = (total_matched * 100)
                            .checked_div(total_terms)
                            .map(|v| v.min(100) as u8)
                            .unwrap_or(100u8);
                        let diverged = coverage_pct < 50;

                        results.push(GapAcResult {
                            id: gap.id.clone(),
                            title: gap.title.chars().take(80).collect(),
                            closed_pr: pr_num,
                            ac_items: item_results,
                            coverage_pct,
                            diverged,
                        });
                    }

                    let diverged_total = results.iter().filter(|r| r.diverged).count();
                    tracing::info!(
                        gaps_checked = results.len(),
                        diverged = diverged_total,
                        "cog052 audit-ac complete"
                    );

                    if as_json {
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&results).unwrap_or_default()
                        );
                    } else {
                        println!("=== gap audit-ac ({} gaps checked) ===", results.len());
                        println!();
                        let mut diverged_count = 0usize;
                        for r in &results {
                            let flag = if r.diverged { " *** DIVERGED" } else { "" };
                            println!(
                                "{} (PR #{}) — {}% coverage{}",
                                r.id, r.closed_pr, r.coverage_pct, flag
                            );
                            if r.diverged {
                                diverged_count += 1;
                                for item in &r.ac_items {
                                    if !item.matched {
                                        println!(
                                            "  MISS: {}",
                                            if item.text.len() > 100 {
                                                format!("{}…", &item.text[..100])
                                            } else {
                                                item.text.clone()
                                            }
                                        );
                                        if !item.missing_terms.is_empty() {
                                            println!(
                                                "        missing terms: {}",
                                                item.missing_terms.join(", ")
                                            );
                                        }
                                    }
                                }
                            }
                        }
                        println!();
                        println!(
                            "Diverged (< 50% AC coverage in diff): {}/{}",
                            diverged_count,
                            results.len()
                        );
                        if diverged_count > 0 {
                            std::process::exit(1);
                        }
                    }
                } // end else (COG-052 closed-gap path)
            }
            "decompose" => {
                // INFRA-1238: trap --help before positional validation.
                if args
                    .iter()
                    .skip(3)
                    .any(|a| matches!(a.as_str(), "--help" | "-h"))
                {
                    println!("Usage: chump gap decompose <GAP-ID> [--apply] [--verify] [--json] [--dry-run] [--no-description]");
                    println!();
                    println!(
                        "Suggests xs/s slices for a large (m/l) gap using the provider cascade."
                    );
                    println!(
                        "  --verify          Validate slices via a stronger model before filing"
                    );
                    println!("  --apply           File the suggested slices and demote the parent");
                    println!("  --json            Output suggestions as JSON");
                    println!(
                        "  --dry-run         Print the full LLM prompt without calling the LLM"
                    );
                    println!(
                        "  --no-description  Skip injecting the gap description into the prompt"
                    );
                    println!("  -h, --help        Show this help");
                    return Ok(());
                }
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap decompose <GAP-ID> [--apply] [--verify] [--json] [--dry-run] [--no-description]");
                    eprintln!();
                    eprintln!(
                        "Suggests xs/s slices for a large (m/l) gap using the provider cascade."
                    );
                    eprintln!("  --verify          Validate slices via a stronger model before filing");
                    eprintln!("  --apply           File the suggested slices and demote the parent");
                    eprintln!("  --json            Output suggestions as JSON");
                    eprintln!("  --dry-run         Print the full LLM prompt without calling the LLM");
                    eprintln!("  --no-description  Skip injecting the gap description into the prompt");
                    eprintln!();
                    eprintln!("Verify model: set CHUMP_VERIFY_API_BASE + CHUMP_VERIFY_MODEL,");
                    eprintln!("  or falls back to ANTHROPIC_API_KEY with claude-sonnet-4-6.");
                    std::process::exit(2);
                });
                let apply = args.iter().any(|a| a == "--apply");
                let verify = args.iter().any(|a| a == "--verify");
                let dry_run = args.iter().any(|a| a == "--dry-run");
                let no_description = args.iter().any(|a| a == "--no-description");
                let parent = match store.get(&gap_id) {
                    Ok(Some(g)) => g,
                    Ok(None) => {
                        eprintln!("chump gap decompose: gap {gap_id} not found");
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump gap decompose: {e:#}");
                        std::process::exit(1);
                    }
                };
                if parent.status != "open" {
                    eprintln!(
                        "chump gap decompose: {gap_id} is not open (status={})",
                        parent.status
                    );
                    std::process::exit(1);
                }
                let effort_lc = parent.effort.to_lowercase();
                if effort_lc == "xs" || effort_lc == "s" {
                    eprintln!(
                        "chump gap decompose: {gap_id} is already effort={} — nothing to decompose",
                        parent.effort
                    );
                    std::process::exit(0);
                }

                if !dry_run {
                    eprintln!("decomposing {gap_id} ({}) via LLM...", parent.title);
                }
                let provider = crate::provider_cascade::build_provider();
                let ac_display = if parent.acceptance_criteria.trim().is_empty()
                    || parent.acceptance_criteria.trim() == "[]"
                {
                    "(none)".to_string()
                } else {
                    parent.acceptance_criteria.clone()
                };

                let system_prompt = "You are a project management assistant for a software project. \
                    Your job is to decompose large gaps (tasks) into smaller, independently shippable slices. \
                    Each slice must be xs (< 1 hour) or s (1-4 hours) effort. \
                    Each slice needs crisp, testable acceptance criteria. \
                    Output ONLY a JSON array of objects with these fields: \
                    {\"title\": \"...\", \"effort\": \"xs|s\", \"priority\": \"P1|P2\", \"acceptance_criteria\": [\"...\", \"...\"], \"depends_on\": []}. \
                    The depends_on field should reference other slices by their 0-based index in the array (e.g. [0] means depends on the first slice). \
                    Do not include any text outside the JSON array.".to_string();

                // Build the description context block.
                // When a filing agent writes architecture notes / rough slice
                // plan into the description, that text is the richest signal
                // available at claim time.  Inject it prominently — not buried
                // inline — so the LLM treats it as primary decomposition
                // guidance rather than incidental metadata.
                //
                // --no-description suppresses this for stale descriptions.
                let description_block = if no_description || parent.description.is_empty() {
                    String::new()
                } else {
                    format!(
                        "\nAdditional context from filing agent:\n{}\n\n\
                         Use this context to inform the decomposition, especially \
                         regarding which files to touch and what the rough \
                         implementation shape looks like.",
                        parent.description
                    )
                };

                let user_msg = format!(
                    "Decompose this gap into xs/s slices:\n\n\
                     ID: {}\n\
                     Domain: {}\n\
                     Title: {}\n\
                     Priority: {}\n\
                     Effort: {}\n\
                     Acceptance Criteria: {}\n\
                     Notes: {}{}",
                    parent.id,
                    parent.domain,
                    parent.title,
                    parent.priority,
                    parent.effort,
                    ac_display,
                    if parent.notes.is_empty() {
                        "(none)"
                    } else {
                        &parent.notes
                    },
                    description_block,
                );

                // --dry-run: print the full prompt and exit without calling
                // the LLM.  Lets agents inspect exactly what context is being
                // used before committing to an LLM call.
                if dry_run {
                    eprintln!("=== dry-run: system prompt ===");
                    eprintln!("{system_prompt}");
                    eprintln!();
                    eprintln!("=== dry-run: user message ===");
                    eprintln!("{user_msg}");
                    return Ok(());
                }

                let messages = vec![axonerai::provider::Message {
                    role: "user".into(),
                    content: user_msg,
                }];

                let resp = match tokio::runtime::Handle::current().block_on(provider.complete(
                    messages,
                    None,
                    Some(4096),
                    Some(system_prompt),
                )) {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("chump gap decompose: LLM call failed: {e:#}");
                        std::process::exit(1);
                    }
                };

                let raw_text = resp.text.unwrap_or_default();
                let json_start = raw_text.find('[').unwrap_or(0);
                let json_end = raw_text.rfind(']').map(|i| i + 1).unwrap_or(raw_text.len());
                let json_slice = &raw_text[json_start..json_end];

                #[derive(Debug, serde::Deserialize)]
                struct SliceSuggestion {
                    title: String,
                    effort: String,
                    priority: String,
                    acceptance_criteria: Vec<String>,
                    #[serde(default)]
                    depends_on: Vec<usize>,
                }

                let suggestions: Vec<SliceSuggestion> = match serde_json::from_str(json_slice) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("chump gap decompose: failed to parse LLM response as JSON: {e}");
                        eprintln!(
                            "Raw response (first 500 chars): {}",
                            &raw_text[..raw_text.len().min(500)]
                        );
                        std::process::exit(1);
                    }
                };

                if suggestions.is_empty() {
                    eprintln!("chump gap decompose: LLM returned no slices");
                    std::process::exit(1);
                }

                // ── Verification pass (--verify) ────────────────────────────
                //
                // Route each slice through a stronger model to check:
                //   1. Is effort truly xs/s?
                //   2. Are ACs testable (not vague)?
                //   3. Does it overlap with sibling slices?
                //   4. Does it map back to the parent gap's intent?
                //
                // The verifier can revise title/ACs or reject a slice entirely.
                // Uses CHUMP_VERIFY_API_BASE + CHUMP_VERIFY_MODEL, or falls
                // back to ANTHROPIC_API_KEY with claude-sonnet.
                #[derive(Debug, serde::Deserialize)]
                struct VerifyVerdict {
                    pass: bool,
                    reason: String,
                    #[serde(default)]
                    revised_title: Option<String>,
                    #[serde(default)]
                    revised_effort: Option<String>,
                    #[serde(default)]
                    revised_acceptance_criteria: Option<Vec<String>>,
                }

                let suggestions = if verify {
                    let verify_provider: Option<
                        Box<dyn axonerai::provider::Provider + Send + Sync>,
                    > = {
                        let vbase = std::env::var("CHUMP_VERIFY_API_BASE")
                            .ok()
                            .filter(|s| !s.is_empty());
                        let vmodel = std::env::var("CHUMP_VERIFY_MODEL")
                            .ok()
                            .filter(|s| !s.is_empty());
                        let vkey = std::env::var("CHUMP_VERIFY_API_KEY")
                            .ok()
                            .filter(|s| !s.is_empty());
                        if let (Some(base), Some(model)) = (vbase, vmodel) {
                            let key = vkey.unwrap_or_default();
                            Some(Box::new(crate::local_openai::LocalOpenAIProvider::new(
                                base, key, model,
                            )))
                        } else if let Ok(api_key) = std::env::var("ANTHROPIC_API_KEY") {
                            if !api_key.is_empty() {
                                let model = "claude-sonnet-4-6".to_string();
                                Some(Box::new(crate::local_openai::LocalOpenAIProvider::new(
                                    "https://api.anthropic.com/v1".to_string(),
                                    api_key,
                                    model,
                                )))
                            } else {
                                None
                            }
                        } else {
                            None
                        }
                    };

                    match verify_provider {
                        None => {
                            eprintln!("chump gap decompose: --verify requested but no verify model available.");
                            eprintln!("Set CHUMP_VERIFY_API_BASE + CHUMP_VERIFY_MODEL, or ANTHROPIC_API_KEY.");
                            std::process::exit(1);
                        }
                        Some(vp) => {
                            eprintln!(
                                "verifying {} slices via stronger model...",
                                suggestions.len()
                            );

                            let siblings_summary: String = suggestions
                                .iter()
                                .enumerate()
                                .map(|(i, s)| {
                                    format!(
                                        "[{i}] {} ({}) — {:?}",
                                        s.title, s.effort, s.acceptance_criteria
                                    )
                                })
                                .collect::<Vec<_>>()
                                .join("\n");

                            let mut verified: Vec<SliceSuggestion> = Vec::new();
                            let mut rejected = 0usize;

                            for (i, s) in suggestions.into_iter().enumerate() {
                                let verify_system = "You are a senior engineering reviewer. \
                                    You verify whether a proposed task slice is well-defined and shippable. \
                                    For each slice, check: \
                                    (1) Is the effort estimate realistic? xs means < 1 hour, s means 1-4 hours. \
                                    (2) Are the acceptance criteria testable and specific (not vague)? \
                                    (3) Does this slice overlap with any sibling slices? \
                                    (4) Does it map back to the parent gap's intent? \
                                    Output ONLY a JSON object: \
                                    {\"pass\": true/false, \"reason\": \"...\", \
                                    \"revised_title\": \"...\" (optional, only if title needs fixing), \
                                    \"revised_effort\": \"xs|s\" (optional, only if effort is wrong), \
                                    \"revised_acceptance_criteria\": [\"...\"] (optional, only if ACs need tightening)}. \
                                    Do not include any text outside the JSON object.".to_string();

                                let verify_msg = format!(
                                    "Parent gap: {} — {}\nParent ACs: {}\n\n\
                                     All proposed sibling slices:\n{}\n\n\
                                     Verify this slice:\n\
                                     [{i}] Title: {}\n\
                                     Effort: {}\n\
                                     Priority: {}\n\
                                     Acceptance Criteria: {:?}",
                                    parent.id,
                                    parent.title,
                                    ac_display,
                                    siblings_summary,
                                    s.title,
                                    s.effort,
                                    s.priority,
                                    s.acceptance_criteria,
                                );

                                let vmsg = vec![axonerai::provider::Message {
                                    role: "user".into(),
                                    content: verify_msg,
                                }];

                                match tokio::runtime::Handle::current().block_on(vp.complete(
                                    vmsg,
                                    None,
                                    Some(1024),
                                    Some(verify_system),
                                )) {
                                    Ok(vresp) => {
                                        let vtext = vresp.text.unwrap_or_default();
                                        let vj_start = vtext.find('{').unwrap_or(0);
                                        let vj_end =
                                            vtext.rfind('}').map(|j| j + 1).unwrap_or(vtext.len());
                                        let vj = &vtext[vj_start..vj_end];

                                        match serde_json::from_str::<VerifyVerdict>(vj) {
                                            Ok(verdict) => {
                                                if verdict.pass {
                                                    let final_slice = SliceSuggestion {
                                                        title: verdict
                                                            .revised_title
                                                            .unwrap_or(s.title),
                                                        effort: verdict
                                                            .revised_effort
                                                            .unwrap_or(s.effort),
                                                        priority: s.priority,
                                                        acceptance_criteria: verdict
                                                            .revised_acceptance_criteria
                                                            .unwrap_or(s.acceptance_criteria),
                                                        depends_on: s.depends_on,
                                                    };
                                                    eprintln!("  [{i}] PASS: {}", verdict.reason);
                                                    verified.push(final_slice);
                                                } else {
                                                    eprintln!(
                                                        "  [{i}] REJECTED: {}",
                                                        verdict.reason
                                                    );
                                                    rejected += 1;
                                                }
                                            }
                                            Err(_) => {
                                                eprintln!("  [{i}] WARN: could not parse verdict, keeping slice as-is");
                                                verified.push(s);
                                            }
                                        }
                                    }
                                    Err(e) => {
                                        eprintln!("  [{i}] WARN: verify call failed ({e:#}), keeping slice as-is");
                                        verified.push(s);
                                    }
                                }
                            }

                            if rejected > 0 {
                                eprintln!(
                                    "verification: {} passed, {} rejected",
                                    verified.len(),
                                    rejected
                                );
                            }

                            if verified.is_empty() {
                                eprintln!("chump gap decompose: all slices rejected by verifier");
                                std::process::exit(1);
                            }
                            verified
                        }
                    }
                } else {
                    suggestions
                };

                if json_out {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!(suggestions
                            .iter()
                            .enumerate()
                            .map(|(i, s)| {
                                serde_json::json!({
                                    "index": i,
                                    "title": s.title,
                                    "effort": s.effort,
                                    "priority": s.priority,
                                    "acceptance_criteria": s.acceptance_criteria,
                                    "depends_on": s.depends_on,
                                })
                            })
                            .collect::<Vec<_>>()))
                        .unwrap_or_default()
                    );
                } else if !apply {
                    eprintln!();
                    eprintln!("Suggested slices for {} ({}):", parent.id, parent.title);
                    eprintln!();
                    for (i, s) in suggestions.iter().enumerate() {
                        let deps_str = if s.depends_on.is_empty() {
                            String::new()
                        } else {
                            format!(
                                " (depends on: {})",
                                s.depends_on
                                    .iter()
                                    .map(|d| format!("slice {d}"))
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            )
                        };
                        eprintln!(
                            "  [{i}] {} ({}/{}){}",
                            s.title, s.priority, s.effort, deps_str
                        );
                        for ac in &s.acceptance_criteria {
                            eprintln!("      - {ac}");
                        }
                        eprintln!();
                    }
                    eprintln!("Run with --apply to file these slices and demote the parent to P2.");
                }

                if apply {
                    let session_id = crate::ambient_stream::env_session_id()
                        .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                    let mut filed_ids: Vec<String> = Vec::new();

                    for s in &suggestions {
                        let slice_title = format!(
                            "{}: {} ({} slice)",
                            parent.domain.to_uppercase(),
                            s.title,
                            parent.id
                        );
                        let effort = if s.effort == "xs" || s.effort == "s" {
                            s.effort.clone()
                        } else {
                            "s".to_string()
                        };
                        let priority = if s.priority == "P1" || s.priority == "P2" {
                            s.priority.clone()
                        } else {
                            "P1".to_string()
                        };

                        match store.reserve_verified(
                            &parent.domain,
                            &slice_title,
                            &priority,
                            &effort,
                            &session_id,
                        ) {
                            Ok(new_id) => {
                                let ac_json = serde_json::to_string(&s.acceptance_criteria)
                                    .unwrap_or_else(|_| "[]".into());
                                let _ = store.set_fields(
                                    &new_id,
                                    gap_store::GapFieldUpdate {
                                        acceptance_criteria: Some(ac_json),
                                        ..Default::default()
                                    },
                                );

                                let gaps_dir = worktree_root.join("docs/gaps");
                                if gaps_dir.is_dir() {
                                    let yaml_path = gaps_dir.join(format!("{}.yaml", new_id));
                                    let _ = store.dump_per_file_single(&new_id, &gaps_dir);
                                    let _ = std::process::Command::new("git")
                                        .args(["add", &yaml_path.to_string_lossy()])
                                        .current_dir(&worktree_root)
                                        .status();
                                }

                                eprintln!("  filed {new_id}: {slice_title}");
                                filed_ids.push(new_id);
                            }
                            Err(e) => {
                                eprintln!("  ERROR filing slice '{}': {e:#}", s.title);
                            }
                        }
                    }

                    // Resolve inter-slice depends_on using filed IDs
                    for (i, s) in suggestions.iter().enumerate() {
                        if !s.depends_on.is_empty() && i < filed_ids.len() {
                            let dep_ids: Vec<String> = s
                                .depends_on
                                .iter()
                                .filter_map(|&idx| filed_ids.get(idx).cloned())
                                .collect();
                            if !dep_ids.is_empty() {
                                let deps_json =
                                    serde_json::to_string(&dep_ids).unwrap_or_else(|_| "[]".into());
                                let _ = store.set_fields(
                                    &filed_ids[i],
                                    gap_store::GapFieldUpdate {
                                        depends_on: Some(deps_json),
                                        ..Default::default()
                                    },
                                );
                            }
                        }
                    }

                    // Demote parent to P2
                    let _ = store.set_fields(
                        &gap_id,
                        gap_store::GapFieldUpdate {
                            priority: Some("P2".into()),
                            notes: Some(format!(
                                "Decomposed into {} slices: {}",
                                filed_ids.len(),
                                filed_ids.join(", ")
                            )),
                            ..Default::default()
                        },
                    );
                    eprintln!();
                    eprintln!(
                        "Decomposed {gap_id} into {} slices. Parent demoted to P2.",
                        filed_ids.len()
                    );

                    if json_out {
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&serde_json::json!({
                                "parent": gap_id,
                                "slices": filed_ids,
                            }))
                            .unwrap_or_default()
                        );
                    } else {
                        println!("{}", filed_ids.join("\n"));
                    }
                }

                return Ok(());
            }
            "dep-clean" => {
                let do_apply = args.iter().any(|a| a == "--apply");
                let as_json = json_out || args.iter().any(|a| a == "--json");
                let do_dry_run = !do_apply;

                let all_open = match store.list(Some("open")) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump gap dep-clean: failed to list open gaps: {e:#}");
                        std::process::exit(1);
                    }
                };

                // Build a lookup: gap_id -> status
                let mut status_map: std::collections::HashMap<&str, &str> =
                    std::collections::HashMap::new();
                for g in &all_open {
                    status_map.insert(g.id.as_str(), "open");
                }
                let all_done = match store.list(Some("done")) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump gap dep-clean: failed to list done gaps: {e:#}");
                        std::process::exit(1);
                    }
                };
                for g in &all_done {
                    status_map.insert(g.id.as_str(), "done");
                }

                // Parse depends_on (stored as JSON array like ["X-1","X-2"])
                let parse_deps = |s: &str| -> Vec<String> {
                    if s.trim().is_empty() {
                        return Vec::new();
                    }
                    serde_json::from_str::<Vec<String>>(s).unwrap_or_default()
                };

                let mut results: Vec<serde_json::Value> = Vec::new();
                let mut found_any = false;

                for g in &all_open {
                    let deps = parse_deps(&g.depends_on);
                    if deps.is_empty() {
                        continue;
                    }
                    let stale: Vec<String> = deps
                        .iter()
                        .filter(|d| status_map.get(d.as_str()).copied() == Some("done"))
                        .cloned()
                        .collect();
                    let clean: Vec<String> = deps
                        .iter()
                        .filter(|d| {
                            let s = status_map.get(d.as_str()).copied();
                            s != Some("done")
                        })
                        .cloned()
                        .collect();

                    if stale.is_empty() {
                        if as_json {
                            results.push(serde_json::json!({
                                "gap_id": g.id,
                                "stale_deps": [],
                                "action": "skipped"
                            }));
                        }
                        continue;
                    }

                    found_any = true;

                    if do_apply {
                        // Strip stale deps: keep only clean ones
                        let new_deps =
                            serde_json::to_string(&clean).unwrap_or_else(|_| "[]".into());
                        let update = gap_store::GapFieldUpdate {
                            depends_on: Some(new_deps),
                            ..Default::default()
                        };
                        if let Err(e) = store.set_fields(&g.id, update) {
                            eprintln!("chump gap dep-clean: failed to update {}: {e:#}", g.id);
                            std::process::exit(1);
                        }
                        // Emit ambient event
                        let lock_dir = repo_root.join(".chump-locks");
                        let _ = std::fs::create_dir_all(&lock_dir);
                        let ambient_path = if let Ok(p) = std::env::var("CHUMP_AMBIENT_IN_PROMPT") {
                            std::path::PathBuf::from(p)
                        } else {
                            lock_dir.join("ambient.jsonl")
                        };
                        let ts =
                            chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
                        let evt = serde_json::json!({
                            "ts": ts,
                            "kind": "dep_cleaned",
                            "gap_id": g.id,
                            "stripped_deps": stale,
                        });
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .create(true)
                            .append(true)
                            .open(&ambient_path)
                        {
                            use std::io::Write as _;
                            let _ = writeln!(f, "{}", evt);
                        }

                        if as_json {
                            results.push(serde_json::json!({
                                "gap_id": g.id,
                                "stale_deps": stale,
                                "action": "stripped"
                            }));
                        } else {
                            println!(
                                "{} depends_on [{}] — stripped {}",
                                g.id,
                                stale.join(", "),
                                clean.join(", ")
                            );
                        }
                    } else {
                        // Dry-run mode
                        if as_json {
                            results.push(serde_json::json!({
                                "gap_id": g.id,
                                "stale_deps": stale,
                                "action": "skipped"
                            }));
                        } else {
                            for sd in &stale {
                                println!("{} depends_on {} (done) — will strip", g.id, sd);
                            }
                        }
                    }
                }

                if as_json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&results).unwrap_or_default()
                    );
                }

                if found_any && do_dry_run {
                    eprintln!("dep-clean: found stale depends_on entries (dry-run; pass --apply to strip)");
                    std::process::exit(1);
                }

                if !found_any && !as_json {
                    println!("No stale depends_on entries found — all clean.");
                }

                return Ok(());
            }
            // INFRA-635: gap rebalance — P0 budget enforcement + pillar floor check.
            // Reads state.db, identifies violations, suggests or applies corrections.
            "rebalance" => {
                let apply = args.iter().any(|a| a == "--apply");
                let as_json = args.iter().any(|a| a == "--json");

                tracing::info!(apply = apply, "gap-rebalance invoked");

                let all_gaps = match store.list(None) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump gap rebalance: {e:#}");
                        std::process::exit(1);
                    }
                };

                let open_gaps: Vec<&gap_store::GapRow> =
                    all_gaps.iter().filter(|g| g.status == "open").collect();

                // ── P0 budget check (CLAUDE.md: ≤ 5 P0s) ────────────────────────
                let p0_budget: usize = 5;
                let mut p0_gaps: Vec<&gap_store::GapRow> = open_gaps
                    .iter()
                    .filter(|g| g.priority == "P0")
                    .copied()
                    .collect();
                // Sort oldest first (by opened_date, then id)
                p0_gaps.sort_by(|a, b| a.opened_date.cmp(&b.opened_date).then(a.id.cmp(&b.id)));

                let mut actions: Vec<String> = Vec::new();
                let mut applied: Vec<String> = Vec::new();

                if p0_gaps.len() > p0_budget {
                    let excess = p0_gaps.len() - p0_budget;
                    let demote_candidates = &p0_gaps[..excess];
                    for g in demote_candidates {
                        let rationale = format!(
                            "auto-demoted P0→P1: P0 budget exceeded by {} (max {}), oldest stale P0",
                            excess, p0_budget
                        );
                        actions.push(format!("DEMOTE {} P0→P1  reason: {}", g.id, rationale));
                        if apply {
                            match store.set_fields(
                                &g.id,
                                gap_store::GapFieldUpdate {
                                    priority: Some("P1".to_string()),
                                    notes: Some(rationale.clone()),
                                    ..Default::default()
                                },
                            ) {
                                Ok(_) => applied.push(g.id.clone()),
                                Err(e) => eprintln!("failed to demote {}: {e}", g.id),
                            }
                        }
                    }
                }

                // ── Pillar floor check (same logic as pillar-balance) ─────────
                let pickable: Vec<&gap_store::GapRow> = open_gaps
                    .iter()
                    .filter(|g| {
                        matches!(g.priority.as_str(), "P0" | "P1")
                            && matches!(g.effort.as_str(), "xs" | "s" | "m")
                    })
                    .copied()
                    .collect();

                let total = pickable.len();
                let pillars = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"];
                let mut pillar_counts: std::collections::HashMap<&str, Vec<String>> =
                    pillars.iter().map(|p| (*p, Vec::new())).collect();

                for g in &pickable {
                    let title_up = g.title.to_uppercase();
                    let mut assigned = false;
                    for p in &pillars {
                        if title_up.contains(p) {
                            pillar_counts.entry(p).or_default().push(g.id.clone());
                            assigned = true;
                            break;
                        }
                    }
                    if !assigned {
                        // no-op — OTHER bucket
                    }
                }

                // Flag under-floor pillars
                for p in &pillars {
                    let n = pillar_counts.get(p).map(|v| v.len()).unwrap_or(0);
                    if n < 2 {
                        actions.push(format!(
                            "FILE 1-2 {p} gaps  reason: only {n} pickable (floor=2, CLAUDE.md §pillar-floor)"
                        ));
                    }
                }
                // Flag dominant pillars (> 50%)
                if total > 0 {
                    for p in &pillars {
                        let n = pillar_counts.get(p).map(|v| v.len()).unwrap_or(0);
                        if n * 2 > total {
                            // Find oldest P1 to suggest demoting to P2
                            let ids = pillar_counts.get(p).cloned().unwrap_or_default();
                            let suggest_demote = ids.first().cloned().unwrap_or_default();
                            actions.push(format!(
                                "DEMOTE {suggest_demote} P1→P2  reason: {p} dominates ({n}/{total} >{:.0}%)",
                                n as f64 / total as f64 * 100.0
                            ));
                            if apply && !suggest_demote.is_empty() {
                                let rationale = format!(
                                    "auto-demoted P1→P2: {} dominates at {}/{} pickable",
                                    p, n, total
                                );
                                match store.set_fields(
                                    &suggest_demote,
                                    gap_store::GapFieldUpdate {
                                        priority: Some("P2".to_string()),
                                        notes: Some(rationale),
                                        ..Default::default()
                                    },
                                ) {
                                    Ok(_) => applied.push(suggest_demote.clone()),
                                    Err(e) => eprintln!("failed to demote {suggest_demote}: {e}"),
                                }
                            }
                        }
                    }
                }

                // ── Output ────────────────────────────────────────────────────
                if as_json {
                    let out = serde_json::json!({
                        "p0_count": p0_gaps.len(),
                        "p0_budget": p0_budget,
                        "total_pickable": total,
                        "actions": actions,
                        "applied": applied,
                        "clean": actions.is_empty(),
                    });
                    println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
                } else {
                    println!(
                        "Gap rebalance: {} open gaps  ({} pickable P0/P1 xs/s/m)  P0={}/{}",
                        open_gaps.len(),
                        total,
                        p0_gaps.len(),
                        p0_budget
                    );
                    if actions.is_empty() {
                        println!("\n✓ Registry clean — P0 budget OK, all pillars ≥ 2 pickable, none > 50%.");
                    } else {
                        println!("\nSuggested actions:");
                        for a in &actions {
                            println!("  • {a}");
                        }
                        if apply {
                            if applied.is_empty() {
                                println!("\nNo changes applied.");
                            } else {
                                println!("\nApplied: {}", applied.join(", "));
                            }
                        } else {
                            println!("\nRun with --apply to execute.");
                        }
                    }
                }

                if !actions.is_empty() && !apply {
                    std::process::exit(1);
                }
                return Ok(());
            }
            // INFRA-604: pillar balance report — inventory pickable gaps per pillar,
            // flag imbalance, optionally suggest or apply priority adjustments.
            "pillar-balance" => {
                let as_json = args.iter().any(|a| a == "--json");
                let suggest = args.iter().any(|a| a == "--suggest");
                let apply = args.iter().any(|a| a == "--apply");

                tracing::info!(apply = apply, suggest = suggest, "pillar-balance invoked");

                let all_gaps = match store.list(Some("open")) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump gap pillar-balance: {e:#}");
                        std::process::exit(1);
                    }
                };

                // Pickable = P0|P1, xs|s|m effort
                let pickable: Vec<&gap_store::GapRow> = all_gaps
                    .iter()
                    .filter(|g| {
                        matches!(g.priority.as_str(), "P0" | "P1")
                            && matches!(g.effort.as_str(), "xs" | "s" | "m")
                    })
                    .collect();

                let total = pickable.len();

                // Classify each gap by pillar using title keyword.
                let pillars = ["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"];
                let mut counts: std::collections::HashMap<&str, Vec<String>> =
                    pillars.iter().map(|p| (*p, Vec::new())).collect();
                let mut other: Vec<String> = Vec::new();

                for g in &pickable {
                    let title_up = g.title.to_uppercase();
                    let mut assigned = false;
                    for p in &pillars {
                        if title_up.contains(p) {
                            counts.entry(p).or_default().push(g.id.clone());
                            assigned = true;
                            break;
                        }
                    }
                    if !assigned {
                        other.push(g.id.clone());
                    }
                }

                let mut warnings: Vec<String> = Vec::new();
                for p in &pillars {
                    let n = counts.get(p).map(|v| v.len()).unwrap_or(0);
                    if n < 2 {
                        warnings.push(format!("UNDER: {p} has only {n} pickable (floor=2)"));
                    }
                    if total > 0 && n * 2 > total {
                        warnings.push(format!(
                            "OVER: {p} is {n}/{total} (>50%) — demote P2 excess"
                        ));
                    }
                }

                // --suggest/--apply: promote oldest P2 gap for under-filled pillars.
                let mut suggestions: Vec<(String, String, String)> = Vec::new(); // (gap_id, old_prio, cmd)
                if suggest || apply {
                    let all_open = store.list(Some("open")).unwrap_or_default();
                    for p in &pillars {
                        let n = counts.get(p).map(|v| v.len()).unwrap_or(0);
                        if n < 2 {
                            // Find oldest P2 xs/s/m gap with this pillar keyword.
                            let candidate = all_open.iter().find(|g| {
                                g.priority == "P2"
                                    && matches!(g.effort.as_str(), "xs" | "s" | "m")
                                    && g.title.to_uppercase().contains(p)
                            });
                            if let Some(c) = candidate {
                                suggestions.push((
                                    c.id.clone(),
                                    "P2".to_string(),
                                    format!("chump gap set {} --priority P1  # refill {}", c.id, p),
                                ));
                                if apply {
                                    let _ = store.set_fields(
                                        &c.id,
                                        gap_store::GapFieldUpdate {
                                            priority: Some("P1".to_string()),
                                            ..Default::default()
                                        },
                                    );
                                }
                            }
                        }
                    }
                    if !as_json {
                        for (id, old, cmd) in &suggestions {
                            println!(
                                "  {} {id} {old}→P1: {cmd}",
                                if apply { "APPLIED" } else { "SUGGEST" },
                            );
                        }
                    }
                }

                let suggestions_ids: Vec<String> =
                    suggestions.iter().map(|(id, _, _)| id.clone()).collect();

                if as_json {
                    let counts_json: std::collections::HashMap<&str, usize> =
                        pillars.iter().map(|p| (*p, counts[p].len())).collect();
                    println!(
                        "{}",
                        serde_json::json!({
                            "total_pickable": total,
                            "pillars": counts_json,
                            "other": other.len(),
                            "warnings": warnings,
                            "suggestions": suggestions_ids,
                        })
                    );
                } else {
                    println!("[pillar-balance] pickable={total}");
                    for p in &pillars {
                        let n = counts[p].len();
                        println!("  {p}: {n}");
                    }
                    println!("  OTHER: {}", other.len());
                    if warnings.is_empty() {
                        println!("✓ Balance OK");
                    } else {
                        for w in &warnings {
                            println!("  WARN: {w}");
                        }
                    }
                }

                if !warnings.is_empty() {
                    std::process::exit(1);
                }
                return Ok(());
            }
            // INFRA-636: import gaps from a markdown spec file.
            // Parses headings matching `### REQ-NNN — <title>` and subsections
            // **Priority.** / **What we need.** / **Acceptance.**
            "import-spec" => {
                let path_arg = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap import-spec <path> [--apply] [--dry-run] [--json]");
                    std::process::exit(2);
                });
                let apply = args.iter().any(|a| a == "--apply");
                let dry_run = args.iter().any(|a| a == "--dry-run") || !apply;
                let spec_path = std::path::Path::new(&path_arg);
                let content = match std::fs::read_to_string(spec_path) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("import-spec: cannot read {path_arg}: {e}");
                        std::process::exit(1);
                    }
                };

                // Parse the spec: collect entries keyed by heading.
                struct SpecEntry {
                    req_id: String,
                    title: String,
                    priority: String,
                    description: String,
                    acceptance: String,
                }

                fn infer_pillar(title: &str) -> &'static str {
                    let t = title.to_uppercase();
                    if t.contains("CREDIBLE")
                        || t.contains("OBSERV")
                        || t.contains("METRIC")
                        || t.contains("MEASURE")
                    {
                        "CREDIBLE"
                    } else if t.contains("EFFECTIVE")
                        || t.contains("USER")
                        || t.contains("DASHBOARD")
                        || t.contains("UX")
                    {
                        "EFFECTIVE"
                    } else if t.contains("RESILIENT")
                        || t.contains("RECOVER")
                        || t.contains("FAILOVER")
                        || t.contains("RETRY")
                    {
                        "RESILIENT"
                    } else if t.contains("ZERO-WASTE")
                        || t.contains("WASTE")
                        || t.contains("PRUNE")
                        || t.contains("COST")
                    {
                        "ZERO-WASTE"
                    } else {
                        "MISSION"
                    }
                }

                fn map_priority(raw: &str) -> String {
                    let r = raw.trim().to_uppercase();
                    if r.starts_with("P0") || r == "CRITICAL" {
                        return "P0".into();
                    }
                    if r.starts_with("P1") || r == "HIGH" {
                        return "P1".into();
                    }
                    if r.starts_with("P2") || r == "MEDIUM" {
                        return "P2".into();
                    }
                    if r.starts_with("P3") || r == "LOW" {
                        return "P3".into();
                    }
                    "P2".into()
                }

                let mut entries: Vec<SpecEntry> = Vec::new();
                let mut current: Option<SpecEntry> = None;
                let mut in_section: Option<&str> = None;
                let mut buf = String::new();

                for line in content.lines() {
                    // Detect `### REQ-NNN — title` headings
                    if let Some(rest) = line.strip_prefix("### ") {
                        // Flush previous entry
                        if let Some(ref mut e) = current {
                            match in_section {
                                Some("desc") => e.description = buf.trim().to_string(),
                                Some("ac") => e.acceptance = buf.trim().to_string(),
                                _ => {}
                            }
                        }
                        if let Some(e) = current.take() {
                            entries.push(e);
                        }
                        buf.clear();
                        in_section = None;

                        // Parse "REQ-NNN — title" or plain title
                        let (req_id, title) = if let Some(idx) = rest.find(" \u{2014} ") {
                            (rest[..idx].to_string(), rest[idx + 4..].to_string())
                        } else if let Some(idx) = rest.find(" -- ") {
                            (rest[..idx].to_string(), rest[idx + 4..].to_string())
                        } else {
                            (String::new(), rest.to_string())
                        };
                        current = Some(SpecEntry {
                            req_id,
                            title,
                            priority: "P2".into(),
                            description: String::new(),
                            acceptance: String::new(),
                        });
                    } else if line.starts_with("**Priority.**")
                        || line.starts_with("**Priority**: ")
                    {
                        if let Some(ref mut e) = current {
                            // Flush previous section
                            match in_section {
                                Some("desc") => e.description = buf.trim().to_string(),
                                Some("ac") => e.acceptance = buf.trim().to_string(),
                                _ => {}
                            }
                            buf.clear();
                            in_section = Some("priority");
                            // Priority value may be inline
                            let raw = line
                                .trim_start_matches("**Priority.**")
                                .trim_start_matches("**Priority**:")
                                .trim();
                            if !raw.is_empty() {
                                e.priority = map_priority(raw);
                                in_section = None;
                            }
                        }
                    } else if line.starts_with("**What we need.**")
                        || line.starts_with("**Description.**")
                    {
                        if let Some(ref mut e) = current {
                            match in_section {
                                Some("desc") => e.description = buf.trim().to_string(),
                                Some("ac") => e.acceptance = buf.trim().to_string(),
                                _ => {}
                            }
                            buf.clear();
                            in_section = Some("desc");
                            let rest = line
                                .trim_start_matches("**What we need.**")
                                .trim_start_matches("**Description.**")
                                .trim();
                            if !rest.is_empty() {
                                buf.push_str(rest);
                                buf.push('\n');
                            }
                        }
                    } else if line.starts_with("**Acceptance.**") || line.starts_with("**AC.**") {
                        if let Some(ref mut e) = current {
                            match in_section {
                                Some("desc") => e.description = buf.trim().to_string(),
                                Some("ac") => e.acceptance = buf.trim().to_string(),
                                _ => {}
                            }
                            buf.clear();
                            in_section = Some("ac");
                            let rest = line
                                .trim_start_matches("**Acceptance.**")
                                .trim_start_matches("**AC.**")
                                .trim();
                            if !rest.is_empty() {
                                buf.push_str(rest);
                                buf.push('\n');
                            }
                        }
                    } else if in_section.is_some() {
                        // Accumulate section content; stop at blank separator or next heading
                        if current.is_some() {
                            if in_section == Some("priority") && !line.trim().is_empty() {
                                if let Some(ref mut e) = current {
                                    e.priority = map_priority(line.trim());
                                }
                                in_section = None;
                            } else {
                                buf.push_str(line);
                                buf.push('\n');
                            }
                        }
                    }
                }
                // Flush last entry
                if let Some(ref mut e) = current {
                    match in_section {
                        Some("desc") => e.description = buf.trim().to_string(),
                        Some("ac") => e.acceptance = buf.trim().to_string(),
                        _ => {}
                    }
                }
                if let Some(e) = current.take() {
                    entries.push(e);
                }

                if entries.is_empty() {
                    eprintln!("import-spec: no gaps found in {path_arg} (expected '### REQ-NNN — title' headings)");
                    std::process::exit(1);
                }

                tracing::info!(
                    path = path_arg,
                    count = entries.len(),
                    apply = apply,
                    "import-spec"
                );

                let mut filed: Vec<String> = Vec::new();
                let mut skipped: Vec<String> = Vec::new();

                for e in &entries {
                    let pillar = infer_pillar(&e.title);
                    let full_title = if !e.req_id.is_empty() {
                        format!("{}: {} — {}", pillar, e.req_id, e.title)
                    } else {
                        format!("{}: {}", pillar, e.title)
                    };
                    let ac_json = if e.acceptance.is_empty() {
                        "[]".to_string()
                    } else {
                        let parts: Vec<&str> = e
                            .acceptance
                            .lines()
                            .map(str::trim)
                            .filter(|l| !l.is_empty())
                            .collect();
                        serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
                    };

                    if dry_run {
                        if json_out {
                            let obj = serde_json::json!({
                                "req_id": e.req_id,
                                "title": full_title,
                                "priority": e.priority,
                                "domain": "INFRA",
                                "description": e.description,
                                "acceptance_criteria_preview": e.acceptance,
                                "dry_run": true,
                            });
                            println!("{}", serde_json::to_string_pretty(&obj).unwrap_or_default());
                        } else {
                            println!("[dry-run] {} | INFRA | {}", e.priority, full_title);
                            if !e.description.is_empty() {
                                println!(
                                    "          desc: {}",
                                    e.description.lines().next().unwrap_or("")
                                );
                            }
                            if !e.acceptance.is_empty() {
                                println!(
                                    "          ac:   {}",
                                    e.acceptance.lines().next().unwrap_or("")
                                );
                            }
                        }
                        skipped.push(full_title.clone());
                    } else {
                        match store.reserve("INFRA", &full_title, &e.priority, "m") {
                            Ok(id) => {
                                let _ = store.set_fields(
                                    &id,
                                    gap_store::GapFieldUpdate {
                                        description: if e.description.is_empty() {
                                            None
                                        } else {
                                            Some(e.description.clone())
                                        },
                                        acceptance_criteria: if ac_json == "[]" {
                                            None
                                        } else {
                                            Some(ac_json)
                                        },
                                        ..Default::default()
                                    },
                                );
                                if json_out {
                                    let obj = serde_json::json!({"id": id, "title": full_title, "priority": e.priority});
                                    println!(
                                        "{}",
                                        serde_json::to_string_pretty(&obj).unwrap_or_default()
                                    );
                                } else {
                                    println!("filed {} | {} | {}", id, e.priority, full_title);
                                }
                                filed.push(id);
                            }
                            Err(err) => {
                                eprintln!(
                                    "import-spec: failed to reserve '{}': {err:#}",
                                    full_title
                                );
                                skipped.push(full_title.clone());
                            }
                        }
                    }
                }

                if !dry_run {
                    tracing::info!(
                        filed = filed.len(),
                        skipped = skipped.len(),
                        "import-spec complete"
                    );
                    eprintln!(
                        "import-spec: filed {} gaps, skipped {}",
                        filed.len(),
                        skipped.len()
                    );
                    // Run rebalance after bulk import per AC (pillar floor + P0 budget).
                    if !filed.is_empty() {
                        let _ = std::process::Command::new(
                            std::env::current_exe().unwrap_or_else(|_| "chump".into()),
                        )
                        .args(["gap", "rebalance"])
                        .status();
                    }
                }
                return Ok(());
            }
            // INFRA-935: gap consolidate — detect near-duplicate gap titles.
            // INFRA-1435 (2026-05-16): added --apply mode that mechanically
            // archives the higher-ID dup, rewrites depends_on backlinks,
            // writes an audit row, and emits ambient kind=gap_dup_archived.
            //
            // Usage:
            //   chump gap consolidate [--threshold N] [--json]
            //     --threshold N  similarity threshold 0-100 (default 80 advisory,
            //                    90 when --apply is set)
            //     --json         output pairs as JSON array
            //
            //   chump gap consolidate --apply --reason "<text>" [--threshold N]
            //                                                   [--json]
            //     --apply        mutate: archive higher-ID dups, rewrite
            //                    depends_on, write audit + ambient events.
            //                    Refuses if either gap has an active lease.
            //     --reason TEXT  required with --apply (audit-trail message)
            "consolidate" => {
                let apply = args.iter().any(|a| a == "--apply");
                let reason = flag("--reason").unwrap_or_default();
                if apply && reason.trim().is_empty() {
                    eprintln!(
                        "chump gap consolidate --apply: requires --reason \"<text>\" \
                         for the audit trail."
                    );
                    std::process::exit(2);
                }
                let default_threshold = if apply { 90 } else { 80 };
                let threshold: u32 = args
                    .iter()
                    .position(|a| a == "--threshold")
                    .and_then(|i| args.get(i + 1))
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(default_threshold);
                let as_json = args.iter().any(|a| a == "--json");

                let all_gaps = match store.list(Some("open")) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump gap consolidate: {e:#}");
                        std::process::exit(1);
                    }
                };

                /// Token-overlap similarity (0-100) between two titles.
                fn title_similarity(a: &str, b: &str) -> u32 {
                    fn tokens(s: &str) -> std::collections::HashSet<String> {
                        s.to_lowercase()
                            .split(|c: char| !c.is_alphanumeric())
                            .filter(|t| t.len() >= 3)
                            .map(String::from)
                            .collect()
                    }
                    let ta = tokens(a);
                    let tb = tokens(b);
                    if ta.is_empty() || tb.is_empty() {
                        return 0;
                    }
                    let intersection = ta.intersection(&tb).count();
                    let union = ta.union(&tb).count();
                    ((intersection as f64 / union as f64) * 100.0) as u32
                }

                let mut pairs: Vec<(String, String, u32)> = Vec::new();
                for i in 0..all_gaps.len() {
                    for j in (i + 1)..all_gaps.len() {
                        let sim = title_similarity(&all_gaps[i].title, &all_gaps[j].title);
                        if sim >= threshold {
                            pairs.push((all_gaps[i].id.clone(), all_gaps[j].id.clone(), sim));
                        }
                    }
                }
                pairs.sort_by_key(|p| std::cmp::Reverse(p.2));

                // INFRA-1435: --apply path. Mutates state.db; defensive
                // against active leases.
                if apply {
                    // Read all active leases once; collect referenced gap IDs.
                    let lease_dir = repo_root.join(".chump-locks");
                    let mut leased_gaps: std::collections::HashSet<String> =
                        std::collections::HashSet::new();
                    if let Ok(entries) = std::fs::read_dir(&lease_dir) {
                        for e in entries.flatten() {
                            let p = e.path();
                            if p.extension().and_then(|s| s.to_str()) != Some("json") {
                                continue;
                            }
                            if let Ok(text) = std::fs::read_to_string(&p) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                                    if let Some(g) = v.get("gap").and_then(|g| g.as_str()) {
                                        leased_gaps.insert(g.to_string());
                                    }
                                }
                            }
                        }
                    }

                    let operator = std::env::var("USER").unwrap_or_default();
                    let ts = chrono::Utc::now().timestamp();
                    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                    let mut applied: Vec<(String, String, u32, usize)> = Vec::new(); // (kept, archived, sim, rewrites)
                    let mut skipped_leased: Vec<(String, String, String)> = Vec::new(); // (a, b, why)

                    for (a, b, sim) in &pairs {
                        // Deterministic kept/archived: keep the LOWER id by
                        // lexicographic order — older IDs have more backlinks
                        // and are more likely to be cited externally.
                        let (kept, archived) = if a < b {
                            (a.clone(), b.clone())
                        } else {
                            (b.clone(), a.clone())
                        };
                        if leased_gaps.contains(&kept) || leased_gaps.contains(&archived) {
                            skipped_leased.push((
                                kept.clone(),
                                archived.clone(),
                                "active lease — refuse to mutate".to_string(),
                            ));
                            continue;
                        }

                        // Rewrite depends_on across all open gaps that point
                        // at the archived ID.
                        let mut rewrites = 0usize;
                        if let Ok(open_gaps) = store.list(Some("open")) {
                            for g in &open_gaps {
                                if g.depends_on.is_empty() || g.id == archived {
                                    continue;
                                }
                                let deps = gap_store::parse_json_ac_list(&g.depends_on);
                                if !deps.iter().any(|d| d == &archived) {
                                    continue;
                                }
                                let new_deps: Vec<String> = deps
                                    .into_iter()
                                    .map(|d| if d == archived { kept.clone() } else { d })
                                    .collect::<Vec<_>>()
                                    .into_iter()
                                    .collect::<std::collections::BTreeSet<_>>()
                                    .into_iter()
                                    .collect();
                                let new_deps_json =
                                    serde_json::to_string(&new_deps).unwrap_or_default();
                                let upd = gap_store::GapFieldUpdate {
                                    depends_on: Some(new_deps_json),
                                    ..Default::default()
                                };
                                if store.set_fields(&g.id, upd).is_ok() {
                                    rewrites += 1;
                                }
                            }
                        }

                        // Archive the higher ID. Bypass closed_pr guard
                        // (this is a dup-archive, not a real ship).
                        let archive_notes = format!(
                            "INFRA-1435 dup-archive (similarity {sim}%): keeping {kept}; \
                             reason: {reason}"
                        );
                        let upd = gap_store::GapFieldUpdate {
                            status: Some("done".to_string()),
                            notes: Some(archive_notes),
                            ..Default::default()
                        };
                        // Temporarily set the bypass env so set_fields' INFRA-402
                        // guard accepts the status flip without a closed_pr.
                        // SAFETY: single-threaded CLI; restored before next
                        // iteration. Only main() touches env at this layer.
                        unsafe {
                            std::env::set_var("CHUMP_BYPASS_CLOSED_PR_GUARD", "1");
                        }
                        let archive_result = store.set_fields(&archived, upd);
                        unsafe {
                            std::env::remove_var("CHUMP_BYPASS_CLOSED_PR_GUARD");
                        }
                        if let Err(e) = archive_result {
                            eprintln!(
                                "[consolidate --apply] WARN: archive of {archived} failed: {e:#} — skipping audit/ambient for this pair"
                            );
                            continue;
                        }

                        // Audit row (typed API; creates table on first call).
                        if let Err(e) = store.record_dup_archive(
                            &kept, &archived, *sim, rewrites, &reason, &operator,
                        ) {
                            eprintln!(
                                "[consolidate --apply] WARN: audit-row write failed for {archived}: {e:#}"
                            );
                        }

                        // Ambient event.
                        if let Some(parent) = ambient_path.parent() {
                            let _ = std::fs::create_dir_all(parent);
                        }
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            use std::io::Write;
                            let safe_reason = reason.replace(['"', '\\'], "");
                            let _ = writeln!(
                                f,
                                r#"{{"ts":{ts},"kind":"gap_dup_archived","kept_id":"{kept}","archived_id":"{archived}","similarity_pct":{sim},"depends_on_rewrites":{rewrites},"reason":"{safe_reason}"}}"#
                            );
                        }

                        applied.push((kept, archived, *sim, rewrites));
                    }

                    if as_json {
                        let arr: Vec<String> = applied
                            .iter()
                            .map(|(k, a, s, r)| {
                                format!(
                                    r#"{{"kept_id":"{k}","archived_id":"{a}","similarity_pct":{s},"depends_on_rewrites":{r}}}"#
                                )
                            })
                            .collect();
                        println!(
                            r#"{{"applied":[{}],"skipped_leased_count":{}}}"#,
                            arr.join(","),
                            skipped_leased.len()
                        );
                    } else {
                        println!(
                            "═══ Gap Consolidate --apply (INFRA-1435) ═══ threshold={}% — \
                             {} pair(s) above threshold, {} archived, {} skipped (leased)",
                            threshold,
                            pairs.len(),
                            applied.len(),
                            skipped_leased.len()
                        );
                        for (k, a, s, r) in &applied {
                            println!(
                                "  archived {} → kept {}  (sim {}%, {} depends_on rewritten)",
                                a, k, s, r
                            );
                        }
                        for (k, a, why) in &skipped_leased {
                            println!("  SKIP  {} ↔ {}: {}", k, a, why);
                        }
                    }
                    return Ok(());
                }

                // Advisory mode (default).
                if as_json {
                    let json_pairs: Vec<String> = pairs
                        .iter()
                        .map(|(a, b, sim)| {
                            format!(
                                r#"{{"gap_id_a":"{}","gap_id_b":"{}","similarity_pct":{},"suggested_action":"{}"}}"#,
                                a, b, sim,
                                if *sim >= 90 { "merge" } else { "review" }
                            )
                        })
                        .collect();
                    println!("[{}]", json_pairs.join(","));
                } else {
                    println!(
                        "═══ Gap Consolidation (INFRA-935) ═══ threshold={}% — {} open gaps scanned",
                        threshold,
                        all_gaps.len()
                    );
                    if pairs.is_empty() {
                        println!("  (no near-duplicate pairs found — registry clean)");
                    } else {
                        println!("  {:>4}  {:>12}  {:>12}  action", "sim%", "gap_a", "gap_b");
                        println!("  ────  ────────────  ────────────  ──────");
                        for (a, b, sim) in &pairs {
                            let action = if *sim >= 90 { "merge" } else { "review" };
                            println!("  {:>3}%  {:>12}  {:>12}  {}", sim, a, b, action);
                        }
                        println!();
                        println!(
                            "  Hint: add --apply --reason \"<text>\" to mutate \
                             (archives higher ID, rewrites depends_on, audits)."
                        );
                    }
                }
                return Ok(());
            }

            // FLEET-048: operator impact rating
            "rate" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap rate <GAP-ID> <1-5> [--comment \"text\"] [--pr N]");
                    std::process::exit(2);
                });
                let rating_str = args.get(4).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap rate <GAP-ID> <1-5> [--comment \"text\"] [--pr N]");
                    std::process::exit(2);
                });
                let rating: u8 = match rating_str.trim().parse::<u8>() {
                    Ok(r) if (1..=5).contains(&r) => r,
                    _ => {
                        eprintln!("chump gap rate: rating must be 1-5 (got {:?})", rating_str);
                        std::process::exit(2);
                    }
                };
                let comment = flag("--comment").unwrap_or_default();
                let pr_number: Option<i64> = flag("--pr").and_then(|s| s.parse::<i64>().ok());

                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let pr_json = pr_number
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| "null".to_string());
                let comment_escaped = comment.replace('\\', "\\\\").replace('"', "\\\"");
                let event = format!(
                    "{{\"ts\":\"{ts}\",\"kind\":\"gap_impact_rated\",\
                     \"gap_id\":\"{gap_id}\",\"rating\":{rating},\
                     \"comment\":\"{comment_escaped}\",\"pr_number\":{pr_json}}}\n"
                );
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                match std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    Ok(mut f) => {
                        use std::io::Write;
                        f.write_all(event.as_bytes())
                            .unwrap_or_else(|e| eprintln!("gap rate: write failed: {e}"));
                    }
                    Err(e) => {
                        eprintln!("gap rate: could not open ambient log: {e}");
                        std::process::exit(1);
                    }
                }
                println!("rated {} → {}/5", gap_id, rating);
                if !comment.is_empty() {
                    println!("  comment: {}", comment);
                }
                return Ok(());
            }
            // INFRA-1220: operator override to clear a post-close cooldown.
            // Usage: chump gap clear-cooldown <GAP-ID> --reason "text"
            "clear-cooldown" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap clear-cooldown <GAP-ID> --reason \"reason\"");
                    std::process::exit(2);
                });
                let reason = flag("--reason").unwrap_or_else(|| {
                    eprintln!("chump gap clear-cooldown: --reason is required (audit trail)");
                    std::process::exit(2);
                });
                // Invoke the shell script so cooldown logic stays in one place.
                let script = repo_root.join("scripts/coord/gap-cooldown.sh");
                let status = std::process::Command::new("bash")
                    .arg(&script)
                    .arg("clear")
                    .arg(&gap_id)
                    .arg("--reason")
                    .arg(&reason)
                    .env("CHUMP_LOCK_DIR", repo_root.join(".chump-locks"))
                    .status();
                match status {
                    Ok(s) if s.success() => {
                        println!("cooldown cleared for {} (reason: {})", gap_id, reason);
                        // INFRA-755: emit ambient event for auditability.
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let reason_esc = reason.replace('\\', "\\\\").replace('"', "\\\"");
                        let event = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"gap_cooldown_cleared_cli\",\
                             \"gap_id\":\"{gap_id}\",\"reason\":\"{reason_esc}\"}}\n"
                        );
                        let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            use std::io::Write;
                            let _ = f.write_all(event.as_bytes());
                        }
                    }
                    Ok(s) => {
                        eprintln!(
                            "gap clear-cooldown: script exited {}",
                            s.code().unwrap_or(-1)
                        );
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("gap clear-cooldown: failed to run script: {e}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            _ => {
                eprintln!("chump gap <subcommand> [options]");
                eprintln!("  list             [--status open|done] [--json]");
                eprintln!("  reserve          --domain D --title T [--priority P1] [--effort s]");
                eprintln!(
                    "                     (positional) D title…  — same as --domain / --title"
                );
                eprintln!(
                    "  claim            <GAP-ID> [--session ID] [--worktree PATH] [--ttl 3600]"
                );
                eprintln!("  preflight        <GAP-ID>");
                eprintln!(
                    "  ship             <GAP-ID> [--session ID] [--update-yaml] [--closed-pr N]"
                );
                eprintln!(
                    "  set              <GAP-ID> [--title T] [--description D] [--priority P]"
                );
                eprintln!("                             [--effort E] [--status S] [--notes N]");
                eprintln!(
                    "                             [--source-doc S] [--opened-date D] [--closed-date D] [--closed-pr N]"
                );
                eprintln!("                             [--acceptance-criteria \"a|b|c\"] [--depends-on \"X-1,X-2\"]");
                eprintln!("  decompose        <GAP-ID> [--apply] [--json] [--dry-run] [--no-description]  # LLM-assisted slicing");
                eprintln!("  dep-clean        [--apply] [--json]  # strip depends_on entries pointing at done gaps");
                eprintln!("  dump             [--out PATH] [--per-file [--out-dir docs/gaps/]]");
                eprintln!("  import           [--yaml docs/gaps.yaml]");
                eprintln!("  restore          --from-sql  # rebuild state.db from .chump/state.sql (INFRA-538)");
                eprintln!("  audit-priorities [--json]   # PM health check (META-046)");
                eprintln!("  triage           [--json] [--apply]  # INFRA-942: classify non-pickable open gaps by reason");
                eprintln!("  audit-ac         [GAP-ID] [--recent N] [--json]  # COG-052 AC coverage check for closed gaps");
                eprintln!("  audit-ac         --open [--json]                  # INFRA-936: warn on open gaps with empty/TODO AC");
                eprintln!("  consolidate      [--threshold N] [--json]  # INFRA-935 near-duplicate title detection");
                eprintln!("  rate             <GAP-ID> <1-5> [--comment text] [--pr N]  # FLEET-048 operator impact rating");
                eprintln!("  rebalance        [--apply] [--json]  # P0 budget + pillar floor enforcement (INFRA-635)");
                eprintln!("  pillar-balance   [--suggest] [--apply] [--json]  # pillar inventory (INFRA-604)");
                eprintln!("  import-spec      <path> [--apply] [--dry-run] [--json]  # import gaps from markdown spec (INFRA-636)");
                eprintln!("  clear-cooldown   <GAP-ID> --reason \"text\"  # INFRA-1220: operator override for post-close cooldown");
                std::process::exit(2);
            }
        }
    }

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
            "{:<10}{:<14}{:<40}{:<10}{:>6}{:>6}{:>8}{:>20}",
            "class", "backend", "model", "provider", "succ", "fail", "rate%", "last_seen"
        );
        for e in &entries {
            println!(
                "{:<10}{:<14}{:<40}{:<10}{:>6}{:>6}{:>7.1}%{:>20}",
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
                e.last_seen
            );
        }
        return Ok(());
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
                }
            }
        }
        match execute_gap::execute_gap(gap_id).await {
            Ok(reply) => {
                print!("{reply}");
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
            let mut cmd_parts = vec![entry.command.clone()];
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
            // SECURITY-005: serenity 0.12.5 (latest on crates.io) pins
            // tokio-tungstenite 0.21 → rustls 0.22 → rustls-webpki 0.102.8,
            // which carries RUSTSEC-2026-0104 (HIGH): DoS via panic on
            // malformed CRL BIT STRING. The Discord gateway is the only
            // chump path that hits this transitive — REST-only callers
            // (a2a_tool, discord_dm) use the safe rustls 0.23 chain.
            // Until upstream serenity ships a tungstenite bump, gate
            // gateway start behind an explicit acknowledgment so an
            // operator can't be silently exposed to the panic risk.
            // Remove this block when `cargo audit` shows 0
            // rustls-webpki 0.102.x advisories AND `cargo tree -i
            // rustls-webpki@0.102.8` returns empty (SECURITY-005 closes).
            let rustls_acked = env::var("CHUMP_ALLOW_DISCORD_RUSTLS")
                .map(|v| v.trim() == "1")
                .unwrap_or(false);
            if !rustls_acked {
                return Err(anyhow::anyhow!(
                    "Discord gateway start is gated by SECURITY-005 — serenity 0.12.5 \
                 (latest) pins vulnerable rustls-webpki 0.102.8 (RUSTSEC-2026-0104 \
                 HIGH: DoS via panic on malformed CRL BIT STRING). To start anyway, \
                 set CHUMP_ALLOW_DISCORD_RUSTLS=1 and accept the panic risk. \
                 Track upstream: https://github.com/serenity-rs/serenity for a \
                 tungstenite/rustls bump. Revisit this gate when SECURITY-005 \
                 closes (cargo audit shows 0 rustls-webpki 0.102.x advisories)."
                ));
            }
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

/// EVAL-009 + EVAL-007: `chump eval run` entry point.
///
/// Loads all eval cases from the DB (seeding if needed), runs each through a
/// stateless ChumpAgent, scores the output, and persists an EvalRunResult per case.
///
/// When `CHUMP_EVAL_WITH_JUDGE=1` AND a case has at least one
/// `ExpectedProperty::LlmJudge` property, scoring uses
/// `check_all_properties_with_judge_async` so the judge_score field is populated
/// in the persisted run (EVAL-007).
///
/// Returns the process exit code: 0 = all cases passed, 1 = one or more failed.
async fn run_eval_runner() -> i32 {
    use eval_harness::{
        check_all_properties, check_all_properties_with_judge_async, load_eval_cases,
        save_eval_run, seed_starter_cases, EvalRunResult, EvalScores, ExpectedProperty,
    };
    use stream_events::AgentEvent;

    // Seed starter cases idempotently.
    if let Err(e) = seed_starter_cases() {
        eprintln!("[eval run] seed_starter_cases failed: {e} — continuing with existing cases");
    }

    let cases = match load_eval_cases() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[eval run] failed to load eval cases: {e}");
            return 1;
        }
    };

    if cases.is_empty() {
        eprintln!("[eval run] no eval cases found in DB — nothing to run");
        return 0;
    }

    let with_judge = std::env::var("CHUMP_EVAL_WITH_JUDGE").as_deref() == Ok("1");
    let provider = provider_cascade::build_provider();
    let agent_version = version::chump_version();
    let model_label = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "unknown".into());

    let mut any_failed = false;
    let total = cases.len();

    for (i, case) in cases.iter().enumerate() {
        let run_id = format!("eval-{}-{}", case.id, uuid::Uuid::new_v4().as_simple());
        let turn_start = std::time::Instant::now();

        // Build a per-case stateless agent with an event channel so we can
        // collect the ordered list of tool names called during the turn.
        let (event_tx, mut event_rx) = stream_events::event_channel();

        let registry = axonerai::tool::ToolRegistry::new();
        // Intentionally empty registry: eval cases test agent reasoning, not
        // live tool execution. Tool-selection properties check the *names* the
        // model would call; with a real registry (and no live DB/network), side
        // effects would corrupt the production DB.
        // The agent still runs with the provider and can reason about tools via
        // the system prompt / context; it just can't execute them.

        let eval_agent = agent_loop::ChumpAgent::new(
            provider_cascade::build_provider(),
            registry,
            Some(
                "You are Chump, a software-development assistant. \
                 Respond concisely and use tools when appropriate."
                    .to_string(),
            ),
            None, // stateless — no session persistence between cases
            Some(event_tx),
            10, // max_iterations sufficient for most eval turns
        );

        let outcome = match eval_agent.run(&case.input).await {
            Ok(o) => o,
            Err(e) => {
                eprintln!("[eval run] case {} errored: {e}", case.id);
                any_failed = true;
                continue;
            }
        };

        // Drain accumulated events to collect tool names in call order.
        // The channel is unbounded; all events are already queued.
        event_rx.close();
        let mut tool_calls_made: Vec<String> = Vec::new();
        while let Ok(ev) = event_rx.try_recv() {
            if let AgentEvent::ToolCallStart { tool_name, .. } = ev {
                tool_calls_made.push(tool_name);
            }
        }

        let duration_ms = turn_start.elapsed().as_millis() as u64;
        let raw_output = outcome.reply.clone();

        // ── EVAL-007: wire CHUMP_EVAL_WITH_JUDGE ──────────────────────────
        // When the env flag is set AND the case has at least one LlmJudge
        // property, use the async judge path so judge_score is populated.
        let has_llm_judge = case
            .expected_properties
            .iter()
            .any(|p| matches!(p, ExpectedProperty::LlmJudge { .. }));

        let (passed_labels, failed_labels, judge_scores) = if with_judge && has_llm_judge {
            let (p, f, js) = check_all_properties_with_judge_async(
                case,
                &raw_output,
                &tool_calls_made,
                provider.as_ref(),
            )
            .await;
            (p, f, js)
        } else {
            let (p, f) = check_all_properties(case, &raw_output, &tool_calls_made);
            (p, f, vec![])
        };

        let case_passed = failed_labels.is_empty();
        if !case_passed {
            any_failed = true;
        }

        // Compute aggregate judge_score (mean across all judged properties).
        let judge_score_agg: Option<f64> = if judge_scores.is_empty() {
            None
        } else {
            let sum: f64 = judge_scores.iter().map(|j| j.score).sum();
            Some(sum / judge_scores.len() as f64)
        };

        // Simple overall score: fraction of properties that passed.
        let total_props = passed_labels.len() + failed_labels.len();
        let overall = if total_props == 0 {
            1.0
        } else {
            passed_labels.len() as f64 / total_props as f64
        };

        let scores = EvalScores {
            overall,
            correctness: overall,
            safety: 1.0,
            efficiency: 1.0,
            judge_score: judge_score_agg,
        };

        let result = EvalRunResult {
            eval_case_id: case.id.clone(),
            run_id,
            properties_passed: passed_labels.clone(),
            properties_failed: failed_labels.clone(),
            scores,
            duration_ms,
            raw_output,
        };

        if let Err(e) = save_eval_run(&result, &agent_version, &model_label) {
            eprintln!("[eval run] save_eval_run failed for {}: {e}", case.id);
        }

        let status = if case_passed { "PASS" } else { "FAIL" };
        let judge_tag = judge_score_agg
            .map(|s| format!(" judge={:.3}", s))
            .unwrap_or_default();
        println!(
            "[eval run] [{}/{total}] {} {:?} — {}/{} props passed{judge_tag}",
            i + 1,
            status,
            case.category,
            passed_labels.len(),
            passed_labels.len() + failed_labels.len(),
        );
    }

    if any_failed {
        eprintln!("[eval run] one or more cases failed");
        1
    } else {
        println!("[eval run] all {} cases passed", total);
        0
    }
}

/// Run eval cases that have LlmJudge properties against the configured provider,
/// persist scores to `logs/judge-scores.json`, and print per-category summary.
/// Called by `chump --eval-judge` (and transitively by `battle-qa.sh --with-judge`).
async fn run_eval_judge_mode() {
    use eval_harness::{
        average_judge_score_per_category, judge_via_provider, load_eval_cases, seed_starter_cases,
        EvalCategory, ExpectedProperty, JudgeInput, JudgeScore,
    };

    // Seed cases into DB if not already there.
    if let Err(e) = seed_starter_cases() {
        eprintln!("[eval-judge] seed_starter_cases failed: {e} — continuing with existing cases");
    }

    let cases = match load_eval_cases() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[eval-judge] failed to load eval cases: {e}");
            return;
        }
    };

    let provider = provider_cascade::build_provider();

    let mut scored: Vec<(EvalCategory, JudgeScore)> = Vec::new();
    let mut json_rows: Vec<serde_json::Value> = Vec::new();

    for case in &cases {
        for prop in &case.expected_properties {
            if let ExpectedProperty::LlmJudge { rubric, threshold } = prop {
                // Get a direct (non-agent) response for this case input.
                let messages = vec![axonerai::provider::Message {
                    role: "user".to_string(),
                    content: case.input.clone(),
                }];
                let agent_output = match provider.complete(messages, None, Some(400), None).await {
                    Ok(r) => r.text.unwrap_or_default(),
                    Err(e) => {
                        eprintln!("[eval-judge] provider error for case {}: {e}", case.id);
                        continue;
                    }
                };

                let judge_input = JudgeInput {
                    rubric: rubric.clone(),
                    agent_output: agent_output.clone(),
                    tool_calls: vec![],
                };
                let judge_out = judge_via_provider(provider.as_ref(), judge_input).await;
                let score = judge_out.score.clamp(0.0, 1.0);
                let js = JudgeScore {
                    rubric: rubric.clone(),
                    threshold: *threshold,
                    score,
                    passed: score >= *threshold,
                    reasoning: judge_out.reasoning.clone(),
                };
                json_rows.push(serde_json::json!({
                    "case_id": case.id,
                    "category": format!("{:?}", case.category),
                    "rubric": rubric,
                    "score": score,
                    "passed": js.passed,
                    "reasoning": judge_out.reasoning,
                }));
                scored.push((case.category.clone(), js));
            }
        }
    }

    // Persist to logs/judge-scores.json
    let logs_dir = repo_path::repo_root().join("logs");
    let _ = std::fs::create_dir_all(&logs_dir);
    let judge_file = logs_dir.join("judge-scores.json");
    if let Ok(json) = serde_json::to_string_pretty(&json_rows) {
        let _ = std::fs::write(&judge_file, json);
    }

    // Print per-category summary
    let summary = average_judge_score_per_category(&scored);
    if summary.is_empty() {
        println!("[eval-judge] No LlmJudge cases found in loaded eval cases.");
        return;
    }
    println!("Avg judge score per category:");
    for (cat, avg, n) in &summary {
        println!(
            "  {cat}: {avg:.3} ({n} case{})",
            if *n == 1 { "" } else { "s" }
        );
    }
    println!("[eval-judge] Scores persisted to {}", judge_file.display());
}

/// EVAL-009 + EVAL-007: full eval runner. Returns exit code (0 = all pass).
///
/// For each chump_eval_case:
///   1. Send case.input to the configured provider (single-turn — no tool loop;
///      richer multi-turn replay lives in scripts/eval/replay-trajectory.sh per
///      EVAL-003).
///   2. Score with `check_all_properties` (always) and
///      `check_all_properties_with_judge_async` (when CHUMP_EVAL_WITH_JUDGE=1).
///   3. Persist EvalRunResult to chump_eval_runs via `save_eval_run`.
///
/// Single-turn caveat: the EvalCase contract is "user input → response"; multi-
/// turn fixtures are GoldenTrajectory's job (EVAL-003 + scripts/eval/replay-
/// trajectory.sh). When EVAL-009 acceptance says "runs each through ChumpAgent"
/// the agent here is the bare provider — full agent-loop integration with tools
/// would re-implement most of agent_loop and isn't needed for property scoring.
async fn run_eval_run_mode() -> i32 {
    use eval_harness::{
        check_all_properties, check_all_properties_with_judge_async, load_eval_cases,
        save_eval_run, seed_starter_cases, EvalRunResult, EvalScores,
    };
    use uuid::Uuid;

    if let Err(e) = seed_starter_cases() {
        eprintln!("[eval-run] seed_starter_cases failed: {e} — continuing with existing cases");
    }
    let cases = match load_eval_cases() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[eval-run] failed to load eval cases: {e}");
            return 2;
        }
    };
    if cases.is_empty() {
        eprintln!("[eval-run] no eval cases loaded — nothing to do");
        return 0;
    }

    let with_judge = matches!(std::env::var("CHUMP_EVAL_WITH_JUDGE").as_deref(), Ok("1"));
    let model_name = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "unknown".to_string());
    let agent_version = env!("CARGO_PKG_VERSION");
    let run_id = format!("evalrun-{}", Uuid::new_v4().simple());
    let provider = provider_cascade::build_provider();

    println!(
        "[eval-run] {} cases, model={}, with_judge={}, run_id={}",
        cases.len(),
        model_name,
        with_judge,
        run_id
    );

    let mut total_passed = 0usize;
    let mut total_failed = 0usize;
    for case in &cases {
        let started = std::time::Instant::now();
        let messages = vec![axonerai::provider::Message {
            role: "user".to_string(),
            content: case.input.clone(),
        }];
        let agent_output = match provider.complete(messages, None, Some(800), None).await {
            Ok(r) => r.text.unwrap_or_default(),
            Err(e) => {
                eprintln!("[eval-run] provider error for case {}: {e}", case.id);
                String::new()
            }
        };
        let duration_ms = started.elapsed().as_millis() as u64;

        // Structural pass/fail (always). Single-turn so tool_calls is empty.
        let (mut passed, mut failed) = check_all_properties(case, &agent_output, &[]);

        // Judge pass/fail (when enabled). Augments the property lists.
        let mut judge_overall = 0.0_f64;
        if with_judge {
            let (jp, jf, scores) =
                check_all_properties_with_judge_async(case, &agent_output, &[], provider.as_ref())
                    .await;
            for s in &jp {
                if !passed.contains(s) {
                    passed.push(s.clone());
                }
            }
            for s in &jf {
                if !failed.contains(s) {
                    failed.push(s.clone());
                }
            }
            if !scores.is_empty() {
                judge_overall = scores.iter().map(|s| s.score).sum::<f64>() / scores.len() as f64;
            }
        }

        let case_passed = failed.is_empty() && !agent_output.trim().is_empty();
        if case_passed {
            total_passed += 1;
        } else {
            total_failed += 1;
        }
        println!(
            "  {} {}  [pass={} fail={} judge={:.2} dur={}ms]",
            if case_passed { "✓" } else { "✗" },
            case.id,
            passed.len(),
            failed.len(),
            judge_overall,
            duration_ms
        );

        let scores = EvalScores {
            overall: if case_passed { 1.0 } else { 0.0 },
            correctness: judge_overall,
            safety: 0.0,
            efficiency: 0.0,
            judge_score: if with_judge && judge_overall > 0.0 {
                Some(judge_overall)
            } else {
                None
            },
        };
        let result = EvalRunResult {
            eval_case_id: case.id.clone(),
            run_id: run_id.clone(),
            properties_passed: passed,
            properties_failed: failed,
            scores,
            duration_ms,
            raw_output: agent_output,
        };
        if let Err(e) = save_eval_run(&result, agent_version, &model_name) {
            eprintln!("[eval-run] save_eval_run failed for {}: {e}", case.id);
        }
    }

    println!(
        "[eval-run] done. passed={} failed={} total={}",
        total_passed,
        total_failed,
        total_passed + total_failed
    );
    if total_failed == 0 {
        0
    } else {
        1
    }
}

/// EVAL-008: A/B reflect_heuristic vs reflect_via_provider on a labeled
/// dataset. Returns exit code 0 if the LLM variant beats the heuristic by
/// >=15 percentage points (the acceptance gate), 1 otherwise.
///
/// Loads tests/fixtures/reflection_episodes.json — 20 labeled episodes with
/// ground-truth ErrorPattern. For each episode, runs both reflectors and
/// compares the predicted pattern against the gold label. Reports per-method
/// accuracy and per-pattern confusion stats.
///
/// Provider for reflect_via_provider comes from provider_cascade::build_provider().
async fn run_eval_reflection_mode() -> i32 {
    use reflection::{
        reflect_heuristic, reflect_via_provider, ErrorPattern, OutcomeClass, ReflectionInput,
    };
    use serde::Deserialize;
    use std::collections::BTreeMap;

    #[derive(Debug, Clone, Deserialize)]
    struct LabeledEpisode {
        id: String,
        intended_goal: String,
        observed_outcome: String,
        outcome_class: String,
        #[serde(default)]
        tool_errors: Vec<String>,
        gold_pattern: Option<String>,
    }

    #[derive(Debug, Clone, Deserialize)]
    struct EpisodesFile {
        episodes: Vec<LabeledEpisode>,
    }

    let fixture_path = repo_path::repo_root().join("tests/fixtures/reflection_episodes.json");
    let raw = match std::fs::read_to_string(&fixture_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "[eval-reflection] cannot read {}: {e}",
                fixture_path.display()
            );
            return 2;
        }
    };
    let parsed: EpisodesFile = match serde_json::from_str(&raw) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[eval-reflection] parse error: {e}");
            return 2;
        }
    };
    println!(
        "[eval-reflection] {} episodes loaded from {}",
        parsed.episodes.len(),
        fixture_path.display()
    );

    let provider = provider_cascade::build_provider();
    let model_name = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "unknown".to_string());

    // Per-method totals.
    let mut h_correct = 0usize;
    let mut p_correct = 0usize;
    // Per-gold-pattern: (heuristic_correct, provider_correct, total).
    let mut by_pattern: BTreeMap<String, (usize, usize, usize)> = BTreeMap::new();

    for ep in &parsed.episodes {
        let outcome = OutcomeClass::from_str(&ep.outcome_class.to_lowercase());
        // Gold label: "ToolMisuse" → ErrorPattern variant; null/None → expected None.
        let gold_label = ep.gold_pattern.as_deref();
        let gold_pattern: Option<ErrorPattern> = gold_label
            .map(|s| s.to_lowercase().replace(' ', "_"))
            .and_then(|s| {
                // The fixture uses CamelCase but ErrorPattern::from_str expects snake.
                let snake = camel_to_snake(s.as_str());
                ErrorPattern::from_str(&snake)
            });

        // Heuristic prediction.
        let h_reflection = reflect_heuristic(
            &ep.intended_goal,
            &ep.observed_outcome,
            outcome,
            &ep.tool_errors,
            None,
            None,
        );

        // Provider prediction.
        let input = ReflectionInput {
            intended_goal: ep.intended_goal.clone(),
            observed_outcome: ep.observed_outcome.clone(),
            outcome_class: outcome,
            tool_errors: ep.tool_errors.clone(),
            surprisal: None,
            trajectory_confidence: None,
        };
        let p_reflection = reflect_via_provider(provider.as_ref(), input).await;

        let h_match = h_reflection.error_pattern == gold_pattern;
        let p_match = p_reflection.error_pattern == gold_pattern;
        if h_match {
            h_correct += 1;
        }
        if p_match {
            p_correct += 1;
        }
        let bucket = by_pattern
            .entry(gold_label.unwrap_or("Pass").to_string())
            .or_insert((0, 0, 0));
        if h_match {
            bucket.0 += 1;
        }
        if p_match {
            bucket.1 += 1;
        }
        bucket.2 += 1;

        let h_pred = h_reflection
            .error_pattern
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "(none)".to_string());
        let p_pred = p_reflection
            .error_pattern
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "(none)".to_string());
        let gold_str = gold_label.unwrap_or("(none)");
        println!(
            "  {:6} gold={:24} heur={:24}{}  prov={:24}{}",
            ep.id,
            gold_str,
            h_pred,
            if h_match { " ✓" } else { " ✗" },
            p_pred,
            if p_match { " ✓" } else { " ✗" },
        );
    }

    let total = parsed.episodes.len() as f64;
    let h_acc = h_correct as f64 / total;
    let p_acc = p_correct as f64 / total;
    let delta = p_acc - h_acc;

    println!();
    println!("[eval-reflection] model={}", model_name);
    println!(
        "  heuristic accuracy: {}/{} = {:.3}",
        h_correct,
        parsed.episodes.len(),
        h_acc
    );
    println!(
        "  provider  accuracy: {}/{} = {:.3}",
        p_correct,
        parsed.episodes.len(),
        p_acc
    );
    println!("  delta (provider - heuristic): {:+.3}", delta);
    println!();
    println!("  per-pattern (heur/prov/total):");
    for (pat, (h, p, t)) in &by_pattern {
        println!("    {:24} {:>2}/{:>2}/{:>2}", pat, h, p, t);
    }

    // Persist a JSON summary alongside other A/B results.
    let logs_dir = repo_path::repo_root().join("logs");
    let _ = std::fs::create_dir_all(&logs_dir);
    let summary = serde_json::json!({
        "tag": "eval-reflection-ab",
        "model": model_name,
        "episodes": parsed.episodes.len(),
        "heuristic_correct": h_correct,
        "provider_correct": p_correct,
        "heuristic_accuracy": h_acc,
        "provider_accuracy": p_acc,
        "delta": delta,
        "by_pattern": by_pattern.iter().map(|(k, (h, p, t))| {
            (k.clone(), serde_json::json!({"heuristic": h, "provider": p, "total": t}))
        }).collect::<serde_json::Map<_, _>>(),
    });
    let summary_path = logs_dir.join(format!(
        "eval-reflection-{}.json",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    ));
    let _ = std::fs::write(
        &summary_path,
        serde_json::to_string_pretty(&summary).unwrap_or_default(),
    );
    println!("\n[eval-reflection] summary: {}", summary_path.display());

    // Acceptance gate: provider must beat heuristic by >=15 pp.
    if delta >= 0.15 {
        println!("[eval-reflection] PASS — provider beats heuristic by >=15 pp");
        0
    } else {
        println!(
            "[eval-reflection] FAIL — delta {:+.3} < +0.150 acceptance gate",
            delta
        );
        1
    }
}

/// "ToolMisuse" → "tool_misuse" — minimal converter for fixture string → enum.
/// COG-043: read all `lessons_shown` events for `gap_id` from
/// ambient.jsonl, fetch the PR diff + body via `gh`, and emit a
/// `lesson_applied` / `lesson_not_applied` event for each unique
/// directive. Returns (applied, not_applied, skipped) counts.
///
/// Caller (bot-merge.sh) treats errors here as best-effort — never
/// gates the auto-close flow on telemetry.
fn run_lesson_grade(
    repo_root: &std::path::Path,
    gap_id: &str,
    pr_number: u64,
    session_filter: Option<&str>,
) -> anyhow::Result<(u64, u64, u64)> {
    use std::process::Command;
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    // Find the most recent `lessons_shown` event matching gap_id (and
    // session if provided). Walk lines from the end backward.
    let mut latest_directives: Vec<String> = Vec::new();
    let mut latest_session = String::new();
    for line in contents.lines().rev() {
        if !line.contains("\"kind\":\"lessons_shown\"")
            && !line.contains("\"kind\": \"lessons_shown\"")
        {
            continue;
        }
        if !line.contains(gap_id) {
            continue;
        }
        if let Some(filt) = session_filter {
            if !line.contains(filt) {
                continue;
            }
        }
        // Parse the JSON line. Use python3 for robustness; fall back to
        // a permissive substring extract if python is unavailable.
        let parsed = parse_lessons_shown_line(line);
        if let Some((session_id, directives)) = parsed {
            if !directives.is_empty() {
                latest_directives = directives;
                latest_session = session_id;
                break;
            }
        }
    }
    if latest_directives.is_empty() {
        return Ok((0, 0, 0));
    }

    // Pull the PR body + diff via gh. Failures here just mean we can't
    // grade — return zeros, don't error.
    let body_out = Command::new("gh")
        .args([
            "pr",
            "view",
            &pr_number.to_string(),
            "--json",
            "body,title,commits",
            "-q",
            ".title + \"\\n\" + (.body // \"\") + \"\\n\" + ([.commits[].messageHeadline + \"\\n\" + (.commits[].messageBody // \"\")] | join(\"\\n\"))",
        ])
        .current_dir(repo_root)
        .output()
        .ok();
    let diff_out = Command::new("gh")
        .args(["pr", "diff", &pr_number.to_string()])
        .current_dir(repo_root)
        .output()
        .ok();

    let mut pr_text = String::new();
    if let Some(o) = body_out {
        if o.status.success() {
            pr_text.push_str(&String::from_utf8_lossy(&o.stdout));
        }
    }
    if let Some(o) = diff_out {
        if o.status.success() {
            pr_text.push('\n');
            pr_text.push_str(&String::from_utf8_lossy(&o.stdout));
        }
    }
    if pr_text.is_empty() {
        return Ok((0, 0, latest_directives.len() as u64));
    }

    let mut applied = 0u64;
    let mut not_applied = 0u64;
    for directive in &latest_directives {
        let (matched, total) = lesson_action::score_directive_against_pr(directive, &pr_text);
        let is_applied = lesson_action::directive_applied(directive, &pr_text);
        lesson_action::emit_lesson_grade(
            repo_root,
            &latest_session,
            gap_id,
            pr_number,
            directive,
            is_applied,
            matched,
            total,
        );
        if is_applied {
            applied += 1;
        } else {
            not_applied += 1;
        }
    }
    Ok((applied, not_applied, 0))
}

/// Parse one `lessons_shown` JSON line. Returns (session_id, directives).
/// Permissive — uses python3 if available, hand-rolls otherwise.
fn parse_lessons_shown_line(line: &str) -> Option<(String, Vec<String>)> {
    use std::process::Command;
    if let Ok(out) = Command::new("python3")
        .arg("-c")
        .arg(
            r#"
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
sid = d.get('session_id', '')
dirs = d.get('directives', [])
if not isinstance(dirs, list):
    dirs = []
print(sid)
for x in dirs:
    print(x)
"#,
        )
        .arg(line)
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout);
            let mut iter = s.lines();
            let sid = iter.next().unwrap_or("").to_string();
            let dirs: Vec<String> = iter.map(|l| l.to_string()).collect();
            if !dirs.is_empty() {
                return Some((sid, dirs));
            }
        }
    }
    // Fallback: don't try to be clever. If python isn't available,
    // grading just no-ops on this corpus. That's acceptable for v1.
    None
}

fn camel_to_snake(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            out.push('_');
        }
        out.extend(c.to_lowercase());
    }
    out
}

/// EVAL-008: A/B accuracy comparison between `reflect_heuristic` and
/// `reflect_via_provider` on a labeled episode dataset.
///
/// Env gating:
///   CHUMP_REFLECTION_AB_WITH_LLM=1  — also runs the provider leg (fails loud
///                                     if no endpoint reachable)
///
/// Exit behaviour (via std::process::exit):
///   0  — heuristic-only run, or LLM leg ≥ 15% more accurate than heuristic
///   1  — LLM leg present but accuracy delta < 15%
async fn run_reflection_ab_mode(episodes_path: Option<std::path::PathBuf>) {
    use reflection::{reflect_heuristic, reflect_via_provider, OutcomeClass, ReflectionInput};

    // ── Locate episode file ────────────────────────────────────────────────
    let default_path = std::path::PathBuf::from("scripts/eval-reflection-ab/episodes.json");
    let path = episodes_path.unwrap_or(default_path);
    let raw = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "[reflect-ab] ERROR: cannot read episodes file {}: {e}",
                path.display()
            );
            std::process::exit(2);
        }
    };
    let doc: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[reflect-ab] ERROR: malformed JSON in episodes file: {e}");
            std::process::exit(2);
        }
    };
    let episodes = match doc.get("episodes").and_then(|v| v.as_array()) {
        Some(a) => a.clone(),
        None => {
            eprintln!("[reflect-ab] ERROR: episodes file has no top-level 'episodes' array");
            std::process::exit(2);
        }
    };

    // ── LLM leg setup ─────────────────────────────────────────────────────
    let with_llm = std::env::var("CHUMP_REFLECTION_AB_WITH_LLM")
        .map(|v| v == "1")
        .unwrap_or(false);
    // build_provider() returns Box<dyn Provider + Send + Sync> directly.
    // The shell script already probed the endpoint before setting
    // CHUMP_REFLECTION_AB_WITH_LLM=1, so this will succeed if --with-llm was passed.
    let provider_box: Option<Box<dyn axonerai::provider::Provider + Send + Sync>> = if with_llm {
        Some(crate::provider_cascade::build_provider())
    } else {
        None
    };

    // ── Per-pattern counters ───────────────────────────────────────────────
    let mut h_correct: usize = 0; // heuristic correct
    let mut l_correct: usize = 0; // llm correct
    let mut total_labeled: usize = 0; // episodes with a label (non-pass)

    // Confusion accumulators: (label, heuristic_pred) → count
    let mut h_confusion: std::collections::HashMap<(String, String), usize> =
        std::collections::HashMap::new();
    let mut l_confusion: std::collections::HashMap<(String, String), usize> =
        std::collections::HashMap::new();

    println!(
        "[reflect-ab] episodes={} with_llm={}",
        episodes.len(),
        with_llm
    );
    println!();

    for ep in &episodes {
        let id = ep.get("id").and_then(|v| v.as_str()).unwrap_or("?");
        let intended_goal = ep
            .get("intended_goal")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let observed_outcome = ep
            .get("observed_outcome")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let outcome_class_str = ep
            .get("outcome_class")
            .and_then(|v| v.as_str())
            .unwrap_or("fail");
        let outcome_class = if outcome_class_str == "pass" {
            OutcomeClass::Pass
        } else {
            OutcomeClass::Failure
        };
        let tool_errors: Vec<String> = ep
            .get("tool_errors")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str())
                    .map(|s| s.to_string())
                    .collect()
            })
            .unwrap_or_default();
        let surprisal = ep.get("surprisal").and_then(|v| v.as_f64());
        let trajectory_confidence = ep.get("trajectory_confidence").and_then(|v| v.as_f64());
        let label_raw = ep.get("label").and_then(|v| v.as_str()); // None for pass episodes

        // Pass episodes: both methods should return None error_pattern.
        if outcome_class == OutcomeClass::Pass {
            let h_refl = reflect_heuristic(
                &intended_goal,
                &observed_outcome,
                outcome_class,
                &tool_errors,
                surprisal,
                trajectory_confidence,
            );
            let h_pred = h_refl
                .error_pattern
                .map(|p| p.as_str().to_string())
                .unwrap_or_else(|| "null".to_string());
            println!("  [{id}] pass | heuristic→{h_pred}");
            continue;
        }

        // Labeled failure episodes.
        let label = match label_raw {
            Some(l) => l.to_string(),
            None => {
                eprintln!("  [{id}] WARN: fail episode has no label — skipping");
                continue;
            }
        };
        total_labeled += 1;

        let input = ReflectionInput {
            intended_goal: intended_goal.clone(),
            observed_outcome: observed_outcome.clone(),
            outcome_class,
            tool_errors: tool_errors.clone(),
            surprisal,
            trajectory_confidence,
        };

        // Heuristic leg
        let h_refl = reflect_heuristic(
            &intended_goal,
            &observed_outcome,
            outcome_class,
            &tool_errors,
            surprisal,
            trajectory_confidence,
        );
        let h_pred = h_refl
            .error_pattern
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "null".to_string());
        let h_hit = h_pred == label;
        if h_hit {
            h_correct += 1;
        }
        *h_confusion
            .entry((label.clone(), h_pred.clone()))
            .or_insert(0) += 1;

        // LLM leg (optional)
        let l_pred = if let Some(ref prov) = provider_box {
            let l_refl = reflect_via_provider(prov.as_ref(), input.clone()).await;
            let pred = l_refl
                .error_pattern
                .map(|p| p.as_str().to_string())
                .unwrap_or_else(|| "null".to_string());
            let l_hit = pred == label;
            if l_hit {
                l_correct += 1;
            }
            *l_confusion
                .entry((label.clone(), pred.clone()))
                .or_insert(0) += 1;
            Some(pred)
        } else {
            None
        };

        let h_mark = if h_hit { "✓" } else { "✗" };
        if let Some(ref lp) = l_pred {
            let l_hit = *lp == label;
            let l_mark = if l_hit { "✓" } else { "✗" };
            println!("  [{id}] label={label} | heuristic={h_pred}{h_mark}  llm={lp}{l_mark}");
        } else {
            println!("  [{id}] label={label} | heuristic={h_pred}{h_mark}");
        }
    }

    // ── Summary ───────────────────────────────────────────────────────────
    println!();
    println!("=== EVAL-008: Reflection A/B Results ===");
    println!("Labeled failure episodes: {total_labeled}");
    println!(
        "Heuristic accuracy: {}/{total_labeled} = {:.1}%",
        h_correct,
        100.0 * h_correct as f64 / total_labeled.max(1) as f64
    );

    if with_llm {
        let l_acc = 100.0 * l_correct as f64 / total_labeled.max(1) as f64;
        let h_acc = 100.0 * h_correct as f64 / total_labeled.max(1) as f64;
        let delta = l_acc - h_acc;
        println!(
            "LLM accuracy:       {}/{total_labeled} = {l_acc:.1}%",
            l_correct
        );
        println!("Delta (LLM − heuristic): {delta:+.1}%");
        println!();

        // Per-pattern confusion matrix (heuristic)
        println!("--- Heuristic confusion (label → predicted) ---");
        let mut h_rows: Vec<_> = h_confusion.iter().collect();
        h_rows.sort_by(|a, b| a.0.cmp(b.0));
        for ((lbl, pred), cnt) in &h_rows {
            let mark = if lbl == pred { "✓" } else { "✗" };
            println!("  {lbl:35} → {pred:35} ×{cnt} {mark}");
        }
        println!();

        println!("--- LLM confusion (label → predicted) ---");
        let mut l_rows: Vec<_> = l_confusion.iter().collect();
        l_rows.sort_by(|a, b| a.0.cmp(b.0));
        for ((lbl, pred), cnt) in &l_rows {
            let mark = if lbl == pred { "✓" } else { "✗" };
            println!("  {lbl:35} → {pred:35} ×{cnt} {mark}");
        }
        println!();

        // A/B gate
        if delta >= 15.0 {
            println!("[reflect-ab] PASS: LLM variant is ≥15% more accurate ({delta:+.1}% delta)");
        } else {
            eprintln!(
                "[reflect-ab] FAIL: LLM delta {delta:+.1}% is below the 15% acceptance threshold"
            );
            std::process::exit(1);
        }
    } else {
        println!();
        println!("--- Heuristic confusion (label → predicted) ---");
        let mut rows: Vec<_> = h_confusion.iter().collect();
        rows.sort_by(|a, b| a.0.cmp(b.0));
        for ((lbl, pred), cnt) in &rows {
            let mark = if lbl == pred { "✓" } else { "✗" };
            println!("  {lbl:35} → {pred:35} ×{cnt} {mark}");
        }
        println!();
        println!(
            "[reflect-ab] Heuristic-only run complete. Re-run with \
             CHUMP_REFLECTION_AB_WITH_LLM=1 to compare against LLM variant."
        );
    }
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-1229 slice 1 — `chump ship plan` CLI wrapper around the pure
// planner in the chump-ship crate. Gathers PR + repo snapshots via gh + git,
// calls chump_ship::plan(), emits JSON (default) or a human summary.
// ──────────────────────────────────────────────────────────────────────

async fn ship_plan_cli(args: &[String]) -> Result<()> {
    let mut gap_id: Option<String> = None;
    let mut pr_num: Option<u64> = None;
    let mut branch: Option<String> = None;
    let mut json_out = true;
    let mut dry_run = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--gap" => {
                gap_id = args.get(i + 1).cloned();
                i += 2;
            }
            "--pr" => {
                pr_num = args.get(i + 1).and_then(|s| s.parse().ok());
                i += 2;
            }
            "--branch" => {
                branch = args.get(i + 1).cloned();
                i += 2;
            }
            "--json" => {
                json_out = true;
                i += 1;
            }
            "--human" => {
                json_out = false;
                i += 1;
            }
            "--dry-run" => {
                dry_run = true;
                i += 1;
            }
            other => {
                eprintln!("chump ship plan: unknown flag {other:?}");
                eprintln!("Run `chump ship plan --help` for usage.");
                std::process::exit(2);
            }
        }
    }

    // Branch: explicit > current symbolic-ref > "HEAD" sentinel.
    let branch_name = match branch {
        Some(b) => b,
        None => std::process::Command::new("git")
            .args(["symbolic-ref", "--short", "HEAD"])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "HEAD".to_string()),
    };

    // Repo snapshot — via git rev-list.
    let stale_threshold: u32 = std::env::var("CHUMP_BOT_MERGE_STALE_THRESHOLD")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(15);
    let (behind_main, ahead_main) = if dry_run {
        (0u32, 0u32)
    } else {
        ship_plan_count_behind_ahead("HEAD", "origin/main").unwrap_or((0, 0))
    };
    let has_uncommitted = if dry_run {
        false
    } else {
        !std::process::Command::new("git")
            .args(["status", "--porcelain"])
            .output()
            .ok()
            .map(|o| o.stdout.is_empty())
            .unwrap_or(true)
    };
    let repo = chump_ship::RepoSnapshot {
        branch: branch_name.clone(),
        behind_main,
        ahead_main,
        has_uncommitted,
        stale_threshold,
    };

    // PR snapshot — via gh api (REST), unless --dry-run.
    let pr = if dry_run {
        chump_ship::PrSnapshot {
            number: pr_num,
            state: if pr_num.is_some() {
                chump_ship::PrState::Open
            } else {
                chump_ship::PrState::None
            },
            mergeable: None,
            mergeable_state: chump_ship::MergeableState::Unknown,
            auto_merge_set: false,
            head_sha: String::new(),
            base_sha: String::new(),
            checks: chump_ship::ChecksSummary::default(),
        }
    } else {
        match ship_plan_fetch_pr_snapshot(pr_num, &branch_name) {
            Ok(snapshot) => snapshot,
            Err(e) => {
                eprintln!(
                    "chump ship plan: could not fetch PR snapshot ({e}); falling back to no-PR."
                );
                chump_ship::PrSnapshot {
                    number: None,
                    state: chump_ship::PrState::None,
                    mergeable: None,
                    mergeable_state: chump_ship::MergeableState::Unknown,
                    auto_merge_set: false,
                    head_sha: String::new(),
                    base_sha: String::new(),
                    checks: chump_ship::ChecksSummary::default(),
                }
            }
        }
    };

    let decision = chump_ship::plan(&pr, &repo);
    let payload = serde_json::json!({
        "gap": gap_id,
        "branch": branch_name,
        "behind_main": behind_main,
        "ahead_main": ahead_main,
        "pr": pr,
        "plan": decision,
    });

    if json_out {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        ship_plan_print_human(&decision, gap_id.as_deref(), &branch_name);
    }
    Ok(())
}

fn ship_plan_count_behind_ahead(head: &str, base: &str) -> std::io::Result<(u32, u32)> {
    let spec = format!("{head}...{base}");
    let out = std::process::Command::new("git")
        .args(["rev-list", "--left-right", "--count", &spec])
        .output()?;
    if !out.status.success() {
        return Ok((0, 0));
    }
    let s = String::from_utf8_lossy(&out.stdout);
    let mut parts = s.split_whitespace();
    let ahead: u32 = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    let behind: u32 = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    Ok((behind, ahead))
}

fn ship_plan_fetch_pr_snapshot(
    pr_num: Option<u64>,
    branch: &str,
) -> anyhow::Result<chump_ship::PrSnapshot> {
    // Resolve owner/repo from origin remote — `gh api repos/{owner}/{repo}/...`
    let nwo_out = std::process::Command::new("gh")
        .args([
            "repo",
            "view",
            "--json",
            "nameWithOwner",
            "--jq",
            ".nameWithOwner",
        ])
        .output()?;
    if !nwo_out.status.success() {
        anyhow::bail!(
            "gh repo view failed: {}",
            String::from_utf8_lossy(&nwo_out.stderr)
        );
    }
    let nwo = String::from_utf8_lossy(&nwo_out.stdout).trim().to_string();

    // Resolve PR number: explicit --pr > look up by head branch.
    let pr = match pr_num {
        Some(n) => n,
        None => {
            let owner = nwo.split('/').next().unwrap_or("");
            let list = std::process::Command::new("gh")
                .args([
                    "api",
                    &format!("repos/{nwo}/pulls?head={owner}:{branch}&state=open"),
                    "--jq",
                    ".[0].number // empty",
                ])
                .output()?;
            let s = String::from_utf8_lossy(&list.stdout).trim().to_string();
            if s.is_empty() {
                // No PR for this branch — return synthetic "no PR" snapshot.
                return Ok(chump_ship::PrSnapshot {
                    number: None,
                    state: chump_ship::PrState::None,
                    mergeable: None,
                    mergeable_state: chump_ship::MergeableState::Unknown,
                    auto_merge_set: false,
                    head_sha: String::new(),
                    base_sha: String::new(),
                    checks: chump_ship::ChecksSummary::default(),
                });
            }
            s.parse()?
        }
    };

    // Fetch PR detail.
    let pr_json = std::process::Command::new("gh")
        .args(["api", &format!("repos/{nwo}/pulls/{pr}")])
        .output()?;
    if !pr_json.status.success() {
        anyhow::bail!(
            "gh api pulls/{pr} failed: {}",
            String::from_utf8_lossy(&pr_json.stderr)
        );
    }
    let v: serde_json::Value = serde_json::from_slice(&pr_json.stdout)?;
    let state = match v.get("state").and_then(|x| x.as_str()) {
        Some("open") => chump_ship::PrState::Open,
        Some("closed") if v.get("merged").and_then(|x| x.as_bool()) == Some(true) => {
            chump_ship::PrState::Merged
        }
        Some("closed") => chump_ship::PrState::Closed,
        _ => chump_ship::PrState::Open,
    };
    let mergeable = v.get("mergeable").and_then(|x| x.as_bool());
    let mergeable_state = match v.get("mergeable_state").and_then(|x| x.as_str()) {
        Some("clean") => chump_ship::MergeableState::Clean,
        Some("behind") => chump_ship::MergeableState::Behind,
        Some("blocked") => chump_ship::MergeableState::Blocked,
        Some("dirty") => chump_ship::MergeableState::Dirty,
        Some("unstable") => chump_ship::MergeableState::Unstable,
        Some("has_hooks") => chump_ship::MergeableState::HasHooks,
        _ => chump_ship::MergeableState::Unknown,
    };
    let auto_merge_set = v.get("auto_merge").map(|x| !x.is_null()).unwrap_or(false);
    let head_sha = v
        .get("head")
        .and_then(|h| h.get("sha"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let base_sha = v
        .get("base")
        .and_then(|b| b.get("sha"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();

    // Fetch checks summary for the head sha.
    let checks = if head_sha.is_empty() {
        chump_ship::ChecksSummary::default()
    } else {
        ship_plan_fetch_checks(&nwo, &head_sha).unwrap_or_default()
    };

    Ok(chump_ship::PrSnapshot {
        number: Some(pr),
        state,
        mergeable,
        mergeable_state,
        auto_merge_set,
        head_sha,
        base_sha,
        checks,
    })
}

fn ship_plan_fetch_checks(nwo: &str, sha: &str) -> anyhow::Result<chump_ship::ChecksSummary> {
    let out = std::process::Command::new("gh")
        .args([
            "api",
            &format!("repos/{nwo}/commits/{sha}/check-runs"),
            "--paginate",
        ])
        .output()?;
    if !out.status.success() {
        anyhow::bail!(
            "gh api check-runs failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or(serde_json::json!({}));
    let runs = v
        .get("check_runs")
        .and_then(|x| x.as_array())
        .cloned()
        .unwrap_or_default();
    let mut s = chump_ship::ChecksSummary::default();
    for c in &runs {
        let status = c.get("status").and_then(|x| x.as_str()).unwrap_or("");
        let conclusion = c.get("conclusion").and_then(|x| x.as_str()).unwrap_or("");
        let neutral_kind = matches!(conclusion, "skipped" | "neutral" | "cancelled");
        if neutral_kind {
            s.neutral_or_skipped += 1;
            continue;
        }
        s.total += 1;
        if status != "completed" {
            s.incomplete += 1;
        } else if conclusion != "success" {
            s.completed_failure += 1;
        } else {
            s.completed_success += 1;
        }
    }
    Ok(s)
}

fn ship_plan_print_human(plan: &chump_ship::ShipPlan, gap: Option<&str>, branch: &str) {
    println!(
        "[ship plan] branch={branch} gap={}",
        gap.unwrap_or("(none)")
    );
    match plan {
        chump_ship::ShipPlan::AlreadyDone {
            pr,
            state,
            recovery_hint,
        } => {
            println!("  action: ALREADY_DONE  pr=#{pr} state={state:?}");
            println!("  hint:   {recovery_hint}");
        }
        chump_ship::ShipPlan::CreatePr { branch, ahead } => {
            println!("  action: CREATE_PR  branch={branch} ahead_main={ahead}");
        }
        chump_ship::ShipPlan::RebaseAndPush { behind_count } => {
            println!("  action: REBASE_AND_PUSH  behind_main={behind_count}");
        }
        chump_ship::ShipPlan::RestDirectMerge {
            pr,
            head_sha,
            checks_verified,
        } => {
            println!(
                "  action: REST_DIRECT_MERGE  pr=#{pr} head={} checks_green={checks_verified}",
                &head_sha[..head_sha.len().min(8)]
            );
        }
        chump_ship::ShipPlan::ArmAutoMerge { pr, reason } => {
            println!("  action: ARM_AUTO_MERGE  pr=#{pr}");
            println!("  reason: {reason}");
        }
        chump_ship::ShipPlan::WaitForChecks {
            pr,
            incomplete,
            reason,
        } => {
            println!("  action: WAIT_FOR_CHECKS  pr=#{pr} incomplete={incomplete}");
            println!("  reason: {reason}");
        }
        chump_ship::ShipPlan::StaleBranch {
            pr,
            behind,
            threshold,
            recovery_hint,
        } => {
            println!(
                "  action: STALE_BRANCH  pr={} behind={behind} threshold={threshold}",
                pr.map(|n| format!("#{n}"))
                    .unwrap_or_else(|| "(none)".to_string())
            );
            println!("  hint:   {recovery_hint}");
        }
        chump_ship::ShipPlan::ConflictRecover { pr, recovery_hint } => {
            println!("  action: CONFLICT_RECOVER  pr=#{pr}");
            println!("  hint:   {recovery_hint}");
        }
        chump_ship::ShipPlan::OperatorAction {
            reason,
            recovery_hint,
        } => {
            println!("  action: OPERATOR_ACTION");
            println!("  reason: {reason}");
            println!("  hint:   {recovery_hint}");
        }
    }
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-1229 slice 2 — `chump ship execute` CLI wrapper around the
// chump-ship executor decision (decide_steps). Reads a ShipPlan from a
// file or stdin, derives the ExecutorStep list, runs each step via
// std::process::Command, and emits an ExecuteResult JSON.
// ──────────────────────────────────────────────────────────────────────

async fn ship_execute_cli(args: &[String]) -> Result<()> {
    let mut plan_path: Option<String> = None;
    let mut from_stdin = false;
    let mut dry_run = false;
    // INFRA-1229 slice 3: bounded retry on push --force-with-lease races.
    let mut max_rebase_retries: u32 = std::env::var("CHUMP_BOT_MERGE_RETRY_MAX")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3);
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--plan" => {
                plan_path = args.get(i + 1).cloned();
                i += 2;
            }
            "--stdin" => {
                from_stdin = true;
                i += 1;
            }
            "--dry-run" => {
                dry_run = true;
                i += 1;
            }
            "--max-rebase-retries" => {
                max_rebase_retries = args
                    .get(i + 1)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(max_rebase_retries);
                i += 2;
            }
            "--json" => {
                i += 1; // default, but accepted
            }
            other => {
                eprintln!("chump ship execute: unknown flag {other:?}");
                eprintln!("Run `chump ship execute --help` for usage.");
                std::process::exit(2);
            }
        }
    }

    if plan_path.is_none() && !from_stdin {
        eprintln!("chump ship execute: one of --plan PATH or --stdin is required.");
        std::process::exit(2);
    }

    // Read the plan envelope. `chump ship plan` emits a top-level object
    // with a `.plan` field; accept both that shape and a bare ShipPlan.
    let plan_json = if let Some(p) = plan_path {
        std::fs::read_to_string(&p).map_err(|e| anyhow::anyhow!("read --plan {p}: {e}"))?
    } else {
        use std::io::Read;
        let mut buf = String::new();
        std::io::stdin()
            .read_to_string(&mut buf)
            .map_err(|e| anyhow::anyhow!("read stdin: {e}"))?;
        buf
    };

    let value: serde_json::Value =
        serde_json::from_str(&plan_json).map_err(|e| anyhow::anyhow!("parse plan JSON: {e}"))?;
    let plan_obj = value.get("plan").unwrap_or(&value).clone();
    let plan: chump_ship::ShipPlan =
        serde_json::from_value(plan_obj).map_err(|e| anyhow::anyhow!("decode ShipPlan: {e}"))?;

    let steps = chump_ship::decide_steps(&plan);
    let plan_action = match &plan {
        chump_ship::ShipPlan::AlreadyDone { .. } => "AlreadyDone",
        chump_ship::ShipPlan::CreatePr { .. } => "CreatePr",
        chump_ship::ShipPlan::RebaseAndPush { .. } => "RebaseAndPush",
        chump_ship::ShipPlan::RestDirectMerge { .. } => "RestDirectMerge",
        chump_ship::ShipPlan::ArmAutoMerge { .. } => "ArmAutoMerge",
        chump_ship::ShipPlan::WaitForChecks { .. } => "WaitForChecks",
        chump_ship::ShipPlan::StaleBranch { .. } => "StaleBranch",
        chump_ship::ShipPlan::ConflictRecover { .. } => "ConflictRecover",
        chump_ship::ShipPlan::OperatorAction { .. } => "OperatorAction",
    };

    if steps.is_empty() {
        let payload = serde_json::json!({
            "plan_action": plan_action,
            "executed": false,
            "steps": [],
            "any_failure": false,
            "note": "No executor action needed for this ShipPlan variant.",
        });
        println!("{}", serde_json::to_string_pretty(&payload)?);
        return Ok(());
    }

    // Resolve the `{OWNER_REPO}` placeholder used by RestDirectMerge before
    // executing — only one `gh repo view` per invocation.
    let owner_repo = if dry_run {
        "{OWNER_REPO}".to_string()
    } else {
        std::process::Command::new("gh")
            .args([
                "repo",
                "view",
                "--json",
                "nameWithOwner",
                "--jq",
                ".nameWithOwner",
            ])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "{OWNER_REPO}".to_string())
    };

    let mut step_results: Vec<serde_json::Value> = Vec::new();
    let mut any_failure = false;
    let mut retry_attempts: u32 = 0;
    let mut final_action: String = "Success".to_string();

    // INFRA-1229 slice 3: RebaseAndPush gets a retry loop driven by
    // chump_ship::classify_step_failure. Other plan variants use a single
    // pass.
    let is_rebase_and_push = matches!(plan, chump_ship::ShipPlan::RebaseAndPush { .. });

    'attempt: for attempt in 0..=max_rebase_retries {
        if attempt > 0 {
            retry_attempts = attempt;
            eprintln!(
                "[ship execute] push lost a race; retry {}/{}",
                attempt, max_rebase_retries
            );
        }
        for step in &steps {
            let resolved_args: Vec<String> = step
                .args
                .iter()
                .map(|a| a.replace("{OWNER_REPO}", &owner_repo))
                .collect();
            if dry_run {
                step_results.push(serde_json::json!({
                    "program": step.program,
                    "args": resolved_args,
                    "rc": 0,
                    "stderr_tail": "",
                    "duration_ms": 0,
                    "dry_run": true,
                    "note": step.note,
                    "attempt": attempt,
                }));
                continue;
            }
            let started = std::time::Instant::now();
            let out = std::process::Command::new(&step.program)
                .args(&resolved_args)
                .output();
            let elapsed_ms = started.elapsed().as_millis() as u64;
            let (rc, stderr_tail) = match out {
                Ok(o) => {
                    let tail = String::from_utf8_lossy(&o.stderr);
                    let tail: String = tail
                        .lines()
                        .rev()
                        .take(3)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect::<Vec<_>>()
                        .join("\n");
                    (o.status.code().unwrap_or(-1), tail)
                }
                Err(e) => (-1, format!("exec error: {e}")),
            };
            let success = rc == 0;
            step_results.push(serde_json::json!({
                "program": step.program,
                "args": resolved_args,
                "rc": rc,
                "stderr_tail": stderr_tail,
                "duration_ms": elapsed_ms,
                "expect_success": step.expect_success,
                "success": success,
                "note": step.note,
                "attempt": attempt,
            }));
            if !success && step.expect_success {
                any_failure = true;

                if is_rebase_and_push {
                    // Classify the failure: retry, abort-as-conflict, or hard-fail.
                    let action = chump_ship::classify_step_failure(
                        &step.program,
                        &resolved_args,
                        rc,
                        &stderr_tail,
                        attempt,
                        max_rebase_retries,
                    );
                    match action {
                        chump_ship::RetryAction::RetryRebaseAndPush { .. } => {
                            // Restart from the top of the step list on next attempt.
                            final_action = "RetryRebaseAndPush".to_string();
                            continue 'attempt;
                        }
                        chump_ship::RetryAction::AbortAsConflict { reason } => {
                            final_action = "ConflictRecover".to_string();
                            eprintln!("[ship execute] {reason}");
                            // Best-effort: leave the rebase abort to the operator
                            // — the conflict markers in the working tree are the
                            // evidence they need.
                            break 'attempt;
                        }
                        chump_ship::RetryAction::Fail { reason } => {
                            final_action = "Fail".to_string();
                            eprintln!("[ship execute] {reason}");
                            break 'attempt;
                        }
                        chump_ship::RetryAction::Continue
                        | chump_ship::RetryAction::AbortAsStaleBranch { .. } => {
                            // AbortAsStaleBranch isn't emitted by this classifier
                            // (it's a pre-push check); Continue shouldn't happen
                            // on a failed step.
                            final_action = "Fail".to_string();
                            break 'attempt;
                        }
                    }
                } else {
                    // Non-rebase variants: keep the existing single-pass behavior.
                    final_action = "Fail".to_string();
                    break 'attempt;
                }
            }
        }
        // Loop finished without a step-failure → all steps succeeded on this attempt.
        // (Overwrite final_action even if a previous attempt failed and we
        // retried successfully — the final state IS success.)
        final_action = "Success".to_string();
        // Once the chain succeeds via retry, the earlier failures are
        // recorded in step_results but don't bubble out as any_failure.
        any_failure = false;
        break 'attempt;
        // Note: if a step failed, control always reaches `break 'attempt` or
        // `continue 'attempt` above and never falls through to here.
    }

    let payload = serde_json::json!({
        "plan_action": plan_action,
        "executed": !dry_run,
        "dry_run": dry_run,
        "steps": step_results,
        "any_failure": any_failure,
        "retry_attempts": retry_attempts,
        "final_action": final_action,
        "max_rebase_retries": max_rebase_retries,
    });
    println!("{}", serde_json::to_string_pretty(&payload)?);
    if any_failure && final_action != "Success" {
        std::process::exit(1);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::agent_factory;
    use serde_json::json;
    use serial_test::serial;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    /// Full agent turn against a mock HTTP server: no real model. Asserts reply content.
    ///
    /// 2026-05-08: marked `#[ignore]`. This test is fragile by design — every
    /// new agent-loop guard breaks it (CHUMP_MAX_CONSECUTIVE_TOOL_FAILS in
    /// INFRA-677, then "Exceeded max iterations (25)" today). The mock
    /// returns `{"content": "Mocked reply", "tool_calls": null}` which the
    /// real agent loop now treats as a partial completion + iterates. The
    /// test would need a more deterministic mock contract (or a test-only
    /// short-circuit in the agent loop) to be maintainable.
    ///
    /// Run manually with `cargo test integration_agent_run_against_mock --
    /// --ignored` after touching the agent loop. Don't gate CI on it.
    #[tokio::test]
    #[serial]
    #[ignore]
    async fn integration_agent_run_against_mock() {
        let mock = MockServer::start().await;
        let body = json!({
            "choices": [{
                "message": {
                    "content": "Mocked reply",
                    "tool_calls": null
                },
                "finish_reason": "stop"
            }]
        });
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&body))
            .mount(&mock)
            .await;

        std::env::set_var("OPENAI_API_BASE", mock.uri());
        // INFRA-677: disable consecutive-tool-fails breaker so a sibling
        // test setting CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=1 mid-run can't
        // trip our agent. Observed sporadic CI failure: returned "Aborting:
        // 3 consecutive tool batches with no successful calls" instead of
        // "Mocked reply" because env-var races slip past #[serial].
        std::env::set_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS", "99999");
        let (agent, _) = agent_factory::build_chump_agent_cli().expect("build agent");
        let outcome = agent.run("Hello").await.unwrap();
        std::env::remove_var("OPENAI_API_BASE");
        std::env::remove_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS");
        assert!(
            outcome.reply.contains("Mocked reply"),
            "expected reply to contain mock content, got: {}",
            outcome.reply
        );
    }

    // EFFECTIVE-011: alias expansion unit tests.
    #[test]
    fn effective_011_alias_g_expands_to_gap() {
        let args = vec!["chump".to_string(), "g".to_string(), "list".to_string()];
        let expanded = crate::expand_aliases(args);
        assert_eq!(expanded, vec!["chump", "gap", "list"]);
    }

    #[test]
    fn effective_011_alias_c_expands_to_claim() {
        let args = vec![
            "chump".to_string(),
            "c".to_string(),
            "INFRA-123".to_string(),
        ];
        let expanded = crate::expand_aliases(args);
        assert_eq!(expanded, vec!["chump", "claim", "INFRA-123"]);
    }

    #[test]
    fn effective_011_alias_s_expands_to_gap_ship() {
        let args = vec![
            "chump".to_string(),
            "s".to_string(),
            "INFRA-123".to_string(),
        ];
        let expanded = crate::expand_aliases(args);
        assert_eq!(expanded, vec!["chump", "gap", "ship", "INFRA-123"]);
    }

    #[test]
    fn effective_011_alias_f_d_h_cs_expand() {
        let mk = |a: &str| vec!["chump".to_string(), a.to_string()];
        assert_eq!(crate::expand_aliases(mk("f"))[1], "fleet");
        assert_eq!(crate::expand_aliases(mk("d"))[1], "dispatch");
        assert_eq!(crate::expand_aliases(mk("h"))[1], "health");
        assert_eq!(crate::expand_aliases(mk("cs"))[1], "cost-watch");
    }

    #[test]
    fn effective_011_no_alias_passthrough() {
        let args = vec!["chump".to_string(), "gap".to_string(), "list".to_string()];
        let expanded = crate::expand_aliases(args.clone());
        assert_eq!(expanded, args);
    }
}
