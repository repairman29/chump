//! Chump's agent factory — constructors for CLI, web, and dispatched-gap
//! agents. Used by every backend that spawns a Chump agent (web_server,
//! telegram, slack, rpc_mode, autonomy_loop, execute_gap, acp_server,
//! platform_router, e2e_bot_tests, plus discord.rs's own build_agent).
//!
//! Extracted from src/discord.rs in META-013 (2026-05-02): the factory
//! lived in the Discord module purely for historical reasons (CLI agent
//! was first written next to the Discord one). Pulling it out lets
//! discord.rs become a self-contained Discord backend, which is the
//! pre-requisite for SECURITY-004 Path B (feature-gating Discord to
//! drop the vulnerable serenity dep chain by default).
//!
//! No behavior change: all four functions ship byte-identical agent
//! configurations.

use anyhow::Result;
use axonerai::agent::Agent;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::tool::ToolRegistry;

use crate::agent_loop::ChumpAgent;
use crate::memory_tool::MemoryTool;
use crate::repo_path;
use crate::session::Session;
use crate::system_prompt::{chump_system_prompt, env_is_mabel};
use crate::tool_routing;

pub struct WebAgentBuild {
    pub provider: Box<dyn axonerai::provider::Provider + Send + Sync>,
    pub registry: ToolRegistry,
    pub session_manager: FileSessionManager,
    pub system_prompt: String,
    #[cfg(feature = "mistralrs-infer")]
    pub mistral_for_stream: Option<std::sync::Arc<crate::mistralrs_provider::MistralRsProvider>>,
}

/// Build Chump agent with full tools and soul for CLI (no Discord). Session "cli", memory source 0.
/// Returns the agent and a typed session in Ready state; caller must call `.start()` when entering
/// the run and `.close()` when the run ends (so close_session is called exactly once).
/// Uses ChumpAgent (not axonerai Agent) so text-format tool calls from cascade models are parsed and executed.
pub fn build_chump_agent_cli() -> Result<(ChumpAgent, Session<crate::session::Ready>)> {
    tool_routing::log_tool_inventory();
    let typed = Session::new().assemble();
    let provider: Box<dyn axonerai::provider::Provider + Send + Sync> =
        crate::provider_cascade::build_provider();

    let mut registry = ToolRegistry::new();
    crate::tool_inventory::register_from_inventory(&mut registry);
    registry.register(crate::tool_middleware::wrap_tool(Box::new(
        MemoryTool::for_discord(0),
    )));

    let session_dir = repo_path::runtime_base().join("sessions").join("cli");
    let _ = std::fs::create_dir_all(&session_dir);
    let session_manager = FileSessionManager::new("cli".to_string(), session_dir)?;
    let agent = ChumpAgent::new(
        provider,
        registry,
        Some(chump_system_prompt(typed.context_str(), env_is_mabel())),
        Some(session_manager),
        None, // no event channel for CLI
        // max_iterations: env-overridable for unattended dispatched-gap mode where
        // 25 hits the cap before the agent ships (observed Together V2 run
        // 2026-04-19 — Qwen3-235B exhausted iterations during exploration phase
        // before reaching bot-merge.sh). Default stays 25 for interactive CLI;
        // execute-gap path bumps via CHUMP_AGENT_MAX_ITER=50 (orchestrator.rs
        // clamps to 1..=50).
        std::env::var("CHUMP_AGENT_MAX_ITER")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(25),
    );
    Ok((agent, typed))
}

/// Web agent components for streaming or non-streaming use.
/// `bot`: Some("mabel") | Some("chump") | None (use CHUMP_MABEL env).
pub fn build_chump_agent_web_components(
    session_id: &str,
    bot: Option<&str>,
) -> Result<WebAgentBuild> {
    let session_id = if session_id.trim().is_empty() {
        "default"
    } else {
        session_id.trim()
    };
    let typed = Session::new().assemble();
    let session_dir = repo_path::runtime_base()
        .join("sessions")
        .join("web")
        .join(session_id);
    let _ = std::fs::create_dir_all(&session_dir);
    let session_manager = FileSessionManager::new(session_id.to_string(), session_dir)?;
    tool_routing::log_tool_inventory();
    #[cfg(feature = "mistralrs-infer")]
    let (provider, mistral_for_stream) =
        crate::provider_cascade::build_provider_with_mistral_stream();
    #[cfg(not(feature = "mistralrs-infer"))]
    let provider = crate::provider_cascade::build_provider();

    let mut registry = ToolRegistry::new();
    crate::tool_inventory::register_from_inventory(&mut registry);
    registry.register(crate::tool_middleware::wrap_tool(Box::new(
        MemoryTool::for_discord(0),
    )));

    let is_mabel = bot
        .map(|b| b.eq_ignore_ascii_case("mabel"))
        .unwrap_or_else(env_is_mabel);
    Ok(WebAgentBuild {
        provider,
        registry,
        session_manager,
        system_prompt: chump_system_prompt(typed.context_str(), is_mabel),
        #[cfg(feature = "mistralrs-infer")]
        mistral_for_stream,
    })
}

/// Build Chump agent for web mode: same as CLI but session under sessions/web/<session_id>.
#[allow(dead_code)] // public API for web server or callers that want a full Agent
pub fn build_chump_agent_web(session_id: &str) -> Result<Agent> {
    let b = build_chump_agent_web_components(session_id, None)?;
    Ok(Agent::new(
        b.provider,
        b.registry,
        Some(b.system_prompt),
        Some(b.session_manager),
    ))
}
