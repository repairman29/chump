//! INFRA-1229 slice 1 — pure planner for the chump ship pipeline.
//!
//! This crate extracts the smallest pure kernel out of
//! `scripts/coord/bot-merge.sh` (2668 LOC of bash): the branching logic
//! that decides what action to take given a snapshot of PR + branch state.
//!
//! The planner does NO I/O. It takes [`PrSnapshot`] and [`RepoSnapshot`]
//! inputs and returns a [`ShipPlan`]. The CLI wrapper in `src/main.rs`
//! gathers snapshots via gh API + git, calls [`plan`], and prints the
//! result as JSON for bot-merge.sh to dispatch on (slice 2 will move the
//! dispatch into Rust as well).
//!
//! Decision priority (matches bot-merge.sh today):
//!   1. PR merged or closed → AlreadyDone
//!   2. No PR + commits → CreatePr
//!   3. behind > stale_threshold → StaleBranch (refuse)
//!   4. behind > 0 → RebaseAndPush
//!   5. mergeable=false + dirty → ConflictRecover
//!   6. all green + mergeable → RestDirectMerge (INFRA-1166 fast path)
//!   7. mergeable + pending checks + unarmed → ArmAutoMerge
//!   8. already armed → WaitForChecks
//!   9. mergeable=null (GH computing) → WaitForChecks
//!  10. unstable + failures (not conflict) → ConflictRecover
//!  11. anything else → OperatorAction

use serde::{Deserialize, Serialize};

/// PR existence + lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PrState {
    /// The PR doesn't exist yet on GitHub.
    None,
    Open,
    Closed,
    Merged,
}

/// GitHub's mergeable_state taxonomy. Values per the REST API; unknown
/// values map to `Unknown` so we fall through to OperatorAction safely.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MergeableState {
    /// Mergeable + all required checks passing.
    Clean,
    /// Mergeable but branch needs to be updated to base.
    Behind,
    /// Mergeable but blocked by required-reviewers / branch protection.
    Blocked,
    /// Merge conflict; needs manual resolution.
    Dirty,
    /// Some required checks are failing (not a merge conflict).
    Unstable,
    /// Pre-merge hooks (e.g. status checks) still running.
    HasHooks,
    /// GitHub hasn't computed mergeability yet, or unknown taxonomy value.
    Unknown,
}

/// Roll-up of CI check states for the PR's head commit.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChecksSummary {
    pub total: u32,
    pub completed_success: u32,
    pub completed_failure: u32,
    /// pending, in-flight, queued
    pub incomplete: u32,
    /// neutral, skipped, cancelled — informational, don't gate merge
    pub neutral_or_skipped: u32,
}

impl ChecksSummary {
    /// All required checks resolved to success.
    pub fn all_green(&self) -> bool {
        self.total > 0 && self.incomplete == 0 && self.completed_failure == 0
    }
    pub fn any_failed(&self) -> bool {
        self.completed_failure > 0
    }
}

/// Snapshot of the PR (or its absence).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrSnapshot {
    /// PR number; None means no PR exists yet for this branch.
    pub number: Option<u64>,
    pub state: PrState,
    /// GitHub-side `mergeable` boolean (None = still computing).
    pub mergeable: Option<bool>,
    pub mergeable_state: MergeableState,
    pub auto_merge_set: bool,
    pub head_sha: String,
    pub base_sha: String,
    pub checks: ChecksSummary,
}

impl PrSnapshot {
    /// Convenience: PR exists in any state (open/closed/merged).
    pub fn exists(&self) -> bool {
        self.number.is_some() && self.state != PrState::None
    }
}

/// Snapshot of the local branch + its position vs `origin/main`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoSnapshot {
    pub branch: String,
    /// Commits in `origin/main` not in HEAD.
    pub behind_main: u32,
    /// Commits in HEAD not in `origin/main`.
    pub ahead_main: u32,
    pub has_uncommitted: bool,
    /// CHUMP_BOT_MERGE_STALE_THRESHOLD — refuse rebase past this point.
    pub stale_threshold: u32,
}

/// Outcome of the planner. Each variant carries enough info for either a
/// machine consumer (slice 2's executor) or a human operator to act.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "PascalCase")]
pub enum ShipPlan {
    /// PR already merged or closed — nothing to ship; close registry side.
    AlreadyDone {
        pr: u64,
        state: PrState,
        recovery_hint: String,
    },
    /// Branch has commits but no PR yet — push (if needed) and create PR.
    CreatePr {
        branch: String,
        ahead: u32,
    },
    /// Branch behind main, within stale threshold — rebase + force-push.
    RebaseAndPush { behind_count: u32 },
    /// All required checks green, mergeable → REST PUT directly (INFRA-1166).
    RestDirectMerge {
        pr: u64,
        head_sha: String,
        checks_verified: u32,
    },
    /// Mergeable, checks still resolving → arm auto-merge.
    ArmAutoMerge {
        pr: u64,
        reason: String,
    },
    /// Already armed and waiting on checks/review.
    WaitForChecks {
        pr: u64,
        incomplete: u32,
        reason: String,
    },
    /// Behind main past the stale threshold — refuse to rebase blindly.
    StaleBranch {
        pr: Option<u64>,
        behind: u32,
        threshold: u32,
        recovery_hint: String,
    },
    /// Mergeable=false + dirty (merge conflict) OR unstable failures.
    ConflictRecover {
        pr: u64,
        recovery_hint: String,
    },
    /// State the planner can't handle confidently — surface to operator.
    OperatorAction {
        reason: String,
        recovery_hint: String,
    },
}

/// Pure planner. No I/O. Decisions only.
pub fn plan(pr: &PrSnapshot, repo: &RepoSnapshot) -> ShipPlan {
    // 1. PR already merged or closed.
    if let Some(num) = pr.number {
        match pr.state {
            PrState::Merged => {
                return ShipPlan::AlreadyDone {
                    pr: num,
                    state: PrState::Merged,
                    recovery_hint: format!(
                        "PR #{num} merged. Run `chump gap ship <ID> --closed-pr {num} --update-yaml` to close the registry side."
                    ),
                };
            }
            PrState::Closed => {
                return ShipPlan::AlreadyDone {
                    pr: num,
                    state: PrState::Closed,
                    recovery_hint: format!(
                        "PR #{num} closed without merging. Inspect with `gh pr view {num}` before re-opening or filing a new gap."
                    ),
                };
            }
            _ => {}
        }
    }

    // 2. No PR yet — if branch is ahead of main, create one.
    if !pr.exists() {
        if repo.ahead_main > 0 {
            return ShipPlan::CreatePr {
                branch: repo.branch.clone(),
                ahead: repo.ahead_main,
            };
        }
        return ShipPlan::OperatorAction {
            reason: "Branch has no PR and no commits ahead of main — nothing to ship.".to_string(),
            recovery_hint: "Make commits on this branch before invoking ship, or check that you're on the intended branch.".to_string(),
        };
    }

    let pr_num = pr.number.expect("pr.exists() ensures number is Some");

    // 3. Branch too far behind — refuse.
    if repo.behind_main > repo.stale_threshold {
        return ShipPlan::StaleBranch {
            pr: Some(pr_num),
            behind: repo.behind_main,
            threshold: repo.stale_threshold,
            recovery_hint: format!(
                "Branch is {} commits behind main (threshold {}). Manual rebase recommended — run `git fetch && git rebase origin/main` and inspect for non-trivial conflicts before pushing.",
                repo.behind_main, repo.stale_threshold
            ),
        };
    }

    // 4. Behind main but within threshold — rebase + force-push.
    if repo.behind_main > 0 {
        return ShipPlan::RebaseAndPush {
            behind_count: repo.behind_main,
        };
    }

    // 5. PR exists, mergeable=false + dirty → conflict recovery.
    if pr.mergeable == Some(false) && pr.mergeable_state == MergeableState::Dirty {
        return ShipPlan::ConflictRecover {
            pr: pr_num,
            recovery_hint: format!(
                "PR #{pr_num} has merge conflicts. Run `gh pr checkout {pr_num}`, resolve conflicts in the affected files, then force-push the rebased branch."
            ),
        };
    }

    // 10. Unstable state — at least one check failing (not a merge conflict).
    if pr.checks.any_failed() && pr.mergeable_state == MergeableState::Unstable {
        return ShipPlan::ConflictRecover {
            pr: pr_num,
            recovery_hint: format!(
                "PR #{pr_num} has {} failing check(s). Inspect with `gh pr checks {pr_num}` — fix the failures and force-push, OR file a flake-rerun follow-up if the failure is known-flaky.",
                pr.checks.completed_failure
            ),
        };
    }

    // 6. All required checks green + mergeable → REST PUT fast path.
    if pr.checks.all_green() && pr.mergeable == Some(true) && !pr.auto_merge_set {
        return ShipPlan::RestDirectMerge {
            pr: pr_num,
            head_sha: pr.head_sha.clone(),
            checks_verified: pr.checks.total,
        };
    }

    // 7. mergeable=true + pending checks + not yet armed → arm auto-merge.
    if pr.mergeable == Some(true) && !pr.auto_merge_set && pr.checks.incomplete > 0 {
        return ShipPlan::ArmAutoMerge {
            pr: pr_num,
            reason: format!(
                "PR #{pr_num} mergeable, {}/{} checks completed, {} in-flight. Arm auto-merge to fire when CI finishes.",
                pr.checks.completed_success,
                pr.checks.total,
                pr.checks.incomplete
            ),
        };
    }

    // 8. Already armed — let the queue handle it.
    if pr.auto_merge_set {
        return ShipPlan::WaitForChecks {
            pr: pr_num,
            incomplete: pr.checks.incomplete,
            reason: format!(
                "PR #{pr_num} already armed; {} check(s) outstanding. No action needed.",
                pr.checks.incomplete
            ),
        };
    }

    // 9. mergeable=null — GitHub still computing. Wait for the next pass.
    if pr.mergeable.is_none() {
        return ShipPlan::WaitForChecks {
            pr: pr_num,
            incomplete: pr.checks.incomplete,
            reason: format!(
                "PR #{pr_num} mergeability still being computed by GitHub. Retry shortly."
            ),
        };
    }

    // Fallback.
    ShipPlan::OperatorAction {
        reason: format!(
            "Uncovered state for PR #{pr_num}: mergeable={:?}, mergeable_state={:?}, auto_merge_set={}, checks={:?}",
            pr.mergeable, pr.mergeable_state, pr.auto_merge_set, pr.checks
        ),
        recovery_hint: format!(
            "Inspect manually with `gh pr view {pr_num} --json mergeStateStatus,statusCheckRollup` and either retry once the state resolves OR file a planner-gap to handle this case."
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_pr(num: u64, state: PrState) -> PrSnapshot {
        PrSnapshot {
            number: Some(num),
            state,
            mergeable: None,
            mergeable_state: MergeableState::Unknown,
            auto_merge_set: false,
            head_sha: "abc1234".into(),
            base_sha: "def5678".into(),
            checks: ChecksSummary::default(),
        }
    }
    fn no_pr() -> PrSnapshot {
        PrSnapshot {
            number: None,
            state: PrState::None,
            mergeable: None,
            mergeable_state: MergeableState::Unknown,
            auto_merge_set: false,
            head_sha: "abc1234".into(),
            base_sha: "def5678".into(),
            checks: ChecksSummary::default(),
        }
    }
    fn mk_repo(behind: u32, ahead: u32) -> RepoSnapshot {
        RepoSnapshot {
            branch: "chump/test".into(),
            behind_main: behind,
            ahead_main: ahead,
            has_uncommitted: false,
            stale_threshold: 15,
        }
    }

    #[test]
    fn merged_pr_yields_already_done() {
        let pr = mk_pr(1913, PrState::Merged);
        let repo = mk_repo(0, 0);
        match plan(&pr, &repo) {
            ShipPlan::AlreadyDone { pr: n, state, .. } => {
                assert_eq!(n, 1913);
                assert_eq!(state, PrState::Merged);
            }
            other => panic!("expected AlreadyDone(Merged), got {other:?}"),
        }
    }

    #[test]
    fn closed_pr_yields_already_done() {
        let pr = mk_pr(1913, PrState::Closed);
        let repo = mk_repo(0, 0);
        assert!(matches!(plan(&pr, &repo), ShipPlan::AlreadyDone { state: PrState::Closed, .. }));
    }

    #[test]
    fn no_pr_with_commits_yields_create_pr() {
        let pr = no_pr();
        let repo = mk_repo(0, 3);
        match plan(&pr, &repo) {
            ShipPlan::CreatePr { ahead, .. } => assert_eq!(ahead, 3),
            other => panic!("expected CreatePr, got {other:?}"),
        }
    }

    #[test]
    fn no_pr_no_commits_yields_operator_action() {
        let pr = no_pr();
        let repo = mk_repo(0, 0);
        assert!(matches!(plan(&pr, &repo), ShipPlan::OperatorAction { .. }));
    }

    #[test]
    fn behind_threshold_yields_stale_branch() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        let repo = mk_repo(20, 5); // 20 > 15 threshold
        match plan(&pr, &repo) {
            ShipPlan::StaleBranch { behind, threshold, .. } => {
                assert_eq!(behind, 20);
                assert_eq!(threshold, 15);
            }
            other => panic!("expected StaleBranch, got {other:?}"),
        }
    }

    #[test]
    fn behind_within_threshold_yields_rebase_and_push() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        let repo = mk_repo(5, 3); // 5 <= 15 threshold
        match plan(&pr, &repo) {
            ShipPlan::RebaseAndPush { behind_count } => assert_eq!(behind_count, 5),
            other => panic!("expected RebaseAndPush, got {other:?}"),
        }
    }

    #[test]
    fn dirty_mergeable_state_yields_conflict_recover() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(false);
        pr.mergeable_state = MergeableState::Dirty;
        let repo = mk_repo(0, 3);
        assert!(matches!(plan(&pr, &repo), ShipPlan::ConflictRecover { .. }));
    }

    #[test]
    fn all_checks_green_unarmed_yields_rest_direct_merge() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.mergeable_state = MergeableState::Clean;
        pr.checks = ChecksSummary {
            total: 7,
            completed_success: 7,
            completed_failure: 0,
            incomplete: 0,
            neutral_or_skipped: 0,
        };
        let repo = mk_repo(0, 3);
        match plan(&pr, &repo) {
            ShipPlan::RestDirectMerge { pr: n, checks_verified, .. } => {
                assert_eq!(n, 1913);
                assert_eq!(checks_verified, 7);
            }
            other => panic!("expected RestDirectMerge, got {other:?}"),
        }
    }

    #[test]
    fn mergeable_with_pending_checks_yields_arm_auto_merge() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.mergeable_state = MergeableState::HasHooks;
        pr.checks = ChecksSummary {
            total: 10,
            completed_success: 6,
            completed_failure: 0,
            incomplete: 4,
            neutral_or_skipped: 0,
        };
        let repo = mk_repo(0, 3);
        assert!(matches!(plan(&pr, &repo), ShipPlan::ArmAutoMerge { .. }));
    }

    #[test]
    fn already_armed_yields_wait_for_checks() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.auto_merge_set = true;
        pr.checks.incomplete = 2;
        let repo = mk_repo(0, 3);
        match plan(&pr, &repo) {
            ShipPlan::WaitForChecks { pr: n, incomplete, .. } => {
                assert_eq!(n, 1913);
                assert_eq!(incomplete, 2);
            }
            other => panic!("expected WaitForChecks, got {other:?}"),
        }
    }

    #[test]
    fn mergeable_null_yields_wait_for_checks() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = None;
        let repo = mk_repo(0, 3);
        assert!(matches!(plan(&pr, &repo), ShipPlan::WaitForChecks { .. }));
    }

    #[test]
    fn unstable_with_failures_yields_conflict_recover() {
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.mergeable_state = MergeableState::Unstable;
        pr.checks = ChecksSummary {
            total: 10,
            completed_success: 8,
            completed_failure: 2,
            incomplete: 0,
            neutral_or_skipped: 0,
        };
        let repo = mk_repo(0, 3);
        match plan(&pr, &repo) {
            ShipPlan::ConflictRecover { recovery_hint, .. } => {
                assert!(recovery_hint.contains("failing check"));
            }
            other => panic!("expected ConflictRecover (CI failure), got {other:?}"),
        }
    }

    #[test]
    fn behind_takes_priority_over_arm() {
        // Even if PR is mergeable, behind > 0 should rebase first.
        let mut pr = mk_pr(1913, PrState::Open);
        pr.mergeable = Some(true);
        pr.mergeable_state = MergeableState::Clean;
        pr.checks = ChecksSummary {
            total: 5,
            completed_success: 5,
            completed_failure: 0,
            incomplete: 0,
            neutral_or_skipped: 0,
        };
        let repo = mk_repo(3, 1);
        assert!(matches!(plan(&pr, &repo), ShipPlan::RebaseAndPush { .. }));
    }

    #[test]
    fn merged_pr_with_behind_still_already_done() {
        // Merged PR with branch behind main — still AlreadyDone, no rebase.
        let pr = mk_pr(1913, PrState::Merged);
        let repo = mk_repo(5, 0);
        assert!(matches!(plan(&pr, &repo), ShipPlan::AlreadyDone { .. }));
    }
}
