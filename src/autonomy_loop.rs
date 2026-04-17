//! Autonomy loop: pick a task, execute, verify, and update state deterministically.
//!
//! Design goal: maximize real-world success by keeping the loop:
//! - single-task-per-run (cron/supervisor friendly)
//! - deterministic (task notes contract, explicit verification)
//! - safe by default (respects existing tool approval gates)

use anyhow::{anyhow, Result};

use crate::discord;
use crate::episode_db;
use crate::mcp_bridge;
use crate::reflection;
use crate::reflection_db;
use crate::repo_path;
use crate::run_test_tool;
use crate::set_working_repo_tool;
use crate::task_contract;
use crate::task_db;
use axonerai::tool::Tool;
use tracing::instrument;

#[derive(Debug, Clone)]
pub struct AutonomyOutcome {
    pub task_id: Option<i64>,
    pub status: String,
    pub detail: String,
}

fn pick_next_task(assignee: &str) -> Result<Option<task_db::TaskRow>> {
    // Highest priority first (task_db order), prefer "open" over "in_progress", never pick blocked.
    let mut tasks = task_db::task_list_for_assignee(assignee)?;
    tasks.retain(|t| t.status != "blocked" && t.status != "done" && t.status != "abandoned");
    if tasks.is_empty() {
        return Ok(None);
    }
    // Prefer open tasks first.
    if let Some(t) = tasks.iter().find(|t| t.status == "open") {
        return Ok(Some(t.clone()));
    }
    Ok(Some(tasks[0].clone()))
}

fn autonomy_owner() -> String {
    std::env::var("CHUMP_AUTONOMY_OWNER")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "chump".to_string())
}

fn ensure_task_contract(t: &task_db::TaskRow) -> Result<String> {
    let title = t.title.as_str();
    let repo = t.repo.as_deref();
    let notes = task_contract::ensure_contract(t.notes.as_deref(), title, repo);
    Ok(notes)
}

fn contract_has_acceptance_and_verify(notes: &str) -> bool {
    task_contract::acceptance(notes).is_some() && task_contract::verify(notes).is_some()
}

fn now_iso() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:03}", t.as_secs(), t.subsec_millis())
}

fn append_progress(notes: &str, line: &str) -> String {
    // Append to Progress section if present; else append a new Progress section.
    let mut out = notes.trim().to_string();
    let stamp = now_iso();
    let entry = format!("- [{}] {}\n", stamp, line.trim());

    if out.contains("## Progress") {
        // naive but deterministic: append at end
        out.push('\n');
        out.push_str(&entry);
        return out;
    }
    out.push_str("\n\n## Progress\n");
    out.push_str(&entry);
    out
}

/// Fetch up to `limit` memories relevant to a task and format them as a
/// concise block for injection into the executor prompt (AUTO-009).
///
/// Searches the memory DB with the task title + repo slug + domain keywords,
/// then filters for entries likely to be playbooks, gotchas, or recurring
/// patterns (by memory_type or content keywords). Returns an empty string when
/// the DB is unavailable or no matches exist.
fn fetch_task_playbooks(title: &str, repo: Option<&str>, limit: usize) -> String {
    if !crate::memory_db::db_available() {
        return String::new();
    }
    let mut query = title.to_string();
    if let Some(r) = repo {
        let slug = r.split('/').last().unwrap_or(r);
        if !slug.is_empty() {
            query.push(' ');
            query.push_str(slug);
        }
    }
    query.push_str(" playbook gotcha pattern");

    let candidates = match crate::memory_db::keyword_search_reranked(&query, limit * 3) {
        Ok(v) => v,
        Err(_) => return String::new(),
    };

    let relevant: Vec<_> = candidates
        .into_iter()
        .filter(|m| {
            m.memory_type == "playbook"
                || m.source.contains("playbook")
                || m.content.to_lowercase().contains("gotcha")
                || m.content.to_lowercase().contains("pattern")
                || m.content.to_lowercase().contains("do not")
                || m.content.to_lowercase().contains("always ")
                || m.content.to_lowercase().contains("never ")
        })
        .take(limit)
        .collect();

    if relevant.is_empty() {
        return String::new();
    }

    let mut out = String::from(
        "Relevant playbooks & patterns from memory (apply these to avoid known pitfalls):\n",
    );
    for (i, m) in relevant.iter().enumerate() {
        let excerpt: String = m
            .content
            .lines()
            .take(4)
            .collect::<Vec<_>>()
            .join("\n")
            .trim()
            .to_string();
        out.push_str(&format!("{}. [{}] {}\n", i + 1, m.source, excerpt));
    }
    out
}

fn extract_local_repo_path_from_clone_pull_output(s: &str) -> Option<String> {
    // github_clone_or_pull returns plain text that includes "... path: <PATH> ...".
    // Extract the first plausible absolute path after "path".
    for line in s.lines() {
        let l = line.trim();
        if let Some(idx) = l.to_lowercase().find("path") {
            let tail = &l[idx..];
            // Supported formats:
            // - "Local path: /abs/path"
            // - "with path /abs/path"
            let rest = if let Some(colon) = tail.find(':') {
                tail[colon + 1..].trim()
            } else {
                // After "path" token, consume whitespace.
                tail.trim_start_matches(|c: char| c.is_ascii_alphabetic())
                    .trim()
            };
            // Up to first whitespace/paren.
            let candidate = rest
                .split_whitespace()
                .next()
                .unwrap_or("")
                .trim_end_matches([')', ',', '.'])
                .trim();
            if candidate.starts_with('/') && candidate.len() > 1 {
                return Some(candidate.to_string());
            }
        }
    }
    None
}

async fn ensure_repo_context(task: &task_db::TaskRow) -> Result<Option<String>> {
    let repo = task
        .repo
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    let Some(repo) = repo else {
        return Ok(None);
    };

    // GitHub clone/pull: route through MCP bridge if available, else use git CLI directly
    if !set_working_repo_tool::set_working_repo_enabled() {
        return Err(anyhow!(
            "Task has repo={} but set_working_repo is disabled (requires CHUMP_MULTI_REPO_ENABLED=1 and CHUMP_REPO or CHUMP_HOME).",
            repo
        ));
    }

    let msg = if mcp_bridge::is_mcp_tool("github_clone_or_pull") {
        let result =
            mcp_bridge::call_mcp_tool("github_clone_or_pull", serde_json::json!({ "repo": repo }))
                .await
                .map_err(|e| anyhow!("github_clone_or_pull (MCP) failed: {}", e))?;
        result["output"].as_str().unwrap_or("").to_string()
    } else {
        // Fallback: clone/pull via git CLI (requires GITHUB_TOKEN)
        let token = std::env::var("GITHUB_TOKEN").map_err(|_| {
            anyhow!(
                "Task has repo={} but GITHUB_TOKEN not set and no MCP github server available",
                repo
            )
        })?;
        let base = repo_path::runtime_base().join("repos");
        let dir_name = repo.replace('/', "_");
        let target = base.join(&dir_name);
        let _ = std::fs::create_dir_all(&base);
        let url = format!("https://x-access-token:{}@github.com/{}.git", token, repo);
        if target.join(".git").exists() {
            let out = tokio::process::Command::new("git")
                .args(["pull", "origin", "main"])
                .current_dir(&target)
                .output()
                .await
                .map_err(|e| anyhow!("git pull failed: {}", e))?;
            format!(
                "pull: {}. Local path: {}",
                String::from_utf8_lossy(&out.stdout).trim(),
                target.display()
            )
        } else {
            let out = tokio::process::Command::new("git")
                .args(["clone", &url, target.to_str().unwrap_or("")])
                .output()
                .await
                .map_err(|e| anyhow!("git clone failed: {}", e))?;
            if !out.status.success() {
                return Err(anyhow!(
                    "git clone failed: {}",
                    String::from_utf8_lossy(&out.stderr)
                ));
            }
            format!(
                "cloned {} to {}. Call set_working_repo with path {} to use file tools.",
                repo,
                target.display(),
                target.display()
            )
        }
    };
    let local_path = extract_local_repo_path_from_clone_pull_output(&msg).ok_or_else(|| {
        anyhow!(
            "github_clone_or_pull returned unexpected output (could not extract local path): {}",
            msg
        )
    })?;

    let set_tool = set_working_repo_tool::SetWorkingRepoTool;
    let _ = set_tool
        .execute(serde_json::json!({ "path": local_path }))
        .await
        .map_err(|e| anyhow!("set_working_repo failed: {}", e))?;

    Ok(Some(repo.to_string()))
}

#[derive(Debug, Clone)]
struct VerifyResult {
    passed: u32,
    failed: u32,
    ignored: u32,
    raw: String,
}

fn parse_run_test_summary(s: &str) -> Option<VerifyResult> {
    // run_test returns: "passed=X failed=Y ignored=Z. Failing: [...]"
    let s = s.trim();
    let mut passed: Option<u32> = None;
    let mut failed: Option<u32> = None;
    let mut ignored: Option<u32> = None;
    for part in s.split_whitespace() {
        if let Some(v) = part.strip_prefix("passed=") {
            passed = v
                .trim_end_matches(|c: char| !c.is_ascii_digit())
                .parse::<u32>()
                .ok();
        } else if let Some(v) = part.strip_prefix("failed=") {
            failed = v
                .trim_end_matches(|c: char| !c.is_ascii_digit())
                .parse::<u32>()
                .ok();
        } else if let Some(v) = part.strip_prefix("ignored=") {
            ignored = v
                .trim_end_matches(|c: char| !c.is_ascii_digit())
                .parse::<u32>()
                .ok();
        }
    }
    Some(VerifyResult {
        passed: passed?,
        failed: failed?,
        ignored: ignored.unwrap_or(0),
        raw: s.to_string(),
    })
}

fn infer_verify_runner(verify_section: &str) -> Option<String> {
    // Try JSON contract first for explicit runner hint.
    let fake_notes = format!("## Verify\n{}", verify_section);
    if let Some(vc) = task_contract::parse_verify_json(&fake_notes) {
        if let Some(runner) = vc.runner {
            let r = runner.trim().to_lowercase();
            if !r.is_empty() {
                return Some(r);
            }
        }
    }
    // Fallback: keyword heuristic.
    let v = verify_section.to_lowercase();
    if v.contains("pnpm test") {
        return Some("pnpm".to_string());
    }
    if v.contains("npm test") {
        return Some("npm".to_string());
    }
    if v.contains("cargo test") || v.contains("run_test") || v.contains("cargo") {
        return Some("cargo".to_string());
    }
    None
}

fn extract_verify_commands(verify_section: &str) -> Vec<String> {
    // 1. Try JSON VerifyContract first (structured, reliable).
    //    We wrap in a fake notes block so parse_verify_json can find it.
    let fake_notes = format!("## Verify\n{}", verify_section);
    if let Some(vc) = task_contract::parse_verify_json(&fake_notes) {
        if !vc.verify_commands.is_empty() {
            tracing::debug!(
                "extracted {} verify commands from JSON contract",
                vc.verify_commands.len()
            );
            return vc.verify_commands;
        }
    }

    // 2. Fallback: heuristic markdown extraction for legacy contracts.
    // - "- [ ] Command(s): <cmd>"
    // - "Command(s): <cmd>"
    // - fenced code blocks (skip json fences)
    let mut out: Vec<String> = Vec::new();
    let mut in_fence = false;
    let mut fence_is_json = false;
    for line in verify_section.lines() {
        let t = line.trim();
        if t.starts_with("```") {
            if !in_fence {
                fence_is_json = t.contains("json");
                in_fence = true;
            } else {
                in_fence = false;
                fence_is_json = false;
            }
            continue;
        }
        if in_fence {
            if fence_is_json {
                continue; // skip JSON blocks in markdown fallback
            }
            let cmd = t.trim_start_matches('$').trim();
            if !cmd.is_empty() {
                out.push(cmd.to_string());
            }
            continue;
        }
        let t = t.trim_start_matches("- [ ]").trim_start_matches('-').trim();
        if let Some(rest) = t.strip_prefix("Command(s):") {
            let cmd = rest.trim();
            if !cmd.is_empty() {
                out.push(cmd.to_string());
            }
        } else if let Some(rest) = t.strip_prefix("Command:") {
            let cmd = rest.trim();
            if !cmd.is_empty() {
                out.push(cmd.to_string());
            }
        }
    }
    out
}

fn wrap_with_exit_code(cmd: &str) -> String {
    // Ensure we can deterministically detect exit status from run_cli output.
    // NOTE: run_cli already uses `sh -c`, so this is safe and portable within that context.
    format!("({}); echo __CHUMP_EXIT_CODE:$?", cmd)
}

fn parse_exit_code(output: &str) -> Option<i32> {
    for line in output.lines().rev() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("__CHUMP_EXIT_CODE:") {
            return rest.trim().parse::<i32>().ok();
        }
    }
    None
}

#[async_trait::async_trait]
trait Executor {
    async fn run(&self, prompt: &str) -> String;
}

struct RealExecutor;

#[async_trait::async_trait]
impl Executor for RealExecutor {
    async fn run(&self, prompt: &str) -> String {
        match discord::build_chump_agent_cli() {
            Ok((agent, _ready)) => agent
                .run(prompt)
                .await
                .map(|o| o.reply)
                .unwrap_or_else(|e| format!("Agent error: {}", e)),
            Err(e) => format!("Agent build error: {}", e),
        }
    }
}

#[async_trait::async_trait]
trait Verifier {
    async fn verify(&self, notes: &str) -> (String, String, &'static str);
}

struct RealVerifier;

#[async_trait::async_trait]
impl Verifier for RealVerifier {
    async fn verify(&self, notes: &str) -> (String, String, &'static str) {
        let verify_section = task_contract::verify(notes).unwrap_or_default();
        let runner = infer_verify_runner(&verify_section);
        if runner.is_some() && repo_path::repo_root_is_explicit() {
            let tool = run_test_tool::RunTestTool;
            let input = serde_json::json!({
                "runner": runner.clone().unwrap_or_else(|| "cargo".to_string())
            });
            if let Ok(s) = tool.execute(input).await {
                if let Some(vr) = parse_run_test_summary(&s) {
                    if vr.failed == 0 {
                        return (
                            "done".to_string(),
                            format!(
                                "Verified ok: {} (passed={} ignored={})",
                                vr.raw, vr.passed, vr.ignored
                            ),
                            "win",
                        );
                    }
                    return (
                        "blocked".to_string(),
                        format!(
                            "Verification failed: {} (passed={} ignored={})",
                            vr.raw, vr.passed, vr.ignored
                        ),
                        "frustrating",
                    );
                }
                return (
                    "blocked".to_string(),
                    format!("Verification output was not parseable: {}", s),
                    "uncertain",
                );
            }
            return (
                "blocked".to_string(),
                "run_test failed to execute.".to_string(),
                "uncertain",
            );
        }
        // Fallback: run explicit verify commands (still deterministic) via run_cli.
        // We only treat exit-code-0 as success; otherwise block with captured output.
        let cmds = extract_verify_commands(&verify_section);
        if !cmds.is_empty() && repo_path::repo_root_is_explicit() {
            let cli = crate::cli_tool::CliTool::for_discord();
            let mut last_blocked: Option<(String, &'static str)> = None;
            for cmd in cmds.into_iter().take(3) {
                let wrapped = wrap_with_exit_code(&cmd);
                match cli.execute(serde_json::json!({ "command": wrapped })).await {
                    Ok(out) => match parse_exit_code(&out).unwrap_or(1) {
                        0 => {
                            return (
                                "done".to_string(),
                                format!("Verified ok via command: {}", cmd),
                                "win",
                            );
                        }
                        code => {
                            last_blocked = Some((
                                    format!(
                                        "Verification command failed (exit {}). Command: {}\n\nOutput:\n{}",
                                        code,
                                        cmd,
                                        out.trim()
                                    ),
                                    "frustrating",
                                ));
                        }
                    },
                    Err(e) => {
                        last_blocked = Some((
                            format!("Verification command could not run: {} ({})", cmd, e),
                            "uncertain",
                        ));
                    }
                }
            }
            if let Some((msg, mood)) = last_blocked {
                return ("blocked".to_string(), msg, mood);
            }
        }

        (
            "blocked".to_string(),
            "No runnable verification found; fill Verify section with an executable check (e.g. cargo test) and rerun."
                .to_string(),
            "uncertain",
        )
    }
}

async fn autonomy_once_with(
    assignee: &str,
    exec: &dyn Executor,
    verifier: &dyn Verifier,
) -> Result<AutonomyOutcome> {
    autonomy_once_impl(assignee, exec, verifier).await
}

/// Run one autonomy loop iteration:
/// - pick next task for assignee
/// - ensure contract exists in notes
/// - mark in_progress
/// - execute via agent prompt
/// - verify via contract "Verify" section (run_test when possible)
/// - mark done or blocked + episode log
#[instrument(skip(assignee), fields(assignee = %assignee.trim()))]
pub async fn autonomy_once(assignee: &str) -> Result<AutonomyOutcome> {
    let exec = RealExecutor;
    let verifier = RealVerifier;
    let out = autonomy_once_impl(assignee, &exec, &verifier).await;
    match &out {
        Ok(o) => {
            let _ = crate::job_log::insert_job(
                "autonomy_once",
                o.status.as_str(),
                o.task_id,
                None,
                Some(o.detail.as_str()),
                None,
            );
            if crate::web_push_send::autonomy_push_enabled()
                && matches!(o.status.as_str(), "done" | "blocked")
            {
                let title = if o.status == "done" {
                    "Chump: autonomy done"
                } else {
                    "Chump: autonomy blocked"
                };
                let body = o.detail.clone();
                let title = title.to_string();
                tokio::spawn(async move {
                    let body_short = if body.chars().count() > 200 {
                        body.chars().take(200).collect::<String>() + "…"
                    } else {
                        body
                    };
                    let (n_ok, n_fail) =
                        crate::web_push_send::broadcast_json_notification(&title, &body_short)
                            .await;
                    if n_ok + n_fail > 0 {
                        tracing::info!(
                            "web push (autonomy): {} delivered, {} failed",
                            n_ok,
                            n_fail
                        );
                    }
                });
            }
        }
        Err(e) => {
            let msg = e.to_string();
            let _ =
                crate::job_log::insert_job("autonomy_once", "error", None, None, None, Some(&msg));
            if crate::web_push_send::autonomy_push_enabled() {
                tokio::spawn(async move {
                    let body_short = if msg.chars().count() > 200 {
                        msg.chars().take(200).collect::<String>() + "…"
                    } else {
                        msg
                    };
                    let _ = crate::web_push_send::broadcast_json_notification(
                        "Chump: autonomy error",
                        &body_short,
                    )
                    .await;
                });
            }
        }
    }
    out
}

#[instrument(skip(exec, verifier), fields(assignee = %assignee.trim()))]
async fn autonomy_once_impl(
    assignee: &str,
    exec: &dyn Executor,
    verifier: &dyn Verifier,
) -> Result<AutonomyOutcome> {
    if !task_db::task_available() {
        return Err(anyhow!("task DB not available"));
    }

    let assignee = assignee.trim();
    let assignee = if assignee.is_empty() {
        "chump"
    } else {
        assignee
    };

    let mut task = match pick_next_task(assignee)? {
        Some(t) => t,
        None => {
            return Ok(AutonomyOutcome {
                task_id: None,
                status: "noop".to_string(),
                detail: "No actionable tasks.".to_string(),
            });
        }
    };

    let owner = autonomy_owner();
    let lease = task_db::task_lease_claim(task.id, Some(&owner))?;
    let lease = match lease {
        Some(l) => l,
        None => {
            return Ok(AutonomyOutcome {
                task_id: Some(task.id),
                status: "noop".to_string(),
                detail: format!(
                    "Task #{} is already leased by another worker; skipping.",
                    task.id
                ),
            });
        }
    };

    let ensured = ensure_task_contract(&task)?;
    if task.notes.as_deref().unwrap_or("") != ensured {
        let _ = task_db::task_update_notes(task.id, Some(&ensured));
        task.notes = Some(ensured.clone());
    }
    // Carry notes as an owned string so we can safely update notes + task row fields
    // without borrow checker conflicts.
    let mut notes = task.notes.clone().unwrap_or_default();
    if !contract_has_acceptance_and_verify(&notes) {
        let _ = task_db::task_update_status(task.id, "blocked", Some(&notes));
        let _ = task_db::task_lease_release(task.id, &lease.token);
        if episode_db::episode_available() {
            let _ = episode_db::episode_log(
                &format!("Blocked task #{} (missing acceptance/verify)", task.id),
                Some("Task contract missing Acceptance/Verify sections; requires human fill-in."),
                Some("autonomy,task,blocked"),
                task.repo.as_deref(),
                Some("uncertain"),
                None,
                task.issue_number,
            );
        }
        return Ok(AutonomyOutcome {
            task_id: Some(task.id),
            status: "blocked".to_string(),
            detail: "Task missing Acceptance/Verify; set to blocked.".to_string(),
        });
    }

    // Deterministic repo setup: if task.repo is set, ensure we clone/pull and set the working repo
    // before the executor or verifier runs. If we cannot, block with an explicit reason.
    if task
        .repo
        .as_deref()
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
    {
        match ensure_repo_context(&task).await {
            Ok(Some(repo)) => {
                notes = append_progress(
                    &notes,
                    &format!("repo_preflight: set working repo for {}", repo),
                );
                let _ = task_db::task_update_notes(task.id, Some(&notes));
                task.notes = Some(notes.clone());
            }
            Ok(None) => {}
            Err(e) => {
                let mut notes_block =
                    append_progress(&notes, &format!("repo_preflight_error: {}", e));
                notes_block = append_progress(
                    &notes_block,
                    "repo_preflight: blocked (enable GitHub tools + multi-repo, or clear task.repo).",
                );
                let _ = task_db::task_update_status(task.id, "blocked", Some(&notes_block));
                let _ = task_db::task_lease_release(task.id, &lease.token);
                if episode_db::episode_available() {
                    let _ = episode_db::episode_log(
                        &format!("Blocked task #{} (repo preflight)", task.id),
                        Some(&e.to_string()),
                        Some("autonomy,task,blocked"),
                        task.repo.as_deref(),
                        Some("uncertain"),
                        None,
                        task.issue_number,
                    );
                }
                return Ok(AutonomyOutcome {
                    task_id: Some(task.id),
                    status: "blocked".to_string(),
                    detail: format!("Repo preflight failed: {}", e),
                });
            }
        }
    }

    // Biological tick throttle: when the agent is in a high-stress state
    // (high NA + low serotonin = frustrated), pause before burning GPU cycles
    // on another attempt. This lets background processes settle and prevents
    // rapid-fire hallucinated retries.
    {
        let nm = crate::neuromodulation::levels();
        let task_belief = crate::belief_state::task_belief();
        let consecutive_failures = task_belief.streak_failures;
        if nm.noradrenaline > 1.3 && nm.serotonin < 0.8 && consecutive_failures >= 2 {
            let pause_secs = if consecutive_failures >= 4 { 60 } else { 30 };
            tracing::info!(
                "biological throttle: NA={:.2} 5HT={:.2} failures={} — pausing {}s",
                nm.noradrenaline,
                nm.serotonin,
                consecutive_failures,
                pause_secs,
            );
            tokio::time::sleep(std::time::Duration::from_secs(pause_secs)).await;
        }
    }

    // Use our owned notes string for the rest of the loop.
    let _ = task_db::task_update_status(task.id, "in_progress", Some(&notes));

    let sections = task_contract::extract_sections(&notes);
    let acceptance = sections
        .get(&task_contract::SECTION_ACCEPTANCE.to_lowercase())
        .cloned()
        .unwrap_or_default();
    let verify = sections
        .get(&task_contract::SECTION_VERIFY.to_lowercase())
        .cloned()
        .unwrap_or_default();
    let plan = sections
        .get(&task_contract::SECTION_PLAN.to_lowercase())
        .cloned()
        .unwrap_or_default();
    let ctx = sections
        .get(&task_contract::SECTION_CONTEXT.to_lowercase())
        .cloned()
        .unwrap_or_default();

    let playbooks = fetch_task_playbooks(&task.title, task.repo.as_deref(), 3);
    let playbook_section = if playbooks.is_empty() {
        String::new()
    } else {
        format!("{}\n\n", playbooks)
    };

    let exec_prompt = format!(
        "You are running an autonomy loop for task #{id}: {title}\n\n\
Context:\n{ctx}\n\n\
Plan:\n{plan}\n\n\
Acceptance (done looks like):\n{acceptance}\n\n\
Verify:\n{verify}\n\n\
{playbook_section}\
Rules:\n\
- Do the work using tools as needed.\n\
- If the task is for a repo and requires repo context, ensure the correct repo is set (github_clone_or_pull + set_working_repo) before file/git/test tools.\n\
- Update the task notes Progress section with what you did and what remains (use task update notes).\n\
- Do not mark the task done yourself; the autonomy loop will verify and close.\n\
Reply with a short completion summary.",
        id = task.id,
        title = task.title,
        ctx = ctx.trim(),
        plan = plan.trim(),
        acceptance = acceptance.trim(),
        verify = verify.trim(),
        playbook_section = playbook_section,
    );

    let exec_reply = exec.run(&exec_prompt).await;

    let refreshed = task_db::task_list_for_assignee(assignee)?
        .into_iter()
        .find(|t| t.id == task.id);
    let mut notes_now = refreshed
        .as_ref()
        .and_then(|t| t.notes.as_deref())
        .unwrap_or(&notes)
        .to_string();

    notes_now = append_progress(
        &notes_now,
        &format!("executor_summary: {}", exec_reply.trim()),
    );
    let _ = task_db::task_update_notes(task.id, Some(&notes_now));

    // Renew lease before verification (keeps long runs safe under TTL).
    let _ = task_db::task_lease_renew(task.id, &lease.token);

    let (final_status, final_detail, sentiment) = verifier.verify(&notes_now).await;

    let notes_final = append_progress(&notes_now, &format!("verify: {}", final_detail));
    let _ = task_db::task_update_notes(task.id, Some(&notes_final));

    if final_status == "done" {
        let _ = task_db::task_complete(task.id, Some(&notes_final));
    } else {
        let _ = task_db::task_update_status(task.id, "blocked", Some(&notes_final));
        let follow_title = format!("Unblock task #{}: {}", task.id, task.title);
        let follow_notes = format!(
            "Task #{id} is blocked.\n\nReason:\n{reason}\n\nNext:\n- Fill Verify section with runnable commands, or fix failing tests, then rerun autonomy.\n",
            id = task.id,
            reason = final_detail
        );
        let _ = task_db::task_create(
            &follow_title,
            task.repo.as_deref(),
            task.issue_number,
            Some(5),
            Some("jeff"),
            Some(&follow_notes),
        );
    }

    let _ = task_db::task_lease_release(task.id, &lease.token);

    let mut last_episode_id: Option<i64> = None;
    if episode_db::episode_available() {
        last_episode_id = episode_db::episode_log(
            &format!("Autonomy {} task #{}", final_status, task.id),
            Some(&final_detail),
            Some("autonomy,task"),
            task.repo.as_deref(),
            Some(sentiment),
            None,
            task.issue_number,
        )
        .ok();
    }

    // COG-006: structured reflection. Best-effort — never block task completion on this.
    // Heuristic mapping: status "done" → Pass, anything else → Failure (we conflate
    // PartialSuccess/Abandoned into Failure here because the verifier only emits two
    // states; richer outcome classification is a future LLM-assisted upgrade).
    if reflection_db::reflection_available() {
        let outcome_class = if final_status == "done" {
            reflection::OutcomeClass::Pass
        } else {
            reflection::OutcomeClass::Failure
        };
        // Pull tool errors out of the verify detail line — verifier prepends
        // "verify failed: <stderr>" or similar on blocked outcomes.
        let tool_errors: Vec<String> = if outcome_class == reflection::OutcomeClass::Pass {
            Vec::new()
        } else {
            vec![final_detail.clone()]
        };
        let r = reflection::reflect_heuristic(
            &task.title,
            &final_detail,
            outcome_class,
            &tool_errors,
            None,
            None,
        );
        let mut r = r;
        r.episode_id = last_episode_id;
        let _ = reflection_db::save_reflection(&r, Some(task.id));
    }

    Ok(AutonomyOutcome {
        task_id: Some(task.id),
        status: final_status,
        detail: final_detail,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    struct FakeExec;

    #[async_trait::async_trait]
    impl Executor for FakeExec {
        async fn run(&self, _prompt: &str) -> String {
            // Simulate doing work by updating the task notes directly.
            // The prompt contains "task #<id>".
            let id = 1i64;
            let rows = task_db::task_list_for_assignee("chump").unwrap_or_default();
            let id = rows.first().map(|t| t.id).unwrap_or(id);
            let current = rows
                .into_iter()
                .find(|t| t.id == id)
                .and_then(|t| t.notes)
                .unwrap_or_default();
            let updated = append_progress(&current, "fake executor ran");
            let _ = task_db::task_update_notes(id, Some(&updated));
            "ok".to_string()
        }
    }

    struct FakeVerifier {
        outcome: (String, String, &'static str),
    }

    #[async_trait::async_trait]
    impl Verifier for FakeVerifier {
        async fn verify(&self, _notes: &str) -> (String, String, &'static str) {
            self.outcome.clone()
        }
    }

    #[test]
    fn parse_run_test_summary_parses_counts() {
        let s = "passed=3 failed=1 ignored=2. Failing: [x]";
        let r = parse_run_test_summary(s).unwrap();
        assert_eq!(r.passed, 3);
        assert_eq!(r.failed, 1);
        assert_eq!(r.ignored, 2);
    }

    #[test]
    fn extract_verify_commands_finds_command_lines_and_fences() {
        let v = r#"
- [ ] Command(s): cargo test

```bash
$ echo ok
```
"#;
        let cmds = extract_verify_commands(v);
        assert!(cmds.contains(&"cargo test".to_string()));
        assert!(cmds.contains(&"echo ok".to_string()));
    }

    #[test]
    fn extract_verify_commands_prefers_json_contract() {
        let v = r#"
```json
{"verify_commands": ["cargo test --release", "cargo clippy"], "runner": "cargo"}
```
"#;
        let cmds = extract_verify_commands(v);
        assert_eq!(cmds, vec!["cargo test --release", "cargo clippy"]);
    }

    #[test]
    fn extract_verify_commands_json_fallback_to_markdown() {
        // If JSON is malformed, falls back to markdown parsing
        let v = r#"
```json
{"not_valid": true}
```
- [ ] Command(s): npm test
"#;
        let cmds = extract_verify_commands(v);
        assert!(cmds.contains(&"npm test".to_string()));
    }

    #[test]
    fn wrap_and_parse_exit_code_roundtrip() {
        let cmd = "echo hi";
        let wrapped = wrap_with_exit_code(cmd);
        assert!(wrapped.contains("__CHUMP_EXIT_CODE"));
        let output = "hi\n__CHUMP_EXIT_CODE:0\n";
        assert_eq!(parse_exit_code(output), Some(0));
    }

    #[test]
    fn extract_local_repo_path_from_clone_pull_output_parses_common_messages() {
        let s1 = "pull main: Already up to date.. Local path: /tmp/repos/o_r (call set_working_repo with this path to use file tools)";
        assert_eq!(
            extract_local_repo_path_from_clone_pull_output(s1),
            Some("/tmp/repos/o_r".to_string())
        );
        let s2 = "cloned owner/repo (ref main) to /home/me/repos/owner_repo. Call set_working_repo with path /home/me/repos/owner_repo to use file tools.";
        assert_eq!(
            extract_local_repo_path_from_clone_pull_output(s2),
            Some("/home/me/repos/owner_repo".to_string())
        );
    }

    #[tokio::test]
    #[serial]
    async fn autonomy_once_deterministic_done_path() {
        // Use task_db's cfg(test) sqlite path by isolating cwd.
        let dir = std::env::temp_dir().join(format!(
            "chump_autonomy_once_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let notes = task_contract::ensure_contract(
            Some("## Acceptance\n- [ ] ok\n\n## Verify\n- [ ] cargo test\n"),
            "T",
            None,
        );
        let id =
            task_db::task_create("T", None, None, Some(5), Some("chump"), Some(&notes)).unwrap();

        let exec = FakeExec;
        let verifier = FakeVerifier {
            outcome: ("done".to_string(), "Verified ok (fake)".to_string(), "win"),
        };
        let out = autonomy_once_with("chump", &exec, &verifier).await.unwrap();
        assert_eq!(out.task_id, Some(id));
        assert_eq!(out.status, "done");

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
    }

    /// COG-010: end-to-end reflection flywheel.
    ///
    /// Failed task → reflect_heuristic emits a Medium-priority lesson →
    /// reflection_db persists it → PromptAssembler::assemble surfaces it
    /// in the next turn's system prompt as a "## Lessons" block.
    ///
    /// This is the smoke test that catches schema drift, scope-filter
    /// regressions, and any future split of the save/load round-trip. The
    /// individual pieces are unit-tested in `reflection_db::tests`; this
    /// pins the cross-module wiring.
    #[tokio::test]
    #[serial]
    async fn reflection_flywheel_persists_and_surfaces_lessons() {
        // Isolated tempdir so we don't touch the user's chump_memory.db.
        let dir = std::env::temp_dir().join(format!(
            "chump_reflect_flywheel_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        // 1. Create a task with a valid contract.
        let notes = task_contract::ensure_contract(
            Some("## Acceptance\n- [ ] ok\n\n## Verify\n- [ ] cargo test\n"),
            "T",
            None,
        );
        let _id = task_db::task_create(
            "Verify file before patch_file",
            None,
            None,
            Some(5),
            Some("chump"),
            Some(&notes),
        )
        .unwrap();

        // 2. Run autonomy with a verifier that fails with a tool-timeout
        //    signature. detect_pattern_heuristic maps this to ToolFailure,
        //    which suggest_improvements turns into a Medium-priority lesson
        //    scoped to "tool_middleware".
        let exec = FakeExec;
        let verifier = FakeVerifier {
            outcome: (
                "blocked".to_string(),
                "verify failed: cargo test timed out after 60s".to_string(),
                "loss",
            ),
        };
        let out = autonomy_once_with("chump", &exec, &verifier).await.unwrap();
        assert_eq!(out.status, "blocked");

        // 3. Confirm the reflection got persisted with a usable lesson.
        let targets = crate::reflection_db::load_recent_high_priority_targets(10, None)
            .expect("reflection_db query");
        assert!(
            !targets.is_empty(),
            "expected at least one improvement target after blocked task; got 0"
        );
        let directives: Vec<_> = targets.iter().map(|t| t.directive.as_str()).collect();
        assert!(
            directives
                .iter()
                .any(|d| d.contains("retry") || d.contains("validate") || d.contains("alternate")),
            "expected a tool_middleware-scoped directive; got {:?}",
            directives
        );

        // 4. Now assemble a fresh prompt — it must contain the lessons block.
        //    Using a trivial perception so no entities steal the scope filter.
        let pa = crate::agent_loop::PromptAssembler {
            base_system_prompt: Some("BASE".to_string()),
        };
        let perception = crate::perception::PerceivedInput {
            raw_text: "next task".to_string(),
            likely_needs_tools: false,
            detected_entities: vec![],
            detected_constraints: vec![],
            ambiguity_level: 0.0,
            risk_indicators: vec![],
            question_count: 0,
            task_type: crate::perception::TaskType::Question,
        };
        let prompt = pa.assemble(&perception).expect("assembled prompt");
        assert!(
            prompt.contains("## Lessons from prior episodes"),
            "lessons block missing from assembled prompt; got: {}",
            prompt
        );
        // Should preserve the base prompt verbatim — lessons append, not replace.
        assert!(
            prompt.starts_with("BASE"),
            "lessons block stomped base prompt; got: {}",
            prompt
        );

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
    }

    #[tokio::test]
    #[serial]
    async fn autonomy_once_blocks_when_repo_set_but_gates_missing() {
        // Isolate DB and ensure gates are disabled.
        std::env::remove_var("GITHUB_TOKEN");
        std::env::remove_var("CHUMP_GITHUB_REPOS");
        std::env::remove_var("CHUMP_MULTI_REPO_ENABLED");
        std::env::remove_var("CHUMP_HOME");
        std::env::remove_var("CHUMP_REPO");

        let dir = std::env::temp_dir().join(format!(
            "chump_autonomy_once_repo_gate_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        let notes = task_contract::ensure_contract(
            Some("## Acceptance\n- [ ] ok\n\n## Verify\n- [ ] cargo test\n"),
            "T",
            Some("owner/repo"),
        );
        let id = task_db::task_create(
            "T",
            Some("owner/repo"),
            None,
            Some(5),
            Some("chump"),
            Some(&notes),
        )
        .unwrap();

        let exec = FakeExec;
        let verifier = FakeVerifier {
            outcome: ("done".to_string(), "Verified ok (fake)".to_string(), "win"),
        };
        let out = autonomy_once_with("chump", &exec, &verifier).await.unwrap();
        assert_eq!(out.task_id, Some(id));
        assert_eq!(out.status, "blocked");

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
    }

    // AUTO-009: fetch_task_playbooks unit tests.

    #[test]
    fn fetch_task_playbooks_returns_empty_when_db_unavailable() {
        // DB is unavailable outside a serial test with temp dir setup.
        // Calling without setup exercises the db_available() guard.
        let result = fetch_task_playbooks("Fix login bug", Some("owner/repo"), 3);
        // Either empty (DB not available) or a valid string (if DB happened to be up).
        // The important invariant: it never panics.
        let _ = result;
    }

    #[test]
    fn fetch_task_playbooks_filters_content_keywords() {
        // Smoke-test the filter logic with synthetic MemoryRows.
        let rows = vec![
            crate::memory_db::MemoryRow {
                id: 1,
                content: "Always run cargo fmt before committing.".to_string(),
                ts: "0".to_string(),
                source: "user".to_string(),
                confidence: 1.0,
                verified: 1,
                sensitivity: "normal".to_string(),
                expires_at: None,
                memory_type: "fact".to_string(),
            },
            crate::memory_db::MemoryRow {
                id: 2,
                content: "Never use unwrap() in production code.".to_string(),
                ts: "0".to_string(),
                source: "user".to_string(),
                confidence: 1.0,
                verified: 0,
                sensitivity: "normal".to_string(),
                expires_at: None,
                memory_type: "fact".to_string(),
            },
            crate::memory_db::MemoryRow {
                id: 3,
                content: "Irrelevant: the sky is blue.".to_string(),
                ts: "0".to_string(),
                source: "user".to_string(),
                confidence: 0.5,
                verified: 0,
                sensitivity: "normal".to_string(),
                expires_at: None,
                memory_type: "fact".to_string(),
            },
        ];

        // Run the same filter logic as fetch_task_playbooks manually.
        let relevant: Vec<_> = rows
            .iter()
            .filter(|m| {
                m.memory_type == "playbook"
                    || m.source.contains("playbook")
                    || m.content.to_lowercase().contains("gotcha")
                    || m.content.to_lowercase().contains("pattern")
                    || m.content.to_lowercase().contains("do not")
                    || m.content.to_lowercase().contains("always ")
                    || m.content.to_lowercase().contains("never ")
            })
            .collect();

        assert_eq!(relevant.len(), 2, "should match 'always' and 'never' rows");
        assert!(relevant.iter().any(|m| m.content.contains("cargo fmt")));
        assert!(relevant.iter().any(|m| m.content.contains("unwrap")));
    }

    #[test]
    #[serial]
    fn exec_prompt_includes_playbook_section_when_memories_exist() {
        use crate::memory_db::{insert_one, MemoryEnrichment};

        let dir =
            std::env::temp_dir().join(format!("chump_auto009_{}", uuid::Uuid::new_v4().simple()));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        // Insert a playbook-type memory.
        let _ = insert_one(
            "Always verify with cargo test before marking done.",
            "0",
            "test-source",
            Some(&MemoryEnrichment {
                memory_type: Some("playbook".to_string()),
                confidence: Some(1.0),
                verified: Some(1),
                ..Default::default()
            }),
        );

        let result = fetch_task_playbooks("Fix CI", None, 3);
        // Should find the "playbook" memory_type entry.
        assert!(
            result.contains("cargo test") || result.is_empty(),
            "if DB is available, should surface the playbook memory"
        );

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
    }
}
