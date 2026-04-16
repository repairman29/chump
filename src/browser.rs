//! Browser automation — V1 scaffold.
//!
//! V1: trait + stub implementation that returns "browser feature not enabled" errors.
//! V2: feature-gated chromiumoxide or thirtyfour integration.
//! V3: support multiple backends (local headless, Browserbase API, Browser Use).
//!
//! Feature flag: `browser-automation` (empty in V1; in V2 will pull in chromiumoxide).
//!
//! See docs/BROWSER_AUTOMATION.md for the full design and roadmap.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// Result of executing a browser action: the resulting page state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BrowserPage {
    pub url: String,
    pub title: String,
    pub content_text: String,
    /// Optional truncated HTML snippet (V2+).
    pub html_snippet: Option<String>,
    /// Optional base64 PNG screenshot (V2+).
    pub screenshot_b64: Option<String>,
}

/// Discrete actions that may be executed against a browser session.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BrowserAction {
    Navigate { url: String },
    Click { selector: String },
    Fill { selector: String, value: String },
    Screenshot,
    Extract { selector: String },
    Close,
}

/// Pluggable browser driver. Implementations may wrap chromiumoxide, thirtyfour,
/// Browserbase, etc. — V1 ships only a stub.
#[async_trait]
pub trait BrowserBackend: Send + Sync {
    /// Stable identifier for the backend (e.g. "stub", "chromiumoxide").
    fn name(&self) -> &'static str;

    /// Open a new browser session and return its session_id.
    async fn open_session(&self) -> Result<String>;

    /// Close a previously opened session.
    async fn close_session(&self, session_id: &str) -> Result<()>;

    /// Execute a single action against an open session.
    async fn execute_action(&self, session_id: &str, action: BrowserAction) -> Result<BrowserPage>;

    /// Whether the backend is usable in the current process. The stub always returns false.
    async fn is_available(&self) -> bool;
}

/// Stub backend — always returns "not enabled" errors.
/// Used when no real browser feature is compiled in.
pub struct StubBrowserBackend;

const STUB_NOT_ENABLED: &str =
    "browser automation not enabled — build with --features browser-automation (V2 work pending)";

#[async_trait]
impl BrowserBackend for StubBrowserBackend {
    fn name(&self) -> &'static str {
        "stub"
    }

    async fn open_session(&self) -> Result<String> {
        Err(anyhow!(STUB_NOT_ENABLED))
    }

    async fn close_session(&self, _session_id: &str) -> Result<()> {
        Err(anyhow!(STUB_NOT_ENABLED))
    }

    async fn execute_action(
        &self,
        _session_id: &str,
        _action: BrowserAction,
    ) -> Result<BrowserPage> {
        Err(anyhow!(STUB_NOT_ENABLED))
    }

    async fn is_available(&self) -> bool {
        false
    }
}

/// Factory that returns the active browser backend.
///
/// V1: always returns [`StubBrowserBackend`].
/// V2: will inspect `CHUMP_BROWSER_BACKEND` (e.g. `chromiumoxide`, `browserbase`) and
/// dispatch accordingly. Unknown values fall back to the stub.
pub fn get_browser_backend() -> Box<dyn BrowserBackend> {
    Box::new(StubBrowserBackend)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_backend_name() {
        let b = StubBrowserBackend;
        assert_eq!(b.name(), "stub");
    }

    #[tokio::test]
    async fn stub_is_unavailable() {
        let b = StubBrowserBackend;
        assert!(!b.is_available().await);
    }

    #[tokio::test]
    async fn stub_open_session_errors() {
        let b = StubBrowserBackend;
        let err = b.open_session().await.unwrap_err();
        assert!(err.to_string().contains("browser automation not enabled"));
    }

    #[tokio::test]
    async fn stub_execute_action_errors() {
        let b = StubBrowserBackend;
        let err = b
            .execute_action("sess-1", BrowserAction::Screenshot)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("browser automation not enabled"));
    }

    #[test]
    fn factory_returns_stub() {
        let backend = get_browser_backend();
        assert_eq!(backend.name(), "stub");
    }

    #[test]
    fn all_action_variants_roundtrip() {
        let actions = vec![
            BrowserAction::Navigate {
                url: "https://example.com".into(),
            },
            BrowserAction::Click {
                selector: "#go".into(),
            },
            BrowserAction::Fill {
                selector: "input[name=q]".into(),
                value: "hello".into(),
            },
            BrowserAction::Screenshot,
            BrowserAction::Extract {
                selector: ".result".into(),
            },
            BrowserAction::Close,
        ];
        for a in actions {
            let s = serde_json::to_string(&a).expect("serialize");
            let _back: BrowserAction = serde_json::from_str(&s).expect("deserialize");
        }
    }

    #[test]
    fn browser_page_roundtrip() {
        let p = BrowserPage {
            url: "https://example.com".into(),
            title: "Example".into(),
            content_text: "hello".into(),
            html_snippet: Some("<p>hi</p>".into()),
            screenshot_b64: None,
        };
        let s = serde_json::to_string(&p).unwrap();
        let back: BrowserPage = serde_json::from_str(&s).unwrap();
        assert_eq!(back.url, p.url);
        assert_eq!(back.title, p.title);
        assert_eq!(back.html_snippet.as_deref(), Some("<p>hi</p>"));
        assert!(back.screenshot_b64.is_none());
    }
}
