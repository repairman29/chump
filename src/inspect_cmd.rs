//! INFRA-1456: `chump inspect <gap-id>` — eject-and-inspect debug surface.
//!
//! Marcus's Saturday-morning-uninstall scenario (Persona-5 skeptic):
//! > "20-agent fleet runs Friday night, 18 green / 2 wedged. If I can't
//! > tell why those 2 are wedged in under 60 seconds, the Chump abstraction
//! > becomes net-negative — I'm debugging Chump instead of my codebase."
//!
//! When `tmux` is available, opens a 3-pane session for the given gap:
//!   1. Worktree shell (cd'd in to the lease's worktree)
//!   2. `tail -F ambient.jsonl | grep <gap-id>` — live event filter
//!   3. Recent ambient events for the gap (snapshot) + "trajectory pending
//!      [follow-up gap INFRA-XXXX]" placeholder
//!
//! When `tmux` is not available, prints the three sections sequentially
//! as text. Either way the gap must have an active lease whose
//! worktree directory still exists; otherwise prints a clear error
//! pointing at INFRA-779 gitdir-recovery if relevant.

use anyhow::{anyhow, Result};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Resolved view of a gap's lease for inspection.
#[derive(Debug, Clone)]
pub struct InspectTarget {
    pub gap_id: String,
    pub session: String,
    pub worktree: PathBuf,
    pub branch: Option<String>,
}

/// Locate the active lease for `gap_id` by scanning `.chump-locks/*.json`.
/// Returns the first match; for resilience to stale or duplicate files we
/// prefer leases whose worktree path actually exists on disk.
pub fn locate_lease(repo_root: &Path, gap_id: &str) -> Result<InspectTarget> {
    let locks_dir = repo_root.join(".chump-locks");
    let entries =
        std::fs::read_dir(&locks_dir).map_err(|e| anyhow!("read {}: {e}", locks_dir.display()))?;
    let mut candidates: Vec<InspectTarget> = Vec::new();
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
        let g = json
            .get("gap_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if !g.eq_ignore_ascii_case(gap_id) {
            continue;
        }
        let session = json
            .get("session")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let worktree_str = json
            .get("worktree")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        let branch = json
            .get("branch")
            .and_then(|v| v.as_str())
            .map(String::from);
        candidates.push(InspectTarget {
            gap_id: g,
            session,
            worktree: PathBuf::from(worktree_str),
            branch,
        });
    }

    if candidates.is_empty() {
        return Err(anyhow!(
            "no active lease for {gap_id} — run `chump --leases` to list known sessions"
        ));
    }
    // Prefer one with a live worktree directory.
    candidates.sort_by_key(|t| !t.worktree.is_dir());
    Ok(candidates.into_iter().next().unwrap())
}

/// Recent ambient events for the gap (snapshot). Greps the file because
/// keeping a structured index across rotates is out of scope for v1.
pub fn recent_ambient_for(repo_root: &Path, gap_id: &str, max_lines: usize) -> Vec<String> {
    let amb = repo_root.join(".chump-locks").join("ambient.jsonl");
    let Ok(text) = std::fs::read_to_string(&amb) else {
        return Vec::new();
    };
    let needle_id = gap_id;
    let needle_session = format!("claim-{}-", gap_id.to_lowercase());
    let mut hits: Vec<String> = text
        .lines()
        .filter(|l| l.contains(needle_id) || l.contains(needle_session.as_str()))
        .map(|s| s.to_string())
        .collect();
    if hits.len() > max_lines {
        let start = hits.len() - max_lines;
        hits = hits.split_off(start);
    }
    hits
}

/// Run the inspect command. `use_tmux` lets tests force the text path even
/// when tmux is available.
pub fn run(repo_root: &Path, gap_id: &str, use_tmux: bool) -> Result<()> {
    let target = locate_lease(repo_root, gap_id)?;
    let worktree_ok = target.worktree.is_dir();
    if !worktree_ok {
        eprintln!(
            "warning: lease worktree {} not present on disk; showing text snapshot only",
            target.worktree.display()
        );
        eprintln!("       INFRA-779 gitdir-confusion recovery: try `chump --release --lease {} && chump claim {}`",
                  target.session, target.gap_id);
    }

    if use_tmux && worktree_ok && have_tmux() {
        return tmux_session(repo_root, &target);
    }
    text_snapshot(repo_root, &target);
    Ok(())
}

fn have_tmux() -> bool {
    Command::new("tmux")
        .arg("-V")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn tmux_session(repo_root: &Path, t: &InspectTarget) -> Result<()> {
    let session_name = format!("chump-inspect-{}", t.gap_id.to_lowercase());
    let ambient = repo_root.join(".chump-locks").join("ambient.jsonl");

    // Kill any leftover session by the same name (idempotent).
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", &session_name])
        .status();

    let mut new = Command::new("tmux");
    new.args([
        "new-session",
        "-d",
        "-s",
        &session_name,
        "-c",
        &t.worktree.display().to_string(),
    ]);
    if !new.status().map(|s| s.success()).unwrap_or(false) {
        return Err(anyhow!("tmux new-session failed"));
    }

    // Pane 2: split right — ambient tail filtered to this gap.
    let tail_cmd = format!(
        "tail -F {} | grep --line-buffered -E '{}|claim-{}-'",
        shell_escape(&ambient.display().to_string()),
        t.gap_id,
        t.gap_id.to_lowercase()
    );
    let _ = Command::new("tmux")
        .args(["split-window", "-h", "-t", &session_name, &tail_cmd])
        .status();

    // Pane 3: split down from pane 2 — last 50 ambient events for this gap
    // followed by a clear "trajectory capture pending" note.
    let grep_part = format!(
        "grep -E '{}|claim-{}-' {} 2>/dev/null | tail -50 || true",
        t.gap_id,
        t.gap_id.to_lowercase(),
        shell_escape(&ambient.display().to_string())
    );
    let snap_cmd = format!(
        "{grep_part} && echo '---' && echo 'trajectory capture (per-bash cmd/cwd/exit) is a follow-up gap.'"
    );
    let _ = Command::new("tmux")
        .args(["split-window", "-v", "-t", &session_name, &snap_cmd])
        .status();

    // Attach.
    let _ = Command::new("tmux")
        .args(["attach-session", "-t", &session_name])
        .status();
    Ok(())
}

fn text_snapshot(repo_root: &Path, t: &InspectTarget) {
    println!("=== chump inspect {} ===", t.gap_id);
    println!("  session  : {}", t.session);
    println!(
        "  worktree : {} ({})",
        t.worktree.display(),
        if t.worktree.is_dir() {
            "present"
        } else {
            "MISSING"
        }
    );
    if let Some(b) = &t.branch {
        println!("  branch   : {b}");
    }
    println!();
    println!("--- recent ambient events (last 50) ---");
    let recent = recent_ambient_for(repo_root, &t.gap_id, 50);
    if recent.is_empty() {
        println!("  (none)");
    } else {
        for line in recent {
            println!("  {line}");
        }
    }
    println!();
    println!("--- next steps ---");
    if t.worktree.is_dir() {
        println!("  cd {}", t.worktree.display());
        println!(
            "  # then `git status`, inspect, fix, and `chump resume {}`",
            t.gap_id
        );
    } else {
        println!(
            "  worktree missing — use `chump scrap {}` to clear the orphan lease",
            t.gap_id
        );
    }
}

fn shell_escape(s: &str) -> String {
    // Cheap quoting for tmux command strings; works for the paths we feed.
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn locate_lease_finds_match_and_prefers_present_worktree() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();

        // Lease A — worktree path does NOT exist.
        let wt_a = dir.path().join("nope-a");
        let lease_a = serde_json::json!({
            "gap_id": "INFRA-9001",
            "session": "claim-infra-9001-1",
            "worktree": wt_a.display().to_string(),
            "branch": "chump/infra-9001-claim",
        });
        fs::write(locks.join("a.json"), lease_a.to_string()).unwrap();

        // Lease B — worktree path DOES exist (we create it).
        let wt_b = dir.path().join("present-b");
        fs::create_dir_all(&wt_b).unwrap();
        let lease_b = serde_json::json!({
            "gap_id": "INFRA-9001",
            "session": "claim-infra-9001-2",
            "worktree": wt_b.display().to_string(),
            "branch": "chump/infra-9001-claim",
        });
        fs::write(locks.join("b.json"), lease_b.to_string()).unwrap();

        let t = locate_lease(dir.path(), "INFRA-9001").expect("locate");
        // Should prefer the lease whose worktree actually exists.
        assert_eq!(t.worktree, wt_b);
        assert_eq!(t.gap_id, "INFRA-9001");
    }

    #[test]
    fn locate_lease_errors_when_no_match() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join(".chump-locks")).unwrap();
        let err = locate_lease(dir.path(), "INFRA-NOPE").unwrap_err();
        assert!(err.to_string().contains("no active lease"));
    }

    #[test]
    fn recent_ambient_filters_by_gap_id() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();
        let amb = locks.join("ambient.jsonl");
        let content = r#"{"ts":"t1","kind":"x","gap":"INFRA-9002"}
{"ts":"t2","kind":"x","gap":"INFRA-OTHER"}
{"ts":"t3","kind":"x","session":"claim-infra-9002-1"}
"#;
        fs::write(&amb, content).unwrap();
        let lines = recent_ambient_for(dir.path(), "INFRA-9002", 10);
        assert_eq!(lines.len(), 2);
        assert!(lines.iter().any(|l| l.contains("\"t1\"")));
        assert!(lines.iter().any(|l| l.contains("\"t3\"")));
        assert!(lines.iter().all(|l| !l.contains("\"t2\"")));
    }

    #[test]
    fn recent_ambient_caps_max_lines() {
        let dir = tempdir().unwrap();
        let locks = dir.path().join(".chump-locks");
        fs::create_dir_all(&locks).unwrap();
        let amb = locks.join("ambient.jsonl");
        let mut content = String::new();
        for i in 0..120 {
            content.push_str(&format!("{{\"ts\":\"t{i}\",\"gap\":\"INFRA-9003\"}}\n"));
        }
        fs::write(&amb, content).unwrap();
        let lines = recent_ambient_for(dir.path(), "INFRA-9003", 25);
        assert_eq!(lines.len(), 25);
        // The 25 returned should be the LAST 25 (most recent).
        assert!(lines.last().unwrap().contains("\"t119\""));
    }
}
