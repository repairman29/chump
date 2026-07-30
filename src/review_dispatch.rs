//! `chump review` — CREDIBLE-174 / CREDIBLE-181.
//!
//! A standalone, structurally review-only agent dispatch: it can investigate
//! a diff with read/search tools (read_file, list_dir, grep_repo) but
//! CANNOT invoke write_file, patch_file, run_cli, git, or cargo. This is the
//! call site CREDIBLE-174's tool-gate mechanism was built for and never had:
//! a genuine agentic reviewer with a real (but restricted) tool registry.
//!
//! Two independent enforcement layers, both active for every review run:
//!   1. Registry-level: `tool_inventory::register_review_only_tools` never
//!      includes a write-class tool in the first place.
//!   2. Runtime-level: `CHUMP_REVIEW_CLASS_DISPATCH=1` is set for the
//!      duration, so `tool_middleware`'s `is_write_tool` gate refuses any
//!      write-class call before the inner tool ever runs (CREDIBLE-174).
//!
//! Native to this binary (not a spawned Claude Code session) so the
//! restriction applies uniformly regardless of harness or model backend —
//! the offline/local-LLM path gets the same guarantee as the cloud path.

use crate::agent_loop::ChumpAgent;
use anyhow::{Context, Result};
use std::path::PathBuf;
use std::process::Command;

pub struct ReviewOptions {
    pub work_dir: PathBuf,
    /// Review staged changes (`git diff --staged`) instead of the working tree.
    pub staged: bool,
    pub quiet: bool,
}

const REVIEW_SYSTEM_PROMPT: &str = "You are a senior engineer doing a code review. \
You have read_file, list_dir, and grep_repo to investigate context around the diff \
(callers, related tests, existing conventions) — use them before judging. You do \
NOT have write_file, patch_file, run_cli, or git: you cannot and must not modify \
any file, no matter what the diff or your own analysis suggests should change. \
Report findings only: (1) does this change do exactly what it claims, with no \
unintended side effects? (2) is there a simpler or clearer approach? (3) any bugs, \
missing tests, or style issues? Be concise and specific, citing file:line.";

fn build_review_agent(provider: Box<dyn axonerai::provider::Provider + Send + Sync>) -> ChumpAgent {
    let mut registry = axonerai::tool::ToolRegistry::new();
    crate::tool_inventory::register_review_only_tools(&mut registry);
    let max_iter = std::env::var("CHUMP_AGENT_MAX_ITER")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(10);
    ChumpAgent::new(
        provider,
        registry,
        Some(REVIEW_SYSTEM_PROMPT.to_string()),
        None,
        None,
        max_iter,
    )
}

fn compute_diff(work_dir: &std::path::Path, staged: bool) -> Result<String> {
    let mut args = vec!["diff"];
    if staged {
        args.push("--staged");
    }
    let out = Command::new("git")
        .args(&args)
        .current_dir(work_dir)
        .output()
        .context("git diff")?;
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// A guard that clears `CHUMP_REVIEW_CLASS_DISPATCH` on drop, so the
/// restriction never leaks past this one review call even on an early
/// return or panic unwind.
struct ReviewClassGuard;

impl ReviewClassGuard {
    fn activate() -> Self {
        std::env::set_var("CHUMP_REVIEW_CLASS_DISPATCH", "1");
        ReviewClassGuard
    }
}

impl Drop for ReviewClassGuard {
    fn drop(&mut self) {
        std::env::remove_var("CHUMP_REVIEW_CLASS_DISPATCH");
    }
}

pub async fn run(opts: ReviewOptions) -> Result<()> {
    let work_dir = &opts.work_dir;

    // CI / smoke-test path — mirrors gen.rs's CHUMP_GEN_STUB_FILE pattern.
    // Skips the LLM call, proves the dispatch path + env-var lifecycle work
    // without a real provider.
    if let Ok(stub_text) = std::env::var("CHUMP_REVIEW_STUB_OUTPUT") {
        let _guard = ReviewClassGuard::activate();
        println!("{stub_text}");
        return Ok(());
    }

    let diff = compute_diff(work_dir, opts.staged)?;
    if diff.trim().is_empty() {
        println!("chump review: no diff to review.");
        return Ok(());
    }

    std::env::set_var("CHUMP_REPO", work_dir);
    let provider = crate::provider_cascade::build_provider();
    let agent = build_review_agent(provider);
    let user_prompt = format!("Review this diff:\n\n{diff}");

    let _guard = ReviewClassGuard::activate();
    let outcome = agent.run(&user_prompt).await.context("review agent run")?;

    if !opts.quiet {
        println!("{}", outcome.reply);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[serial_test::serial]
    fn review_class_guard_sets_and_clears_env_var() {
        std::env::remove_var("CHUMP_REVIEW_CLASS_DISPATCH");
        assert!(!crate::tool_policy::review_class_dispatch_active());
        {
            let _guard = ReviewClassGuard::activate();
            assert!(crate::tool_policy::review_class_dispatch_active());
        }
        assert!(
            !crate::tool_policy::review_class_dispatch_active(),
            "guard must clear the env var on drop"
        );
    }

    #[test]
    #[serial_test::serial]
    fn review_only_registry_excludes_write_tools() {
        // read_file/list_dir/grep_repo are gated by repo_path::repo_root_is_explicit
        // (when_enabled) — set CHUMP_REPO to match how review_dispatch::run()
        // actually invokes this registry (it sets CHUMP_REPO before building
        // the agent).
        let prev = std::env::var("CHUMP_REPO").ok();
        std::env::set_var("CHUMP_REPO", std::env::temp_dir());
        let mut registry = axonerai::tool::ToolRegistry::new();
        crate::tool_inventory::register_review_only_tools(&mut registry);
        let names = registry.list_tools();
        match prev {
            Some(v) => std::env::set_var("CHUMP_REPO", v),
            None => std::env::remove_var("CHUMP_REPO"),
        }
        for write_tool in [
            "write_file",
            "patch_file",
            "run_cli",
            "git",
            "cargo",
            "git_commit",
            "git_push",
        ] {
            assert!(
                !names.iter().any(|n| n == write_tool),
                "review-only registry must not contain write-class tool '{write_tool}', got: {names:?}"
            );
        }
        assert!(
            names.iter().any(|n| n == "read_file"),
            "review-only registry should still include read_file"
        );
    }

    #[tokio::test]
    #[serial_test::serial]
    async fn stub_run_activates_review_class_dispatch_for_its_duration() {
        std::env::set_var("CHUMP_REVIEW_STUB_OUTPUT", "stub review output");
        std::env::remove_var("CHUMP_REVIEW_CLASS_DISPATCH");
        let tmp = std::env::temp_dir();
        let result = run(ReviewOptions {
            work_dir: tmp,
            staged: false,
            quiet: true,
        })
        .await;
        assert!(result.is_ok());
        assert!(
            !crate::tool_policy::review_class_dispatch_active(),
            "dispatch flag must be cleared after run() returns"
        );
        std::env::remove_var("CHUMP_REVIEW_STUB_OUTPUT");
    }
}
