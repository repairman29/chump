//! Bulk REST refill for `pr_state` (INFRA-3833).
//!
//! Replaces the Phase 1 `refresh-open-prs` stub (which printed `0` and
//! made no network calls) with a real implementation matching
//! `cache_refresh_open_prs` in `scripts/coord/lib/github_cache.sh`:
//! one REST call to `GET /repos/{owner}/{repo}/pulls?state=open&per_page=100`,
//! written into `pr_state` via [`crate::SqliteCache::upsert_pr`].
//!
//! ## Resolution order
//!
//! - **Repo** (`owner/repo`): explicit `--repo` flag/argument, then
//!   `GH_REPO` / `GITHUB_REPOSITORY` env (same vars the bash helpers and
//!   `gh` itself honor), then `gh repo view --json nameWithOwner`.
//! - **Token**: `GH_TOKEN` / `GITHUB_TOKEN` env (the explicit-credentials
//!   path documented in CLAUDE.md "GitHub credentials for agents"), then
//!   `gh auth token` (implicit keyring path).
//!
//! ## Graceful degradation
//!
//! Any failure — repo unresolved, token unresolved, network error,
//! non-2xx response, undecodable body — logs a `tracing::warn!` and
//! returns `Ok(0)`. This is a deliberate choice, not an oversight: the
//! Phase 1 stub always exited 0, and callsites across the fleet (e.g.
//! `scripts/coord/lib/github_cache.sh::cache_refresh_open_prs`) only
//! check the process exit code. Propagating an `Err` here would turn a
//! "cache stayed as it was" no-op into a hard failure for every caller
//! that has no `gh` auth configured (headless CI runners, sandboxed test
//! environments) — a regression, not a parity fix.

use crate::{CacheError, PrState, SqliteCache};

/// Resolve `owner/repo` (GitHub's "nameWithOwner").
///
/// `override_value` wins if present and non-empty (the CLI's `--repo`
/// flag). Falls through to `GH_REPO` / `GITHUB_REPOSITORY` env, then a
/// `gh repo view` subprocess call. Returns `None` if every path fails —
/// callers treat that as "skip the refill", not an error.
fn resolve_repo_nwo(override_value: Option<&str>) -> Option<String> {
    if let Some(r) = override_value {
        if !r.is_empty() {
            return Some(r.to_string());
        }
    }
    for var in ["GH_REPO", "GITHUB_REPOSITORY"] {
        if let Ok(v) = std::env::var(var) {
            if !v.is_empty() {
                return Some(v);
            }
        }
    }
    let out = std::process::Command::new("gh")
        .args([
            "repo",
            "view",
            "--json",
            "nameWithOwner",
            "-q",
            ".nameWithOwner",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// Resolve a GitHub REST bearer token.
///
/// `GH_TOKEN` / `GITHUB_TOKEN` env first (explicit-credentials mode),
/// then `gh auth token` (implicit keyring mode) — mirrors the two auth
/// modes documented for agent GitHub access.
fn resolve_token() -> Option<String> {
    for var in ["GH_TOKEN", "GITHUB_TOKEN"] {
        if let Ok(v) = std::env::var(var) {
            if !v.is_empty() {
                return Some(v);
            }
        }
    }
    let out = std::process::Command::new("gh")
        .args(["auth", "token"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

#[derive(serde::Deserialize)]
struct RestRef {
    #[serde(rename = "ref")]
    ref_: Option<String>,
    sha: Option<String>,
}

#[derive(serde::Deserialize)]
struct RestUser {
    login: Option<String>,
}

/// Just the fields of `GET /repos/{owner}/{repo}/pulls` we persist.
/// Unknown fields are silently dropped (default serde behavior) so a
/// future GitHub schema addition does not break deserialization.
#[derive(serde::Deserialize)]
struct RestPr {
    number: u64,
    head: Option<RestRef>,
    base: Option<RestRef>,
    mergeable_state: Option<String>,
    #[serde(default)]
    auto_merge: Option<serde_json::Value>,
    #[serde(default)]
    draft: bool,
    merged_at: Option<String>,
    title: Option<String>,
    user: Option<RestUser>,
    updated_at: Option<String>,
}

/// Perform the bulk REST refill and write rows into `pr_state`.
///
/// Returns the number of rows written. See the module docs for the
/// graceful-degradation contract (never returns `Err` for
/// resolution/network failures — only [`CacheError`] from the SQLite
/// write path itself can propagate, and even individual row upsert
/// failures are skipped rather than aborting the whole batch).
pub async fn refresh_open_prs(
    cache: &SqliteCache,
    repo_override: Option<&str>,
) -> Result<u64, CacheError> {
    let repo = match resolve_repo_nwo(repo_override) {
        Some(r) => r,
        None => {
            tracing::warn!("refresh_open_prs: could not resolve owner/repo; skipping REST refill");
            return Ok(0);
        }
    };
    let token = match resolve_token() {
        Some(t) => t,
        None => {
            tracing::warn!(repo = %repo, "refresh_open_prs: could not resolve a GitHub token; skipping REST refill");
            return Ok(0);
        }
    };
    let url = format!("https://api.github.com/repos/{repo}/pulls?state=open&per_page=100");
    let client = match reqwest::Client::builder()
        .user_agent("chump-github-cache-cli/0.1 (INFRA-3833)")
        .build()
    {
        Ok(c) => c,
        Err(err) => {
            tracing::warn!(%err, "refresh_open_prs: failed to build http client");
            return Ok(0);
        }
    };
    let resp = match client
        .get(&url)
        .bearer_auth(&token)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
    {
        Ok(r) => r,
        Err(err) => {
            tracing::warn!(%err, repo = %repo, "refresh_open_prs: gh api request failed");
            return Ok(0);
        }
    };
    if !resp.status().is_success() {
        tracing::warn!(status = %resp.status(), repo = %repo, "refresh_open_prs: gh api returned non-2xx");
        return Ok(0);
    }
    let body = match resp.text().await {
        Ok(b) => b,
        Err(err) => {
            tracing::warn!(%err, "refresh_open_prs: failed to read response body");
            return Ok(0);
        }
    };
    let elements: Vec<serde_json::Value> = match serde_json::from_str(&body) {
        Ok(serde_json::Value::Array(v)) => v,
        _ => {
            tracing::warn!("refresh_open_prs: response body was not a JSON array; skipping");
            return Ok(0);
        }
    };

    let now = crate::webhook::chrono_like_now();
    let mut written = 0u64;
    for elem in elements {
        let raw = serde_json::to_string(&elem).ok();
        let pr: RestPr = match serde_json::from_value(elem) {
            Ok(p) => p,
            Err(_) => continue,
        };
        let auto_merge_enabled = matches!(pr.auto_merge, Some(serde_json::Value::Object(_)));
        let row = PrState {
            number: pr.number,
            head_ref: pr.head.as_ref().and_then(|h| h.ref_.clone()),
            head_sha: pr.head.as_ref().and_then(|h| h.sha.clone()),
            base_ref: pr.base.as_ref().and_then(|b| b.ref_.clone()),
            base_sha: pr.base.as_ref().and_then(|b| b.sha.clone()),
            mergeable_state: pr.mergeable_state.clone(),
            auto_merge_enabled,
            draft: pr.draft,
            merged_at: pr.merged_at,
            title: pr.title,
            user_login: pr.user.and_then(|u| u.login),
            updated_at_api: pr.updated_at.clone().unwrap_or_else(|| now.clone()),
            fetched_at_local: now.clone(),
            raw_payload_json: raw,
            merge_state_status: pr.mergeable_state,
        };
        if cache.upsert_pr(&row).is_ok() {
            written += 1;
        }
    }
    Ok(written)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_repo_nwo_prefers_explicit_override() {
        assert_eq!(
            resolve_repo_nwo(Some("org/explicit")).as_deref(),
            Some("org/explicit")
        );
    }

    #[test]
    fn resolve_repo_nwo_ignores_empty_override() {
        // Empty override falls through to env/gh — we only assert it
        // does NOT short-circuit to Some(""), since that would produce a
        // malformed REST URL.
        assert_ne!(resolve_repo_nwo(Some("")).as_deref(), Some(""));
    }
}
