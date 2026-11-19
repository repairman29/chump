//! Rust-native `pre-commit` hook context and guards (Milestone 3).
//!
//! Provides [`PreCommitContext`] (with `ENV_LEAK_VARS` scrubbing), the
//! [`PreCommitHook`] trait, and concrete cross-platform guards:
//! - [`LeaseCollisionGuard`] (via `chump-agent-lease`)
//! - [`SecretPatternGuard`] (high-signal token prefix scanner, INFRA-7880 value-withheld)
//! - [`SubmoduleSanityGuard`] (`160000` gitlink vs `.gitmodules` validator, INFRA-018)
//! - [`BookSyncGuard`] (`docs/process/*.md` <-> `book/src/*.md` drift detector, INFRA-170)
//! - [`RustFmtGuard`] (optional `cargo fmt --all -- --check` gate)

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use chrono::Utc;
use chump_agent_lease::{current_session_id, Lease};

use crate::{BlockReason, HookError, HookOutcome, ENV_LEAK_VARS};

/// Per-invocation context for the `pre-commit` hook.
#[derive(Debug, Clone)]
pub struct PreCommitContext {
    /// Canonical repository root discovered via env-scrubbed `git rev-parse --show-toplevel`.
    pub repo_root: PathBuf,
    /// Staged repo-relative file paths (`git diff --cached --name-only --diff-filter=ACMR`).
    pub staged_files: Vec<String>,
}

impl PreCommitContext {
    /// Discover repository root after scrubbing [`ENV_LEAK_VARS`] from the current
    /// process and load staged file paths from the index.
    pub fn new() -> Result<Self, HookError> {
        for var in ENV_LEAK_VARS {
            std::env::remove_var(var);
        }
        let output = Command::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .output()?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(HookError::RepoDiscoveryFailed(stderr));
        }
        let root = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
        Self::from_explicit_root(root)
    }

    /// Construct a [`PreCommitContext`] anchored to an explicit `repo_root` without
    /// mutating process-global environment variables (safe for parallel tests).
    pub fn from_explicit_root(repo_root: impl AsRef<Path>) -> Result<Self, HookError> {
        let repo_root = repo_root.as_ref().to_path_buf();
        let mut cmd = Command::new("git");
        for var in ENV_LEAK_VARS {
            cmd.env_remove(var);
        }
        let out = cmd
            .arg("-C")
            .arg(&repo_root)
            .args(["diff", "--cached", "--name-only", "--diff-filter=ACMR"])
            .output()?;
        let staged_files = if out.status.success() {
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(|l| l.replace('\\', "/"))
                .collect()
        } else {
            Vec::new()
        };
        Ok(Self {
            repo_root,
            staged_files,
        })
    }

    /// Return a `git` [`Command`] anchored to `self.repo_root` with [`ENV_LEAK_VARS`] removed.
    pub fn git(&self) -> Command {
        let mut cmd = Command::new("git");
        for var in ENV_LEAK_VARS {
            cmd.env_remove(var);
        }
        cmd.arg("-C").arg(&self.repo_root);
        cmd
    }

    /// Read the staged index blob (`:<repo_rel_path>`) for a file, returning
    /// `Ok(None)` if the entry is not a regular blob (e.g. gitlink or deleted).
    pub fn staged_blob(&self, repo_rel_path: &str) -> Result<Option<Vec<u8>>, HookError> {
        let spec = format!(":{repo_rel_path}");
        let out = self.git().args(["show", &spec]).output()?;
        if !out.status.success() {
            return Ok(None);
        }
        Ok(Some(out.stdout))
    }

    /// Return the added lines (`+...`, excluding `+++` file headers) staged for
    /// `repo_rel_path` via `git diff --cached -U0 -- <repo_rel_path>`.
    pub fn staged_added_lines(&self, repo_rel_path: &str) -> Result<String, HookError> {
        let out = self
            .git()
            .args(["diff", "--cached", "-U0", "--", repo_rel_path])
            .output()?;
        if !out.status.success() {
            return Ok(String::new());
        }
        let raw = String::from_utf8_lossy(&out.stdout);
        let mut added = String::new();
        for line in raw.lines() {
            if let Some(stripped) = line.strip_prefix('+') {
                if !line.starts_with("+++ ") {
                    added.push_str(stripped);
                    added.push('\n');
                }
            }
        }
        Ok(added)
    }
}

/// Trait implemented by every guard in the `pre-commit` chain.
pub trait PreCommitHook {
    /// Stable guard identifier for logs and diagnostics.
    fn name(&self) -> &'static str;

    /// Evaluate the guard against [`PreCommitContext`].
    fn run(&self, ctx: &PreCommitContext) -> Result<HookOutcome, HookError>;
}

/// Run a chain of [`PreCommitHook`] guards, short-circuiting on the first [`HookOutcome::Block`].
pub fn run_pre_commit_hooks(
    ctx: &PreCommitContext,
    hooks: &[Box<dyn PreCommitHook>],
) -> Result<HookOutcome, HookError> {
    if env_truthy("CHUMP_OPERATOR_RECOVERY") {
        return Ok(HookOutcome::Skipped {
            reason: "CHUMP_OPERATOR_RECOVERY=1".to_string(),
        });
    }
    for hook in hooks {
        match hook.run(ctx)? {
            HookOutcome::Pass => tracing::debug!(hook = hook.name(), "pass"),
            HookOutcome::Skipped { reason } => {
                tracing::debug!(hook = hook.name(), %reason, "skipped");
            }
            HookOutcome::Block(reason) => {
                tracing::warn!(hook = hook.name(), code = %reason.code, "blocked");
                return Ok(HookOutcome::Block(reason));
            }
        }
    }
    Ok(HookOutcome::Pass)
}

fn env_disabled(var: &str) -> bool {
    std::env::var(var).map(|v| v.trim() == "0").unwrap_or(false)
}

fn env_truthy(var: &str) -> bool {
    std::env::var(var)
        .map(|v| {
            let t = v.trim();
            t == "1" || t.eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

/// Guard 1: Path-lease collision detector backed by [`chump_agent_lease::Lease`].
///
/// Rejects commits that touch a staged file covered by another session's live
/// `.chump-locks/*.json` lease. Bypass with `CHUMP_LEASE_CHECK=0` or
/// `CHUMP_OPERATOR_RECOVERY=1`.
pub struct LeaseCollisionGuard {
    /// Optional explicit session ID override (defaults to [`current_session_id`]).
    pub session_id_override: Option<String>,
}

impl LeaseCollisionGuard {
    /// Construct a [`LeaseCollisionGuard`] using [`current_session_id`].
    pub fn new() -> Self {
        Self {
            session_id_override: None,
        }
    }

    /// Construct a [`LeaseCollisionGuard`] with an explicit session ID (for hermetic tests).
    pub fn with_session_id(session_id: impl Into<String>) -> Self {
        Self {
            session_id_override: Some(session_id.into()),
        }
    }
}

impl Default for LeaseCollisionGuard {
    fn default() -> Self {
        Self::new()
    }
}

impl PreCommitHook for LeaseCollisionGuard {
    fn name(&self) -> &'static str {
        "lease_collision_guard"
    }

    fn run(&self, ctx: &PreCommitContext) -> Result<HookOutcome, HookError> {
        if env_disabled("CHUMP_LEASE_CHECK") {
            return Ok(HookOutcome::Skipped {
                reason: "CHUMP_LEASE_CHECK=0".to_string(),
            });
        }
        if ctx.staged_files.is_empty() {
            return Ok(HookOutcome::Pass);
        }
        let locks_dir = ctx.repo_root.join(".chump-locks");
        let Ok(entries) = fs::read_dir(&locks_dir) else {
            return Ok(HookOutcome::Pass);
        };

        let my_session = self
            .session_id_override
            .clone()
            .unwrap_or_else(current_session_id);
        let now = Utc::now();

        let mut active_other_leases: Vec<Lease> = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Ok(raw) = fs::read_to_string(&path) else {
                continue;
            };
            let Ok(lease) = serde_json::from_str::<Lease>(&raw) else {
                continue;
            };
            if lease.session_id != my_session && lease.is_live(now) {
                active_other_leases.push(lease);
            }
        }

        for staged in &ctx.staged_files {
            for lease in &active_other_leases {
                if lease.covers(staged) {
                    let diagnostic = format!(
                        "LEASE CONFLICT: staged file `{staged}` is claimed by active session `{holder}`.\n\
                         Options:\n\
                         - Coordinate with `{holder}` or wait for lease expiry\n\
                         - Bypass: CHUMP_LEASE_CHECK=0 (or CHUMP_OPERATOR_RECOVERY=1) git commit",
                        holder = lease.session_id
                    );
                    return Ok(HookOutcome::Block(BlockReason {
                        code: "lease_collision".to_string(),
                        diagnostic,
                    }));
                }
            }
        }

        Ok(HookOutcome::Pass)
    }
}

/// Guard 2: High-confidence live credential scanner (`INFRA-018` / `INFRA-7880`).
///
/// Scans staged files for live API-key / token prefixes while skipping markdown
/// documentation and explicit fixture paths. Never echoes the matched secret
/// value (`value withheld`). Bypass with `CHUMP_CREDENTIAL_CHECK=0`.
pub struct SecretPatternGuard;

impl SecretPatternGuard {
    /// Inspect `content` of `repo_rel_path` and return `Some(key_family)` if a
    /// live-shaped token prefix is present and the path is not a doc/fixture file.
    pub fn scan_text(repo_rel_path: &str, content: &str) -> Option<&'static str> {
        if is_doc_or_fixture_path(repo_rel_path) {
            return None;
        }
        for line in content.lines() {
            if let Some(family) = scan_line_for_secret(line) {
                return Some(family);
            }
        }
        None
    }
}

fn is_doc_or_fixture_path(path: &str) -> bool {
    let p = path.replace('\\', "/");
    let lower = p.to_ascii_lowercase();
    lower.starts_with("docs/")
        || lower.starts_with("book/")
        || lower.ends_with(".md")
        || lower.contains("fixture")
        || lower.starts_with("scripts/ci/test-")
        || lower.starts_with("scripts/archived/")
}

fn count_token_body(s: &str, allow_underscore_dash: bool) -> usize {
    s.chars()
        .take_while(|c| {
            c.is_ascii_alphanumeric() || (allow_underscore_dash && (*c == '_' || *c == '-'))
        })
        .count()
}

fn scan_line_for_secret(line: &str) -> Option<&'static str> {
    let prefixes: &[(&str, &'static str, usize, bool)] = &[
        ("sk-ant-", "Anthropic API key", 24, true),
        ("sk-proj-", "OpenAI project key", 24, true),
        ("tgp_v1_", "Together API key", 24, true),
        ("AIzaSy", "Google API key", 30, true),
        ("ghp_", "GitHub personal access token", 30, false),
        ("gho_", "GitHub OAuth token", 30, false),
        ("github_pat_", "GitHub fine-grained PAT", 30, true),
    ];
    for &(prefix, family, min_tail, allow_ud) in prefixes {
        let mut rest = line;
        while let Some(idx) = rest.find(prefix) {
            let after = &rest[idx + prefix.len()..];
            let tail_len = count_token_body(after, allow_ud);
            if tail_len >= min_tail {
                let candidate_tail = &after[..tail_len];
                // Ignore obvious placeholder strings like `sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx`
                if !is_placeholder_tail(candidate_tail) {
                    return Some(family);
                }
            }
            rest = after;
        }
    }

    // AWS access key ID: AKIA + 16 uppercase alphanumeric chars (excluding AWS example key).
    let mut rest = line;
    while let Some(idx) = rest.find("AKIA") {
        let after = &rest[idx + 4..];
        let tail_len = after
            .chars()
            .take_while(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
            .count();
        if tail_len >= 16 {
            let full = &rest[idx..idx + 20];
            if full != "AKIAIOSFODNN7EXAMPLE" && !is_placeholder_tail(&after[..16]) {
                return Some("AWS access key ID");
            }
        }
        rest = after;
    }

    None
}

fn is_placeholder_tail(tail: &str) -> bool {
    let lower = tail.to_ascii_lowercase();
    if lower.contains("example") || lower.contains("placeholder") || lower.contains("redacted") {
        return true;
    }
    let mut chars = lower.chars();
    let Some(first) = chars.next() else {
        return true;
    };
    chars.all(|c| c == first)
}

impl PreCommitHook for SecretPatternGuard {
    fn name(&self) -> &'static str {
        "secret_pattern_guard"
    }

    fn run(&self, ctx: &PreCommitContext) -> Result<HookOutcome, HookError> {
        if env_disabled("CHUMP_CREDENTIAL_CHECK") {
            return Ok(HookOutcome::Skipped {
                reason: "CHUMP_CREDENTIAL_CHECK=0".to_string(),
            });
        }
        for path in &ctx.staged_files {
            if is_doc_or_fixture_path(path) {
                continue;
            }
            let content = ctx.staged_added_lines(path)?;
            if content.is_empty() {
                continue;
            }
            if let Some(family) = Self::scan_text(path, &content) {
                // INFRA-7880: NEVER include the matched secret value in diagnostic output.
                let diagnostic = format!(
                    "Credential pattern detected ({family}, value withheld)\n  \
                     in: {path}\n\
                     Remove the credential from staged changes or bypass with CHUMP_CREDENTIAL_CHECK=0."
                );
                return Ok(HookOutcome::Block(BlockReason {
                    code: "secret_pattern_detected".to_string(),
                    diagnostic,
                }));
            }
        }
        Ok(HookOutcome::Pass)
    }
}

/// Guard 3: Submodule gitlink sanity guard (`INFRA-018` / `INFRA-158`).
///
/// Verifies every staged `160000` gitlink entry in `git ls-files --stage` has
/// a matching `path = <gitlink>` declaration in `.gitmodules`. Bypass with
/// `CHUMP_SUBMODULE_CHECK=0`.
pub struct SubmoduleSanityGuard;

impl PreCommitHook for SubmoduleSanityGuard {
    fn name(&self) -> &'static str {
        "submodule_sanity_guard"
    }

    fn run(&self, ctx: &PreCommitContext) -> Result<HookOutcome, HookError> {
        if env_disabled("CHUMP_SUBMODULE_CHECK") {
            return Ok(HookOutcome::Skipped {
                reason: "CHUMP_SUBMODULE_CHECK=0".to_string(),
            });
        }
        let has_head = ctx
            .git()
            .args(["rev-parse", "--verify", "HEAD"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        let mut gitlinks: Vec<String> = Vec::new();
        if has_head {
            let out = ctx.git().args(["diff", "--cached", "--raw"]).output()?;
            if !out.status.success() {
                return Ok(HookOutcome::Pass);
            }
            let stdout = String::from_utf8_lossy(&out.stdout);
            for line in stdout.lines() {
                // Format: `:<old_mode> <new_mode> <old_sha> <new_sha> <status>\t<path>`
                let Some((meta, path)) = line.split_once('\t') else {
                    continue;
                };
                let mut parts = meta.trim_start_matches(':').split_whitespace();
                let _old_mode = parts.next().unwrap_or("");
                let new_mode = parts.next().unwrap_or("");
                if new_mode == "160000" {
                    gitlinks.push(path.trim().replace('\\', "/"));
                }
            }
        } else {
            let out = ctx.git().args(["ls-files", "--stage"]).output()?;
            if !out.status.success() {
                return Ok(HookOutcome::Pass);
            }
            let stdout = String::from_utf8_lossy(&out.stdout);
            for line in stdout.lines() {
                let Some((meta, path)) = line.split_once('\t') else {
                    continue;
                };
                let mode = meta.split_whitespace().next().unwrap_or("");
                if mode == "160000" {
                    gitlinks.push(path.trim().replace('\\', "/"));
                }
            }
        }
        if gitlinks.is_empty() {
            return Ok(HookOutcome::Pass);
        }

        let gitmodules_raw = if let Some(staged) = ctx.staged_blob(".gitmodules")? {
            String::from_utf8_lossy(&staged).into_owned()
        } else {
            fs::read_to_string(ctx.repo_root.join(".gitmodules")).unwrap_or_default()
        };
        let declared_paths = parse_gitmodules_paths(&gitmodules_raw);

        for link in gitlinks {
            if !declared_paths.contains(&link) {
                let diagnostic = format!(
                    "Dangling gitlink (mode 160000) `{link}` has no matching `path = {link}` entry in .gitmodules.\n\
                     Either register the submodule in .gitmodules or remove the gitlink (`git rm --cached {link}`).\n\
                     Bypass: CHUMP_SUBMODULE_CHECK=0"
                );
                return Ok(HookOutcome::Block(BlockReason {
                    code: "dangling_gitlink".to_string(),
                    diagnostic,
                }));
            }
        }
        Ok(HookOutcome::Pass)
    }
}

fn parse_gitmodules_paths(raw: &str) -> HashSet<String> {
    let mut set = HashSet::new();
    for line in raw.lines() {
        let trimmed = line.trim();
        if let Some((k, v)) = trimmed.split_once('=') {
            if k.trim() == "path" {
                set.insert(v.trim().replace('\\', "/"));
            }
        }
    }
    set
}

/// Guard 4: `docs/process/*.md` <-> `book/src/*.md` sync guard (`INFRA-170`).
///
/// When `book/src/` exists in the repository and a commit stages changes under
/// `docs/process/<name>.md`, verifies `book/src/<name>.md` matches the staged
/// source-of-truth document. Bypass with `CHUMP_BOOK_SYNC_CHECK=0`.
pub struct BookSyncGuard;

impl PreCommitHook for BookSyncGuard {
    fn name(&self) -> &'static str {
        "book_sync_guard"
    }

    fn run(&self, ctx: &PreCommitContext) -> Result<HookOutcome, HookError> {
        if env_disabled("CHUMP_BOOK_SYNC_CHECK") {
            return Ok(HookOutcome::Skipped {
                reason: "CHUMP_BOOK_SYNC_CHECK=0".to_string(),
            });
        }
        if !ctx.repo_root.join("book/src").is_dir() {
            return Ok(HookOutcome::Pass);
        }
        for staged in &ctx.staged_files {
            let Some(fname) = staged.strip_prefix("docs/process/") else {
                continue;
            };
            if fname.contains('/') || !fname.ends_with(".md") {
                continue;
            }
            let Some(src_bytes) = ctx.staged_blob(staged)? else {
                continue;
            };
            let mirror_rel = format!("book/src/{fname}");
            let mirror_disk = ctx.repo_root.join(&mirror_rel);
            let mirror_bytes = match ctx.staged_blob(&mirror_rel)? {
                Some(b) => Some(b),
                None => fs::read(&mirror_disk).ok(),
            };
            if mirror_bytes.as_deref() != Some(src_bytes.as_slice()) {
                // Auto-sync the working-tree mirror so the caller only needs `git add book/`.
                let _ = fs::write(&mirror_disk, &src_bytes);
                let diagnostic = format!(
                    "`{staged}` drifted from `{mirror_rel}` (mirror updated on disk; stage `{mirror_rel}` and retry).\n\
                     Bypass with CHUMP_BOOK_SYNC_CHECK=0."
                );
                return Ok(HookOutcome::Block(BlockReason {
                    code: "book_sync_drift".to_string(),
                    diagnostic,
                }));
            }
        }
        Ok(HookOutcome::Pass)
    }
}

/// Guard 5: Optional `cargo fmt --all -- --check` guard for staged `.rs` files.
///
/// Enabled when `enabled_by_default` is `true` or `CHUMP_FMT_CHECK=1` is set;
/// skipped when `CHUMP_FMT_CHECK=0` or when no `.rs` files are staged.
pub struct RustFmtGuard {
    /// Whether `cargo fmt --check` runs even when `CHUMP_FMT_CHECK` is unset.
    pub enabled_by_default: bool,
}

impl RustFmtGuard {
    /// Opt-in guard (runs when `CHUMP_FMT_CHECK=1`).
    pub fn opt_in() -> Self {
        Self {
            enabled_by_default: false,
        }
    }

    /// Strict guard (runs by default unless `CHUMP_FMT_CHECK=0`).
    pub fn strict() -> Self {
        Self {
            enabled_by_default: true,
        }
    }
}

impl PreCommitHook for RustFmtGuard {
    fn name(&self) -> &'static str {
        "rust_fmt_guard"
    }

    fn run(&self, ctx: &PreCommitContext) -> Result<HookOutcome, HookError> {
        if env_disabled("CHUMP_FMT_CHECK") {
            return Ok(HookOutcome::Skipped {
                reason: "CHUMP_FMT_CHECK=0".to_string(),
            });
        }
        if !self.enabled_by_default && !env_truthy("CHUMP_FMT_CHECK") {
            return Ok(HookOutcome::Skipped {
                reason: "opt-in (set CHUMP_FMT_CHECK=1 to enforce)".to_string(),
            });
        }
        if !ctx.staged_files.iter().any(|f| f.ends_with(".rs"))
            || !ctx.repo_root.join("Cargo.toml").is_file()
        {
            return Ok(HookOutcome::Pass);
        }

        let mut cmd = Command::new("cargo");
        for var in ENV_LEAK_VARS {
            cmd.env_remove(var);
        }
        let out = cmd
            .current_dir(&ctx.repo_root)
            .args(["fmt", "--all", "--", "--check"])
            .output()?;
        if !out.status.success() {
            return Ok(HookOutcome::Block(BlockReason {
                code: "rust_fmt_drift".to_string(),
                diagnostic:
                    "Staged Rust files are not formatted (`cargo fmt --all -- --check` failed).\n\
                     Run `cargo fmt --all` and re-stage, or bypass with CHUMP_FMT_CHECK=0."
                        .to_string(),
            }));
        }
        Ok(HookOutcome::Pass)
    }
}

/// Assemble the default cross-platform `pre-commit` guard chain.
pub fn default_pre_commit_chain() -> Vec<Box<dyn PreCommitHook>> {
    vec![
        Box::new(LeaseCollisionGuard::new()),
        Box::new(SubmoduleSanityGuard),
        Box::new(SecretPatternGuard),
        Box::new(BookSyncGuard),
        Box::new(RustFmtGuard::opt_in()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration as ChronoDuration, SecondsFormat};
    use tempfile::TempDir;

    fn init_sandbox() -> TempDir {
        let tmp = TempDir::new().unwrap();
        let run = |args: &[&str]| {
            let mut c = Command::new("git");
            for v in ENV_LEAK_VARS {
                c.env_remove(v);
            }
            let st = c.arg("-C").arg(tmp.path()).args(args).status().unwrap();
            assert!(st.success(), "git {args:?} failed");
        };
        run(&["init", "-b", "main"]);
        run(&["config", "user.email", "t@chump.local"]);
        run(&["config", "user.name", "Chump Test"]);
        fs::write(tmp.path().join("README.md"), "seed\n").unwrap();
        run(&["add", "README.md"]);
        run(&["commit", "-m", "seed"]);
        tmp
    }

    #[test]
    fn lease_collision_guard_blocks_other_session_and_allows_self() {
        let tmp = init_sandbox();
        fs::create_dir_all(tmp.path().join("src")).unwrap();
        fs::write(tmp.path().join("src/owned.rs"), "pub fn a() {}\n").unwrap();
        Command::new("git")
            .arg("-C")
            .arg(tmp.path())
            .args(["add", "src/owned.rs"])
            .status()
            .unwrap();

        let locks = tmp.path().join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();
        let now = Utc::now();
        let lease = Lease {
            session_id: "peer-agent-1".to_string(),
            paths: vec!["src/".to_string()],
            taken_at: now.to_rfc3339_opts(SecondsFormat::Secs, true),
            expires_at: (now + ChronoDuration::minutes(20))
                .to_rfc3339_opts(SecondsFormat::Secs, true),
            heartbeat_at: now.to_rfc3339_opts(SecondsFormat::Secs, true),
            purpose: "editing src".to_string(),
            worktree: String::new(),
            gap_id: None,
            pending_new_gap: None,
            branch: None,
        };
        fs::write(
            locks.join("peer-agent-1.json"),
            serde_json::to_vec_pretty(&lease).unwrap(),
        )
        .unwrap();

        let ctx = PreCommitContext::from_explicit_root(tmp.path()).unwrap();
        let blocked = LeaseCollisionGuard::with_session_id("my-session")
            .run(&ctx)
            .unwrap();
        match blocked {
            HookOutcome::Block(r) => {
                assert_eq!(r.code, "lease_collision");
                assert!(r.diagnostic.contains("LEASE CONFLICT"));
                assert!(r.diagnostic.contains("peer-agent-1"));
            }
            other => panic!("expected Block, got {other:?}"),
        }

        // Same session owning the lease passes!
        let allowed = LeaseCollisionGuard::with_session_id("peer-agent-1")
            .run(&ctx)
            .unwrap();
        assert_eq!(allowed, HookOutcome::Pass);
    }

    #[test]
    fn secret_pattern_guard_catches_tokens_without_echoing_and_skips_docs() {
        let fake_tok = format!("sk-ant-{}", "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5");
        let code = format!("const KEY: &str = \"{fake_tok}\";\n");

        // Docs and fixtures must not false-positive.
        assert_eq!(SecretPatternGuard::scan_text("docs/AUTH.md", &code), None);
        assert_eq!(
            SecretPatternGuard::scan_text("tests/fixtures/sample.txt", &code),
            None
        );

        // Source code must trigger!
        assert_eq!(
            SecretPatternGuard::scan_text("src/lib.rs", &code),
            Some("Anthropic API key")
        );

        let tmp = init_sandbox();
        fs::create_dir_all(tmp.path().join("src")).unwrap();
        fs::write(tmp.path().join("src/lib.rs"), &code).unwrap();
        Command::new("git")
            .arg("-C")
            .arg(tmp.path())
            .args(["add", "src/lib.rs"])
            .status()
            .unwrap();

        let ctx = PreCommitContext::from_explicit_root(tmp.path()).unwrap();
        let outcome = SecretPatternGuard.run(&ctx).unwrap();
        match outcome {
            HookOutcome::Block(r) => {
                assert!(r.diagnostic.contains("value withheld"));
                assert!(r.diagnostic.contains("in: src/lib.rs"));
                assert!(
                    !r.diagnostic.contains(&fake_tok),
                    "diagnostic must never echo secret value!"
                );
            }
            other => panic!("expected Block, got {other:?}"),
        }
    }

    #[test]
    fn submodule_sanity_guard_blocks_dangling_gitlink_and_passes_registered() {
        let tmp = init_sandbox();
        let head = String::from_utf8_lossy(
            &Command::new("git")
                .arg("-C")
                .arg(tmp.path())
                .args(["rev-parse", "HEAD"])
                .output()
                .unwrap()
                .stdout,
        )
        .trim()
        .to_string();

        Command::new("git")
            .arg("-C")
            .arg(tmp.path())
            .args([
                "update-index",
                "--add",
                "--cacheinfo",
                &format!("160000,{head},vendor-sub"),
            ])
            .status()
            .unwrap();

        let ctx = PreCommitContext::from_explicit_root(tmp.path()).unwrap();
        let blocked = SubmoduleSanityGuard.run(&ctx).unwrap();
        assert!(matches!(blocked, HookOutcome::Block(_)));

        // Register in .gitmodules and stage it -> passes!
        fs::write(
            tmp.path().join(".gitmodules"),
            "[submodule \"vendor-sub\"]\n\tpath = vendor-sub\n\turl = https://example.invalid/x.git\n",
        )
        .unwrap();
        Command::new("git")
            .arg("-C")
            .arg(tmp.path())
            .args(["add", ".gitmodules"])
            .status()
            .unwrap();

        let ctx2 = PreCommitContext::from_explicit_root(tmp.path()).unwrap();
        assert_eq!(SubmoduleSanityGuard.run(&ctx2).unwrap(), HookOutcome::Pass);
    }
}
