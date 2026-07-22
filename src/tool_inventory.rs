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
    git_tools_enabled, CleanupBranchesTool, GhPrListCommentsTool, GitCommitTool, GitPushTool,
    GitRevertTool, GitStashTool, MergeSubtaskTool,
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

/// Minimal tool set for free-tier dispatched agents (Groq, Cerebras, NVIDIA,
/// etc.). Non-Claude models get confused by 30+ tools and pick wrong ones
/// (observed: Llama 3.3 70B called `ask_jeff` instead of `read_file` with
/// the full tool inventory). 5 tools is the sweet spot: read → edit → commit.
///
/// Deliberately excludes `run_cli` and `run_test` — cold worktrees need a
/// full `cargo build` from scratch (3-5 min), which causes agent timeouts.
/// CI runs tests after the PR is opened instead.
///
/// EFFECTIVE-005: write_file removed — Llama 3.3 70B replaces entire files
/// with truncated/placeholder content. patch_file is safer: the model only
/// specifies the diff, not the full file. Use write_file only for new files
/// (which we don't need for most xs gaps).
const DISPATCH_FREE_TOOL_KEYS: &[&str] = &["read_file", "list_dir", "patch_file", "git_commit"];

/// INFRA-3407: opt-in write_file for stronger open models (MiniMax-M3 class).
/// EFFECTIVE-005's removal stays the default; `CHUMP_FREE_TIER_WRITE_FILE=1`
/// re-admits write_file WITH the >50%-shrink guard in repo_tools, so
/// truncated whole-file rewrites are refused instead of landed.
fn free_tier_write_file_enabled() -> bool {
    std::env::var("CHUMP_FREE_TIER_WRITE_FILE").as_deref() == Ok("1")
}

/// Register the slim free-tier dispatch tool set. Used by `execute_gap.rs`
/// when `OPENAI_MODEL` resolves to a non-Claude family (INFRA-733).
pub fn register_free_dispatch_tools(registry: &mut ToolRegistry) {
    let mut keys: Vec<&str> = DISPATCH_FREE_TOOL_KEYS.to_vec();
    if free_tier_write_file_enabled() {
        keys.push("write_file");
    }
    let mut entries: Vec<_> = inventory::iter::<ToolEntry>()
        .filter(|e| keys.contains(&e.sort_key))
        .collect();
    entries.sort_by(|a, b| a.sort_key.cmp(b.sort_key));
    for entry in entries {
        registry.register(tool_middleware::wrap_tool((entry.factory)()));
    }
}

/// Tool keys for `chump gen` (PRODUCT-050/051). Read ops for context exploration,
/// patch_file + run_cli for iterative code editing and cargo check loops.
/// Excludes git_commit — gen.rs owns the commit step after the agent finishes.
const GEN_TOOL_KEYS: &[&str] = &["list_dir", "patch_file", "read_file", "run_cli"];

/// Register the gen tool set. Does not check `enabled()` — set CHUMP_REPO
/// before `agent.run()` so read_file/list_dir resolve paths correctly.
pub fn register_gen_tools(registry: &mut ToolRegistry) {
    let mut entries: Vec<_> = inventory::iter::<ToolEntry>()
        .filter(|e| GEN_TOOL_KEYS.contains(&e.sort_key))
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

/// Ultra-slim tool set for PWA web chat on local models (qwen3:8b etc.).
///
/// PRODUCT-065: benchmarked on M4 with qwen3:8b via Ollama:
///   - 16 tools (LIGHT_CHAT_TOOL_KEYS): >120s, timeout
///   - 5 tools: 10.5s, correct tool call
///   - 1 tool: 3s
///
/// The sweet spot is 5-6 tools. Enough for interactive dev chat (read, write,
/// list, run commands, do math, persist learnings) without drowning the model
/// in schema tokens that cause infinite thinking loops.
///
/// Activate: `CHUMP_WEB_SLIM_TOOLS=1` or auto-detected when
/// `CHUMP_LIGHT_CONTEXT=1` + Ollama endpoint.
const WEB_SLIM_TOOL_KEYS: &[&str] = &[
    "calculator",
    "list_dir",
    "memory_brain",
    "read_file",
    "run_cli",
    "write_file",
];

/// True when web-slim tool profile should be used.
///
/// Explicit: `CHUMP_WEB_SLIM_TOOLS=1`
/// Auto: `CHUMP_LIGHT_CONTEXT=1` + Ollama endpoint detected
pub fn web_slim_active() -> bool {
    if let Ok(v) = std::env::var("CHUMP_WEB_SLIM_TOOLS") {
        let t = v.trim();
        return t == "1" || t.eq_ignore_ascii_case("true");
    }
    // Auto-detect: light context + local Ollama
    if env_flags::light_interactive_active() {
        let base = std::env::var("OPENAI_API_BASE").unwrap_or_default();
        if base.contains("11434") {
            return true;
        }
    }
    false
}

/// Tools the agent loop considers essential for self-improvement workflows.
/// Every name in this list MUST appear in [`LIGHT_CHAT_TOOL_KEYS`] — enforced
/// by `light_profile_includes_all_critical_tools` in the test module below.
///
/// Background: 2026-04-15 dogfood found that `patch_file` was missing from
/// the light profile, so qwen3:8b's correct unified diffs got rejected as
/// "Unknown tool" and the model retried 25 times before giving up. Adding a
/// new critical tool = add it here AND to LIGHT_CHAT_TOOL_KEYS, and the test
/// guarantees no future drift.
#[cfg(test)]
const LIGHT_PROFILE_CRITICAL_TOOLS: &[&str] = &[
    // Self-improvement loop: read → reason → patch → run tests → repeat.
    "read_file",
    "list_dir",
    "patch_file",
    "write_file",
    "run_cli",
    // State + memory minimum so the agent can persist what it learned.
    "task",
    "memory_brain",
    "episode",
];

/// Register all inventory tools into `registry` (wrapped with middleware). Deterministic order by sort_key.
///
/// Tool profile selection (most restrictive wins):
/// - `web_slim_active()` → [`WEB_SLIM_TOOL_KEYS`] (6 tools, for local models via PWA)
/// - `CHUMP_LIGHT_CONTEXT=1` → [`LIGHT_CHAT_TOOL_KEYS`] (16 tools, for capable local models)
/// - default → all enabled tools (~30-40)
///
/// MCP-discovered tools take priority: if an MCP server provides a tool with the same sort_key,
/// the inline version is skipped and the MCP proxy is registered instead.
pub fn register_from_inventory(registry: &mut ToolRegistry) {
    let web_slim = web_slim_active();
    let light = !web_slim && env_flags::light_interactive_active();

    // Pick the tool allowlist for this profile
    let allowlist: Option<&[&str]> = if web_slim {
        Some(WEB_SLIM_TOOL_KEYS)
    } else if light {
        Some(LIGHT_CHAT_TOOL_KEYS)
    } else {
        None
    };

    if web_slim {
        eprintln!(
            "[tool_inventory] PRODUCT-065: web-slim profile active ({} tools)",
            WEB_SLIM_TOOL_KEYS.len()
        );
    }

    // Collect MCP tool names so we can skip inline duplicates
    let mcp_tools = crate::mcp_bridge::all_mcp_tools();
    let mcp_names: std::collections::HashSet<&str> =
        mcp_tools.iter().map(|m| m.name.as_str()).collect();

    let mut entries: Vec<_> = inventory::iter::<ToolEntry>()
        .filter(|e| e.enabled())
        .filter(|e| allowlist.is_none_or(|keys| keys.contains(&e.sort_key)))
        // Skip inline tools that have MCP replacements
        .filter(|e| !mcp_names.contains(e.sort_key))
        .collect();
    entries.sort_by(|a, b| a.sort_key.cmp(b.sort_key));
    for entry in entries {
        registry.register(tool_middleware::wrap_tool((entry.factory)()));
    }

    // Register MCP proxy tools (skip in slim/light mode unless whitelisted)
    for meta in mcp_tools {
        if let Some(keys) = allowlist {
            if !keys.contains(&meta.name.as_str()) {
                continue;
            }
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
    // gh CLI must be installed + authenticated; we still gate on git_tools_enabled
    // so non-repo runs don't expose it. Read-only — no allowlist write needed.
    ToolEntry::new(|| Box::new(GhPrListCommentsTool), "gh_pr_list_comments").when_enabled(git_tools_enabled)
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
    // PRODUCT-004: only present during FTUE (profile not yet complete)
    ToolEntry::new(|| Box::new(crate::ftue_tool::CompleteOnboardingTool), "complete_onboarding")
        .when_enabled(|| !crate::ftue_tool::onboarding_complete())
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

#[cfg(test)]
mod tests {
    use super::{
        LIGHT_CHAT_TOOL_KEYS, LIGHT_PROFILE_CRITICAL_TOOLS, WEB_SLIM_TOOL_KEYS, WORKER_TOOL_KEYS,
    };

    /// Guard against the regression that hit qwen3:8b on 2026-04-15:
    /// `patch_file` was missing from `LIGHT_CHAT_TOOL_KEYS`, so the model's
    /// correct diffs got rejected as "Unknown tool" until the agent loop hit
    /// its 25-iteration cap. Anything in `LIGHT_PROFILE_CRITICAL_TOOLS` MUST
    /// also be in the light profile — adding a new critical tool requires
    /// updating both lists, and this test catches anyone who forgets one side.
    #[test]
    fn light_profile_includes_all_critical_tools() {
        for &critical in LIGHT_PROFILE_CRITICAL_TOOLS {
            assert!(
                LIGHT_CHAT_TOOL_KEYS.contains(&critical),
                "LIGHT_PROFILE_CRITICAL_TOOLS contains '{}' but it's missing from LIGHT_CHAT_TOOL_KEYS — \
                 the light interactive profile would silently drop it. Add '{}' to LIGHT_CHAT_TOOL_KEYS \
                 in src/tool_inventory.rs.",
                critical, critical
            );
        }
    }

    /// LIGHT_CHAT_TOOL_KEYS is sorted alphabetically by convention so diffs
    /// don't shuffle when adding tools and reviewers can quickly verify
    /// presence/absence. Pin this so a sloppy insert doesn't desort the list.
    #[test]
    fn light_chat_tool_keys_sorted_alphabetically() {
        let mut sorted = LIGHT_CHAT_TOOL_KEYS.to_vec();
        sorted.sort();
        assert_eq!(
            sorted, LIGHT_CHAT_TOOL_KEYS,
            "LIGHT_CHAT_TOOL_KEYS must stay sorted alphabetically; expected {:?}, got {:?}",
            sorted, LIGHT_CHAT_TOOL_KEYS
        );
    }

    /// Same convention for WORKER_TOOL_KEYS — but the existing list isn't
    /// strictly alphabetical (groups read/list/write together, then run, then
    /// git). Just assert no duplicates so a copy-paste error doesn't go
    /// unnoticed.
    #[test]
    fn worker_tool_keys_have_no_duplicates() {
        let mut seen = std::collections::HashSet::new();
        for &key in WORKER_TOOL_KEYS {
            assert!(
                seen.insert(key),
                "WORKER_TOOL_KEYS contains duplicate '{}'",
                key
            );
        }
    }

    /// LIGHT_CHAT_TOOL_KEYS no-duplicates guard.
    #[test]
    fn light_chat_tool_keys_have_no_duplicates() {
        let mut seen = std::collections::HashSet::new();
        for &key in LIGHT_CHAT_TOOL_KEYS {
            assert!(
                seen.insert(key),
                "LIGHT_CHAT_TOOL_KEYS contains duplicate '{}'",
                key
            );
        }
    }

    /// WEB_SLIM_TOOL_KEYS sorted alphabetically.
    #[test]
    fn web_slim_tool_keys_sorted_alphabetically() {
        let mut sorted = WEB_SLIM_TOOL_KEYS.to_vec();
        sorted.sort();
        assert_eq!(
            sorted, WEB_SLIM_TOOL_KEYS,
            "WEB_SLIM_TOOL_KEYS must stay sorted alphabetically"
        );
    }

    /// WEB_SLIM_TOOL_KEYS no-duplicates guard.
    #[test]
    fn web_slim_tool_keys_have_no_duplicates() {
        let mut seen = std::collections::HashSet::new();
        for &key in WEB_SLIM_TOOL_KEYS {
            assert!(
                seen.insert(key),
                "WEB_SLIM_TOOL_KEYS contains duplicate '{}'",
                key
            );
        }
    }

    /// WEB_SLIM_TOOL_KEYS is a subset of LIGHT_CHAT_TOOL_KEYS.
    /// This ensures any tool in web-slim is also available in the
    /// broader light profile (consistency across profile tiers).
    #[test]
    fn web_slim_is_subset_of_light_chat() {
        for &key in WEB_SLIM_TOOL_KEYS {
            assert!(
                LIGHT_CHAT_TOOL_KEYS.contains(&key),
                "WEB_SLIM_TOOL_KEYS contains '{}' which is missing from LIGHT_CHAT_TOOL_KEYS — \
                 web-slim must be a subset of light-chat",
                key
            );
        }
    }

    /// PRODUCT-065: web-slim must stay ≤ 6 tools. Benchmarked on M4/qwen3:8b:
    /// >6 tools causes 120s+ inference timeouts. This is a hard constraint.
    #[test]
    fn web_slim_max_tool_count() {
        assert!(
            WEB_SLIM_TOOL_KEYS.len() <= 6,
            "WEB_SLIM_TOOL_KEYS has {} tools but max is 6 (PRODUCT-065 benchmark: \
             >6 tools causes 120s+ inference on M4/qwen3:8b)",
            WEB_SLIM_TOOL_KEYS.len()
        );
    }
}
