//! Tool registration via the `inventory` crate. Submissions below; the registry is built by
//! `register_from_inventory()`. Tools that need per-session context (e.g. MemoryTool with channel_id)
//! are registered manually in the build functions.

use axonerai::tool::Tool;
use axonerai::tool::ToolRegistry;

use crate::a2a_tool::{a2a_peer_configured, A2aTool};
use crate::adb_tool::{adb_enabled, AdbTool};
use crate::ask_jeff_db;
use crate::ask_jeff_tool::AskJeffTool;
use crate::battle_qa_tool::BattleQaTool;
use crate::calc_tool::ChumpCalculator;
use crate::cli_tool::{CliTool, CliToolAlias};
use crate::delegate_tool::DelegateTool;
use crate::diff_review_tool::DiffReviewTool;
use crate::ego_tool::EgoTool;
use crate::episode_db;
use crate::episode_tool::EpisodeTool;
use crate::gh_tools::{
    gh_tools_enabled, GhCreateBranchTool, GhCreatePrTool, GhGetIssueTool, GhListIssuesTool,
    GhListMyPrsTool, GhPrChecksTool, GhPrCommentTool, GhPrViewCommentsTool,
};
use crate::git_tools::{git_tools_enabled, GitCommitTool, GitPushTool, GitRevertTool, GitStashTool};
use crate::github_tools::{
    github_enabled, GithubCloneOrPullTool, GithubRepoListTool, GithubRepoReadTool,
};
use crate::memory_brain_tool::MemoryBrainTool;
use crate::notify_tool::NotifyTool;
use crate::read_url_tool::ReadUrlTool;
use crate::repo_path;
use crate::repo_tools::{EditFileTool, ListDirTool, ReadFileTool, WriteFileTool};
use crate::run_test_tool::RunTestTool;
use crate::schedule_db;
use crate::schedule_tool::ScheduleTool;
use crate::state_db;
use crate::task_db;
use crate::task_tool::TaskTool;
use crate::tavily_tool::{tavily_enabled, TavilyTool};
use crate::tool_middleware;
use crate::toolkit_status_tool::ToolkitStatusTool;
use crate::wasm_calc_tool::{wasm_calc_available, WasmCalcTool};

/// One tool registration: factory to create the tool, optional env-based gating, and sort key for deterministic order.
pub struct ToolEntry {
    pub(crate) factory: fn() -> Box<dyn Tool>,
    pub(crate) is_enabled: Option<fn() -> bool>,
    pub(crate) sort_key: &'static str,
}

impl ToolEntry {
    /// Register a tool that is always enabled. `sort_key` is the tool name for stable registration order.
    pub const fn new(factory: fn() -> Box<dyn Tool>, sort_key: &'static str) -> Self {
        Self {
            factory,
            is_enabled: None,
            sort_key,
        }
    }

    /// Only register when `check()` returns true (e.g. env CHUMP_ADB_ENABLED).
    pub const fn when_enabled(mut self, check: fn() -> bool) -> Self {
        self.is_enabled = Some(check);
        self
    }

    /// True if this tool should be registered (no gating or gating check passed).
    pub fn enabled(&self) -> bool {
        self.is_enabled.map(|f| f()).unwrap_or(true)
    }
}

inventory::collect!(ToolEntry);

/// Register all inventory tools into `registry` (wrapped with middleware). Deterministic order by sort_key.
pub fn register_from_inventory(registry: &mut ToolRegistry) {
    let mut entries: Vec<_> = inventory::iter::<ToolEntry>()
        .filter(|e| e.enabled())
        .collect();
    entries.sort_by(|a, b| a.sort_key.cmp(b.sort_key));
    for entry in entries {
        registry.register(tool_middleware::wrap_tool((entry.factory)()));
    }
}

// --- Submissions: one per tool; optional .when_enabled(...) for gating ---

inventory::submit! {
    ToolEntry::new(|| Box::new(ChumpCalculator), "calculator")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(WasmCalcTool), "wasm_calc").when_enabled(wasm_calc_available)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(DelegateTool), "delegate").when_enabled(crate::delegate_tool::delegate_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(TavilyTool), "web_search").when_enabled(tavily_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(ReadUrlTool), "read_url")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(ToolkitStatusTool), "toolkit_status")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(AdbTool::from_env()), "adb").when_enabled(adb_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(CliTool::for_discord()), "run_cli")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(CliToolAlias { name: "git".to_string(), inner: CliTool::for_discord() }), "git")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(CliToolAlias { name: "cargo".to_string(), inner: CliTool::for_discord() }), "cargo")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(ReadFileTool), "read_file").when_enabled(repo_path::repo_root_is_explicit)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(ListDirTool), "list_dir").when_enabled(repo_path::repo_root_is_explicit)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(WriteFileTool), "write_file").when_enabled(repo_path::repo_root_is_explicit)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(EditFileTool), "edit_file").when_enabled(repo_path::repo_root_is_explicit)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(BattleQaTool), "battle_qa").when_enabled(repo_path::repo_root_is_explicit)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(RunTestTool), "run_test").when_enabled(repo_path::repo_root_is_explicit)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GithubRepoReadTool), "github_repo_read").when_enabled(github_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GithubRepoListTool), "github_repo_list").when_enabled(github_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GithubCloneOrPullTool), "github_clone_or_pull").when_enabled(github_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GitCommitTool), "git_commit").when_enabled(git_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GitPushTool), "git_push").when_enabled(git_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GitStashTool), "git_stash").when_enabled(git_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GitRevertTool), "git_revert").when_enabled(git_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GhListIssuesTool), "gh_list_issues").when_enabled(gh_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GhGetIssueTool), "gh_get_issue").when_enabled(gh_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GhListMyPrsTool), "gh_list_my_prs").when_enabled(gh_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GhCreateBranchTool), "gh_create_branch").when_enabled(gh_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GhCreatePrTool), "gh_create_pr").when_enabled(gh_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GhPrChecksTool), "gh_pr_checks").when_enabled(gh_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GhPrCommentTool), "gh_pr_comment").when_enabled(gh_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(GhPrViewCommentsTool), "gh_pr_view_comments").when_enabled(gh_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(TaskTool), "task").when_enabled(task_db::task_available)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(NotifyTool), "notify")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(A2aTool), "message_peer").when_enabled(a2a_peer_configured)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(EgoTool), "ego").when_enabled(state_db::state_available)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(EpisodeTool), "episode").when_enabled(episode_db::episode_available)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(MemoryBrainTool), "memory_brain")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(ScheduleTool), "schedule").when_enabled(schedule_db::schedule_available)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(AskJeffTool), "ask_jeff").when_enabled(ask_jeff_db::ask_jeff_available)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(DiffReviewTool), "diff_review").when_enabled(repo_path::repo_root_is_explicit)
}
