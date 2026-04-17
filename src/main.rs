//! Minimal AxonerAI agent that talks to an OpenAI-compatible endpoint (e.g. Ollama on localhost).
//! Set OPENAI_API_BASE (e.g. http://localhost:11434/v1) to use a local server; default is Ollama.
//! Run with no args for interactive chat; pass a message for single-shot; --discord to run Discord bot (DISCORD_TOKEN required).

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod a2a_tool;
mod acp;
mod acp_server;
mod adapters;
mod agent_lease;
pub mod agent_loop;
mod agent_session;
mod agent_turn;
mod approval_resolver;
mod ask_jeff_db;
mod ask_jeff_tool;
mod autonomy_fsm;
mod autonomy_loop;
mod autopilot;
mod battle_qa_tool;
mod belief_state;
mod blackboard;
mod browser;
mod browser_tool;
mod calc_tool;
mod checkpoint_db;
mod checkpoint_tool;
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
mod db_pool;
mod decompose_task_tool;
mod delegate_tool;
mod desktop_launcher;
mod diff_review_tool;
mod discord;
mod discord_dm;
mod doctor;
mod ego_tool;
mod env_flags;
mod episode_db;
mod episode_tool;
mod eval_harness;
mod file_watch;
mod fleet;
mod fleet_db;
mod fleet_tool;
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
mod memory_brain_tool;
mod memory_db;
mod memory_graph;
mod memory_graph_tool;
mod memory_graph_viz;
mod memory_tool;
#[cfg(feature = "mistralrs-infer")]
mod mistralrs_provider;
mod neuromodulation;
mod notify_tool;
mod onboard_repo_tool;
mod patch_apply;
mod pending_peer_approval;
mod perception;
mod phi_proxy;
mod pilot_metrics;
mod plugin;
mod policy_override;
mod precision_controller;
mod provider_cascade;
mod provider_quality;
mod ratings;
mod read_url_tool;
mod reflection;
mod reflection_db;
mod repo_allowlist;
mod repo_allowlist_tool;
mod repo_path;
mod repo_tools;
mod routes;
mod rpc_mode;
mod run_test_tool;
mod sandbox_tool;
mod schedule_db;
mod schedule_tool;
mod screen_vision_tool;
mod session;
mod session_search_tool;
mod set_working_repo_tool;
mod skill_db;
mod skill_hub;
mod skill_hub_tool;
mod skill_metrics;
mod skill_tool;
mod skills;
mod spawn_worker_tool;
mod speculative_execution;
mod state_db;
mod stream_events;
mod streaming_provider;
mod surprise_tracker;
mod task_contract;
mod task_db;
mod task_executor;
mod task_planner_tool;
mod task_tool;
mod tda_blackboard;
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
mod vector6_verify;
mod vector7_swarm_verify;
mod version;
#[cfg(feature = "voice")]
mod voice;
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
use std::io::{self, Read, Write};

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
        let script = repo_path::repo_root().join("scripts/chump-preflight.sh");
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
    // See docs/AGENT_COORDINATION.md for the full cheatsheet.
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
    let chump_mode = args.get(1).map(|s| s == "--chump").unwrap_or(false);

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
