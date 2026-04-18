//! Browser automation — V2 implementation (COMP-005b).
//!
//! V1 scaffold → V2: stateless `navigate` and `screenshot` actions, no new crate deps.
//!
//! ## Navigate
//! Fetches the URL via `reqwest` + `scraper` (already in the dep tree), extracts the
//! `<title>` and the first 500 chars of body text. Suitable for docs, landing pages,
//! and link inspection. For JavaScript-heavy SPAs, the V3 chromiumoxide path is needed.
//!
//! ## Screenshot
//! Shells to `chromium --headless=new --screenshot=<path> <url>` (falls back to
//! `google-chrome`, `google-chrome-stable`, `chromium-browser`). Writes a PNG to
//! `chump-brain/screenshots/<hex-hash>.png`. Returns the file path on success.
//! No screenshot if no Chromium binary is found; returns a clear error.
//!
//! ## Approval gate
//! Controlled by `CHUMP_BROWSER_AUTOAPPROVE=1` (permit without asking) or by adding
//! "browser" to `CHUMP_TOOLS_ASK` (approval UI fires before execute). If neither is
//! set, the tool refuses and explains how to enable it.
//!
//! ## V3 roadmap
//! Wire in `chromiumoxide` or `thirtyfour` for session-based CDP (click, fill, JS
//! execution). Set `CHUMP_BROWSER_BACKEND=chromiumoxide` to activate when that crate
//! is added behind the `browser-automation` feature flag.
//!
//! See docs/BROWSER_AUTOMATION.md for the full design.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use scraper::{Html, Selector};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

// ── Stateless helpers (COMP-005b) ────────────────────────────────────────────

const NAVIGATE_PREVIEW_CHARS: usize = 500;

/// Fetch `url`, extract `<title>` and the first [`NAVIGATE_PREVIEW_CHARS`] chars of
/// body text. Uses `reqwest` + `scraper` — no headless browser required.
///
/// Returns a formatted string:
/// ```text
/// title: <page title>
///
/// <first 500 chars of body text>
/// ```
pub async fn simple_navigate(url: &str) -> Result<String> {
    let client = reqwest::Client::builder()
        .user_agent("Chump/1.0 (browser navigate)")
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let resp = client.get(url).send().await?;
    if !resp.status().is_success() {
        return Ok(format!("HTTP {}: {}", resp.status(), resp.url()));
    }
    let html = resp.text().await?;
    let doc = Html::parse_document(&html);

    // Title
    let title = Selector::parse("title")
        .ok()
        .and_then(|s| doc.select(&s).next())
        .map(|el| el.text().collect::<Vec<_>>().join("").trim().to_string())
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| url.to_string());

    // Body text — prefer main content nodes
    let body_text = {
        let mut found = String::new();
        for try_sel in [
            "main",
            "article",
            "[role=\"main\"]",
            ".content",
            "#content",
            "body",
        ] {
            if let Ok(s) = Selector::parse(try_sel) {
                let text: String = doc
                    .select(&s)
                    .flat_map(|el| el.text().collect::<Vec<_>>())
                    .collect::<Vec<_>>()
                    .join(" ");
                let normalized = text.split_whitespace().collect::<Vec<_>>().join(" ");
                if normalized.len() > 80 {
                    found = normalized;
                    break;
                }
            }
        }
        found
    };
    let preview = if body_text.len() > NAVIGATE_PREVIEW_CHARS {
        format!(
            "{}… [{} more chars]",
            &body_text[..NAVIGATE_PREVIEW_CHARS],
            body_text.len() - NAVIGATE_PREVIEW_CHARS
        )
    } else {
        body_text
    };

    Ok(format!("title: {}\n\n{}", title, preview))
}

/// Shell to a headless Chromium binary to take a screenshot of `url`.
/// Writes a PNG to `<out_dir>/<url-hash>.png` and returns the path.
///
/// Tries (in order): `chromium`, `google-chrome`, `google-chrome-stable`,
/// `chromium-browser`. Returns an error if none are found.
pub async fn simple_screenshot(url: &str, out_dir: &Path) -> Result<PathBuf> {
    use std::process::Command;

    // Stable filename derived from URL so repeated calls for the same URL overwrite.
    let hash = format!("{:x}", md5_hex(url.as_bytes()));
    std::fs::create_dir_all(out_dir)?;
    let png_path = out_dir.join(format!("{}.png", &hash[..16]));

    // Find a Chromium binary.
    let bins = [
        "chromium",
        "google-chrome",
        "google-chrome-stable",
        "chromium-browser",
    ];
    let browser_bin = bins
        .iter()
        .find(|b| which_bin(b).is_some())
        .copied()
        .ok_or_else(|| {
            anyhow!(
                "no Chromium binary found (tried: {}). \
                 Install Chromium or Google Chrome to use browser screenshot.",
                bins.join(", ")
            )
        })?;

    let screenshot_arg = format!("--screenshot={}", png_path.display());
    let out = Command::new(browser_bin)
        .args([
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--window-size=1280,800",
            &screenshot_arg,
            url,
        ])
        .output()?;

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(anyhow!(
            "chromium exited {}: {}",
            out.status,
            &stderr[..stderr.len().min(300)]
        ));
    }

    if !png_path.exists() {
        return Err(anyhow!(
            "chromium ran but {} was not created",
            png_path.display()
        ));
    }

    Ok(png_path)
}

/// Tiny inline MD5-like hash for generating stable filenames without adding a dep.
/// NOT cryptographically secure — only used for deterministic short filenames.
fn md5_hex(data: &[u8]) -> u64 {
    // FNV-1a 64-bit: fast, no dep, good enough for filename stability.
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in data {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn which_bin(name: &str) -> Option<()> {
    std::process::Command::new("which")
        .arg(name)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|_| ())
}

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

    // ── simple_navigate unit tests ─────────────────────────────────────────

    #[test]
    fn md5_hex_is_deterministic() {
        let a = md5_hex(b"https://example.com");
        let b = md5_hex(b"https://example.com");
        assert_eq!(a, b);
    }

    #[test]
    fn md5_hex_differs_for_different_inputs() {
        let a = md5_hex(b"https://example.com");
        let b = md5_hex(b"https://other.com");
        assert_ne!(a, b);
    }

    #[test]
    fn which_bin_known_binary() {
        // `ls` should always be available.
        assert!(which_bin("ls").is_some());
    }

    #[test]
    fn which_bin_nonexistent() {
        assert!(which_bin("__chump_nonexistent_binary_xyz__").is_none());
    }

    // ── StubBrowserBackend tests ───────────────────────────────────────────

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
