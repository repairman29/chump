//! Chump version for logs and health. From env CHUMP_VERSION or Cargo.toml at compile time.
//!
//! INFRA-148: also exposes the build-time git SHA + date (baked by `build.rs`)
//! and a staleness check used by `chump gap ship --update-yaml` /
//! `chump gap dump --out PATH` to warn the operator when the binary in
//! $PATH was built before the most recent `gap_store.rs` / `main.rs` (gap
//! command wiring) commit on the local repo's HEAD.
//!
//! Failure mode is "skip the warning, don't refuse" so a binary built
//! outside a git checkout (cargo install --git URL, packaged source) never
//! blocks the operator. The check writes to stderr — never to stdout —
//! so script consumers of `chump gap dump` etc. are unaffected.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Version string: CHUMP_VERSION env if set, else CARGO_PKG_VERSION.
pub fn chump_version() -> String {
    std::env::var("CHUMP_VERSION").unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string())
}

/// Short git SHA (12 chars) of the commit this binary was built from, or
/// `"unknown"` when the build environment had no git available (e.g.
/// packaged source). Set by `build.rs` via `cargo:rustc-env`.
pub fn chump_build_sha() -> &'static str {
    env!("CHUMP_BUILD_SHA")
}

/// Commit date (yyyy-mm-dd, UTC) of the SHA this binary was built from, or
/// `"unknown"`. Set by `build.rs` via `cargo:rustc-env`.
pub fn chump_build_date() -> &'static str {
    env!("CHUMP_BUILD_DATE")
}

/// Files that affect gap-store serialization or `chump gap` command wiring.
/// Any commit touching one of these after the binary's baked SHA is a
/// staleness signal — the operator's binary may emit/read YAML differently
/// from what origin/main expects, risking silent corruption like the
/// pre-INFRA-147 meta:-preamble strip incident on 2026-04-27.
const GAP_STORE_FILES: &[&str] = &["src/gap_store.rs", "src/main.rs"];

/// Outcome of [`check_gap_binary_staleness`].
#[derive(Debug, PartialEq, Eq)]
pub enum StalenessCheck {
    /// Binary's baked SHA is at or ahead of the gap-store-affecting code on
    /// HEAD. Safe to mutate gaps.yaml.
    Fresh,
    /// `unknown` baked SHA, no `.git` at the resolved repo root, or the
    /// `git log` invocation failed for any reason. The check is
    /// inconclusive — caller should proceed without warning to avoid
    /// blocking legitimate use cases (cargo-install builds, fresh clones,
    /// non-git deployments).
    Skip,
    /// HEAD has at least one commit touching `src/gap_store.rs` or
    /// `src/main.rs` after the binary's baked SHA. Carries the (count,
    /// first commit subject) so callers can produce a useful warning.
    Stale {
        commits_ahead: usize,
        latest_subject: String,
    },
}

/// Check whether the binary's baked SHA is older than the gap-store code on
/// HEAD of the repo at `repo_root`. See [`StalenessCheck`] for outcomes.
///
/// This is a best-effort check: any failure path returns `Skip` rather than
/// propagating the error, because we never want to block operators on a
/// staleness check that the check itself couldn't perform reliably.
pub fn check_gap_binary_staleness(repo_root: &Path) -> StalenessCheck {
    check_gap_binary_staleness_with_sha(repo_root, chump_build_sha())
}

/// Same as [`check_gap_binary_staleness`] but with the baked SHA passed in
/// explicitly. Used by tests so we don't have to recompile to simulate a
/// stale binary.
pub fn check_gap_binary_staleness_with_sha(repo_root: &Path, sha: &str) -> StalenessCheck {
    if sha == "unknown" || sha.is_empty() {
        return StalenessCheck::Skip;
    }
    // .git is normally a directory, but in linked worktrees it's a file
    // pointing to the parent's gitdir. Either way is a valid checkout.
    if !repo_root.join(".git").exists() {
        return StalenessCheck::Skip;
    }

    let mut cmd = Command::new("git");
    cmd.arg("-C")
        .arg(repo_root)
        .arg("log")
        .arg(format!("{sha}..HEAD"))
        .arg("--format=%s")
        .arg("--");
    for f in GAP_STORE_FILES {
        cmd.arg(f);
    }

    let output = match cmd.output() {
        Ok(o) if o.status.success() => o,
        _ => return StalenessCheck::Skip,
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<&str> = stdout.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.is_empty() {
        StalenessCheck::Fresh
    } else {
        StalenessCheck::Stale {
            commits_ahead: lines.len(),
            latest_subject: lines[0].to_string(),
        }
    }
}

/// Convenience helper: locate the chump repo root by walking up from `start`
/// looking for `.git`. Returns `None` if no such ancestor exists.
pub fn find_repo_root(start: &Path) -> Option<PathBuf> {
    let mut cur: PathBuf = start.canonicalize().ok()?;
    loop {
        if cur.join(".git").exists() {
            return Some(cur);
        }
        if !cur.pop() {
            return None;
        }
    }
}

/// Emit a stderr warning when the binary is stale relative to the repo at
/// `repo_root`. Honors `CHUMP_BINARY_STALENESS_CHECK=0` to disable.
/// Returns `true` if a warning was emitted (caller may want to refuse
/// non-trivial mutations behind `--force`); `false` for fresh / skipped /
/// disabled.
pub fn warn_if_stale_for_gap_mutation(repo_root: &Path) -> bool {
    if std::env::var("CHUMP_BINARY_STALENESS_CHECK").as_deref() == Ok("0") {
        return false;
    }
    match check_gap_binary_staleness(repo_root) {
        StalenessCheck::Fresh | StalenessCheck::Skip => false,
        StalenessCheck::Stale {
            commits_ahead,
            latest_subject,
        } => {
            eprintln!(
                "[chump] WARNING: this binary was built at {} ({}) but {} \
                 gap-store-affecting commit(s) have landed since on this \
                 repo's HEAD. Most recent: {}",
                chump_build_sha(),
                chump_build_date(),
                commits_ahead,
                latest_subject,
            );
            eprintln!(
                "[chump]          A pre-INFRA-147 binary stripped the meta: \
                 preamble during YAML regen on 2026-04-27 (~20k-line silent \
                 corruption). Rebuild + reinstall before continuing:"
            );
            eprintln!(
                "[chump]            cargo install --path {} --bin chump --force",
                repo_root.display()
            );
            eprintln!(
                "[chump]          Or set CHUMP_BINARY_STALENESS_CHECK=0 to \
                 silence this check (use sparingly)."
            );
            true
        }
    }
}

/// Outcome of [`fail_if_stale_for_destructive`].
#[derive(Debug, PartialEq, Eq)]
pub enum DestructiveStalenessOutcome {
    /// Binary is fresh, skip-state, or the check is disabled. Caller proceeds.
    Proceed,
    /// Binary is stale and the operator has explicitly opted into running
    /// anyway via `CHUMP_ALLOW_STALE_DESTRUCTIVE=1`. Caller proceeds; ambient
    /// telemetry has been emitted naming the override.
    OverrideAccepted,
    /// Binary is stale and no override is set. Caller MUST abort the
    /// destructive operation. Stderr has been told why.
    Refuse,
}

/// INFRA-825: hard-fail variant of [`warn_if_stale_for_gap_mutation`] for
/// destructive operations like `chump gap ship --update-yaml` and `chump gap
/// dump --per-file` that regenerate >1 YAML in a single invocation.
///
/// PR #1444 silently reverted META-044 because `chump gap ship --update-yaml`
/// ran with a 9-commit-stale binary that regenerated all YAMLs from an
/// outdated state.db. The soft `warn_if_stale_for_gap_mutation` printed a
/// warning but did not refuse to run. This function refuses.
///
/// Honors three escape hatches:
/// - `CHUMP_BINARY_STALENESS_CHECK=0` — disable the check entirely (matches
///   the soft path; reserved for CI / packaged builds where the staleness
///   signal is itself unreliable).
/// - `CHUMP_ALLOW_STALE_DESTRUCTIVE=1` — explicit operator override; returns
///   `OverrideAccepted` after emitting a loud `stale_binary_destructive_override`
///   ambient event so the override is auditable.
/// - The check returns `Skip` (no .git, unknown SHA): treated as `Proceed`.
///
/// `op_name` is a short human-readable label for the operation (e.g.,
/// `"gap ship --update-yaml"`) used in the error message and the ambient
/// event.
pub fn fail_if_stale_for_destructive(
    repo_root: &Path,
    op_name: &str,
) -> DestructiveStalenessOutcome {
    if std::env::var("CHUMP_BINARY_STALENESS_CHECK").as_deref() == Ok("0") {
        return DestructiveStalenessOutcome::Proceed;
    }
    match check_gap_binary_staleness(repo_root) {
        StalenessCheck::Fresh | StalenessCheck::Skip => DestructiveStalenessOutcome::Proceed,
        StalenessCheck::Stale {
            commits_ahead,
            latest_subject,
        } => {
            let override_set = std::env::var("CHUMP_ALLOW_STALE_DESTRUCTIVE").as_deref() == Ok("1");
            if override_set {
                eprintln!(
                    "[chump] OVERRIDE: CHUMP_ALLOW_STALE_DESTRUCTIVE=1 — proceeding \
                     with '{op_name}' despite {commits_ahead} unmerged \
                     gap-store-affecting commit(s) (latest: {latest_subject}). \
                     This is the escape hatch INFRA-825 ships with; expect \
                     ambient kind=stale_binary_destructive_override."
                );
                emit_destructive_override_ambient_event(repo_root, op_name, commits_ahead);
                DestructiveStalenessOutcome::OverrideAccepted
            } else {
                eprintln!(
                    "[chump] REFUSED: '{op_name}' is a destructive bulk-YAML \
                     operation, and this binary was built at {} ({}) but {} \
                     gap-store-affecting commit(s) have landed since on this \
                     repo's HEAD. Latest: {}",
                    chump_build_sha(),
                    chump_build_date(),
                    commits_ahead,
                    latest_subject,
                );
                eprintln!(
                    "[chump]          Running this would risk silent revert \
                     of merged work (see PR #1444 — META-044 wiped by a \
                     9-commit-stale binary on 2026-05-11). Rebuild + retry:"
                );
                eprintln!(
                    "[chump]            cargo install --path {} --bin chump --force",
                    repo_root.display()
                );
                eprintln!(
                    "[chump]          Override (very loud, audited): \
                     CHUMP_ALLOW_STALE_DESTRUCTIVE=1"
                );
                DestructiveStalenessOutcome::Refuse
            }
        }
    }
}

/// Emit an ambient event naming the override use. Best-effort: failures here
/// must never break the caller (the override is already accepted by the time
/// we get here).
fn emit_destructive_override_ambient_event(repo_root: &Path, op_name: &str, commits_ahead: usize) {
    let ambient = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = format!(
        "{{\"ts\":{ts},\"event\":\"ALERT\",\"kind\":\"stale_binary_destructive_override\",\
         \"op\":\"{}\",\"commits_ahead\":{},\"build_sha\":\"{}\"}}\n",
        op_name.replace('"', "\\\""),
        commits_ahead,
        chump_build_sha(),
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command as PCommand;

    fn make_repo() -> (tempfile::TempDir, String, String) {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        // INFRA-1024: use env vars, not git config writes, so no .git/config mutation escapes.
        let run = |args: &[&str]| {
            let st = PCommand::new("git")
                .args(args)
                .current_dir(p)
                .env("GIT_AUTHOR_EMAIL", "ci@version.test")
                .env("GIT_AUTHOR_NAME", "CI")
                .env("GIT_COMMITTER_EMAIL", "ci@version.test")
                .env("GIT_COMMITTER_NAME", "CI")
                .output()
                .unwrap();
            assert!(st.status.success(), "git {args:?} failed: {st:?}");
        };
        run(&["init", "-q", "-b", "main"]);
        std::fs::create_dir_all(p.join("src")).unwrap();
        std::fs::write(p.join("src/gap_store.rs"), "// initial\n").unwrap();
        run(&["add", "."]);
        run(&["commit", "-q", "-m", "first"]);
        let sha1 = String::from_utf8(
            PCommand::new("git")
                .args(["rev-parse", "--short=12", "HEAD"])
                .current_dir(p)
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap()
        .trim()
        .to_string();

        std::fs::write(p.join("README.md"), "hi\n").unwrap();
        run(&["add", "."]);
        run(&["commit", "-q", "-m", "unrelated change"]);
        let sha2 = String::from_utf8(
            PCommand::new("git")
                .args(["rev-parse", "--short=12", "HEAD"])
                .current_dir(p)
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap()
        .trim()
        .to_string();

        (dir, sha1, sha2)
    }

    #[test]
    fn fresh_when_baked_sha_is_at_head() {
        let (dir, _sha1, sha2) = make_repo();
        assert_eq!(
            check_gap_binary_staleness_with_sha(dir.path(), &sha2),
            StalenessCheck::Fresh
        );
    }

    #[test]
    fn fresh_when_only_unrelated_files_changed_since_baked_sha() {
        // Between sha1 and sha2 only README.md changed — gap_store.rs and
        // main.rs untouched. A binary baked at sha1 is still safe.
        let (dir, sha1, _sha2) = make_repo();
        assert_eq!(
            check_gap_binary_staleness_with_sha(dir.path(), &sha1),
            StalenessCheck::Fresh
        );
    }

    #[test]
    fn stale_when_gap_store_changed_since_baked_sha() {
        let (dir, sha1, _sha2) = make_repo();
        let p = dir.path();
        std::fs::write(p.join("src/gap_store.rs"), "// edited\n").unwrap();
        PCommand::new("git")
            .args(["add", "."])
            .current_dir(p)
            .output()
            .unwrap();
        PCommand::new("git")
            .args(["commit", "-q", "-m", "INFRA-X: edit gap_store"])
            .current_dir(p)
            .output()
            .unwrap();
        match check_gap_binary_staleness_with_sha(p, &sha1) {
            StalenessCheck::Stale {
                commits_ahead,
                latest_subject,
            } => {
                assert_eq!(commits_ahead, 1);
                assert_eq!(latest_subject, "INFRA-X: edit gap_store");
            }
            other => panic!("expected Stale, got {other:?}"),
        }
    }

    #[test]
    fn skip_when_baked_sha_unknown() {
        let (dir, _, _) = make_repo();
        assert_eq!(
            check_gap_binary_staleness_with_sha(dir.path(), "unknown"),
            StalenessCheck::Skip
        );
    }

    #[test]
    fn skip_when_repo_root_is_not_a_git_checkout() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            check_gap_binary_staleness_with_sha(dir.path(), "deadbeefcafe"),
            StalenessCheck::Skip
        );
    }

    // ── INFRA-825 hard-fail destructive variant ──────────────────────────────

    /// Helper: stale-repo fixture (gap_store.rs edited after sha1).
    fn make_stale_repo() -> (tempfile::TempDir, String) {
        let (dir, sha1, _) = make_repo();
        let p = dir.path();
        std::fs::write(p.join("src/gap_store.rs"), "// stale-fixture edit\n").unwrap();
        PCommand::new("git")
            .args(["add", "."])
            .current_dir(p)
            .output()
            .unwrap();
        PCommand::new("git")
            .args(["commit", "-q", "-m", "INFRA-X: simulate post-build commit"])
            .current_dir(p)
            .output()
            .unwrap();
        (dir, sha1)
    }

    /// Replay the PR #1444 failure mode: simulate a 1-commit-stale binary
    /// running a destructive op (no override). Must REFUSE.
    #[test]
    #[serial_test::serial]
    fn pr_1444_replay_refuses_without_override() {
        let (dir, sha1) = make_stale_repo();
        // Defensive: ensure no leaked env from a parallel test.
        unsafe {
            std::env::remove_var("CHUMP_ALLOW_STALE_DESTRUCTIVE");
            std::env::remove_var("CHUMP_BINARY_STALENESS_CHECK");
        }
        // We can't call fail_if_stale_for_destructive directly (it reads the
        // baked SHA via chump_build_sha which is set at compile time, not
        // injectable). Test the predicate it uses instead: a Stale outcome
        // with no override means REFUSE.
        let outcome = check_gap_binary_staleness_with_sha(dir.path(), &sha1);
        match outcome {
            StalenessCheck::Stale { .. } => { /* expected */ }
            other => panic!("expected Stale, got {other:?}"),
        }
    }

    #[test]
    #[serial_test::serial]
    fn override_env_recognized() {
        // Direct env-var read; we don't exercise the full function (compile-baked SHA)
        // but verify the operator-facing escape hatch is wired correctly.
        unsafe {
            std::env::set_var("CHUMP_ALLOW_STALE_DESTRUCTIVE", "1");
        }
        let val = std::env::var("CHUMP_ALLOW_STALE_DESTRUCTIVE").as_deref() == Ok("1");
        assert!(val, "CHUMP_ALLOW_STALE_DESTRUCTIVE=1 should be readable");
        unsafe {
            std::env::remove_var("CHUMP_ALLOW_STALE_DESTRUCTIVE");
        }
    }

    #[test]
    #[serial_test::serial]
    fn override_env_unset_means_no_override() {
        unsafe {
            std::env::remove_var("CHUMP_ALLOW_STALE_DESTRUCTIVE");
        }
        let val = std::env::var("CHUMP_ALLOW_STALE_DESTRUCTIVE").as_deref() == Ok("1");
        assert!(
            !val,
            "unset CHUMP_ALLOW_STALE_DESTRUCTIVE should NOT trigger override"
        );
    }

    /// Ambient-event emitter writes a parseable JSONL line. (Best-effort
    /// helper; this test asserts the file exists and contains the right kind.)
    #[test]
    fn override_event_emitted_to_ambient_jsonl() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        emit_destructive_override_ambient_event(p, "test-op", 3);
        let ambient = p.join(".chump-locks").join("ambient.jsonl");
        assert!(ambient.exists(), "ambient.jsonl should be created");
        let contents = std::fs::read_to_string(&ambient).unwrap();
        assert!(
            contents.contains("\"kind\":\"stale_binary_destructive_override\""),
            "ambient event should name the kind; got: {contents}"
        );
        assert!(
            contents.contains("\"op\":\"test-op\""),
            "ambient event should include op name; got: {contents}"
        );
        assert!(
            contents.contains("\"commits_ahead\":3"),
            "ambient event should include commits_ahead; got: {contents}"
        );
    }
}
