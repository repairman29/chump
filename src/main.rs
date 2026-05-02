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
mod agent_lease;
pub mod agent_loop;
mod agent_session;
mod agent_turn;
mod ambient_stream;
mod approval_resolver;
mod asi_telemetry;
mod ask_jeff_db;
mod ask_jeff_tool;
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
mod checkpoint_db;
mod checkpoint_tool;
mod chump_init;
mod chump_log;
mod cli_tool;
mod cluster_mesh;
mod codebase_digest_tool;
mod config_validation;
mod consciousness_traits;
mod context_assembly;
mod context_engine;
mod context_firewall;
mod context_window;
mod cost_tracker;
mod counterfactual;
mod dashboard;
mod db_pool;
mod decompose_task_tool;
mod delegate_tool;
mod desktop_launcher;
mod diff_review_tool;
mod discord;
mod discord_dm;
mod discord_intent;
mod doctor;
mod ego_tool;
mod env_flags;
mod episode_db;
mod episode_extractor;
mod episode_tool;
mod eval_harness;
mod execute_gap;
mod file_watch;
mod fleet;
mod fleet_capability;
mod fleet_db;
mod fleet_tool;
mod ftue_tool;
mod gap_store;
mod genai_conv;
mod git_tools;
mod health_server;
mod hitl_escalation;
mod holographic_workspace;
mod hooks;
mod interrupt_notify;
mod introspect_tool;
mod job_log;
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
#[cfg(feature = "mistralrs-infer")]
mod mistralrs_provider;
mod model_overlay;
mod neuromodulation;
mod notify_tool;
mod onboard_repo_tool;
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
mod precision_controller;
mod provider_bandit;
mod provider_cascade;
mod provider_quality;
mod ratings;
mod read_url_tool;
mod reasoning_mode;
mod recipe;
mod reflection;
mod reflection_db;
mod repo_allowlist;
mod repo_allowlist_tool;
mod repo_path;
mod repo_tools;
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
mod session_search_tool;
mod set_working_repo_tool;
mod skill_db;
mod skill_hub;
mod skill_hub_tool;
mod skill_metrics;
mod skill_tool;
mod skills;
mod slack;
mod spawn_worker_tool;
mod speculative_execution;
mod state_db;
mod stream_events;
mod streaming_provider;
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

use anyhow::Result;
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

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.iter().any(|a| a == "--desktop") {
        desktop_launcher::launch_and_wait(&args);
    }
    load_dotenv();

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
        activation::print_funnel();
        return Ok(());
    }

    // `chump dashboard` (INFRA-063 / M5) — print the cycle-time dashboard:
    // PRs landed today/week, median PR-open time, dispatcher backend split,
    // top 5 stale linked worktrees. Pure read aggregator over `gh` + `git`.
    if args.get(1).map(String::as_str) == Some("dashboard") {
        if let Err(e) = dashboard::print_dashboard() {
            eprintln!("chump dashboard: {e:#}");
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
            "list" => {
                let status_filter = flag("--status");
                match store.list(status_filter.as_deref()) {
                    Ok(gaps) => {
                        if json_out {
                            println!(
                                "{}",
                                serde_json::to_string_pretty(&gaps).unwrap_or_default()
                            );
                        } else {
                            for g in &gaps {
                                println!(
                                    "[{}] {} — {} ({}/{})",
                                    g.status, g.id, g.title, g.priority, g.effort
                                );
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
                match store.reserve(&domain, &title, &priority, &effort) {
                    Ok(id) => {
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
                        let per_file_dir = repo_root.join("docs").join("gaps");
                        match store.dump_per_file_single(&id, &per_file_dir) {
                            Ok(true) => {
                                eprintln!(
                                    "wrote {}",
                                    per_file_dir.join(format!("{id}.yaml")).display()
                                );
                                write_yaml_op_marker(&repo_root, "reserve");
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
                let session_id = flag("--session")
                    .or_else(|| std::env::var("CLAUDE_SESSION_ID").ok())
                    .or_else(|| std::env::var("CHUMP_SESSION_ID").ok())
                    .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                let worktree = flag("--worktree").unwrap_or_default();
                let ttl: i64 = flag("--ttl").and_then(|s| s.parse().ok()).unwrap_or(3600);
                match store.claim(&gap_id, &session_id, &worktree, ttl) {
                    Ok(()) => {
                        println!("claimed {} for session {}", gap_id, session_id);
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap claim: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "preflight" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap preflight <GAP-ID>");
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
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N]");
                    std::process::exit(2);
                });
                let session_id = flag("--session")
                    .or_else(|| std::env::var("CLAUDE_SESSION_ID").ok())
                    .or_else(|| std::env::var("CHUMP_SESSION_ID").ok())
                    .unwrap_or_else(|| format!("chump-anon-{}", unix_ts()));
                let update_yaml = args.iter().any(|a| a == "--update-yaml");
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
                match store.ship(&gap_id, &session_id, closed_pr) {
                    Ok(()) => {
                        println!("shipped {}", gap_id);
                        if update_yaml {
                            // INFRA-148: warn if this binary predates the most recent
                            // gap_store-affecting commit on the repo's HEAD before mutating
                            // the YAML mirror. Pre-INFRA-147 binaries silently stripped the
                            // meta: preamble (~20k-line corruption observed 2026-04-27); a
                            // fresh build catches that and similar future serialization
                            // changes.
                            let _ = version::warn_if_stale_for_gap_mutation(&repo_root);
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
                            let per_file_dir = repo_root.join("docs").join("gaps");
                            match store.dump_per_file_single(&gap_id, &per_file_dir) {
                                Ok(true) => {
                                    eprintln!(
                                        "wrote {}",
                                        per_file_dir.join(format!("{gap_id}.yaml")).display()
                                    );
                                    write_yaml_op_marker(&repo_root, "ship");
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
            "set" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!(
                        "Usage: chump gap set <GAP-ID> [--title T] [--description D] [--priority P]"
                    );
                    eprintln!("                          [--effort E] [--status S] [--notes N]");
                    eprintln!("                          [--source-doc S] [--opened-date D] [--closed-date D]");
                    eprintln!("                          [--closed-pr N] [--acceptance-criteria \"a|b|c\"] [--depends-on \"X,Y\"]");
                    std::process::exit(2);
                });
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
                let update = gap_store::GapFieldUpdate {
                    title: flag("--title"),
                    description: flag("--description"),
                    priority: flag("--priority"),
                    effort: flag("--effort"),
                    status: flag("--status"),
                    acceptance_criteria,
                    depends_on,
                    notes: flag("--notes"),
                    source_doc: flag("--source-doc"),
                    opened_date: flag("--opened-date"),
                    closed_date: flag("--closed-date"),
                    closed_pr,
                };
                match store.set_fields(&gap_id, update) {
                    Ok(()) => {
                        println!("updated {}", gap_id);
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

                // INFRA-148: warn if binary is stale relative to gap_store-affecting
                // code on HEAD. Only warn when actually writing to a file
                // (--out PATH or --per-file) — stdout dump for piping shouldn't
                // spam stderr unconditionally.
                if out_path.is_some() || per_file {
                    let _ = version::warn_if_stale_for_gap_mutation(&repo_root);
                }

                // ── INFRA-188 v0: --per-file path ────────────────────────────
                if per_file {
                    let dir_str = out_dir_flag.unwrap_or_else(|| "docs/gaps".to_string());
                    let dir = std::path::PathBuf::from(&dir_str);
                    let dir_abs = if dir.is_absolute() {
                        dir
                    } else {
                        repo_root.join(dir)
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
                            write_yaml_op_marker(&repo_root, "dump --per-file");
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
                            // canonical (not a raw hand-edit).
                            write_yaml_op_marker(&repo_root, "dump");
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
                let root = if std::path::Path::new(&yaml_path).is_absolute() {
                    std::path::PathBuf::from("/")
                } else {
                    repo_root.clone()
                };
                match store.import_from_yaml(&root) {
                    Ok((ins, skip)) => {
                        eprintln!(
                            "import complete: {} inserted, {} skipped (already present).",
                            ins, skip
                        );
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump gap import: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            _ => {
                eprintln!("chump gap <subcommand> [options]");
                eprintln!("  list       [--status open|done] [--json]");
                eprintln!("  reserve    --domain D --title T [--priority P1] [--effort s]");
                eprintln!("               (positional) D title…  — same as --domain / --title");
                eprintln!("  claim      <GAP-ID> [--session ID] [--worktree PATH] [--ttl 3600]");
                eprintln!("  preflight  <GAP-ID>");
                eprintln!("  ship       <GAP-ID> [--session ID] [--update-yaml] [--closed-pr N]");
                eprintln!("  set        <GAP-ID> [--title T] [--description D] [--priority P]");
                eprintln!("                       [--effort E] [--status S] [--notes N]");
                eprintln!(
                    "                       [--source-doc S] [--opened-date D] [--closed-date D] [--closed-pr N]"
                );
                eprintln!("                       [--acceptance-criteria \"a|b|c\"] [--depends-on \"X-1,X-2\"]");
                eprintln!("  dump       [--out PATH] [--per-file [--out-dir docs/gaps/]]");
                eprintln!("  import     [--yaml docs/gaps.yaml]");
                std::process::exit(2);
            }
        }
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
        match execute_gap::execute_gap(gap_id).await {
            Ok(reply) => {
                print!("{reply}");
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump --execute-gap {gap_id}: {e:#}");
                std::process::exit(1);
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
        let exit_code = if args.iter().any(|a| a == "--json") {
            doctor::print_json_report(&report)
        } else {
            doctor::print_human_report(&report)
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

    // `chump mcp list` (INFRA-MCP-DISCOVERY) — enumerate discovered MCP servers
    // grouped by source (PATH, user-config, system). Works without validate_config()
    // so it is useful during setup / debugging.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "list").unwrap_or(false)
    {
        let servers = mcp_discovery::discover_mcp_servers();
        mcp_discovery::print_mcp_list(&servers);
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
        // Release this session's lease, or a named one with --session-id=<id>.
        let override_id = args.iter().find_map(|a| a.strip_prefix("--session-id="));
        let target_id = override_id
            .map(|s| s.to_string())
            .unwrap_or_else(agent_lease::current_session_id);
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
        match agent_lease::release(&stub) {
            Ok(()) => {
                println!("released session_id={}", target_id);
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

    let autonomy_once = args.iter().any(|a| a == "--autonomy-once");
    if autonomy_once {
        config_validation::validate_config();
        let assignee_from_env = std::env::var("CHUMP_AUTONOMY_ASSIGNEE").ok();
        let assignee = args
            .windows(2)
            .find(|w| w[0] == "--assignee")
            .map(|w| w[1].as_str())
            .or(assignee_from_env.as_deref())
            .unwrap_or("chump");
        let out = autonomy_loop::autonomy_once(assignee).await?;
        println!(
            "status={} task_id={:?} detail={}",
            out.status, out.task_id, out.detail
        );
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
    }

    if chump_mode {
        eprintln!("Chump version {}", version::chump_version());
        if let Some(port) = env::var("CHUMP_HEALTH_PORT")
            .ok()
            .and_then(|p| p.parse::<u16>().ok())
        {
            tokio::spawn(health_server::run(port));
        }
        let (agent, ready_session) = discord::build_chump_agent_cli()?;
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

#[cfg(test)]
mod tests {
    use crate::discord;
    use serde_json::json;
    use serial_test::serial;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    /// Full agent turn against a mock HTTP server: no real model. Asserts reply content.
    #[tokio::test]
    #[serial]
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
        let (agent, _) = discord::build_chump_agent_cli().expect("build agent");
        let outcome = agent.run("Hello").await.unwrap();
        std::env::remove_var("OPENAI_API_BASE");
        assert!(
            outcome.reply.contains("Mocked reply"),
            "expected reply to contain mock content, got: {}",
            outcome.reply
        );
    }
}
