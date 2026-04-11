//! Minimal AxonerAI agent that talks to an OpenAI-compatible endpoint (e.g. Ollama on localhost).
//! Set OPENAI_API_BASE (e.g. http://localhost:11434/v1) to use a local server; default is Ollama.
//! Run with no args for interactive chat; pass a message for single-shot; --discord to run Discord bot (DISCORD_TOKEN required).

mod a2a_tool;
mod adb_tool;
mod agent_loop;
mod agent_session;
mod agent_turn;
mod approval_resolver;
mod ask_jeff_db;
mod ask_jeff_tool;
mod autonomy_loop;
mod autopilot;
mod battle_qa_tool;
mod belief_state;
mod blackboard;
mod calc_tool;
mod chump_log;
mod cli_tool;
mod codebase_digest_tool;
mod config_validation;
mod consciousness_traits;
mod context_assembly;
mod context_window;
mod cost_tracker;
mod cluster_mesh;
mod counterfactual;
mod db_pool;
mod decompose_task_tool;
mod delegate_tool;
mod desktop_launcher;
mod diff_review_tool;
mod discord;
mod discord_dm;
mod ego_tool;
mod env_flags;
mod episode_db;
mod episode_tool;
mod file_watch;
mod gh_tools;
mod git_tools;
mod github_tools;
mod health_server;
mod holographic_workspace;
mod interrupt_notify;
mod introspect_tool;
mod limits;
mod local_openai;
mod memory_brain_tool;
mod memory_db;
mod memory_graph;
mod memory_tool;
mod neuromodulation;
mod notify_tool;
mod onboard_repo_tool;
mod pending_peer_approval;
mod phi_proxy;
mod pilot_metrics;
mod precision_controller;
mod provider_cascade;
mod provider_quality;
mod read_url_tool;
mod repo_allowlist;
mod repo_allowlist_tool;
mod repo_path;
mod repo_tools;
mod rpc_mode;
mod run_test_tool;
mod sandbox_tool;
mod schedule_db;
mod schedule_tool;
mod screen_vision_tool;
mod session;
mod set_working_repo_tool;
mod spawn_worker_tool;
mod speculative_execution;
mod state_db;
mod stream_events;
mod streaming_provider;
mod surprise_tracker;
mod task_contract;
mod task_db;
mod task_executor;
mod task_tool;
mod task_planner_tool;
mod tavily_tool;
mod test_aware;
mod thinking_strip;
mod tool_health_db;
mod tool_input_validate;
mod tool_inventory;
mod tool_middleware;
mod tool_policy;
mod tool_routing;
mod toolkit_status_tool;
mod version;
mod wasm_calc_tool;
mod wasm_runner;
mod web_brain;
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
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_target(true)
        .try_init();
    let check_config = args.get(1).map(|s| s == "--check-config").unwrap_or(false);
    if check_config {
        config_validation::validate_config();
        return Ok(());
    }
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
        return Ok(());
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

    let web_mode = args.iter().any(|a| a == "--web");
    let discord_mode = args.iter().any(|a| a == "--discord");
    let chump_mode = args.get(1).map(|s| s == "--chump").unwrap_or(false);

    if web_mode && !discord_mode {
        config_validation::validate_config();
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
                let label = std::env::var("CHUMP_BATTLE_LABEL").unwrap_or_else(|_| "cli_battle".into());
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
    let system_prompt = Some("You are a helpful assistant.".to_string());

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
