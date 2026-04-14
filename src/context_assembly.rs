//! Session context assembly and close: inject ego, tasks, episodes, schedule into system prompt;
//! on session end increment session_count, optionally commit brain, log.

use anyhow::Result;
use std::collections::HashMap;
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};

use crate::ask_jeff_db;
use crate::chump_log;
use crate::cost_tracker;
use crate::episode_db;
use crate::repo_path;
use crate::schedule_db;
use crate::state_db;
use crate::task_db;
use crate::tool_health_db;

/// Truncate a string to at most `max_bytes` without splitting a multi-byte character.
fn truncate_char_boundary(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

fn cos_weekly_default_rounds(round_type: &str) -> bool {
    matches!(
        round_type,
        "work" | "cursor_improve" | "doc_hygiene" | "discovery" | "opportunity" | "weekly_cos"
    )
}

/// When unset: inject on COS-oriented heartbeat rounds only (not Discord/CLI with empty type).
/// `CHUMP_INCLUDE_COS_WEEKLY=0|false` disables. `CHUMP_INCLUDE_COS_WEEKLY=1|true` always injects when a file exists (higher token use).
/// `CHUMP_WEB_INJECT_COS=1|true` injects the latest COS weekly snapshot for PWA/daily-driver sessions too
/// (still respects `CHUMP_INCLUDE_COS_WEEKLY=0|false` to hard-disable).
fn should_inject_cos_weekly_snapshot(round_type: &str) -> bool {
    let web_cos = std::env::var("CHUMP_WEB_INJECT_COS")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    match std::env::var("CHUMP_INCLUDE_COS_WEEKLY") {
        Ok(ref v) if v == "0" || v.eq_ignore_ascii_case("false") => return false,
        Ok(ref v) if v == "1" || v.eq_ignore_ascii_case("true") => return true,
        _ => {}
    }
    if web_cos {
        return true;
    }
    !round_type.is_empty() && cos_weekly_default_rounds(round_type)
}

fn pick_latest_cos_weekly_path(logs_dir: &Path) -> Option<PathBuf> {
    let rd = std::fs::read_dir(logs_dir).ok()?;
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for ent in rd.flatten() {
        let path = ent.path();
        let name = path.file_name()?.to_string_lossy();
        if !name.starts_with("cos-weekly-") || !name.ends_with(".md") {
            continue;
        }
        let mtime = std::fs::metadata(&path).ok()?.modified().ok()?;
        best = match best {
            None => Some((mtime, path)),
            Some((t0, p0)) => {
                if mtime > t0 || (mtime == t0 && path.as_os_str() > p0.as_os_str()) {
                    Some((mtime, path))
                } else {
                    Some((t0, p0))
                }
            }
        };
    }
    best.map(|(_, p)| p)
}

fn append_cos_weekly_snapshot_if_applicable(out: &mut String, round_type: &str) {
    if !should_inject_cos_weekly_snapshot(round_type) {
        return;
    }
    let logs_dir = repo_path::runtime_base().join("logs");
    let Some(path) = pick_latest_cos_weekly_path(&logs_dir) else {
        return;
    };
    let Ok(content) = std::fs::read_to_string(&path) else {
        return;
    };
    let mut max_chars = std::env::var("CHUMP_COS_WEEKLY_MAX_CHARS")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .filter(|&n| n > 0)
        .unwrap_or(8000);
    if crate::env_flags::chump_light_context() && round_type.trim().is_empty() {
        max_chars = max_chars.min(2000);
    }
    let trimmed = content.trim();
    let truncated = truncate_char_boundary(trimmed, max_chars);
    let suffix = if trimmed.len() > max_chars {
        "… [truncated]"
    } else {
        ""
    };
    let fname = path
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "cos-weekly.md".to_string());
    let _ = writeln!(
        out,
        "COS weekly snapshot (latest file `{}`):\n{}{}\n",
        fname, truncated, suffix
    );
}

/// Brain repo root (for a2a files, pending peer approval, etc.). Used by pending_peer_approval and record_last_reply.
pub fn brain_root() -> Result<PathBuf> {
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

fn brain_autoload_last_turns() -> &'static Mutex<HashMap<String, u64>> {
    static M: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Build the context block injected into the system prompt (ego, tasks, episodes, schedule, heartbeat meta).
/// When CHUMP_HEARTBEAT_TYPE is set, only inject sections relevant to that round to save context tokens.
pub fn assemble_context() -> String {
    const INITIAL_CAP: usize = 4096;
    let mut out = String::with_capacity(INITIAL_CAP);
    out.push_str("\n[CHUMP CONTEXT — auto-loaded, do not repeat these tool calls]\n\n");

    if let Some(line) = crate::repo_path::active_tool_repo_context_line() {
        let _ = writeln!(out, "{}\n", line);
    }

    crate::precision_controller::init_energy_budget_from_env();

    static BB_RESTORED: std::sync::Once = std::sync::Once::new();
    BB_RESTORED.call_once(crate::blackboard::restore_persisted);

    let round_type = std::env::var("CHUMP_HEARTBEAT_TYPE")
        .ok()
        .unwrap_or_default();
    let is_work = round_type == "work";
    let is_research = round_type == "research";
    let is_cursor_improve = round_type == "cursor_improve";
    let is_doc_hygiene = round_type == "doc_hygiene";
    let is_ship = round_type == "ship";
    let is_cli = round_type.is_empty();
    let light_interactive = crate::env_flags::chump_light_context() && is_cli;

    if state_db::state_available()
        && (!light_interactive || crate::env_flags::chump_light_include_state_db())
    {
        let _ = writeln!(out, "Current focus: {}", get_state("current_focus"));
        let _ = writeln!(out, "Mood: {}", get_state("mood"));
        let _ = writeln!(out, "Frustrations: {}", get_state("frustrations"));
        let _ = writeln!(out, "Recent wins: {}", get_state("recent_wins"));
        let _ = writeln!(
            out,
            "Things Jeff should know: {}",
            get_state("things_jeff_should_know")
        );
        let _ = writeln!(out, "Session #{}\n", get_state("session_count"));
    }

    // CHUMP_BRAIN_AUTOLOAD: comma-separated brain-relative paths injected without requiring agent tool call.
    // Small models often skip the "read self.md" tool call the soul instructs; autoload makes continuity reliable.
    if !light_interactive || crate::env_flags::chump_light_include_brain_autoload() {
        if let Ok(autoload) = std::env::var("CHUMP_BRAIN_AUTOLOAD") {
            if let Ok(brain_path) = brain_root() {
                const MAX_FILE_CHARS: usize = 2000;
                let turn = crate::agent_turn::current();
                let mut last_map = brain_autoload_last_turns()
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                let files: Vec<&str> = autoload
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .collect();
                for file in files {
                    let include = match last_map.get(file) {
                        None => true,
                        Some(last) => {
                            let d = turn.saturating_sub(*last);
                            d <= 3 || d > 20
                        }
                    };
                    if !include {
                        continue;
                    }
                    let full = brain_path.join(file);
                    if let Ok(content) = std::fs::read_to_string(&full) {
                        let truncated = truncate_char_boundary(&content, MAX_FILE_CHARS);
                        let _ = writeln!(out, "=== brain/{} ===\n{}\n", file, truncated.trim());
                        last_map.insert(file.to_string(), turn);
                    }
                }
            }
        }
    }

    // Portfolio injection: when chump-brain/portfolio.md exists, inject a compact summary so
    // Chump always knows the active products and current phase without a separate tool call.
    if let Ok(brain_path) = brain_root() {
        if !light_interactive {
            let portfolio_path = brain_path.join("portfolio.md");
            if portfolio_path.is_file() {
                if let Ok(content) = std::fs::read_to_string(&portfolio_path) {
                    out.push_str("Active portfolio:\n");
                    for line in content.lines() {
                        if line.starts_with("## ")
                            || line.starts_with("- **Phase:**")
                            || line.starts_with("- **What shipping means")
                            || line.starts_with("- **Blocked:**")
                        {
                            let _ = writeln!(out, "  {}", line.trim_start_matches("- "));
                        }
                    }
                    out.push('\n');
                }
            }
        }
    }

    // Ship round: inject top product slug, log tail, playbook steps excerpt, and optional "This round: Step N".
    if is_ship {
        if let Ok(brain_path) = brain_root() {
            let portfolio_path = brain_path.join("portfolio.md");
            let slug = portfolio_path
                .is_file()
                .then(|| std::fs::read_to_string(&portfolio_path).ok())
                .flatten()
                .and_then(|content| {
                    content
                        .lines()
                        .find(|l| l.trim().starts_with("**Playbook:**"))
                        .and_then(|l| {
                            let rest = l.trim().strip_prefix("**Playbook:**")?.trim();
                            let strip = rest.strip_prefix("projects/")?;
                            let s = strip.split('/').next()?.to_string();
                            Some(s)
                        })
                });
            if let Some(ref slug) = slug {
                const LOG_TAIL_CHARS: usize = 800;
                const PLAYBOOK_EXCERPT_CHARS: usize = 1500;
                let log_path = brain_path.join("projects").join(slug).join("log.md");
                let playbook_path = brain_path.join("projects").join(slug).join("playbook.md");
                let log_tail = std::fs::read_to_string(&log_path).ok().map(|c| {
                    if c.len() <= LOG_TAIL_CHARS {
                        c
                    } else {
                        let mut start = c.len().saturating_sub(LOG_TAIL_CHARS);
                        while start < c.len() && !c.is_char_boundary(start) {
                            start += 1;
                        }
                        c[start..].to_string()
                    }
                });
                let (playbook_excerpt, max_step) = std::fs::read_to_string(&playbook_path)
                    .ok()
                    .map(|content| {
                        let start = content
                            .find("## Steps")
                            .or_else(|| content.find("### Phase"))
                            .unwrap_or(0);
                        let end_off = content[start..]
                            .find("\n## On Failure")
                            .or_else(|| content[start..].find("\n## Quality"))
                            .unwrap_or(content.len().saturating_sub(start));
                        let steps_len = end_off.min(PLAYBOOK_EXCERPT_CHARS);
                        let excerpt_slice = &content[start..start + end_off.min(steps_len)];
                        let excerpt = if end_off > PLAYBOOK_EXCERPT_CHARS {
                            format!("{}… [truncated]", excerpt_slice.trim())
                        } else {
                            excerpt_slice.trim().to_string()
                        };
                        let max = excerpt
                            .lines()
                            .filter_map(|l| {
                                let l = l.trim();
                                let rest = l
                                    .strip_prefix("- [ ] **Step ")
                                    .or_else(|| l.strip_prefix("**Step "))?;
                                let num_str = rest.split(':').next()?.trim_end_matches('*').trim();
                                num_str.parse::<u32>().ok()
                            })
                            .max()
                            .unwrap_or(5);
                        (excerpt, max)
                    })
                    .unwrap_or((String::new(), 5));
                if !playbook_excerpt.is_empty() {
                    out.push_str("Ship round — top product: ");
                    out.push_str(slug);
                    out.push_str(".\n");
                    if let Some(ref tail) = log_tail {
                        let _ = writeln!(out, "Last log (tail):\n{}\n", tail.trim());
                    }
                    let _ = writeln!(out, "Playbook steps (excerpt):\n{}\n", playbook_excerpt);
                    out.push_str("There are only steps 1–");
                    let _ = write!(out, "{}", max_step);
                    out.push_str(" in this playbook. Do not invent Step 6+. Execute exactly one step this round.\n\n");
                    let next_step = log_tail.as_ref().and_then(|tail| {
                        tail.lines().rev().find_map(|l| {
                            let l = l.trim();
                            if l.contains("Next: Step ") {
                                let after = l.split("Next: Step ").nth(1)?;
                                let num_str = after.split(|c: char| !c.is_ascii_digit()).next()?;
                                num_str.parse::<u32>().ok()
                            } else {
                                None
                            }
                        })
                    });
                    if let Some(n) = next_step {
                        if n >= 1 && n <= max_step {
                            let _ = writeln!(out, "This round: execute Step {} only.\n", n);
                        } else if n > max_step {
                            let _ = writeln!(
                                out,
                                "Log says Next: Step {} but playbook has only 1–{}. Treat phase complete; run Quality Checks and notify, or set Next: Phase complete. Do not invent Step {}.\n",
                                n, max_step, n
                            );
                        }
                    }
                }
            }
        }
    }

    if repo_path::has_working_repo_override() && !light_interactive {
        if let Ok(brain_path) = brain_root() {
            let root = repo_path::repo_root();
            let project_name = root
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("unknown");
            let digest_path = brain_path
                .join("projects")
                .join(project_name)
                .join("digest.md");
            if digest_path.exists() {
                if let Ok(content) = std::fs::read_to_string(&digest_path) {
                    const MAX_DIGEST_CHARS: usize = 8000;
                    let truncated = if content.len() > MAX_DIGEST_CHARS {
                        format!(
                            "{}… [truncated]",
                            truncate_char_boundary(&content, MAX_DIGEST_CHARS)
                        )
                    } else {
                        content
                    };
                    let _ = writeln!(
                        out,
                        "=== codebase digest (project: {}) ===\n{}\n",
                        project_name,
                        truncated.trim()
                    );
                }
            }
        }
    }

    if task_db::task_available()
        && (is_work || is_cursor_improve || is_doc_hygiene || (is_cli && !light_interactive))
    {
        if let Ok(tasks) = task_db::task_list(None) {
            let top: Vec<_> = tasks.into_iter().take(5).collect();
            if !top.is_empty() {
                out.push_str("Open tasks (top 5):\n");
                for t in &top {
                    let notes = t.notes.as_deref().unwrap_or("");
                    let snippet = truncate_char_boundary(notes, 60);
                    let suffix = if notes.len() > 60 { "…" } else { "" };
                    let _ = writeln!(
                        out,
                        "  #{}: {} [{}] — {}{}",
                        t.id, t.title, t.status, snippet, suffix
                    );
                }
                out.push('\n');
            }
        }
        if is_work {
            if let Ok(chump_tasks) = task_db::task_list_for_assignee("chump") {
                if !chump_tasks.is_empty() {
                    out.push_str("Tasks for Chump (your work queue):\n");
                    for t in chump_tasks.iter().take(10) {
                        let _ = writeln!(out, "  #{}: {} [{}]", t.id, t.title, t.status);
                    }
                    out.push_str("→ Prefer these in this work round.\n\n");
                }
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

    append_cos_weekly_snapshot_if_applicable(&mut out, &round_type);

    if episode_db::episode_available() {
        if is_research || (is_cli && !light_interactive) {
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
        if is_cursor_improve || is_doc_hygiene || (is_cli && !light_interactive) {
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

    if schedule_db::schedule_available() && is_cli && !light_interactive {
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

    if is_work || (is_cli && !light_interactive) {
        out.push_str(
            "Outstanding PRs: Run gh_list_my_prs to see your open PRs and their status.\n\n",
        );
    }

    if ask_jeff_db::ask_jeff_available() && (is_work || (is_cli && !light_interactive)) {
        if let Ok(answers) = ask_jeff_db::list_recent_answers(5) {
            if !answers.is_empty() {
                out.push_str("Jeff answered your questions:\n");
                for (id, q, a) in answers {
                    let (q_short, suffix) = if q.len() > 60 {
                        (truncate_char_boundary(&q, 60), "…")
                    } else {
                        (q.as_str(), "")
                    };
                    let _ = writeln!(out, "  Q#{}: {}{} → A: {}", id, q_short, suffix, a.trim());
                }
                out.push('\n');
            }
        }
        if let Ok(blocking) = ask_jeff_db::list_unanswered_blocking(5) {
            if !blocking.is_empty() {
                out.push_str("Blocking questions (waiting for Jeff):\n");
                for (id, q, asked_at) in blocking {
                    let (q_short, suffix) = if q.len() > 50 {
                        (truncate_char_boundary(&q, 50), "…")
                    } else {
                        (q.as_str(), "")
                    };
                    let _ = writeln!(
                        out,
                        "  Q#{}: {}{} (asked {})",
                        id, q_short, suffix, asked_at
                    );
                }
                out.push_str("→ Don't work on related tasks until Jeff answers.\n\n");
            }
        }
    }

    if repo_path::repo_root_is_explicit()
        && (is_cursor_improve || is_doc_hygiene || (is_cli && !light_interactive))
    {
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

    // Light interactive (PWA/CLI chat): surface user file edits between turns.
    // Kept brief to stay within token budget.
    if light_interactive {
        let live = crate::file_watch::drain_recent_changes();
        if !live.is_empty() {
            out.push_str("User edited since last message:\n");
            for path in live.into_iter().take(10) {
                let _ = writeln!(out, "  {}", path);
            }
            out.push('\n');
        }
    }

    if let Ok(round) = std::env::var("CHUMP_HEARTBEAT_ROUND") {
        let kind = std::env::var("CHUMP_HEARTBEAT_TYPE").unwrap_or_else(|_| "work".to_string());
        let elapsed = std::env::var("CHUMP_HEARTBEAT_ELAPSED").unwrap_or_else(|_| "?".to_string());
        let duration =
            std::env::var("CHUMP_HEARTBEAT_DURATION").unwrap_or_else(|_| "?".to_string());
        let _ = writeln!(
            out,
            "This is heartbeat round {} ({}), {}s into a {}s run. Pace yourself.\n",
            round, kind, elapsed, duration
        );
    }

    if crate::interrupt_notify::heartbeat_restrict_enabled()
        && !std::env::var("CHUMP_HEARTBEAT_TYPE")
            .map(|s| s.trim().is_empty())
            .unwrap_or(true)
    {
        out.push_str(
            "Interrupt policy: CHUMP_INTERRUPT_NOTIFY_POLICY=restrict — the notify tool only queues DMs when the message matches an allowed interrupt (tags/phrases in docs/COS_DECISION_LOG.md). System alerts (e.g. git credential failures) still send.\n\n",
        );
    }

    if !light_interactive {
        use std::time::{SystemTime, UNIX_EPOCH};
        let t = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let _ = writeln!(out, "Current time (UTC epoch): {}", t.as_secs());
    }

    if !light_interactive {
        let _ = writeln!(out, "Cost so far: {}.", cost_tracker::summary());
        if let Some(warn) = cost_tracker::budget_warning() {
            let _ = writeln!(out, "{}", warn);
        }
    }

    // A/B toggle: set CHUMP_CONSCIOUSNESS_ENABLED=0 to skip all consciousness module injections.
    let consciousness_enabled = std::env::var("CHUMP_CONSCIOUSNESS_ENABLED")
        .map(|v| v != "0")
        .unwrap_or(true);

    if consciousness_enabled && !light_interactive {
        let substrate = crate::consciousness_traits::substrate();
        // Consciousness framework: regime-driven context budget
        let regime = crate::precision_controller::current_regime();
        let full_consciousness = !matches!(
            regime,
            crate::precision_controller::PrecisionRegime::Exploit
        );

        if substrate.surprise.total_predictions() > 0 {
            let _ = writeln!(
                out,
                "Prediction tracking: {}.",
                substrate.surprise.summary()
            );
            let _ = writeln!(out, "Precision control: {}.", substrate.precision.summary());
            crate::precision_controller::check_regime_change();
        }

        // Global Workspace: cross-module reads + broadcast
        {
            let bb = crate::blackboard::global();
            let _ = bb.read_from(
                crate::blackboard::Module::Task,
                &crate::blackboard::Module::SurpriseTracker,
            );
            let _ = bb.read_from(
                crate::blackboard::Module::Task,
                &crate::blackboard::Module::Episode,
            );
            let _ = bb.read_from(
                crate::blackboard::Module::Memory,
                &crate::blackboard::Module::Task,
            );
        }
        let (gw_entries, gw_chars) = if full_consciousness {
            (5, 1200)
        } else {
            (2, 400)
        };
        let gw_context = substrate.workspace.broadcast_context(gw_entries, gw_chars);
        if !gw_context.is_empty() {
            out.push_str(&gw_context);
        }

        // Memory graph summary
        if crate::memory_graph::graph_available() {
            if let Ok(tc) = crate::memory_graph::triple_count() {
                if tc > 0 {
                    let _ = writeln!(
                        out,
                        "Associative memory: {} triples in knowledge graph.",
                        tc
                    );
                }
            }
        }

        substrate.holographic.sync_from_blackboard();

        let neuro_summary = substrate.neuromod.context_summary();
        if !neuro_summary.is_empty() {
            let _ = writeln!(out, "{}.", neuro_summary);
        }

        substrate.belief.decay_turn();
        let belief_summary = substrate.belief.context_summary();
        if !belief_summary.is_empty() {
            let _ = writeln!(out, "{}.", belief_summary);
        }

        // Phi proxy + causal lessons: only in full consciousness mode
        if full_consciousness {
            let phi = crate::phi_proxy::compute_phi();
            if phi.active_coupling_pairs > 0 {
                let _ = writeln!(
                    out,
                    "Integration metric: {}.",
                    crate::phi_proxy::summary_from(&phi)
                );
            }

            if crate::counterfactual::counterfactual_available() && (is_work || is_cli) {
                let focus = get_state("current_focus");
                let (lessons_ctx, lesson_ids) =
                    crate::counterfactual::lessons_for_context_with_ids(None, &focus, 3);
                if !lessons_ctx.is_empty() {
                    out.push_str(&lessons_ctx);
                    record_surfaced_lessons(&lesson_ids);
                }
            }
        }
    }

    if tool_health_db::tool_health_available() {
        if let Ok(degraded) = tool_health_db::list_degraded() {
            if !degraded.is_empty() {
                let _ = writeln!(
                    out,
                    "Tools degraded this run: {}. Use alternatives where possible.",
                    degraded.join(", ")
                );
            }
        }
        if let Ok(unavail) = tool_health_db::list_unavailable() {
            if !unavail.is_empty() {
                let _ = writeln!(
                    out,
                    "Tools unavailable: {}. Do not retry these.",
                    unavail.join(", ")
                );
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
    let filename = if is_mabel {
        "mabel-last-reply.md"
    } else {
        "chump-last-reply.md"
    };
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

/// Track lesson IDs surfaced during this session for mark_lesson_applied at close.
static SURFACED_LESSONS: std::sync::OnceLock<Mutex<Vec<i64>>> = std::sync::OnceLock::new();

fn surfaced_lessons_cell() -> &'static Mutex<Vec<i64>> {
    SURFACED_LESSONS.get_or_init(|| Mutex::new(Vec::new()))
}

fn record_surfaced_lessons(ids: &[i64]) {
    if let Ok(mut g) = surfaced_lessons_cell().lock() {
        g.extend_from_slice(ids);
    }
}

/// Record per-session consciousness metrics for phi–surprisal correlation tracking.
fn record_session_consciousness_metrics() {
    let phi = crate::phi_proxy::compute_phi();
    let ema = crate::surprise_tracker::current_surprisal_ema();
    let regime = format!("{:?}", crate::precision_controller::current_regime());
    let session_id = state_db::state_read("session_count")
        .ok()
        .flatten()
        .unwrap_or_else(|| "0".to_string());
    if let Ok(conn) = crate::db_pool::get() {
        let _ = conn.execute(
            "INSERT INTO chump_consciousness_metrics (session_id, phi_proxy, surprisal_ema, coupling_score, regime) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![session_id, phi.phi_proxy, ema, phi.coupling_score, regime],
        );
    }
}

pub fn close_session() {
    repo_path::clear_working_repo();
    crate::diff_review_tool::clear_diff_reviewed();

    // Mark surfaced causal lessons as applied and decay old unused ones
    if let Ok(mut g) = surfaced_lessons_cell().lock() {
        if !g.is_empty() {
            crate::counterfactual::mark_surfaced_lessons_applied(&g);
            g.clear();
        }
    }
    let _ = crate::counterfactual::decay_unused_lessons(7, 0.05);
    crate::blackboard::persist_high_salience();
    record_session_consciousness_metrics();
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
            let session_count = state_db::state_read("session_count")
                .ok()
                .flatten()
                .unwrap_or_else(|| "0".to_string());
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

#[cfg(test)]
mod cos_weekly_tests {
    use super::*;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn pick_latest_prefers_newer_mtime() {
        let base = std::env::temp_dir().join(format!("chump-cos-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let logs = base.join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(logs.join("cos-weekly-2026-01-01.md"), "older").unwrap();
        thread::sleep(Duration::from_millis(80));
        std::fs::write(logs.join("cos-weekly-2026-06-15.md"), "newer").unwrap();
        let got = pick_latest_cos_weekly_path(&logs).expect("expected a file");
        assert!(got
            .file_name()
            .unwrap()
            .to_string_lossy()
            .contains("2026-06-15"));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn pick_latest_none_when_no_matching_files() {
        let base = std::env::temp_dir().join(format!("chump-cos-empty-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let logs = base.join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        assert!(pick_latest_cos_weekly_path(&logs).is_none());
        let _ = std::fs::remove_dir_all(&base);
    }
}
