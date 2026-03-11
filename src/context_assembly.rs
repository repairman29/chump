//! Session context assembly and close: inject ego, tasks, episodes, schedule into system prompt;
//! on session end increment session_count, optionally commit brain, log.

use anyhow::Result;
use std::path::PathBuf;
use std::process::Command;

use crate::ask_jeff_db;
use crate::chump_log;
use crate::episode_db;
use crate::repo_path;
use crate::schedule_db;
use crate::state_db;
use crate::task_db;

fn brain_root() -> Result<PathBuf> {
    let root = std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let base = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let path = if PathBuf::from(&root).is_absolute() {
        PathBuf::from(root)
    } else {
        base.join(root)
    };
    Ok(path)
}

fn get_state(key: &str) -> String {
    state_db::state_read(key)
        .ok()
        .flatten()
        .unwrap_or_else(|| "—".to_string())
}

/// Build the context block injected into the system prompt (ego, tasks, episodes, schedule, heartbeat meta).
pub fn assemble_context() -> String {
    let mut out = String::from("\n[CHUMP CONTEXT — auto-loaded, do not repeat these tool calls]\n\n");

    if state_db::state_available() {
        out.push_str(&format!("Current focus: {}\n", get_state("current_focus")));
        out.push_str(&format!("Mood: {}\n", get_state("mood")));
        out.push_str(&format!("Frustrations: {}\n", get_state("frustrations")));
        out.push_str(&format!("Recent wins: {}\n", get_state("recent_wins")));
        out.push_str(&format!("Things Jeff should know: {}\n", get_state("things_jeff_should_know")));
        out.push_str(&format!("Session #{}\n\n", get_state("session_count")));
    }

    if task_db::task_available() {
        if let Ok(tasks) = task_db::task_list(None) {
            let top: Vec<_> = tasks.into_iter().take(5).collect();
            if !top.is_empty() {
                out.push_str("Open tasks (top 5):\n");
                for t in &top {
                    let notes = t.notes.as_deref().unwrap_or("");
                    let snippet = if notes.len() > 60 {
                        format!("{}…", &notes[..60])
                    } else {
                        notes.to_string()
                    };
                    out.push_str(&format!("  #{}: {} [{}] — {}\n", t.id, t.title, t.status, snippet));
                }
                out.push('\n');
            }
        }
    }

    if episode_db::episode_available() {
        if let Ok(episodes) = episode_db::episode_recent(None, 3) {
            if !episodes.is_empty() {
                out.push_str("Recent episodes (last 3):\n");
                for e in &episodes {
                    let sent = e.sentiment.as_deref().unwrap_or("—");
                    out.push_str(&format!("  - {} [{}] {}\n", e.summary, sent, e.happened_at));
                }
                out.push('\n');
            }
        }
    }

    if schedule_db::schedule_available() {
        if let Ok(due) = schedule_db::schedule_due() {
            if !due.is_empty() {
                out.push_str("Scheduled (due soon):\n");
                for (id, prompt, _ctx) in due.into_iter().take(3) {
                    out.push_str(&format!("  - {} (id={})\n", prompt.trim(), id));
                }
                out.push('\n');
            }
        }
    }

    out.push_str("Outstanding PRs: Run gh_list_my_prs to see your open PRs and their status.\n\n");

    if ask_jeff_db::ask_jeff_available() {
        if let Ok(answers) = ask_jeff_db::list_recent_answers(5) {
            if !answers.is_empty() {
                out.push_str("Jeff answered your questions:\n");
                for (id, q, a) in answers {
                    let q_short = if q.len() > 60 { format!("{}…", &q[..60]) } else { q };
                    out.push_str(&format!("  Q#{}: {} → A: {}\n", id, q_short, a.trim()));
                }
                out.push('\n');
            }
        }
        if let Ok(blocking) = ask_jeff_db::list_unanswered_blocking(5) {
            if !blocking.is_empty() {
                out.push_str("Blocking questions (waiting for Jeff):\n");
                for (id, q, asked_at) in blocking {
                    let q_short = if q.len() > 50 { format!("{}…", &q[..50]) } else { q };
                    out.push_str(&format!("  Q#{}: {} (asked {})\n", id, q_short, asked_at));
                }
                out.push_str("→ Don't work on related tasks until Jeff answers.\n\n");
            }
        }
    }


    if repo_path::repo_root_is_explicit() {
        let root = repo_path::repo_root();
        if let Ok(out_git) = Command::new("git")
            .args(["diff", "--name-only", "HEAD~1..HEAD"])
            .current_dir(&root)
            .output()
        {
            if out_git.status.success() {
                let names = String::from_utf8_lossy(&out_git.stdout);
                let names = names.trim();
                if !names.is_empty() {
                    out.push_str("Files changed in last commit:\n");
                    for line in names.lines().take(20) {
                        out.push_str(&format!("  {}\n", line));
                    }
                    out.push_str("Read changed files before working on related code.\n\n");
                }
            }
        }
    }

    if let Ok(round) = std::env::var("CHUMP_HEARTBEAT_ROUND") {
        let kind = std::env::var("CHUMP_HEARTBEAT_TYPE").unwrap_or_else(|_| "work".to_string());
        let elapsed = std::env::var("CHUMP_HEARTBEAT_ELAPSED").unwrap_or_else(|_| "?".to_string());
        let duration = std::env::var("CHUMP_HEARTBEAT_DURATION").unwrap_or_else(|_| "?".to_string());
        out.push_str(&format!(
            "This is heartbeat round {} ({}), {}s into a {}s run. Pace yourself.\n\n",
            round, kind, elapsed, duration
        ));
    }

    let now_utc = {
        use std::time::{SystemTime, UNIX_EPOCH};
        let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        format!("{}", t.as_secs())
    };
    out.push_str(&format!("Current time (UTC epoch): {}\n", now_utc));

    out
}

/// Call at end of a session: increment session_count, optionally commit brain repo, log.
pub fn close_session() {
    if state_db::state_available() {
        let _ = state_db::state_increment("session_count");
    }

    if let Ok(brain) = brain_root() {
        if brain.join(".git").exists() {
            let _ = Command::new("git")
                .args(["add", "-A"])
                .current_dir(&brain)
                .output();
            let session_count = state_db::state_read("session_count").ok().flatten().unwrap_or_else(|| "0".to_string());
            let msg = format!("chump: auto-commit session {}", session_count);
            let _ = Command::new("git")
                .args(["commit", "-m", &msg])
                .current_dir(&brain)
                .output();
        }
    }

    chump_log::log_session_end();
}
