//! MCP server: Android Debug Bridge operations via JSON-RPC 2.0 over stdio.
//! Set CHUMP_ADB_DEVICE=ip:port. Supports: status, connect, disconnect, shell,
//! input, screencap, ui_dump, list_packages, logcat, battery, getprop.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

#[derive(Deserialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    method: String,
    #[serde(default)]
    params: Value,
    id: Value,
}

#[derive(Serialize)]
struct JsonRpcResponse {
    jsonrpc: String,
    result: Option<Value>,
    error: Option<JsonRpcError>,
    id: Value,
}

#[derive(Serialize)]
struct JsonRpcError {
    code: i32,
    message: String,
}

const DEFAULT_TIMEOUT_SECS: u64 = 30;
const DEFAULT_MAX_OUTPUT: usize = 4000;

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
    "chmod 777",
    "chmod +s",
    "chown root",
    "mount ",
    "insmod ",
    "modprobe ",
    "setprop ",
    "pm disable",
    "pm clear",
    "am force-stop",
    "settings put global",
];

fn device() -> Result<String> {
    let d = std::env::var("CHUMP_ADB_DEVICE")
        .map_err(|_| anyhow!("CHUMP_ADB_DEVICE not set"))?
        .trim()
        .to_string();
    if d.is_empty() {
        return Err(anyhow!("CHUMP_ADB_DEVICE is empty"));
    }
    Ok(d)
}

fn timeout_secs() -> u64 {
    std::env::var("CHUMP_ADB_TIMEOUT")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (1..=300).contains(&n))
        .unwrap_or(DEFAULT_TIMEOUT_SECS)
}

fn max_output() -> usize {
    std::env::var("CHUMP_ADB_MAX_OUTPUT")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (500..=100_000).contains(&n))
        .unwrap_or(DEFAULT_MAX_OUTPUT)
}

fn blocklist_blocked(cmd: &str) -> bool {
    let lower = cmd.to_lowercase();
    ADB_SHELL_BLOCKLIST
        .iter()
        .any(|b| lower.contains(&b.to_lowercase()))
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() > max {
        format!("{}...", s.chars().take(max - 3).collect::<String>())
    } else {
        s.to_string()
    }
}

async fn run_adb(args: &[&str], timeout: u64) -> Result<(bool, String)> {
    let output = tokio::time::timeout(
        Duration::from_secs(timeout),
        Command::new("adb").args(args).output(),
    )
    .await
    .map_err(|_| anyhow!("adb timed out after {}s", timeout))??;
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
    Ok((ok, out))
}

async fn run_adb_s(device: &str, args: &[&str], timeout: u64) -> Result<(bool, String)> {
    let mut a = vec!["-s", device];
    a.extend(args);
    run_adb(&a, timeout).await
}

async fn handle_adb(params: &Value) -> Result<Value> {
    let action = params["action"]
        .as_str()
        .ok_or_else(|| anyhow!("missing action"))?
        .trim();
    let dev = device()?;
    let timeout = timeout_secs();
    let max = max_output();

    match action {
        "status" => {
            let (ok, out) = run_adb(&["devices"], timeout).await?;
            Ok(json!({ "success": ok, "output": truncate(out.trim(), max) }))
        }
        "connect" => {
            let (ok, out) = run_adb(&["connect", &dev], timeout).await?;
            Ok(json!({ "success": ok, "output": truncate(out.trim(), max) }))
        }
        "disconnect" => {
            let (ok, out) = run_adb(&["disconnect", &dev], timeout).await?;
            Ok(json!({ "success": ok, "output": truncate(out.trim(), max) }))
        }
        "shell" => {
            let cmd = params["command"]
                .as_str()
                .or_else(|| params["cmd"].as_str())
                .ok_or_else(|| anyhow!("shell requires 'command'"))?
                .trim();
            if blocklist_blocked(cmd) {
                return Err(anyhow!("blocked: command not allowed (safety blocklist)"));
            }
            let (ok, out) = run_adb_s(&dev, &["shell", cmd], timeout).await?;
            Ok(json!({ "success": ok, "output": truncate(&out, max) }))
        }
        "input" => {
            let cmd = params["command"]
                .as_str()
                .or_else(|| params["cmd"].as_str())
                .ok_or_else(|| anyhow!("input requires 'command' (e.g. 'tap 540 1800')"))?
                .trim();
            let (ok, out) = run_adb_s(&dev, &["shell", "input", cmd], timeout).await?;
            Ok(json!({ "success": ok, "output": if ok { "input sent".to_string() } else { truncate(&out, max) } }))
        }
        "screencap" => {
            let output = tokio::time::timeout(
                Duration::from_secs(timeout),
                Command::new("adb")
                    .args(["-s", &dev, "exec-out", "screencap", "-p"])
                    .output(),
            )
            .await
            .map_err(|_| anyhow!("screencap timed out"))??;
            if !output.status.success() {
                return Err(anyhow!(
                    "screencap failed: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ));
            }
            // Write to a temp file
            let path = std::env::temp_dir().join("chump_mcp_screen.png");
            tokio::fs::write(&path, &output.stdout).await?;
            Ok(json!({ "success": true, "output": format!("Screenshot saved to {}", path.display()), "bytes": output.stdout.len() }))
        }
        "battery" => {
            let (ok, out) = run_adb_s(&dev, &["shell", "dumpsys battery"], timeout).await?;
            Ok(json!({ "success": ok, "output": truncate(&out, max) }))
        }
        "getprop" => {
            let prop = params["prop"].as_str().unwrap_or("").trim();
            let (ok, out) = if prop.is_empty() {
                run_adb_s(&dev, &["shell", "getprop"], timeout).await?
            } else {
                run_adb_s(&dev, &["shell", "getprop", prop], timeout).await?
            };
            Ok(json!({ "success": ok, "output": truncate(&out, max) }))
        }
        "list_packages" => {
            let filter = params["filter"].as_str().unwrap_or("").trim();
            let mut args = vec!["shell", "pm", "list", "packages"];
            if !filter.is_empty() {
                args.push(filter);
            }
            let (ok, out) = run_adb_s(&dev, &args, timeout).await?;
            Ok(json!({ "success": ok, "output": truncate(&out, max) }))
        }
        "logcat" => {
            let lines = params["lines"]
                .as_u64()
                .unwrap_or(100)
                .min(500)
                .to_string();
            let (ok, out) = run_adb_s(&dev, &["logcat", "-d", "-t", &lines], timeout).await?;
            Ok(json!({ "success": ok, "output": truncate(&out, max) }))
        }
        "ui_dump" => {
            let remote_xml = "/sdcard/chump_window_dump.xml";
            run_adb_s(
                &dev,
                &["shell", &format!("uiautomator dump {}", remote_xml)],
                timeout,
            )
            .await?;
            let local_path = std::env::temp_dir().join("adb_ui_dump.xml");
            run_adb_s(
                &dev,
                &["pull", remote_xml, local_path.to_str().unwrap_or("/tmp/adb_ui_dump.xml")],
                timeout,
            )
            .await?;
            let _ = run_adb_s(&dev, &["shell", &format!("rm -f {}", remote_xml)], 5).await;
            let xml = tokio::fs::read_to_string(&local_path)
                .await
                .unwrap_or_else(|e| format!("Could not read dump: {}", e));
            Ok(json!({ "success": true, "output": truncate(&xml, max) }))
        }
        _ => Err(anyhow!(
            "unknown action '{}'. Use: status, connect, disconnect, shell, input, screencap, ui_dump, list_packages, logcat, battery, getprop",
            action
        )),
    }
}

async fn handle_method(method: &str, params: &Value) -> Result<Value> {
    match method {
        "adb" => handle_adb(params).await,
        "tools/list" => Ok(json!({
            "tools": [
                {
                    "name": "adb",
                    "description": "Control an Android phone over wireless ADB. Actions: status, connect, disconnect, shell, input, screencap, ui_dump, list_packages, logcat, battery, getprop. Set CHUMP_ADB_DEVICE=ip:port.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "action": { "type": "string", "description": "Action to run", "enum": ["status", "connect", "disconnect", "shell", "input", "screencap", "ui_dump", "list_packages", "logcat", "battery", "getprop"] },
                            "command": { "type": "string", "description": "For shell/input: the command" },
                            "filter": { "type": "string", "description": "For list_packages: filter" },
                            "lines": { "type": "number", "description": "For logcat: number of lines" },
                            "prop": { "type": "string", "description": "For getprop: property name" }
                        },
                        "required": ["action"]
                    }
                }
            ]
        })),
        _ => Err(anyhow!("unknown method: {}", method)),
    }
}

#[tokio::main]
async fn main() {
    let stdin = tokio::io::stdin();
    let reader = BufReader::new(stdin);
    let mut lines = reader.lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }

        let req: JsonRpcRequest = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let err_resp = JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32700,
                        message: format!("Parse error: {}", e),
                    }),
                    id: Value::Null,
                };
                println!("{}", serde_json::to_string(&err_resp).unwrap());
                continue;
            }
        };

        if req.jsonrpc != "2.0" {
            let err_resp = JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32600,
                    message: "Invalid Request: jsonrpc must be \"2.0\"".to_string(),
                }),
                id: req.id,
            };
            println!("{}", serde_json::to_string(&err_resp).unwrap());
            continue;
        }

        let resp = match handle_method(&req.method, &req.params).await {
            Ok(result) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: Some(result),
                error: None,
                id: req.id,
            },
            Err(e) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                result: None,
                error: Some(JsonRpcError {
                    code: -32603,
                    message: e.to_string(),
                }),
                id: req.id,
            },
        };
        println!("{}", serde_json::to_string(&resp).unwrap());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocklist_catches_dangerous_commands() {
        assert!(blocklist_blocked("rm -rf /"));
        assert!(blocklist_blocked("su "));
        assert!(!blocklist_blocked("ls /sdcard"));
    }

    #[tokio::test]
    async fn tools_list_returns_adb() {
        let result = handle_method("tools/list", &json!({})).await.unwrap();
        let tools = result["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0]["name"], "adb");
    }
}
