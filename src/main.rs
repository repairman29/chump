//! Minimal AxonerAI agent that talks to an OpenAI-compatible endpoint (e.g. Ollama on localhost).
//! Set OPENAI_API_BASE (e.g. http://localhost:11434/v1) to use a local server; default is Ollama.
//! Run with no args for interactive chat; pass a message for single-shot; --discord to run Discord bot (DISCORD_TOKEN required).

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod a2a_tool;
mod acp;
mod acp_server;
mod activation;
mod admission_check; // RESILIENT-1426: admission check against concurrency ceiling
mod admit; // INFRA-8219: `chump admit <claude|cargo>` — node-wide admission ceiling (ports RESILIENT-1604)
mod adversary;
mod adversary_llm;
mod agent_factory;
mod agent_lease;
pub mod agent_loop;
mod agent_session;
mod agent_turn;
mod scaffold_holes;
mod service_cmd;
// EFFECTIVE-023: ambient_emit/rotate/stream live in crates/ambient-cli/ now.
// Re-exported at the crate root so existing `crate::ambient_emit::*` callers
// (18+ across the binary) keep working without churn.
pub use chump_ambient_cli::{ambient_emit, ambient_rotate, ambient_stream};
// EFFECTIVE-394: verify cluster extracted to crates/chump-verify; re-export so existing crate::pr_ac_coverage / crate::external_verify_merge / crate::confidence references keep resolving unchanged.
pub use chump_verify::{confidence, external_verify_merge, organ_muster, pr_ac_coverage};
mod almanac_tool;
mod approval_resolver;
mod asi_telemetry;
mod ask_jeff_db;
mod ask_jeff_tool;
mod assertion;
mod organ_cmd; // RESILIENT-1692: `chump organ pause|resume <unit>`
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
// INFRA-7938 (INFRA-1965 slice): calc_tool now lives in the lib crate
// (src/lib.rs); re-exported here so existing `crate::calc_tool::X` call
// sites in this binary keep resolving unchanged.
pub use chump::calc_tool;
// INFRA-4667 (INFRA-1687 slice): subcommand_registry lives in the lib crate
// (src/lib.rs); re-exported here so existing `crate::subcommand_registry::X`
// call sites in this binary keep resolving unchanged.
pub use chump::subcommand_registry;
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
mod cognition_gate;
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
mod decompose_backend; // INFRA-8573: --backend selection (cascade / claude -p / auto) for `chump gap decompose`
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
mod dispatch_model_defaults; // INFRA-8220: layer-aware default model/budget when --model omitted
mod dispatch_repair; // INFRA-8199: dispatch open-PR gate + repair brief; auto-prompt never decomposes
mod doctor;
mod duty_officer; // RESILIENT-444: DutyOfficer trait contract (RESILIENT-274 slice)
mod ego_tool;
mod env_flags;
mod episode_db;
mod episode_extractor;
mod episode_tool;
mod playbook_registry; // RESILIENT-443: registry loading from JSON (RESILIENT-274 slice)
pub use chump_eval_harness::eval_harness;
mod execute_gap;
mod failure_catalog;
mod farmer_status; // RESILIENT-069: farmer readiness gate (lights-on check)
mod file_watch;
mod fleet;
mod fleet_capability;
mod fleet_db;
mod fleet_doctor_dispatcher; // RESILIENT-1355: routing dispatcher for health check failures
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
mod gap_filer; // RESILIENT-1356: gap filing and deduplication
mod rebase_queue; // INFRA-2225: fleet rebase-queue — auto-rebase daemon backlog surface
                  // INFRA-693: gap_store moved to its own crate (crates/chump-gap-store/).
                  // The rename keeps every `gap_store::*` call site compiling unchanged.
pub(crate) use chump_gap_store as gap_store;
// INFRA-1229: explicit linkage declaration so Cargo always links chump-ship
// even when the CI rust-cache restores a stale build (fixes E0433 on Ubuntu).
extern crate chump_ship;
mod audit;
mod audit_log; // INFRA-1842: queryable per-action audit log (CP-010, vendored from BEAST-MODE AuditLogger)
mod inference_provider;
mod log_triage; // INFRA-1891: `chump fleet log-triage` daily structured ambient×state.db triage pass // INFRA-1844: multi-model provider chain (CP-012, vendored from ai-gm-service)
pub use chump_bench::bench; // DOC-072/EFFECTIVE-327: ChumpBench — run a track as a scoreable lap (EFFECTIVE-405: extracted to crates/chump-bench)
mod budget_tracker; // INFRA-1486: per-gap execution budgets (Marcus trust gate)
mod cartographer; // INFRA-1782: chump cartograph <repo-path> — ARCHITECTURE.md generation (INFRA-1746 phase 2)
mod collision_prediction; // META-076: predictive collision detection (mock inputs), first impl of docs/design/COLLISION_PREDICTION_SCHEMA.md
mod completion;
mod disk_cmd; // INFRA-2196: chump disk status|plan|budget (META-128/C5)
mod done_auditor; // INFRA-3495: anti-over-claim watchdog — audit DONE gaps for uncovered AC
mod evangelist; // INFRA-1783: chump evangelize <repo-path> — HIDDEN_GEMS.md generation (INFRA-1746 phase 3)
mod front_door; // EFFECTIVE-330 (COTG-0.0): plain-language front-door mode router
mod gap_file; // INFRA-8061: universal gap-intake filer (POST CHUMP_GAP_URL + durable local spool)
mod gap_route; // INFRA-3689: route gap mutations to the fleet-server when local checkout is non-canonical
mod gap_scoring; // INFRA-1816: gap-value scorer, vendored from repairman29/echeo — substrate for INFRA-1764
mod gen;
mod genai_conv;
mod git_safety; // RESILIENT-256: destructive-git guard + object-store WIP snapshot
mod git_tools;
mod github_rate_limit;
mod gonogo; // INFRA-3481/INFRA-5340: honest go/no-go verdict parsing, cloned from pr_ac_coverage::parse_judge_verdicts
mod harvester_cli; // INFRA-1823: chump harvest <scan|check|brief|deep-scan|list-clusters> — fleet cartographer CLI
mod health;
mod health_check_routing; // RESILIENT-1354: routing configuration for health check failures
mod health_server;
mod hitl_escalation;
mod hooks;
mod improve; // EFFECTIVE-177: chump improve <owner/repo> — autonomous-improve loop
mod inference_router; // INFRA-1843: two-tier LLM dispatch (Reflexive on-device + Neocortex cloud), CP-011
mod ingest; // INFRA-1780: chump ingest <repo-path> (phase 1a — validation + read-only safety)
mod ingest_backlog; // MISSION-055: chump ingest <repo-path> --import-backlog — import a repo's DEFINED backlog as fleet gaps
mod ingest_librarian; // INFRA-1781: Phase 1 Librarian audit + triage report (INFRA-1746 phase 1b)
mod ingest_orchestrate; // INFRA-1784: orchestration + certificate + auto-gaps (INFRA-1746 phase 5)
mod ingest_preflight; // INFRA-1778: chump ingest-preflight — gh auth + push-access safety rail
mod inspect_cmd; // INFRA-1456: chump inspect <gap-id> — eject-and-inspect surface
mod intent_parser;
mod interrupt_notify;
mod intervention_watchdog; // COTG-2.1/INFRA-3489: log every human touch as an autonomy defect
mod introspect_tool;
mod node_mode; // RESILIENT-1614: node pause/resume commands (enforce paused mode as invariant)
mod node_pause; // RESILIENT-1652/1653: the ONE paused predicate (farmer gate + pause detector)
mod scan; // INFRA-1882: chump scan <repo-path> — repo takeover opener (2026 demo #2)
pub use chump_inventory::inventory; // META-271: fleet inventory + tech-debt review-only audit DB (EFFECTIVE-401: extracted to crates/chump-inventory)
mod job_log;
pub use chump_kpi_report::kpi_report; // EFFECTIVE-418: extracted to crates/chump-kpi-report (build-speed)
mod ledger_prune; // CREDIBLE-1307: prune_ledger — remove low-crit dormant ledger entries
mod lesson_action;
mod lesson_embeddings;
mod limits;
mod llm_backend_metrics;
mod local_openai;
mod mcp_bridge;
mod mcp_discovery;
mod memory_brain_tool;
pub use chump_memory_db::memory_db;
mod memory_graph;
mod memory_graph_tool;
mod memory_graph_viz;
mod memory_tool;
mod messaging;
mod mission_grade;
#[cfg(feature = "mistralrs-infer")]
mod mistralrs_provider;
mod model_overlay;
mod model_probe;
mod neuromodulation;
mod notify_tool;
mod onboard; // INFRA-2108: chump onboard <repo-url-or-path>
mod onboard_repo_tool;
mod operator_presence;
mod orchestrate;
pub use chump_paramedic::paramedic;
mod patch_apply;
mod pe_suite_status; // INFRA-2229: chump pe-suite status dashboard
mod pending_peer_approval;
mod perception;
mod peripheral_sensor;
mod phi_proxy;
mod pillar_cap; // CREDIBLE-072: per-pillar weekly merge-share cap/floor at gap reserve
mod pilot_metrics;
mod plan_mode;
mod platform_router;
mod plugin;
mod policy_override;
mod pr_blame_file; // INFRA-1445: chump pr blame-file <path>
mod pr_coupling_cost;
mod pr_explain; // INFRA-1416: chump pr explain-block <PR>
mod pr_fix_clippy;
mod pr_rescue; // INFRA-1714: closed-loop PR rescue (chump pr-rescue)
mod pr_triage;
mod precision_controller;
pub use chump_preflight::preflight; // INFRA-1670: local CI mirror — chump preflight subcommand (extracted to crates/chump-preflight, EFFECTIVE-400)
mod provider_bandit;
mod provider_cascade;
mod provider_probe;
mod provider_quality;
mod prune_ledger; // CREDIBLE-1277: prune_ledger — low-crit dormant stage pruning
mod ratings;
mod read_url_tool;
mod reasoning_mode;
mod rebase_stuck;
mod recipe;
mod reflect_delta;
mod reflection;
mod reflection_db;
mod repo_allowlist;
mod repo_allowlist_tool;
mod repo_path;
mod repo_tools;
mod required_check_health; // INFRA-1522: W-007 required-check health gate
mod rescue_tally;
mod resume_cmd; // INFRA-1456: chump resume <gap-id> — reattach wedged gap
mod revert_pr;
mod review_dispatch; // CREDIBLE-181: `chump review` — structurally review-only agent dispatch
mod review_handoff;
mod roadmap_pillar_score; // META-409 (META-152 slice): roadmap-bottleneck-pillar alignment scoring
mod roadmap_status;
mod rollup_cmd; // INFRA-1455: chump rollup --semantic (Marcus M-B converge)
mod routes;
mod rpc_mode;
mod rules_audit; // ZERO-WASTE-125: `chump rules <audit|check-budget>` — self-pruning rulebook auditor
mod run_test_tool;
mod runtime_flags;
mod sandbox; // INFRA-1454: agent bash syscall-restriction layer (macOS sandbox-exec wrap)
mod sandbox_tool;
mod schedule_db;
mod schedule_tool;
mod scrap_cmd; // INFRA-1456: chump scrap <gap-id> — clean teardown
mod screen_vision_tool;
mod self_hosted_runner_check; // INFRA-1544: self-hosted runner liveness check for fleet doctor
mod session;
pub mod session_compact;
mod session_export;
mod session_ledger;
mod session_search_tool;
mod session_summary; // INFRA-1437: chump session-summary subcommand
mod set_working_repo_tool;
mod ship_quality;
mod skill_db;
mod skill_hub;
mod skill_hub_tool;
mod skill_metrics;
mod skill_routing; // META-078: skill-aware routing decision engine (stub skills DB), first impl of docs/design/SKILL_AWARE_ROUTING_SCHEMA.md
mod skill_tool;
mod skills;
mod slack;
mod spawn_worker_tool;
mod speculative_execution;
mod stack_detect;
mod staleness;
mod standard_missions; // EFFECTIVE-199: L1 foundation queue for 0→1 onboard — see docs/design/ONBOARD_0TO1_DOCTRINE.md
mod state_db;
mod stream_events;
mod streaming_provider;
mod system_prompt;
mod systematizer; // INFRA-1783: chump systematize <repo-path> — CAPABILITIES_REGISTRY.json generation (INFRA-1746 phase 4)
mod task_contract;
mod task_db;
mod task_executor;
mod task_planner_tool;
mod task_tool;
mod telegram;
mod telemetry_energy;
mod test_aware;
mod thinking_strip;
mod tool_health_db;
mod tool_input_schema_validate;
mod tool_input_validate;
mod tool_inventory;
mod tool_middleware;
mod tool_normalize; // INFRA-740: repair malformed tool-call JSON from weak LLMs
mod tool_policy;
mod tool_routing;
mod toolkit_status_tool;
mod tracing_init;
mod trajectory_replay;
mod trek; // INFRA-3656 (RIBBON-01): chump trek — auto-execute front-door entrypoint
mod user_error_hints;
pub mod user_profile;
mod vector6_verify;
mod vector7_swarm_verify;
mod verify; // CREDIBLE-155: unified policy engine — chump verify subcommand
mod verify_claim_branch; // INFRA-1649 (re-do of INFRA-1598): verify-claim-branch primitive
mod version;
mod vision_intake; // INFRA-3480: chump intake "<plain-language problem>" [--json] [--create]
mod wasm_calc_tool;
mod wasm_runner;
mod wasm_text_tool;
// EFFECTIVE-411: waste_tally extracted to crates/chump-waste-tally for build
// speed. Re-exported so every existing `waste_tally::…` / `crate::waste_tally::…`
// caller resolves unchanged. Per-model pricing is injected at startup (see
// `main()` → `waste_tally::set_cost_fn`).
pub use chump_waste_tally::waste_tally;
mod web_brain;
#[cfg(all(feature = "web-push", not(windows)))]
mod web_push_send;
mod web_server;
mod web_sessions_db;
mod web_uploads;
// META-159: fleet recv-side v0 voting CLIs (chump vote + chump consensus-tally).
mod commands;

#[cfg(test)]
mod consciousness_exercise;
#[cfg(test)]
mod consciousness_tests;
#[cfg(test)]
mod e2e_bot_tests;

#[cfg(feature = "inprocess-embed")]
mod embed_inprocess;

mod metrics;
mod metrics_registry;
#[cfg(test)]
mod test_env; // ZERO-WASTE-152: CHUMP_STATE_DB isolation for tests

mod cli_dispatch;
pub(crate) use cli_dispatch::*;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    cli_dispatch::run().await
}
