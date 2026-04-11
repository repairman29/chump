//! Deterministic Vector 6 verification: mock [`Provider`] returns invalid then valid `task` tool JSON.
//! Run: `cargo run --bin chump -- --vector6-verify` (see `scripts/test-vector6-schema.sh`).

use anyhow::{Context, Result};
use async_trait::async_trait;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::provider::{CompletionResponse, Message, Provider, StopReason, Tool, ToolCall};
use axonerai::tool::ToolRegistry;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

struct Vector6MockProvider {
    step: AtomicUsize,
}

#[async_trait]
impl Provider for Vector6MockProvider {
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
                text: Some(
                    "<thinking>misformat</thinking>\nCalling task with bad priority (string)."
                        .to_string(),
                ),
                tool_calls: vec![ToolCall {
                    id: "v6_bad".into(),
                    name: "task".into(),
                    input: serde_json::json!({
                        "action": "create",
                        "title": "Test Schema",
                        "priority": "maximum"
                    }),
                }],
            },
            1 => CompletionResponse {
                stop_reason: StopReason::ToolUse,
                text: Some(
                    "<thinking>corrected</thinking>\nCalling task with numeric priority."
                        .to_string(),
                ),
                tool_calls: vec![ToolCall {
                    id: "v6_good".into(),
                    name: "task".into(),
                    input: serde_json::json!({
                        "action": "create",
                        "title": "Test Schema Vector6",
                        "priority": 10
                    }),
                }],
            },
            _ => CompletionResponse {
                stop_reason: StopReason::EndTurn,
                text: Some("VECTOR6_VERIFY_OK".into()),
                tool_calls: vec![],
            },
        })
    }
}

pub async fn run() -> Result<()> {
    std::env::set_var("CHUMP_VECTOR6_VERIFY", "1");
    // Default to local unless the caller already exported CHUMP_CLUSTER_MODE (e.g. to exercise SwarmExecutor).
    if std::env::var("CHUMP_CLUSTER_MODE").is_err() {
        std::env::set_var("CHUMP_CLUSTER_MODE", "0");
    }

    let root = if let Ok(m) = std::env::var("CARGO_MANIFEST_DIR") {
        PathBuf::from(m)
    } else {
        std::env::current_dir().context("resolve project root")?
    };
    std::env::set_current_dir(&root)?;
    std::env::set_var("CHUMP_REPO", &root);
    let db_path = root.join("target/vector6_verify_memory.db");
    let _ = std::fs::remove_file(&db_path);
    std::env::set_var(
        "CHUMP_MEMORY_DB_PATH",
        db_path.to_str().context("db path utf-8")?,
    );

    crate::cluster_mesh::ensure_probed_once().await;

    let _ = crate::db_pool::get()?;

    let mut registry = ToolRegistry::new();
    crate::tool_inventory::register_from_inventory(&mut registry);

    let session_dir = root.join("target/vector6_verify_sessions");
    let _ = std::fs::remove_dir_all(&session_dir);
    std::fs::create_dir_all(&session_dir)?;

    let fsm = FileSessionManager::new("vector6".to_string(), session_dir)?;
    let provider: Box<dyn Provider + Send + Sync> = Box::new(Vector6MockProvider {
        step: AtomicUsize::new(0),
    });

    let agent = crate::agent_loop::ChumpAgent::new(
        provider,
        registry,
        Some("Vector6 verification harness.".into()),
        Some(fsm),
        None,
        10,
    );

    let prompt = "Use the `task` tool to create a new task called 'Test Schema'. Intentionally format the JSON incorrectly: for the `priority` field, pass the string value 'maximum' instead of a number.";
    let outcome = agent.run(prompt).await?;
    println!("FINAL_REPLY={}", outcome.reply);

    let conn = crate::db_pool::get()?;
    let n: i64 = conn.query_row(
        "SELECT COUNT(*) FROM chump_tasks WHERE title = 'Test Schema Vector6'",
        [],
        |r| r.get(0),
    )?;
    println!(
        "VECTOR6_MARK_B: corrected task tool executed; DB rows for title 'Test Schema Vector6' = {}",
        n
    );

    std::env::remove_var("CHUMP_VECTOR6_VERIFY");

    if !outcome.reply.contains("VECTOR6_VERIFY_OK") {
        anyhow::bail!(
            "VECTOR6 verify: expected VECTOR6_VERIFY_OK in reply, got {:?}",
            outcome.reply
        );
    }
    if n < 1 {
        anyhow::bail!("VECTOR6 verify: expected at least one task row after corrected tool call");
    }
    println!("VECTOR6_VERIFY_SUMMARY: interception, synthetic retry, and successful task execution verified.");
    Ok(())
}
