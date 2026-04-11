//! Tauri desktop shell (Option B: HTTP sidecar).
//! Loads [`web/`](../../web/) in the WebView; talks to **`CHUMP_DESKTOP_API_BASE`** (default `http://127.0.0.1:3000`).
//!
//! **One-app experience:** unless `CHUMP_DESKTOP_AUTO_WEB=0`, on startup we try to spawn the sibling **`chump --web`**
//! binary (same directory as `chump-desktop`) if `/api/health` is not yet reachable.

use serde::Deserialize;
use serde_json::json;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::Manager;

static SIDE_SPAWN_ATTEMPTED: AtomicBool = AtomicBool::new(false);

fn get_desktop_api_base_inner() -> String {
    std::env::var("CHUMP_DESKTOP_API_BASE")
        .unwrap_or_else(|_| "http://127.0.0.1:3000".to_string())
        .trim_end_matches('/')
        .to_string()
}

/// Base URL for the Chump web server (no trailing slash). Override with `CHUMP_DESKTOP_API_BASE`.
#[tauri::command]
fn get_desktop_api_base() -> String {
    get_desktop_api_base_inner()
}

fn sidecar_base() -> String {
    get_desktop_api_base_inner()
}

fn http_client_short() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(|e| e.to_string())
}

fn http_client_long() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(300))
        .build()
        .map_err(|e| e.to_string())
}

/// `true` unless `CHUMP_DESKTOP_AUTO_WEB` is `0`, `false`, or `off`.
fn desktop_auto_spawn_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_DESKTOP_AUTO_WEB").map(|v| v.to_lowercase()),
        Ok(v) if v == "0" || v == "false" || v == "off"
    )
}

fn port_from_sidecar_base(base: &str) -> u16 {
    let b = base.trim_end_matches('/');
    if let Some(colon) = b.rfind(':') {
        let tail = &b[colon + 1..];
        if !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit()) {
            return tail.parse().unwrap_or(3000);
        }
    }
    3000
}

fn sibling_chump_binary() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let name = if cfg!(target_os = "windows") {
        "chump.exe"
    } else {
        "chump"
    };
    let p = dir.join(name);
    if p.is_file() {
        Some(p)
    } else {
        None
    }
}

/// Working directory for the spawned `chump --web` so `load_dotenv()` finds repo `.env` (MLX on 8001, etc.).
fn sidecar_repo_cwd() -> Option<PathBuf> {
    for key in ["CHUMP_REPO", "CHUMP_HOME"] {
        if let Ok(p) = std::env::var(key) {
            let pb = PathBuf::from(p.trim());
            if pb.is_dir() && pb.join(".env").is_file() {
                return Some(pb);
            }
        }
    }
    // Dev: `chump-desktop` lives in `target/debug/` — walk up to the repo root that has `.env` + `Cargo.toml`.
    let mut dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    for _ in 0..14 {
        if dir.join(".env").is_file() && dir.join("Cargo.toml").is_file() {
            return Some(dir);
        }
        dir = dir.parent()?.to_path_buf();
    }
    None
}

async fn health_ok(base: &str) -> bool {
    let Ok(client) = http_client_short() else {
        return false;
    };
    let url = format!("{}/api/health", base);
    client
        .get(&url)
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

fn set_window_title(handle: &tauri::AppHandle, online: bool) {
    let Some(w) = handle.get_webview_window("main") else {
        return;
    };
    let title = if online {
        "Chump · Cowork — online"
    } else {
        "Chump · Cowork — engine offline"
    };
    let _ = w.set_title(title);
}

/// Spawn `chump --web --port …` once per process unless `force` clears the latch.
async fn spawn_chump_web_sidecar(base: &str, force: bool) -> Result<serde_json::Value, String> {
    if force {
        SIDE_SPAWN_ATTEMPTED.store(false, Ordering::SeqCst);
    }
    if SIDE_SPAWN_ATTEMPTED.load(Ordering::SeqCst) && !force {
        return Ok(json!({ "spawned": false, "reason": "already_attempted" }));
    }
    let Some(bin) = sibling_chump_binary() else {
        return Ok(json!({ "spawned": false, "reason": "chump_binary_not_found_next_to_desktop" }));
    };
    let port = port_from_sidecar_base(base);
    let mut cmd = Command::new(&bin);
    cmd.arg("--web").arg("--port").arg(port.to_string());
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::null());
    if let Some(dir) = sidecar_repo_cwd() {
        cmd.current_dir(&dir);
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return Ok(json!({
                "spawned": false,
                "reason": format!("spawn_failed: {}", e)
            }));
        }
    };
    SIDE_SPAWN_ATTEMPTED.store(true, Ordering::SeqCst);
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(json!({ "spawned": true, "port": port }))
}

/// Try to start the local web engine (`chump --web`). Call from the UI **Retry** when health fails.
/// Pass `force: true` to spawn again even if a previous attempt ran this session.
#[tauri::command]
async fn try_bring_sidecar_online(force: Option<bool>) -> Result<serde_json::Value, String> {
    let base = sidecar_base();
    let force = force.unwrap_or(false);
    if health_ok(&base).await {
        return Ok(json!({ "ok": true, "health": true, "spawned": false }));
    }
    let spawn_out = spawn_chump_web_sidecar(&base, force).await?;
    for _ in 0..100 {
        tokio::time::sleep(Duration::from_millis(200)).await;
        if health_ok(&base).await {
            return Ok(json!({
                "ok": true,
                "health": true,
                "spawned": spawn_out.get("spawned").and_then(|v| v.as_bool()).unwrap_or(false),
                "wait_ms": "up_to_20s"
            }));
        }
    }
    Ok(json!({
        "ok": false,
        "health": false,
        "spawned": spawn_out.get("spawned").and_then(|v| v.as_bool()).unwrap_or(false),
        "reason": "health_still_unreachable_after_wait"
    }))
}

/// GET `{base}/api/health` — diagnostics when the sidecar is up.
#[tauri::command]
async fn health_snapshot() -> Result<String, String> {
    let url = format!("{}/api/health", sidecar_base());
    let client = http_client_short()?;
    let res = client.get(&url).send().await.map_err(|e| e.to_string())?;
    let status = res.status();
    let text = res.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!(
            "HTTP {}: {}",
            status,
            text.chars().take(240).collect::<String>()
        ));
    }
    Ok(text)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveToolApprovalArgs {
    pub request_id: String,
    pub allowed: bool,
    #[serde(default)]
    pub token: Option<String>,
}

/// POST `/api/approve` on the sidecar (same contract as the PWA).
#[tauri::command]
async fn resolve_tool_approval(args: ResolveToolApprovalArgs) -> Result<String, String> {
    let url = format!("{}/api/approve", sidecar_base());
    let client = http_client_short()?;
    let body = serde_json::json!({
        "request_id": args.request_id,
        "allowed": args.allowed,
    })
    .to_string();
    let mut req = client
        .post(&url)
        .header("Content-Type", "application/json")
        .body(body);
    if let Some(t) = args
        .token
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        req = req.header("Authorization", format!("Bearer {}", t));
    }
    let res = req.send().await.map_err(|e| e.to_string())?;
    let status = res.status();
    let text = res.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!(
            "HTTP {}: {}",
            status,
            text.chars().take(240).collect::<String>()
        ));
    }
    Ok(text)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmitChatArgs {
    pub body_json: String,
    #[serde(default)]
    pub token: Option<String>,
}

/// POST `/api/chat` on the sidecar; returns the **full raw** response body (SSE text).
#[tauri::command]
async fn submit_chat(args: SubmitChatArgs) -> Result<String, String> {
    let url = format!("{}/api/chat", sidecar_base());
    let client = http_client_long()?;
    let mut req = client
        .post(&url)
        .header("Content-Type", "application/json")
        .body(args.body_json);
    if let Some(t) = args
        .token
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        req = req.header("Authorization", format!("Bearer {}", t));
    }
    let res = req.send().await.map_err(|e| e.to_string())?;
    let status = res.status();
    let text = res.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!(
            "HTTP {}: {}",
            status,
            text.chars().take(400).collect::<String>()
        ));
    }
    Ok(text)
}

#[tauri::command]
fn ping_orchestrator() -> &'static str {
    "Chump desktop IPC ok"
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(Duration::from_millis(400)).await;
                let base = get_desktop_api_base_inner();
                if health_ok(&base).await {
                    set_window_title(&handle, true);
                    return;
                }
                if desktop_auto_spawn_enabled() {
                    let _ = spawn_chump_web_sidecar(&base, false).await;
                    for _ in 0..100 {
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        if health_ok(&base).await {
                            set_window_title(&handle, true);
                            return;
                        }
                    }
                }
                set_window_title(&handle, false);
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            ping_orchestrator,
            get_desktop_api_base,
            health_snapshot,
            resolve_tool_approval,
            submit_chat,
            try_bring_sidecar_online
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn port_from_sidecar_base_defaults() {
        assert_eq!(port_from_sidecar_base("http://127.0.0.1:3000"), 3000);
        assert_eq!(port_from_sidecar_base("http://127.0.0.1:3000/"), 3000);
        assert_eq!(port_from_sidecar_base("http://127.0.0.1:3001"), 3001);
    }

    #[test]
    fn port_from_sidecar_base_no_numeric_port_falls_back() {
        assert_eq!(port_from_sidecar_base("http://127.0.0.1"), 3000);
        assert_eq!(port_from_sidecar_base("http://localhost"), 3000);
    }

    #[test]
    fn desktop_auto_spawn_respects_env() {
        let _g = ENV_LOCK.lock().expect("env test lock");
        std::env::remove_var("CHUMP_DESKTOP_AUTO_WEB");
        assert!(
            desktop_auto_spawn_enabled(),
            "default should allow auto-spawn"
        );

        for v in ["0", "false", "off", "FALSE", "OFF"] {
            std::env::set_var("CHUMP_DESKTOP_AUTO_WEB", v);
            assert!(
                !desktop_auto_spawn_enabled(),
                "CHUMP_DESKTOP_AUTO_WEB={v} should disable"
            );
        }
        std::env::remove_var("CHUMP_DESKTOP_AUTO_WEB");
        assert!(desktop_auto_spawn_enabled());
    }
}
