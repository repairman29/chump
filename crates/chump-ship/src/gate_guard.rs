//! CREDIBLE-1576: Gate-file auto-merge arm refusal guard.
//!
//! Any PR diff vs the merge base (`origin/<base>...HEAD`) that touches a CI
//! workflow, CI gate script, git hook, `chump-preflight` crate, or
//! `*verified-wait*` helper must land under human review — never self-armed.
//!
//! Key invariants:
//! 1. [`BOT_MERGE_GATE_FILE_GLOBS`] is a compile-time constant with zero env
//!    overrides (safety inputs must never be bypassable via env vars).
//! 2. **Fail-closed:** if `git diff --name-only origin/<base>...HEAD` fails or
//!    has no merge base when `auto_merge == true`, arming is refused.
//! 3. **Non-destructive to PR opening:** branch push and PR creation still
//!    succeed; only arming GitHub `--auto` merge is refused.

use std::path::Path;
use std::process::Command;

use thiserror::Error;

/// Env vars scrubbed on every `git` subprocess so inherited runner/hook state
/// never redirects diff computation to another repository.
const ENV_LEAK_VARS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GITHUB_WORKSPACE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
];

/// CREDIBLE-1576 compile-time gate-file globs. Never read from environment.
pub const BOT_MERGE_GATE_FILE_GLOBS: &[&str] = &[
    ".github/workflows/*",
    "scripts/ci/*",
    "scripts/git-hooks/*",
    "crates/chump-preflight/*",
    "*verified-wait*",
];

/// Typed refusal returned when [`check_gate_arm_refused`] blocks `--auto-merge`.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum GateArmRefusal {
    /// Diff against `origin/<base>...HEAD` touched at least one protected gate file.
    #[error(
        "REFUSED: bot-merge will not arm --auto-merge — PR diff touches gate file {file} \
         (matched `{matched_glob}`, CREDIBLE-1576 gate-file guard). The branch is pushed \
         and the PR is open; land it only after review."
    )]
    GateFileTouched {
        /// First repo-relative path in the diff that matched a gate glob.
        file: String,
        /// The pattern in [`BOT_MERGE_GATE_FILE_GLOBS`] that matched.
        matched_glob: &'static str,
    },

    /// `git diff --name-only <base_ref>...HEAD` could not be computed; fail closed.
    #[error(
        "REFUSED: bot-merge will not arm --auto-merge — cannot compute the {base_ref}...HEAD \
         diff ({detail}); failing closed per CREDIBLE-1576. The branch is pushed and the PR \
         is open; land it only after review."
    )]
    DiffUncomputable {
        /// Merge-base ref spec used for the diff (e.g. `origin/main`).
        base_ref: String,
        /// Diagnostic from `git diff` stderr or spawn error.
        detail: String,
    },
}

/// Match a single `*`-wildcard shell glob (where `*` matches zero or more of
/// any character, including `/`, matching bash `case "$f" in $glob)`).
fn wildcard_match(pattern: &str, text: &str) -> bool {
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return pattern == text;
    }
    let mut remainder = text;
    for (idx, part) in parts.iter().enumerate() {
        if part.is_empty() {
            continue;
        }
        if idx == 0 {
            if let Some(rest) = remainder.strip_prefix(part) {
                remainder = rest;
            } else {
                return false;
            }
        } else if idx == parts.len() - 1 {
            return remainder.ends_with(part);
        } else if let Some(pos) = remainder.find(part) {
            remainder = &remainder[pos + part.len()..];
        } else {
            return false;
        }
    }
    true
}

/// Returns `Some(matched_glob)` if `repo_rel_path` matches any glob in
/// [`BOT_MERGE_GATE_FILE_GLOBS`]. Normalizes Windows `\` separators to `/`.
pub fn matches_gate_glob(repo_rel_path: &str) -> Option<&'static str> {
    let normalized = repo_rel_path.trim().replace('\\', "/");
    let normalized = normalized.trim_start_matches("./");
    if normalized.is_empty() {
        return None;
    }
    BOT_MERGE_GATE_FILE_GLOBS
        .iter()
        .copied()
        .find(|glob| wildcard_match(glob, normalized))
}

/// Pure check over a list of changed repo-relative paths.
pub fn check_changed_files<'a, I>(files: I) -> Result<(), GateArmRefusal>
where
    I: IntoIterator<Item = &'a str>,
{
    for f in files {
        let trimmed = f.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(matched_glob) = matches_gate_glob(trimmed) {
            return Err(GateArmRefusal::GateFileTouched {
                file: trimmed.replace('\\', "/"),
                matched_glob,
            });
        }
    }
    Ok(())
}

/// Normalize a base branch argument into the remote-tracking ref used for
/// three-dot merge-base diffing (`main` -> `origin/main`, `origin/main` -> `origin/main`).
pub fn normalize_base_ref(base: &str) -> String {
    let b = base.trim();
    if b.is_empty() {
        "origin/main".to_string()
    } else if b.starts_with("origin/") || b.starts_with("refs/") {
        b.to_string()
    } else {
        format!("origin/{b}")
    }
}

/// CREDIBLE-1576 standalone + embedded gate check.
///
/// - When `auto_merge == false`, returns `Ok(())` immediately without running `git`.
/// - When `auto_merge == true`, computes `git -C <repo_root> diff --name-only <base_ref>...HEAD`.
///   Fails closed (`Err(GateArmRefusal::DiffUncomputable)`) if `git diff` fails, and returns
///   `Err(GateArmRefusal::GateFileTouched)` if any touched file matches [`BOT_MERGE_GATE_FILE_GLOBS`].
pub fn check_gate_arm_refused(
    repo_root: &Path,
    base: &str,
    auto_merge: bool,
) -> Result<(), GateArmRefusal> {
    if !auto_merge {
        return Ok(());
    }
    let base_ref = normalize_base_ref(base);
    let range = format!("{base_ref}...HEAD");

    let mut cmd = Command::new("git");
    for var in ENV_LEAK_VARS {
        cmd.env_remove(var);
    }
    let output = cmd
        .arg("-C")
        .arg(repo_root)
        .args(["diff", "--name-only", &range])
        .output()
        .map_err(|err| GateArmRefusal::DiffUncomputable {
            base_ref: base_ref.clone(),
            detail: format!("failed to spawn git diff: {err}"),
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let detail = if stderr.is_empty() {
            format!("git diff exited with status {}", output.status)
        } else {
            stderr
        };
        return Err(GateArmRefusal::DiffUncomputable { base_ref, detail });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    check_changed_files(stdout.lines())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn matches_all_protected_gate_globs() {
        assert_eq!(
            matches_gate_glob(".github/workflows/ci.yml"),
            Some(".github/workflows/*")
        );
        assert_eq!(
            matches_gate_glob("scripts/ci/test-smoke.sh"),
            Some("scripts/ci/*")
        );
        assert_eq!(
            matches_gate_glob("scripts/git-hooks/pre-push"),
            Some("scripts/git-hooks/*")
        );
        assert_eq!(
            matches_gate_glob("crates/chump-preflight/src/lib.rs"),
            Some("crates/chump-preflight/*")
        );
        assert_eq!(
            matches_gate_glob("scripts/ops/pr-verified-wait.sh"),
            Some("*verified-wait*")
        );
        // Windows path separator normalization
        assert_eq!(
            matches_gate_glob(r"scripts\git-hooks\pre-commit"),
            Some("scripts/git-hooks/*")
        );
    }

    #[test]
    fn allows_ordinary_source_and_doc_paths() {
        assert_eq!(matches_gate_glob("src/main.rs"), None);
        assert_eq!(matches_gate_glob("crates/chump-pal/src/lib.rs"), None);
        assert_eq!(matches_gate_glob("docs/ROADMAP.md"), None);
        assert_eq!(
            matches_gate_glob("scripts/archived/unwired-ci/test-old.sh"),
            None
        );
    }

    #[test]
    fn auto_merge_false_always_allows_without_git() {
        let tmp = TempDir::new().unwrap();
        // Not even a git repo — must still return Ok(()) when auto_merge=false.
        assert!(check_gate_arm_refused(tmp.path(), "main", false).is_ok());
    }

    #[test]
    fn missing_merge_base_fails_closed_when_auto_merge_true() {
        let tmp = TempDir::new().unwrap();
        let err = check_gate_arm_refused(tmp.path(), "main", true).unwrap_err();
        assert!(
            matches!(err, GateArmRefusal::DiffUncomputable { .. }),
            "expected DiffUncomputable, got {err:?}"
        );
    }

    #[test]
    fn git_repo_allows_clean_branch_and_refuses_gate_file_branch() {
        let tmp = TempDir::new().unwrap();
        let origin = tmp.path().join("origin.git");
        let work = tmp.path().join("work");
        std::fs::create_dir_all(&origin).unwrap();

        let run_git = |dir: &Path, args: &[&str]| {
            let mut c = Command::new("git");
            for v in ENV_LEAK_VARS {
                c.env_remove(v);
            }
            let st = c.arg("-C").arg(dir).args(args).status().unwrap();
            assert!(st.success(), "git {args:?} failed in {}", dir.display());
        };

        run_git(&origin, &["init", "--bare", "-b", "main"]);
        let st = Command::new("git")
            .args(["clone", origin.to_str().unwrap(), work.to_str().unwrap()])
            .status()
            .unwrap();
        assert!(st.success());

        run_git(&work, &["config", "user.email", "t@chump.local"]);
        run_git(&work, &["config", "user.name", "Chump Test"]);
        std::fs::write(work.join("README.md"), "seed\n").unwrap();
        run_git(&work, &["add", "README.md"]);
        run_git(&work, &["commit", "-m", "seed"]);
        run_git(&work, &["push", "-u", "origin", "main"]);

        // Clean feature branch
        run_git(&work, &["checkout", "-b", "chump/clean-feature"]);
        std::fs::create_dir_all(work.join("src")).unwrap();
        std::fs::write(work.join("src/lib.rs"), "pub fn ok() {}\n").unwrap();
        run_git(&work, &["add", "src/lib.rs"]);
        run_git(&work, &["commit", "-m", "feat: clean"]);
        assert!(check_gate_arm_refused(&work, "main", true).is_ok());

        // Touch a gate file on the branch -> auto-merge must be refused!
        std::fs::create_dir_all(work.join(".github/workflows")).unwrap();
        std::fs::write(work.join(".github/workflows/ci.yml"), "name: CI\n").unwrap();
        run_git(&work, &["add", ".github/workflows/ci.yml"]);
        run_git(&work, &["commit", "-m", "chore: touch workflow"]);
        let err = check_gate_arm_refused(&work, "main", true).unwrap_err();
        match err {
            GateArmRefusal::GateFileTouched { file, matched_glob } => {
                assert_eq!(file, ".github/workflows/ci.yml");
                assert_eq!(matched_glob, ".github/workflows/*");
            }
            other => panic!("expected GateFileTouched, got {other:?}"),
        }
    }
}
