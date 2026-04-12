//! Tauri desktop shell (Option B: HTTP sidecar).
//! Loads [`web/`](../../web/) in the WebView; talks to **`CHUMP_DESKTOP_API_BASE`** (default `http://127.0.0.1:3000`).
//!
//! **One-app experience:** unless `CHUMP_DESKTOP_AUTO_WEB=0`, on startup we try to spawn **`chump --web`**
//! if `/api/health` is not yet reachable. Binary resolution: **`CHUMP_BINARY`**, then **`chump`** next to `chump-desktop`
//! (dev or a copied MacOS bundle layout).
//!
//! **OOTB:** [`ootb`] first-run flow (Application Support `.env`, Ollama). See `docs/PACKAGED_OOTB_DESKTOP.md`.

mod ootb;

use serde::Deserialize;
use serde_json::json;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::Emitter;
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

/// `chump` next to `chump-desktop`, or **`CHUMP_BINARY`** (absolute path) from Info.plist / shell.
fn sidecar_chump_binary() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("CHUMP_BINARY") {
        let pb = PathBuf::from(p.trim());
        if pb.is_file() {
            return Some(pb);
        }
    }
    sibling_chump_binary()
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
    // Bundled .app (no repo walk): common clone path when `LSEnvironment` was not set.
    #[cfg(target_os = "macos")]
    if let Ok(home) = std::env::var("HOME") {
        let guess = PathBuf::from(home).join("Projects/Chump");
        if guess.join(".env").is_file() {
            return Some(guess);
        }
    }
    // Packaged / novice: `~/Library/Application Support/Chump/.env` (etc.)
    if let Some(ud) = ootb::user_data_dotenv_dir() {
        return Some(ud);
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
    let Some(bin) = sidecar_chump_binary() else {
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

#[tauri::command]
fn ootb_wizard_should_show() -> bool {
    ootb::wizard_should_show()
}

#[tauri::command]
async fn ootb_detect_ollama() -> serde_json::Value {
    ootb::detect_ollama().await
}

#[tauri::command]
fn ootb_open_ollama_download() -> Result<(), String> {
    ootb::open_ollama_download_page()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OotbPrepareUserDataArgs {
    pub model: String,
    #[serde(default)]
    pub openai_api_base: Option<String>,
}

#[tauri::command]
fn ootb_prepare_user_data(args: OotbPrepareUserDataArgs) -> Result<String, String> {
    let dir = ootb::ensure_user_data_and_env(args.model.trim(), args.openai_api_base)?;
    Ok(dir.to_string_lossy().to_string())
}

#[tauri::command]
async fn ootb_pull_model(app: tauri::AppHandle, model: String) -> Result<String, String> {
    use std::sync::Arc;
    let emitter = app.clone();
    let on_line: Arc<dyn Fn(String) + Send + Sync> = Arc::new(move |line: String| {
        let _ = emitter.emit("ootb-pull-line", json!({ "line": line }));
    });
    ootb::ollama_pull_with_lines(model.trim().to_string(), on_line).await
}

#[tauri::command]
async fn ootb_model_present(model: String) -> bool {
    ootb::ollama_has_model(model.trim()).await
}

#[tauri::command]
fn ootb_default_model() -> String {
    ootb::DEFAULT_OLLAMA_MODEL.to_string()
}

#[tauri::command]
fn ootb_user_data_dir_path() -> Result<String, String> {
    ootb::chump_user_data_dir()
        .map(|p| p.to_string_lossy().to_string())
        .ok_or_else(|| "no user data directory for this OS".into())
}

#[tauri::command]
fn ootb_reveal_user_data_folder() -> Result<(), String> {
    ootb::reveal_user_data_dir()
}

#[tauri::command]
fn set_main_window_title(app: tauri::AppHandle, title: String) -> Result<(), String> {
    let title = title.trim();
    if title.is_empty() {
        return Err("title is empty".into());
    }
    let Some(w) = app.get_webview_window("main") else {
        return Err("main window not found".into());
    };
    w.set_title(title).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    // A second Dock/CLI launch is discarded; this closure runs on the already-running app so we
    // focus it instead of stacking WebViews (each could auto-spawn another `chump --web`).
    #[cfg(desktop)]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.show();
                let _ = w.set_focus();
            }
        }));
    }

    builder
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
            try_bring_sidecar_online,
            ootb_wizard_should_show,
            ootb_detect_ollama,
            ootb_open_ollama_download,
            ootb_prepare_user_data,
            ootb_pull_model,
            ootb_model_present,
            ootb_default_model,
            ootb_user_data_dir_path,
            ootb_reveal_user_data_folder,
            set_main_window_title
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

    /// Regression: a missing `)` after `chumpApiUrl(...encodeURIComponent(a.file_id)` is a **syntax
    /// error** that prevents the entire inline script from parsing — WebView shows UI but no clicks
    /// or keyboard handlers run.
    #[test]
    fn web_index_attachment_chip_url_calls_chump_api_url_closed() {
        let index = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../web/index.html");
        let s = std::fs::read_to_string(&index)
            .unwrap_or_else(|e| panic!("read {}: {e}", index.display()));
        let buggy = "chumpApiUrl('/api/files/' + encodeURIComponent(a.file_id);";
        assert!(
            !s.contains(buggy),
            "web/index.html must not contain unclosed chumpApiUrl( (breaks whole Cowork shell JS)"
        );
    }

    #[test]
    fn web_index_loads_sse_event_parser_before_bundle() {
        let index = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../web/index.html");
        let s = std::fs::read_to_string(&index)
            .unwrap_or_else(|e| panic!("read {}: {e}", index.display()));
        assert!(
            s.contains("src=\"/sse-event-parser.js\""),
            "Cowork must load /sse-event-parser.js before the inline bundle (chat SSE)"
        );
        assert!(
            s.contains("src=\"/ui-selftests.js\""),
            "Cowork must load /ui-selftests.js for Settings + /selftest diagnostics"
        );
        assert!(
            s.contains("src=\"/ootb-wizard.js\""),
            "Cowork must load /ootb-wizard.js for first-run OOTB wizard (Tauri)"
        );
        assert!(
            s.contains("id=\"ootb-wizard\""),
            "index.html must include OOTB wizard root element"
        );
    }
}
