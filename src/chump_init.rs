//! `chump init` — UX-001 first-run flow.
//!
//! Chains: detect-model → write-.env → start-server → open-browser
//!
//! Idempotent: safe to re-run. Skips steps that are already done (e.g. .env
//! already exists, server already running).

use anyhow::Result;
use std::path::Path;
use std::time::Duration;

// ────────────────────────── public entry point ──────────────────────────

pub fn run_init(repo_root: &Path) -> Result<()> {
    println!("🚀  chump init — first-run setup");
    println!();

    // Step 1: detect model
    let model_cfg = detect_model();
    println!("  [1/4] model detection ... {}", model_cfg.summary());

    // Step 2: write .env (skip if already present)
    let env_path = repo_root.join(".env");
    if env_path.exists() {
        println!("  [2/4] .env already exists — skipping write");
    } else {
        write_minimal_env(&env_path, &model_cfg)?;
        println!("  [2/4] wrote {}", env_path.display());
    }

    // Step 3: ensure server is running (start if not)
    let port = std::env::var("CHUMP_WEB_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(3000);

    if server_is_healthy(port) {
        println!("  [3/4] server already running on port {}", port);
    } else {
        start_server(repo_root, port)?;
        println!("  [3/4] server started on port {}", port);
    }

    // Step 4: open browser
    let url = format!("http://localhost:{}/v2/", port);
    println!("  [4/4] opening {}", url);
    open_browser(&url);

    println!();
    println!("  ✓  Setup complete.");
    println!("     PWA: {}", url);
    if !model_cfg.has_model() {
        println!();
        println!("  ⚠  No local model detected. Install Ollama and pull a model:");
        println!("       brew install ollama && ollama pull qwen2.5:7b");
        println!("     Then re-run: chump init");
    }
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
        return ModelConfig {
            api_base: Some("http://localhost:11434/v1".into()),
            api_key: "ollama".into(),
            model: Some("qwen2.5:7b".into()),
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
    // Parse {"data":[{"id":"<model>"},...]}
    let v: serde_json::Value = serde_json::from_str(&body).ok()?;
    v["data"].as_array()?.first()?["id"]
        .as_str()
        .map(String::from)
}

// ────────────────────────── .env writer ──────────────────────────

fn write_minimal_env(env_path: &Path, cfg: &ModelConfig) -> Result<()> {
    let mut lines = vec![
        "# Generated by chump init".to_string(),
        "# Edit to add DISCORD_TOKEN, ANTHROPIC_API_KEY, etc.".to_string(),
        String::new(),
        format!("CHUMP_WEB_PORT=3000"),
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

    // Start chump --web in the background (detached from this process)
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
            eprintln!("  [3/4] could not spawn server: {e}");
            eprintln!("        Start manually: chump --web --port {}", port);
            return Ok(());
        }
    }

    // Wait up to 15 seconds for the health endpoint to respond
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
            "  [4/4] cannot open browser on this platform — navigate to: {}",
            url
        );
        return;
    };
    if let Err(e) = result {
        eprintln!(
            "  [4/4] could not open browser ({}): navigate to {}",
            e, url
        );
    }
}
