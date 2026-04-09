//! GitHub read tools: repo file content, directory listing, and clone/pull. Scoped to allowlist (CHUMP_GITHUB_REPOS or authorized).
//! Requires GITHUB_TOKEN. Phase 3 of ROADMAP_DOGFOOD_SELF_IMPROVE.

use crate::chump_log;
use crate::repo_allowlist;
use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::process::Command;

const GITHUB_API_BASE: &str = "https://api.github.com";

fn debug_github_log_enabled() -> bool {
    std::env::var("CHUMP_DEBUG_GITHUB_LOG").ok().as_deref() == Some("1")
}

fn debug_log_path() -> std::path::PathBuf {
    std::env::var("CHUMP_HOME")
        .ok()
        .map(|h| std::path::PathBuf::from(h).join("logs").join("debug-fef776.log"))
        .unwrap_or_else(|| std::path::PathBuf::from("/Users/jeffadkins/Projects/Maclawd/.cursor/debug-fef776.log"))
}

fn github_token() -> Option<String> {
    std::env::var("GITHUB_TOKEN")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn validate_repo_path(path: &str) -> Result<String, String> {
    let path = path.trim().trim_start_matches('/');
    if path.contains("..") {
        return Err("path must not contain ..".to_string());
    }
    if path.is_empty() {
        return Err("path is empty".to_string());
    }
    Ok(path.to_string())
}

/// Minimal percent-encode for path and ref (space, %, and a few chars).
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            ' ' => out.push_str("%20"),
            '%' => out.push_str("%25"),
            '?' => out.push_str("%3F"),
            '#' => out.push_str("%23"),
            '&' => out.push_str("%26"),
            _ => out.push(c),
        }
    }
    out
}

fn parse_repo(repo: &str) -> Result<(String, String), String> {
    let repo = repo.trim();
    let parts: Vec<&str> = repo.splitn(2, '/').collect();
    match parts[..] {
        [owner, name] if !owner.is_empty() && !name.is_empty() => {
            Ok((owner.to_string(), name.to_string()))
        }
        _ => Err("repo must be owner/name".to_string()),
    }
}

pub fn github_enabled() -> bool {
    github_token().is_some() && repo_allowlist::allowlist_non_empty()
}

async fn github_get(
    client: &reqwest::Client,
    url: &str,
    accept_raw: bool,
) -> Result<reqwest::Response> {
    let token_opt = github_token();
    // #region agent log
    if debug_github_log_enabled() {
        let _ = std::fs::OpenOptions::new().create(true).append(true).open(debug_log_path()).and_then(|mut f| {
            use std::io::Write;
            f.write_all(format!("{}\n", serde_json::json!({
                "sessionId": "fef776",
                "location": "github_tools.rs:github_get",
                "message": "GitHub API token check",
                "data": { "token_set": token_opt.is_some(), "token_len": token_opt.as_ref().map(|t| t.len()).unwrap_or(0) },
                "timestamp": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
                "hypothesisId": "A"
            })).as_bytes())
        });
    }
    // #endregion
    let token =
        token_opt.ok_or_else(|| anyhow!("GITHUB_TOKEN or CHUMP_GITHUB_TOKEN not set"))?;
    let mut req = client
        .get(url)
        .header("Accept", "application/vnd.github.v3+json")
        .header("Authorization", format!("Bearer {}", token));
    if accept_raw {
        req = req.header("Accept", "application/vnd.github.v3.raw");
    }
    let res = req
        .send()
        .await
        .map_err(|e| anyhow!("GitHub API request failed: {}", e))?;
    if !res.status().is_success() {
        let status = res.status();
        let body = res.text().await.unwrap_or_default();
        // #region agent log
        if debug_github_log_enabled() {
            let _ = std::fs::OpenOptions::new().create(true).append(true).open(debug_log_path()).and_then(|mut f| {
                use std::io::Write;
                f.write_all(format!("{}\n", serde_json::json!({
                    "sessionId": "fef776",
                    "location": "github_tools.rs:github_get_error",
                    "message": "GitHub API error",
                    "data": { "status": status.as_u16(), "body_snippet": body.chars().take(300).collect::<String>() },
                    "timestamp": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
                    "hypothesisId": "B"
            })).as_bytes())
            });
        }
        // #endregion
        return Err(anyhow!("GitHub API error {}: {}", status, body));
    }
    Ok(res)
}

#[derive(Debug, Deserialize)]
struct ContentsDirEntry {
    name: Option<String>,
    #[serde(rename = "type")]
    typ: Option<String>,
}

pub struct GithubRepoReadTool;

#[async_trait]
impl Tool for GithubRepoReadTool {
    fn name(&self) -> String {
        "github_repo_read".to_string()
    }

    fn description(&self) -> String {
        "Read a file from a GitHub repo. Params: repo (owner/name), path (file path in repo), optional ref (branch/tag, default main). Repo must be in CHUMP_GITHUB_REPOS.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name" },
                "path": { "type": "string", "description": "File path in repo" },
                "ref": { "type": "string", "description": "Branch or tag (default main)" }
            },
            "required": ["repo", "path"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !github_enabled() {
            log_github_disabled();
            return Err(anyhow!(
                "GitHub tools require GITHUB_TOKEN and CHUMP_GITHUB_REPOS"
            ));
        }
        let repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing repo"))?
            .trim();
        if !repo_allowlist::allowlist_contains(repo) {
            log_allowlist_miss(repo);
            return Err(anyhow!("repo {} is not in allowlist", repo));
        }
        let (owner, name) = parse_repo(repo).map_err(|e| anyhow!("{}", e))?;
        let path = input
            .get("path")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing path"))?;
        let path = validate_repo_path(path).map_err(|e| anyhow!("{}", e))?;
        let ref_ = input
            .get("ref")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("main");
        let url = format!(
            "{}/repos/{}/{}/contents/{}?ref={}",
            GITHUB_API_BASE,
            owner,
            name,
            percent_encode(&path),
            percent_encode(ref_)
        );
        let client = reqwest::Client::builder()
            .user_agent("chump-rust-agent")
            .build()
            .map_err(|e| anyhow!("reqwest client: {}", e))?;
        let res = github_get(&client, &url, true).await?;
        let body = res.text().await.map_err(|e| anyhow!("read body: {}", e))?;
        Ok(body)
    }
}

fn log_github_disabled() {
    if !debug_github_log_enabled() {
        return;
    }
    let tok = github_token();
    let _ = std::fs::OpenOptions::new().create(true).append(true).open(debug_log_path()).and_then(|mut f| {
        use std::io::Write;
        f.write_all(format!("{}\n", serde_json::json!({
            "sessionId": "fef776",
            "location": "github_tools.rs:github_enabled_false",
            "message": "GitHub tools disabled",
            "data": { "token_set": tok.is_some(), "allowlist_non_empty": repo_allowlist::allowlist_non_empty() },
            "timestamp": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
            "hypothesisId": "A"
        })).as_bytes())
    });
}

fn log_allowlist_miss(repo: &str) {
    if !debug_github_log_enabled() {
        return;
    }
    use std::io::Write;
    let path = debug_log_path();
    let payload = format!("{}\n", serde_json::json!({
        "sessionId": "fef776",
        "location": "github_tools.rs:allowlist",
        "message": "repo not in allowlist",
        "data": { "repo": repo, "allowlist_non_empty": repo_allowlist::allowlist_non_empty() },
        "timestamp": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
        "hypothesisId": "C"
    }));
    let _ = std::fs::OpenOptions::new().create(true).append(true).open(&path).and_then(|mut f| f.write_all(payload.as_bytes()));
}

pub struct GithubRepoListTool;

#[async_trait]
impl Tool for GithubRepoListTool {
    fn name(&self) -> String {
        "github_repo_list".to_string()
    }

    fn description(&self) -> String {
        "List directory contents in a GitHub repo. Params: repo (owner/name), path (dir path, default .), optional ref (branch/tag). Repo must be in CHUMP_GITHUB_REPOS.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name" },
                "path": { "type": "string", "description": "Directory path (default .)" },
                "ref": { "type": "string", "description": "Branch or tag (default main)" }
            },
            "required": ["repo"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !github_enabled() {
            return Err(anyhow!(
                "GitHub tools require GITHUB_TOKEN and CHUMP_GITHUB_REPOS"
            ));
        }
        let repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing repo"))?
            .trim();
        if !repo_allowlist::allowlist_contains(repo) {
            return Err(anyhow!("repo {} is not in allowlist", repo));
        }
        let (owner, name) = parse_repo(repo).map_err(|e| anyhow!("{}", e))?;
        let path = input
            .get("path")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().trim_start_matches('/'))
            .filter(|s| !s.is_empty())
            .unwrap_or(".");
        if path != "." {
            validate_repo_path(path).map_err(|e| anyhow!("{}", e))?;
        }
        let ref_ = input
            .get("ref")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("main");
        let path_segment = if path == "." {
            "".to_string()
        } else {
            format!("/{}", percent_encode(path))
        };
        let url = format!(
            "{}/repos/{}/{}/contents{}?ref={}",
            GITHUB_API_BASE,
            owner,
            name,
            path_segment,
            percent_encode(ref_)
        );
        let client = reqwest::Client::builder()
            .user_agent("chump-rust-agent")
            .build()
            .map_err(|e| anyhow!("reqwest client: {}", e))?;
        let res = github_get(&client, &url, false).await?;
        let body = res.text().await.map_err(|e| anyhow!("read body: {}", e))?;
        let entries: Vec<ContentsDirEntry> =
            serde_json::from_str(&body).map_err(|e| anyhow!("parse GitHub response: {}", e))?;
        let lines: Vec<String> = entries
            .into_iter()
            .map(|e| {
                let name = e.name.unwrap_or_else(|| "?".to_string());
                let typ = e.typ.unwrap_or_else(|| "file".to_string());
                format!("{} ({})", name, typ)
            })
            .collect();
        Ok(lines.join("\n"))
    }
}

/// Base dir for clone/pull: CHUMP_HOME/repos or current_dir/repos.
fn clone_pull_base_dir() -> Result<PathBuf, String> {
    let base = std::env::var("CHUMP_HOME")
        .ok()
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok());
    let base = base.ok_or_else(|| "CHUMP_HOME not set and current_dir failed".to_string())?;
    Ok(base.join("repos"))
}

/// Target dir for a repo: base/repos/owner_name (no slash in dir name).
fn clone_pull_target(repo: &str) -> Result<PathBuf, String> {
    let (owner, name) = parse_repo(repo)?;
    let base = clone_pull_base_dir()?;
    let dir_name = format!("{}_{}", owner, name);
    Ok(base.join(dir_name))
}

pub struct GithubCloneOrPullTool;

#[async_trait]
impl Tool for GithubCloneOrPullTool {
    fn name(&self) -> String {
        "github_clone_or_pull".to_string()
    }

    fn description(&self) -> String {
        "Clone a GitHub repo (or pull if already cloned) into CHUMP_HOME/repos/owner_name. Params: repo (owner/name), optional ref (branch, default main). Repo must be in CHUMP_GITHUB_REPOS. Return value includes the local path; call set_working_repo with that path (or with repos/owner_name relative to CHUMP_HOME) so file and git tools operate on the cloned repo.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "repo": { "type": "string", "description": "Repository owner/name" },
                "ref": { "type": "string", "description": "Branch to clone or pull (default main)" }
            },
            "required": ["repo"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        if !github_enabled() {
            return Err(anyhow!(
                "GitHub tools require GITHUB_TOKEN and CHUMP_GITHUB_REPOS"
            ));
        }
        let repo = input
            .get("repo")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing repo"))?
            .trim();
        if !repo_allowlist::allowlist_contains(repo) {
            return Err(anyhow!("repo {} is not in allowlist", repo));
        }
        let (owner, name) = parse_repo(repo).map_err(|e| anyhow!("{}", e))?;
        let ref_ = input
            .get("ref")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("main");

        let target = clone_pull_target(repo).map_err(|e| anyhow!("{}", e))?;
        fn tail_detail(s: &str, max: usize) -> String {
            let t = s.trim();
            if t.len() <= max {
                t.to_string()
            } else {
                format!("...{}", &t[t.len().saturating_sub(max)..])
            }
        }

        let token = github_token().ok_or_else(|| anyhow!("GitHub token not set"))?;
        let url = format!(
            "https://x-access-token:{}@github.com/{}/{}.git",
            token, owner, name
        );

        if target.exists() && !target.join(".git").exists() {
            return Err(anyhow!(
                "{} exists but is not a git repo; remove it or use a different path",
                target.display()
            ));
        }
        let (success, msg) = if target.join(".git").exists() {
            // Pull
            let out = Command::new("git")
                .args(["pull", "origin", ref_])
                .current_dir(&target)
                .output()
                .await
                .map_err(|e| anyhow!("git pull failed: {}", e))?;
            let ok = out.status.success();
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            let err_combined = format!("{} {}", stdout.trim(), stderr.trim()).to_lowercase();
            let empty_remote = err_combined.contains("couldn't find remote ref")
                || (err_combined.contains("ref ") && err_combined.contains(" does not exist"));
            let (ok, msg) = if ok {
                (
                    true,
                    format!(
                        "pull {}: {}. Local path: {} (call set_working_repo with this path to use file tools)",
                        ref_,
                        stdout.trim(),
                        target.display()
                    ),
                )
            } else if empty_remote {
                // Remote has no commits yet; repo is ready for local init.
                (
                    true,
                    format!(
                        "Pull skipped (remote has no commits yet). Repo ready for local init. Call set_working_repo with path {} to use file tools.",
                        target.display()
                    ),
                )
            } else {
                (false, format!("pull failed: {} {}", stdout.trim(), stderr.trim()))
            };
            chump_log::log_git_clone_pull(repo, "pull", target.to_string_lossy().as_ref(), ok);
            (ok, msg)
        } else {
            // Clone
            if let Some(parent) = target.parent() {
                if let Err(e) = std::fs::create_dir_all(parent) {
                    return Err(anyhow!("create repos dir: {}", e));
                }
            }
            let out = Command::new("git")
                .args([
                    "clone",
                    "--branch",
                    ref_,
                    &url,
                    target.to_string_lossy().as_ref(),
                ])
                .output()
                .await
                .map_err(|e| anyhow!("git clone failed: {}", e))?;
            let ok = out.status.success();
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            let msg = if ok {
                format!(
                    "cloned {} (ref {}) to {}. Call set_working_repo with path {} to use file tools.",
                    repo,
                    ref_,
                    target.display(),
                    target.display()
                )
            } else {
                let stderr_tail = tail_detail(&stderr, 500);
                format!(
                    "clone failed: {} {}\n--- stderr (last 500 chars) ---\n{}",
                    stdout.trim(),
                    stderr.trim(),
                    stderr_tail
                )
            };
            chump_log::log_git_clone_pull(repo, "clone", target.to_string_lossy().as_ref(), ok);
            (ok, msg)
        };

        if success {
            Ok(msg)
        } else {
            Err(anyhow!("{}", msg))
        }
    }
}
