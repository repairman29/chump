//! INFRA-667: track "session rescues" — commits on main where the human operator
//! directly authored the fix (rather than the fleet bot doing it autonomously).
//!
//! A rescue is any commit merged to main in the last 24h where:
//!   - The author email contains the operator's git identity (jeffadkins by default,
//!     overridable via `CHUMP_GIT_AUTHOR_EMAIL`), AND
//!   - The commit is not a GitHub merge-bot squash (filtered by subject pattern).
//!
//! High rescue counts mean the fleet is not self-sufficient.
//! Alert threshold: `CHUMP_SESSION_RESCUE_ALERT_24H` (default 2).
//!
//! Emits `kind=session_rescue` to ambient.jsonl for each rescue commit found
//! (deduplicated by commit hash across calls).

use std::path::Path;

/// One session rescue commit.
#[derive(Debug, Clone)]
pub struct RescueCommit {
    pub hash: String,
    pub subject: String,
    pub author_email: String,
}

/// Scan git log on the default branch for rescue commits in the last `window_hours` hours.
/// Returns the list found; caller decides whether to emit ambient events.
pub fn scan_rescues(repo_root: &Path, window_hours: u64) -> Vec<RescueCommit> {
    let operator_email =
        std::env::var("CHUMP_GIT_AUTHOR_EMAIL").unwrap_or_else(|_| "jeffadkins".to_string());

    let since = format!("{} hours ago", window_hours);
    // INFRA-1057: clear inherited git env so -C routes to repo_root, not the
    // parent shell's linked worktree when running tests from a worktree.
    let output = std::process::Command::new("git")
        .args([
            "-C",
            &repo_root.to_string_lossy(),
            "log",
            "origin/main",
            &format!("--since={}", since),
            "--format=%H\t%ae\t%s",
        ])
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_INDEX_FILE")
        .output();

    let output = match output {
        Ok(o) if o.status.success() => o,
        _ => return Vec::new(),
    };

    let text = String::from_utf8_lossy(&output.stdout);
    let mut rescues = Vec::new();

    for line in text.lines() {
        let parts: Vec<&str> = line.splitn(3, '\t').collect();
        if parts.len() < 3 {
            continue;
        }
        let hash = parts[0].to_string();
        let author_email = parts[1].to_string();
        let subject = parts[2].to_string();

        // Only count commits authored directly by the operator.
        if !author_email.contains(&operator_email) {
            continue;
        }

        // Filter out GitHub auto-merge bot squashes (operator is sometimes listed
        // as author on squash merges they didn't write — skip pure auto-merges).
        if is_auto_merge_subject(&subject) {
            continue;
        }

        rescues.push(RescueCommit {
            hash,
            subject,
            author_email,
        });
    }

    rescues
}

/// Emit a `kind=session_rescue` ambient event for each rescue commit.
/// Uses a state file to avoid re-emitting rescues already reported.
pub fn emit_rescue_events(repo_root: &Path, rescues: &[RescueCommit]) {
    if rescues.is_empty() {
        return;
    }
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let state_path = lock_dir.join("rescue-emitted.txt");
    let already_emitted: std::collections::HashSet<String> = std::fs::read_to_string(&state_path)
        .unwrap_or_default()
        .lines()
        .map(|l| l.to_string())
        .collect();

    let ambient = lock_dir.join("ambient.jsonl");
    let ts = iso8601_now();
    use std::io::Write as _;

    let mut new_hashes = Vec::new();
    for r in rescues {
        if already_emitted.contains(&r.hash) {
            continue;
        }
        let event = format!(
            r#"{{"ts":"{ts}","kind":"session_rescue","commit":"{hash}","subject":"{subj}","author":"{auth}"}}"#,
            ts = ts,
            hash = json_escape(&r.hash),
            subj = json_escape(&r.subject),
            auth = json_escape(&r.author_email),
        );
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&ambient)
        {
            let _ = writeln!(f, "{}", event);
        }
        new_hashes.push(r.hash.clone());
    }

    // Persist newly emitted hashes so we don't double-emit.
    if !new_hashes.is_empty() {
        let mut existing = std::fs::read_to_string(&state_path).unwrap_or_default();
        for h in &new_hashes {
            existing.push_str(h);
            existing.push('\n');
        }
        let _ = std::fs::write(&state_path, existing);
    }
}

/// Count session rescues in the last 24h without emitting ambient events.
/// Used by `chump health` for the health score.
pub fn count_rescues_24h(repo_root: &Path) -> u64 {
    scan_rescues(repo_root, 24).len() as u64
}

/// Alert threshold from env (default 2).
pub fn alert_threshold() -> u64 {
    std::env::var("CHUMP_SESSION_RESCUE_ALERT_24H")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2)
}

fn is_auto_merge_subject(subject: &str) -> bool {
    // GitHub auto-merge squash subjects look like: "Merge pull request #NNN" or
    // the chump bot-merge subject pattern: "feat(infra-NNN): ..." when the commit is
    // in the merge-bot's format but author shows as the squash-merger (Jeff).
    // We conservatively only skip explicit GitHub merge commits.
    subject.starts_with("Merge pull request #")
        || subject.starts_with("Merge branch '")
        || subject.contains("[skip ci]")
}

fn iso8601_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    std::process::Command::new("date")
        .args(["-u", "-r", &secs.to_string(), "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| format!("{}", secs))
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn infra667_auto_merge_filter() {
        assert!(is_auto_merge_subject(
            "Merge pull request #123 from foo/bar"
        ));
        assert!(is_auto_merge_subject("Merge branch 'main'"));
        assert!(!is_auto_merge_subject("fix(infra-667): rescue tally"));
        assert!(!is_auto_merge_subject(
            "feat(product-042): add health endpoint"
        ));
    }

    #[test]
    fn infra667_json_escape_roundtrip() {
        let escaped = json_escape("hello \"world\"\nbye");
        assert!(escaped.contains("\\\""));
        assert!(escaped.contains("\\n"));
    }

    #[test]
    fn infra667_alert_threshold_default() {
        // Without env var set, default is 2.
        let prev = std::env::var("CHUMP_SESSION_RESCUE_ALERT_24H").ok();
        std::env::remove_var("CHUMP_SESSION_RESCUE_ALERT_24H");
        assert_eq!(alert_threshold(), 2);
        if let Some(v) = prev {
            std::env::set_var("CHUMP_SESSION_RESCUE_ALERT_24H", v);
        }
    }

    #[test]
    fn infra667_alert_threshold_from_env() {
        std::env::set_var("CHUMP_SESSION_RESCUE_ALERT_24H", "5");
        assert_eq!(alert_threshold(), 5);
        std::env::remove_var("CHUMP_SESSION_RESCUE_ALERT_24H");
    }

    #[test]
    fn infra667_count_rescues_returns_zero_on_empty_repo() {
        let tmp = std::env::temp_dir().join("infra667-test-empty");
        std::fs::create_dir_all(&tmp).unwrap();
        // No git repo → git log fails → returns 0
        assert_eq!(count_rescues_24h(&tmp), 0);
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
