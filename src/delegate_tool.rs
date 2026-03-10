//! Orchestrator–worker: delegate a subtask to a single LLM call (no tools).
//! Task types: summarize, extract. Supports single task or batch (tasks array) run in parallel.
//! See docs/ORCHESTRATOR_WORKER.md and ROADMAP_PARALLEL_AGENTS.md.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::provider::{Message, Provider};
use axonerai::tool::Tool;
use serde_json::{json, Value};

use crate::local_openai;
use axonerai::openai::OpenAIProvider;

fn max_parallel_workers() -> usize {
    std::env::var("CHUMP_DELEGATE_MAX_PARALLEL")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| n >= 1 && n <= 32)
        .unwrap_or(4)
}

/// Build the worker provider. Uses CHUMP_WORKER_API_BASE / CHUMP_WORKER_MODEL when set,
/// otherwise OPENAI_API_BASE / OPENAI_MODEL so the worker can use a smaller/faster model (e.g. 7B on 8001).
fn worker_provider() -> Box<dyn Provider> {
    let api_key =
        std::env::var("OPENAI_API_KEY").unwrap_or_else(|_| "token-abc123".to_string());
    let base = std::env::var("CHUMP_WORKER_API_BASE")
        .ok()
        .filter(|u| !u.is_empty())
        .or_else(|| std::env::var("OPENAI_API_BASE").ok())
        .filter(|u| !u.is_empty());
    let model = std::env::var("CHUMP_WORKER_MODEL")
        .ok()
        .filter(|m| !m.is_empty())
        .or_else(|| std::env::var("OPENAI_MODEL").ok())
        .unwrap_or_else(|| "gpt-5-mini".to_string());
    if let Some(base) = base {
        let fallback = std::env::var("CHUMP_FALLBACK_API_BASE").ok().filter(|s| !s.is_empty());
        Box::new(local_openai::LocalOpenAIProvider::with_fallback(
            base, fallback, api_key, model,
        ))
    } else {
        Box::new(OpenAIProvider::new(api_key).with_model(model))
    }
}

/// Worker system prompt for summarize: at most N sentences, no preamble.
fn summarize_worker_prompt(max_sentences: u32) -> String {
    format!(
        "You are a summarizer. Summarize the following in at most {} sentence(s). Output only the summary, no preamble.",
        max_sentences
    )
}

/// Worker system prompt for extract: list what was requested (e.g. entities, facts).
fn extract_worker_prompt(instruction: &str) -> String {
    let instr = if instruction.is_empty() {
        "Extract key facts or entities as a short list (one per line)."
    } else {
        instruction
    };
    format!(
        "You are an extractor. From the following text, {}. Output only the extracted items, one per line or as a short list. No preamble.",
        instr
    )
}

async fn run_single(input: Value) -> Result<String> {
    let task_type = input
        .get("task_type")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_lowercase();
    let text = input
        .get("text")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim();
    if text.is_empty() {
        return Ok("Error: text is required.".to_string());
    }

    let (system_prompt, max_tokens) = match task_type.as_str() {
        "summarize" => {
            let max_sentences = input
                .get("max_sentences")
                .and_then(|v| v.as_f64())
                .map(|n| n as u32)
                .filter(|&n| (1..=20).contains(&n))
                .unwrap_or(3);
            (summarize_worker_prompt(max_sentences), 1024u32)
        }
        "extract" => {
            let instruction = input
                .get("instruction")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim();
            (extract_worker_prompt(instruction), 1024u32)
        }
        _ => {
            return Ok(format!(
                "Error: unknown task_type {:?}. Supported: summarize, extract.",
                task_type
            ));
        }
    };

    let provider = worker_provider();
    let messages = vec![Message {
        role: "user".to_string(),
        content: text.to_string(),
    }];
    let response = provider
        .complete(messages, None, Some(max_tokens), Some(system_prompt))
        .await?;

    Ok(response
        .text
        .unwrap_or_else(|| "".to_string())
        .trim()
        .to_string())
}

async fn run_one_task(task: &Value) -> String {
    match run_single(task.clone()).await {
        Ok(s) => s,
        Err(e) => format!("[Error: {}]", e),
    }
}

async fn run_batch(tasks: &[Value]) -> Result<String> {
    let cap = max_parallel_workers();
    let mut results = Vec::with_capacity(tasks.len());
    for chunk in tasks.chunks(cap) {
        let handles: Vec<_> = chunk
            .iter()
            .map(|t| {
                let task = t.clone();
                tokio::spawn(async move { run_one_task(&task).await })
            })
            .collect();
        for h in handles {
            let s = h.await.unwrap_or_else(|_| "[Error: join]".to_string());
            results.push(s);
        }
    }
    Ok(results
        .into_iter()
        .enumerate()
        .map(|(i, s)| format!("{}. {}", i + 1, s))
        .collect::<Vec<_>>()
        .join("\n"))
}

pub struct DelegateTool;

#[async_trait]
impl Tool for DelegateTool {
    fn name(&self) -> String {
        "delegate".to_string()
    }

    fn description(&self) -> String {
        "Delegate a subtask to a worker. Single task: task_type (summarize or extract) + text. Batch: pass 'tasks' array of { task_type, text, max_sentences?, instruction? } to run multiple in parallel. Returns the worker result(s); for batch, one result per line.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "task_type": { "type": "string", "description": "Task type: summarize or extract (single task)" },
                "text": { "type": "string", "description": "Input text for the task (single task)" },
                "max_sentences": { "type": "number", "description": "For summarize: max sentences (default 3)" },
                "instruction": { "type": "string", "description": "For extract: what to extract (e.g. 'names and dates')" },
                "tasks": {
                    "type": "array",
                    "description": "Batch: run multiple tasks in parallel. Each item: { task_type, text, max_sentences?, instruction? }",
                    "items": {
                        "type": "object",
                        "properties": {
                            "task_type": { "type": "string" },
                            "text": { "type": "string" },
                            "max_sentences": { "type": "number" },
                            "instruction": { "type": "string" }
                        },
                        "required": ["task_type", "text"]
                    }
                }
            }
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Some(tasks) = input.get("tasks").and_then(|t| t.as_array()) {
            if tasks.is_empty() {
                return Ok("Error: tasks array is empty.".to_string());
            }
            return run_batch(tasks).await;
        }

        run_single(input).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn delegate_rejects_unknown_task_type() {
        let tool = DelegateTool;
        let out = tool
            .execute(json!({ "task_type": "translate", "text": "foo" }))
            .await
            .unwrap();
        assert!(out.contains("unknown task_type"));
        assert!(out.contains("summarize"));
        assert!(out.contains("extract"));
    }

    #[tokio::test]
    async fn delegate_requires_text_for_summarize() {
        let tool = DelegateTool;
        let out = tool
            .execute(json!({ "task_type": "summarize", "text": "" }))
            .await
            .unwrap();
        assert!(out.contains("text is required"));
    }

    #[tokio::test]
    async fn delegate_batch_empty_tasks_rejected() {
        let tool = DelegateTool;
        let out = tool.execute(json!({ "tasks": [] })).await.unwrap();
        assert!(out.contains("tasks array is empty"));
    }

    #[tokio::test]
    async fn delegate_batch_returns_numbered_lines() {
        let tool = DelegateTool;
        // Two tasks that fail validation (empty text) so we don't need network.
        let out = tool
            .execute(json!({
                "tasks": [
                    { "task_type": "summarize", "text": "" },
                    { "task_type": "extract", "text": "" }
                ]
            }))
            .await
            .unwrap();
        assert!(out.starts_with("1. "));
        assert!(out.contains("text is required"));
        assert!(out.contains("\n2. "));
        assert_eq!(out.matches("text is required").count(), 2);
    }
}
