//! INFRA-1780: `chump ingest <repo-path>` — phase 1a of the existing-repo takeover
//! entrypoint (INFRA-1746). This slice ships CLI parsing + repo validation +
//! read-only safety only. The analysis phases (Librarian/Cartographer/Evangelist/
//! Systematizer) are separate follow-up gaps (INFRA-1781 through INFRA-1784) that
//! build on the validated target this command establishes.
//!
//! Safety contract: the target repo is treated as READ-ONLY by default. No file
//! under the target is ever written unless the operator passes
//! `--confirm-mutations`, and even then this phase performs no mutations itself —
//! it only records operator intent for the later phases to honor.

use std::path::{Path, PathBuf};
use std::time::Instant;

// ── Failure taxonomy ─────────────────────────────────────────────────────────

/// Distinguishes permanent (operator must fix input) from transient
/// (retry may succeed) failure classes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FailureClass {
    /// Target path does not exist on disk. Permanent until operator fixes the path.
    PathNotFound,
    /// Target path exists but is not a directory. Permanent.
    NotADirectory,
    /// Target directory exists but is not a git repository. Permanent.
    NotAGitRepo,
    /// `git` binary invocation itself failed (not found / spawn error). Transient —
    /// retriable once the environment has `git` on PATH.
    GitInvocationFailed,
}

impl FailureClass {
    fn as_str(self) -> &'static str {
        match self {
            FailureClass::PathNotFound => "path_not_found",
            FailureClass::NotADirectory => "not_a_directory",
            FailureClass::NotAGitRepo => "not_a_git_repo",
            FailureClass::GitInvocationFailed => "git_invocation_failed",
        }
    }
}

// ── Args ─────────────────────────────────────────────────────────────────────

#[derive(Debug)]
struct IngestArgs {
    repo_path: PathBuf,
    /// Operator has confirmed later phases may mutate the target repo. This
    /// phase performs no mutations regardless — it only records the intent.
    confirm_mutations: bool,
}

impl IngestArgs {
    fn from_argv(args: &[String]) -> Result<Self, String> {
        // args[0] = "ingest"
        let mut repo_path: Option<PathBuf> = None;
        let mut confirm_mutations = false;

        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--help" | "-h" => return Err("__help__".to_string()),
                "--confirm-mutations" => confirm_mutations = true,
                other if !other.starts_with('-') && repo_path.is_none() => {
                    repo_path = Some(PathBuf::from(other));
                }
                other => return Err(format!("unrecognized argument: {other}")),
            }
            i += 1;
        }

        let repo_path = repo_path.ok_or_else(|| "missing required <repo-path>".to_string())?;

        Ok(IngestArgs {
            repo_path,
            confirm_mutations,
        })
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn run(args: &[String]) -> i32 {
    let ingest_args = match IngestArgs::from_argv(args) {
        Ok(a) => a,
        Err(e) if e == "__help__" => {
            print_usage();
            return 0;
        }
        Err(e) => {
            eprintln!("chump ingest: {e}");
            eprintln!();
            print_usage();
            return 2;
        }
    };

    match run_ingest(ingest_args) {
        Ok(()) => 0,
        Err(()) => 1,
    }
}

fn print_usage() {
    println!("Usage: chump ingest <repo-path> [--confirm-mutations]");
    println!();
    println!("Validate an existing repo as an ingest target (INFRA-1746 phase 1a).");
    println!("The target is READ-ONLY unless --confirm-mutations is passed. This");
    println!("phase never writes to the target itself — later phases (INFRA-1781+)");
    println!("do the actual analysis + artifact generation.");
    println!();
    println!("Arguments:");
    println!("  <repo-path>           Path to an existing local git repository");
    println!();
    println!("Options:");
    println!("  --confirm-mutations   Record operator consent for later phases to write");
    println!("                        artifacts into the target repo (no effect yet)");
    println!();
    println!("Examples:");
    println!("  chump ingest ~/code/some-axum-app");
    println!("  chump ingest ~/code/some-axum-app --confirm-mutations");
}

fn run_ingest(args: IngestArgs) -> Result<(), ()> {
    let start = Instant::now();
    let target = &args.repo_path;

    let session_id = std::env::var("CHUMP_SESSION_ID")
        .or_else(|_| std::env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| "unknown".to_string());

    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_initiated".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("target_repo_path".to_string(), target.display().to_string()),
            (
                "confirm_mutations".to_string(),
                args.confirm_mutations.to_string(),
            ),
            ("session_id".to_string(), session_id),
        ],
        ..Default::default()
    });

    // ── Validation 1: path exists ──────────────────────────────────────────
    if !target.exists() {
        eprintln!("chump ingest: path does not exist: {}", target.display());
        emit_failed(FailureClass::PathNotFound, target, start);
        return Err(());
    }

    // ── Validation 2: is a directory ───────────────────────────────────────
    if !target.is_dir() {
        eprintln!("chump ingest: not a directory: {}", target.display());
        emit_failed(FailureClass::NotADirectory, target, start);
        return Err(());
    }

    // ── Validation 3: is a git repository ──────────────────────────────────
    match is_git_repo(target) {
        Ok(true) => {}
        Ok(false) => {
            eprintln!("chump ingest: not a git repository: {}", target.display());
            emit_failed(FailureClass::NotAGitRepo, target, start);
            return Err(());
        }
        Err(()) => {
            eprintln!("chump ingest: could not invoke git to validate target");
            emit_failed(FailureClass::GitInvocationFailed, target, start);
            return Err(());
        }
    }

    // ── Read-only safety gate ──────────────────────────────────────────────
    let mode = if args.confirm_mutations {
        "mutations_confirmed"
    } else {
        "read_only"
    };

    println!("chump ingest: target validated — {}", target.display());
    if args.confirm_mutations {
        println!(
            "  mutation consent recorded — later ingest phases (INFRA-1781+) may write artifacts"
        );
    } else {
        println!(
            "  read-only mode — no writes will occur under this target. Pass --confirm-mutations to allow later phases to write."
        );
    }
    println!(
        "  analysis phases (Librarian/Cartographer/Evangelist/Systematizer) are not yet wired — INFRA-1781 through INFRA-1784"
    );

    let duration_ms = start.elapsed().as_millis();
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_validated".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("target_repo_path".to_string(), target.display().to_string()),
            ("mode".to_string(), mode.to_string()),
            ("duration_ms".to_string(), duration_ms.to_string()),
        ],
        ..Default::default()
    });

    Ok(())
}

/// True if `path` is (or is inside) a git working tree, per `git rev-parse
/// --is-inside-work-tree`. Returns Err(()) only if `git` itself could not be
/// invoked (not found / spawn failure) — a transient environment problem, not
/// a verdict on the target.
fn is_git_repo(path: &Path) -> Result<bool, ()> {
    let output = std::process::Command::new("git")
        .args(["rev-parse", "--is-inside-work-tree"])
        .current_dir(path)
        .output();

    match output {
        Ok(out) => Ok(out.status.success()),
        Err(_) => Err(()),
    }
}

fn emit_failed(class: FailureClass, target: &Path, start: Instant) {
    let duration_ms = start.elapsed().as_millis();
    let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
        kind: "ingest_failed".to_string(),
        source: Some("chump-ingest".to_string()),
        fields: vec![
            ("failure_class".to_string(), class.as_str().to_string()),
            ("target_repo_path".to_string(), target.display().to_string()),
            ("duration_ms".to_string(), duration_ms.to_string()),
        ],
        ..Default::default()
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_repo_path() {
        let args = IngestArgs::from_argv(&["ingest".to_string(), "/tmp/foo".to_string()]).unwrap();
        assert_eq!(args.repo_path, PathBuf::from("/tmp/foo"));
        assert!(!args.confirm_mutations);
    }

    #[test]
    fn parses_confirm_mutations_flag() {
        let args = IngestArgs::from_argv(&[
            "ingest".to_string(),
            "/tmp/foo".to_string(),
            "--confirm-mutations".to_string(),
        ])
        .unwrap();
        assert!(args.confirm_mutations);
    }

    #[test]
    fn missing_repo_path_errors() {
        let err = IngestArgs::from_argv(&["ingest".to_string()]).unwrap_err();
        assert!(err.contains("missing required"));
    }

    #[test]
    fn help_flag_short_circuits() {
        let err = IngestArgs::from_argv(&["ingest".to_string(), "--help".to_string()]).unwrap_err();
        assert_eq!(err, "__help__");
    }

    #[test]
    fn unrecognized_flag_errors() {
        let err = IngestArgs::from_argv(&[
            "ingest".to_string(),
            "/tmp/foo".to_string(),
            "--bogus".to_string(),
        ])
        .unwrap_err();
        assert!(err.contains("unrecognized argument"));
    }

    #[test]
    fn failure_class_strings_are_stable() {
        assert_eq!(FailureClass::PathNotFound.as_str(), "path_not_found");
        assert_eq!(FailureClass::NotADirectory.as_str(), "not_a_directory");
        assert_eq!(FailureClass::NotAGitRepo.as_str(), "not_a_git_repo");
        assert_eq!(
            FailureClass::GitInvocationFailed.as_str(),
            "git_invocation_failed"
        );
    }

    #[test]
    fn nonexistent_path_is_not_a_git_repo_check_target() {
        // is_git_repo runs `git rev-parse` with current_dir set to a nonexistent
        // path; Command::output() surfaces that as a spawn error (transient
        // GitInvocationFailed), not a definitive not-a-repo verdict — the caller
        // (run_ingest) checks existence first, so this path is unreachable in
        // practice. Assert the low-level behavior directly here.
        let result = is_git_repo(Path::new("/nonexistent/definitely/not/here"));
        assert!(result.is_err() || result == Ok(false));
    }
}
