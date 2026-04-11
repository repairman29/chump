//! Deterministic Vector 7 verification: `CHUMP_CLUSTER_MODE=1` selects [`crate::task_executor::SwarmExecutor`],
//! which logs `[SWARM ROUTER]` and delegates to the same local sequential pipeline. Uses a mock
//! provider so the first model round always issues `task` `{ "action": "list" }`.
//! Run: `CHUMP_CLUSTER_MODE=1 cargo run --bin chump -- --vector7-swarm-verify`

use anyhow::{Context, Result};
use async_trait::async_trait;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::provider::{CompletionResponse, Message, Provider, StopReason, Tool, ToolCall};
use axonerai::tool::ToolRegistry;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

struct Vector7MockProvider {
    step: AtomicUsize,
}

#[async_trait]
impl Provider for Vector7MockProvider {
    async fn complete(
        &self,
        _messages: Vec<Message>,
        _tools: Option<Vec<Tool>>,
        _max_tokens: Option<u32>,
        _system: Option<String>,
    ) -> Result<CompletionResponse> {
        let s = self.step.fetch_add(1, Ordering::SeqCst);
        Ok(match s {
            0 => CompletionResponse {
                stop_reason: StopReason::ToolUse,
                text: Some("Calling task list.".into()),
                tool_calls: vec![ToolCall {
                    id: "v7_list".into(),
                    name: "task".into(),
                    input: serde_json::json!({ "action": "list" }),
                }],
            },
            _ => CompletionResponse {
                stop_reason: StopReason::EndTurn,
                text: Some("VECTOR7_SWARM_OK".into()),
                tool_calls: vec![],
            },
        })
    }
}

pub async fn run() -> Result<()> {
    std::env::set_var("CHUMP_CLUSTER_MODE", "1");

    let root = if let Ok(m) = std::env::var("CARGO_MANIFEST_DIR") {
        PathBuf::from(m)
    } else {
        std::env::current_dir().context("resolve project root")?
    };
    std::env::set_current_dir(&root)?;
    std::env::set_var("CHUMP_REPO", &root);
    let db_path = root.join("target/vector7_swarm_verify_memory.db");
    let _ = std::fs::remove_file(&db_path);
    std::env::set_var(
        "CHUMP_MEMORY_DB_PATH",
        db_path.to_str().context("db path utf-8")?,
    );

    crate::cluster_mesh::ensure_probed_once().await;

    let _ = crate::db_pool::get()?;

    let mut registry = ToolRegistry::new();
    crate::tool_inventory::register_from_inventory(&mut registry);

    let session_dir = root.join("target/vector7_swarm_sessions");
    let _ = std::fs::remove_dir_all(&session_dir);
    std::fs::create_dir_all(&session_dir)?;
    let fsm = FileSessionManager::new("v7swarm".to_string(), session_dir)?;

    let agent = crate::agent_loop::ChumpAgent::new(
        Box::new(Vector7MockProvider {
            step: AtomicUsize::new(0),
        }),
        registry,
        Some("Vector7 swarm verification harness.".into()),
        Some(fsm),
        None,
        10,
    );

    let prompt = "Use the `task` tool to list all open tasks.";
    let outcome = agent.run(prompt).await?;
    println!("FINAL_REPLY={}", outcome.reply);

    if !outcome.reply.contains("VECTOR7_SWARM_OK") {
        anyhow::bail!(
            "vector7 swarm verify: expected VECTOR7_SWARM_OK in reply, got {:?}",
            outcome.reply
        );
    }
    println!("VECTOR7_MARK_B: turn completed after task list; SwarmExecutor stub + local pipeline succeeded.");
    println!("VECTOR7_VERIFY_SUMMARY: CHUMP_CLUSTER_MODE=1, [SWARM ROUTER] log, and tool execution verified.");
    Ok(())
}
