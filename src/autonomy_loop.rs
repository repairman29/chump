//! Autonomy loop: pick a task, execute, verify, and update state deterministically.
//!
//! Design goal: maximize real-world success by keeping the loop:
//! - single-task-per-run (cron/supervisor friendly)
//! - deterministic (task notes contract, explicit verification)
//! - safe by default (respects existing tool approval gates)

use anyhow::{anyhow, Result};

use axonerai::tool::Tool;
use crate::discord;
use crate::episode_db;
use crate::github_tools;
use crate::repo_path;
use crate::run_test_tool;
use crate::set_working_repo_tool;
use crate::task_contract;
use crate::task_db;

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
                .trim_end_matches(|c: char| c == ')' || c == ',' || c == '.')
                .trim();
            if candidate.starts_with('/') && candidate.len() > 1 {
                return Some(candidate.to_string());
            }
        }
    }
    None
}

async fn ensure_repo_context(task: &task_db::TaskRow) -> Result<Option<String>> {
    let repo = task.repo.as_deref().map(|s| s.trim()).filter(|s| !s.is_empty());
    let Some(repo) = repo else {
        return Ok(None);
    };

    if !github_tools::github_enabled() {
        return Err(anyhow!(
            "Task has repo={} but GitHub tools are disabled (requires GITHUB_TOKEN and CHUMP_GITHUB_REPOS allowlist).",
            repo
        ));
    }
    if !set_working_repo_tool::set_working_repo_enabled() {
        return Err(anyhow!(
            "Task has repo={} but set_working_repo is disabled (requires CHUMP_MULTI_REPO_ENABLED=1 and CHUMP_REPO or CHUMP_HOME).",
            repo
        ));
    }

    let clone_tool = github_tools::GithubCloneOrPullTool;
    let msg = clone_tool
        .execute(serde_json::json!({ "repo": repo }))
        .await
        .map_err(|e| anyhow!("github_clone_or_pull failed: {}", e))?;
    let local_path =
        extract_local_repo_path_from_clone_pull_output(&msg).ok_or_else(|| {
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
            passed = v.trim_end_matches(|c: char| !c.is_ascii_digit())
                .parse::<u32>()
                .ok();
        } else if let Some(v) = part.strip_prefix("failed=") {
            failed = v.trim_end_matches(|c: char| !c.is_ascii_digit())
                .parse::<u32>()
                .ok();
        } else if let Some(v) = part.strip_prefix("ignored=") {
            ignored = v.trim_end_matches(|c: char| !c.is_ascii_digit())
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
    // Heuristic, deterministic extraction for common patterns:
    // - "- [ ] Command(s): <cmd>"
    // - "Command(s): <cmd>"
    // - fenced code blocks under Verify section
    let mut out: Vec<String> = Vec::new();
    let mut in_fence = false;
    for line in verify_section.lines() {
        let t = line.trim();
        if t.starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            let cmd = t.trim_start_matches('$').trim();
            if !cmd.is_empty() {
                out.push(cmd.to_string());
            }
            continue;
        }
        let t = t
            .trim_start_matches("- [ ]")
            .trim_start_matches('-')
            .trim();
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
            for cmd in cmds.into_iter().take(3) {
                let wrapped = wrap_with_exit_code(&cmd);
                match cli.execute(serde_json::json!({ "command": wrapped })).await {
                    Ok(out) => {
                        match parse_exit_code(&out).unwrap_or(1) {
                            0 => {
                                return (
                                    "done".to_string(),
                                    format!("Verified ok via command: {}", cmd),
                                    "win",
                                );
                            }
                            code => {
                                return (
                                    "blocked".to_string(),
                                    format!(
                                        "Verification command failed (exit {}). Command: {}\n\nOutput:\n{}",
                                        code,
                                        cmd,
                                        out.trim()
                                    ),
                                    "frustrating",
                                );
                            }
                        }
                    }
                    Err(e) => {
                        return (
                            "blocked".to_string(),
                            format!("Verification command could not run: {} ({})", cmd, e),
                            "uncertain",
                        );
                    }
                }
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
pub async fn autonomy_once(assignee: &str) -> Result<AutonomyOutcome> {
    let exec = RealExecutor;
    let verifier = RealVerifier;
    autonomy_once_impl(assignee, &exec, &verifier).await
}

async fn autonomy_once_impl(
    assignee: &str,
    exec: &dyn Executor,
    verifier: &dyn Verifier,
) -> Result<AutonomyOutcome> {
    if !task_db::task_available() {
        return Err(anyhow!("task DB not available"));
    }

    let assignee = assignee.trim();
    let assignee = if assignee.is_empty() { "chump" } else { assignee };

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
    if task.repo.as_deref().map(|s| !s.trim().is_empty()).unwrap_or(false) {
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

    let exec_prompt = format!(
        "You are running an autonomy loop for task #{id}: {title}\n\n\
Context:\n{ctx}\n\n\
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
        plan = plan.trim(),
        acceptance = acceptance.trim(),
        verify = verify.trim()
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

    notes_now = append_progress(&notes_now, &format!("executor_summary: {}", exec_reply.trim()));
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

    if episode_db::episode_available() {
        let _ = episode_db::episode_log(
            &format!("Autonomy {} task #{}", final_status, task.id),
            Some(&final_detail),
            Some("autonomy,task"),
            task.repo.as_deref(),
            Some(sentiment),
            None,
            task.issue_number,
        );
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
        let id = task_db::task_create("T", None, None, Some(5), Some("chump"), Some(&notes)).unwrap();

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
        let id = task_db::task_create("T", Some("owner/repo"), None, Some(5), Some("chump"), Some(&notes))
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
}
