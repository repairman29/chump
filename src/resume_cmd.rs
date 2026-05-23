//! INFRA-1456: `chump resume <gap-id>` — reattach a wedged gap.
//!
//! AC#3: "chump resume <gap-id> reattaches a wedged gap to fleet rotation
//! after manual operator fix (validates worktree state + commit graph +
//! re-leases atomically)."
//!
//! v1 scope:
//!   - validate the lease still exists and the worktree directory is present
//!   - validate `git status` is clean enough to continue (no dangling
//!     rebase / merge / cherry-pick state)
//!   - emit `kind=gap_resumed` to ambient.jsonl with the validation result
//!   - print "ready for fleet rotation" next-step guidance
//!
//! The actual re-leasing is handled by the existing claim/lease machinery
//! — `chump resume` does the *validation* gate so the operator can see at
//! a glance whether the worktree is recoverable, then trigger fleet
//! restart manually. v2 (follow-up) wires automatic re-assignment via
//! NATS push routing (FLEET-034).

use anyhow::Result;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResumeVerdict {
    Ready,
    DirtyState { reason: String },
    WorktreeMissing,
    LeaseMissing,
}

impl ResumeVerdict {
    pub fn tag(&self) -> &'static str {
        match self {
            ResumeVerdict::Ready => "ready",
            ResumeVerdict::DirtyState { .. } => "dirty",
            ResumeVerdict::WorktreeMissing => "worktree_missing",
            ResumeVerdict::LeaseMissing => "lease_missing",
        }
    }

    pub fn summary(&self) -> String {
        match self {
            ResumeVerdict::Ready => "ready for fleet rotation".to_string(),
            ResumeVerdict::DirtyState { reason } => {
                format!("worktree dirty: {reason}")
            }
            ResumeVerdict::WorktreeMissing => {
                "worktree directory missing — run `chump scrap <gap-id>` then `chump claim <gap-id>`".to_string()
            }
            ResumeVerdict::LeaseMissing => {
                "no active lease for this gap — run `chump claim <gap-id>`".to_string()
            }
        }
    }
}

pub fn run(repo_root: &Path, gap_id: &str) -> Result<ResumeVerdict> {
    let target = match crate::inspect_cmd::locate_lease(repo_root, gap_id) {
        Ok(t) => t,
        Err(_) => return Ok(ResumeVerdict::LeaseMissing),
    };
    if !target.worktree.is_dir() {
        emit_resume_event(repo_root, gap_id, &ResumeVerdict::WorktreeMissing);
        return Ok(ResumeVerdict::WorktreeMissing);
    }

    // Detect dangling git state machine residues (rebase / merge /
    // cherry-pick) — these confuse a re-attached agent worse than a
    // clean stop would. Operator must resolve before resume.
    let verdict = validate_worktree(&target.worktree);
    emit_resume_event(repo_root, gap_id, &verdict);
    Ok(verdict)
}

pub fn validate_worktree(worktree: &Path) -> ResumeVerdict {
    let git_dir = worktree.join(".git");
    // For linked worktrees .git is a file, not a directory; both layouts work.
    if !git_dir.exists() {
        return ResumeVerdict::DirtyState {
            reason: format!(
                ".git not found under {} (INFRA-779 gitdir-confusion suspected)",
                worktree.display()
            ),
        };
    }

    // Check for in-progress operations.
    for marker in [
        "rebase-merge",
        "rebase-apply",
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
    ] {
        if marker_present(worktree, marker) {
            return ResumeVerdict::DirtyState {
                reason: format!(
                    "{marker} present — resolve via git rebase --continue/abort, git merge --abort, or git cherry-pick --abort"
                ),
            };
        }
    }

    // Reject if `git status --porcelain` has unstaged or untracked content
    // that would surprise an agent re-picking the gap. Allow nothing — the
    // operator is expected to commit or stash before resuming.
    let out = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(worktree)
        .output();
    if let Ok(o) = out {
        let body = String::from_utf8_lossy(&o.stdout);
        if !body.trim().is_empty() {
            return ResumeVerdict::DirtyState {
                reason: "uncommitted changes — commit or stash before resuming".to_string(),
            };
        }
    }

    ResumeVerdict::Ready
}

fn marker_present(worktree: &Path, marker: &str) -> bool {
    // Direct check first (regular repo).
    if worktree.join(".git").join(marker).exists() {
        return true;
    }
    // Linked worktree: .git is a file pointing at gitdir.
    let gitdir_file = worktree.join(".git");
    if gitdir_file.is_file() {
        if let Ok(s) = std::fs::read_to_string(&gitdir_file) {
            if let Some(rest) = s.trim().strip_prefix("gitdir: ") {
                let gitdir = std::path::Path::new(rest);
                if gitdir.join(marker).exists() {
                    return true;
                }
            }
        }
    }
    false
}

fn emit_resume_event(repo_root: &Path, gap_id: &str, v: &ResumeVerdict) {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let summary_esc = v.summary().replace('"', "\\\"");
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_resumed\",\"gap\":\"{}\",\"verdict\":\"{}\",\"summary\":\"{}\"}}\n",
        gap_id,
        v.tag(),
        summary_esc
    );
    if let Some(parent) = amb.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&amb)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn validate_worktree_flags_missing_git_dir() {
        let dir = tempdir().unwrap();
        // No .git at all.
        let v = validate_worktree(dir.path());
        match v {
            ResumeVerdict::DirtyState { reason } => assert!(reason.contains(".git not found")),
            other => panic!("expected DirtyState, got {other:?}"),
        }
    }

    #[test]
    fn validate_worktree_flags_rebase_in_progress() {
        let dir = tempdir().unwrap();
        let git = dir.path().join(".git");
        fs::create_dir_all(git.join("rebase-merge")).unwrap();
        // Note: we don't have a real git worktree here, so `git status`
        // will fail and the function will fall through. The rebase-merge
        // marker check fires before that, which is what we want.
        let v = validate_worktree(dir.path());
        match v {
            ResumeVerdict::DirtyState { reason } => assert!(reason.contains("rebase-merge")),
            other => panic!("expected DirtyState, got {other:?}"),
        }
    }

    #[test]
    fn verdict_summary_strings_are_human_readable() {
        assert!(ResumeVerdict::Ready.summary().contains("ready"));
        assert!(ResumeVerdict::WorktreeMissing.summary().contains("missing"));
        assert!(ResumeVerdict::LeaseMissing
            .summary()
            .contains("claim <gap-id>"));
        let d = ResumeVerdict::DirtyState {
            reason: "test reason".into(),
        };
        assert!(d.summary().contains("test reason"));
    }

    #[test]
    fn marker_present_handles_linked_worktree_gitdir_file() {
        let dir = tempdir().unwrap();
        let real_gitdir = dir.path().join(".chump/.git/worktrees/wt1");
        fs::create_dir_all(real_gitdir.join("rebase-apply")).unwrap();

        // .git is a FILE pointing at real_gitdir (linked-worktree shape).
        let wt = dir.path().join("wt1");
        fs::create_dir_all(&wt).unwrap();
        fs::write(
            wt.join(".git"),
            format!("gitdir: {}\n", real_gitdir.display()),
        )
        .unwrap();
        assert!(marker_present(&wt, "rebase-apply"));
        assert!(!marker_present(&wt, "MERGE_HEAD"));
    }
}
