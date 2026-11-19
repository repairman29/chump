//! `BotMergePath` — cross-platform autonomous ship executor (Milestone 3).
//!
//! Replaces the 5.8K-LOC `scripts/coord/bot-merge.sh` control plane with a
//! pure-Rust, Windows/macOS/Linux-compatible executor backed by:
//! - [`chump_pal::ipc::IpcServer::bind_exclusive_at`] single-instance lock
//! - [`crate::plan`] (`ShipPlan`) decision engine
//! - `git fetch` + `git rebase origin/<base>` when behind within `stale_threshold`
//! - `git push -u origin <branch> --force-with-lease`
//! - `gh pr create --base <base> --head <branch>` (when PR is absent)
//! - Typed `gap_prs` SQLite recording when `<repo_root>/.chump/state.db` exists
//! - Gate-guarded `gh pr merge --auto --squash` (`arm_policy` + `gate_guard`)

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use chrono::Utc;
use rusqlite::params;
use tokio::process::Command;

use crate::ship::{
    truncate_for_log, PreflightGate, PreflightReport, Ship, ShipError, ShipIntent, ShipReceipt,
};
use crate::{plan, ChecksSummary, MergeableState, PrSnapshot, PrState, RepoSnapshot, ShipPlan};

/// Default maximum commits behind `origin/<base>` before refusing blind rebase.
pub const DEFAULT_STALE_THRESHOLD: u32 = 200;

const ENV_LEAK_VARS: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GITHUB_WORKSPACE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
];

/// Cross-platform autonomous ship executor.
pub struct BotMergePath {
    intent: ShipIntent<'static>,
    repo_root: PathBuf,
    bot_session_id: String,
    _ipc_guard: chump_pal::ipc::IpcServer,
    dry_run: bool,
    auto_merge: bool,
    stale_threshold: u32,
    explicit_state_db: Option<PathBuf>,
}

impl std::fmt::Debug for BotMergePath {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BotMergePath")
            .field("intent", &self.intent)
            .field("repo_root", &self.repo_root)
            .field("bot_session_id", &self.bot_session_id)
            .field("dry_run", &self.dry_run)
            .field("auto_merge", &self.auto_merge)
            .field("stale_threshold", &self.stale_threshold)
            .finish()
    }
}

impl BotMergePath {
    /// Construct a new `BotMergePath` and acquire the cross-platform single-instance
    /// IPC lock for `bot_session_id`. Returns [`ShipError::BotMergeDoubleInstance`]
    /// if another `BotMergePath` holds the same `bot_session_id`.
    pub fn new(
        intent: ShipIntent<'static>,
        repo_root: impl AsRef<Path>,
        bot_session_id: impl Into<String>,
    ) -> Result<Self, ShipError> {
        let bot_session_id = bot_session_id.into();
        let ipc_path = bot_merge_ipc_path_for(&bot_session_id);
        let ipc_guard = match chump_pal::ipc::IpcServer::bind_exclusive_at(&ipc_path) {
            Ok(srv) => srv,
            Err(err) if err.kind() == std::io::ErrorKind::AddrInUse => {
                return Err(ShipError::BotMergeDoubleInstance {
                    detail: format!(
                        "ipc endpoint {} already bound by an active BotMergePath \
                         (bot_session_id={bot_session_id}): {err}",
                        ipc_path.display()
                    ),
                });
            }
            Err(err) => return Err(ShipError::Io(err)),
        };

        let stale_threshold = std::env::var("CHUMP_BOT_MERGE_STALE_THRESHOLD")
            .ok()
            .and_then(|v| v.trim().parse::<u32>().ok())
            .unwrap_or(DEFAULT_STALE_THRESHOLD);

        Ok(Self {
            intent,
            repo_root: repo_root.as_ref().to_path_buf(),
            bot_session_id,
            _ipc_guard: ipc_guard,
            dry_run: false,
            auto_merge: false,
            stale_threshold,
            explicit_state_db: None,
        })
    }

    /// Enable or disable dry-run mode (no remote mutations; emits synthesized receipt).
    pub fn with_dry_run(mut self, dry_run: bool) -> Self {
        self.dry_run = dry_run;
        self
    }

    /// Enable or disable arming GitHub auto-merge (`--auto --squash`) after PR open.
    pub fn with_auto_merge(mut self, auto_merge: bool) -> Self {
        self.auto_merge = auto_merge;
        self
    }

    /// Override the stale-branch behind threshold (defaults to `CHUMP_BOT_MERGE_STALE_THRESHOLD` or 200).
    pub fn with_stale_threshold(mut self, threshold: u32) -> Self {
        self.stale_threshold = threshold;
        self
    }

    /// Override the `state.db` path used for `gap_prs` recording (useful in isolated tests).
    pub fn with_state_db(mut self, state_db: impl Into<PathBuf>) -> Self {
        self.explicit_state_db = Some(state_db.into());
        self
    }

    /// Worker session id passed to [`Self::new`].
    pub fn bot_session_id(&self) -> &str {
        &self.bot_session_id
    }

    /// Repo root path passed to [`Self::new`].
    pub fn repo_root(&self) -> &Path {
        &self.repo_root
    }

    /// Whether dry-run mode is enabled.
    pub fn dry_run(&self) -> bool {
        self.dry_run
    }

    /// Whether auto-merge arming is enabled.
    pub fn auto_merge(&self) -> bool {
        self.auto_merge
    }

    fn git(&self) -> Command {
        let mut cmd = Command::new("git");
        for v in ENV_LEAK_VARS {
            cmd.env_remove(v);
        }
        cmd.arg("-C").arg(&self.repo_root);
        cmd
    }

    fn gh(&self) -> Command {
        let mut cmd = Command::new("gh");
        for v in ENV_LEAK_VARS {
            cmd.env_remove(v);
        }
        cmd.current_dir(&self.repo_root);
        cmd
    }

    async fn gate_branch_exists(&self) -> PreflightGate {
        let out = self
            .git()
            .args([
                "rev-parse",
                "--verify",
                &format!("refs/heads/{}", self.intent.branch),
            ])
            .output()
            .await;
        match out {
            Ok(o) if o.status.success() => PreflightGate {
                name: "branch_exists".into(),
                passed: true,
                detail: String::new(),
            },
            Ok(o) => PreflightGate {
                name: "branch_exists".into(),
                passed: false,
                detail: format!(
                    "branch `{}` not found (rc={}): {}",
                    self.intent.branch,
                    o.status.code().unwrap_or(-1),
                    truncate_for_log(&String::from_utf8_lossy(&o.stderr), 240),
                ),
            },
            Err(err) => PreflightGate {
                name: "branch_exists".into(),
                passed: false,
                detail: format!("failed to run git rev-parse: {err}"),
            },
        }
    }

    fn gate_branch_not_main(&self) -> PreflightGate {
        let b = self.intent.branch.trim();
        if b == "main" || b == "master" || b == "HEAD" || b.is_empty() {
            PreflightGate {
                name: "branch_not_main".into(),
                passed: false,
                detail: format!("Already on {b}. Run from a feature/agent branch."),
            }
        } else {
            PreflightGate {
                name: "branch_not_main".into(),
                passed: true,
                detail: String::new(),
            }
        }
    }

    async fn has_uncommitted_tracked(&self) -> bool {
        match self
            .git()
            .args(["status", "--porcelain", "--untracked-files=no"])
            .output()
            .await
        {
            Ok(o) if o.status.success() => !String::from_utf8_lossy(&o.stdout).trim().is_empty(),
            _ => false,
        }
    }

    async fn gate_ahead_of_base(&self) -> PreflightGate {
        let base_ref = crate::gate_guard::normalize_base_ref(&self.intent.base);
        let revspec = format!("{base_ref}..{}", self.intent.branch);
        let out = self
            .git()
            .args(["rev-list", "--count", &revspec])
            .output()
            .await;
        match out {
            Ok(o) if o.status.success() => {
                let count: u64 = String::from_utf8_lossy(&o.stdout)
                    .trim()
                    .parse()
                    .unwrap_or(0);
                if count > 0 {
                    PreflightGate {
                        name: "ahead_of_base".into(),
                        passed: true,
                        detail: String::new(),
                    }
                } else {
                    PreflightGate {
                        name: "ahead_of_base".into(),
                        passed: false,
                        detail: format!(
                            "branch `{}` is not ahead of `{base_ref}` — nothing to ship",
                            self.intent.branch
                        ),
                    }
                }
            }
            Ok(o) => PreflightGate {
                name: "ahead_of_base".into(),
                passed: false,
                detail: format!(
                    "git rev-list failed (rc={}): {}",
                    o.status.code().unwrap_or(-1),
                    truncate_for_log(&String::from_utf8_lossy(&o.stderr), 240),
                ),
            },
            Err(err) => PreflightGate {
                name: "ahead_of_base".into(),
                passed: false,
                detail: format!("failed to run git rev-list: {err}"),
            },
        }
    }

    async fn fetch_base(&self) {
        if self.dry_run {
            println!("[dry-run] git fetch origin {}", self.intent.base);
            return;
        }
        let base_branch = self
            .intent
            .base
            .strip_prefix("origin/")
            .unwrap_or(&self.intent.base);
        let _ = self
            .git()
            .args(["fetch", "origin", base_branch])
            .output()
            .await;
    }

    async fn build_repo_snapshot(&self) -> Result<RepoSnapshot, ShipError> {
        let base_ref = crate::gate_guard::normalize_base_ref(&self.intent.base);
        let behind_spec = format!("{}..{base_ref}", self.intent.branch);
        let ahead_spec = format!("{base_ref}..{}", self.intent.branch);

        let behind_out = self
            .git()
            .args(["rev-list", "--count", &behind_spec])
            .output()
            .await?;
        if !behind_out.status.success() {
            return Err(ShipError::Git {
                rc: behind_out.status.code().unwrap_or(-1),
                stderr_tail: truncate_for_log(&String::from_utf8_lossy(&behind_out.stderr), 480),
            });
        }
        let behind_main: u32 = String::from_utf8_lossy(&behind_out.stdout)
            .trim()
            .parse()
            .unwrap_or(0);

        let ahead_out = self
            .git()
            .args(["rev-list", "--count", &ahead_spec])
            .output()
            .await?;
        if !ahead_out.status.success() {
            return Err(ShipError::Git {
                rc: ahead_out.status.code().unwrap_or(-1),
                stderr_tail: truncate_for_log(&String::from_utf8_lossy(&ahead_out.stderr), 480),
            });
        }
        let ahead_main: u32 = String::from_utf8_lossy(&ahead_out.stdout)
            .trim()
            .parse()
            .unwrap_or(0);

        Ok(RepoSnapshot {
            branch: self.intent.branch.to_string(),
            behind_main,
            ahead_main,
            has_uncommitted: self.has_uncommitted_tracked().await,
            stale_threshold: self.stale_threshold,
        })
    }

    async fn query_existing_pr(&self) -> (PrSnapshot, Option<String>) {
        let empty = PrSnapshot {
            number: None,
            state: PrState::None,
            mergeable: None,
            mergeable_state: MergeableState::Unknown,
            auto_merge_set: false,
            head_sha: String::new(),
            base_sha: String::new(),
            checks: ChecksSummary::default(),
        };
        if self.dry_run {
            return (empty, None);
        }
        let out = match self
            .gh()
            .args([
                "pr",
                "view",
                self.intent.branch.as_ref(),
                "--json",
                "number,url,state,mergeable,mergeStateStatus,autoMergeRequest,headRefOid,baseRefOid",
            ])
            .output()
            .await
        {
            Ok(o) if o.status.success() => o,
            _ => return (empty, None),
        };
        let Ok(v) = serde_json::from_slice::<serde_json::Value>(&out.stdout) else {
            return (empty, None);
        };
        let number = v.get("number").and_then(|n| n.as_u64());
        let url = v.get("url").and_then(|u| u.as_str()).map(ToOwned::to_owned);
        let state = match v
            .get("state")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_ascii_uppercase()
            .as_str()
        {
            "OPEN" => PrState::Open,
            "MERGED" => PrState::Merged,
            "CLOSED" => PrState::Closed,
            _ => PrState::None,
        };
        let mergeable = match v.get("mergeable").and_then(|m| m.as_str()) {
            Some("MERGEABLE") => Some(true),
            Some("CONFLICTING") => Some(false),
            _ => v.get("mergeable").and_then(|m| m.as_bool()),
        };
        let mergeable_state = match v
            .get("mergeStateStatus")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_ascii_uppercase()
            .as_str()
        {
            "CLEAN" => MergeableState::Clean,
            "BEHIND" => MergeableState::Behind,
            "BLOCKED" => MergeableState::Blocked,
            "DIRTY" => MergeableState::Dirty,
            "UNSTABLE" => MergeableState::Unstable,
            "HAS_HOOKS" => MergeableState::HasHooks,
            _ => MergeableState::Unknown,
        };
        let auto_merge_set = v
            .get("autoMergeRequest")
            .map(|am| !am.is_null())
            .unwrap_or(false);
        let head_sha = v
            .get("headRefOid")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string();
        let base_sha = v
            .get("baseRefOid")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string();

        (
            PrSnapshot {
                number,
                state,
                mergeable,
                mergeable_state,
                auto_merge_set,
                head_sha,
                base_sha,
                checks: ChecksSummary::default(),
            },
            url,
        )
    }

    async fn rebase_onto_base(&self) -> Result<(), ShipError> {
        let base_ref = crate::gate_guard::normalize_base_ref(&self.intent.base);
        if self.dry_run {
            println!("[dry-run] git rebase {base_ref}");
            return Ok(());
        }
        let out = self.git().args(["rebase", &base_ref]).output().await?;
        if !out.status.success() {
            let _ = self.git().args(["rebase", "--abort"]).output().await;
            return Err(ShipError::Git {
                rc: out.status.code().unwrap_or(-1),
                stderr_tail: truncate_for_log(&String::from_utf8_lossy(&out.stderr), 480),
            });
        }
        Ok(())
    }

    async fn push_branch(&self) -> Result<(), ShipError> {
        if self.dry_run {
            println!(
                "[dry-run] git push -u origin {} --force-with-lease",
                self.intent.branch
            );
            return Ok(());
        }
        let out = self
            .git()
            .env("CHUMP_BOT_MERGE_IN_PROGRESS", "1")
            .args([
                "push",
                "-u",
                "origin",
                self.intent.branch.as_ref(),
                "--force-with-lease",
            ])
            .output()
            .await?;
        if !out.status.success() {
            return Err(ShipError::Git {
                rc: out.status.code().unwrap_or(-1),
                stderr_tail: truncate_for_log(&String::from_utf8_lossy(&out.stderr), 480),
            });
        }
        Ok(())
    }

    async fn resolve_head_sha(&self) -> Result<String, ShipError> {
        let out = self
            .git()
            .args(["rev-parse", self.intent.branch.as_ref()])
            .output()
            .await?;
        if !out.status.success() {
            if self.dry_run {
                return Ok("dryrun0000000000000000000000000000000000".to_string());
            }
            return Err(ShipError::Git {
                rc: out.status.code().unwrap_or(-1),
                stderr_tail: truncate_for_log(&String::from_utf8_lossy(&out.stderr), 480),
            });
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    async fn create_pr(&self) -> Result<(u64, String), ShipError> {
        let base_branch = self
            .intent
            .base
            .strip_prefix("origin/")
            .unwrap_or(&self.intent.base);
        let title = self.intent.commit_message.to_string();
        if self.dry_run {
            println!(
                "[dry-run] gh pr create --base {base_branch} --head {} --title {:?}",
                self.intent.branch, title
            );
            return Ok((
                0,
                format!(
                    "https://github.com/dry-run/dry-run/pull/0 (gap={})",
                    self.intent.gap_id
                ),
            ));
        }
        let body = format!(
            "Automated ship for {gap}.\n\nGenerated by chump-ship (BotMergePath).",
            gap = self.intent.gap_id
        );
        let out = self
            .gh()
            .args([
                "pr",
                "create",
                "--base",
                base_branch,
                "--head",
                self.intent.branch.as_ref(),
                "--title",
                &title,
                "--body",
                &body,
            ])
            .output()
            .await?;
        if !out.status.success() {
            return Err(ShipError::Gh {
                rc: out.status.code().unwrap_or(-1),
                stderr_tail: truncate_for_log(&String::from_utf8_lossy(&out.stderr), 480),
            });
        }
        let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let url = stdout
            .lines()
            .rev()
            .find(|l| l.starts_with("http"))
            .ok_or_else(|| ShipError::UnparseablePrNumber {
                raw: stdout.clone(),
            })?
            .to_string();
        let pr_num = url
            .rsplit('/')
            .next()
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or_else(|| ShipError::UnparseablePrNumber { raw: url.clone() })?;
        Ok((pr_num, url))
    }

    async fn arm_auto_merge_guarded(
        &self,
        pr_number: u64,
    ) -> Result<(bool, Option<String>), ShipError> {
        if let Err(refusal) =
            crate::gate_guard::check_gate_arm_refused(&self.repo_root, &self.intent.base, true)
        {
            let msg = refusal.to_string();
            eprintln!("{msg}");
            tracing::warn!(pr = pr_number, reason = %msg, "gate_guard refused auto-merge");
            return Ok((false, Some(msg)));
        }
        if self.dry_run {
            println!("[dry-run] gh pr merge {pr_number} --auto --squash");
            return Ok((true, None));
        }
        if let Err(held) = crate::arm_policy::require_allowed_at(
            &pr_number.to_string(),
            "",
            "chump-ship(bot_merge)",
            crate::arm_policy::GateAction::Arm,
            Some(&self.repo_root),
        ) {
            let msg = held.to_string();
            tracing::warn!(pr = pr_number, %held, "arm policy: PR held; not arming");
            return Ok((false, Some(msg)));
        }
        let out = self
            .gh()
            .args(["pr", "merge", &pr_number.to_string(), "--auto", "--squash"])
            .output()
            .await?;
        if !out.status.success() {
            let stderr_tail = truncate_for_log(&String::from_utf8_lossy(&out.stderr), 240);
            tracing::warn!(
                pr = pr_number,
                rc = out.status.code().unwrap_or(-1),
                stderr_tail = %stderr_tail,
                "auto-merge arm failed; PR open but not armed"
            );
            return Ok((
                false,
                Some(format!("gh pr merge --auto failed: {stderr_tail}")),
            ));
        }
        Ok((true, None))
    }
}

#[async_trait]
impl Ship for BotMergePath {
    fn intent(&self) -> &ShipIntent<'_> {
        &self.intent
    }

    async fn preflight(&self) -> Result<PreflightReport, ShipError> {
        let mut gates = vec![self.gate_branch_exists().await, self.gate_branch_not_main()];
        if !self.dry_run && self.has_uncommitted_tracked().await {
            gates.push(PreflightGate {
                name: "clean_worktree".into(),
                passed: false,
                detail: "worktree has uncommitted tracked modifications".into(),
            });
        } else {
            gates.push(PreflightGate {
                name: "clean_worktree".into(),
                passed: true,
                detail: String::new(),
            });
        }
        gates.push(self.gate_ahead_of_base().await);
        Ok(PreflightReport { gates })
    }

    async fn ship(&self) -> Result<ShipReceipt, ShipError> {
        // 1. Fetch latest base ref before preflight / planning.
        self.fetch_base().await;

        // 2. Run preflight gates.
        let report = self.preflight().await?;
        if !report.all_passed() {
            let fail = report
                .first_failure()
                .expect("all_passed=false implies a failure exists");
            return Err(ShipError::PreflightFailed {
                gate_name: fail.name.clone(),
                detail: fail.detail.clone(),
            });
        }

        // 3. Build snapshots and invoke the pure ShipPlan planner.
        let repo_snap = self.build_repo_snapshot().await?;
        let (pr_snap, existing_url) = self.query_existing_pr().await;
        let ship_plan = plan(&pr_snap, &repo_snap);
        tracing::info!(
            gap = %self.intent.gap_id,
            branch = %self.intent.branch,
            ?ship_plan,
            "BotMergePath evaluated ShipPlan"
        );

        // 4. Refuse if behind exceeds stale_threshold (or planner returned StaleBranch).
        if repo_snap.behind_main > repo_snap.stale_threshold {
            return Err(ShipError::PreflightFailed {
                gate_name: "stale_branch".into(),
                detail: format!(
                    "branch `{}` is {} commits behind `{}` (stale_threshold={})",
                    self.intent.branch,
                    repo_snap.behind_main,
                    self.intent.base,
                    repo_snap.stale_threshold
                ),
            });
        }
        if let ShipPlan::AlreadyDone { pr, state, .. } = ship_plan {
            let head_sha = if pr_snap.head_sha.is_empty() {
                self.resolve_head_sha().await?
            } else {
                pr_snap.head_sha
            };
            return Ok(ShipReceipt {
                pr_number: pr,
                pr_url: existing_url.unwrap_or_else(|| format!("pr://{pr}")),
                head_sha,
                auto_merge_armed: state == PrState::Merged || pr_snap.auto_merge_set,
                auto_merge_note: Some(format!("PR #{pr} already in terminal state {state:?}")),
                shipped_at: Utc::now(),
            });
        }

        // 5. Rebase onto origin/<base> when behind within stale_threshold.
        if repo_snap.behind_main > 0 {
            self.rebase_onto_base().await?;
        }

        // 6. Push branch with --force-with-lease.
        self.push_branch().await?;
        let head_sha = self.resolve_head_sha().await?;

        // 7. Create PR if absent, or reuse open PR.
        let (pr_number, pr_url) = match (pr_snap.number, pr_snap.state) {
            (Some(num), PrState::Open) => (
                num,
                existing_url.unwrap_or_else(|| format!("https://github.com/local/pr/{num}")),
            ),
            _ => self.create_pr().await?,
        };

        // 8. Record typed gap_prs FK when state.db exists locally.
        if !self.dry_run && pr_number > 0 {
            let db_res = if let Some(ref db_path) = self.explicit_state_db {
                record_gap_pr_at(db_path, &self.intent.gap_id, pr_number, &head_sha)
            } else {
                record_gap_pr_if_store_exists(
                    &self.repo_root,
                    &self.intent.gap_id,
                    pr_number,
                    &head_sha,
                )
            };
            if let Err(err) = db_res {
                tracing::warn!(
                    gap = %self.intent.gap_id,
                    pr = pr_number,
                    %err,
                    "failed to record gap_prs link"
                );
            }
        }

        // 9. Arm auto-merge ONLY when explicitly requested, gated by CREDIBLE-1576 + arm_policy.
        let (auto_merge_armed, auto_merge_note) = if self.auto_merge {
            if pr_snap.auto_merge_set && !self.dry_run {
                (true, None)
            } else {
                self.arm_auto_merge_guarded(pr_number).await?
            }
        } else {
            (false, None)
        };

        Ok(ShipReceipt {
            pr_number,
            pr_url,
            head_sha,
            auto_merge_armed,
            auto_merge_note,
            shipped_at: Utc::now(),
        })
    }
}

pub(crate) fn bot_merge_ipc_path_for(bot_session_id: &str) -> PathBuf {
    let safe = bot_session_id.replace(['/', '\\', ':'], "_");
    chump_pal::ipc::ipc_file_path(&format!("chump-bot-merge-{safe}"))
}

/// Record a typed `(gap_id, pr_number, head_sha)` link in `<repo_root>/.chump/state.db`
/// (or `CHUMP_STATE_DB` if explicitly set) when that SQLite database already exists.
///
/// Never walks up from linked worktrees to mutate a parent checkout's `state.db`,
/// and respects any sibling `.noncanonical` marker (RESILIENT-1650) and single-gap
/// link protection (CREDIBLE-1559).
pub fn record_gap_pr_if_store_exists(
    repo_root: &Path,
    gap_id: &str,
    pr_number: u64,
    head_sha: &str,
) -> Result<bool, String> {
    let db_path = std::env::var_os("CHUMP_STATE_DB")
        .map(PathBuf::from)
        .unwrap_or_else(|| repo_root.join(".chump").join("state.db"));
    record_gap_pr_at(&db_path, gap_id, pr_number, head_sha)
}

/// Record a typed `(gap_id, pr_number, head_sha)` link in the given `state.db` file
/// if it exists on disk. Returns `Ok(false)` when `db_path` does not exist.
pub fn record_gap_pr_at(
    db_path: &Path,
    gap_id: &str,
    pr_number: u64,
    head_sha: &str,
) -> Result<bool, String> {
    if gap_id.trim().is_empty() || !db_path.is_file() {
        return Ok(false);
    }
    if let Some(parent) = db_path.parent() {
        let marker = parent.join(".noncanonical");
        if marker.exists() {
            return Err(format!(
                "RESILIENT-1650: refusing to write gap_prs into non-canonical store ({})",
                marker.display()
            ));
        }
    }

    let conn = rusqlite::Connection::open(db_path)
        .map_err(|e| format!("open {}: {e}", db_path.display()))?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS gap_prs (
            gap_id      TEXT NOT NULL,
            pr_number   INTEGER NOT NULL,
            head_sha    TEXT NOT NULL,
            opened_at   INTEGER NOT NULL,
            state       TEXT NOT NULL DEFAULT 'open',
            multi_ok    INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (gap_id, pr_number)
         );
         CREATE INDEX IF NOT EXISTS gap_prs_pr_number ON gap_prs(pr_number);",
    )
    .map_err(|e| format!("ensure gap_prs schema: {e}"))?;

    // CREDIBLE-1559 AC2: refuse linking a second distinct gap to an already-linked PR
    // unless multi_ok is already set.
    let mut stmt = conn
        .prepare("SELECT gap_id, multi_ok FROM gap_prs WHERE pr_number = ?1")
        .map_err(|e| format!("prepare gap_prs lookup: {e}"))?;
    let rows = stmt
        .query_map(params![pr_number as i64], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1).unwrap_or(0)))
        })
        .map_err(|e| format!("query gap_prs: {e}"))?;
    for row in rows {
        let (existing_gap, multi_ok) = row.map_err(|e| format!("read gap_prs row: {e}"))?;
        if existing_gap != gap_id && multi_ok == 0 {
            return Err(format!(
                "CREDIBLE-1559 AC2: PR #{pr_number} is already linked to {existing_gap} — refusing to link {gap_id}"
            ));
        }
    }
    drop(stmt);

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    conn.execute(
        "INSERT INTO gap_prs(gap_id, pr_number, head_sha, opened_at, state, multi_ok)
         VALUES(?1, ?2, ?3, ?4, 'open', 0)
         ON CONFLICT(gap_id, pr_number) DO UPDATE SET
             head_sha = excluded.head_sha",
        params![gap_id, pr_number as i64, head_sha, now],
    )
    .map_err(|e| format!("upsert gap_prs: {e}"))?;

    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn unique_bot_id(label: &str) -> String {
        format!(
            "bot-{label}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        )
    }

    fn seed_origin_and_worktree(tmp: &TempDir) -> (PathBuf, PathBuf) {
        let origin = tmp.path().join("origin.git");
        let work = tmp.path().join("work");
        std::fs::create_dir_all(&origin).unwrap();

        let run_git = |dir: &Path, args: &[&str]| {
            let mut c = std::process::Command::new("git");
            for v in ENV_LEAK_VARS {
                c.env_remove(v);
            }
            let st = c.arg("-C").arg(dir).args(args).status().unwrap();
            assert!(st.success(), "git {args:?} failed in {}", dir.display());
        };

        run_git(&origin, &["init", "--bare", "-b", "main"]);
        let st = std::process::Command::new("git")
            .args(["clone", origin.to_str().unwrap(), work.to_str().unwrap()])
            .status()
            .unwrap();
        assert!(st.success());

        run_git(&work, &["config", "user.email", "t@chump.local"]);
        run_git(&work, &["config", "user.name", "Chump Test"]);
        std::fs::write(work.join("README.md"), "init\n").unwrap();
        run_git(&work, &["add", "README.md"]);
        run_git(&work, &["commit", "-m", "initial"]);
        run_git(&work, &["push", "-u", "origin", "main"]);

        (origin, work)
    }

    #[tokio::test]
    async fn bot_merge_enforces_single_instance_via_pal_ipc() {
        let tmp = TempDir::new().unwrap();
        let bot_id = unique_bot_id("single-inst");
        let i1 = ShipIntent::owned("INFRA-TEST", "chump/test", "main", "msg", "s1");
        let i2 = ShipIntent::owned("INFRA-TEST", "chump/test", "main", "msg", "s2");
        let _first = BotMergePath::new(i1, tmp.path(), bot_id.clone()).expect("first bind");
        let second = BotMergePath::new(i2, tmp.path(), bot_id);
        assert!(
            matches!(second, Err(ShipError::BotMergeDoubleInstance { .. })),
            "expected BotMergeDoubleInstance, got {second:?}"
        );
    }

    #[tokio::test]
    async fn bot_merge_dry_run_succeeds_and_gates_auto_merge() {
        let tmp = TempDir::new().unwrap();
        let (_origin, work) = seed_origin_and_worktree(&tmp);

        let run_git = |args: &[&str]| {
            let st = std::process::Command::new("git")
                .arg("-C")
                .arg(&work)
                .args(args)
                .status()
                .unwrap();
            assert!(st.success());
        };

        run_git(&["checkout", "-b", "chump/infra-test-dry"]);
        std::fs::create_dir_all(work.join("src")).unwrap();
        std::fs::write(work.join("src/new.rs"), "pub fn x() {}\n").unwrap();
        run_git(&["add", "src/new.rs"]);
        run_git(&["commit", "-m", "feat(INFRA-TEST): clean"]);

        let intent = ShipIntent::owned(
            "INFRA-TEST",
            "chump/infra-test-dry",
            "main",
            "feat(INFRA-TEST): clean",
            unique_bot_id("s"),
        );
        let bot = BotMergePath::new(intent, &work, unique_bot_id("dry-clean"))
            .unwrap()
            .with_dry_run(true)
            .with_auto_merge(true);
        let receipt = bot.ship().await.expect("dry-run clean ship");
        assert!(receipt.auto_merge_armed);
        assert!(receipt.auto_merge_note.is_none());

        // Touch a gate file -> ship still succeeds, but auto_merge_armed is false!
        std::fs::create_dir_all(work.join("scripts/ci")).unwrap();
        std::fs::write(work.join("scripts/ci/test-gate.sh"), "#!/bin/sh\n").unwrap();
        run_git(&["add", "scripts/ci/test-gate.sh"]);
        run_git(&["commit", "-m", "chore: touch gate"]);

        let intent2 = ShipIntent::owned(
            "INFRA-TEST",
            "chump/infra-test-dry",
            "main",
            "feat(INFRA-TEST): gate",
            unique_bot_id("s2"),
        );
        let bot2 = BotMergePath::new(intent2, &work, unique_bot_id("dry-gate"))
            .unwrap()
            .with_dry_run(true)
            .with_auto_merge(true);
        let receipt2 = bot2.ship().await.expect("dry-run gate ship still opens PR");
        assert!(
            !receipt2.auto_merge_armed,
            "gate-file PR must NOT arm auto-merge"
        );
        assert!(
            receipt2
                .auto_merge_note
                .as_deref()
                .unwrap_or("")
                .contains("CREDIBLE-1576"),
            "expected CREDIBLE-1576 refusal note, got {:?}",
            receipt2.auto_merge_note
        );
    }

    #[tokio::test]
    async fn bot_merge_refuses_stale_branch_past_threshold() {
        let tmp = TempDir::new().unwrap();
        let (_origin, work) = seed_origin_and_worktree(&tmp);
        let run_git = |args: &[&str]| {
            let st = std::process::Command::new("git")
                .arg("-C")
                .arg(&work)
                .args(args)
                .status()
                .unwrap();
            assert!(st.success());
        };

        // Create feature branch off initial commit.
        run_git(&["checkout", "-b", "chump/stale-test"]);
        std::fs::write(work.join("feat.txt"), "1\n").unwrap();
        run_git(&["add", "feat.txt"]);
        run_git(&["commit", "-m", "feat"]);

        // Advance main by 2 commits on origin.
        run_git(&["checkout", "main"]);
        for i in 1..=2 {
            std::fs::write(work.join(format!("m{i}.txt")), "m\n").unwrap();
            run_git(&["add", "."]);
            run_git(&["commit", "-m", &format!("main {i}")]);
        }
        run_git(&["push", "origin", "main"]);
        run_git(&["checkout", "chump/stale-test"]);

        let intent = ShipIntent::owned(
            "INFRA-TEST",
            "chump/stale-test",
            "main",
            "feat",
            unique_bot_id("stale-s"),
        );
        let bot = BotMergePath::new(intent, &work, unique_bot_id("stale"))
            .unwrap()
            .with_dry_run(true)
            .with_stale_threshold(1);
        let err = bot.ship().await.unwrap_err();
        match err {
            ShipError::PreflightFailed { gate_name, .. } => {
                assert_eq!(gate_name, "stale_branch");
            }
            other => panic!("expected stale_branch PreflightFailed, got {other:?}"),
        }
    }

    #[test]
    fn record_gap_pr_at_upserts_and_enforces_single_gap_guard() {
        let tmp = TempDir::new().unwrap();
        let db_path = tmp.path().join(".chump/state.db");
        // Missing DB -> returns Ok(false) without creating a stray DB.
        assert!(!record_gap_pr_at(&db_path, "INFRA-B1", 101, "sha1").unwrap());
        assert!(!db_path.exists());

        // Create empty SQLite DB -> records gap_prs cleanly.
        std::fs::create_dir_all(db_path.parent().unwrap()).unwrap();
        let _conn = rusqlite::Connection::open(&db_path).unwrap();
        assert!(record_gap_pr_at(&db_path, "INFRA-B1", 101, "sha1").unwrap());
        // Idempotent re-run updates head_sha.
        assert!(record_gap_pr_at(&db_path, "INFRA-B1", 101, "sha2").unwrap());

        // Linking a different gap to the same PR without multi_ok fails per CREDIBLE-1559.
        let err = record_gap_pr_at(&db_path, "INFRA-B2", 101, "sha2").unwrap_err();
        assert!(err.contains("CREDIBLE-1559"), "got {err}");
    }
}
