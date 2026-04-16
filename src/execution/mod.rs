//! Pluggable execution backends for shell command tools.
//!
//! V1: local (default), docker, ssh. Selection via CHUMP_EXECUTION env var.
//! Future: daytona, modal, singularity (requires cloud SDK integration).
//!
//! Each backend shells out to existing system binaries — no new Rust crate deps.
//!
//! # Usage
//!
//! ```ignore
//! let backend = execution::get_backend();
//! let req = execution::ExecutionRequest {
//!     command: "echo hello".to_string(),
//!     cwd: None,
//!     stdin: None,
//!     timeout: std::time::Duration::from_secs(10),
//!     env_vars: vec![],
//! };
//! let result = backend.execute(req).await?;
//! ```
//!
//! # Backend selection
//!
//! - `CHUMP_EXECUTION=local` (default): runs commands on the host
//! - `CHUMP_EXECUTION=docker`: runs commands inside an ephemeral container
//! - `CHUMP_EXECUTION=ssh`: runs commands on a remote host via ssh
//!
//! Allowlist/blocklist enforcement (CHUMP_CLI_ALLOWLIST / CHUMP_CLI_BLOCKLIST) is
//! handled by the caller (e.g. CliTool) BEFORE dispatching to a backend.

use anyhow::Result;
use async_trait::async_trait;
use std::time::Duration;

pub mod docker;
pub mod local;
pub mod ssh;

/// A single command execution request handed to a backend.
#[derive(Debug, Clone)]
pub struct ExecutionRequest {
    /// Full shell command (passed as a single string to `sh -c`).
    pub command: String,
    /// Working directory on the host (for local backend) or inside the container/remote.
    pub cwd: Option<String>,
    /// Optional stdin to pipe to the command.
    pub stdin: Option<String>,
    /// Hard timeout. The backend should kill the process and return an error.
    pub timeout: Duration,
    /// Additional env vars to inject (KEY, VALUE pairs).
    pub env_vars: Vec<(String, String)>,
}

impl Default for ExecutionRequest {
    fn default() -> Self {
        Self {
            command: String::new(),
            cwd: None,
            stdin: None,
            timeout: Duration::from_secs(60),
            env_vars: Vec::new(),
        }
    }
}

/// Outcome of an execution. Backends populate `backend` with their `name()`.
#[derive(Debug, Clone)]
pub struct ExecutionResult {
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub duration_ms: u64,
    pub backend: String,
}

#[async_trait]
pub trait ExecutionBackend: Send + Sync {
    /// Stable identifier (e.g. "local", "docker", "ssh"). Used for logging.
    fn name(&self) -> &'static str;

    /// Execute the request. Honours `req.timeout`. Errors here indicate the
    /// command could not be dispatched (missing binary, network failure, etc.);
    /// non-zero exit codes are returned via `ExecutionResult::exit_code`.
    async fn execute(&self, req: ExecutionRequest) -> Result<ExecutionResult>;

    /// Quick check that the backend is reachable (binary present, container
    /// daemon up, ssh host responsive). Should complete in a few seconds.
    async fn health_check(&self) -> Result<()>;
}

/// Read CHUMP_EXECUTION and return the selected backend. Defaults to local.
///
/// Unknown values fall back to local (logged at warn level) so a typo never
/// breaks the agent.
pub fn get_backend() -> Box<dyn ExecutionBackend> {
    let kind = std::env::var("CHUMP_EXECUTION")
        .unwrap_or_else(|_| "local".to_string())
        .to_lowercase();
    match kind.as_str() {
        "local" => Box::new(local::LocalBackend::new()),
        "docker" => Box::new(docker::DockerBackend::from_env()),
        "ssh" => Box::new(ssh::SshBackend::from_env()),
        other => {
            tracing::warn!(
                requested = %other,
                "unknown CHUMP_EXECUTION value, falling back to local"
            );
            Box::new(local::LocalBackend::new())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn factory_defaults_to_local() {
        // SAFETY: tests in the same process may race on env vars; we only test
        // the default branch by clearing CHUMP_EXECUTION here.
        std::env::remove_var("CHUMP_EXECUTION");
        let b = get_backend();
        assert_eq!(b.name(), "local");
    }

    #[test]
    fn factory_returns_docker_when_requested() {
        std::env::set_var("CHUMP_EXECUTION", "docker");
        let b = get_backend();
        assert_eq!(b.name(), "docker");
        std::env::remove_var("CHUMP_EXECUTION");
    }

    #[test]
    fn factory_returns_ssh_when_requested() {
        std::env::set_var("CHUMP_EXECUTION", "ssh");
        let b = get_backend();
        assert_eq!(b.name(), "ssh");
        std::env::remove_var("CHUMP_EXECUTION");
    }

    #[test]
    fn factory_falls_back_to_local_for_unknown() {
        std::env::set_var("CHUMP_EXECUTION", "no-such-backend");
        let b = get_backend();
        assert_eq!(b.name(), "local");
        std::env::remove_var("CHUMP_EXECUTION");
    }

    #[test]
    fn execution_request_default_has_60s_timeout() {
        let req = ExecutionRequest::default();
        assert_eq!(req.timeout, Duration::from_secs(60));
        assert!(req.command.is_empty());
        assert!(req.env_vars.is_empty());
    }

    #[test]
    fn execution_result_can_be_constructed() {
        let r = ExecutionResult {
            exit_code: Some(0),
            stdout: "hi".into(),
            stderr: String::new(),
            duration_ms: 12,
            backend: "local".into(),
        };
        assert_eq!(r.exit_code, Some(0));
        assert_eq!(r.backend, "local");
    }
}
