//! SSH execution backend — runs commands on a remote host via ssh.
//!
//! Configured via CHUMP_SSH_HOST (required for this backend) and CHUMP_SSH_USER
//! (default: current user). Uses the system ssh binary; SSH keys must be
//! configured separately in ~/.ssh/config.

use super::{ExecutionBackend, ExecutionRequest, ExecutionResult};
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use std::process::Stdio;
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

const DEFAULT_PORT: u16 = 22;

pub struct SshBackend {
    host: Option<String>,
    user: Option<String>,
    port: u16,
    options: Vec<String>,
}

impl SshBackend {
    pub fn new(
        host: Option<String>,
        user: Option<String>,
        port: u16,
        options: Vec<String>,
    ) -> Self {
        Self {
            host,
            user,
            port,
            options,
        }
    }

    pub fn from_env() -> Self {
        let host = std::env::var("CHUMP_SSH_HOST").ok().filter(|s| !s.is_empty());
        let user = std::env::var("CHUMP_SSH_USER")
            .ok()
            .or_else(|| std::env::var("USER").ok())
            .filter(|s| !s.is_empty());
        let port = std::env::var("CHUMP_SSH_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_PORT);
        let options: Vec<String> = std::env::var("CHUMP_SSH_OPTIONS")
            .ok()
            .map(|s| {
                s.split_whitespace()
                    .map(|x| x.to_string())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        Self::new(host, user, port, options)
    }

    fn target(&self) -> Result<String> {
        let host = self
            .host
            .as_ref()
            .ok_or_else(|| anyhow!("CHUMP_SSH_HOST is not set; ssh backend requires a host"))?;
        Ok(match &self.user {
            Some(u) => format!("{}@{}", u, host),
            None => host.clone(),
        })
    }

    fn build_args(&self, req: &ExecutionRequest) -> Result<Vec<String>> {
        let mut args: Vec<String> = Vec::new();
        args.push("-p".into());
        args.push(self.port.to_string());
        args.push("-o".into());
        args.push("BatchMode=yes".into());
        for opt in &self.options {
            args.push(opt.clone());
        }
        args.push(self.target()?);
        // Build remote shell command. Honour cwd and env_vars by prefixing.
        let mut remote = String::new();
        for (k, v) in &req.env_vars {
            // Best-effort POSIX export. Caller must avoid shell-meta in env values.
            remote.push_str(&format!("export {}={}; ", k, shell_escape(v)));
        }
        if let Some(cwd) = &req.cwd {
            remote.push_str(&format!("cd {} && ", shell_escape(cwd)));
        }
        remote.push_str(&req.command);
        args.push(remote);
        Ok(args)
    }
}

fn shell_escape(s: &str) -> String {
    // Single-quote the value, escaping internal single quotes.
    let escaped = s.replace('\'', "'\\''");
    format!("'{}'", escaped)
}

#[async_trait]
impl ExecutionBackend for SshBackend {
    fn name(&self) -> &'static str {
        "ssh"
    }

    async fn execute(&self, req: ExecutionRequest) -> Result<ExecutionResult> {
        let started = Instant::now();
        let args = self.build_args(&req)?;
        let mut cmd = Command::new("ssh");
        cmd.args(&args);
        if req.stdin.is_some() {
            cmd.stdin(Stdio::piped());
        }
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());

        let mut child = cmd.spawn().map_err(|e| {
            anyhow!(
                "failed to spawn ssh (is the ssh binary installed and on PATH?): {}",
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
            Ok(res) => res.map_err(|e| anyhow!("ssh backend wait failed: {}", e))?,
            Err(_) => {
                return Err(anyhow!(
                    "command timed out after {}s (ssh backend)",
                    req.timeout.as_secs()
                ));
            }
        };

        Ok(ExecutionResult {
            exit_code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
            duration_ms: started.elapsed().as_millis() as u64,
            backend: "ssh".to_string(),
        })
    }

    async fn health_check(&self) -> Result<()> {
        let target = self.target()?;
        let res = tokio::time::timeout(
            Duration::from_secs(8),
            Command::new("ssh")
                .args([
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "ConnectTimeout=5",
                    "-p",
                    &self.port.to_string(),
                    &target,
                    "echo ok",
                ])
                .output(),
        )
        .await
        .map_err(|_| anyhow!("ssh health check timed out (host {} unreachable)", target))?;
        let out = res.map_err(|e| {
            anyhow!(
                "ssh binary not available: {} (install OpenSSH client and configure ~/.ssh/config)",
                e
            )
        })?;
        if !out.status.success() {
            return Err(anyhow!(
                "ssh health check failed for {}: {}",
                target,
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
    fn target_requires_host() {
        let b = SshBackend::new(None, Some("alice".into()), 22, vec![]);
        assert!(b.target().is_err());
    }

    #[test]
    fn target_combines_user_and_host() {
        let b = SshBackend::new(Some("box.example".into()), Some("alice".into()), 22, vec![]);
        assert_eq!(b.target().unwrap(), "alice@box.example");
    }

    #[test]
    fn target_omits_user_when_none() {
        let b = SshBackend::new(Some("box.example".into()), None, 22, vec![]);
        assert_eq!(b.target().unwrap(), "box.example");
    }

    #[test]
    fn build_args_includes_port_and_batch_mode() {
        let b = SshBackend::new(Some("box.example".into()), Some("alice".into()), 2222, vec![]);
        let req = ExecutionRequest {
            command: "uname -a".into(),
            ..Default::default()
        };
        let args = b.build_args(&req).unwrap();
        assert!(args.iter().any(|a| a == "2222"));
        assert!(args.iter().any(|a| a == "BatchMode=yes"));
        assert!(args.iter().any(|a| a == "alice@box.example"));
        assert!(args.iter().any(|a| a.contains("uname -a")));
    }

    #[test]
    fn build_args_prefixes_cwd_and_env() {
        let b = SshBackend::new(Some("box".into()), None, 22, vec![]);
        let req = ExecutionRequest {
            command: "ls".into(),
            cwd: Some("/tmp".into()),
            env_vars: vec![("FOO".into(), "bar".into())],
            ..Default::default()
        };
        let args = b.build_args(&req).unwrap();
        let last = args.last().unwrap();
        assert!(last.contains("export FOO="));
        assert!(last.contains("cd '/tmp'"));
        assert!(last.ends_with("ls"));
    }

    #[test]
    fn shell_escape_handles_quotes() {
        assert_eq!(shell_escape("plain"), "'plain'");
        assert_eq!(shell_escape("it's"), "'it'\\''s'");
    }

    #[tokio::test]
    async fn execute_errors_when_host_missing() {
        let b = SshBackend::new(None, None, 22, vec![]);
        let req = ExecutionRequest {
            command: "echo hi".into(),
            timeout: Duration::from_secs(2),
            ..Default::default()
        };
        let r = b.execute(req).await;
        assert!(r.is_err());
        assert!(r.unwrap_err().to_string().contains("CHUMP_SSH_HOST"));
    }

    #[tokio::test]
    async fn health_check_errors_when_host_missing() {
        let b = SshBackend::new(None, None, 22, vec![]);
        let r = b.health_check().await;
        assert!(r.is_err());
    }
}
