//! INFRA-1456: `chump scrap <gap-id>` — clean teardown of a wedged gap.
//!
//! AC#4: "chump scrap <gap-id> cleanly destroys worktree directory, kills
//! any associated sandbox container, releases lease, leaves zero
//! host-fs/disk-port/container residue."
//!
//! v1 scope:
//!   - remove the linked git worktree (`git worktree remove --force`)
//!   - delete the lease JSON file from .chump-locks/
//!   - emit `kind=gap_scrapped` to ambient.jsonl
//!   - prune dangling git worktree refs
//!
//! v2 (follow-up gap): if INFRA-1454 sandbox launched a container, stop
//! and remove it. v1 INFRA-1454 sandbox is `sandbox-exec` (no container)
//! so nothing to clean.

use anyhow::{anyhow, Result};
use std::path::Path;
use std::process::Command;

use crate::inspect_cmd::InspectTarget;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScrapOutcome {
    pub worktree_removed: bool,
    pub lease_removed: bool,
    pub branch_deleted: bool,
}

pub fn run(repo_root: &Path, gap_id: &str) -> Result<ScrapOutcome> {
    let target = crate::inspect_cmd::locate_lease(repo_root, gap_id)?;
    let outcome = scrap(repo_root, &target)?;
    emit_scrap_event(repo_root, &target, &outcome);
    Ok(outcome)
}

fn scrap(repo_root: &Path, t: &InspectTarget) -> Result<ScrapOutcome> {
    let mut worktree_removed = false;
    if t.worktree.is_dir() {
        let out = Command::new("git")
            .args([
                "worktree",
                "remove",
                "--force",
                &t.worktree.display().to_string(),
            ])
            .current_dir(repo_root)
            .output()
            .map_err(|e| anyhow!("git worktree remove spawn: {e}"))?;
        if out.status.success() {
            worktree_removed = true;
        } else {
            // If the worktree's gitdir is corrupt (INFRA-779 surface),
            // git refuses. Fall back to a plain `rm -rf` of the directory
            // and then `git worktree prune` to clean refs.
            let _ = std::fs::remove_dir_all(&t.worktree);
            worktree_removed = !t.worktree.is_dir();
        }
    }
    // Always prune dangling refs whether or not the directory existed.
    let _ = Command::new("git")
        .args(["worktree", "prune"])
        .current_dir(repo_root)
        .status();

    let lease_path = repo_root
        .join(".chump-locks")
        .join(format!("{}.json", t.session));
    let lease_removed = if lease_path.exists() {
        std::fs::remove_file(&lease_path).is_ok()
    } else {
        // Some lease files are named differently (older sessions). Best-effort:
        // walk the dir and delete any JSON whose `gap_id` matches.
        delete_leases_matching(repo_root, &t.gap_id)
    };

    let branch_deleted = if let Some(branch) = &t.branch {
        Command::new("git")
            .args(["branch", "-D", branch])
            .current_dir(repo_root)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    } else {
        false
    };

    Ok(ScrapOutcome {
        worktree_removed,
        lease_removed,
        branch_deleted,
    })
}

fn delete_leases_matching(repo_root: &Path, gap_id: &str) -> bool {
    let locks = repo_root.join(".chump-locks");
    let Ok(entries) = std::fs::read_dir(&locks) else {
        return false;
    };
    let mut any = false;
    for ent in entries.flatten() {
        let p = ent.path();
        if p.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&p) else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        if json
            .get("gap_id")
            .and_then(|v| v.as_str())
            .map(|s| s.eq_ignore_ascii_case(gap_id))
            .unwrap_or(false)
            && std::fs::remove_file(&p).is_ok()
        {
            any = true;
        }
    }
    any
}

fn emit_scrap_event(repo_root: &Path, t: &InspectTarget, o: &ScrapOutcome) {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"gap_scrapped\",\"gap\":\"{}\",\"session\":\"{}\",\"worktree_removed\":{},\"lease_removed\":{},\"branch_deleted\":{}}}\n",
        t.gap_id, t.session, o.worktree_removed, o.lease_removed, o.branch_deleted
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
    fn scrap_removes_orphan_lease_when_worktree_missing() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();
        let fake_wt = dir.path().join("nope");
        let session = "claim-infra-9100-1";
        let lease = serde_json::json!({
            "gap_id": "INFRA-9100",
            "session": session,
            "worktree": fake_wt.display().to_string(),
            "branch": "chump/infra-9100-claim",
        });
        fs::write(locks.join(format!("{session}.json")), lease.to_string()).unwrap();

        let t = crate::inspect_cmd::InspectTarget {
            gap_id: "INFRA-9100".into(),
            session: session.into(),
            worktree: fake_wt.clone(),
            branch: Some("chump/infra-9100-claim".into()),
        };
        let outcome = scrap(dir.path(), &t).expect("scrap");
        assert!(!outcome.worktree_removed, "no worktree to remove");
        assert!(outcome.lease_removed, "lease file should be deleted");
        assert!(!locks.join(format!("{session}.json")).exists());
    }

    #[test]
    fn delete_leases_matching_finds_by_gap_id_when_session_name_differs() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();
        let lease = serde_json::json!({
            "gap_id": "INFRA-9101",
            "session": "oddly-named-session-xyz",
            "worktree": "/nope",
        });
        let lease_path = locks.join("unmatched-filename.json");
        fs::write(&lease_path, lease.to_string()).unwrap();
        assert!(delete_leases_matching(dir.path(), "INFRA-9101"));
        assert!(!lease_path.exists());
    }

    #[test]
    fn emit_scrap_event_writes_jsonl_line() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();
        let t = crate::inspect_cmd::InspectTarget {
            gap_id: "INFRA-9102".into(),
            session: "s".into(),
            worktree: dir.path().to_path_buf(),
            branch: None,
        };
        let o = ScrapOutcome {
            worktree_removed: true,
            lease_removed: true,
            branch_deleted: false,
        };
        emit_scrap_event(dir.path(), &t, &o);
        let text = fs::read_to_string(locks.join("ambient.jsonl")).unwrap();
        assert!(text.contains("gap_scrapped"));
        assert!(text.contains("INFRA-9102"));
        assert!(text.contains("\"worktree_removed\":true"));
    }
}
