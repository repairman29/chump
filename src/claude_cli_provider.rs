//! RESILIENT-1034: `chump gap decompose` LLM backend selector.
//!
//! Root cause: the decompose provider cascade pins `OPENAI_API_BASE` to
//! `http://127.0.0.1:11434` (local Ollama, qwen2.5:7b) by default. That
//! daemon runs on `CJ`, not `cuphead` — so any fleet worker on cuphead that
//! calls `chump gap decompose` gets `error sending request for url
//! (http://127.0.0.1:11434/v1/chat/completions)` and l-sized gaps sit
//! unpickable forever (verified against RESILIENT-1029).
//!
//! Fix: an opt-in `FLEET_BACKEND=claude` (or `sonnet`) escape hatch that
//! routes inference through the `claude` CLI already installed on every
//! fleet worker — the "working floor" every machine actually has, instead of
//! a host-pinned local daemon.
use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use axonerai::provider::{CompletionResponse, Message, Provider, StopReason, Tool};
use std::process::Stdio;

/// True when `FLEET_BACKEND` requests routing inference through the local
/// `claude` CLI rather than an OpenAI-compatible HTTP endpoint (Ollama /
/// vLLM / OpenRouter / etc). Recognizes `claude`, `sonnet`, and `claude-cli`
/// (case-insensitive) so either the model family name or the tool name works
/// as the trigger value.
pub fn claude_cli_backend_requested() -> bool {
    std::env::var("FLEET_BACKEND")
        .map(|v| {
            matches!(
                v.trim().to_lowercase().as_str(),
                "claude" | "sonnet" | "claude-cli"
            )
        })
        .unwrap_or(false)
}

/// Resolve the `--model` argument passed to the `claude` CLI. Defaults to
/// `sonnet` (fast + cheap enough for decompose-sized prompts); `FLEET_MODEL`
/// overrides it so callers can pin `opus`/`haiku` without touching
/// `FLEET_BACKEND`.
fn resolved_cli_model() -> String {
    std::env::var("FLEET_MODEL")
        .ok()
        .filter(|m| !m.trim().is_empty())
        .unwrap_or_else(|| "sonnet".to_string())
}

/// Provider that shells out to the `claude` CLI in one-shot print mode
/// (`claude -p`) instead of calling an OpenAI-compatible HTTP endpoint. Used
/// as the decompose backend when `FLEET_BACKEND=claude` (or `sonnet`) is set
/// — see [`claude_cli_backend_requested`]. Every fleet worker already has an
/// authenticated `claude` CLI on `PATH` (it's how the worker itself runs),
/// so this backend has no host-pinned reachability dependency the way a
/// fixed `127.0.0.1:11434` base URL does.
pub struct ClaudeCliProvider {
    model: String,
}

impl ClaudeCliProvider {
    pub fn new() -> Self {
        Self {
            model: resolved_cli_model(),
        }
    }
}

impl Default for ClaudeCliProvider {
    fn default() -> Self {
        Self::new()
    }
}

/// Flatten a system prompt + message history into a single text prompt
/// suitable for `claude -p`'s stdin. The CLI's print mode is a single-turn
/// completion, not a chat API, so history is rendered inline with role
/// labels rather than sent as structured turns.
fn render_prompt(messages: &[Message], system_prompt: Option<&str>) -> String {
    let mut out = String::new();
    if let Some(sys) = system_prompt {
        if !sys.trim().is_empty() {
            out.push_str(sys.trim());
            out.push_str("\n\n");
        }
    }
    for m in messages {
        out.push_str(&format!("[{}]\n{}\n\n", m.role, m.content));
    }
    out
}

#[async_trait]
impl Provider for ClaudeCliProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        _tools: Option<Vec<Tool>>,
        _max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let prompt = render_prompt(&messages, system_prompt.as_deref());
        if prompt.trim().is_empty() {
            bail!("ClaudeCliProvider: empty prompt (no messages/system_prompt)");
        }
        let model = self.model.clone();

        // `claude -p` blocks on I/O, so run it on a blocking thread rather
        // than tying up the async executor.
        let output = tokio::task::spawn_blocking(move || -> Result<std::process::Output> {
            use std::io::Write;
            let mut child = std::process::Command::new("claude")
                .arg("-p")
                .args(["--model", &model])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .context("ClaudeCliProvider: failed to spawn `claude` CLI — is it on PATH?")?;
            child
                .stdin
                .take()
                .context("ClaudeCliProvider: no stdin handle")?
                .write_all(prompt.as_bytes())
                .context("ClaudeCliProvider: failed to write prompt to `claude` stdin")?;
            child
                .wait_with_output()
                .context("ClaudeCliProvider: failed waiting for `claude` CLI")
        })
        .await
        .context("ClaudeCliProvider: blocking task panicked")??;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            bail!("ClaudeCliProvider: `claude -p` exited non-zero: {stderr}");
        }
        let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
        Ok(CompletionResponse {
            text: Some(text),
            tool_calls: Vec::new(),
            stop_reason: StopReason::EndTurn,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_backend<T>(value: Option<&str>, f: impl FnOnce() -> T) -> T {
        let _guard = ENV_LOCK.lock().unwrap();
        match value {
            Some(v) => std::env::set_var("FLEET_BACKEND", v),
            None => std::env::remove_var("FLEET_BACKEND"),
        }
        let result = f();
        std::env::remove_var("FLEET_BACKEND");
        result
    }

    #[test]
    fn unset_does_not_request_claude_cli_backend() {
        with_backend(None, || {
            assert!(!claude_cli_backend_requested());
        });
    }

    #[test]
    fn ollama_or_other_values_do_not_request_claude_cli_backend() {
        with_backend(Some("ollama"), || {
            assert!(!claude_cli_backend_requested());
        });
    }

    #[test]
    fn claude_requests_claude_cli_backend() {
        with_backend(Some("claude"), || {
            assert!(claude_cli_backend_requested());
        });
    }

    #[test]
    fn sonnet_requests_claude_cli_backend_case_insensitive() {
        with_backend(Some("SONNET"), || {
            assert!(claude_cli_backend_requested());
        });
    }

    #[test]
    fn claude_cli_alias_requests_claude_cli_backend() {
        with_backend(Some("claude-cli"), || {
            assert!(claude_cli_backend_requested());
        });
    }

    #[test]
    fn render_prompt_includes_system_and_messages() {
        let msgs = vec![Message {
            role: "user".to_string(),
            content: "hello".to_string(),
        }];
        let rendered = render_prompt(&msgs, Some("be terse"));
        assert!(rendered.contains("be terse"));
        assert!(rendered.contains("[user]"));
        assert!(rendered.contains("hello"));
    }

    #[test]
    fn default_cli_model_is_sonnet() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::remove_var("FLEET_MODEL");
        assert_eq!(resolved_cli_model(), "sonnet");
    }

    #[test]
    fn fleet_model_overrides_default_cli_model() {
        let _guard = ENV_LOCK.lock().unwrap();
        std::env::set_var("FLEET_MODEL", "opus");
        assert_eq!(resolved_cli_model(), "opus");
        std::env::remove_var("FLEET_MODEL");
    }
}
