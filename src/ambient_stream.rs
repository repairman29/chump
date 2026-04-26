//! INFRA-084 — read `.chump-locks/ambient.jsonl` and surface recent
//! sibling-session activity as a prompt-injectable summary block.
//!
//! Layer 2 of the ambient-glance discipline (Layer 1 lives in
//! `scripts/chump-ambient-glance.sh`). Both layers read the same shared
//! `ambient.jsonl` and apply the same self-session exclusion rules so a
//! chump-local agent's view of "what other agents are doing right now" is
//! consistent whether they got there via bot-merge.sh's pre-push glance or
//! via the prompt the agent loop just assembled.
//!
//! The reader is deliberately resilient: malformed JSON lines are skipped,
//! a missing file returns an empty Vec, and clock skew is tolerated by
//! comparing wall-clock deltas only when the timestamp parses cleanly.

use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};

/// One sibling-session event extracted from `ambient.jsonl`. Fields beyond
/// what the prompt block needs are intentionally dropped — this is a
/// projection of the schema, not a full deserialization.
#[derive(Debug, Clone)]
pub struct AmbientEvent {
    pub ts: DateTime<Utc>,
    pub session: String,
    pub kind: String,
    pub summary: String,
}

#[derive(Debug, Deserialize)]
struct RawEvent {
    #[serde(default)]
    ts: String,
    #[serde(default)]
    session: String,
    #[serde(default)]
    event: String,
    #[serde(default)]
    gap: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    sha: Option<String>,
    #[serde(default)]
    cmd: Option<String>,
    #[serde(default)]
    files: Option<String>,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    msg: Option<String>,
}

/// Locate the shared `ambient.jsonl` path. Walks up from `start` looking for
/// a `.chump-locks/ambient.jsonl`. Worktrees under `.claude/worktrees/<name>/`
/// share the main repo's `.chump-locks/`, so this walk hops past the
/// worktree boundary on its own.
pub fn locate_ambient(start: &Path) -> Option<PathBuf> {
    let mut cur: Option<&Path> = Some(start);
    while let Some(dir) = cur {
        let candidate = dir.join(".chump-locks").join("ambient.jsonl");
        if candidate.is_file() {
            return Some(candidate);
        }
        cur = dir.parent();
    }
    None
}

/// Resolve the current session ID using the same priority chain as
/// `scripts/gap-claim.sh`:
///   1. `CHUMP_SESSION_ID` (explicit override)
///   2. `CLAUDE_SESSION_ID` (Claude Code SDK)
///   3. `<worktree>/.chump-locks/.wt-session-id`
///   4. `<main-repo>/.chump-locks/.wt-session-id`
///   5. `$HOME/.chump/session_id`
pub fn current_session_id(repo_root: &Path) -> Option<String> {
    if let Ok(s) = std::env::var("CHUMP_SESSION_ID") {
        if !s.is_empty() {
            return Some(s);
        }
    }
    if let Ok(s) = std::env::var("CLAUDE_SESSION_ID") {
        if !s.is_empty() {
            return Some(s);
        }
    }
    let local = repo_root.join(".chump-locks").join(".wt-session-id");
    if let Ok(s) = fs::read_to_string(&local) {
        let s = s.trim().to_string();
        if !s.is_empty() {
            return Some(s);
        }
    }
    if let Some(amb) = locate_ambient(repo_root) {
        if let Some(parent) = amb.parent() {
            if let Ok(s) = fs::read_to_string(parent.join(".wt-session-id")) {
                let s = s.trim().to_string();
                if !s.is_empty() {
                    return Some(s);
                }
            }
        }
    }
    if let Some(home) = dirs_next_home() {
        if let Ok(s) = fs::read_to_string(home.join(".chump").join("session_id")) {
            let s = s.trim().to_string();
            if !s.is_empty() {
                return Some(s);
            }
        }
    }
    None
}

fn dirs_next_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Read the tail of `ambient.jsonl` and return events from sibling sessions
/// (i.e. session != `self_session`) whose timestamp is within `since_secs`
/// of `now`. Filters by gap and/or path overlap when those args are
/// non-empty. Most-recent-first; capped at `limit`.
///
/// Tail-reads at most ~512 KiB of the file so a long-lived stream doesn't
/// drag the agent loop. That budget covers ~2k events at typical line
/// length, far more than the per-prompt window.
pub fn recent_sibling_events(
    ambient_path: &Path,
    self_session: Option<&str>,
    gap: Option<&str>,
    paths: &[&str],
    since_secs: i64,
    limit: usize,
) -> Vec<AmbientEvent> {
    let Ok(meta) = fs::metadata(ambient_path) else {
        return Vec::new();
    };
    let total = meta.len();
    let want = 512 * 1024u64;
    let start = total.saturating_sub(want);

    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut f) = fs::File::open(ambient_path) else {
        return Vec::new();
    };
    if f.seek(SeekFrom::Start(start)).is_err() {
        return Vec::new();
    }
    let mut buf = Vec::new();
    if f.read_to_end(&mut buf).is_err() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&buf);

    let now = Utc::now();
    let mut hits: Vec<AmbientEvent> = Vec::new();

    for line in text.lines().rev() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(ev) = serde_json::from_str::<RawEvent>(line) else {
            continue;
        };
        if let Some(self_sid) = self_session {
            if ev.session == self_sid {
                continue;
            }
        }
        let Ok(ts) = DateTime::parse_from_rfc3339(&ev.ts) else {
            continue;
        };
        let ts_utc = ts.with_timezone(&Utc);
        let age = (now - ts_utc).num_seconds();
        if age < 0 || age > since_secs {
            continue;
        }

        let mut summary = String::new();
        let mut keep = false;
        match ev.event.as_str() {
            "INTENT" => {
                if let Some(g) = gap {
                    if ev.gap.as_deref() == Some(g) {
                        summary = format!("INTENT for {}", g);
                        keep = true;
                    }
                }
            }
            "commit" => {
                if let Some(g) = gap {
                    if ev.gap.as_deref() == Some(g) {
                        let sha = ev.sha.as_deref().unwrap_or("?");
                        let sha_short = sha.chars().take(7).collect::<String>();
                        summary = format!("committed {} ({})", g, sha_short);
                        keep = true;
                    }
                }
            }
            "file_edit" => {
                if let Some(p) = ev.path.as_deref() {
                    let basename = Path::new(p)
                        .file_name()
                        .map(|s| s.to_string_lossy().to_string())
                        .unwrap_or_default();
                    for want in paths {
                        let want_bn = Path::new(want)
                            .file_name()
                            .map(|s| s.to_string_lossy().to_string())
                            .unwrap_or_default();
                        if p.contains(want) || (!basename.is_empty() && basename == want_bn) {
                            summary = format!("file_edit {}", basename);
                            keep = true;
                            break;
                        }
                    }
                }
            }
            "ALERT" => {
                if gap.is_some() || !paths.is_empty() {
                    let kind_s = ev.kind.as_deref().unwrap_or("");
                    summary = format!("ALERT {}", kind_s);
                    keep = true;
                }
            }
            _ => {}
        }
        let _ = (&ev.cmd, &ev.files, &ev.msg); // suppress unused warnings — kept for future heuristics

        if keep {
            hits.push(AmbientEvent {
                ts: ts_utc,
                session: ev.session.clone(),
                kind: ev.event.clone(),
                summary,
            });
            if hits.len() >= limit {
                break;
            }
        }
    }
    hits
}

/// Format a vector of events as a markdown block to inject into the system
/// prompt. Empty output for an empty vector — callers can plug the result
/// directly into a `format!` chain.
pub fn format_ambient_block(events: &[AmbientEvent]) -> String {
    if events.is_empty() {
        return String::new();
    }
    let now = Utc::now();
    let mut out = String::from("[Ambient sibling activity — last few minutes]\n");
    for ev in events {
        let age = (now - ev.ts).num_seconds().max(0);
        let sid = short_session(&ev.session);
        out.push_str(&format!("- {}s ago — {}: {}\n", age, sid, ev.summary));
    }
    out.push_str(
        "If a sibling event overlaps your plan (same gap, same files), pause and re-tail .chump-locks/ambient.jsonl before pushing.\n",
    );
    out
}

fn short_session(sid: &str) -> String {
    let parts: Vec<&str> = sid.split('-').collect();
    if parts.len() >= 2 {
        parts[parts.len() - 2].to_string()
    } else {
        sid.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    fn write_stream(dir: &Path, lines: &[&str]) -> PathBuf {
        let lock = dir.join(".chump-locks");
        fs::create_dir_all(&lock).unwrap();
        let path = lock.join("ambient.jsonl");
        let mut f = fs::File::create(&path).unwrap();
        for l in lines {
            writeln!(f, "{}", l).unwrap();
        }
        path
    }

    fn iso_ago(secs: i64) -> String {
        let t = Utc::now() - chrono::Duration::seconds(secs);
        t.format("%Y-%m-%dT%H:%M:%SZ").to_string()
    }

    #[test]
    fn missing_file_returns_empty() {
        let td = TempDir::new().unwrap();
        let p = td.path().join("nope.jsonl");
        let out = recent_sibling_events(&p, Some("me"), Some("FOO-1"), &[], 600, 10);
        assert!(out.is_empty());
    }

    #[test]
    fn intent_for_same_gap_kept() {
        let td = TempDir::new().unwrap();
        let line = format!(
            r#"{{"event":"INTENT","session":"sib","ts":"{}","gap":"FOO-1"}}"#,
            iso_ago(30)
        );
        let p = write_stream(td.path(), &[&line]);
        let out = recent_sibling_events(&p, Some("me"), Some("FOO-1"), &[], 600, 10);
        assert_eq!(out.len(), 1);
        assert!(out[0].summary.contains("INTENT"));
    }

    #[test]
    fn self_events_filtered() {
        let td = TempDir::new().unwrap();
        let line = format!(
            r#"{{"event":"INTENT","session":"me","ts":"{}","gap":"FOO-1"}}"#,
            iso_ago(30)
        );
        let p = write_stream(td.path(), &[&line]);
        let out = recent_sibling_events(&p, Some("me"), Some("FOO-1"), &[], 600, 10);
        assert!(out.is_empty());
    }

    #[test]
    fn old_events_dropped() {
        let td = TempDir::new().unwrap();
        let line = format!(
            r#"{{"event":"INTENT","session":"sib","ts":"{}","gap":"FOO-1"}}"#,
            iso_ago(10_000)
        );
        let p = write_stream(td.path(), &[&line]);
        let out = recent_sibling_events(&p, Some("me"), Some("FOO-1"), &[], 600, 10);
        assert!(out.is_empty());
    }

    #[test]
    fn file_edit_basename_match() {
        let td = TempDir::new().unwrap();
        let line = format!(
            r#"{{"event":"file_edit","session":"sib","ts":"{}","path":"/abs/path/src/foo.rs"}}"#,
            iso_ago(30)
        );
        let p = write_stream(td.path(), &[&line]);
        let out = recent_sibling_events(&p, Some("me"), None, &["src/foo.rs"], 600, 10);
        assert_eq!(out.len(), 1);
        assert!(out[0].summary.contains("foo.rs"));
    }

    #[test]
    fn malformed_lines_skipped() {
        let td = TempDir::new().unwrap();
        let good = format!(
            r#"{{"event":"INTENT","session":"sib","ts":"{}","gap":"FOO-1"}}"#,
            iso_ago(30)
        );
        let p = write_stream(td.path(), &["not json", "{partial", &good]);
        let out = recent_sibling_events(&p, Some("me"), Some("FOO-1"), &[], 600, 10);
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn limit_caps_results() {
        let td = TempDir::new().unwrap();
        let lines: Vec<String> = (0..20)
            .map(|i| {
                format!(
                    r#"{{"event":"INTENT","session":"sib-{}","ts":"{}","gap":"FOO-1"}}"#,
                    i,
                    iso_ago(30 + i)
                )
            })
            .collect();
        let line_refs: Vec<&str> = lines.iter().map(|s| s.as_str()).collect();
        let p = write_stream(td.path(), &line_refs);
        let out = recent_sibling_events(&p, Some("me"), Some("FOO-1"), &[], 600, 5);
        assert_eq!(out.len(), 5);
    }

    #[test]
    fn format_block_empty_for_no_events() {
        assert!(format_ambient_block(&[]).is_empty());
    }

    #[test]
    fn format_block_renders_age_and_summary() {
        let ev = AmbientEvent {
            ts: Utc::now() - chrono::Duration::seconds(45),
            session: "chump-sibling-12345".to_string(),
            kind: "INTENT".to_string(),
            summary: "INTENT for FOO-1".to_string(),
        };
        let s = format_ambient_block(&[ev]);
        assert!(s.contains("Ambient sibling activity"));
        assert!(s.contains("INTENT for FOO-1"));
        assert!(s.contains("sibling"));
    }
}
