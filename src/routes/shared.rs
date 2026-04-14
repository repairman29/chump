//! Shared helpers for web route handlers.

use axum::http::HeaderMap;
use std::path::PathBuf;

use crate::repo_path;

pub fn check_auth(headers: &HeaderMap) -> bool {
    let required = match std::env::var("CHUMP_WEB_TOKEN") {
        Ok(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => return true,
    };
    headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|t| t.trim() == required)
        .unwrap_or(false)
}

pub fn pwa_static_dir() -> PathBuf {
    std::env::var("CHUMP_WEB_STATIC_DIR")
        .ok()
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| repo_path::runtime_base().join("web"))
}
