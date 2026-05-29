//! Smart reviewer routing for fleet PRs.
//!
//! Marcus M-E (INFRA-1491). Persona-1's Q2 pipeline-tax detail described
//! the breaking pattern: PR finishes CI, but GitHub's notification gets
//! lost in the reviewer's noise. Manual Slack ping required. At fleet
//! scale (20+ PRs in queue) this stalls everything.
//!
//! **This is not AI-assignment.** It's deterministic. Given the files a
//! PR touches, we compute a suggested reviewer set as the union of:
//!
//!   1. **Recent committers** — `git log --since=<window>` over the touched
//!      files; the top-N most-recent unique committers. Default window:
//!      90 days. Default top-N: 3. The intuition: people who touched
//!      this code recently have the context to review it.
//!   2. **CODEOWNERS** — standard GitHub CODEOWNERS file at one of
//!      `CODEOWNERS`, `.github/CODEOWNERS`, or `docs/CODEOWNERS`. Each
//!      pattern → owner mapping is glob-matched against the touched files
//!      and matching owners are unioned in.
//!   3. **Operator override** — `.chump/reviewers.toml` has an
//!      `always_request = ["@gh-login", …]` list that's unioned
//!      unconditionally. For repos where one human always wants eyes on
//!      every PR regardless of file touched.
//!
//! The result is deduplicated and capped at `max_reviewers` (default 5)
//! so we don't ping ten people on a one-file fix.
//!
//! ## Event registry
//!   scanner-anchor: "kind":"reviewer_routing_computed" emitted by this crate (INFRA-1491)
//!   scanner-anchor: "kind":"reviewer_routing_requested" emitted by this crate (INFRA-1491)

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Per-repo reviewer-routing config persisted at `.chump/reviewers.toml`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewerConfig {
    /// Unconditional reviewers — added to every PR regardless of files
    /// touched. Use sparingly (e.g. release-manager who needs sign-off on
    /// every change to a regulated repo).
    #[serde(default)]
    pub always_request: Vec<String>,

    /// Slack handle ↔ GitHub login mapping. Only consulted by callers
    /// that send Slack notifications; library doesn't dispatch directly.
    /// Shape: `slack_to_github = { "@marcus" = "marcus-gh-login" }`.
    #[serde(default)]
    pub slack_to_github: std::collections::BTreeMap<String, String>,

    /// Reviewers to never auto-request even if they match recent-committer
    /// or CODEOWNERS. Used for bots / departed contributors / vacation.
    #[serde(default)]
    pub exclude: Vec<String>,

    /// Max reviewers to add to a single PR. Default 5.
    #[serde(default = "default_max_reviewers")]
    pub max_reviewers: usize,

    /// Recent-committers lookback window (days). Default 90.
    #[serde(default = "default_recent_window_days")]
    pub recent_window_days: u32,

    /// Top-N most-recent committers to pull from the lookback window.
    /// Default 3.
    #[serde(default = "default_top_n_recent")]
    pub top_n_recent: usize,
}

fn default_max_reviewers() -> usize {
    5
}
fn default_recent_window_days() -> u32 {
    90
}
fn default_top_n_recent() -> usize {
    3
}

impl Default for ReviewerConfig {
    /// Hand-impl Default so usize fields get the sensible defaults
    /// (not `0`, which `#[derive(Default)]` would produce — those zeros
    /// would cap max_reviewers to 0 and silently drop every suggestion).
    /// The serde `default_*` functions only fire during deserialization;
    /// callers that construct a config in code expect these defaults.
    fn default() -> Self {
        Self {
            always_request: Vec::new(),
            slack_to_github: std::collections::BTreeMap::new(),
            exclude: Vec::new(),
            max_reviewers: default_max_reviewers(),
            recent_window_days: default_recent_window_days(),
            top_n_recent: default_top_n_recent(),
        }
    }
}

impl ReviewerConfig {
    /// Read from `<repo>/.chump/reviewers.toml`. Missing file returns
    /// default config (no overrides, sensible thresholds).
    pub fn from_repo_root(repo_root: &Path) -> anyhow::Result<Self> {
        let path = repo_root.join(".chump").join("reviewers.toml");
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = std::fs::read_to_string(&path)?;
        let cfg: ReviewerConfig = toml::from_str(&raw)?;
        Ok(cfg)
    }
}

/// Computed reviewer set with provenance per reviewer. The provenance is
/// kept so the ambient audit event can disclose WHY each reviewer was
/// suggested (recent / codeowners / always-request).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReviewerSet {
    pub reviewers: Vec<ScopedReviewer>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopedReviewer {
    pub login: String,
    pub via: Vec<ReviewerSource>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ReviewerSource {
    RecentCommitter,
    Codeowner,
    OperatorOverride,
}

impl ReviewerSource {
    pub fn as_str(self) -> &'static str {
        match self {
            ReviewerSource::RecentCommitter => "recent_committer",
            ReviewerSource::Codeowner => "codeowner",
            ReviewerSource::OperatorOverride => "operator_override",
        }
    }
}

/// Top-level entry point. Compute the suggested reviewer set for a PR
/// that touched `touched_files`.
///
/// * `repo_root` — repository root (looked up via git in callers)
/// * `touched_files` — repo-relative paths of files this PR changed
/// * `config` — the parsed `ReviewerConfig`
/// * `now_user` — the PR author's GitHub login (filtered out of the
///   result; nobody should be asked to review their own PR)
///
/// Returns the final `ReviewerSet` after deduplication, exclusion, and
/// the `max_reviewers` cap.
pub fn compute_reviewer_set(
    repo_root: &Path,
    touched_files: &[PathBuf],
    config: &ReviewerConfig,
    pr_author: Option<&str>,
) -> anyhow::Result<ReviewerSet> {
    let mut acc: std::collections::BTreeMap<String, BTreeSet<ReviewerSource>> =
        std::collections::BTreeMap::new();

    // (1) Recent committers — git log over the touched paths.
    let recent = recent_committers(
        repo_root,
        touched_files,
        config.recent_window_days,
        config.top_n_recent,
    )?;
    for login in recent {
        acc.entry(login)
            .or_default()
            .insert(ReviewerSource::RecentCommitter);
    }

    // (2) CODEOWNERS.
    let codeowners_rules = read_codeowners(repo_root)?;
    let codeowner_matches = match_codeowners(&codeowners_rules, touched_files);
    for login in codeowner_matches {
        acc.entry(login)
            .or_default()
            .insert(ReviewerSource::Codeowner);
    }

    // (3) Operator override — unconditional.
    for login in &config.always_request {
        acc.entry(login.trim_start_matches('@').to_string())
            .or_default()
            .insert(ReviewerSource::OperatorOverride);
    }

    // Apply exclusions.
    let exclude: BTreeSet<String> = config
        .exclude
        .iter()
        .map(|s| s.trim_start_matches('@').to_string())
        .collect();
    if let Some(author) = pr_author {
        acc.remove(&author.to_string());
        acc.remove(&author.trim_start_matches('@').to_string());
    }
    for ex in &exclude {
        acc.remove(ex);
    }

    // Cap. Stable order: operator overrides first (most intentful), then
    // codeowners, then recent committers. Within each tier, alphabetical.
    let mut reviewers: Vec<ScopedReviewer> = acc
        .into_iter()
        .map(|(login, vias)| ScopedReviewer {
            login,
            via: vias.into_iter().collect(),
        })
        .collect();
    reviewers.sort_by_key(|r| sort_key(&r.via));
    reviewers.truncate(config.max_reviewers);

    Ok(ReviewerSet { reviewers })
}

/// Stable sort key: operator > codeowner > recent. Lower value sorts first.
fn sort_key(vias: &[ReviewerSource]) -> u8 {
    let mut best = 3;
    for v in vias {
        let p = match v {
            ReviewerSource::OperatorOverride => 0,
            ReviewerSource::Codeowner => 1,
            ReviewerSource::RecentCommitter => 2,
        };
        if p < best {
            best = p;
        }
    }
    best
}

/// Top-N most-recent unique committers to `paths` within the last
/// `window_days`. Calls out to `git log` and parses author emails.
///
/// Returns empty list if `paths` is empty or if `git log` fails (e.g.
/// running outside a git repo). Never errors — best-effort surface.
pub fn recent_committers(
    repo_root: &Path,
    paths: &[PathBuf],
    window_days: u32,
    top_n: usize,
) -> anyhow::Result<Vec<String>> {
    if paths.is_empty() {
        return Ok(Vec::new());
    }
    // `git log --since=<N>.days.ago --pretty=format:%ae -- <paths>` gives
    // newest-first committer emails. We dedupe preserving order and take
    // top-N. Email → login mapping is left to the caller's GitHub query
    // layer (we keep emails here so callers can map them).
    let mut cmd = Command::new("git");
    cmd.arg("-C")
        .arg(repo_root)
        .arg("log")
        .arg(format!("--since={window_days}.days.ago"))
        .arg("--pretty=format:%ae");
    cmd.arg("--");
    for p in paths {
        cmd.arg(p);
    }
    let out = match cmd.output() {
        Ok(o) => o,
        Err(_) => return Ok(Vec::new()),
    };
    if !out.status.success() {
        return Ok(Vec::new());
    }
    let raw = String::from_utf8_lossy(&out.stdout);
    let mut seen = BTreeSet::new();
    let mut ordered: Vec<String> = Vec::new();
    for line in raw.lines() {
        let email = line.trim();
        if email.is_empty() {
            continue;
        }
        let login = email_to_login(email);
        if seen.insert(login.clone()) {
            ordered.push(login);
            if ordered.len() >= top_n {
                break;
            }
        }
    }
    Ok(ordered)
}

/// Heuristic mapping from a git author email → GitHub login.
///
/// Handles the common GitHub noreply pattern:
///   `12345+username@users.noreply.github.com` → `username`
///   `username@users.noreply.github.com` → `username`
///
/// For arbitrary emails, returns the local-part as a best-effort guess.
/// Callers that need authoritative mapping should plug in a per-repo
/// `.chump/reviewers.toml` `slack_to_github` mapping or similar.
pub fn email_to_login(email: &str) -> String {
    let email = email.trim();
    if let Some(local) = email.split('@').next() {
        if email.ends_with("@users.noreply.github.com") {
            // 12345+username or just username
            if let Some((_, login)) = local.split_once('+') {
                return login.to_string();
            }
            return local.to_string();
        }
        return local.to_string();
    }
    email.to_string()
}

/// One CODEOWNERS rule: pattern → list of owners.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodeownerRule {
    pub pattern: String,
    pub owners: Vec<String>,
}

/// Read CODEOWNERS from the first existing canonical location. Returns
/// empty list if no CODEOWNERS file exists.
pub fn read_codeowners(repo_root: &Path) -> anyhow::Result<Vec<CodeownerRule>> {
    for rel in &["CODEOWNERS", ".github/CODEOWNERS", "docs/CODEOWNERS"] {
        let path = repo_root.join(rel);
        if path.exists() {
            let raw = std::fs::read_to_string(&path)?;
            return Ok(parse_codeowners(&raw));
        }
    }
    Ok(Vec::new())
}

/// Parse CODEOWNERS text. Each non-comment, non-blank line is
/// `<pattern> <@owner1> <@owner2> …`.
pub fn parse_codeowners(raw: &str) -> Vec<CodeownerRule> {
    let mut rules = Vec::new();
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split_whitespace();
        let pattern = match parts.next() {
            Some(p) => p.to_string(),
            None => continue,
        };
        let owners: Vec<String> = parts
            .map(|o| o.trim_start_matches('@').to_string())
            .filter(|o| !o.is_empty())
            .collect();
        if !owners.is_empty() {
            rules.push(CodeownerRule { pattern, owners });
        }
    }
    rules
}

/// Given CODEOWNERS rules + touched files, return the union of owners
/// whose patterns match any of the touched files.
///
/// Pattern matching follows GitHub CODEOWNERS semantics for the common
/// cases: `/path/`, `*.ext`, `dir/**`. Full gitignore-style globbing is
/// not implemented — known limitation; if a CODEOWNERS file uses an
/// exotic pattern that fails to match, the recent-committers + operator-
/// override paths still produce coverage.
pub fn match_codeowners(rules: &[CodeownerRule], touched: &[PathBuf]) -> Vec<String> {
    let mut owners = BTreeSet::new();
    for rule in rules {
        for file in touched {
            if pattern_matches(&rule.pattern, file) {
                for o in &rule.owners {
                    owners.insert(o.clone());
                }
            }
        }
    }
    owners.into_iter().collect()
}

/// Minimal CODEOWNERS-pattern matcher.
///   `/path/` — matches any file under that directory.
///   `*.ext` — matches files with that suffix in any directory.
///   `dir/**` — matches any file under `dir/`.
///   `path/to/file.rs` — exact match.
fn pattern_matches(pattern: &str, file: &Path) -> bool {
    let file_str = file.to_string_lossy();
    let file_str = file_str.trim_start_matches("./");
    // `/path/` — directory anchor.
    if let Some(stripped) = pattern.strip_prefix('/') {
        if let Some(dir) = stripped.strip_suffix('/') {
            return file_str.starts_with(dir);
        }
        // `/exact/path.rs`
        return file_str == stripped;
    }
    // `*.ext`
    if let Some(ext) = pattern.strip_prefix("*.") {
        return file_str.ends_with(&format!(".{ext}"));
    }
    // `dir/**`
    if let Some(prefix) = pattern.strip_suffix("/**") {
        return file_str.starts_with(prefix);
    }
    // bare path — exact match
    file_str == pattern
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn tmp() -> tempdir::TempDir {
        tempdir::TempDir::new("reviewer-routing").unwrap()
    }

    // We deliberately don't pull tempdir as a dep; use a tiny inline
    // tempdir for tests via std::env::temp_dir + cleanup-on-drop.
    mod tempdir {
        use std::path::PathBuf;
        pub struct TempDir(pub PathBuf);
        impl TempDir {
            pub fn new(prefix: &str) -> std::io::Result<TempDir> {
                use std::time::{SystemTime, UNIX_EPOCH};
                let nanos = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .subsec_nanos();
                let pid = std::process::id();
                let dir = std::env::temp_dir().join(format!("{prefix}-{pid}-{nanos}"));
                std::fs::create_dir_all(&dir)?;
                Ok(TempDir(dir))
            }
            pub fn path(&self) -> &std::path::Path {
                &self.0
            }
        }
        impl Drop for TempDir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    // ── ReviewerConfig roundtrip ─────────────────────────────────────

    #[test]
    fn config_default_when_missing() {
        let dir = tmp();
        let cfg = ReviewerConfig::from_repo_root(dir.path()).unwrap();
        assert_eq!(cfg.max_reviewers, 5);
        assert_eq!(cfg.recent_window_days, 90);
        assert!(cfg.always_request.is_empty());
    }

    #[test]
    fn config_parses_toml() {
        let dir = tmp();
        fs::create_dir_all(dir.path().join(".chump")).unwrap();
        fs::write(
            dir.path().join(".chump").join("reviewers.toml"),
            r#"
always_request = ["@marcus", "@release-mgr"]
exclude = ["@dependabot[bot]"]
max_reviewers = 3
recent_window_days = 60
top_n_recent = 2

[slack_to_github]
"@marcus_slack" = "marcus-gh"
"#,
        )
        .unwrap();
        let cfg = ReviewerConfig::from_repo_root(dir.path()).unwrap();
        assert_eq!(cfg.always_request, vec!["@marcus", "@release-mgr"]);
        assert_eq!(cfg.max_reviewers, 3);
        assert_eq!(cfg.recent_window_days, 60);
        assert_eq!(cfg.top_n_recent, 2);
        assert_eq!(
            cfg.slack_to_github.get("@marcus_slack").unwrap(),
            "marcus-gh"
        );
    }

    // ── Email → login ─────────────────────────────────────────────────

    #[test]
    fn email_to_login_noreply_with_prefix() {
        assert_eq!(
            email_to_login("12345+jeffadkins@users.noreply.github.com"),
            "jeffadkins"
        );
    }

    #[test]
    fn email_to_login_noreply_no_prefix() {
        assert_eq!(
            email_to_login("jeffadkins@users.noreply.github.com"),
            "jeffadkins"
        );
    }

    #[test]
    fn email_to_login_regular_email_local_part() {
        assert_eq!(email_to_login("jeff@example.com"), "jeff");
    }

    // ── CODEOWNERS parsing ──────────────────────────────────────────

    #[test]
    fn codeowners_parses_comments_and_blanks() {
        let raw = r#"
# top comment
*.rs @rust-team

# blank line ignored

/docs/ @docs-team @marcus
crates/chump-policy/** @policy-team
"#;
        let rules = parse_codeowners(raw);
        assert_eq!(rules.len(), 3);
        assert_eq!(rules[0].pattern, "*.rs");
        assert_eq!(rules[0].owners, vec!["rust-team"]);
        assert_eq!(rules[1].owners, vec!["docs-team", "marcus"]);
        assert_eq!(rules[2].pattern, "crates/chump-policy/**");
    }

    #[test]
    fn pattern_match_extension() {
        assert!(pattern_matches("*.rs", &PathBuf::from("src/lib.rs")));
        assert!(!pattern_matches("*.rs", &PathBuf::from("README.md")));
    }

    #[test]
    fn pattern_match_directory_anchored() {
        assert!(pattern_matches("/docs/", &PathBuf::from("docs/foo.md")));
        assert!(!pattern_matches("/docs/", &PathBuf::from("src/docs.rs")));
    }

    #[test]
    fn pattern_match_glob_dir() {
        assert!(pattern_matches(
            "crates/chump-policy/**",
            &PathBuf::from("crates/chump-policy/src/lib.rs")
        ));
        assert!(!pattern_matches(
            "crates/chump-policy/**",
            &PathBuf::from("crates/chump-cost-tracker/src/lib.rs")
        ));
    }

    #[test]
    fn pattern_match_exact_path() {
        assert!(pattern_matches(
            "README.md",
            &PathBuf::from("README.md")
        ));
        assert!(!pattern_matches(
            "README.md",
            &PathBuf::from("docs/README.md")
        ));
    }

    #[test]
    fn match_codeowners_unions_across_rules() {
        let rules = vec![
            CodeownerRule {
                pattern: "*.rs".into(),
                owners: vec!["rust-team".into()],
            },
            CodeownerRule {
                pattern: "/docs/".into(),
                owners: vec!["docs-team".into()],
            },
        ];
        let touched = vec![
            PathBuf::from("src/lib.rs"),
            PathBuf::from("docs/foo.md"),
        ];
        let mut owners = match_codeowners(&rules, &touched);
        owners.sort();
        assert_eq!(owners, vec!["docs-team", "rust-team"]);
    }

    // ── compute_reviewer_set integration ────────────────────────────

    #[test]
    fn compute_includes_operator_override_unconditionally() {
        let dir = tmp();
        let cfg = ReviewerConfig {
            always_request: vec!["@marcus".into()],
            ..Default::default()
        };
        let set =
            compute_reviewer_set(dir.path(), &[], &cfg, None).unwrap();
        // No files touched, no codeowners, no git history — but operator
        // override still produces a reviewer.
        let logins: Vec<&str> = set.reviewers.iter().map(|r| r.login.as_str()).collect();
        assert_eq!(logins, vec!["marcus"]);
        assert_eq!(set.reviewers[0].via, vec![ReviewerSource::OperatorOverride]);
    }

    #[test]
    fn compute_unions_codeowners_with_override() {
        let dir = tmp();
        fs::write(
            dir.path().join("CODEOWNERS"),
            "*.rs @rust-team\n",
        )
        .unwrap();
        let cfg = ReviewerConfig {
            always_request: vec!["@marcus".into()],
            ..Default::default()
        };
        let touched = vec![PathBuf::from("src/lib.rs")];
        let set = compute_reviewer_set(dir.path(), &touched, &cfg, None).unwrap();
        let logins: Vec<&str> = set.reviewers.iter().map(|r| r.login.as_str()).collect();
        // marcus (override, priority 0) sorts before rust-team (codeowner, priority 1)
        assert_eq!(logins, vec!["marcus", "rust-team"]);
    }

    #[test]
    fn compute_caps_at_max_reviewers() {
        let dir = tmp();
        let cfg = ReviewerConfig {
            always_request: vec![
                "@a".into(),
                "@b".into(),
                "@c".into(),
                "@d".into(),
                "@e".into(),
                "@f".into(),
            ],
            max_reviewers: 3,
            ..Default::default()
        };
        let set = compute_reviewer_set(dir.path(), &[], &cfg, None).unwrap();
        assert_eq!(set.reviewers.len(), 3);
    }

    #[test]
    fn compute_excludes_pr_author() {
        let dir = tmp();
        let cfg = ReviewerConfig {
            always_request: vec!["@author".into(), "@reviewer".into()],
            ..Default::default()
        };
        let set =
            compute_reviewer_set(dir.path(), &[], &cfg, Some("author")).unwrap();
        let logins: Vec<&str> = set.reviewers.iter().map(|r| r.login.as_str()).collect();
        assert_eq!(logins, vec!["reviewer"]);
    }

    #[test]
    fn compute_honors_exclude_list() {
        let dir = tmp();
        let cfg = ReviewerConfig {
            always_request: vec!["@marcus".into(), "@dependabot[bot]".into()],
            exclude: vec!["@dependabot[bot]".into()],
            ..Default::default()
        };
        let set = compute_reviewer_set(dir.path(), &[], &cfg, None).unwrap();
        let logins: Vec<&str> = set.reviewers.iter().map(|r| r.login.as_str()).collect();
        assert_eq!(logins, vec!["marcus"]);
    }

    #[test]
    fn recent_committers_empty_paths_returns_empty() {
        let dir = tmp();
        let r = recent_committers(dir.path(), &[], 90, 3).unwrap();
        assert!(r.is_empty());
    }

    #[test]
    fn recent_committers_outside_git_repo_returns_empty() {
        let dir = tmp();
        // No `git init`; git log will fail.
        let r = recent_committers(
            dir.path(),
            &[PathBuf::from("doesnotmatter.rs")],
            90,
            3,
        )
        .unwrap();
        assert!(r.is_empty());
    }
}
