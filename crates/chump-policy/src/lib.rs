//! Per-operator + per-repo auto-merge policy resolution.
//!
//! Marcus M-E (INFRA-1489) trust-cliff knob: lets an operator gate auto-
//! merge per-scope so an agent claiming under their session does not auto-
//! merge until trust has been earned.
//!
//! ## Scope precedence (most-restrictive wins)
//!
//! Three scopes are layered. The effective policy is the most-restrictive
//! of any that match:
//!
//!   1. **Fleet** — the workspace default (today: enabled = true). Lives
//!      at `<repo>/.chump/fleet-policy.toml` or hard-coded fallback.
//!   2. **Operator** — the human's personal preference. Lives at
//!      `~/.chump/auto_merge_policy.toml`. Most operators want
//!      `require_human_review = true` until they have personally reviewed
//!      N PRs in a given repo.
//!   3. **Repo** — the per-repo override. Lives at
//!      `<repo>/.chump/auto_merge_policy.toml`. Repos with regulated
//!      consumers (financial, medical) hard-disable auto-merge here.
//!
//! "Most restrictive" means: if ANY scope sets `enabled = false`, the
//! effective policy is disabled. If ANY scope sets
//! `require_human_review = true`, the effective policy requires review.
//! The effective `trust_threshold_pr_count` is the MAXIMUM across scopes
//! (the strictest gate wins).
//!
//! ## Reviewed-PR counter (the trust ladder)
//!
//! The policy persists `reviewed_pr_count` per (operator, repo) tuple.
//! When the operator hand-reviews a PR, the count increments. Once
//! `reviewed_pr_count >= trust_threshold_pr_count`, auto-merge unlocks
//! for that (operator, repo). The counter is monotonically increasing;
//! resetting requires deleting the file.
//!
//! ## Event registry
//!   scanner-anchor: "kind":"auto_merge_policy_evaluated" emitted by this crate (INFRA-1489)
//!   scanner-anchor: "kind":"auto_merge_policy_blocked" emitted by this crate (INFRA-1489)

use serde::{Deserialize, Serialize};
use std::path::Path;

/// A single scope's auto-merge policy. Fields default to the most-permissive
/// values; explicit restrictions opt-in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Policy {
    /// Master switch. When `false`, auto-merge is disabled even if every
    /// other field permits it.
    #[serde(default = "default_enabled")]
    pub enabled: bool,

    /// When `true`, every PR ship requires a human review acknowledgement
    /// before auto-merge fires — even if the trust threshold has been
    /// passed.
    #[serde(default)]
    pub require_human_review: bool,

    /// Auto-merge unlocks only after the operator has hand-reviewed at
    /// least this many PRs in the scope. `0` means "no trust gate".
    #[serde(default)]
    pub trust_threshold_pr_count: u32,

    /// Live count of PRs the operator has hand-reviewed in this scope.
    /// Incremented via `Policy::record_human_review`. Compared against
    /// `trust_threshold_pr_count` to determine `is_trust_satisfied`.
    #[serde(default)]
    pub reviewed_pr_count: u32,
}

fn default_enabled() -> bool {
    true
}

impl Default for Policy {
    /// Permissive default: enabled, no review required, no trust gate.
    /// Matches today's fleet-wide behavior for operators who have not
    /// configured anything.
    fn default() -> Self {
        Self {
            enabled: true,
            require_human_review: false,
            trust_threshold_pr_count: 0,
            reviewed_pr_count: 0,
        }
    }
}

impl Policy {
    /// True when `reviewed_pr_count >= trust_threshold_pr_count`. The
    /// fast-check used by `is_auto_merge_allowed`.
    pub fn is_trust_satisfied(&self) -> bool {
        self.reviewed_pr_count >= self.trust_threshold_pr_count
    }

    /// True when auto-merge is currently allowed under this scope's policy.
    /// Combines all three gating fields.
    pub fn is_auto_merge_allowed(&self) -> bool {
        self.enabled && !self.require_human_review && self.is_trust_satisfied()
    }

    /// Returns a human-readable reason this scope blocks auto-merge, or
    /// `None` if it allows. Used to surface the WHY in audit logs +
    /// cockpit UI.
    pub fn block_reason(&self) -> Option<String> {
        if !self.enabled {
            return Some("auto-merge disabled (enabled=false)".into());
        }
        if self.require_human_review {
            return Some("require_human_review=true".into());
        }
        if !self.is_trust_satisfied() {
            return Some(format!(
                "trust threshold not met (reviewed {} of required {})",
                self.reviewed_pr_count, self.trust_threshold_pr_count
            ));
        }
        None
    }

    /// Atomically increment `reviewed_pr_count` by one. Used when the
    /// operator hand-reviews a PR; the counter trends toward the trust
    /// threshold so future PRs can auto-merge.
    pub fn record_human_review(&mut self) {
        self.reviewed_pr_count = self.reviewed_pr_count.saturating_add(1);
    }

    /// Parse a `Policy` from a TOML file. Missing fields fall back to
    /// `Policy::default()`. A missing FILE is not an error — it returns
    /// the default; only a malformed file errors.
    pub fn from_file(path: impl AsRef<Path>) -> anyhow::Result<Self> {
        let path = path.as_ref();
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = std::fs::read_to_string(path)?;
        let parsed: Policy = toml::from_str(&raw)?;
        Ok(parsed)
    }

    /// Persist this policy to a TOML file. Uses sibling-file + rename for
    /// atomicity so a concurrent reader never sees a half-written file.
    /// Process ID + nanosecond suffix avoids collision when two saves race.
    pub fn save_to_file(&self, path: impl AsRef<Path>) -> anyhow::Result<()> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let toml_body = toml::to_string_pretty(self)?;
        // Atomic write: write to sibling tempfile, then rename. Rename
        // is atomic on POSIX. The tempfile name includes pid+nanos so two
        // concurrent saves don't clobber each other's sibling.
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let pid = std::process::id();
        let parent = path
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| Path::new(".").to_path_buf());
        let stem = path
            .file_name()
            .map(|f| f.to_string_lossy().into_owned())
            .unwrap_or_else(|| "policy.toml".to_string());
        let tmp = parent.join(format!(".{stem}.tmp-{pid}-{nanos}"));
        std::fs::write(&tmp, toml_body)?;
        // POSIX rename is atomic within the same filesystem.
        if let Err(e) = std::fs::rename(&tmp, path) {
            // Clean up the orphan tempfile on failure.
            let _ = std::fs::remove_file(&tmp);
            return Err(e.into());
        }
        Ok(())
    }
}

/// A scope label used in audit logs + ambient emits. Order matches
/// precedence: Fleet first, Operator second, Repo third.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Fleet,
    Operator,
    Repo,
}

impl Scope {
    pub fn as_str(self) -> &'static str {
        match self {
            Scope::Fleet => "fleet",
            Scope::Operator => "operator",
            Scope::Repo => "repo",
        }
    }
}

/// Layered policy across the three scopes. Resolves the effective
/// (most-restrictive) policy via [`Self::effective`].
#[derive(Debug, Clone)]
pub struct PolicyChain {
    pub fleet: Policy,
    pub operator: Policy,
    pub repo: Policy,
}

impl PolicyChain {
    /// Read the chain from the three canonical file locations. Each file is
    /// optional; missing files yield `Policy::default()` for that scope.
    ///
    /// * `repo_root` is the repository root; canonical files are
    ///   `<repo>/.chump/fleet-policy.toml` and
    ///   `<repo>/.chump/auto_merge_policy.toml`.
    /// * `home_dir` is the operator's home dir; canonical file is
    ///   `<home>/.chump/auto_merge_policy.toml`.
    pub fn load(repo_root: &Path, home_dir: &Path) -> anyhow::Result<Self> {
        let fleet_path = repo_root.join(".chump").join("fleet-policy.toml");
        let operator_path = home_dir.join(".chump").join("auto_merge_policy.toml");
        let repo_path = repo_root.join(".chump").join("auto_merge_policy.toml");

        Ok(Self {
            fleet: Policy::from_file(fleet_path)?,
            operator: Policy::from_file(operator_path)?,
            repo: Policy::from_file(repo_path)?,
        })
    }

    /// Compute the effective policy by combining the three scopes with
    /// most-restrictive-wins semantics. Returns the effective `Policy`
    /// plus the `Scope` that contributed the strictest gate (used for
    /// audit-log "blocked by which scope" disclosure).
    pub fn effective(&self) -> (Policy, Vec<Scope>) {
        let scopes = [
            (Scope::Fleet, &self.fleet),
            (Scope::Operator, &self.operator),
            (Scope::Repo, &self.repo),
        ];
        // Most-restrictive of `enabled` and `require_human_review` is the
        // boolean AND / OR respectively. trust_threshold is the max.
        let mut eff = Policy::default();
        let mut contributing: Vec<Scope> = Vec::new();

        for (sc, p) in scopes {
            if !p.enabled {
                if eff.enabled {
                    // First scope to disable wins the "why" slot, but
                    // we still track all contributors.
                    eff.enabled = false;
                }
                contributing.push(sc);
            }
            if p.require_human_review {
                if !eff.require_human_review {
                    eff.require_human_review = true;
                }
                if !contributing.contains(&sc) {
                    contributing.push(sc);
                }
            }
            if p.trust_threshold_pr_count > eff.trust_threshold_pr_count {
                eff.trust_threshold_pr_count = p.trust_threshold_pr_count;
                if !contributing.contains(&sc) {
                    contributing.push(sc);
                }
            }
        }
        // reviewed_pr_count is the OPERATOR scope's value (operator is the
        // human who reviews); fleet/repo don't track it.
        eff.reviewed_pr_count = self.operator.reviewed_pr_count;
        (eff, contributing)
    }

    /// Convenience: returns Ok(()) if the effective policy permits an
    /// auto-merge right now; Err with the blocking reason otherwise. The
    /// `contributing` Vec is included so the audit log can disclose
    /// which scope(s) blocked.
    pub fn require_auto_merge_allowed(&self) -> Result<(), AutoMergeBlocked> {
        let (eff, contributing) = self.effective();
        if eff.is_auto_merge_allowed() {
            Ok(())
        } else {
            Err(AutoMergeBlocked {
                reason: eff
                    .block_reason()
                    .unwrap_or_else(|| "unknown".into()),
                contributing,
            })
        }
    }
}

/// Structured "blocked" result. Returned by
/// [`PolicyChain::require_auto_merge_allowed`] when auto-merge is not
/// allowed under the layered policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoMergeBlocked {
    pub reason: String,
    pub contributing: Vec<Scope>,
}

impl std::fmt::Display for AutoMergeBlocked {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let scopes_str: Vec<&str> = self
            .contributing
            .iter()
            .map(|s| s.as_str())
            .collect();
        write!(
            f,
            "auto-merge blocked by [{}]: {}",
            scopes_str.join(","),
            self.reason
        )
    }
}

impl std::error::Error for AutoMergeBlocked {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    #[test]
    fn permissive_default_allows() {
        let p = Policy::default();
        assert!(p.is_auto_merge_allowed());
        assert!(p.block_reason().is_none());
    }

    #[test]
    fn disabled_blocks_with_reason() {
        let p = Policy {
            enabled: false,
            ..Policy::default()
        };
        assert!(!p.is_auto_merge_allowed());
        let reason = p.block_reason().unwrap();
        assert!(reason.contains("disabled"));
    }

    #[test]
    fn require_review_blocks_with_reason() {
        let p = Policy {
            require_human_review: true,
            ..Policy::default()
        };
        assert!(!p.is_auto_merge_allowed());
        assert!(p
            .block_reason()
            .unwrap()
            .contains("require_human_review"));
    }

    #[test]
    fn trust_threshold_below_blocks() {
        let p = Policy {
            trust_threshold_pr_count: 50,
            reviewed_pr_count: 23,
            ..Policy::default()
        };
        assert!(!p.is_auto_merge_allowed());
        let r = p.block_reason().unwrap();
        assert!(r.contains("23 of required 50"));
    }

    #[test]
    fn trust_threshold_met_allows() {
        let p = Policy {
            trust_threshold_pr_count: 50,
            reviewed_pr_count: 50,
            ..Policy::default()
        };
        assert!(p.is_auto_merge_allowed());
    }

    #[test]
    fn record_human_review_increments() {
        let mut p = Policy::default();
        p.record_human_review();
        p.record_human_review();
        assert_eq!(p.reviewed_pr_count, 2);
    }

    #[test]
    fn record_human_review_saturates_at_u32_max() {
        let mut p = Policy {
            reviewed_pr_count: u32::MAX,
            ..Policy::default()
        };
        p.record_human_review();
        assert_eq!(p.reviewed_pr_count, u32::MAX);
    }

    #[test]
    fn missing_file_is_default() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("nope.toml");
        let p = Policy::from_file(&path).unwrap();
        assert_eq!(p, Policy::default());
    }

    #[test]
    fn malformed_file_errors() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("bad.toml");
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(b"this is { not valid toml")
            .unwrap();
        assert!(Policy::from_file(&path).is_err());
    }

    #[test]
    fn roundtrip_save_load() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("p.toml");
        let orig = Policy {
            enabled: true,
            require_human_review: true,
            trust_threshold_pr_count: 10,
            reviewed_pr_count: 3,
        };
        orig.save_to_file(&path).unwrap();
        let loaded = Policy::from_file(&path).unwrap();
        assert_eq!(orig, loaded);
    }

    // ── PolicyChain precedence tests (AC #3: most-restrictive wins) ────

    fn chain_with(
        fleet: Policy,
        operator: Policy,
        repo: Policy,
    ) -> PolicyChain {
        PolicyChain {
            fleet,
            operator,
            repo,
        }
    }

    #[test]
    fn chain_all_permissive_allows() {
        let chain = chain_with(
            Policy::default(),
            Policy::default(),
            Policy::default(),
        );
        let (eff, _) = chain.effective();
        assert!(eff.is_auto_merge_allowed());
        assert!(chain.require_auto_merge_allowed().is_ok());
    }

    #[test]
    fn chain_repo_disables_overrides_permissive_fleet() {
        let mut repo = Policy::default();
        repo.enabled = false;
        let chain = chain_with(
            Policy::default(),
            Policy::default(),
            repo,
        );
        let res = chain.require_auto_merge_allowed();
        assert!(res.is_err());
        let blocked = res.unwrap_err();
        assert!(blocked.contributing.contains(&Scope::Repo));
        assert!(blocked.reason.contains("disabled"));
    }

    #[test]
    fn chain_operator_require_review_propagates() {
        let mut operator = Policy::default();
        operator.require_human_review = true;
        let chain = chain_with(
            Policy::default(),
            operator,
            Policy::default(),
        );
        let res = chain.require_auto_merge_allowed();
        assert!(res.is_err());
        let blocked = res.unwrap_err();
        assert!(blocked.contributing.contains(&Scope::Operator));
    }

    #[test]
    fn chain_max_threshold_wins() {
        // Fleet=0, Operator=50, Repo=10  → effective max=50
        let mut operator = Policy::default();
        operator.trust_threshold_pr_count = 50;
        operator.reviewed_pr_count = 12;
        let mut repo = Policy::default();
        repo.trust_threshold_pr_count = 10;
        let chain = chain_with(Policy::default(), operator, repo);
        let (eff, _) = chain.effective();
        assert_eq!(eff.trust_threshold_pr_count, 50);
        assert_eq!(eff.reviewed_pr_count, 12);
        assert!(!eff.is_auto_merge_allowed());
    }

    #[test]
    fn chain_trust_threshold_met_via_operator_count() {
        // Fleet+repo are permissive; operator says threshold=5, reviewed=5
        let mut operator = Policy::default();
        operator.trust_threshold_pr_count = 5;
        operator.reviewed_pr_count = 5;
        let chain = chain_with(
            Policy::default(),
            operator,
            Policy::default(),
        );
        let (eff, _) = chain.effective();
        assert!(eff.is_auto_merge_allowed());
    }

    #[test]
    fn chain_multiple_blockers_all_listed() {
        let mut operator = Policy::default();
        operator.require_human_review = true;
        let mut repo = Policy::default();
        repo.enabled = false;
        let chain = chain_with(Policy::default(), operator, repo);
        let res = chain.require_auto_merge_allowed();
        let blocked = res.unwrap_err();
        // Both operator and repo are restrictive — both should be
        // disclosed in the contributing list.
        assert!(blocked.contributing.contains(&Scope::Repo));
        assert!(blocked.contributing.contains(&Scope::Operator));
    }

    #[test]
    fn chain_loads_from_disk() {
        let tmp = TempDir::new().unwrap();
        let repo_root = tmp.path();
        let home_dir = tmp.path().join("home");
        std::fs::create_dir_all(&home_dir).unwrap();

        // Write operator policy: enabled, require review.
        let op_policy = Policy {
            enabled: true,
            require_human_review: true,
            trust_threshold_pr_count: 0,
            reviewed_pr_count: 0,
        };
        op_policy
            .save_to_file(home_dir.join(".chump").join("auto_merge_policy.toml"))
            .unwrap();

        let chain = PolicyChain::load(repo_root, &home_dir).unwrap();
        assert!(chain.operator.require_human_review);
        let res = chain.require_auto_merge_allowed();
        assert!(res.is_err());
    }
}
