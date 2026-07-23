//! `chump ingest-preflight <owner/repo|url|local-path>` — INFRA-1778
//! (Column A safety rail, phase of INFRA-1746).
//!
//! Verifies the operator has push access to the ingest target *before* any
//! ingest work begins, via `gh`. Makes zero LLM calls — cost_usd is always
//! 0.00. No filesystem mutation, no clone, no write of any kind.

use std::path::Path;
use std::process::Command;
use std::time::Instant;

/// `chump ingest-preflight` subcommand entry point. `args` is everything
/// after `ingest-preflight`.
pub fn run(args: &[String]) -> i32 {
    let mut target: Option<String> = None;
    for a in args {
        match a.as_str() {
            "--help" | "-h" => {
                print_usage();
                return 0;
            }
            a if !a.starts_with('-') => {
                if target.is_some() {
                    eprintln!("chump ingest-preflight: unexpected extra argument: {a}");
                    print_usage();
                    return 2;
                }
                target = Some(a.to_string());
            }
            a => {
                eprintln!("chump ingest-preflight: unknown flag: {a}");
                print_usage();
                return 2;
            }
        }
    }

    let target = match target {
        Some(t) => t,
        None => {
            eprintln!(
                "chump ingest-preflight: missing required argument <owner/repo|url|local-path>"
            );
            print_usage();
            return 2;
        }
    };

    run_validated(&target)
}

fn print_usage() {
    println!("Usage: chump ingest-preflight <owner/repo|url|local-path>");
    println!();
    println!("Verifies gh is installed, the operator is authenticated, the target");
    println!("repo resolves, and the operator has push access to it — before any");
    println!("ingest work begins. Read-only, zero LLM calls (cost_usd=0.00).");
}

fn run_validated(target: &str) -> i32 {
    let start = Instant::now();
    emit_started(target);

    if !gh_installed() {
        return finish_failure(target, start, "gh_not_installed", false);
    }

    if !gh_authenticated() {
        return finish_failure(target, start, "not_authenticated", false);
    }

    let slug = match resolve_slug(target) {
        Some(s) => s,
        None => {
            return finish_failure(target, start, "unresolvable_repo", false);
        }
    };

    let output = Command::new("gh")
        .args(["api", &format!("repos/{slug}")])
        .output();

    let output = match output {
        Ok(o) => o,
        Err(_) => {
            return finish_failure(target, start, "transient_api_error", true);
        }
    };

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // gh exits non-zero for 404 (not found / no access) and for genuine
        // transient failures (5xx, timeouts, connection resets). Treat the
        // former as permanent, the latter as retryable.
        if stderr.contains("HTTP 404") || stderr.contains("Not Found") {
            return finish_failure(target, start, "repo_not_found_or_no_access", false);
        }
        return finish_failure(target, start, "transient_api_error", true);
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let has_push_access = parse_push_permission(&stdout);

    match has_push_access {
        Some(true) => {
            let elapsed_ms = start.elapsed().as_millis();
            emit_result(target, true, elapsed_ms, "");
            println!(
                "chump ingest-preflight: {target} resolved to {slug} — operator has push \
                 access (cost_usd=0.00)"
            );
            0
        }
        Some(false) => finish_failure(target, start, "no_push_access", false),
        None => finish_failure(target, start, "repo_not_found_or_no_access", false),
    }
}

fn finish_failure(target: &str, start: Instant, failure_class: &str, transient: bool) -> i32 {
    let elapsed_ms = start.elapsed().as_millis();
    emit_result(target, false, elapsed_ms, failure_class);
    eprintln!("chump ingest-preflight: failed ({failure_class}): {target}");
    if transient {
        3
    } else {
        1
    }
}

fn gh_installed() -> bool {
    Command::new("gh")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn gh_authenticated() -> bool {
    // Deliberately does NOT strip GH_TOKEN/GITHUB_TOKEN: fleet workers
    // authenticate via env-var token (not gh's keyring), so removing them
    // would report a false not_authenticated for the exact auth path
    // ingest actually uses.
    Command::new("gh")
        .args(["auth", "status", "--hostname", "github.com"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Resolve `<owner/repo|url|local-path>` down to an `owner/repo` slug.
fn resolve_slug(target: &str) -> Option<String> {
    // Local path: a directory containing .git — read `origin` remote URL.
    let path = Path::new(target);
    if path.is_dir() && path.join(".git").exists() {
        let output = Command::new("git")
            .args(["-C", target, "remote", "get-url", "origin"])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let url = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return extract_owner_repo(&url);
    }

    // URL or SSH form.
    if target.contains("://") || target.starts_with("git@") {
        return extract_owner_repo(target);
    }

    // Bare `owner/repo` slug.
    let parts: Vec<&str> = target.splitn(2, '/').collect();
    if parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty() && !parts[1].contains('/') {
        return Some(target.to_string());
    }

    None
}

/// Extract `owner/repo` from an HTTPS or SSH GitHub URL.
fn extract_owner_repo(url: &str) -> Option<String> {
    let stripped = url.trim_end_matches('/').trim_end_matches(".git");

    if let Some(rest) = stripped.strip_prefix("git@") {
        let colon = rest.find(':')?;
        let slug = &rest[colon + 1..];
        return validate_slug(slug);
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
    validate_slug(&format!("{}/{}", parts[0], parts[1]))
}

fn validate_slug(slug: &str) -> Option<String> {
    let parts: Vec<&str> = slug.splitn(2, '/').collect();
    if parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty() {
        Some(format!("{}/{}", parts[0], parts[1]))
    } else {
        None
    }
}

/// Parse `"permissions":{"push":true|false,...}` out of `gh api repos/OWNER/REPO`
/// JSON output without pulling in a JSON dependency.
fn parse_push_permission(json: &str) -> Option<bool> {
    let idx = json.find("\"permissions\"")?;
    let rest = &json[idx..];
    let push_idx = rest.find("\"push\"")?;
    let after = &rest[push_idx + "\"push\"".len()..];
    let colon = after.find(':')?;
    let after_colon = after[colon + 1..].trim_start();
    if after_colon.starts_with("true") {
        Some(true)
    } else if after_colon.starts_with("false") {
        Some(false)
    } else {
        None
    }
}

fn emit_started(target: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_preflight_started".to_string(),
        source: Some("chump-ingest-preflight".to_string()),
        fields: vec![("target".to_string(), target.to_string())],
        ..Default::default()
    });
}

fn emit_result(target: &str, has_push_access: bool, elapsed_ms: u128, failure_class: &str) {
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_preflight_result".to_string(),
        source: Some("chump-ingest-preflight".to_string()),
        fields: vec![
            ("target".to_string(), target.to_string()),
            ("has_push_access".to_string(), has_push_access.to_string()),
            ("elapsed_ms".to_string(), elapsed_ms.to_string()),
            ("cost_usd".to_string(), "0.00".to_string()),
            ("failure_class".to_string(), failure_class.to_string()),
        ],
        ..Default::default()
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_slug_bare() {
        assert_eq!(resolve_slug("owner/repo"), Some("owner/repo".to_string()));
    }

    #[test]
    fn resolve_slug_https_url() {
        assert_eq!(
            resolve_slug("https://github.com/owner/repo"),
            Some("owner/repo".to_string())
        );
        assert_eq!(
            resolve_slug("https://github.com/owner/repo.git"),
            Some("owner/repo".to_string())
        );
    }

    #[test]
    fn resolve_slug_ssh_url() {
        assert_eq!(
            resolve_slug("git@github.com:owner/repo.git"),
            Some("owner/repo".to_string())
        );
    }

    #[test]
    fn resolve_slug_invalid() {
        assert_eq!(resolve_slug("not-a-valid-target"), None);
    }

    #[test]
    fn parse_push_permission_true() {
        let json = r#"{"permissions":{"admin":false,"push":true,"pull":true}}"#;
        assert_eq!(parse_push_permission(json), Some(true));
    }

    #[test]
    fn parse_push_permission_false() {
        let json = r#"{"permissions":{"admin":false,"push":false,"pull":true}}"#;
        assert_eq!(parse_push_permission(json), Some(false));
    }

    #[test]
    fn parse_push_permission_missing() {
        let json = r#"{"name":"repo"}"#;
        assert_eq!(parse_push_permission(json), None);
    }
}
