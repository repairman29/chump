//! Local execution backend — runs commands on the host via `sh -c` (or `cmd /c` on Windows).
//!
//! This is the default backend and mirrors what `cli_tool::CliTool::run` does today.
//! No allowlist/blocklist is applied here; the caller is responsible for that.

use super::{ExecutionBackend, ExecutionRequest, ExecutionResult};
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use std::process::Stdio;
use std::time::Instant;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

pub struct LocalBackend;

impl LocalBackend {
    pub fn new() -> Self {
        Self
    }
}

impl Default for LocalBackend {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl ExecutionBackend for LocalBackend {
    fn name(&self) -> &'static str {
        "local"
    }

    async fn execute(&self, req: ExecutionRequest) -> Result<ExecutionResult> {
        let started = Instant::now();
        let (program, shell_arg) = if cfg!(target_os = "windows") {
            ("cmd", "/c")
        } else {
            ("sh", "-c")
        };

        let mut cmd = Command::new(program);
        cmd.arg(shell_arg).arg(&req.command);
        if let Some(cwd) = &req.cwd {
            cmd.current_dir(cwd);
        }
        for (k, v) in &req.env_vars {
            cmd.env(k, v);
        }
        if req.stdin.is_some() {
            cmd.stdin(Stdio::piped());
        }
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

        let mut child = cmd
            .spawn()
            .map_err(|e| anyhow!("failed to spawn local shell: {}", e))?;

        if let (Some(stdin_data), Some(mut stdin)) = (req.stdin.as_ref(), child.stdin.take()) {
            let data = stdin_data.clone();
            tokio::spawn(async move {
                let _ = stdin.write_all(data.as_bytes()).await;
                let _ = stdin.shutdown().await;
            });
        }

        let output = match tokio::time::timeout(req.timeout, child.wait_with_output()).await {
            Ok(res) => res.map_err(|e| anyhow!("local backend wait failed: {}", e))?,
            Err(_) => {
                return Err(anyhow!(
                    "command timed out after {}s (local backend)",
                    req.timeout.as_secs()
                ));
            }
        };

        Ok(ExecutionResult {
            exit_code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
            duration_ms: started.elapsed().as_millis() as u64,
            backend: "local".to_string(),
        })
    }

    async fn health_check(&self) -> Result<()> {
        // Local always available — confirm by spawning a tiny shell.
        let req = ExecutionRequest {
            command: "echo health".to_string(),
            timeout: std::time::Duration::from_secs(5),
            ..Default::default()
        };
        let r = self.execute(req).await?;
        if r.exit_code != Some(0) {
            return Err(anyhow!(
                "local health check returned non-zero exit: {:?}",
                r.exit_code
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn local_health_check_passes() {
        let backend = LocalBackend::new();
        backend.health_check().await.expect("local should be healthy");
    }

    #[tokio::test]
    async fn local_executes_simple_command() {
        let backend = LocalBackend::new();
        let req = ExecutionRequest {
            command: "echo hello-local".to_string(),
            timeout: Duration::from_secs(5),
            ..Default::default()
        };
        let r = backend.execute(req).await.unwrap();
        assert_eq!(r.exit_code, Some(0));
        assert!(r.stdout.contains("hello-local"));
        assert_eq!(r.backend, "local");
    }

    #[tokio::test]
    async fn local_respects_timeout() {
        let backend = LocalBackend::new();
        let req = ExecutionRequest {
            command: "sleep 5".to_string(),
            timeout: Duration::from_millis(300),
            ..Default::default()
        };
        let result = backend.execute(req).await;
        assert!(result.is_err(), "expected timeout error");
        let err = result.unwrap_err().to_string();
        assert!(err.contains("timed out"), "got: {err}");
    }

    #[tokio::test]
    async fn local_pipes_stdin() {
        let backend = LocalBackend::new();
        let req = ExecutionRequest {
            command: "cat".to_string(),
            stdin: Some("piped-input".to_string()),
            timeout: Duration::from_secs(5),
            ..Default::default()
        };
        let r = backend.execute(req).await.unwrap();
        assert_eq!(r.exit_code, Some(0));
        assert!(r.stdout.contains("piped-input"));
    }

    #[tokio::test]
    async fn local_propagates_env_vars() {
        let backend = LocalBackend::new();
        let req = ExecutionRequest {
            command: "echo $CHUMP_TEST_VAR".to_string(),
            env_vars: vec![("CHUMP_TEST_VAR".to_string(), "from-test".to_string())],
            timeout: Duration::from_secs(5),
            ..Default::default()
        };
        let r = backend.execute(req).await.unwrap();
        assert!(r.stdout.contains("from-test"));
    }
}
