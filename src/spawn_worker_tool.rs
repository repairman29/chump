//! spawn_worker: run a tooled agent (restricted tools, branch, scoped repo) to completion.
//! Gate: CHUMP_SPAWN_WORKERS_ENABLED=1. Concurrency: CHUMP_SPAWN_MAX_PARALLEL (default 3).

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::agent::Agent;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::tool::ToolRegistry;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::Semaphore;

use crate::provider_cascade;
use crate::repo_path;
use crate::tool_inventory;

pub fn spawn_workers_enabled() -> bool {
    std::env::var("CHUMP_SPAWN_WORKERS_ENABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn max_parallel() -> usize {
    std::env::var("CHUMP_SPAWN_MAX_PARALLEL")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|&n| (1..=16).contains(&n))
        .unwrap_or(3)
}

static SPAWN_SEMAPHORE: std::sync::OnceLock<Arc<Semaphore>> = std::sync::OnceLock::new();
fn spawn_semaphore() -> &'static Arc<Semaphore> {
    SPAWN_SEMAPHORE.get_or_init(|| Arc::new(Semaphore::new(max_parallel())))
}

fn worker_system_prompt(branch: &str, task: &str) -> String {
    format!(
        "You are working on a subtask. Branch: {}. Do exactly this: {}. Run tests before reporting success. When done, reply with a brief summary of what you did.",
        branch, task
    )
}

async fn run_git(repo_dir: &PathBuf, args: &[&str]) -> Result<(bool, String)> {
    let out = Command::new("git")
        .args(args)
        .current_dir(repo_dir)
        .output()
        .await
        .map_err(|e| anyhow!("git failed: {}", e))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let combined = if stderr.is_empty() {
        stdout
    } else if stdout.is_empty() {
        stderr
    } else {
        format!("{}\n{}", stdout, stderr)
    };
    Ok((out.status.success(), combined))
}

pub struct SpawnWorkerTool;

#[async_trait]
impl axonerai::tool::Tool for SpawnWorkerTool {
    fn name(&self) -> String {
        "spawn_worker".to_string()
    }

    fn description(&self) -> String {
        "Run a tooled worker on a branch in a repo. Params: task (description), branch (e.g. chump/task-1-subtask-1), working_dir (repo root path), optional max_iterations (default 15), optional base_ref (for files_changed diff, default main). Worker has read_file, list_dir, write_file, edit_file, run_test, run_cli, git_commit, diff_review only. Returns { success, files_changed, test_results?, summary }.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "task": { "type": "string", "description": "Subtask description" },
                "branch": { "type": "string", "description": "Branch name (create if missing)" },
                "working_dir": { "type": "string", "description": "Repo root path (absolute or under CHUMP_HOME)" },
                "max_iterations": { "type": "number", "description": "Max agent iterations (default 15)" },
                "base_ref": { "type": "string", "description": "Base ref for files_changed diff (default main)" }
            },
            "required": ["task", "branch", "working_dir"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }
        let task = input
            .get("task")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing task"))?
            .trim()
            .to_string();
        let branch = input
            .get("branch")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing branch"))?
            .trim()
            .to_string();
        let working_dir_str = input
            .get("working_dir")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("missing working_dir"))?
            .trim();
        let _max_iterations = input
            .get("max_iterations")
            .and_then(|v| v.as_u64())
            .unwrap_or(15) as usize;
        let base_ref = input
            .get("base_ref")
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("main")
            .to_string();

        let working_dir: PathBuf = if PathBuf::from(working_dir_str).is_absolute() {
            PathBuf::from(working_dir_str)
        } else {
            repo_path::runtime_base().join(working_dir_str.trim_start_matches('/'))
        };
        let working_dir = working_dir
            .canonicalize()
            .map_err(|e| anyhow!("working_dir not found: {}", e))?;
        if !working_dir.join(".git").exists() {
            return Err(anyhow!("working_dir is not a git repo (no .git)"));
        }

        let _permit = spawn_semaphore()
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| anyhow!("spawn_worker semaphore closed"))?;

        repo_path::set_working_repo(working_dir.clone()).map_err(|e| anyhow!("{}", e))?;

        let result = async {
            let (ok_checkout, out_checkout) =
                run_git(&working_dir, &["checkout", "-b", &branch]).await?;
            if !ok_checkout {
                let (ok2, out2) = run_git(&working_dir, &["checkout", &branch]).await?;
                if !ok2 {
                    return Err(anyhow!(
                        "git checkout branch failed: {}; checkout -b: {}",
                        out2,
                        out_checkout
                    ));
                }
            }

            let provider = provider_cascade::build_provider();
            let mut registry = ToolRegistry::new();
            tool_inventory::register_worker_tools(&mut registry);

            let system_prompt =
                worker_system_prompt(&branch, &task);
            let session_dir = repo_path::runtime_base()
                .join("sessions")
                .join("worker")
                .join(format!("{:x}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()));
            let _ = std::fs::create_dir_all(&session_dir);
            let session_manager =
                FileSessionManager::new("worker".to_string(), session_dir).map_err(|e| anyhow!("session manager: {}", e))?;

            let agent = Agent::new(
                provider,
                registry,
                Some(system_prompt),
                Some(session_manager),
            );
            let reply = agent.run(&task).await.map_err(|e| anyhow!("agent run: {}", e))?;

            let hit_max = reply.contains("max iterations");
            let success = !hit_max;

            let (_, files_out) = run_git(&working_dir, &["diff", "--name-only", &format!("{}..HEAD", base_ref)]).await?;
            let files_changed: Vec<String> = files_out
                .lines()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(String::from)
                .collect();

            let test_out = Command::new("cargo")
                .args(["test"])
                .current_dir(&working_dir)
                .output()
                .await;
            let test_results = match test_out {
                Ok(o) => {
                    String::from_utf8_lossy(&o.stdout).into_owned()
                        + &String::from_utf8_lossy(&o.stderr).into_owned()
                }
                Err(_) => "cargo test not run".to_string(),
            };

            Ok::<_, anyhow::Error>((
                success,
                files_changed,
                test_results,
                reply.trim().to_string(),
            ))
        }
        .await;

        repo_path::clear_working_repo();

        let (success, files_changed, test_results, summary) = result?;

        let out = json!({
            "success": success,
            "files_changed": files_changed,
            "test_results": test_results,
            "summary": summary
        });
        Ok(out.to_string())
    }
}
