//! `chump init` — first-run wizard (INFRA-597) + UX-001 web-server flow.
//!
//! Running `chump init` on a clean machine:
//!   (a) checks brew tap repairman29/chump is installed
//!   (b) writes ~/.chump/config.toml (API key + offline-LLM base URL)
//!   (c) prompts for FLEET_MODEL preference (sonnet/haiku/opus)
//!   (d) verifies binary freshness (INFRA-148 staleness check)
//!   (e) writes ~/.chump/state.db scaffold
//!   (f) emits next-step hint
//!
//! Idempotent: safe to re-run. Skips steps that are already done.
//! Pass --no-interactive to skip stdin prompts (for CI / test-chump-init-clean-machine.sh).

use anyhow::{anyhow, Result};
use std::io::{self, Write as IoWrite};
use std::path::{Path, PathBuf};
use std::time::Duration;

// ────────────────────────── public entry point ──────────────────────────

/// CLI arguments for `chump init`.
///
/// Construct via `InitArgs::from_argv()` for CLI parsing, or `InitArgs::default()`
/// for env-only defaults (`CHUMP_WEB_PORT` env var or 3000; browser opens).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InitArgs {
    pub port: u16,
    pub open_browser: bool,
    /// Skip stdin prompts; derive choices from env vars only (for CI/tests).
    pub no_interactive: bool,
}

impl Default for InitArgs {
    fn default() -> Self {
        let port = std::env::var("CHUMP_WEB_PORT")
            .ok()
            .and_then(|p| p.parse::<u16>().ok())
            .unwrap_or(3000);
        Self {
            port,
            open_browser: true,
            no_interactive: false,
        }
    }
}

impl InitArgs {
    /// Parse argv tail (everything after `chump init`).
    ///
    /// Recognized flags:
    /// - `--port N` — bind the web server to port N (overrides `CHUMP_WEB_PORT`)
    /// - `--no-browser` — skip the browser-open step (for CI / automation)
    /// - `--no-interactive` — skip stdin prompts; use env-var defaults only
    ///
    /// Returns `Err` for unknown flags or missing values.
    pub fn from_argv(argv: &[String]) -> Result<Self> {
        let mut out = Self::default();
        let mut i = 0;
        while i < argv.len() {
            match argv[i].as_str() {
                "--port" => {
                    let raw = argv
                        .get(i + 1)
                        .ok_or_else(|| anyhow!("--port requires a value"))?;
                    out.port = raw
                        .parse::<u16>()
                        .map_err(|e| anyhow!("--port: invalid u16 {raw:?}: {e}"))?;
                    i += 2;
                }
                "--no-browser" => {
                    out.open_browser = false;
                    i += 1;
                }
                "--no-interactive" => {
                    out.no_interactive = true;
                    i += 1;
                }
                "--help" | "-h" => {
                    println!("Usage: chump init [--port N] [--no-browser] [--no-interactive]");
                    std::process::exit(0);
                }
                other => return Err(anyhow!("chump init: unknown flag {other:?}")),
            }
        }
        Ok(out)
    }
}

pub fn run_init(repo_root: &Path, args: &InitArgs) -> Result<()> {
    println!("chump init — first-run wizard");
    println!();

    // PRODUCT-015: emit kind=activation_install on the first successful init.
    crate::activation::emit_install();

    // (a) brew tap check
    let tap_ok = check_brew_tap("repairman29/chump");
    if tap_ok {
        println!("  [a] brew tap repairman29/chump ... ok");
    } else {
        println!("  [a] brew tap repairman29/chump ... NOT installed");
        println!("      Fix: brew tap repairman29/chump && brew install chump");
    }

    // (b+c) ~/.chump/config.toml — API key + offline-LLM base + FLEET_MODEL
    let chump_home = chump_home_dir();
    std::fs::create_dir_all(&chump_home)
        .map_err(|e| anyhow!("cannot create {}: {e}", chump_home.display()))?;

    let config_path = chump_home.join("config.toml");
    if config_path.exists() {
        println!("  [b] ~/.chump/config.toml already exists — skipping write");
        println!("  [c] FLEET_MODEL — using value in config.toml");
    } else {
        let fleet_model = resolve_fleet_model(args.no_interactive)?;
        let (api_key, openai_base) = resolve_api_config(args.no_interactive)?;
        write_config_toml(&config_path, &api_key, &openai_base, &fleet_model)?;
        println!("  [b] wrote ~/.chump/config.toml");
        println!("  [c] FLEET_MODEL={fleet_model}");
    }

    // (d) binary freshness (INFRA-148)
    match crate::version::check_gap_binary_staleness(repo_root) {
        crate::version::StalenessCheck::Fresh => {
            println!(
                "  [d] binary freshness ... ok ({})",
                crate::version::chump_build_sha()
            );
        }
        crate::version::StalenessCheck::Skip => {
            println!("  [d] binary freshness ... skipped (no git or unknown SHA)");
        }
        crate::version::StalenessCheck::Stale {
            commits_ahead,
            latest_subject,
        } => {
            println!("  [d] binary freshness ... STALE ({commits_ahead} commit(s) behind HEAD)");
            println!("      Latest: {latest_subject}");
            println!("      Fix: brew upgrade chump  (or cargo install --path .)");
        }
    }

    // (e) ~/.chump/state.db scaffold
    let db_path = chump_home.join("state.db");
    if db_path.exists() {
        println!("  [e] ~/.chump/state.db already exists — skipping scaffold");
    } else {
        write_state_db_scaffold(&db_path)?;
        println!("  [e] wrote ~/.chump/state.db scaffold");
    }

    // UX-001: detect model, write .env (repo-local), start server, open browser
    let model_cfg = detect_model();
    println!("  [*] model detection ... {}", model_cfg.summary());
    if model_cfg.source.contains("Ollama") {
        let models = fetch_ollama_models("http://localhost:11434/v1/models");
        if !models.is_empty() {
            println!("         Available models:");
            for m in &models {
                println!("           - {m}");
            }
        }
    }

    let env_path = repo_root.join(".env");
    if env_path.exists() {
        println!("  [*] .env already exists — skipping write");
    } else {
        write_minimal_env(&env_path, &model_cfg, args.port)?;
        println!("  [*] wrote {}", env_path.display());
    }

    if server_is_healthy(args.port) {
        println!("  [*] server already running on port {}", args.port);
    } else {
        start_server(repo_root, args.port)?;
        println!("  [*] server started on port {}", args.port);
    }

    let url = format!("http://localhost:{}/v2/", args.port);
    if args.open_browser {
        println!("  [*] opening {}", url);
        open_browser(&url);
    } else {
        println!("  [*] browser open skipped (--no-browser); navigate to {url}");
    }

    // (f) next-step hint
    println!();
    println!("  chump init complete — try:");
    println!("    chump gen \"summarize my last 5 commits\"");
    println!("    chump fleet start");
    println!();

    if !model_cfg.has_model() {
        if model_cfg.source.contains("Ollama") {
            println!("  Ollama is running but no models are pulled.");
            println!("    Pull a model: ollama pull qwen2.5:7b");
        } else {
            println!("  No local model detected. Install Ollama and pull a model:");
            println!("    brew install ollama && ollama pull qwen2.5:7b");
        }
        println!("  Then re-run: chump init");
    }
    Ok(())
}

// ────────────────────────── (a) brew tap check ──────────────────────────

fn check_brew_tap(tap: &str) -> bool {
    // `brew tap` lists installed taps; grep for the target.
    let out = std::process::Command::new("brew").args(["tap"]).output();
    match out {
        Ok(o) if o.status.success() => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            stdout.lines().any(|l| l.trim() == tap)
        }
        _ => false,
    }
}

// ────────────────────────── (b+c) config.toml ──────────────────────────

fn chump_home_dir() -> PathBuf {
    // Respect CHUMP_HOME override (used by tests).
    if let Ok(h) = std::env::var("CHUMP_HOME") {
        return PathBuf::from(h);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".chump")
}

fn resolve_api_config(no_interactive: bool) -> Result<(String, String)> {
    // Prefer env vars first (CI / non-interactive).
    let api_key = std::env::var("ANTHROPIC_API_KEY").unwrap_or_default();
    let openai_base = std::env::var("OPENAI_API_BASE").unwrap_or_default();

    if !api_key.is_empty() || !openai_base.is_empty() || no_interactive {
        return Ok((api_key, openai_base));
    }

    // Interactive: ask the user.
    println!();
    println!("  Configure API access (press Enter to skip a field):");
    let api_key = prompt("    ANTHROPIC_API_KEY: ")?;
    let openai_base = if api_key.is_empty() {
        prompt("    OPENAI_API_BASE (for offline/local LLM, e.g. http://localhost:11434/v1): ")?
    } else {
        String::new()
    };
    println!();
    Ok((api_key, openai_base))
}

fn resolve_fleet_model(no_interactive: bool) -> Result<String> {
    if let Ok(m) = std::env::var("FLEET_MODEL") {
        if !m.is_empty() {
            return Ok(m);
        }
    }
    if no_interactive {
        return Ok("haiku".to_string());
    }
    println!();
    println!("  FLEET_MODEL preference:");
    println!("    1) haiku  — fast, cost-efficient (default for IDE sessions)");
    println!("    2) sonnet — balanced (default for fleet workers)");
    println!("    3) opus   — highest quality (~50x haiku cost)");
    let choice = prompt("  Choose [1/2/3, default=2]: ")?;
    let model = match choice.trim() {
        "1" => "haiku",
        "3" => "opus",
        _ => "sonnet",
    };
    println!();
    Ok(model.to_string())
}

fn write_config_toml(
    path: &Path,
    api_key: &str,
    openai_base: &str,
    fleet_model: &str,
) -> Result<()> {
    let mut lines = vec![
        "# ~/.chump/config.toml — generated by chump init".to_string(),
        "# Edit freely. Re-run 'chump init' only overwrites if this file is absent.".to_string(),
        String::new(),
        format!("fleet_model = {:?}", fleet_model),
        String::new(),
        "[api]".to_string(),
    ];

    if !api_key.is_empty() {
        lines.push(format!("anthropic_api_key = {:?}", api_key));
    } else {
        lines.push("# anthropic_api_key = \"sk-ant-...\"".to_string());
    }

    if !openai_base.is_empty() {
        lines.push(format!("openai_api_base = {:?}", openai_base));
    } else {
        lines.push(
            "# openai_api_base = \"http://localhost:11434/v1\"  # for offline/local LLM"
                .to_string(),
        );
    }

    std::fs::write(path, lines.join("\n") + "\n")?;
    Ok(())
}

fn prompt(label: &str) -> Result<String> {
    print!("{label}");
    io::stdout().flush()?;
    let mut buf = String::new();
    io::stdin().read_line(&mut buf)?;
    Ok(buf.trim().to_string())
}

// ────────────────────────── (e) state.db scaffold ──────────────────────────

pub fn write_state_db_scaffold(path: &Path) -> Result<()> {
    // Minimal SQLite scaffold so `chump gap list` works immediately on a clean machine.
    let conn = rusqlite::Connection::open(path)
        .map_err(|e| anyhow!("cannot create {}: {e}", path.display()))?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS gaps (
            id          TEXT PRIMARY KEY,
            domain      TEXT NOT NULL DEFAULT '',
            title       TEXT NOT NULL DEFAULT '',
            status      TEXT NOT NULL DEFAULT 'open',
            priority    TEXT NOT NULL DEFAULT 'P2',
            effort      TEXT NOT NULL DEFAULT 's',
            kind        TEXT NOT NULL DEFAULT 'feature',
            assignee    TEXT NOT NULL DEFAULT '',
            deps        TEXT NOT NULL DEFAULT '',
            paths       TEXT NOT NULL DEFAULT '',
            created_at  TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
            meta        TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS gap_log (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            gap_id      TEXT NOT NULL,
            event       TEXT NOT NULL,
            ts          TEXT NOT NULL DEFAULT (datetime('now'))
        );",
    )
    .map_err(|e| anyhow!("state.db scaffold failed: {e}"))?;
    Ok(())
}

// ────────────────────────── model detection ──────────────────────────

#[derive(Debug)]
struct ModelConfig {
    api_base: Option<String>,
    api_key: String,
    model: Option<String>,
    source: &'static str,
}

impl ModelConfig {
    fn has_model(&self) -> bool {
        self.model.is_some()
    }

    fn summary(&self) -> String {
        match &self.model {
            Some(m) => format!("found {} via {}", m, self.source),
            None => "no local model found (Anthropic API key or Ollama required)".into(),
        }
    }
}

fn detect_model() -> ModelConfig {
    // 1. Anthropic API key → Claude (no local server needed)
    if let Ok(k) = std::env::var("ANTHROPIC_API_KEY") {
        if !k.is_empty() && !k.starts_with("sk-ant-api0") {
            return ModelConfig {
                api_base: None,
                api_key: k,
                model: Some("claude-haiku-4-5-20251001".into()),
                source: "ANTHROPIC_API_KEY",
            };
        }
    }

    // 2. Ollama on default port
    if probe_url("http://localhost:11434/v1/models") {
        let models = fetch_ollama_models("http://localhost:11434/v1/models");
        let model = models.first().cloned();
        return ModelConfig {
            api_base: Some("http://localhost:11434/v1".into()),
            api_key: "ollama".into(),
            model,
            source: "Ollama (localhost:11434)",
        };
    }

    // 3. vllm-mlx on 8000
    if probe_url("http://localhost:8000/v1/models") {
        return ModelConfig {
            api_base: Some("http://localhost:8000/v1".into()),
            api_key: "vllm-mlx".into(),
            model: Some(
                probe_first_model("http://localhost:8000/v1/models")
                    .unwrap_or_else(|| "local".into()),
            ),
            source: "vllm-mlx (localhost:8000)",
        };
    }

    // 4. vllm-mlx on 8001
    if probe_url("http://localhost:8001/v1/models") {
        return ModelConfig {
            api_base: Some("http://localhost:8001/v1".into()),
            api_key: "vllm-mlx".into(),
            model: Some(
                probe_first_model("http://localhost:8001/v1/models")
                    .unwrap_or_else(|| "local".into()),
            ),
            source: "vllm-mlx (localhost:8001)",
        };
    }

    // 5. OpenAI key in env
    if let Ok(k) = std::env::var("OPENAI_API_KEY") {
        if !k.is_empty() && k != "ollama" {
            return ModelConfig {
                api_base: None,
                api_key: k,
                model: Some("gpt-4o-mini".into()),
                source: "OPENAI_API_KEY",
            };
        }
    }

    ModelConfig {
        api_base: None,
        api_key: String::new(),
        model: None,
        source: "none",
    }
}

fn probe_url(url: &str) -> bool {
    std::process::Command::new("curl")
        .args(["-sf", "--max-time", "2", url, "-o", "/dev/null"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn probe_first_model(url: &str) -> Option<String> {
    let out = std::process::Command::new("curl")
        .args(["-sf", "--max-time", "2", url])
        .output()
        .ok()?;
    let body = String::from_utf8(out.stdout).ok()?;
    let v: serde_json::Value = serde_json::from_str(&body).ok()?;
    v["data"].as_array()?.first()?["id"]
        .as_str()
        .map(String::from)
}

fn fetch_ollama_models(url: &str) -> Vec<String> {
    std::process::Command::new("curl")
        .args(["-sf", "--max-time", "2", url])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|body| serde_json::from_str::<serde_json::Value>(&body).ok())
        .and_then(|v| v["data"].as_array().cloned())
        .map(|arr| {
            arr.iter()
                .filter_map(|item| item["id"].as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

// ────────────────────────── .env writer ──────────────────────────

fn write_minimal_env(env_path: &Path, cfg: &ModelConfig, port: u16) -> Result<()> {
    let mut lines = vec![
        "# Generated by chump init".to_string(),
        "# Edit to add DISCORD_TOKEN, ANTHROPIC_API_KEY, etc.".to_string(),
        String::new(),
        format!("CHUMP_WEB_PORT={}", port),
    ];

    if let Some(base) = &cfg.api_base {
        lines.push(format!("OPENAI_API_BASE={}", base));
        lines.push(format!("OPENAI_API_KEY={}", cfg.api_key));
    }
    if let Some(model) = &cfg.model {
        lines.push(format!("OPENAI_MODEL={}", model));
    }

    lines.push(String::new());
    lines.push("# Uncomment to add Anthropic direct API:".to_string());
    lines.push("# ANTHROPIC_API_KEY=sk-ant-...".to_string());
    lines.push(String::new());
    lines.push("# Uncomment to enable Discord:".to_string());
    lines.push("# DISCORD_TOKEN=your-bot-token-here".to_string());

    std::fs::write(env_path, lines.join("\n") + "\n")?;
    Ok(())
}

// ────────────────────────── server lifecycle ──────────────────────────

fn server_is_healthy(port: u16) -> bool {
    probe_url(&format!("http://localhost:{}/health", port))
}

fn start_server(repo_root: &Path, port: u16) -> Result<()> {
    let exe = std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("chump"));

    let child = std::process::Command::new(&exe)
        .arg("--web")
        .arg("--port")
        .arg(port.to_string())
        .current_dir(repo_root)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();

    match child {
        Ok(_) => {}
        Err(e) => {
            eprintln!("  [*] could not spawn server: {e}");
            eprintln!("      Start manually: chump --web --port {}", port);
            return Ok(());
        }
    }

    print!("         waiting for server");
    for i in 0..15 {
        std::thread::sleep(Duration::from_secs(1));
        if server_is_healthy(port) {
            println!(" ready ({i}s)");
            return Ok(());
        }
        print!(".");
    }
    println!(" timeout — server may still be starting");
    Ok(())
}

// ────────────────────────── browser launcher ──────────────────────────

fn open_browser(url: &str) {
    let result = if cfg!(target_os = "macos") {
        std::process::Command::new("open").arg(url).spawn()
    } else if cfg!(target_os = "linux") {
        std::process::Command::new("xdg-open").arg(url).spawn()
    } else if cfg!(target_os = "windows") {
        std::process::Command::new("cmd")
            .args(["/c", "start", url])
            .spawn()
    } else {
        eprintln!(
            "  [*] cannot open browser on this platform — navigate to: {}",
            url
        );
        return;
    };
    if let Err(e) = result {
        eprintln!("  [*] could not open browser ({}): navigate to {}", e, url);
    }
}

// ────────────────────────── tests ──────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn from_argv_empty_uses_defaults() {
        let prev = std::env::var("CHUMP_WEB_PORT").ok();
        std::env::remove_var("CHUMP_WEB_PORT");
        let args = InitArgs::from_argv(&[]).unwrap();
        assert_eq!(args.port, 3000);
        assert!(args.open_browser);
        assert!(!args.no_interactive);
        if let Some(p) = prev {
            std::env::set_var("CHUMP_WEB_PORT", p);
        }
    }

    #[test]
    fn from_argv_port_flag_parses() {
        let argv: Vec<String> = vec!["--port".into(), "3001".into()];
        let args = InitArgs::from_argv(&argv).unwrap();
        assert_eq!(args.port, 3001);
        assert!(args.open_browser);
    }

    #[test]
    fn from_argv_no_browser_flag_works() {
        let argv: Vec<String> = vec!["--no-browser".into()];
        let args = InitArgs::from_argv(&argv).unwrap();
        assert!(!args.open_browser);
    }

    #[test]
    fn from_argv_no_interactive_flag_works() {
        let argv: Vec<String> = vec!["--no-interactive".into()];
        let args = InitArgs::from_argv(&argv).unwrap();
        assert!(args.no_interactive);
    }

    #[test]
    fn from_argv_combined_flags() {
        let argv: Vec<String> = vec![
            "--port".into(),
            "4001".into(),
            "--no-browser".into(),
            "--no-interactive".into(),
        ];
        let args = InitArgs::from_argv(&argv).unwrap();
        assert_eq!(args.port, 4001);
        assert!(!args.open_browser);
        assert!(args.no_interactive);
    }

    #[test]
    fn from_argv_unknown_flag_errors() {
        let argv: Vec<String> = vec!["--bogus".into()];
        let err = InitArgs::from_argv(&argv).unwrap_err();
        assert!(err.to_string().contains("--bogus"));
    }

    #[test]
    fn from_argv_port_missing_value_errors() {
        let argv: Vec<String> = vec!["--port".into()];
        let err = InitArgs::from_argv(&argv).unwrap_err();
        assert!(err.to_string().contains("--port"));
    }

    #[test]
    fn from_argv_port_invalid_value_errors() {
        let argv: Vec<String> = vec!["--port".into(), "notanumber".into()];
        let err = InitArgs::from_argv(&argv).unwrap_err();
        assert!(err.to_string().contains("--port"));
    }

    #[test]
    fn write_minimal_env_uses_supplied_port() {
        let tmp = std::env::temp_dir().join(format!("chump_init_env_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let env_path = tmp.join(".env");
        let cfg = ModelConfig {
            api_base: Some("http://localhost:11434/v1".into()),
            api_key: "ollama".into(),
            model: Some("qwen2.5:7b".into()),
            source: "Ollama (localhost:11434)",
        };
        write_minimal_env(&env_path, &cfg, 4173).unwrap();
        let written = std::fs::read_to_string(&env_path).unwrap();
        assert!(
            written.contains("CHUMP_WEB_PORT=4173"),
            "expected CHUMP_WEB_PORT=4173 in:\n{written}"
        );
        assert!(
            !written.contains("CHUMP_WEB_PORT=3000"),
            "stale hard-coded 3000 leaked through:\n{written}"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn write_config_toml_anthropic_key() {
        let tmp = std::env::temp_dir().join(format!("chump_init_toml_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let p = tmp.join("config.toml");
        write_config_toml(&p, "sk-ant-test", "", "sonnet").unwrap();
        let s = std::fs::read_to_string(&p).unwrap();
        assert!(
            s.contains("fleet_model = \"sonnet\""),
            "fleet_model missing:\n{s}"
        );
        assert!(
            s.contains("anthropic_api_key = \"sk-ant-test\""),
            "api key missing:\n{s}"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn write_config_toml_openai_base() {
        let tmp =
            std::env::temp_dir().join(format!("chump_init_toml_oai_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let p = tmp.join("config.toml");
        write_config_toml(&p, "", "http://localhost:11434/v1", "haiku").unwrap();
        let s = std::fs::read_to_string(&p).unwrap();
        assert!(
            s.contains("fleet_model = \"haiku\""),
            "fleet_model missing:\n{s}"
        );
        assert!(
            s.contains("openai_api_base = \"http://localhost:11434/v1\""),
            "openai_base missing:\n{s}"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn write_state_db_scaffold_creates_tables() {
        let tmp = std::env::temp_dir().join(format!("chump_init_db_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let p = tmp.join("state.db");
        write_state_db_scaffold(&p).unwrap();
        assert!(p.exists(), "state.db not created");
        let conn = rusqlite::Connection::open(&p).unwrap();
        let tables: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT name FROM sqlite_master WHERE type='table'")
                .unwrap();
            stmt.query_map([], |r| r.get(0))
                .unwrap()
                .filter_map(|r| r.ok())
                .collect()
        };
        assert!(
            tables.contains(&"gaps".to_string()),
            "gaps table missing: {tables:?}"
        );
        assert!(
            tables.contains(&"gap_log".to_string()),
            "gap_log table missing: {tables:?}"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    // INFRA-825 follow-up: these two tests mutate the FLEET_MODEL env var
    // which is process-global, so running them in parallel races. The
    // failure mode: from_env sets opus, default_no_interactive removes it,
    // both call resolve_fleet_model() and assert distinct values. Cargo's
    // default parallel test runner caused sporadic CI failures on PR #1474.
    // #[serial] forces sequential execution across these env-touching tests.
    #[test]
    #[serial]
    fn resolve_fleet_model_from_env() {
        std::env::set_var("FLEET_MODEL", "opus");
        let m = resolve_fleet_model(true).unwrap();
        assert_eq!(m, "opus");
        std::env::remove_var("FLEET_MODEL");
    }

    #[test]
    #[serial]
    fn resolve_fleet_model_default_no_interactive() {
        std::env::remove_var("FLEET_MODEL");
        let m = resolve_fleet_model(true).unwrap();
        assert_eq!(m, "haiku");
    }
}
