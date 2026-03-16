//! Repo allowlist: CHUMP_GITHUB_REPOS env var plus chump_authorized_repos DB table.
//! Used by git_tools, gh_tools, github_tools to decide if a repo is authorized.

use anyhow::Result;
use crate::db_pool;

fn env_allowlist() -> Vec<String> {
    std::env::var("CHUMP_GITHUB_REPOS")
        .ok()
        .map(|s| {
            s.split(',')
                .map(|x| x.trim().to_string())
                .filter(|x| !x.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn db_contains(repo: &str) -> bool {
    let repo = repo.trim();
    if repo.is_empty() {
        return false;
    }
    let conn = match db_pool::get() {
        Ok(c) => c,
        Err(_) => return false,
    };
    conn.query_row(
        "SELECT 1 FROM chump_authorized_repos WHERE repo = ?1",
        [repo],
        |_| Ok(()),
    )
    .is_ok()
}

/// True if repo is in CHUMP_GITHUB_REPOS or chump_authorized_repos table.
pub fn allowlist_contains(repo: &str) -> bool {
    let repo = repo.trim();
    if repo.is_empty() {
        return false;
    }
    env_allowlist().iter().any(|r| r == repo) || db_contains(repo)
}

/// True if at least one repo is allowed (env or DB).
pub fn allowlist_non_empty() -> bool {
    !env_allowlist().is_empty() || db_has_any()
}

fn db_has_any() -> bool {
    let conn = match db_pool::get() {
        Ok(c) => c,
        Err(_) => return false,
    };
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM chump_authorized_repos", [], |r| r.get(0))
        .unwrap_or(0);
    count > 0
}

/// Add repo to chump_authorized_repos. Idempotent.
pub fn add_authorized_repo(repo: &str) -> Result<()> {
    let repo = repo.trim();
    if repo.is_empty() {
        return Err(anyhow::anyhow!("repo is empty"));
    }
    let conn = db_pool::get()?;
    conn.execute(
        "INSERT OR IGNORE INTO chump_authorized_repos (repo) VALUES (?1)",
        [repo],
    )?;
    Ok(())
}

/// Remove repo from chump_authorized_repos.
pub fn remove_authorized_repo(repo: &str) -> Result<()> {
    let repo = repo.trim();
    if repo.is_empty() {
        return Err(anyhow::anyhow!("repo is empty"));
    }
    let conn = db_pool::get()?;
    conn.execute("DELETE FROM chump_authorized_repos WHERE repo = ?1", [repo])?;
    Ok(())
}
