//! Out-of-the-box setup: Application Support (or XDG/APPDATA) `.env`, Ollama detection, model pull.

use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

/// Default model for first-time download (smaller than 14b for faster OOTB).
pub const DEFAULT_OLLAMA_MODEL: &str = "qwen2.5:7b";

/// `PATH` prefix so GUI-launched processes find Homebrew Ollama.
pub fn enriched_path() -> String {
    let base = std::env::var("PATH").unwrap_or_default();
    let prefix = if cfg!(target_os = "macos") {
        "/opt/homebrew/bin:/usr/local/bin"
    } else if cfg!(target_os = "windows") {
        ""
    } else {
        "/usr/local/bin:/usr/bin"
    };
    if prefix.is_empty() {
        base
    } else {
        format!("{prefix}:{base}")
    }
}

/// Cross-platform Chump user data directory (no trailing slash).
pub fn chump_user_data_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME").ok()?;
        return Some(PathBuf::from(home).join("Library/Application Support/Chump"));
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let base = std::env::var("XDG_DATA_HOME").unwrap_or_else(|_| {
            format!(
                "{}/.local/share",
                std::env::var("HOME").unwrap_or_else(|_| String::from("."))
            )
        });
        return Some(PathBuf::from(base).join("chump"));
    }
    #[cfg(target_os = "windows")]
    {
        let app = std::env::var("APPDATA").ok()?;
        return Some(PathBuf::from(app).join("Chump"));
    }
    #[allow(unreachable_code)]
    None
}

fn env_file_from_chump_home_or_repo() -> Option<PathBuf> {
    for key in ["CHUMP_HOME", "CHUMP_REPO"] {
        if let Ok(p) = std::env::var(key) {
            let pb = PathBuf::from(p.trim());
            let ef = pb.join(".env");
            if ef.is_file() {
                return Some(ef);
            }
        }
    }
    None
}

fn walk_exe_parents_for_dotenv() -> Option<PathBuf> {
    let mut dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    for _ in 0..14 {
        let envf = dir.join(".env");
        let cargo = dir.join("Cargo.toml");
        if envf.is_file() && cargo.is_file() {
            return Some(envf);
        }
        dir = dir.parent()?.to_path_buf();
    }
    None
}

fn macos_projects_chump_env() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME").ok()?;
        let guess = PathBuf::from(home).join("Projects/Chump/.env");
        if guess.is_file() {
            return Some(guess);
        }
    }
    #[cfg(not(target_os = "macos"))]
    {}
    None
}

/// True when the user already has a developer-style `.env` (repo or explicit env) — skip first-run wizard.
pub fn wizard_should_show() -> bool {
    if env_file_from_chump_home_or_repo().is_some() {
        return false;
    }
    if walk_exe_parents_for_dotenv().is_some() {
        return false;
    }
    if macos_projects_chump_env().is_some() {
        return false;
    }
    let Some(ud) = chump_user_data_dir() else {
        return false;
    };
    !ud.join(".env").is_file()
}

/// Sidecar `current_dir`: user data when `.env` exists there (OOTB install).
pub fn user_data_dotenv_dir() -> Option<PathBuf> {
    let ud = chump_user_data_dir()?;
    let ef = ud.join(".env");
    if ef.is_file() {
        Some(ud)
    } else {
        None
    }
}

/// Normalize optional OpenAI-compatible base URL (no trailing slash).
pub fn sanitize_openai_api_base(raw: Option<String>) -> Result<Option<String>, String> {
    let Some(s) = raw else {
        return Ok(None);
    };
    let t = s.trim();
    if t.is_empty() {
        return Ok(None);
    }
    if !t.starts_with("http://") && !t.starts_with("https://") {
        return Err("API base must start with http:// or https://".into());
    }
    Ok(Some(t.trim_end_matches('/').to_string()))
}

pub fn default_env_file_body(chump_home: &Path, model: &str, openai_api_base: Option<&str>) -> String {
    let home = chump_home.to_string_lossy();
    let base = openai_api_base.unwrap_or("http://127.0.0.1:11434/v1");
    format!(
        r#"# Chump — created by first-run setup (Cowork desktop)
CHUMP_HOME={home}
OPENAI_API_BASE={base}
OPENAI_API_KEY=ollama
OPENAI_MODEL={model}
# Web-only OOTB: leave Discord unset
DISCORD_TOKEN=
"#
    )
}

/// Create `sessions` and write `.env` if missing. Returns absolute user data path.
pub fn ensure_user_data_and_env(model: &str, openai_api_base: Option<String>) -> Result<PathBuf, String> {
    let api_base = sanitize_openai_api_base(openai_api_base)?;
    let dir =
        chump_user_data_dir().ok_or_else(|| "no user data directory for this OS".to_string())?;
    std::fs::create_dir_all(dir.join("sessions")).map_err(|e| format!("create sessions: {e}"))?;
    let env_path = dir.join(".env");
    if env_path.is_file() {
        return Ok(dir);
    }
    let body = default_env_file_body(&dir, model, api_base.as_deref());
    std::fs::write(&env_path, body).map_err(|e| format!("write .env: {e}"))?;
    Ok(dir)
}

/// Run `ollama version`; returns JSON `{ installed, version, error? }`.
pub async fn detect_ollama() -> serde_json::Value {
    let mut cmd = Command::new("ollama");
    cmd.arg("version");
    cmd.env("PATH", enriched_path());
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let out = match cmd.output().await {
        Ok(o) => o,
        Err(e) => {
            return json!({
                "installed": false,
                "version": serde_json::Value::Null,
                "error": format!("spawn ollama: {e}"),
            });
        }
    };
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return json!({
            "installed": false,
            "version": serde_json::Value::Null,
            "error": if err.is_empty() { "ollama returned non-zero".into() } else { err },
        });
    }
    let ver = String::from_utf8_lossy(&out.stdout).trim().to_string();
    json!({
        "installed": true,
        "version": ver,
        "error": serde_json::Value::Null,
    })
}

/// Parse `ollama list` first column for tag names (e.g. `qwen2.5:7b`).
pub async fn ollama_has_model(model: &str) -> bool {
    let mut cmd = Command::new("ollama");
    cmd.args(["list"]);
    cmd.env("PATH", enriched_path());
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::null());
    let out = match cmd.output().await {
        Ok(o) if o.status.success() => o,
        _ => return false,
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let needle = model.trim();
    for line in text.lines().skip(1) {
        let first = line.split_whitespace().next().unwrap_or("");
        if first == needle {
            return true;
        }
    }
    false
}

pub fn open_ollama_download_page() -> Result<(), String> {
    let url = "https://ollama.com/download";
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(url)
            .status()
            .map_err(|e| e.to_string())?;
        Ok(())
    }
    #[cfg(target_os = "linux")]
    {
        for bin in ["xdg-open", "gio"] {
            if std::process::Command::new(bin)
                .arg(url)
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
            {
                return Ok(());
            }
        }
        return Err("could not open browser (xdg-open)".into());
    }
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/C", "start", "", url])
            .status()
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        Err("open URL not implemented for this OS".into())
    }
}

async fn forward_pull_lines<R>(reader: R, on_line: Arc<dyn Fn(String) + Send + Sync>)
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        on_line(line);
    }
}

/// Run `ollama pull` (may take several minutes). Streams each stdout/stderr line through `on_line`.
pub async fn ollama_pull_with_lines(
    model: String,
    on_line: Arc<dyn Fn(String) + Send + Sync>,
) -> Result<String, String> {
    let m = model.clone();
    let mut cmd = Command::new("ollama");
    cmd.args(["pull", &model]);
    cmd.env("PATH", enriched_path());
    cmd.kill_on_drop(true);
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("spawn ollama pull: {e}"))?;
    let stdout = child.stdout.take().ok_or("ollama pull: no stdout")?;
    let stderr = child.stderr.take().ok_or("ollama pull: no stderr")?;
    let o1 = on_line.clone();
    let o2 = on_line.clone();
    let h1 = tokio::spawn(forward_pull_lines(stdout, o1));
    let h2 = tokio::spawn(forward_pull_lines(stderr, o2));
    let status = child
        .wait()
        .await
        .map_err(|e| format!("ollama pull wait: {e}"))?;
    let _ = h1.await;
    let _ = h2.await;
    if !status.success() {
        return Err(format!(
            "ollama pull {m} failed (exit {:?})",
            status.code()
        ));
    }
    Ok(format!("Finished pulling {m}."))
}

/// Open `path` in the OS file manager (Finder, Explorer, xdg-open).
pub fn reveal_path_in_shell(path: &Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(path)
            .status()
            .map_err(|e| format!("open: {e}"))?;
        return Ok(());
    }
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(path)
            .status()
            .map_err(|e| format!("explorer: {e}"))?;
        return Ok(());
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let s = std::process::Command::new("xdg-open")
            .arg(path)
            .status()
            .map_err(|e| format!("xdg-open: {e}"))?;
        if !s.success() {
            return Err("xdg-open exited with an error".into());
        }
        return Ok(());
    }
    #[allow(unreachable_code)]
    Err("reveal folder is not supported on this platform".into())
}

/// Open the Chump user data directory (must already exist on disk).
pub fn reveal_user_data_dir() -> Result<(), String> {
    let dir = chump_user_data_dir().ok_or_else(|| "no user data directory for this OS".to_string())?;
    if !dir.is_dir() {
        return Err("folder does not exist yet — use “Create config” first".into());
    }
    reveal_path_in_shell(&dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_env_contains_ollama_base() {
        let p = PathBuf::from("/tmp/ChumpTest");
        let s = default_env_file_body(&p, "qwen2.5:7b", None);
        assert!(s.contains("OPENAI_API_BASE=http://127.0.0.1:11434/v1"));
        assert!(s.contains("OPENAI_MODEL=qwen2.5:7b"));
        assert!(s.contains("CHUMP_HOME="));
    }

    #[test]
    fn default_env_custom_api_base() {
        let p = PathBuf::from("/tmp/ChumpTest");
        let s = default_env_file_body(&p, "mistral", Some("http://127.0.0.1:8001/v1"));
        assert!(s.contains("OPENAI_API_BASE=http://127.0.0.1:8001/v1"));
        assert!(s.contains("OPENAI_MODEL=mistral"));
    }

    #[test]
    fn sanitize_api_base_rejects_non_http() {
        assert!(sanitize_openai_api_base(Some("ftp://x".into())).is_err());
        assert_eq!(
            sanitize_openai_api_base(Some("  https://api.example/v1  ".into()))
                .unwrap()
                .as_deref(),
            Some("https://api.example/v1")
        );
    }
}
