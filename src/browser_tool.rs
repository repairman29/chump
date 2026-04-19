//! `browser` tool — V2 implementation (COMP-005b).
//!
//! Surfaces a single `browser` tool with a typed `action` field.
//!
//! ## V2 stateless actions (COMP-005b)
//! - `navigate url=<URL>` — returns `title: <T>\n\n<first 500 chars of body>` via reqwest+scraper.
//!   session_id NOT required.
//! - `screenshot url=<URL>` — shells to `chromium --headless=new --screenshot=...` and
//!   writes a PNG to `chump-brain/screenshots/`. session_id NOT required.
//!
//! ## Session-based actions (V3, not yet wired)
//! `open`, `close`, `click`, `fill`, `extract` still route through the stub backend and
//! return a clear scaffold message. V3 will replace the stub with chromiumoxide.
//!
//! ## Approval gate
//! Browser actions can navigate to arbitrary URLs and interact with forms — high risk.
//! Gate: the tool refuses unless EITHER:
//!   a) `CHUMP_BROWSER_AUTOAPPROVE=1` (bypass — no UI needed), OR
//!   b) "browser" is listed in `CHUMP_TOOLS_ASK` (approval UI fired before execute).
//! If neither is set, execute returns a refusal explaining how to enable it.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};
use std::path::Path;

use crate::browser::{get_browser_backend, simple_navigate, simple_screenshot, BrowserAction};

pub struct BrowserTool;

/// Default screenshots directory relative to the repo root.
const SCREENSHOTS_DIR: &str = "chump-brain/screenshots";

/// Check the two-part approval gate:
///   1. `CHUMP_BROWSER_AUTOAPPROVE=1` → permitted.
///   2. "browser" in `CHUMP_TOOLS_ASK` → approval UI already fired upstream → permitted.
///
/// Otherwise returns an Err with instructions.
fn check_approval_gate() -> Result<()> {
    if std::env::var("CHUMP_BROWSER_AUTOAPPROVE")
        .map(|v| v == "1" || v.to_lowercase() == "true")
        .unwrap_or(false)
    {
        return Ok(());
    }
    // Check if "browser" is in CHUMP_TOOLS_ASK (approval was handled upstream by
    // tool_middleware — we're past the gate and safe to proceed).
    let ask_tools = std::env::var("CHUMP_TOOLS_ASK").unwrap_or_default();
    let in_ask = ask_tools
        .split(',')
        .any(|t| t.trim().eq_ignore_ascii_case("browser"));
    if in_ask {
        return Ok(());
    }
    Err(anyhow!(
        "browser actions require explicit approval. \
         Either:\n\
         • Set CHUMP_BROWSER_AUTOAPPROVE=1 to run without per-action approval, OR\n\
         • Add 'browser' to CHUMP_TOOLS_ASK (e.g. CHUMP_TOOLS_ASK=browser) so the\n\
           approval UI fires before each action.\n\
         This gate exists because the browser can navigate arbitrary URLs and submit forms."
    ))
}

const SCAFFOLD_MSG: &str = "session-based browser actions (open/click/fill/extract/close) are not \
     yet wired (V3 work — requires chromiumoxide). \
     Use `navigate` for stateless page reads and `screenshot` for page captures.";

#[async_trait]
impl Tool for BrowserTool {
    fn name(&self) -> String {
        "browser".to_string()
    }

    fn description(&self) -> String {
        "Browser automation tool (COMP-005b). \
         Stateless actions: `navigate url=<URL>` returns page title + first 500 chars of body; \
         `screenshot url=<URL>` takes a headless screenshot and saves to chump-brain/screenshots/. \
         Requires CHUMP_BROWSER_AUTOAPPROVE=1 or 'browser' in CHUMP_TOOLS_ASK. \
         Session-based actions (open/click/fill/extract/close) are V3 scaffolds — not yet wired."
            .to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["open", "navigate", "click", "fill", "screenshot", "extract", "close"],
                    "description": "Browser action to perform."
                },
                "session_id": {
                    "type": "string",
                    "description": "Session identifier returned by `open`. Required for all actions except `open`."
                },
                "url": {
                    "type": "string",
                    "description": "Target URL for `navigate`."
                },
                "selector": {
                    "type": "string",
                    "description": "CSS selector for `click`, `fill`, `extract`."
                },
                "value": {
                    "type": "string",
                    "description": "Value to type for `fill`."
                }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        let action = input
            .get("action")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| anyhow!("action is required"))?;

        // Approval gate — checked before ANY action runs.
        check_approval_gate()?;

        let backend = get_browser_backend();

        match action {
            // ── V2 stateless actions ──────────────────────────────────────────
            "navigate" => {
                // Stateless path: url required, session_id optional.
                let url = require_string(&input, "url")?;
                simple_navigate(&url).await
            }
            "screenshot" => {
                // Stateless path: url required, session_id optional.
                let url = require_string(&input, "url")?;
                let out_dir = Path::new(SCREENSHOTS_DIR);
                match simple_screenshot(&url, out_dir).await {
                    Ok(path) => Ok(format!(
                        "screenshot saved: {}\nURL: {}",
                        path.display(),
                        url
                    )),
                    Err(e) => Ok(format!("screenshot failed: {}", e)),
                }
            }

            // ── V3 scaffolds (session-based CDP — not yet wired) ──────────────
            "open" => match backend.open_session().await {
                Ok(sid) => Ok(format!("session_id={}", sid)),
                Err(_) => Ok(format!("[scaffold] open: {}", SCAFFOLD_MSG)),
            },
            "close" => {
                let sid = require_session(&input)?;
                match backend.close_session(&sid).await {
                    Ok(()) => Ok(format!("closed session {}", sid)),
                    Err(_) => Ok(format!("[scaffold] close: {}", SCAFFOLD_MSG)),
                }
            }
            "click" => {
                let sid = require_session(&input)?;
                let selector = require_string(&input, "selector")?;
                run_action(&*backend, &sid, BrowserAction::Click { selector }).await
            }
            "fill" => {
                let sid = require_session(&input)?;
                let selector = require_string(&input, "selector")?;
                let value = require_string(&input, "value")?;
                run_action(&*backend, &sid, BrowserAction::Fill { selector, value }).await
            }
            "extract" => {
                let sid = require_session(&input)?;
                let selector = require_string(&input, "selector")?;
                run_action(&*backend, &sid, BrowserAction::Extract { selector }).await
            }
            other => Err(anyhow!(
                "unknown browser action: {} (expected navigate|screenshot|open|close|click|fill|extract)",
                other
            )),
        }
    }
}

fn require_session(input: &Value) -> Result<String> {
    require_string(input, "session_id")
}

fn require_string(input: &Value, key: &str) -> Result<String> {
    input
        .get(key)
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("{} is required", key))
}

async fn run_action(
    backend: &dyn crate::browser::BrowserBackend,
    session_id: &str,
    action: BrowserAction,
) -> Result<String> {
    match backend.execute_action(session_id, action).await {
        Ok(page) => Ok(serde_json::to_string(&page)?),
        Err(_) => Ok(format!("[scaffold] {}", SCAFFOLD_MSG)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn name_is_browser() {
        let t = BrowserTool;
        assert_eq!(t.name(), "browser");
    }

    #[test]
    fn schema_has_required_action() {
        let t = BrowserTool;
        let schema = t.input_schema();
        assert_eq!(schema.get("type").and_then(|v| v.as_str()), Some("object"));
        let required = schema
            .get("required")
            .and_then(|v| v.as_array())
            .expect("required array");
        assert!(required.iter().any(|v| v.as_str() == Some("action")));
    }

    // ── Approval gate tests ────────────────────────────────────────────────

    #[tokio::test]
    async fn refuses_without_autoapprove_or_tools_ask() {
        // Ensure neither env var is set in this test (serial isolation not needed —
        // we're testing the default case where neither var is present).
        let t = BrowserTool;
        // Use temp_env crate is unavailable; rely on the vars being absent.
        // If CHUMP_BROWSER_AUTOAPPROVE or CHUMP_TOOLS_ASK=browser happen to be set
        // in the test environment, this test is a no-op. Skip gracefully.
        let autoapprove = std::env::var("CHUMP_BROWSER_AUTOAPPROVE")
            .map(|v| v == "1")
            .unwrap_or(false);
        let ask_has_browser = std::env::var("CHUMP_TOOLS_ASK")
            .map(|v| {
                v.split(',')
                    .any(|t| t.trim().eq_ignore_ascii_case("browser"))
            })
            .unwrap_or(false);
        if autoapprove || ask_has_browser {
            return; // approval already granted in test env — skip
        }
        let err = t
            .execute(json!({ "action": "navigate", "url": "https://example.com" }))
            .await
            .unwrap_err();
        assert!(
            err.to_string().contains("CHUMP_BROWSER_AUTOAPPROVE"),
            "expected approval-gate message, got: {}",
            err
        );
    }

    // ── V2 stateless navigate tests (run with CHUMP_BROWSER_AUTOAPPROVE=1) ──

    #[tokio::test]
    #[serial]
    async fn navigate_requires_url() {
        std::env::set_var("CHUMP_BROWSER_AUTOAPPROVE", "1");
        let t = BrowserTool;
        let err = t
            .execute(json!({ "action": "navigate" }))
            .await
            .unwrap_err();
        std::env::remove_var("CHUMP_BROWSER_AUTOAPPROVE");
        assert!(err.to_string().contains("url"), "got: {}", err);
    }

    #[tokio::test]
    #[serial]
    async fn screenshot_requires_url() {
        std::env::set_var("CHUMP_BROWSER_AUTOAPPROVE", "1");
        let t = BrowserTool;
        let err = t
            .execute(json!({ "action": "screenshot" }))
            .await
            .unwrap_err();
        std::env::remove_var("CHUMP_BROWSER_AUTOAPPROVE");
        assert!(err.to_string().contains("url"), "got: {}", err);
    }

    // ── V3 scaffold tests (session-based CDP — still stub) ─────────────────

    #[tokio::test]
    #[serial]
    async fn open_returns_scaffold_message() {
        std::env::set_var("CHUMP_BROWSER_AUTOAPPROVE", "1");
        let t = BrowserTool;
        let out = t.execute(json!({ "action": "open" })).await.unwrap();
        std::env::remove_var("CHUMP_BROWSER_AUTOAPPROVE");
        assert!(out.contains("scaffold"), "got: {}", out);
    }

    #[tokio::test]
    #[serial]
    async fn click_requires_selector() {
        std::env::set_var("CHUMP_BROWSER_AUTOAPPROVE", "1");
        let t = BrowserTool;
        let err = t
            .execute(json!({ "action": "click", "session_id": "s" }))
            .await
            .unwrap_err();
        std::env::remove_var("CHUMP_BROWSER_AUTOAPPROVE");
        assert!(err.to_string().contains("selector"));
    }

    #[tokio::test]
    #[serial]
    async fn fill_requires_value() {
        std::env::set_var("CHUMP_BROWSER_AUTOAPPROVE", "1");
        let t = BrowserTool;
        let err = t
            .execute(json!({
                "action": "fill",
                "session_id": "s",
                "selector": "input"
            }))
            .await
            .unwrap_err();
        std::env::remove_var("CHUMP_BROWSER_AUTOAPPROVE");
        assert!(err.to_string().contains("value"));
    }

    #[tokio::test]
    async fn unknown_action_errors() {
        std::env::set_var("CHUMP_BROWSER_AUTOAPPROVE", "1");
        let t = BrowserTool;
        let err = t
            .execute(json!({ "action": "teleport" }))
            .await
            .unwrap_err();
        std::env::remove_var("CHUMP_BROWSER_AUTOAPPROVE");
        assert!(err.to_string().contains("unknown browser action"));
    }

    #[tokio::test]
    async fn missing_action_errors() {
        // approval check comes after action-parse, so this fires before gate
        let t = BrowserTool;
        let err = t.execute(json!({})).await.unwrap_err();
        assert!(err.to_string().contains("action is required"));
    }
}
