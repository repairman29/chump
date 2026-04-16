//! Tool registration via the `inventory` crate. Submissions below; the registry is built by
//! `register_from_inventory()`. Tools that need per-session context (e.g. MemoryTool with channel_id)
//! are registered manually in the build functions.

use axonerai::tool::Tool;
use axonerai::tool::ToolRegistry;

use crate::a2a_tool::{a2a_peer_configured, A2aTool};
use crate::ask_jeff_db;
use crate::ask_jeff_tool::AskJeffTool;
use crate::battle_qa_tool::BattleQaTool;
use crate::browser_tool::BrowserTool;
use crate::calc_tool::ChumpCalculator;
use crate::checkpoint_tool::CheckpointTool;
use crate::cli_tool::{CliTool, CliToolAlias};
use crate::codebase_digest_tool::{codebase_digest_enabled, CodebaseDigestTool};
use crate::decompose_task_tool::DecomposeTaskTool;
use crate::delegate_tool::DelegateTool;
use crate::diff_review_tool::DiffReviewTool;
use crate::ego_tool::EgoTool;
use crate::env_flags;
use crate::episode_db;
use crate::episode_tool::EpisodeTool;
use crate::fleet_tool::FleetTool;
use crate::git_tools::{
    git_tools_enabled, CleanupBranchesTool, GitCommitTool, GitPushTool, GitRevertTool,
    GitStashTool, MergeSubtaskTool,
};
use crate::introspect_tool::{introspect_available, IntrospectTool};
use crate::memory_brain_tool::MemoryBrainTool;
use crate::memory_graph_tool::MemoryGraphVizTool;
use crate::notify_tool::NotifyTool;
use crate::onboard_repo_tool::{onboard_repo_enabled, OnboardRepoTool};
use crate::read_url_tool::ReadUrlTool;
use crate::repo_allowlist_tool::{
    repo_allowlist_tools_enabled, RepoAuthorizeTool, RepoDeauthorizeTool,
};
use crate::repo_path;
use crate::repo_tools::{ListDirTool, PatchFileTool, ReadFileTool, WriteFileTool};
use crate::run_test_tool::RunTestTool;
use crate::sandbox_tool::{sandbox_enabled, SandboxTool};
use crate::schedule_db;
use crate::schedule_tool::ScheduleTool;
use crate::screen_vision_tool::{screen_vision_enabled, ScreenVisionTool};
use crate::session_search_tool::SessionSearchTool;
use crate::set_working_repo_tool::{set_working_repo_enabled, SetWorkingRepoTool};
use crate::skill_hub_tool::SkillHubTool;
use crate::skill_tool::SkillManageTool;
use crate::spawn_worker_tool::{spawn_workers_enabled, SpawnWorkerTool};
use crate::state_db;
use crate::task_db;
use crate::task_planner_tool::TaskPlannerTool;
use crate::task_tool::TaskTool;
use crate::tool_middleware;
use crate::toolkit_status_tool::ToolkitStatusTool;
use crate::wasm_calc_tool::{wasm_calc_available, WasmCalcTool};
use crate::wasm_text_tool::{wasm_text_available, WasmTextTool};

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

/// When air-gap mode is on, do not register general-Internet fetch/search tools (see HIGH_ASSURANCE §18).
#[inline]
fn outbound_web_tools_allowed() -> bool {
    !env_flags::chump_air_gap_mode()
}

/// Sort keys for spawn_worker: file ops, run_cli, run_test, git_commit, diff_review. No git_push, gh_*, set_working_repo, delegate, notify.
const WORKER_TOOL_KEYS: &[&str] = &[
    "read_file",
    "list_dir",
    "write_file",
    "patch_file",
    "run_test",
    "run_cli",
    "git",
    "cargo",
    "git_commit",
    "diff_review",
];

/// Register only worker-allowed tools (for spawn_worker). Ignores enabled() so worker always gets file tools when repo is set via set_working_repo.
pub fn register_worker_tools(registry: &mut ToolRegistry) {
    let mut entries: Vec<_> = inventory::iter::<ToolEntry>()
        .filter(|e| WORKER_TOOL_KEYS.contains(&e.sort_key))
        .collect();
    entries.sort_by(|a, b| a.sort_key.cmp(b.sort_key));
    for entry in entries {
        registry.register(tool_middleware::wrap_tool((entry.factory)()));
    }
}

/// Core tools for light interactive chat (`CHUMP_LIGHT_CONTEXT=1`).
/// Keeps prompt token count low for faster local inference (~10 tools vs ~40).
const LIGHT_CHAT_TOOL_KEYS: &[&str] = &[
    "ask_jeff",
    "calculator",
    "checkpoint",
    "episode",
    "list_dir",
    "memory_brain",
    "notify",
    "patch_file",
    "read_file",
    "run_cli",
    "schedule",
    "session_search",
    "skill_manage",
    "task",
    "task_planner",
    "write_file",
];

/// Register all inventory tools into `registry` (wrapped with middleware). Deterministic order by sort_key.
/// When `CHUMP_LIGHT_CONTEXT=1` and this is an interactive (non-heartbeat) turn, registers only
/// [`LIGHT_CHAT_TOOL_KEYS`] for faster local inference.
///
/// MCP-discovered tools take priority: if an MCP server provides a tool with the same sort_key,
/// the inline version is skipped and the MCP proxy is registered instead.
pub fn register_from_inventory(registry: &mut ToolRegistry) {
    let light = env_flags::light_interactive_active();

    // Collect MCP tool names so we can skip inline duplicates
    let mcp_tools = crate::mcp_bridge::all_mcp_tools();
    let mcp_names: std::collections::HashSet<&str> =
        mcp_tools.iter().map(|m| m.name.as_str()).collect();

    let mut entries: Vec<_> = inventory::iter::<ToolEntry>()
        .filter(|e| e.enabled())
        .filter(|e| !light || LIGHT_CHAT_TOOL_KEYS.contains(&e.sort_key))
        // Skip inline tools that have MCP replacements
        .filter(|e| !mcp_names.contains(e.sort_key))
        .collect();
    entries.sort_by(|a, b| a.sort_key.cmp(b.sort_key));
    for entry in entries {
        registry.register(tool_middleware::wrap_tool((entry.factory)()));
    }

    // Register MCP proxy tools (skip in light mode unless whitelisted)
    for meta in mcp_tools {
        if light && !LIGHT_CHAT_TOOL_KEYS.contains(&meta.name.as_str()) {
            continue;
        }
        let proxy = crate::mcp_bridge::McpProxyTool::new(meta);
        registry.register(tool_middleware::wrap_tool(Box::new(proxy)));
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
    ToolEntry::new(|| Box::new(WasmTextTool), "wasm_text").when_enabled(wasm_text_available)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(DelegateTool), "delegate").when_enabled(crate::delegate_tool::delegate_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(ReadUrlTool), "read_url").when_enabled(outbound_web_tools_allowed)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(ToolkitStatusTool), "toolkit_status")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(SandboxTool), "sandbox_run").when_enabled(sandbox_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(ScreenVisionTool), "screen_vision").when_enabled(screen_vision_enabled)
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
    ToolEntry::new(|| Box::new(PatchFileTool), "patch_file").when_enabled(repo_path::repo_root_is_explicit)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(BattleQaTool), "battle_qa").when_enabled(repo_path::repo_root_is_explicit)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(RunTestTool), "run_test").when_enabled(repo_path::repo_root_is_explicit)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(SetWorkingRepoTool), "set_working_repo").when_enabled(set_working_repo_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(OnboardRepoTool), "onboard_repo").when_enabled(onboard_repo_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(CodebaseDigestTool), "codebase_digest").when_enabled(codebase_digest_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(RepoAuthorizeTool), "repo_authorize").when_enabled(repo_allowlist_tools_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(RepoDeauthorizeTool), "repo_deauthorize").when_enabled(repo_allowlist_tools_enabled)
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
    ToolEntry::new(|| Box::new(TaskTool), "task").when_enabled(task_db::task_available)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(TaskPlannerTool), "task_planner").when_enabled(task_db::task_available)
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
    ToolEntry::new(|| Box::new(MemoryGraphVizTool), "memory_graph_viz")
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
inventory::submit! {
    ToolEntry::new(|| Box::new(IntrospectTool), "introspect").when_enabled(introspect_available)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(SpawnWorkerTool), "spawn_worker").when_enabled(spawn_workers_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(DecomposeTaskTool), "decompose_task").when_enabled(spawn_workers_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(MergeSubtaskTool), "merge_subtask").when_enabled(spawn_workers_enabled)
}
inventory::submit! {
    ToolEntry::new(|| Box::new(SessionSearchTool::new()), "session_search")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(SkillManageTool::new()), "skill_manage")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(SkillHubTool::new()), "skill_hub")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(FleetTool::new()), "fleet")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(CheckpointTool::new()), "checkpoint")
}
inventory::submit! {
    ToolEntry::new(|| Box::new(CleanupBranchesTool), "cleanup_branches").when_enabled(spawn_workers_enabled)
}
// Browser automation (V1 scaffold). Heavy by intent — NOT in LIGHT_CHAT_TOOL_KEYS.
// Recommended in CHUMP_TOOLS_ASK so each browser action requires approval.
inventory::submit! {
    ToolEntry::new(|| Box::new(BrowserTool), "browser")
}
