//! Minimal AxonerAI agent that talks to an OpenAI-compatible endpoint (e.g. vLLM-MLX on localhost).
//! Set OPENAI_API_BASE (e.g. http://localhost:8000/v1) to use a local server; otherwise uses OpenAI.
//! Run with no args for interactive chat; pass a message for single-shot; --discord to run Discord bot (DISCORD_TOKEN required).

mod calc_tool;
mod chump_log;
mod cli_tool;
mod delegate_tool;
mod discord;
mod health_server;
mod limits;
mod tavily_tool;
mod local_openai;
mod memory_db;
mod memory_tool;
mod version;
mod wasm_runner;
mod wasm_calc_tool;

#[cfg(feature = "inprocess-embed")]
mod embed_inprocess;

use anyhow::Result;
use axonerai::agent::Agent;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::openai::OpenAIProvider;
use axonerai::tool::ToolRegistry;
use std::env;
use std::io::{self, Write};
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    let discord_mode = args.get(1).map(|s| s == "--discord").unwrap_or(false);
    let chump_mode = args.get(1).map(|s| s == "--chump").unwrap_or(false);

    if discord_mode {
        eprintln!("Chump version {}", version::chump_version());
        if let Some(port) = env::var("CHUMP_HEALTH_PORT").ok().and_then(|p| p.parse::<u16>().ok()) {
            tokio::spawn(health_server::run(port));
        }
        let token = env::var("DISCORD_TOKEN")
            .map_err(|_| anyhow::anyhow!("DISCORD_TOKEN must be set for Discord mode"))?;
        return discord::run(token.trim()).await;
    }

    if chump_mode {
        eprintln!("Chump version {}", version::chump_version());
        if let Some(port) = env::var("CHUMP_HEALTH_PORT").ok().and_then(|p| p.parse::<u16>().ok()) {
            tokio::spawn(health_server::run(port));
        }
        let agent = discord::build_chump_agent_cli()?;
        let single_message = args.get(2).map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        if let Some(msg) = single_message {
            if let Err(e) = limits::check_message_len(&msg) {
                eprintln!("{}", e);
                return Ok(());
            }
            let reply = agent.run(&msg).await?;
            println!("{}", reply);
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
                println!("Bye.");
                break;
            }
            if let Err(e) = limits::check_message_len(line) {
                eprintln!("{}", e);
                continue;
            }
            match agent.run(line).await {
                Ok(r) => println!("{}", r),
                Err(e) => eprintln!("Error: {}", e),
            }
        }
        return Ok(());
    }

    let api_key = env::var("OPENAI_API_KEY").unwrap_or_else(|_| "token-abc123".to_string());
    let model = env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-5-mini".to_string());

    let provider: Box<dyn axonerai::provider::Provider> = if let Ok(base) = env::var("OPENAI_API_BASE") {
        let fallback = env::var("CHUMP_FALLBACK_API_BASE").ok().filter(|s| !s.is_empty());
        Box::new(local_openai::LocalOpenAIProvider::with_fallback(
            base, fallback, api_key, model,
        ))
    } else {
        Box::new(OpenAIProvider::new(api_key).with_model(model))
    };

    let registry = ToolRegistry::new();
    let system_prompt = Some("You are a helpful assistant.".to_string());

    let single_message = args.get(1).map(|s| s.trim().to_string()).filter(|s| !s.is_empty());

    if let Some(msg) = single_message {
        if let Err(e) = limits::check_message_len(&msg) {
            eprintln!("{}", e);
            return Ok(());
        }
        let agent = Agent::new(provider, registry, system_prompt, None);
        let reply = agent.run(&msg).await?;
        println!("{}", reply);
        return Ok(());
    }

    // Interactive mode: keep session so conversation has context
    let session_dir = PathBuf::from("./sessions");
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
        if let Err(e) = agent.run(line).await {
            eprintln!("Error: {}", e);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::discord;
    use axonerai::agent::Agent;
    use serial_test::serial;
    use serde_json::json;
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
        let agent: Agent = discord::build_chump_agent_cli().expect("build agent");
        let reply = agent.run("Hello").await.unwrap();
        std::env::remove_var("OPENAI_API_BASE");
        assert!(
            reply.contains("Mocked reply"),
            "expected reply to contain mock content, got: {}",
            reply
        );
    }
}
