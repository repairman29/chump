//! Session context assembly and close: inject ego, tasks, episodes, schedule into system prompt;
//! on session end increment session_count, optionally commit brain, log.

use anyhow::Result;
use std::fmt::Write;
use std::path::PathBuf;
use std::process::Command;
use std::sync::Mutex;

use crate::ask_jeff_db;
use crate::chump_log;
use crate::cost_tracker;
use crate::episode_db;
use crate::repo_path;
use crate::schedule_db;
use crate::state_db;
use crate::task_db;
use crate::tool_health_db;

fn brain_root() -> Result<PathBuf> {
    let root = std::env::var("CHUMP_BRAIN_PATH").unwrap_or_else(|_| "chump-brain".to_string());
    let base = repo_path::runtime_base();
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
/// When CHUMP_HEARTBEAT_TYPE is set, only inject sections relevant to that round to save context tokens.
pub fn assemble_context() -> String {
    const INITIAL_CAP: usize = 4096;
    let mut out = String::with_capacity(INITIAL_CAP);
    out.push_str("\n[CHUMP CONTEXT — auto-loaded, do not repeat these tool calls]\n\n");

    let round_type = std::env::var("CHUMP_HEARTBEAT_TYPE").ok().unwrap_or_default();
    let is_work = round_type == "work";
    let is_research = round_type == "research";
    let is_cursor_improve = round_type == "cursor_improve";
    let is_cli = round_type.is_empty();

    if state_db::state_available() {
        let _ = writeln!(out, "Current focus: {}", get_state("current_focus"));
        let _ = writeln!(out, "Mood: {}", get_state("mood"));
        let _ = writeln!(out, "Frustrations: {}", get_state("frustrations"));
        let _ = writeln!(out, "Recent wins: {}", get_state("recent_wins"));
        let _ = writeln!(out, "Things Jeff should know: {}", get_state("things_jeff_should_know"));
        let _ = writeln!(out, "Session #{}\n", get_state("session_count"));
    }

    // CHUMP_BRAIN_AUTOLOAD: comma-separated brain-relative paths injected without requiring agent tool call.
    // Small models often skip the "read self.md" tool call the soul instructs; autoload makes continuity reliable.
    if let Ok(autoload) = std::env::var("CHUMP_BRAIN_AUTOLOAD") {
        if let Ok(brain_path) = brain_root() {
            const MAX_FILE_CHARS: usize = 2000;
            let files: Vec<&str> = autoload.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
            for file in files {
                let full = brain_path.join(file);
                if let Ok(content) = std::fs::read_to_string(&full) {
                    let truncated = if content.len() > MAX_FILE_CHARS { &content[..MAX_FILE_CHARS] } else { &content };
                    let _ = writeln!(out, "=== brain/{} ===\n{}\n", file, truncated.trim());
                }
            }
        }
    }

    if task_db::task_available() && (is_work || is_cursor_improve || is_cli) {
        if let Ok(tasks) = task_db::task_list(None) {
            let top: Vec<_> = tasks.into_iter().take(5).collect();
            if !top.is_empty() {
                out.push_str("Open tasks (top 5):\n");
                for t in &top {
                    let notes = t.notes.as_deref().unwrap_or("");
                    let snippet = if notes.len() > 60 { &notes[..60] } else { notes };
                    let suffix = if notes.len() > 60 { "…" } else { "" };
                    let _ = writeln!(out, "  #{}: {} [{}] — {}{}", t.id, t.title, t.status, snippet, suffix);
                }
                out.push('\n');
            }
        }
        if let Ok(jeff_tasks) = task_db::task_list_for_assignee("jeff") {
            if !jeff_tasks.is_empty() {
                out.push_str("Tasks for Jeff (human judgment / review):\n");
                for t in jeff_tasks.iter().take(10) {
                    let _ = writeln!(out, "  #{}: {} [{}]", t.id, t.title, t.status);
                }
                out.push_str("→ Notify Jeff or surface in morning briefing.\n\n");
            }
        }
    }

    if episode_db::episode_available() {
        if is_research || is_cli {
            if let Ok(episodes) = episode_db::episode_recent(None, 3) {
                if !episodes.is_empty() {
                    out.push_str("Recent episodes (last 3):\n");
                    for e in &episodes {
                        let sent = e.sentiment.as_deref().unwrap_or("—");
                        let _ = writeln!(out, "  - {} [{}] {}", e.summary, sent, e.happened_at);
                    }
                    out.push('\n');
                }
            }
        }
        if is_cursor_improve || is_cli {
            if let Ok(frustrating) = episode_db::episode_recent_by_sentiment("frustrating", 3) {
                if !frustrating.is_empty() {
                    out.push_str("Recent frustrating episodes (failure pattern check):\n");
                    for e in &frustrating {
                        let _ = writeln!(out, "  - {} {}", e.summary, e.happened_at);
                    }
                    out.push_str("Consider addressing root cause before adding similar work.\n\n");
                }
            }
        }
    }

    if schedule_db::schedule_available() && is_cli {
        if let Ok(due) = schedule_db::schedule_due() {
            if !due.is_empty() {
                out.push_str("Scheduled (due soon):\n");
                for (id, prompt, _ctx) in due.into_iter().take(3) {
                    let _ = writeln!(out, "  - {} (id={})", prompt.trim(), id);
                }
                out.push('\n');
            }
        }
    }

    if is_work || is_cli {
        out.push_str("Outstanding PRs: Run gh_list_my_prs to see your open PRs and their status.\n\n");
    }

    if ask_jeff_db::ask_jeff_available() && (is_work || is_cli) {
        if let Ok(answers) = ask_jeff_db::list_recent_answers(5) {
            if !answers.is_empty() {
                out.push_str("Jeff answered your questions:\n");
                for (id, q, a) in answers {
                    let (q_short, suffix) = if q.len() > 60 { (&q[..60], "…") } else { (q.as_str(), "") };
                    let _ = writeln!(out, "  Q#{}: {}{} → A: {}", id, q_short, suffix, a.trim());
                }
                out.push('\n');
            }
        }
        if let Ok(blocking) = ask_jeff_db::list_unanswered_blocking(5) {
            if !blocking.is_empty() {
                out.push_str("Blocking questions (waiting for Jeff):\n");
                for (id, q, asked_at) in blocking {
                    let (q_short, suffix) = if q.len() > 50 { (&q[..50], "…") } else { (q.as_str(), "") };
                    let _ = writeln!(out, "  Q#{}: {}{} (asked {})", id, q_short, suffix, asked_at);
                }
                out.push_str("→ Don't work on related tasks until Jeff answers.\n\n");
            }
        }
    }

    if repo_path::repo_root_is_explicit() && (is_cursor_improve || is_cli) {
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
                        let _ = writeln!(out, "  {}", line);
                    }
                    out.push_str("Read changed files before working on related code.\n\n");
                }
            }
        }
        let live = crate::file_watch::drain_recent_changes();
        if !live.is_empty() {
            out.push_str("Files changed since last run (live):\n");
            for path in live.into_iter().take(30) {
                let _ = writeln!(out, "  {}", path);
            }
            out.push_str("Read changed files before working on related code.\n\n");
        }
    }

    if let Ok(round) = std::env::var("CHUMP_HEARTBEAT_ROUND") {
        let kind = std::env::var("CHUMP_HEARTBEAT_TYPE").unwrap_or_else(|_| "work".to_string());
        let elapsed = std::env::var("CHUMP_HEARTBEAT_ELAPSED").unwrap_or_else(|_| "?".to_string());
        let duration = std::env::var("CHUMP_HEARTBEAT_DURATION").unwrap_or_else(|_| "?".to_string());
        let _ = writeln!(
            out,
            "This is heartbeat round {} ({}), {}s into a {}s run. Pace yourself.\n",
            round, kind, elapsed, duration
        );
    }

    {
        use std::time::{SystemTime, UNIX_EPOCH};
        let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        let _ = writeln!(out, "Current time (UTC epoch): {}", t.as_secs());
    }

    let _ = writeln!(out, "Cost so far: {}.", cost_tracker::summary());
    if let Some(warn) = cost_tracker::budget_warning() {
        let _ = writeln!(out, "{}", warn);
    }

    if tool_health_db::tool_health_available() {
        if let Ok(degraded) = tool_health_db::list_degraded() {
            if !degraded.is_empty() {
                let _ = writeln!(out, "Tools degraded this run: {}. Use alternatives where possible.", degraded.join(", "));
            }
        }
        if let Ok(unavail) = tool_health_db::list_unavailable() {
            if !unavail.is_empty() {
                let _ = writeln!(out, "Tools unavailable: {}. Do not retry these.", unavail.join(", "));
            }
        }
    }

    out
}

/// Call at end of a session: increment session_count, optionally commit brain repo, log.
/// Store the last agent reply so peer_sync can write it to the shared brain on close_session.
/// Called from Discord/web turn handlers after stripping thinking blocks.
pub fn record_last_reply(reply: &str) {
    static LAST_REPLY: std::sync::OnceLock<Mutex<String>> = std::sync::OnceLock::new();
    let cell = LAST_REPLY.get_or_init(|| Mutex::new(String::new()));
    if let Ok(mut g) = cell.lock() {
        *g = reply.to_string();
    }
    // Peer-sync: immediately persist to brain a2a file so Mabel can read it without waiting for close.
    write_last_reply_to_brain(reply);
}

fn last_reply_cell() -> &'static Mutex<String> {
    static CELL: std::sync::OnceLock<Mutex<String>> = std::sync::OnceLock::new();
    CELL.get_or_init(|| Mutex::new(String::new()))
}

/// Write the given reply to `brain/a2a/chump-last-reply.md` (or mabel variant).
fn write_last_reply_to_brain(reply: &str) {
    let Ok(brain) = brain_root() else { return };
    let a2a_dir = brain.join("a2a");
    let _ = std::fs::create_dir_all(&a2a_dir);
    let is_mabel = std::env::var("CHUMP_MABEL")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let filename = if is_mabel { "mabel-last-reply.md" } else { "chump-last-reply.md" };
    let agent_name = if is_mabel { "Mabel" } else { "Chump" };
    let ts = {
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        format!("unix:{}", secs)
    };
    let content = format!("# {} last reply ({})\n\n{}\n", agent_name, ts, reply);
    let _ = std::fs::write(a2a_dir.join(filename), content);
}

pub fn close_session() {
    // Peer-sync: ensure last reply is written to the a2a brain file before git commit.
    if let Ok(g) = last_reply_cell().lock() {
        if !g.is_empty() {
            write_last_reply_to_brain(&g.clone());
        }
    }
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
    eprintln!("chump session end: {}", cost_tracker::summary());
}
