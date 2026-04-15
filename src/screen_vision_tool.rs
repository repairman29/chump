//! Capture screen (macOS `screencapture` or Android via `adb`) and complete with a vision model.
//! Opt-in: `CHUMP_SCREEN_VISION_ENABLED=1`. Uses OpenAI-style `/v1/chat/completions` with a base64 PNG.
//! Base URL: `CHUMP_VISION_API_BASE` or `OPENAI_API_KEY` host via `OPENAI_API_BASE`. Model: `CHUMP_VISION_MODEL` or `OPENAI_MODEL`.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use base64::Engine;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::process::Command;

/// True when ADB is configured (CHUMP_ADB_ENABLED=1 and CHUMP_ADB_DEVICE set).
fn adb_configured() -> bool {
    let on = std::env::var("CHUMP_ADB_ENABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let device = std::env::var("CHUMP_ADB_DEVICE")
        .unwrap_or_default()
        .trim()
        .to_string();
    on && !device.is_empty()
}

/// True when `CHUMP_SCREEN_VISION_ENABLED=1` or `true`.
pub fn screen_vision_enabled() -> bool {
    std::env::var("CHUMP_SCREEN_VISION_ENABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn vision_model() -> String {
    std::env::var("CHUMP_VISION_MODEL")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("OPENAI_MODEL").ok())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "gpt-4o-mini".to_string())
}

fn api_base_raw() -> String {
    std::env::var("CHUMP_VISION_API_BASE")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("OPENAI_API_BASE").ok())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "http://localhost:11434/v1".to_string())
        .trim_end_matches('/')
        .to_string()
}

fn api_key() -> String {
    std::env::var("OPENAI_API_KEY").unwrap_or_else(|_| "ollama".to_string())
}

fn vision_timeout_secs() -> u64 {
    std::env::var("CHUMP_VISION_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (30..=600).contains(&n))
        .unwrap_or(120)
}

async fn capture_png(source: &str) -> Result<Vec<u8>> {
    match source {
        "adb" => capture_adb().await,
        "mac" | "screencapture" => capture_macos().await,
        "auto" => {
            if adb_configured() {
                capture_adb().await
            } else {
                capture_macos().await
            }
        }
        other => Err(anyhow!("unknown source {:?}; use auto, mac, or adb", other)),
    }
}

async fn capture_adb() -> Result<Vec<u8>> {
    if !adb_configured() {
        return Err(anyhow!(
            "ADB not configured (set CHUMP_ADB_ENABLED=1 and CHUMP_ADB_DEVICE)"
        ));
    }
    let device = std::env::var("CHUMP_ADB_DEVICE").unwrap_or_default();
    let out = tokio::time::timeout(
        Duration::from_secs(45),
        Command::new("adb")
            .args(["-s", &device, "exec-out", "screencap", "-p"])
            .output(),
    )
    .await
    .map_err(|_| anyhow!("adb screencap timed out"))?
    .map_err(|e| anyhow!("adb: {}", e))?;
    if !out.status.success() {
        return Err(anyhow!(
            "adb screencap failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    if out.stdout.len() < 100 {
        return Err(anyhow!("adb screencap returned empty output"));
    }
    Ok(out.stdout)
}

async fn capture_macos() -> Result<Vec<u8>> {
    if !cfg!(target_os = "macos") {
        return Err(anyhow!(
            "screencapture requires macOS; use source=adb or run on a Mac"
        ));
    }
    let path = std::env::temp_dir().join(format!("chump-screenshot-{}.png", uuid::Uuid::new_v4()));
    let status = tokio::time::timeout(
        Duration::from_secs(30),
        Command::new("screencapture")
            .args(["-x", "-t", "png"])
            .arg(&path)
            .status(),
    )
    .await
    .map_err(|_| anyhow!("screencapture timed out"))?
    .map_err(|e| anyhow!("screencapture: {}", e))?;
    if !status.success() {
        return Err(anyhow!("screencapture exited with failure"));
    }
    let bytes = tokio::fs::read(&path).await?;
    let _ = tokio::fs::remove_file(&path).await;
    Ok(bytes)
}

async fn vision_complete(prompt: &str, image_png: &[u8]) -> Result<String> {
    let b64 = base64::engine::general_purpose::STANDARD.encode(image_png);
    let url = format!("{}/chat/completions", api_base_raw());
    let body = json!({
        "model": vision_model(),
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": format!("data:image/png;base64,{}", b64)}}
            ]
        }],
        "max_tokens": 1024,
    });
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(vision_timeout_secs()))
        .build()
        .map_err(|e| anyhow!("http client: {}", e))?;

    let mut req = client.post(&url).json(&body);
    let key = api_key();
    if !key.is_empty() {
        req = req.bearer_auth(key);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| anyhow!("vision request: {}", e))?;
    if !resp.status().is_success() {
        let t = resp.text().await.unwrap_or_default();
        let clip: String = t.chars().take(2000).collect();
        return Err(anyhow!("vision API error: {}", clip));
    }
    let v: Value = resp
        .json()
        .await
        .map_err(|e| anyhow!("vision JSON: {}", e))?;
    v["choices"][0]["message"]["content"]
        .as_str()
        .map(String::from)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("unexpected API response (no choices[0].message.content)"))
}

pub struct ScreenVisionTool;

#[async_trait]
impl Tool for ScreenVisionTool {
    fn name(&self) -> String {
        "screen_vision".to_string()
    }

    fn description(&self) -> String {
        "Capture the screen and ask a vision-capable model about it. macOS: screencapture. Android: ADB when configured. \
         Requires CHUMP_SCREEN_VISION_ENABLED=1 and a model that accepts image_url (set CHUMP_VISION_MODEL or OPENAI_MODEL). \
         Params: prompt (required). Optional source: auto (default), mac, adb."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "prompt": { "type": "string", "description": "What to ask about the screenshot" },
                "source": {
                    "type": "string",
                    "description": "Capture source: auto (ADB if enabled, else Mac), mac, adb",
                    "enum": ["auto", "mac", "adb"]
                }
            },
            "required": ["prompt"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if !screen_vision_enabled() {
            return Err(anyhow!(
                "screen_vision is disabled; set CHUMP_SCREEN_VISION_ENABLED=1"
            ));
        }
        crate::limits::check_tool_input_len(&input).map_err(|e| anyhow!("{}", e))?;

        let prompt = input
            .get("prompt")
            .and_then(|p| p.as_str())
            .unwrap_or("")
            .trim();
        if prompt.is_empty() {
            return Err(anyhow!("prompt is required"));
        }

        let source = input
            .get("source")
            .and_then(|s| s.as_str())
            .unwrap_or("auto")
            .to_lowercase();

        let png = capture_png(&source).await?;
        vision_complete(prompt, &png).await
    }
}
