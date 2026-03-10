//! Discord gateway: receive messages, run agent, reply. Token from DISCORD_TOKEN only.
//! Chump has a configurable soul/purpose (CHUMP_SYSTEM_PROMPT), per-channel memory, and tools.
//! When CHUMP_WARM_SERVERS=1, the first message triggers warm-the-ovens (start MLX servers on demand).
//! Only one bot process should run per token; multiple processes each receive every message and reply once, causing duplicate replies (e.g. 3x if 3 processes). run-discord.sh guards against starting a second instance.

use anyhow::Result;
use serenity::async_trait;
use serenity::model::channel::Message;
use serenity::model::gateway::Ready;
use serenity::model::id::ChannelId;
use serenity::prelude::*;
use std::path::PathBuf;
use std::process::Stdio;

use crate::chump_log;
use crate::cli_tool::{CliTool, CliToolAlias};
use crate::local_openai;
use crate::memory_tool::MemoryTool;
use axonerai::agent::Agent;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::openai::OpenAIProvider;
use axonerai::tool::ToolRegistry;
use crate::calc_tool::ChumpCalculator;
use crate::wasm_calc_tool::{wasm_calc_available, WasmCalcTool};
use crate::delegate_tool::DelegateTool;
use crate::tavily_tool::{tavily_enabled, TavilyTool};
use serenity::model::id::UserId;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;

fn delegate_enabled() -> bool {
    std::env::var("CHUMP_DELEGATE")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

const CHUMP_DEFAULT_SOUL: &str = "You are Chump, a friendly, sharp-witted assistant with long-term memory. \
Your tools: run_cli (shell commands), memory (store/recall), calculator (math), when available wasm_calc (sandboxed arithmetic), when delegate enabled: delegate (summarize, extract), and when web_search is available: web_search (Tavily; use for research and self-improvement — look things up and store learnings in memory; we have limited monthly credits so use one focused query per call). Do not use or invent other tools. \
When the user says 'Use run_cli to run: X' you MUST call run_cli with command exactly X, then reply with the output or a one-sentence summary. \
You are often given 'Relevant context from memory' above the user message: use it to answer specifically. \
Store important facts and things you learn from web search with memory action=store so future turns get them. Use calculator for math. One command per run_cli call. \
Reply with your final answer only: do not include <think>, think>, or other reasoning blocks in your reply. \
You're concise and warm. Stay in character.";

const CHUMP_PROJECT_SOUL: &str = "You are Chump, a friendly dev buddy in Discord. Your focus: help the user build and organize code projects and repos. \
Your tools: run_cli, memory, calculator, when available wasm_calc and web_search (research/self-improvement; use sparingly). When delegate enabled: delegate (summarize, extract). Do not use or invent other tools. \
You are often given 'Relevant context from memory' above the user message: use it to answer specifically. Store important facts with memory action=store. \
When the user says 'Use run_cli to run: X' you MUST call run_cli with command exactly X. You propose short plans; run git, cargo, pnpm via run_cli. \
Reply with your final answer only: do not include <think>, think>, or other reasoning blocks in your reply. \
You're concise and warm. Stay in character.";

/// If CHUMP_WARM_SERVERS=1, run warm-the-ovens.sh and wait (up to 90s). Returns true if ready or skipped, false if timeout.
async fn ensure_ovens_warm() -> bool {
    if std::env::var("CHUMP_WARM_SERVERS")
        .map(|v| v != "1" && !v.eq_ignore_ascii_case("true"))
        .unwrap_or(true)
    {
        return true;
    }
    let root = std::env::var("CHUMP_HOME").unwrap_or_else(|_| ".".to_string());
    let script = PathBuf::from(&root).join("scripts").join("warm-the-ovens.sh");
    if !script.exists() {
        eprintln!("CHUMP_WARM_SERVERS=1 but script not found: {:?}", script);
        return true;
    }
    let root_clone = root.clone();
    let mut cmd = tokio::process::Command::new("sh");
    cmd.arg(script)
        .current_dir(&root_clone)
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    match tokio::time::timeout(std::time::Duration::from_secs(90), cmd.output()).await {
        Ok(Ok(out)) if out.status.success() => true,
        Ok(Ok(_)) => {
            eprintln!("warm-the-ovens.sh exited with error");
            false
        }
        Ok(Err(e)) => {
            eprintln!("warm-the-ovens.sh failed: {}", e);
            false
        }
        Err(_) => false,
    }
}

/// Strip thinking/reasoning blocks so only the final reply is sent to Discord.
fn strip_thinking(reply: &str) -> String {
    let mut out = reply.to_string();
    // Remove <think>...</think> blocks (case-insensitive)
    loop {
        let lower = out.to_lowercase();
        if let Some(start) = lower.find("<think>") {
            let after_open = start + 7;
            if let Some(rel_end) = lower[after_open..].find("</think>") {
                let end = after_open + rel_end + 8;
                out = format!("{}{}", &out[..start], &out[end..]);
            } else {
                out = out[..start].trim_end().to_string();
                break;
            }
        } else {
            break;
        }
    }
    // Remove lines that start with think> (optional leading whitespace)
    out = out
        .lines()
        .filter(|line| !line.trim_start().to_lowercase().starts_with("think>"))
        .map(|s| s.to_string())
        .collect::<Vec<_>>()
        .join("\n");
    out.trim().to_string()
}

fn chump_system_prompt() -> String {
    if let Ok(custom) = std::env::var("CHUMP_SYSTEM_PROMPT") {
        return custom;
    }
    if std::env::var("CHUMP_PROJECT_MODE").map(|v| v == "1" || v.eq_ignore_ascii_case("true")).unwrap_or(false) {
        return CHUMP_PROJECT_SOUL.to_string();
    }
    CHUMP_DEFAULT_SOUL.to_string()
}

/// Build Chump agent with full tools and soul for CLI (no Discord). Session "cli", memory source 0.
pub fn build_chump_agent_cli() -> Result<Agent> {
    let api_key = std::env::var("OPENAI_API_KEY").unwrap_or_else(|_| "token-abc123".to_string());
    let model = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-5-mini".to_string());
    let provider: Box<dyn axonerai::provider::Provider> =
        if let Ok(base) = std::env::var("OPENAI_API_BASE") {
            let fallback = std::env::var("CHUMP_FALLBACK_API_BASE").ok().filter(|s| !s.is_empty());
            Box::new(local_openai::LocalOpenAIProvider::with_fallback(base, fallback, api_key, model))
        } else {
            Box::new(OpenAIProvider::new(api_key).with_model(model))
        };

    let mut registry = ToolRegistry::new();
    registry.register(Box::new(ChumpCalculator));
    if wasm_calc_available() {
        registry.register(Box::new(WasmCalcTool));
    }
    if delegate_enabled() {
        registry.register(Box::new(DelegateTool));
    }
    if tavily_enabled() {
        registry.register(Box::new(TavilyTool));
    }
    registry.register(Box::new(CliTool::for_discord()));
    registry.register(Box::new(CliToolAlias { name: "git".to_string(), inner: CliTool::for_discord() }));
    registry.register(Box::new(CliToolAlias { name: "cargo".to_string(), inner: CliTool::for_discord() }));
    registry.register(Box::new(MemoryTool::for_discord(0)));

    let session_dir = PathBuf::from("./sessions/cli");
    let session_manager = FileSessionManager::new("cli".to_string(), session_dir)?;
    Ok(Agent::new(
        provider,
        registry,
        Some(chump_system_prompt()),
        Some(session_manager),
    ))
}

fn build_agent(channel_id: ChannelId) -> Result<Agent> {
    let api_key = std::env::var("OPENAI_API_KEY").unwrap_or_else(|_| "token-abc123".to_string());
    let model = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-5-mini".to_string());
    let provider: Box<dyn axonerai::provider::Provider> =
        if let Ok(base) = std::env::var("OPENAI_API_BASE") {
            let fallback = std::env::var("CHUMP_FALLBACK_API_BASE").ok().filter(|s| !s.is_empty());
            Box::new(local_openai::LocalOpenAIProvider::with_fallback(base, fallback, api_key, model))
        } else {
            Box::new(OpenAIProvider::new(api_key).with_model(model))
        };

    let mut registry = ToolRegistry::new();
    registry.register(Box::new(ChumpCalculator));
    if wasm_calc_available() {
        registry.register(Box::new(WasmCalcTool));
    }
    if delegate_enabled() {
        registry.register(Box::new(DelegateTool));
    }
    if tavily_enabled() {
        registry.register(Box::new(TavilyTool));
    }
    registry.register(Box::new(CliTool::for_discord()));
    registry.register(Box::new(CliToolAlias { name: "git".to_string(), inner: CliTool::for_discord() }));
    registry.register(Box::new(CliToolAlias { name: "cargo".to_string(), inner: CliTool::for_discord() }));
    registry.register(Box::new(MemoryTool::for_discord(channel_id.get())));

    let session_dir = PathBuf::from("./sessions/discord");
    let session_id = channel_id.to_string();
    let session_manager = FileSessionManager::new(session_id, session_dir)?;

    Ok(Agent::new(
        provider,
        registry,
        Some(chump_system_prompt()),
        Some(session_manager),
    ))
}

fn rate_limit_turns_per_min() -> u32 {
    std::env::var("CHUMP_RATE_LIMIT_TURNS_PER_MIN")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

fn rate_limit_check(channel_id: u64) -> bool {
    let limit = rate_limit_turns_per_min();
    if limit == 0 {
        return true;
    }
    static STATE: std::sync::OnceLock<Mutex<std::collections::HashMap<u64, VecDeque<Instant>>>> =
        std::sync::OnceLock::new();
    let state = STATE.get_or_init(|| Mutex::new(std::collections::HashMap::new()));
    let mut guard = match state.lock() {
        Ok(g) => g,
        Err(_) => return true,
    };
    let window = Duration::from_secs(60);
    let now = Instant::now();
    let entries = guard.entry(channel_id).or_default();
    while entries.front().map_or(false, |t| now.saturating_duration_since(*t) > window) {
        entries.pop_front();
    }
    if entries.len() >= limit as usize {
        return false;
    }
    entries.push_back(now);
    true
}

/// Parse CHUMP_MAX_CONCURRENT_TURNS: 0 = no limit, 1..=32 = semaphore permits. Returns None when 0 (no cap).
fn max_concurrent_turns_semaphore() -> Option<Arc<Semaphore>> {
    let n = std::env::var("CHUMP_MAX_CONCURRENT_TURNS")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);
    if n == 0 {
        return None;
    }
    let permits = n.clamp(1, 32);
    Some(Arc::new(Semaphore::new(permits)))
}

struct Handler {
    /// When set, limits concurrent Discord turns; try_acquire before spawn, hold permit for turn duration.
    turn_semaphore: Option<Arc<Semaphore>>,
}

#[async_trait]
impl EventHandler for Handler {
    async fn ready(&self, ctx: Context, ready: Ready) {
        println!("Discord connected as {}", ready.user.name);
        if let Ok(id_str) = std::env::var("CHUMP_READY_DM_USER_ID") {
            let id_str = id_str.trim();
            if let Ok(id) = id_str.parse::<u64>() {
                let user_id = UserId::new(id);
                if let Ok(channel) = user_id.create_dm_channel(&ctx).await {
                    let msg = "Chump is online and ready to chat. I have web search (Tavily) for research and self-improvement; I'll use memory to remember what we discuss.";
                    if let Err(e) = channel.say(&ctx.http, msg).await {
                        eprintln!("Ready DM failed: {:?}", e);
                    } else {
                        println!("Sent ready DM to user {}", id);
                    }
                } else {
                    eprintln!("Could not create DM channel for CHUMP_READY_DM_USER_ID {}", id);
                }
            }
        }
    }

    async fn message(&self, ctx: Context, msg: Message) {
        if msg.author.bot {
            return;
        }
        let content = msg.content.trim().to_string();
        if content.is_empty() {
            return;
        }

        // Reply in DMs; in guilds only when the bot is mentioned
        let is_dm = msg.guild_id.is_none();
        let bot_id = ctx.cache.current_user().id;
        let mentioned = msg.mentions.iter().any(|u| u.id == bot_id);
        if !is_dm && !mentioned {
            return;
        }

        let channel_id = msg.channel_id;
        let http = ctx.http.clone();
        let user_name = msg.author.name.clone();

        // Kill switch: pause file or env — respond without running the agent
        if crate::chump_log::paused() {
            let _ = channel_id.say(&http, "I'm paused.").await;
            return;
        }

        // Input cap: reject too-long messages
        if let Err(msg) = crate::limits::check_message_len(&content) {
            let _ = channel_id.say(&http, msg).await;
            return;
        }

        // Rate limit: per-channel turns per minute (0 = off)
        if !rate_limit_check(channel_id.get()) {
            let _ = channel_id
                .say(&http, "Rate limited; try again in a minute.")
                .await;
            return;
        }

        let request_id = chump_log::gen_request_id();
        chump_log::log_message_with_request_id(channel_id.get(), &user_name, &content, Some(&request_id));

        // Concurrent turns cap: try to acquire a permit; if capped and no permit, reply and return
        let permit = self
            .turn_semaphore
            .as_ref()
            .and_then(|s| s.clone().try_acquire_owned().ok());
        if self.turn_semaphore.is_some() && permit.is_none() {
            let _ = channel_id
                .say(&http, "I'm at capacity; try again in a moment.")
                .await;
            return;
        }

        // Run agent in a separate task so the gateway stays responsive and can process more messages
        tokio::spawn(async move {
            let _permit = permit;
            chump_log::set_request_id(Some(request_id.clone()));
            let _typing = channel_id.start_typing(&http);
            if !ensure_ovens_warm().await {
                let _ = channel_id
                    .say(&http, "Ovens are warming up — give it a minute and try again.")
                    .await;
                return;
            }
            // Inject relevant memories (semantic if embed server up, else keyword)
            let context = crate::memory_tool::recall_for_context(Some(&content), 10).await.unwrap_or_default();
            let message = if context.is_empty() {
                content.clone()
            } else {
                format!("Relevant context from memory:\n{}\n\nUser: {}", context, content)
            };
            let reply = match build_agent(channel_id) {
                Ok(agent) => agent.run(&message).await.unwrap_or_else(|e| format!("Error: {}", e)),
                Err(e) => format!("Error: {}", e),
            };
            drop(_typing);

            let reply = strip_thinking(&reply);
            let to_send = if reply.len() > 1990 {
                format!("{}…", &reply[..1989])
            } else {
                reply.clone()
            };

            chump_log::log_reply_with_request_id(channel_id.get(), to_send.len(), Some(&to_send), Some(&request_id));
            chump_log::set_request_id(None);
            // Preview in terminal so you can see how Chump is responding
            let preview: String = to_send.chars().take(200).collect();
            println!("Chump → {} chars: {}", to_send.len(), preview.replace('\n', " "));
            if let Err(e) = channel_id.say(&http, &to_send).await {
                eprintln!("{}", chump_log::redact(&format!("Discord send error: {:?}", e)));
            }
        });
    }
}

pub async fn run(token: &str) -> Result<()> {
    let intents =
        GatewayIntents::non_privileged() | GatewayIntents::MESSAGE_CONTENT | GatewayIntents::DIRECT_MESSAGES;
    let turn_semaphore = max_concurrent_turns_semaphore();
    let handler = Handler {
        turn_semaphore,
    };
    let mut client = Client::builder(token, intents)
        .event_handler(handler)
        .await
        .map_err(|e| anyhow::anyhow!("Discord client build: {}", e))?;
    client
        .start()
        .await
        .map_err(|e| anyhow::anyhow!("Discord run: {}", e))?;
    Ok(())
}
