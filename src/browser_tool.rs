//! `browser` tool — V1 scaffold.
//!
//! Surfaces a single `browser` tool with a typed `action` field. In V1, every action
//! returns a clear "not enabled" message so callers can plan around the gap without
//! crashing. V2 will wire this through [`crate::browser::get_browser_backend`].
//!
//! Approval: this tool is intended to live in `CHUMP_TOOLS_ASK` by default — see
//! docs/BROWSER_AUTOMATION.md. Browser sessions can navigate to arbitrary URLs and
//! interact with forms, so each action should require human approval.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

use crate::browser::{get_browser_backend, BrowserAction};

pub struct BrowserTool;

const SCAFFOLD_MSG: &str = "browser tool is a V1 scaffold — actual driver integration is pending. \
     Build with `--features browser-automation` once V2 lands. \
     For static page reads use `read_url` instead.";

#[async_trait]
impl Tool for BrowserTool {
    fn name(&self) -> String {
        "browser".to_string()
    }

    fn description(&self) -> String {
        "Browser automation (V1 scaffold — not yet wired). \
         Actions: open, navigate, click, fill, screenshot, extract, close. \
         All actions currently return a 'not enabled' message — use `read_url` for static content. \
         When V2 lands this will drive a real headless browser via the `browser-automation` feature."
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

        let backend = get_browser_backend();

        match action {
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
            "navigate" => {
                let sid = require_session(&input)?;
                let url = require_string(&input, "url")?;
                run_action(&*backend, &sid, BrowserAction::Navigate { url }).await
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
            "screenshot" => {
                let sid = require_session(&input)?;
                run_action(&*backend, &sid, BrowserAction::Screenshot).await
            }
            "extract" => {
                let sid = require_session(&input)?;
                let selector = require_string(&input, "selector")?;
                run_action(&*backend, &sid, BrowserAction::Extract { selector }).await
            }
            other => Err(anyhow!(
                "unknown browser action: {} (expected open|navigate|click|fill|screenshot|extract|close)",
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

    #[tokio::test]
    async fn open_returns_scaffold_message() {
        let t = BrowserTool;
        let out = t.execute(json!({ "action": "open" })).await.unwrap();
        assert!(out.contains("scaffold"), "got: {}", out);
    }

    #[tokio::test]
    async fn navigate_returns_scaffold_message() {
        let t = BrowserTool;
        let out = t
            .execute(json!({
                "action": "navigate",
                "session_id": "sess-1",
                "url": "https://example.com"
            }))
            .await
            .unwrap();
        assert!(out.contains("scaffold"), "got: {}", out);
    }

    #[tokio::test]
    async fn click_requires_selector() {
        let t = BrowserTool;
        let err = t
            .execute(json!({ "action": "click", "session_id": "s" }))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("selector"));
    }

    #[tokio::test]
    async fn fill_requires_value() {
        let t = BrowserTool;
        let err = t
            .execute(json!({
                "action": "fill",
                "session_id": "s",
                "selector": "input"
            }))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("value"));
    }

    #[tokio::test]
    async fn navigate_requires_session_id() {
        let t = BrowserTool;
        let err = t
            .execute(json!({ "action": "navigate", "url": "https://example.com" }))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("session_id"));
    }

    #[tokio::test]
    async fn unknown_action_errors() {
        let t = BrowserTool;
        let err = t
            .execute(json!({ "action": "teleport" }))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("unknown browser action"));
    }

    #[tokio::test]
    async fn missing_action_errors() {
        let t = BrowserTool;
        let err = t.execute(json!({})).await.unwrap_err();
        assert!(err.to_string().contains("action is required"));
    }
}
