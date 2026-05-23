//! Subagent-spawn transports.
//!
//! The crate stays agent-runner agnostic: [`crate::Transport`] is a trait,
//! and two concrete impls ship here:
//!
//! * [`AgentToolTransport`] — production path. Shells out to a runner binary
//!   on PATH (default: `chump-agent-cli`) so Claude Code, opencode, codex, and
//!   future harnesses can all plug in by providing a command that takes
//!   `--model <tier>` + prompt-on-stdin and emits subagent output on stdout.
//!   No direct dependency on the Claude Code Agent tool — the harness contract
//!   (INFRA-1044 docs/process/HARNESS_CONTRACT.md) keeps this layer portable.
//!
//! * [`StubTransport`] — test path. Returns a fixed string the test supplies,
//!   so contract logic can be exercised deterministically.

use async_trait::async_trait;
use std::process::Stdio;
use tokio::io::AsyncWriteExt;

use crate::{ModelTier, Transport};

/// Production transport — shells out to a runner binary on PATH.
///
/// Resolution order for the runner command:
///
/// 1. `CHUMP_HANDOFF_RUNNER_CMD` env var (e.g. `claude-code --headless`)
/// 2. Compile-time default `"chump-agent-cli"` (must be on PATH)
///
/// Runner contract: reads prompt from stdin, accepts `--model <haiku|sonnet|opus>`,
/// emits subagent output on stdout, exits 0 on success.
#[derive(Default)]
pub struct AgentToolTransport {
    /// Override the runner command (otherwise read from env or fall back).
    pub runner_cmd_override: Option<String>,
}

impl AgentToolTransport {
    /// Construct a transport that reads `CHUMP_HANDOFF_RUNNER_CMD` (or falls
    /// back to `"chump-agent-cli"`).
    pub fn new() -> Self {
        Self::default()
    }

    fn resolve_runner_cmd(&self) -> String {
        if let Some(cmd) = &self.runner_cmd_override {
            return cmd.clone();
        }
        std::env::var("CHUMP_HANDOFF_RUNNER_CMD").unwrap_or_else(|_| "chump-agent-cli".to_string())
    }
}

#[async_trait]
impl Transport for AgentToolTransport {
    async fn dispatch(
        &self,
        agent_id: &str,
        contract_name: &str,
        prompt: String,
        tier: ModelTier,
    ) -> anyhow::Result<String> {
        let cmd_str = self.resolve_runner_cmd();
        // The runner command may be "claude-code --headless"; tokio's Command
        // needs a program + args, so we split on whitespace. This is the same
        // pattern chump-team uses for CHUMP_TEAM_RUNNER.
        let mut parts = cmd_str.split_whitespace();
        let prog = parts
            .next()
            .ok_or_else(|| anyhow::anyhow!("CHUMP_HANDOFF_RUNNER_CMD is empty"))?;
        let extra_args: Vec<&str> = parts.collect();

        let model_arg = match tier {
            ModelTier::Haiku => "haiku",
            ModelTier::Sonnet => "sonnet",
            ModelTier::Opus => "opus",
        };

        tracing::info!(
            agent_id,
            contract_name,
            model = model_arg,
            runner = prog,
            "handoff dispatch"
        );

        let mut child = tokio::process::Command::new(prog)
            .args(&extra_args)
            .arg("--model")
            .arg(model_arg)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(prompt.as_bytes()).await?;
            stdin.shutdown().await?;
        }

        let output = child.wait_with_output().await?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            anyhow::bail!("runner exited non-zero ({}): {stderr}", output.status);
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }
}

/// Test transport. Constructed with a fixed `reply` string; every dispatch
/// call returns it verbatim. Used by integration tests + downstream-crate
/// tests so contract logic exercises end-to-end without a live LLM.
pub struct StubTransport {
    /// Fixed reply emitted on every dispatch.
    pub reply: String,
    /// Optional error to return instead of `reply` (for testing the dispatch-error path).
    pub force_error: Option<String>,
}

impl StubTransport {
    /// Build a stub that always replies with `reply`.
    pub fn new(reply: impl Into<String>) -> Self {
        Self {
            reply: reply.into(),
            force_error: None,
        }
    }

    /// Build a stub that forces a transport-level error.
    pub fn err(msg: impl Into<String>) -> Self {
        Self {
            reply: String::new(),
            force_error: Some(msg.into()),
        }
    }
}

#[async_trait]
impl Transport for StubTransport {
    async fn dispatch(
        &self,
        _agent_id: &str,
        _contract_name: &str,
        _prompt: String,
        _tier: ModelTier,
    ) -> anyhow::Result<String> {
        if let Some(err) = &self.force_error {
            anyhow::bail!("{err}");
        }
        Ok(self.reply.clone())
    }
}
