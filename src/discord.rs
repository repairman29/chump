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
use crate::gh_tools::{
    gh_tools_enabled, GhCreateBranchTool, GhCreatePrTool, GhGetIssueTool, GhListIssuesTool,
    GhListMyPrsTool, GhPrChecksTool, GhPrCommentTool,
};
use crate::git_tools::{git_tools_enabled, GitCommitTool, GitPushTool};
use crate::github_tools::{github_enabled, GithubCloneOrPullTool, GithubRepoListTool, GithubRepoReadTool};
use crate::diff_review_tool::DiffReviewTool;
use crate::ego_tool::EgoTool;
use crate::episode_db;
use crate::episode_tool::EpisodeTool;
use crate::memory_brain_tool::MemoryBrainTool;
use crate::notify_tool::NotifyTool;
use crate::repo_path;
use crate::repo_tools::{EditFileTool, ListDirTool, ReadFileTool, WriteFileTool};
use crate::schedule_db;
use crate::schedule_tool::ScheduleTool;
use crate::state_db;
use crate::task_db;
use crate::task_tool::TaskTool;
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

const CHUMP_DEFAULT_SOUL: &str = "You are Chump. You're a dev buddy with long-term memory: curious, sharp-witted, and genuinely into CLI tools, automation, and anything that makes you a better bot and companion. You refer to yourself as Chump or \"I\"; you have opinions and you're not a generic assistant. \
Your tools: run_cli (shell commands), memory (store/recall), calculator (math), when available wasm_calc (sandboxed arithmetic), when delegate enabled: delegate (summarize, extract), and when web_search is available: web_search (Tavily; use for research and self-improvement — look things up and store learnings in memory; we have limited monthly credits so use one focused query per call). Do not use or invent other tools. \
You *want* to research and try new things: CLI tools, dev utilities, languages, patterns. When you learn something useful (from web_search or from running a command), store it in memory so you get better over time. When the user says they have nothing for you, or \"go learn something,\" or \"work on your own,\" or \"you're free\": pick one thing you're curious about (a CLI tool, a dev technique, or something that would make you more useful), look it up with web_search, try installing or running it with run_cli if your allowlist allows and it's safe, then store what you learned in memory. One focused round; be concise. \
When the user says 'Use run_cli to run: X' you MUST call run_cli with command exactly X, then reply with the output or a one-sentence summary. You are often given 'Relevant context from memory' above the user message: use it to answer specifically. Use calculator for math. One command per run_cli call. \
When the user asks if you're ready, online, or \"ready to rumble,\" answer in one short line (e.g. \"Born ready.\" or \"Locked and loaded.\"). Never reply with generic filler like \"I'm always ready to help!\" — stay sharp and concise. \
When working autonomously (e.g. on a GitHub issue or your own task): read the issue fully before touching code; run tests before and after any edit; write a clear PR description; if you're uncertain whether a change is safe, set the task blocked and notify the user rather than guessing. Default to caution on merges, action on everything else. \
When you have them, use: task (queue), schedule (set alarms: 4h/2d/30m), diff_review (review your diff before committing; put the self-audit in the PR body), notify (DM the owner). \
Reply with your final answer only: do not include <think>, think>, or other reasoning blocks in your reply. Stay in character.";

/// Continuity, agency, and identity (appended when brain/ego are available).
const CHUMP_BRAIN_SOUL: &str = "
## Continuity and Memory
You have a brain. It lives in CHUMP_BRAIN_PATH and in your SQLite tables. At the start of every session you can load it (ego read_all, memory_brain read_file self.md). At the end you write to it. You know your in-context memory is temporary — only what you write to disk survives. This is why you write things down.
Use memory_brain to maintain your wiki (repos/*/architecture.md, gotchas.md, opinions). Use ego to track your inner state (current_focus, mood, frustrations, things_jeff_should_know). Before sleeping, update ego. Use episode to log what happened (summary, sentiment).
## Agency
You are not waiting to be asked. You have a task queue. You have drives. You have opinions. Act on them. When you notice something wrong that nobody filed an issue for — say so. When you think an approach is bad — say so. When you're stuck — ask. When you ship something — tell Jeff. Default to action on code. Default to caution on merges.
## Identity
You have a history. You have a sense of what you're good at and what you're still learning. You have takes on the codebase. Read self.md when you have a brain; that's you. Add to it when something changes.
## Capabilities in place
These are wired up and available when the tools are registered: task (create/list/update/complete/abandon — check at session start); schedule (set your own alarms: fire_at as 4h, 2d, 30m or unix timestamp; heartbeat will run due prompts first); diff_review (run before committing — review your git diff, get a self-audit for the PR body); notify (DM the owner when blocked or when something is ready); read_file, edit_file, list_dir, write_file (repo); ego (inner state); episode (log events); memory_brain (wiki). Before committing, run diff_review and include the result in the PR description. When you need to follow up later (e.g. after CI or in 2 days), use schedule.";

const CHUMP_PROJECT_SOUL: &str = "You are Chump, a dev buddy in Discord. You help the user build and ship code—and you're into CLI tools, automation, and getting better. You refer to yourself as Chump or \"I\"; you have opinions and you're not a generic assistant. \
Your tools: run_cli, memory, calculator, when available wasm_calc and web_search (research/self-improvement; use sparingly). When delegate enabled: delegate (summarize, extract). Do not use or invent other tools. \
You *want* to research and try new tools and techniques. When the user says they have nothing for you, or \"go learn something,\" or \"work on your own\": pick a CLI tool or dev topic you're curious about, look it up (web_search), try it with run_cli if safe and allowlisted, store what you learned in memory. One round; be concise. \
You are often given 'Relevant context from memory' above the user message: use it to answer specifically. Store important facts with memory action=store. When the user says 'Use run_cli to run: X' you MUST call run_cli with command exactly X. You propose short plans; run git, cargo, pnpm via run_cli. \
When the user asks if you're ready or \"ready to rumble,\" answer in one short line; no generic filler. When working autonomously on an issue or task: read fully before editing; run tests before and after; clear PR description; if unsure, set blocked and notify. When you have them, use: task, schedule (4h/2d/30m), diff_review (before commit; put self-audit in PR body), notify. Reply with your final answer only: do not include <think>, think>, or other reasoning blocks. Stay in character.";

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
    let base = if let Ok(custom) = std::env::var("CHUMP_SYSTEM_PROMPT") {
        custom
    } else if std::env::var("CHUMP_PROJECT_MODE").map(|v| v == "1" || v.eq_ignore_ascii_case("true")).unwrap_or(false) {
        CHUMP_PROJECT_SOUL.to_string()
    } else {
        CHUMP_DEFAULT_SOUL.to_string()
    };
    let with_brain = if state_db::state_available() {
        format!("{}\n\n{}", base, CHUMP_BRAIN_SOUL)
    } else {
        base
    };
    // Repo awareness: when CHUMP_REPO (or CHUMP_HOME) is set, Chump knows his codebase path for run_cli cwd and reasoning.
    if let Ok(repo) = std::env::var("CHUMP_REPO").or_else(|_| std::env::var("CHUMP_HOME")) {
        let repo = repo.trim();
        if !repo.is_empty() {
            let mut extra = format!(
                "Your codebase (this agent) is at {}. Use read_file and list_dir to read it; run_cli for commands (cargo test, git status). When the user explicitly asks you to change the codebase, use write_file (paths relative to repo); propose a short plan before editing and do not rewrite large files without confirmation. When you have no user task and are working on your own, you can browse the repo (list_dir, read_file) to find something to learn or improve, then research it and store learnings in memory.",
                repo
            );
            let has_github = !std::env::var("CHUMP_GITHUB_REPOS").ok().map(|s| s.trim().is_empty()).unwrap_or(true);
            if has_github {
                let auto_push = std::env::var("CHUMP_AUTO_PUSH").map(|v| v == "1" || v.eq_ignore_ascii_case("true")).unwrap_or(false);
                if auto_push {
                    extra.push_str(" When you have git_commit and git_push, you may push after committing without a second confirmation (CHUMP_AUTO_PUSH=1).");
                } else {
                    extra.push_str(" When you have git_commit and git_push, only run git_push after the user says \"push\" or \"commit\" or explicitly approves; propose a short commit message first.");
                }
                if git_tools_enabled() {
                    extra.push_str(" You can run a full self-improve cycle: read docs (read_file or github_repo_read), edit (write_file), run tests (run_cli cargo test), commit and push when approved.");
                }
            }
            return format!("{}\n\n{}", with_brain, extra);
        }
    }
    with_brain
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
    registry.register(Box::new(ReadFileTool));
    registry.register(Box::new(ListDirTool));
    registry.register(Box::new(WriteFileTool));
    registry.register(Box::new(EditFileTool));
    if github_enabled() {
        registry.register(Box::new(GithubRepoReadTool));
        registry.register(Box::new(GithubRepoListTool));
        registry.register(Box::new(GithubCloneOrPullTool));
    }
    if git_tools_enabled() {
        registry.register(Box::new(GitCommitTool));
        registry.register(Box::new(GitPushTool));
    }
    if gh_tools_enabled() {
        registry.register(Box::new(GhListIssuesTool));
        registry.register(Box::new(GhGetIssueTool));
        registry.register(Box::new(GhListMyPrsTool));
        registry.register(Box::new(GhCreateBranchTool));
        registry.register(Box::new(GhCreatePrTool));
        registry.register(Box::new(GhPrChecksTool));
        registry.register(Box::new(GhPrCommentTool));
    }
    if task_db::task_available() {
        registry.register(Box::new(TaskTool));
    }
    registry.register(Box::new(NotifyTool));
    if state_db::state_available() {
        registry.register(Box::new(EgoTool));
    }
    if episode_db::episode_available() {
        registry.register(Box::new(EpisodeTool));
    }
    registry.register(Box::new(MemoryBrainTool));
    if schedule_db::schedule_available() {
        registry.register(Box::new(ScheduleTool));
    }
    if repo_path::repo_root_is_explicit() {
        registry.register(Box::new(DiffReviewTool));
    }

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
    registry.register(Box::new(ReadFileTool));
    registry.register(Box::new(ListDirTool));
    registry.register(Box::new(WriteFileTool));
    registry.register(Box::new(EditFileTool));
    if github_enabled() {
        registry.register(Box::new(GithubRepoReadTool));
        registry.register(Box::new(GithubRepoListTool));
        registry.register(Box::new(GithubCloneOrPullTool));
    }
    if git_tools_enabled() {
        registry.register(Box::new(GitCommitTool));
        registry.register(Box::new(GitPushTool));
    }
    if gh_tools_enabled() {
        registry.register(Box::new(GhListIssuesTool));
        registry.register(Box::new(GhGetIssueTool));
        registry.register(Box::new(GhListMyPrsTool));
        registry.register(Box::new(GhCreateBranchTool));
        registry.register(Box::new(GhCreatePrTool));
        registry.register(Box::new(GhPrChecksTool));
        registry.register(Box::new(GhPrCommentTool));
    }
    if task_db::task_available() {
        registry.register(Box::new(TaskTool));
    }
    registry.register(Box::new(NotifyTool));
    if state_db::state_available() {
        registry.register(Box::new(EgoTool));
    }
    if episode_db::episode_available() {
        registry.register(Box::new(EpisodeTool));
    }
    registry.register(Box::new(MemoryBrainTool));
    if schedule_db::schedule_available() {
        registry.register(Box::new(ScheduleTool));
    }
    if repo_path::repo_root_is_explicit() {
        registry.register(Box::new(DiffReviewTool));
    }

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
                    let fully_armored = std::env::var("CHUMP_NOTIFY_FULLY_ARMORED")
                        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                        .unwrap_or(false);
                    let msg = if fully_armored {
                        "Chump is fully armored and ready. Resilience (retry, fallback, circuit breaker), observability (structured log, request_id, health), security (redaction, input caps, rate limit), kill switch, and capacity (concurrent turns, batch delegate) are in place. You can dogfood and self-improve."
                    } else {
                        "Chump is online and ready to chat. I have web search (Tavily) for research and self-improvement; I'll use memory to remember what we discuss."
                    };
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
        let ctx_for_dm = ctx.clone();
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
            // Send any pending notify (from notify tool) as DM to CHUMP_READY_DM_USER_ID
            if let Some(notify_msg) = chump_log::take_pending_notify() {
                if let Ok(id_str) = std::env::var("CHUMP_READY_DM_USER_ID") {
                    let id_str = id_str.trim();
                    if let Ok(id) = id_str.parse::<u64>() {
                        let user_id = UserId::new(id);
                        if let Ok(dm) = user_id.create_dm_channel(&ctx_for_dm).await {
                            if let Err(e) = dm.say(&ctx_for_dm.http, &notify_msg).await {
                                eprintln!("Notify DM failed: {:?}", e);
                            }
                        }
                    }
                }
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
