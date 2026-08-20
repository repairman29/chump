//! Minimal AxonerAI agent that talks to an OpenAI-compatible endpoint (e.g. Ollama on localhost).
//! Set OPENAI_API_BASE (e.g. http://localhost:11434/v1) to use a local server; default is Ollama.
//! Run with no args for interactive chat; pass a message for single-shot; --discord to run Discord bot (DISCORD_TOKEN required).

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod a2a_tool;
mod acp;
mod acp_server;
mod activation;
mod adversary;
mod adversary_llm;
mod agent_factory;
mod agent_lease;
pub mod agent_loop;
mod agent_session;
mod agent_turn;
// EFFECTIVE-023: ambient_emit/rotate/stream live in crates/ambient-cli/ now.
// Re-exported at the crate root so existing `crate::ambient_emit::*` callers
// (18+ across the binary) keep working without churn.
pub use chump_ambient_cli::{ambient_emit, ambient_rotate, ambient_stream};
// EFFECTIVE-394: verify cluster extracted to crates/chump-verify; re-export so existing crate::pr_ac_coverage / crate::external_verify_merge / crate::confidence references keep resolving unchanged.
pub use chump_verify::{confidence, external_verify_merge, pr_ac_coverage};
mod almanac_tool;
mod approval_resolver;
mod asi_telemetry;
mod ask_jeff_db;
mod ask_jeff_tool;
mod assertion;
// EFFECTIVE-399: atomic_claim + its autonomy_level leaf dep extracted into
// crates/chump-atomic-claim for build speed. Re-exported at crate root so every
// existing `crate::atomic_claim::X` / `crate::autonomy_level::X` (and bare
// `atomic_claim::X`) reference across the bin resolves with zero caller edits.
pub use chump_atomic_claim::{atomic_claim, autonomy_level};
mod auth;
mod autonomy_fsm;
mod autonomy_loop;
mod autopilot;
mod battle_qa_tool;
mod belief_state;
mod blackboard;
mod blocker_detect;
mod briefing;
mod browser;
mod browser_tool;
mod calc_tool;
mod cancel_registry;
mod cascade_stats;
mod checkpoint_db;
mod checkpoint_tool;
mod chump_init;
mod chump_log;
mod ci_lesson;
mod ci_summary;
mod cli_tool;
mod cluster_mesh;
mod codebase_digest_tool;
mod comprehend_tool;
mod config_validation;
mod consciousness_traits;
mod content_bots;
mod context_assembly;
mod context_engine;
mod context_firewall;
mod context_window;
mod cost_ledger;
mod cost_tracker;
mod cost_watch;
mod counterfactual;
mod curator_bell;
mod dashboard;
mod sourcing_resolver; // INFRA-3508 (COTG-S.1): repo -> arsenal -> world prior-art resolver
pub use chump_db_pool::db_pool;
mod decompose_task_tool;
mod delegate_tool;
mod desktop_launcher;
mod diff_review_tool;
#[cfg(feature = "discord")]
mod discord;
mod discord_dm;
mod discord_intent;
mod disk_plan_gate; // INFRA-2198: disk-aware gate for fleet up + auto-scale (META-128/C7)
mod dispatch;
mod doctor;
mod ego_tool;
mod env_flags;
mod episode_db;
mod episode_extractor;
mod episode_tool;
pub use chump_eval_harness::eval_harness;
mod execute_gap;
mod failure_catalog;
mod farmer_status; // RESILIENT-069: farmer readiness gate (lights-on check)
mod file_watch;
mod fleet;
mod fleet_capability;
mod fleet_db;
mod fleet_fanout; // INFRA-1484: cross-repo fan-out (Marcus M-B continuation)
mod fleet_health;
mod fleet_mode;
mod fleet_pulse; // INFRA-1995: THE FLOOR Phase 2 — single-pane fleet status
mod fleet_resize;
mod fleet_self_doctor;
mod fleet_self_rescue_conductor; // EFFECTIVE-088: self-rescue conductor (the empty chair)
mod fleet_spec; // INFRA-1483: declarative chump.fleet.yaml (Marcus M-B)
mod fleet_status;
mod fleet_tool;
mod fleet_velocity;
mod floor_temp; // INFRA-1992: THE FLOOR Phase 1 — floor-temperature signal
mod ftue_tool;
mod rebase_queue; // INFRA-2225: fleet rebase-queue — auto-rebase daemon backlog surface
                  // INFRA-693: gap_store moved to its own crate (crates/chump-gap-store/).
                  // The rename keeps every `gap_store::*` call site compiling unchanged.
use chump_gap_store as gap_store;
// INFRA-1229: explicit linkage declaration so Cargo always links chump-ship
// even when the CI rust-cache restores a stale build (fixes E0433 on Ubuntu).
extern crate chump_ship;
mod audit;
mod audit_log; // INFRA-1842: queryable