//! ADB tool for Chump: run adb commands against a wireless Android device (e.g. Pixel on Tailscale).
//! Enable with CHUMP_ADB_ENABLED=1 and CHUMP_ADB_DEVICE=ip:port. Pair once with `adb pair <ip>:<pairing_port>` and the code; then connect with the port shown on the wireless debugging screen.
//! See docs/ROADMAP_ADB.md.

use crate::chump_log;
use crate::repo_path;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Duration;
use tokio::process::Command;

const DEFAULT_TIMEOUT_SECS: u64 = 30;
const DEFAULT_MAX_OUTPUT: usize = 4000;

/// Dangerous shell substrings that are always blocked.
const ADB_SHELL_BLOCKLIST: &[&str] = &[
    "rm -rf /",
    "rm -rf /system",
    "factory_reset",
    "wipe data",
    "flash",
    "fastboot",
    "su ",
    "su\n",
    "reboot bootloader",
    "dd if=",
    "dd of=",
];

pub struct AdbTool {
    device: String,
    timeout_secs: u64,
    max_output: usize,
    /// If non-empty, only these actions are allowed (e.g. "input,screencap,shell,status").
    allowlist: Vec<String>,
    /// When true, install/push/uninstall return error asking for owner approval (notify then retry).
    confirm_destructive: bool,
}

/// True when CHUMP_ADB_ENABLED=1 (or "true") and CHUMP_ADB_DEVICE is set. Does not check that adb is on PATH.
pub fn adb_enabled() -> bool {
    let on = std::env::var("CHUMP_ADB_ENABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let device = std::env::var("CHUMP_ADB_DEVICE")
        .unwrap_or_default()
        .trim()
        .to_string();
    on && !device.is_empty()
}

impl AdbTool {
    pub fn from_env() -> Self {
        let device = std::env::var("CHUMP_ADB_DEVICE")
            .unwrap_or_else(|_| "".to_string())
            .trim()
            .to_string();
        let timeout_secs = std::env::var("CHUMP_ADB_TIMEOUT")
            .ok()
            .and_then(|v| v.parse().ok())
            .filter(|&n| n >= 1 && n <= 300)
            .unwrap_or(DEFAULT_TIMEOUT_SECS);
        let max_output = std::env::var("CHUMP_ADB_MAX_OUTPUT")
            .ok()
            .and_then(|v| v.parse().ok())
            .filter(|&n| n >= 500 && n <= 100_000)
            .unwrap_or(DEFAULT_MAX_OUTPUT);
        let allowlist: Vec<String> = std::env::var("CHUMP_ADB_ALLOWLIST")
            .ok()
            .map(|s| {
                s.split(',')
                    .map(|x| x.trim().to_lowercase())
                    .filter(|x| !x.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let confirm_destructive = std::env::var("CHUMP_ADB_CONFIRM_DESTRUCTIVE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        Self {
            device,
            timeout_secs,
            max_output,
            allowlist,
            confirm_destructive,
        }
    }

    fn needs_confirmation(&self, action: &str) -> bool {
        if !self.confirm_destructive {
            return false;
        }
        matches!(action, "install" | "push" | "uninstall")
    }

    fn action_allowed(&self, action: &str) -> bool {
        if self.allowlist.is_empty() {
            return true;
        }
        self.allowlist
            .contains(&action.to_lowercase().to_string())
    }

    fn blocklist_blocked(&self, shell_cmd: &str) -> bool {
        let lower = shell_cmd.to_lowercase();
        ADB_SHELL_BLOCKLIST
            .iter()
            .any(|b| lower.contains(&b.to_lowercase()))
    }

    async fn run_adb(&self, args: &[&str], timeout_secs: u64) -> Result<(bool, String)> {
        let output = tokio::time::timeout(
            Duration::from_secs(timeout_secs),
            Command::new("adb").args(args).output(),
        )
        .await
        .map_err(|_| anyhow!("adb timed out after {}s", timeout_secs))??;
        let mut out = String::new();
        if !output.stdout.is_empty() {
            out.push_str(&String::from_utf8_lossy(&output.stdout));
        }
        if !output.stderr.is_empty() {
            if !out.is_empty() {
                out.push_str("\nstderr: ");
            }
            out.push_str(&String::from_utf8_lossy(&output.stderr));
        }
        let ok = output.status.success();
        if out.is_empty() && !ok {
            out = format!("exit code {:?}", output.status.code());
        }
        let cmd_preview = format!("adb {}", args.join(" "));
        chump_log::log_adb(
            &cmd_preview,
            output.status.code().map(|c| c as i32),
            out.len(),
        );
        Ok((ok, out))
    }

    async fn run_adb_s(&self, args: &[&str], timeout_secs: u64) -> Result<(bool, String)> {
        let mut a = vec!["-s", self.device.as_str()];
        a.extend(args);
        self.run_adb(&a, timeout_secs).await
    }

    async fn execute_action(&self, action: &str, input: &Value) -> Result<String> {
        if !self.action_allowed(action) {
            return Err(anyhow!(
                "adb action '{}' is not in CHUMP_ADB_ALLOWLIST",
                action
            ));
        }
        if self.needs_confirmation(action) {
            return Err(anyhow!(
                "Action '{}' requires confirmation (CHUMP_ADB_CONFIRM_DESTRUCTIVE=1). Use notify to ask the owner for approval, then retry.",
                action
            ));
        }

        match action {
            "status" => {
                let (ok, out) = self.run_adb(&["devices"], self.timeout_secs).await?;
                let trimmed = out.trim();
                let truncated = if trimmed.len() > self.max_output {
                    format!("{}…", trimmed.chars().take(self.max_output - 1).collect::<String>())
                } else {
                    trimmed.to_string()
                };
                Ok(if ok {
                    truncated
                } else {
                    format!("adb devices failed: {}", truncated)
                })
            }
            "connect" => {
                let (ok, out) = self
                    .run_adb(&["connect", self.device.as_str()], self.timeout_secs)
                    .await?;
                let trimmed = out.trim();
                Ok(if ok {
                    format!("Connected to {}: {}", self.device, trimmed)
                } else {
                    format!("Connect failed: {}", trimmed)
                })
            }
            "disconnect" => {
                let (ok, out) = if self.device.is_empty() {
                    self.run_adb(&["disconnect"], self.timeout_secs).await?
                } else {
                    self.run_adb(&["disconnect", self.device.as_str()], self.timeout_secs)
                        .await?
                };
                Ok(if ok {
                    out.trim().to_string()
                } else {
                    format!("disconnect: {}", out.trim())
                })
            }
            "shell" => {
                let cmd = input
                    .get("command")
                    .or_else(|| input.get("cmd"))
                    .and_then(|c| c.as_str())
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| anyhow!("shell action requires 'command'"))?;
                if self.blocklist_blocked(&cmd) {
                    return Err(anyhow!("blocked: shell command not allowed (safety blocklist)"));
                }
                let (ok, out) = self
                    .run_adb_s(&["shell", cmd.as_str()], self.timeout_secs)
                    .await?;
                let truncated = if out.len() > self.max_output {
                    format!("{}…", out.chars().take(self.max_output - 1).collect::<String>())
                } else {
                    out
                };
                Ok(if ok {
                    truncated
                } else {
                    format!("shell failed: {}", truncated)
                })
            }
            "input" => {
                let cmd = input
                    .get("command")
                    .or_else(|| input.get("cmd"))
                    .and_then(|c| c.as_str())
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| anyhow!("input action requires 'command' (e.g. 'tap 540 1800', 'text \"hello\"', 'keyevent 4')"))?;
                let (ok, out) = self
                    .run_adb_s(&["shell", "input", cmd.as_str()], self.timeout_secs)
                    .await?;
                Ok(if ok {
                    "input sent.".to_string()
                } else {
                    format!("input failed: {}", out.trim())
                })
            }
            "screencap" => {
                let base = repo_path::runtime_base();
                let logs = base.join("logs");
                let _ = std::fs::create_dir_all(&logs);
                let local: PathBuf = logs.join("chump_screen.png");

                // exec-out sends raw binary to host; avoids PTY corruption.
                let output = tokio::time::timeout(
                    Duration::from_secs(self.timeout_secs),
                    Command::new("adb")
                        .args(["-s", self.device.as_str(), "exec-out", "screencap", "-p"])
                        .output(),
                )
                .await
                .map_err(|_| anyhow!("adb screencap timed out after {}s", self.timeout_secs))??;
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(anyhow!("adb exec-out screencap failed: {}", stderr.trim()));
                }
                if output.stdout.is_empty() {
                    return Err(anyhow!("adb screencap produced no output"));
                }
                tokio::fs::write(&local, &output.stdout)
                    .await
                    .map_err(|e| anyhow!("write {}: {}", local.display(), e))?;
                chump_log::log_adb(
                    "adb -s <device> exec-out screencap -p",
                    Some(0),
                    output.stdout.len(),
                );
                Ok(format!(
                    "Screenshot saved to {}. Use read_file to view or vision/OCR to analyze.",
                    local.display()
                ))
            }
            "ui_dump" => {
                let remote_xml = "/sdcard/chump_window_dump.xml";
                let base = repo_path::runtime_base();
                let logs = base.join("logs");
                let _ = std::fs::create_dir_all(&logs);
                let local_path = logs.join("adb_ui_dump.xml");
                self.run_adb_s(
                    &["shell", &format!("uiautomator dump {}", remote_xml)],
                    self.timeout_secs,
                )
                .await?;
                self.run_adb_s(
                    &["pull", remote_xml, local_path.to_str().unwrap_or("logs/adb_ui_dump.xml")],
                    self.timeout_secs,
                )
                .await?;
                let _ = self
                    .run_adb_s(&["shell", &format!("rm -f {}", remote_xml)], 5)
                    .await;
                match std::fs::read_to_string(&local_path) {
                    Ok(xml) => {
                        let out = if xml.len() > self.max_output {
                            format!(
                                "UI dump (truncated to {} chars):\n{}…",
                                self.max_output,
                                xml.chars().take(self.max_output - 50).collect::<String>()
                            )
                        } else {
                            format!("UI dump:\n{}", xml)
                        };
                        Ok(out)
                    }
                    Err(e) => Ok(format!(
                        "UI dump saved to {} but could not read: {}",
                        local_path.display(),
                        e
                    )),
                }
            }
            "battery" => {
                let (ok, out) = self
                    .run_adb_s(&["shell", "dumpsys battery"], self.timeout_secs)
                    .await?;
                let truncated = if out.len() > self.max_output {
                    format!("{}…", out.chars().take(self.max_output - 1).collect::<String>())
                } else {
                    out
                };
                Ok(if ok {
                    truncated
                } else {
                    format!("battery failed: {}", truncated)
                })
            }
            "getprop" => {
                let prop = input.get("prop").and_then(|v| v.as_str()).map(|s| s.trim()).filter(|s| !s.is_empty());
                let (ok, out) = if let Some(p) = prop {
                    self.run_adb_s(&["shell", "getprop", p], self.timeout_secs).await?
                } else {
                    self.run_adb_s(&["shell", "getprop"], self.timeout_secs).await?
                };
                let truncated = if out.len() > self.max_output {
                    format!("{}…", out.chars().take(self.max_output - 1).collect::<String>())
                } else {
                    out
                };
                Ok(if ok {
                    truncated
                } else {
                    format!("getprop failed: {}", truncated)
                })
            }
            "install" => {
                let apk_path = input
                    .get("apk_path")
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| anyhow!("install requires apk_path (local path to .apk)"))?;
                let (ok, out) = self
                    .run_adb_s(&["install", apk_path], self.timeout_secs)
                    .await?;
                Ok(if ok {
                    out.trim().to_string()
                } else {
                    format!("install failed: {}", out.trim())
                })
            }
            "uninstall" => {
                let package = input
                    .get("package")
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| anyhow!("uninstall requires package name"))?;
                let (ok, out) = self
                    .run_adb_s(&["uninstall", package], self.timeout_secs)
                    .await?;
                Ok(if ok {
                    out.trim().to_string()
                } else {
                    format!("uninstall failed: {}", out.trim())
                })
            }
            "push" => {
                let local = input
                    .get("local_path")
                    .or_else(|| input.get("local"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| anyhow!("push requires local_path and remote_path"))?;
                let remote = input
                    .get("remote_path")
                    .or_else(|| input.get("remote"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| anyhow!("push requires local_path and remote_path"))?;
                let (ok, out) = self
                    .run_adb_s(&["push", local, remote], self.timeout_secs)
                    .await?;
                Ok(if ok {
                    out.trim().to_string()
                } else {
                    format!("push failed: {}", out.trim())
                })
            }
            "pull" => {
                let remote = input
                    .get("remote_path")
                    .or_else(|| input.get("remote"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| anyhow!("pull requires remote_path"))?;
                let base = repo_path::runtime_base();
                let logs = base.join("logs");
                let _ = std::fs::create_dir_all(&logs);
                let default_local = logs
                    .join(remote.rsplit('/').next().unwrap_or("adb_pulled"))
                    .to_string_lossy()
                    .to_string();
                let local = input
                    .get("local_path")
                    .or_else(|| input.get("local"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                    .unwrap_or(&default_local);
                let (ok, out) = self
                    .run_adb_s(&["pull", remote, local], self.timeout_secs)
                    .await?;
                Ok(if ok {
                    format!("Pulled to {}", local)
                } else {
                    format!("pull failed: {}", out.trim())
                })
            }
            "list_packages" => {
                let filter = input
                    .get("filter")
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty());
                let mut args = vec!["shell", "pm", "list", "packages"];
                if let Some(f) = filter {
                    args.push(f);
                }
                let (ok, out) = self.run_adb_s(&args, self.timeout_secs).await?;
                let truncated = if out.len() > self.max_output {
                    format!("{}…", out.chars().take(self.max_output - 1).collect::<String>())
                } else {
                    out
                };
                Ok(if ok {
                    truncated
                } else {
                    format!("list_packages failed: {}", truncated)
                })
            }
            "logcat" => {
                let lines = input
                    .get("lines")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(100);
                let lines = lines.min(500) as i64;
                let (ok, out) = self
                    .run_adb_s(
                        &["logcat", "-d", "-t", &lines.to_string()],
                        self.timeout_secs,
                    )
                    .await?;
                let truncated = if out.len() > self.max_output {
                    format!("{}…", out.chars().take(self.max_output - 1).collect::<String>())
                } else {
                    out
                };
                Ok(if ok {
                    truncated
                } else {
                    format!("logcat failed: {}", truncated)
                })
            }
            _ => Err(anyhow!(
                "unknown action '{}'. Use one of: status, connect, disconnect, shell, input, screencap, ui_dump, list_packages, logcat, battery, getprop, install, uninstall, push, pull",
                action
            )),
        }
    }
}

#[async_trait]
impl Tool for AdbTool {
    fn name(&self) -> String {
        "adb".to_string()
    }

    fn description(&self) -> String {
        "Control an Android phone over wireless ADB. Actions: status, connect, disconnect, shell, input (tap/swipe/text/keyevent), screencap, ui_dump (UI hierarchy XML), list_packages, logcat, battery, getprop, install, uninstall, push, pull. Use screencap or ui_dump to see the screen. If device offline, call connect first. Set CHUMP_ADB_DEVICE=ip:port and CHUMP_ADB_ENABLED=1.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "Action to run",
                    "enum": ["status", "connect", "disconnect", "shell", "input", "screencap", "ui_dump", "list_packages", "logcat", "battery", "getprop", "install", "uninstall", "push", "pull"]
                },
                "command": {
                    "type": "string",
                    "description": "For shell: full shell command. For input: e.g. 'tap 540 1800', 'text \"hello\"', 'keyevent 4'"
                },
                "filter": {
                    "type": "string",
                    "description": "Optional filter for list_packages"
                },
                "lines": {
                    "type": "number",
                    "description": "For logcat: number of lines (default 100, max 500)"
                },
                "prop": {
                    "type": "string",
                    "description": "For getprop: property name (e.g. ro.build.version.release); omit for all"
                },
                "apk_path": {
                    "type": "string",
                    "description": "For install: local path to .apk"
                },
                "package": {
                    "type": "string",
                    "description": "For uninstall: package name"
                },
                "local_path": {
                    "type": "string",
                    "description": "For push: local file; for pull: optional destination"
                },
                "remote_path": {
                    "type": "string",
                    "description": "For push: device path; for pull: device path"
                }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| anyhow!("missing 'action'"))?;
        self.execute_action(action, &input).await
    }
}
