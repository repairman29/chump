//! Middleware around every tool call: timeout, and a single place to add rate limit,
//! circuit breaker, and tracing later (see docs/RUST_INFRASTRUCTURE.md).
//!
//! Today: one wrapper that applies a configurable timeout to `execute()` and
//! records timeout/errors to tool_health_db when available. Full Tower stack
//! (ServiceBuilder + layers) can be added in a follow-up.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;
use tokio::time::timeout;

/// Default timeout for a single tool execution (seconds).
pub const DEFAULT_TOOL_TIMEOUT_SECS: u64 = 30;

/// Wraps a `Tool` so that every `execute()` call is bounded by a timeout.
/// Delegates `name()`, `description()`, and `input_schema()` to the inner tool.
pub struct ToolTimeoutWrapper {
    inner: Arc<dyn Tool + Send + Sync>,
    timeout_duration: Duration,
}

impl ToolTimeoutWrapper {
    /// Wrap `inner` with the default timeout (30s).
    pub fn new(inner: Box<dyn Tool + Send + Sync>) -> Self {
        Self {
            inner: Arc::from(inner),
            timeout_duration: Duration::from_secs(DEFAULT_TOOL_TIMEOUT_SECS),
        }
    }

    /// Wrap with a custom timeout.
    #[allow(dead_code)]
    pub fn with_timeout(inner: Box<dyn Tool + Send + Sync>, secs: u64) -> Self {
        Self {
            inner: Arc::from(inner),
            timeout_duration: Duration::from_secs(secs),
        }
    }
}

#[async_trait]
impl Tool for ToolTimeoutWrapper {
    fn name(&self) -> String {
        self.inner.name()
    }

    fn description(&self) -> String {
        self.inner.description()
    }

    fn input_schema(&self) -> Value {
        self.inner.input_schema()
    }

    #[tracing::instrument(skip(self, input), fields(tool = %self.inner.name()))]
    async fn execute(&self, input: Value) -> Result<String> {
        let inner = self.inner.clone();
        let fut = async move { inner.execute(input).await };
        match timeout(self.timeout_duration, fut).await {
            Ok(Ok(out)) => Ok(out),
            Ok(Err(e)) => {
                let err_msg = e.to_string();
                let _ = crate::tool_health_db::record_failure(
                    self.inner.name().as_str(),
                    "degraded",
                    Some(err_msg.as_str()),
                );
                Err(e)
            }
            Err(_elapsed) => {
                let msg = format!("tool timed out after {}s", self.timeout_duration.as_secs());
                let _ = crate::tool_health_db::record_failure(
                    self.inner.name().as_str(),
                    "degraded",
                    Some(msg.as_str()),
                );
                Err(anyhow!("{}", msg))
            }
        }
    }
}

/// Wrap a tool with the default timeout and optional tool-health recording.
/// Use when building the registry so every tool gets the same guarantees.
pub fn wrap_tool(inner: Box<dyn Tool + Send + Sync>) -> Box<dyn Tool + Send + Sync> {
    Box::new(ToolTimeoutWrapper::new(inner))
}
