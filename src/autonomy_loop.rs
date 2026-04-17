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
use crate::memory_db;
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

/// Fetch up to 3 relevant memory entries for a task (AUTO-009).
/// Searches by task title + repo; surface playbooks, gotchas, and procedures.
/// Returns a formatted block ready for injection into exec_prompt, or empty string if none.
fn fetch_task_memory_context(task: &task_db::TaskRow) -> String {
    // Build a compound query: task title words + optional repo name.
    let mut query_parts: Vec<&str> = task.title.split_whitespace().collect();
    if let Some(ref repo) = task.repo {
        // Use only the last segment of "owner/repo" to reduce FTS noise.
        let short = repo.split('/').last().unwrap_or(repo.as_str());
        query_parts.push(short);
    }
    let query = query_parts.join(" ");
    let rows = match memory_db::keyword_search(&query, 5) {
        Ok(r) => r,
        Err(_) => return String::new(),
    };
    if rows.is_empty() {
        return String::new();
    }
    // Take top 3, deduplicated by leading line.
    let snippets: Vec<String> = rows
        .into_iter()
        .take(3)
        .map(|r| {
            let snippet: String = r.content.chars().take(400).collect();
            format!("- [{memory_type}] {snippet}", memory_type = r.memory_type)
        })
        .collect();
    format!(
        "Relevant memory (top matches from prior episodes — use as context only):\n{}",
        snippets.join("\n")
    )
}

fn pick_next_task(assignee: &str) -> Result<Option<task_db::TaskRow>> {
    // Try dependency-aware selection first: open tasks with all deps satisfied, ordered by
    // urgency score (priority * 10 + age_days). Falls back to in_progress tasks if no open
    // tasks are unblocked.
    let unblocked = task_db::task_list_unblocked_for_assignee(assignee)?;
    if !unblocked.is_empty() {
        let scored = score_tasks_by_urgency(unblocked);
        let chosen = scored.into_iter().next().map(|(t, _)| t);
        if let Some(ref t) = chosen {
            tracing::info!(
                task_id = t.id,
                priority = t.priority,
                title = %t.title,
                "pick_next_task: selected via dependency-aware urgency scoring"
            );
        }
        return Ok(chosen);
    }
    // Fall back to non-blocked in_progress tasks (no dependency check — already started).
    let mut tasks = task_db::task_list_for_assignee(assignee)?;
    tasks.retain(|t| t.status == "in_progress");
    if tasks.is_empty() {
        tracing::info!(
            "pick_next_task: no actionable tasks for assignee={}",
            assignee
        );
        return Ok(None);
    }
    let chosen = tasks.into_iter().next();
    if let Some(ref t) = &chosen {
        tracing::info!(
            task_id = t.id,
            priority = t.priority,
            title = %t.title,
            "pick_next_task: resuming in_progress task (fallback)"
        );
    }
    Ok(chosen)
}

/// Score tasks by urgency: higher priority wins; ties broken by age (older = more urgent).
fn score_tasks_by_urgency(tasks: Vec<task_db::TaskRow>) -> Vec<(task_db::TaskRow, i64)> {
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let mut scored: Vec<(task_db::TaskRow, i64)> = tasks
        .into_iter()
        .map(|t| {
            // Parse created_at as unix timestamp or ISO-8601 seconds component.
            let age_days = t
                .created_at
                .as_deref()
                .and_then(|s| {
                    // "1234567890.123" or ISO "2024-01-01T..."
                    if let Ok(f) = s.split('.').next().unwrap_or(s).parse::<i64>() {
                        Some((now_secs - f).max(0) / 86400)
                    } else {
                        None
                    }
                })
                .unwrap_or(0);
            let score = t.priority * 10 + age_days;
            (t, score)
        })
        .collect();
    scored.sort_by(|a, b| b.1.cmp(&a.1));
    scored
}

/// AUTO-008: heuristic complexity score for a task (0.0 = simple, 1.0 = very complex).
/// Factors: notes length, number of acceptance bullet points, number of "and"/"or" conjunctions
/// in the title/acceptance section, presence of risk markers.
fn task_complexity_score(task: &task_db::TaskRow) -> f64 {
    let notes = task.notes.as_deref().unwrap_or("");
    let title = task.title.as_str();

    // 1. Notes length contribution (normalised to ~1000 chars = 0.3)
    let len_score = (notes.len() as f64 / 1000.0).min(0.3);

    // 2. Number of acceptance bullet points (each -/✓/• line counts)
    let acceptance_bullets = crate::task_contract::acceptance(notes)
        .map(|s| {
            s.lines()
                .filter(|l| {
                    let t = l.trim();
                    t.starts_with('-') || t.starts_with('*') || t.starts_with('•')
                })
                .count()
        })
        .unwrap_or(0);
    // 3+ bullets → complex; normalise: 0.1 per bullet up to 0.4
    let bullet_score = ((acceptance_bullets as f64 * 0.1).min(0.4)).max(0.0);

    // 3. Conjunctions ("and", "or", "then", ";") in title/acceptance suggest multi-step
    let combined = format!(
        "{} {}",
        title,
        crate::task_contract::acceptance(notes).unwrap_or_default()
    );
    let conj_count = combined
        .split_whitespace()
        .filter(|w| {
            matches!(
                w.to_lowercase()
                    .trim_matches(|c: char| !c.is_alphanumeric()),
                "and" | "or" | "then"
            )
        })
        .count()
        + combined.chars().filter(|&c| c == ';').count();
    let conj_score = ((conj_count as f64 * 0.05).min(0.2)).max(0.0);

    // 4. Risk markers
    let risk_score =
        if notes.to_lowercase().contains("## risks") || notes.to_lowercase().contains("## risk") {
            0.1
        } else {
            0.0
        };

    (len_score + bullet_score + conj_score + risk_score).min(1.0)
}

fn decompose_threshold() -> f64 {
    std::env::var("CHUMP_TASK_DECOMPOSE_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.6)
}

// COG-007 ─────────────────────────────────────────────────────────────────────

fn probe_threshold() -> f64 {
    std::env::var("CHUMP_PROBE_THRESHOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.75)
}

/// COG-007: estimate the epistemic surprisal load for a task.
/// Blends the global surprisal EMA with task-note signals (unknowns, missing sections).
/// Returns a value in [0.0, 1.0]; higher means more uncertain.
pub fn task_surprisal_estimate(task: &task_db::TaskRow) -> f64 {
    let notes = task.notes.as_deref().unwrap_or("");
    let lower = notes.to_lowercase();

    // Base: current running surprisal EMA (reflects recent environment uncertainty).
    let ema = crate::surprise_tracker::current_surprisal_ema();

    // Additive signals from task notes.
    let unknown_markers = [
        "unclear",
        "unknown",
        "tbd",
        "to be determined",
        "assumption:",
        "[?]",
    ];
    let marker_penalty: f64 = unknown_markers
        .iter()
        .filter(|&&m| lower.contains(m))
        .count() as f64
        * 0.08;

    let missing_context = if task_contract::context(notes)
        .map(|s| s.trim().is_empty())
        .unwrap_or(true)
    {
        0.08
    } else {
        0.0
    };
    let missing_plan = if task_contract::plan(notes)
        .map(|s| s.trim().is_empty())
        .unwrap_or(true)
    {
        0.05
    } else {
        0.0
    };

    (ema + marker_penalty + missing_context + missing_plan).min(1.0)
}

/// COG-007: true if the task notes contain unresolved high-surprisal variable markers
/// that should hard-block execution until resolved.
fn has_unresolved_surprisal_variables(notes: &str) -> bool {
    let lower = notes.to_lowercase();
    // "[?]" is the canonical "unknown variable" marker; also plain TBD in the Context block.
    lower.contains("[?]")
        || lower.contains("tbd")
        || lower.contains("to be determined")
        || lower.contains("unknown:")
}

/// COG-007: spawn a probe subtask and block the parent on it.
/// Returns Ok(probe_id) if created, Err if task_db is unavailable.
fn spawn_probe_subtask(parent: &task_db::TaskRow) -> Result<i64> {
    let probe_title = format!(
        "Probe: verify assumptions for task #{}: {}",
        parent.id, parent.title
    );
    let notes = parent.notes.as_deref().unwrap_or("");
    let probe_notes = format!(
        "## Context\nProbe for parent task #{}: {}\n\n\
         ## Acceptance\n- [ ] All high-uncertainty assumptions verified or flagged.\n\n\
         ## Verify\n- [ ] Notes updated with verification results.\n\n\
         ## Plan\nInspect the parent task notes for unknowns/TBD items and verify \
         each assumption (e.g. check file paths exist, APIs return expected shapes, \
         env vars are set). Record findings as accepted or flagged. \
         estimated_cost: 0.05\n\n\
         ## Parent task notes\n{}\n",
        parent.id,
        parent.title,
        notes.chars().take(400).collect::<String>()
    );
    let probe_id = task_db::task_create(
        &probe_title,
        parent.repo.as_deref(),
        parent.issue_number,
        Some(parent.priority + 1),
        parent.assignee.as_deref(),
        Some(&probe_notes),
    )?;
    // Block parent on probe subtask.
    let _ = task_db::task_add_dependency(parent.id, probe_id);
    let block_note = format!(
        "blocked on probe subtask #{} (COG-007: high surprisal estimate)",
        probe_id
    );
    let _ = task_db::task_update_status(parent.id, "blocked", Some(&block_note));
    Ok(probe_id)
}

// ─────────────────────────────────────────────────────────────────────────────

/// AUTO-008: decompose a complex task into subtasks derived from its acceptance bullets.
/// Creates one child task per acceptance bullet, with the parent blocked pending them.
/// Returns Ok(true) if decomposition occurred, Ok(false) if task is simple enough.
fn auto_decompose_if_complex(task: &task_db::TaskRow) -> Result<bool> {
    if task_complexity_score(task) < decompose_threshold() {
        return Ok(false);
    }
    let notes = task.notes.as_deref().unwrap_or("");
    let acceptance_text = match crate::task_contract::acceptance(notes) {
        Some(s) => s,
        None => return Ok(false),
    };
    let bullets: Vec<String> = acceptance_text
        .lines()
        .filter_map(|l| {
            let t = l.trim();
            if t.starts_with('-') || t.starts_with('*') || t.starts_with('•') {
                let body = t.trim_start_matches(|c: char| !c.is_alphanumeric()).trim();
                if !body.is_empty() {
                    return Some(body.to_string());
                }
            }
            None
        })
        .collect();
    if bullets.len() < 3 {
        return Ok(false);
    }
    let assignee = task.assignee.as_deref().unwrap_or("chump");
    let repo = task.repo.as_deref();
    let mut child_ids = Vec::new();
    for (i, bullet) in bullets.iter().enumerate() {
        let child_title = format!(
            "[{}] subtask {}/{}: {}",
            task.title,
            i + 1,
            bullets.len(),
            bullet
        );
        let child_notes = format!(
            "## Context\nSubtask of task #{}: {}\n\n## Acceptance\n- {}\n\n## Verify\n- [ ] Command(s): true\n",
            task.id, task.title, bullet
        );
        let id = task_db::task_create(
            &child_title,
            repo,
            None,
            Some(task.priority),
            Some(assignee),
            Some(&child_notes),
        )?;
        child_ids.push(id);
    }
    // Set parent to blocked, depending on all children
    let child_ids_i64: Vec<i64> = child_ids.clone();
    // Update depends_on for parent task: set to JSON of child ids
    let deps_json = serde_json::to_string(&child_ids_i64)?;
    task_db::task_update_depends_on(task.id, &deps_json)?;
    task_db::task_update_status(
        task.id,
        "blocked",
        Some(&format!(
            "{}\n\n## Progress\n- [decomposed into {} subtasks: {:?}]\n",
            notes.trim(),
            child_ids.len(),
            child_ids
        )),
    )?;
    tracing::info!(
        task_id = task.id,
        subtasks = child_ids.len(),
        "auto_decompose: complex task decomposed into {} subtasks",
        child_ids.len()
    );
    Ok(true)
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

    // COG-008: restore belief state from previous run if available.
    if let Ok(Some(snap)) = crate::checkpoint_db::restore_latest_autonomy_checkpoint() {
        crate::belief_state::restore_from_snapshot(snap.tool_beliefs, snap.task_belief);
        crate::neuromodulation::restore(snap.neuromod);
        tracing::debug!("COG-008: restored autonomy snapshot from {}", snap.saved_at);
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

    // COG-009: begin FSM at Planning state; transitions enforce lifecycle order.
    // _-prefix suppresses unused-variable warnings on early-return paths.
    let _fsm = crate::autonomy_fsm::AutonomyState::<crate::autonomy_fsm::Planning>::new();

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

    // AUTO-008: auto-decompose complex tasks before executing them.
    if let Ok(true) = auto_decompose_if_complex(&task) {
        let _ = task_db::task_lease_release(task.id, &lease.token);
        return Ok(AutonomyOutcome {
            task_id: Some(task.id),
            status: "blocked".to_string(),
            detail: format!(
                "Task #{} was complex; auto-decomposed into subtasks.",
                task.id
            ),
        });
    }

    // COG-007: hard-block if the contract contains unresolved high-surprisal variables.
    if has_unresolved_surprisal_variables(&notes)
        && task_surprisal_estimate(&task) > probe_threshold()
    {
        let _ = task_db::task_update_status(task.id, "blocked", Some("COG-007: unresolved high-surprisal variables ([?]/TBD) block execution — resolve unknowns first."));
        let _ = task_db::task_lease_release(task.id, &lease.token);
        return Ok(AutonomyOutcome {
            task_id: Some(task.id),
            status: "blocked".to_string(),
            detail: "Execution hard-blocked: task contains unresolved high-surprisal variables. Remove [?]/TBD markers or lower surprisal before retrying.".to_string(),
        });
    }

    // COG-007: if surprisal estimate exceeds threshold, spawn a probe subtask instead of executing.
    if task_surprisal_estimate(&task) > probe_threshold() {
        match spawn_probe_subtask(&task) {
            Ok(probe_id) => {
                let _ = task_db::task_lease_release(task.id, &lease.token);
                return Ok(AutonomyOutcome {
                    task_id: Some(task.id),
                    status: "blocked".to_string(),
                    detail: format!(
                        "COG-007: high surprisal ({:.2}) — spawned probe subtask #{} instead of executing.",
                        task_surprisal_estimate(&task),
                        probe_id
                    ),
                });
            }
            Err(e) => {
                tracing::warn!(
                    "COG-007: probe subtask creation failed ({}); proceeding with execution.",
                    e
                );
            }
        }
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

    // COG-009: contract is valid; advance FSM to Executing.
    let _fsm = _fsm.begin_execution(crate::autonomy_fsm::PlanningComplete {
        task_id: task.id,
        has_acceptance: true,
        has_verify: true,
    });

    // AUTO-010: proactive escalation when operator has been denying frequently.
    if crate::hitl_escalation::maybe_escalate_proactive(&task.title, Some(task.id)) {
        let _ = task_db::task_lease_release(task.id, &lease.token);
        return Ok(AutonomyOutcome {
            task_id: Some(task.id),
            status: "awaiting_approval".to_string(),
            detail: "Task escalated for operator approval (low auto-approve rate).".to_string(),
        });
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

    // AUTO-009: fetch relevant memory snippets to surface known patterns and gotchas.
    let memory_context = fetch_task_memory_context(&task);
    let memory_block = if memory_context.is_empty() {
        String::new()
    } else {
        format!("\n\n{}", memory_context)
    };

    let exec_prompt = format!(
        "You are running an autonomy loop for task #{id}: {title}\n\n\
Context:\n{ctx}{memory_block}\n\n\
Plan:\n{plan}\n\n\
Acceptance (done looks like):\n{acceptance}\n\n\
Verify:\n{verify}\n\n\
Rules:\n\
- Do the work using tools as needed.\n\
- If the task is for a repo and requires repo context, ensure the correct repo is set (github_clone_or_pull + set_working_repo) before file/git/test tools.\n\
- Update the task notes Progress section with what you did and what remains (use task update notes).\n\
- Do not mark the task done yourself; the autonomy loop will verify and close.\n\
Reply with a short completion summary.",
        id = task.id,
        title = task.title,
        ctx = ctx.trim(),
        memory_block = memory_block,
        plan = plan.trim(),
        acceptance = acceptance.trim(),
        verify = verify.trim()
    );

    let exec_reply = exec.run(&exec_prompt).await;

    // AUTO-010: if executor reply indicates permission denied, escalate to operator.
    if crate::hitl_escalation::maybe_escalate_from_reply(&exec_reply, Some(task.id)) {
        let _ = task_db::task_lease_release(task.id, &lease.token);
        return Ok(AutonomyOutcome {
            task_id: Some(task.id),
            status: "awaiting_approval".to_string(),
            detail: "Task escalated for operator approval (permission denied during execution)."
                .to_string(),
        });
    }

    // COG-009: executor ran; advance FSM to Verifying.
    let _fsm = _fsm.begin_verification(crate::autonomy_fsm::ExecutionReceipt {
        task_id: task.id,
        summary: exec_reply.clone(),
    });

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

    // COG-009: verification complete; advance FSM to terminal state.
    {
        let outcome = crate::autonomy_fsm::VerificationOutcome {
            task_id: task.id,
            status: final_status.clone(),
            detail: final_detail.clone(),
        };
        if final_status == "done" {
            drop(_fsm.complete(outcome));
        } else {
            drop(_fsm.fail(outcome));
        }
    }

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

    // COG-008: persist belief state so next run can restore it.
    {
        let (tool_beliefs, task_belief) = crate::belief_state::snapshot_inner();
        let neuromod = crate::neuromodulation::levels();
        let surprisal_ema = crate::surprise_tracker::current_surprisal_ema();
        let saved_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs().to_string())
            .unwrap_or_default();
        let snap = crate::checkpoint_db::AutonomySnapshot {
            tool_beliefs,
            task_belief,
            neuromod,
            surprisal_ema,
            saved_at,
        };
        if let Err(e) = crate::checkpoint_db::save_autonomy_checkpoint(&snap) {
            tracing::warn!("COG-008: failed to save autonomy snapshot: {}", e);
        }
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

    fn make_task_row(id: i64, title: &str, notes: &str) -> task_db::TaskRow {
        task_db::TaskRow {
            id,
            title: title.to_string(),
            repo: None,
            issue_number: None,
            priority: 3,
            status: "open".to_string(),
            assignee: Some("chump".to_string()),
            notes: Some(notes.to_string()),
            depends_on: Some("[]".to_string()),
            created_at: None,
            updated_at: None,
            lease_owner: None,
            lease_token: None,
            lease_expires_at: None,
        }
    }

    #[test]
    fn task_complexity_score_simple_task_is_low() {
        let task = make_task_row(
            1,
            "Fix typo",
            "## Acceptance\n- [ ] done\n\n## Verify\n- [ ] cargo test\n",
        );
        assert!(
            task_complexity_score(&task) < 0.6,
            "simple task should be below decompose threshold"
        );
    }

    #[test]
    fn task_complexity_score_complex_task_is_high() {
        let long_notes = format!(
            "## Acceptance\n{}\n\n## Risks\nMay break things\n\n## Verify\n- [ ] cargo test\n",
            (0..8)
                .map(|i| format!("- [ ] Step {} and then do something or another\n", i))
                .collect::<String>()
        );
        let task = make_task_row(
            2,
            "Refactor auth and migrate sessions or rollback then verify",
            &long_notes,
        );
        assert!(
            task_complexity_score(&task) >= 0.6,
            "complex task should meet or exceed decompose threshold"
        );
    }

    #[test]
    #[serial]
    fn auto_decompose_creates_subtasks_and_blocks_parent() {
        let dir = std::env::temp_dir().join(format!(
            "chump_decompose_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        // Create a complex task with many acceptance bullets
        let notes = format!(
            "## Acceptance\n{}\n\n## Risks\nHigh\n\n## Verify\n- [ ] cargo test\n",
            (0..4)
                .map(|i| format!("- [ ] Acceptance step {}\n", i))
                .collect::<String>()
        );
        let id = task_db::task_create(
            "Complex parent task and also involves migration then rollback",
            None,
            None,
            Some(5),
            Some("chump"),
            Some(&notes),
        )
        .unwrap();

        // Force threshold low so decomposition fires
        std::env::set_var("CHUMP_TASK_DECOMPOSE_THRESHOLD", "0.0");
        let task = task_db::task_list_for_assignee("chump")
            .unwrap()
            .into_iter()
            .find(|t| t.id == id)
            .unwrap();
        let decomposed = auto_decompose_if_complex(&task).unwrap();
        std::env::remove_var("CHUMP_TASK_DECOMPOSE_THRESHOLD");

        assert!(decomposed, "should have decomposed");

        // Parent should be blocked
        let all_after = task_db::task_list(None).unwrap();
        let parent = all_after.iter().find(|t| t.id == id).unwrap();
        assert_eq!(parent.status, "blocked");

        // Children should exist
        let all = task_db::task_list_for_assignee("chump").unwrap();
        let children: Vec<_> = all.iter().filter(|t| t.id != id).collect();
        assert!(!children.is_empty(), "subtasks should have been created");

        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
    }

    // AUTO-010: HITL escalation integration test.
    struct PermissionDeniedExec;

    #[async_trait::async_trait]
    impl Executor for PermissionDeniedExec {
        async fn run(&self, _prompt: &str) -> String {
            "Error: permission denied when attempting to write /etc/shadow".to_string()
        }
    }

    #[tokio::test]
    #[serial]
    async fn hitl_escalation_on_permission_denied_sets_awaiting_approval() {
        let dir =
            std::env::temp_dir().join(format!("chump_hitl_test_{}", uuid::Uuid::new_v4().simple()));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();

        // Ensure approval rate is not below threshold (avoid proactive escalation).
        // By default with empty DB the rate is 0.0, which would trigger proactive escalation.
        // We set the env to disable the proactive path so only the permission-denied path fires.
        std::env::set_var("CHUMP_HITL_PROACTIVE_DISABLED", "1");

        let notes = task_contract::ensure_contract(
            Some("## Acceptance\n- [ ] written\n\n## Verify\n- [ ] cargo test\n"),
            "Write sensitive file",
            None,
        );
        let id = task_db::task_create(
            "Write sensitive file",
            None,
            None,
            Some(5),
            Some("chump"),
            Some(&notes),
        )
        .unwrap();

        let exec = PermissionDeniedExec;
        let verifier = FakeVerifier {
            outcome: ("done".to_string(), "ok".to_string(), "win"),
        };
        let out = autonomy_once_with("chump", &exec, &verifier).await.unwrap();
        assert_eq!(out.task_id, Some(id));
        assert_eq!(
            out.status, "awaiting_approval",
            "permission-denied reply should escalate task"
        );

        // Task should be in awaiting_approval status.
        let rows = task_db::task_list(None).unwrap();
        let task_row = rows.iter().find(|t| t.id == id);
        if let Some(t) = task_row {
            assert_eq!(t.status, "awaiting_approval");
        }

        std::env::remove_var("CHUMP_HITL_PROACTIVE_DISABLED");
        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
    }

    #[tokio::test]
    #[serial]
    async fn hitl_escalation_resume_from_checkpoint_after_approval() {
        // Simulate: task was previously escalated (awaiting_approval) and is now re-queued.
        // Autonomy loop should resume from checkpoint on next iteration.
        let dir = std::env::temp_dir().join(format!(
            "chump_hitl_resume_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();
        std::env::set_var("CHUMP_HITL_PROACTIVE_DISABLED", "1");

        let notes = task_contract::ensure_contract(
            Some("## Acceptance\n- [ ] done\n\n## Verify\n- [ ] cargo test\n"),
            "Resume after approval",
            None,
        );
        // Re-queue by creating task as open — autonomy will pick it up normally.
        let id = task_db::task_create(
            "Resume after approval",
            None,
            None,
            Some(5),
            Some("chump"),
            Some(&notes),
        )
        .unwrap();

        let exec = FakeExec;
        let verifier = FakeVerifier {
            outcome: (
                "done".to_string(),
                "Verified ok (resumed)".to_string(),
                "win",
            ),
        };
        let out = autonomy_once_with("chump", &exec, &verifier).await.unwrap();
        assert_eq!(out.task_id, Some(id));
        assert_eq!(out.status, "done", "resumed task should complete");

        std::env::remove_var("CHUMP_HITL_PROACTIVE_DISABLED");
        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
    }

    // COG-007 tests ───────────────────────────────────────────────────────────

    #[test]
    fn task_surprisal_estimate_clean_task_is_low() {
        let notes = task_contract::ensure_contract(
            Some("## Context\nClear context.\n\n## Plan\nClear plan.\n\n## Acceptance\n- [ ] ok\n\n## Verify\n- [ ] cargo test\n"),
            "Clean task",
            None,
        );
        let task = make_task_row(1, "Clean task", &notes);
        // EMA starts at 0.0 in test context; no markers in notes.
        let est = task_surprisal_estimate(&task);
        assert!(est < 0.5, "clean task surprisal should be low: {}", est);
    }

    #[test]
    fn task_surprisal_estimate_unknown_markers_raise_score() {
        let notes = "## Acceptance\n- [ ] ok\n\n## Verify\n- [ ] cargo test\n\
                     \nThe approach is tbd and [?] assumption: unclear";
        let task = make_task_row(2, "Uncertain task", notes);
        let est = task_surprisal_estimate(&task);
        // Should be higher than clean due to tbd, [?], assumption:, unclear markers.
        assert!(
            est > 0.2,
            "uncertain task surprisal should be elevated: {}",
            est
        );
    }

    #[test]
    fn probe_threshold_reads_env_var() {
        std::env::set_var("CHUMP_PROBE_THRESHOLD", "0.5");
        assert!((probe_threshold() - 0.5).abs() < 1e-6);
        std::env::remove_var("CHUMP_PROBE_THRESHOLD");
        assert!((probe_threshold() - 0.75).abs() < 1e-6);
    }

    #[test]
    fn has_unresolved_surprisal_variables_detects_markers() {
        assert!(has_unresolved_surprisal_variables("the value is [?] tbd"));
        assert!(has_unresolved_surprisal_variables("unknown: the key"));
        assert!(has_unresolved_surprisal_variables("to be determined later"));
        assert!(!has_unresolved_surprisal_variables("everything is clear"));
    }

    #[tokio::test]
    #[serial]
    async fn cog007_high_surprisal_spawns_probe_subtask() {
        let dir = std::env::temp_dir().join(format!(
            "chump_cog007_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();
        std::env::set_var("CHUMP_HITL_PROACTIVE_DISABLED", "1");

        // Lower probe threshold so our engineered task triggers it.
        std::env::set_var("CHUMP_PROBE_THRESHOLD", "0.01");

        // Task with high-uncertainty notes but NOT unresolved markers (avoids hard-block path).
        let notes = task_contract::ensure_contract(
            Some("## Acceptance\n- [ ] ok\n\n## Verify\n- [ ] cargo test\n"),
            "High surprisal task",
            None,
        );
        let id = task_db::task_create(
            "High surprisal task",
            None,
            None,
            Some(5),
            Some("chump"),
            Some(&notes),
        )
        .unwrap();

        let exec = FakeExec;
        let verifier = FakeVerifier {
            outcome: ("done".to_string(), "ok".to_string(), "win"),
        };
        let out = autonomy_once_with("chump", &exec, &verifier).await.unwrap();
        assert_eq!(out.task_id, Some(id));
        assert_eq!(
            out.status, "blocked",
            "high surprisal should block and spawn probe"
        );
        assert!(
            out.detail.contains("probe") || out.detail.contains("COG-007"),
            "detail should mention probe/COG-007: {}",
            out.detail
        );

        // Probe subtask should exist.
        let all = task_db::task_list(None).unwrap();
        let probe = all.iter().find(|t| t.title.contains("Probe:"));
        assert!(probe.is_some(), "probe subtask should have been created");

        std::env::remove_var("CHUMP_PROBE_THRESHOLD");
        std::env::remove_var("CHUMP_HITL_PROACTIVE_DISABLED");
        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
    }
}
