//! `chump ingest-preflight <owner/repo|url|local-path>` — INFRA-1778
//! (Column A safety rail for INFRA-1746 ingest).
//!
//! Verifies the operator has push access to a target repo BEFORE any
//! ingest phase runs, and offers a natural place to point at gh-app
//! install for webhook-driven regen later. Zero LLM calls, zero mutation
//! — this only shells out to `gh` / `git` read-only subcommands.

use std::path::Path;
use std::process::Command;
use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FailureClass {
    /// `gh` is not on PATH. Permanent — operator must install the CLI.
    GhNotInstalled,
    /// `gh` is installed but not logged in. Permanent — operator must `gh auth login`.
    NotAuthenticated,
    /// Could not turn the input into an owner/repo slug. Permanent.
    UnresolvableRepo,
    /// `gh repo view` reports the repo doesn't exist, or exists but the
    /// operator has zero visibility into it. Permanent.
    RepoNotFoundOrNoAccess,
    /// Repo is visible but the operator's role is below WRITE. Permanent —
    /// operator needs a collaborator invite or different account.
    NoPushAccess,
    /// `gh repo view` failed in a way that looks like a network/API blip.
    /// Retryable — operator action is "try again", not "fix something".
    TransientApiError,
}

impl FailureClass {
    fn as_str(&self) -> &'static str {
        match self {
            FailureClass::GhNotInstalled => "gh_not_installed",
            FailureClass::NotAuthenticated => "not_authenticated",
            FailureClass::UnresolvableRepo => "unresolvable_repo",
            FailureClass::RepoNotFoundOrNoAccess => "repo_not_found_or_no_access",
            FailureClass::NoPushAccess => "no_push_access",
            FailureClass::TransientApiError => "transient_api_error",
        }
    }

    fn transient(&self) -> bool {
        matches!(self, FailureClass::TransientApiError)
    }

    fn exit_code(&self) -> i32 {
        if self.transient() {
            3
        } else {
            1
        }
    }
}

enum ParseOutcome {
    Ok(String),
    Help,
    UsageError(String),
}

/// `chump ingest-preflight` subcommand entry point. `args` is everything
/// after `ingest-preflight`.
pub fn run(args: &[String]) -> i32 {
    match parse_args(args) {
        ParseOutcome::Help => {
            print_usage();
            0
        }
        ParseOutcome::UsageError(msg) => {
            eprintln!("chump ingest-preflight: {msg}");
            print_usage();
            2
        }
        ParseOutcome::Ok(target) => run_validated(&target),
    }
}

fn parse_args(args: &[String]) -> ParseOutcome {
    let mut target: Option<String> = None;
    for a in args {
        match a.as_str() {
            "--help" | "-h" => return ParseOutcome::Help,
            a if !a.starts_with('-') => {
                if target.is_some() {
                    return ParseOutcome::UsageError(format!("unexpected extra argument: {a}"));
                }
                target = Some(a.to_string());
            }
            a => return ParseOutcome::UsageError(format!("unknown flag: {a}")),
        }
    }
    match target {
        Some(t) => ParseOutcome::Ok(t),
        None => ParseOutcome::UsageError(
            "missing required argument <owner/repo|url|local-path>\nUsage: chump ingest-preflight <owner/repo|url|local-path>".into(),
        ),
    }
}

fn print_usage() {
    println!("Usage: chump ingest-preflight <owner/repo|url|local-path>");
    println!();
    println!("INFRA-1778: verifies the operator has push access to a target repo via");
    println!("`gh`, before any ingest phase runs. Read-only, zero LLM calls (cost_usd=0.00).");
    println!();
    println!("Accepts:");
    println!("  owner/repo               e.g. repairman29/BEAST-MODE");
    println!("  https://github.com/... or git@github.com:... URL");
    println!("  a local path to an existing git checkout (reads its 'origin' remote)");
    println!();
    println!("Exit codes: 0 ok, 1 permanent failure, 2 usage error, 3 transient API error");
}

fn run_validated(target: &str) -> i32 {
    let start = Instant::now();
    emit_started(target);

    if !gh_installed() {
        return fail(
            target,
            None,
            FailureClass::GhNotInstalled,
            "gh CLI not found on PATH — install from https://cli.github.com/",
            start,
        );
    }

    if !gh_authenticated() {
        return fail(
            target,
            None,
            FailureClass::NotAuthenticated,
            "gh is not authenticated — run `gh auth login`",
            start,
        );
    }

    let slug = match resolve_slug(target) {
        Ok(s) => s,
        Err(msg) => return fail(target, None, FailureClass::UnresolvableRepo, &msg, start),
    };

    match check_repo_access(&slug) {
        RepoAccess::HasPush => {
            let elapsed_ms = start.elapsed().as_millis();
            emit_result(target, Some(&slug), true, None, elapsed_ms, None);
            println!(
                "chump ingest-preflight: {slug} — push access confirmed \
                 (cost_usd=0.00, elapsed_ms={elapsed_ms})"
            );
            0
        }
        RepoAccess::NoPush => fail(
            target,
            Some(&slug),
            FailureClass::NoPushAccess,
            &format!(
                "authenticated but lacks push access to {slug} (viewerPermission below WRITE)"
            ),
            start,
        ),
        RepoAccess::NotFound => fail(
            target,
            Some(&slug),
            FailureClass::RepoNotFoundOrNoAccess,
            &format!("{slug} does not exist, or the operator has no visibility into it"),
            start,
        ),
        RepoAccess::Transient(msg) => fail(
            target,
            Some(&slug),
            FailureClass::TransientApiError,
            &msg,
            start,
        ),
    }
}

fn fail(
    target: &str,
    slug: Option<&str>,
    class: FailureClass,
    message: &str,
    start: Instant,
) -> i32 {
    let elapsed_ms = start.elapsed().as_millis();
    emit_result(target, slug, false, Some(class), elapsed_ms, Some(message));
    eprintln!("chump ingest-preflight: {} — {message}", class.as_str());
    class.exit_code()
}

fn gh_installed() -> bool {
    Command::new("gh")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// `$GH_TOKEN` / `$GITHUB_TOKEN` are stripped so a stale env token can't
/// mask (or fake) gh's actual keyring auth state.
fn gh_authenticated() -> bool {
    Command::new("gh")
        .args(["auth", "status", "--hostname", "github.com"])
        .env_remove("GH_TOKEN")
        .env_remove("GITHUB_TOKEN")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Turn `target` into an `owner/repo` slug: local git checkout (reads its
/// `origin` remote), a GitHub URL (HTTPS or SSH), or a bare `owner/repo`.
fn resolve_slug(target: &str) -> Result<String, String> {
    let path = Path::new(target);
    if path.is_dir() {
        if !path.join(".git").exists() {
            return Err(format!(
                "local path {target} is not a git repository (no .git found)"
            ));
        }
        let out = Command::new("git")
            .args(["-C", target, "remote", "get-url", "origin"])
            .output();
        return match out {
            Ok(o) if o.status.success() => {
                let url = String::from_utf8_lossy(&o.stdout).trim().to_string();
                extract_owner_repo(&url).ok_or_else(|| {
                    format!("could not parse owner/repo from remote 'origin' url: {url}")
                })
            }
            _ => Err(format!(
                "local path {target} has no 'origin' remote configured — cannot determine \
                 owner/repo for push-access check"
            )),
        };
    }

    if target.contains("://") || target.starts_with("git@") {
        return extract_owner_repo(target)
            .ok_or_else(|| format!("could not parse owner/repo from URL: {target}"));
    }

    if is_plain_slug(target) {
        return Ok(target
            .trim_end_matches('/')
            .trim_end_matches(".git")
            .to_string());
    }

    Err(format!(
        "could not resolve '{target}' as a GitHub owner/repo, URL, or local git repository path"
    ))
}

/// True for a bare `owner/repo` (exactly one non-empty `/`-separated pair,
/// no scheme, no whitespace).
fn is_plain_slug(s: &str) -> bool {
    let stripped = s.trim_end_matches('/').trim_end_matches(".git");
    if stripped.contains(char::is_whitespace) {
        return false;
    }
    let parts: Vec<&str> = stripped.split('/').collect();
    parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty()
}

/// Extract `owner/repo` from an HTTPS or SSH GitHub URL.
fn extract_owner_repo(url: &str) -> Option<String> {
    let stripped = url.trim_end_matches('/').trim_end_matches(".git");

    if let Some(rest) = stripped.strip_prefix("git@") {
        let colon = rest.find(':')?;
        let path = &rest[colon + 1..];
        return is_plain_slug(path).then(|| path.to_string());
    }

    let without_scheme = stripped
        .trim_start_matches("https://")
        .trim_start_matches("http://");
    let slash = without_scheme.find('/')?;
    let path = &without_scheme[slash + 1..];
    let parts: Vec<&str> = path.splitn(3, '/').collect();
    if parts.len() < 2 || parts[0].is_empty() || parts[1].is_empty() {
        return None;
    }
    Some(format!("{}/{}", parts[0], parts[1]))
}

enum RepoAccess {
    HasPush,
    NoPush,
    NotFound,
    Transient(String),
}

fn check_repo_access(slug: &str) -> RepoAccess {
    let out = Command::new("gh")
        .args(["repo", "view", slug, "--json", "viewerPermission"])
        .env_remove("GH_TOKEN")
        .env_remove("GITHUB_TOKEN")
        .output();

    match out {
        Ok(o) if o.status.success() => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            match serde_json::from_str::<serde_json::Value>(&stdout) {
                Ok(v) => {
                    let perm = v
                        .get("viewerPermission")
                        .and_then(|p| p.as_str())
                        .unwrap_or("");
                    if matches!(perm, "WRITE" | "MAINTAIN" | "ADMIN") {
                        RepoAccess::HasPush
                    } else {
                        RepoAccess::NoPush
                    }
                }
                Err(e) => {
                    RepoAccess::Transient(format!("gh repo view returned unparseable JSON: {e}"))
                }
            }
        }
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr).to_lowercase();
            let transient_markers = [
                "timeout",
                "timed out",
                "connection",
                "temporarily unavailable",
                "502",
                "503",
                "rate limit",
            ];
            if transient_markers.iter().any(|m| stderr.contains(m)) {
                RepoAccess::Transient(format!("gh repo view transient error: {}", stderr.trim()))
            } else {
                RepoAccess::NotFound
            }
        }
        Err(e) => RepoAccess::Transient(format!("failed to execute gh: {e}")),
    }
}

/// # scanner-anchor: "kind":"ingest_preflight_started"
fn emit_started(target: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_preflight_started".to_string(),
        source: Some("chump-ingest-preflight".to_string()),
        fields: vec![
            ("target".to_string(), target.to_string()),
            ("cost_usd".to_string(), "0.00".to_string()),
        ],
        ..Default::default()
    });
}

/// # scanner-anchor: "kind":"ingest_preflight_result"
#[allow(clippy::too_many_arguments)]
fn emit_result(
    target: &str,
    resolved_repo: Option<&str>,
    has_push_access: bool,
    failure_class: Option<FailureClass>,
    elapsed_ms: u128,
    error: Option<&str>,
) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_preflight_result".to_string(),
        source: Some("chump-ingest-preflight".to_string()),
        fields: vec![
            ("target".to_string(), target.to_string()),
            (
                "resolved_repo".to_string(),
                resolved_repo.unwrap_or("").to_string(),
            ),
            ("has_push_access".to_string(), has_push_access.to_string()),
            (
                "failure_class".to_string(),
                failure_class.map(|c| c.as_str()).unwrap_or("").to_string(),
            ),
            (
                "transient".to_string(),
                failure_class
                    .map(|c| c.transient())
                    .unwrap_or(false)
                    .to_string(),
            ),
            ("elapsed_ms".to_string(), elapsed_ms.to_string()),
            ("cost_usd".to_string(), "0.00".to_string()),
            ("error".to_string(), error.unwrap_or("").to_string()),
        ],
        ..Default::default()
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_plain_slug_accepts_owner_repo() {
        assert!(is_plain_slug("repairman29/BEAST-MODE"));
        assert!(is_plain_slug("owner/repo/"));
        assert!(is_plain_slug("owner/repo.git"));
    }

    #[test]
    fn is_plain_slug_rejects_non_slugs() {
        assert!(!is_plain_slug("just-a-name"));
        assert!(!is_plain_slug("owner/repo/extra"));
        assert!(!is_plain_slug("has space/repo"));
        assert!(!is_plain_slug("owner/"));
        assert!(!is_plain_slug("/repo"));
    }

    #[test]
    fn extract_owner_repo_handles_https() {
        assert_eq!(
            extract_owner_repo("https://github.com/repairman29/BEAST-MODE"),
            Some("repairman29/BEAST-MODE".to_string())
        );
        assert_eq!(
            extract_owner_repo("https://github.com/repairman29/BEAST-MODE.git"),
            Some("repairman29/BEAST-MODE".to_string())
        );
    }

    #[test]
    fn extract_owner_repo_handles_ssh() {
        assert_eq!(
            extract_owner_repo("git@github.com:repairman29/BEAST-MODE.git"),
            Some("repairman29/BEAST-MODE".to_string())
        );
    }

    #[test]
    fn extract_owner_repo_rejects_malformed() {
        assert_eq!(extract_owner_repo("https://github.com/onlyowner"), None);
        assert_eq!(extract_owner_repo("not-a-url"), None);
    }

    #[test]
    fn resolve_slug_plain_slug_passthrough() {
        assert_eq!(
            resolve_slug("repairman29/BEAST-MODE"),
            Ok("repairman29/BEAST-MODE".to_string())
        );
    }

    #[test]
    fn resolve_slug_rejects_unresolvable() {
        assert!(resolve_slug("this is not resolvable").is_err());
    }

    #[test]
    fn failure_class_exit_codes_and_transience() {
        assert_eq!(FailureClass::GhNotInstalled.exit_code(), 1);
        assert!(!FailureClass::GhNotInstalled.transient());
        assert_eq!(FailureClass::TransientApiError.exit_code(), 3);
        assert!(FailureClass::TransientApiError.transient());
    }

    #[test]
    fn parse_args_help() {
        assert!(matches!(
            parse_args(&["--help".to_string()]),
            ParseOutcome::Help
        ));
    }

    #[test]
    fn parse_args_missing_target_is_usage_error() {
        assert!(matches!(parse_args(&[]), ParseOutcome::UsageError(_)));
    }

    #[test]
    fn parse_args_extra_argument_is_usage_error() {
        assert!(matches!(
            parse_args(&["a/b".to_string(), "c/d".to_string()]),
            ParseOutcome::UsageError(_)
        ));
    }
}
