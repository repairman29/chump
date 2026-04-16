//! Docker execution backend — runs commands in an ephemeral container.
//!
//! Configured via CHUMP_DOCKER_IMAGE (default: "ubuntu:22.04") and
//! CHUMP_DOCKER_MOUNT (default: none). Each execution creates a fresh container,
//! runs the command, captures output, and removes the container.
//!
//! Shell-out only — no Docker SDK dependency. Requires `docker` on PATH.

use super::{ExecutionBackend, ExecutionRequest, ExecutionResult};
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use std::process::Stdio;
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

const DEFAULT_IMAGE: &str = "ubuntu:22.04";
const DEFAULT_NETWORK: &str = "none";

pub struct DockerBackend {
    image: String,
    mount: Option<String>,
    network: String,
}

impl DockerBackend {
    pub fn new(image: impl Into<String>, mount: Option<String>, network: impl Into<String>) -> Self {
        Self {
            image: image.into(),
            mount,
            network: network.into(),
        }
    }

    pub fn from_env() -> Self {
        let image = std::env::var("CHUMP_DOCKER_IMAGE").unwrap_or_else(|_| DEFAULT_IMAGE.to_string());
        let mount = std::env::var("CHUMP_DOCKER_MOUNT").ok().filter(|s| !s.is_empty());
        let network =
            std::env::var("CHUMP_DOCKER_NETWORK").unwrap_or_else(|_| DEFAULT_NETWORK.to_string());
        Self::new(image, mount, network)
    }

    fn build_args(&self, req: &ExecutionRequest) -> Vec<String> {
        let mut args: Vec<String> = vec!["run".into(), "--rm".into(), "-i".into()];
        args.push(format!("--network={}", self.network));
        if let Some(m) = &self.mount {
            args.push("-v".into());
            args.push(m.clone());
        }
        if let Some(cwd) = &req.cwd {
            args.push("-w".into());
            args.push(cwd.clone());
        }
        for (k, v) in &req.env_vars {
            args.push("-e".into());
            args.push(format!("{}={}", k, v));
        }
        args.push(self.image.clone());
        args.push("sh".into());
        args.push("-c".into());
        args.push(req.command.clone());
        args
    }
}

#[async_trait]
impl ExecutionBackend for DockerBackend {
    fn name(&self) -> &'static str {
        "docker"
    }

    async fn execute(&self, req: ExecutionRequest) -> Result<ExecutionResult> {
        let started = Instant::now();
        let args = self.build_args(&req);
        let mut cmd = Command::new("docker");
        cmd.args(&args);
        if req.stdin.is_some() {
            cmd.stdin(Stdio::piped());
        }
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

        let mut child = cmd.spawn().map_err(|e| {
            anyhow!(
                "failed to spawn docker (is the docker binary installed and on PATH?): {}",
                e
            )
        })?;

        if let (Some(stdin_data), Some(mut stdin)) = (req.stdin.as_ref(), child.stdin.take()) {
            let data = stdin_data.clone();
            tokio::spawn(async move {
                let _ = stdin.write_all(data.as_bytes()).await;
                let _ = stdin.shutdown().await;
            });
        }

        let output = match tokio::time::timeout(req.timeout, child.wait_with_output()).await {
            Ok(res) => res.map_err(|e| anyhow!("docker backend wait failed: {}", e))?,
            Err(_) => {
                return Err(anyhow!(
                    "command timed out after {}s (docker backend)",
                    req.timeout.as_secs()
                ));
            }
        };

        Ok(ExecutionResult {
            exit_code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
            duration_ms: started.elapsed().as_millis() as u64,
            backend: "docker".to_string(),
        })
    }

    async fn health_check(&self) -> Result<()> {
        let res = tokio::time::timeout(
            Duration::from_secs(5),
            Command::new("docker").arg("version").output(),
        )
        .await
        .map_err(|_| anyhow!("docker version timed out (daemon may be down)"))?;
        let out = res.map_err(|e| {
            anyhow!(
                "docker binary not available: {} (install Docker Desktop or the docker CLI)",
                e
            )
        })?;
        if !out.status.success() {
            return Err(anyhow!(
                "docker version returned non-zero: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_env_uses_defaults_when_unset() {
        std::env::remove_var("CHUMP_DOCKER_IMAGE");
        std::env::remove_var("CHUMP_DOCKER_MOUNT");
        std::env::remove_var("CHUMP_DOCKER_NETWORK");
        let b = DockerBackend::from_env();
        assert_eq!(b.image, DEFAULT_IMAGE);
        assert_eq!(b.network, DEFAULT_NETWORK);
        assert!(b.mount.is_none());
    }

    #[test]
    fn build_args_includes_image_and_command() {
        let b = DockerBackend::new("alpine:3.20", None, "none");
        let req = ExecutionRequest {
            command: "echo hi".to_string(),
            ..Default::default()
        };
        let args = b.build_args(&req);
        assert_eq!(args[0], "run");
        assert!(args.contains(&"--rm".to_string()));
        assert!(args.contains(&"-i".to_string()));
        assert!(args.iter().any(|a| a == "alpine:3.20"));
        assert!(args.iter().any(|a| a == "echo hi"));
    }

    #[test]
    fn build_args_includes_mount_when_set() {
        let b = DockerBackend::new("alpine", Some("/host:/in".to_string()), "none");
        let req = ExecutionRequest::default();
        let args = b.build_args(&req);
        let pos = args.iter().position(|a| a == "-v").expect("missing -v");
        assert_eq!(args[pos + 1], "/host:/in");
    }

    #[tokio::test]
    async fn health_check_returns_helpful_error_when_docker_missing() {
        // Force PATH to a directory that has no `docker` so the spawn fails predictably.
        let original = std::env::var("PATH").ok();
        std::env::set_var("PATH", "/var/empty");
        let backend = DockerBackend::from_env();
        let result = backend.health_check().await;
        if let Some(p) = original {
            std::env::set_var("PATH", p);
        } else {
            std::env::remove_var("PATH");
        }
        assert!(result.is_err(), "expected docker missing to error");
        let err = result.unwrap_err().to_string();
        assert!(
            err.contains("docker") || err.contains("not available"),
            "unexpected error: {err}"
        );
    }
}
