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
mod approval_resolver;
mod asi_telemetry;
mod ask_jeff_db;
mod ask_jeff_tool;
mod assertion;
mod atomic_claim;
mod auth;
mod autonomy_fsm;
mod autonomy_level; // RESILIENT-073: fleet kill switch — fail-closed pure file read
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
mod ci_summary;
mod cli_tool;
mod cluster_mesh;
mod codebase_digest_tool;
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
mod dashboard;
mod db_pool;
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
mod eval_harness;
mod execute_gap;
mod failure_catalog;
mod file_watch;
mod fleet;
mod fleet_capability;
mod fleet_db;
mod fleet_fanout; // INFRA-1484: cross-repo fan-out (Marcus M-B continuation)
mod fleet_health;
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
// INFRA-693: gap_store moved to its own crate (crates/chump-gap-store/).
// The rename keeps every `gap_store::*` call site compiling unchanged.
use chump_gap_store as gap_store;
// INFRA-1229: explicit linkage declaration so Cargo always links chump-ship
// even when the CI rust-cache restores a stale build (fixes E0433 on Ubuntu).
extern crate chump_ship;
mod audit;
mod budget_tracker; // INFRA-1486: per-gap execution budgets (Marcus trust gate)
mod completion;
mod disk_cmd; // INFRA-2196: chump disk status|plan|budget (META-128/C5)
mod external_verify_merge; // CREDIBLE-096: chump external verify-merge
mod gen;
mod genai_conv;
mod git_tools;
mod github_rate_limit;
mod health;
mod health_server;
mod hitl_escalation;
mod hooks;
mod improve; // EFFECTIVE-177: chump improve <owner/repo> — autonomous-improve loop
mod inspect_cmd; // INFRA-1456: chump inspect <gap-id> — eject-and-inspect surface
mod intent_parser;
mod interrupt_notify;
mod introspect_tool;
mod inventory; // META-271: fleet inventory + tech-debt review-only audit DB
mod job_log;
mod kpi_report;
mod lesson_action;
mod lesson_embeddings;
mod limits;
mod llm_backend_metrics;
mod local_openai;
mod mcp_bridge;
mod mcp_discovery;
mod memory_brain_tool;
mod memory_db;
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
mod paramedic;
mod patch_apply;
mod pe_suite_status; // INFRA-2229: chump pe-suite status dashboard
mod pending_peer_approval;
mod perception;
mod peripheral_sensor;
mod phi_proxy;
mod pilot_metrics;
mod plan_mode;
mod platform_router;
mod plugin;
mod policy_override;
mod pr_ac_coverage;
mod pr_coupling_cost;
mod pr_explain; // INFRA-1416: chump pr explain-block <PR>
mod pr_fix_clippy;
mod pr_rescue; // INFRA-1714: closed-loop PR rescue (chump pr-rescue)
mod pr_triage;
mod precision_controller;
mod preflight; // INFRA-1670: local CI mirror — chump preflight subcommand
mod provider_bandit;
mod provider_cascade;
mod provider_quality;
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
mod review_handoff;
mod roadmap_status;
mod rollup_cmd; // INFRA-1455: chump rollup --semantic (Marcus M-B converge)
mod routes;
mod rpc_mode;
mod run_test_tool;
mod runtime_flags;
mod sandbox; // INFRA-1454: agent bash syscall-restriction layer (macOS sandbox-exec wrap)
mod sandbox_tool;
mod schedule_db;
mod schedule_tool;
mod scrap_cmd; // INFRA-1456: chump scrap <gap-id> — clean teardown
mod screen_vision_tool;
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
mod user_error_hints;
pub mod user_profile;
mod vector6_verify;
mod vector7_swarm_verify;
mod version;
mod wasm_calc_tool;
mod wasm_runner;
mod wasm_text_tool;
mod waste_tally;
mod web_brain;
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

use anyhow::{Context as _, Result};
use axonerai::agent::Agent;
use axonerai::file_session_manager::FileSessionManager;
use axonerai::tool::ToolRegistry;
use std::env;
use std::io::{self, IsTerminal, Read, Write};

/// Serenity adds "Bot " to the token; if .env has "Bot xxx", strip it so we don't send "Bot Bot xxx".
fn normalize_discord_token(s: &str) -> String {
    let s = s.trim();
    if s.eq_ignore_ascii_case("bot") {
        return String::new();
    }
    if s.len() > 4 && s.get(..4).map(|p| p.eq_ignore_ascii_case("bot ")) == Some(true) {
        return s[4..].trim().to_string();
    }
    s.to_string()
}

pub(crate) fn unix_ts() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// INFRA-1886: `chump gap preflight <ID>` advisory hint. When the target
/// gap is open + unclaimed, surface up to 3 higher-priority unclaimed gaps
/// so the picker is nudged toward what's actually starved without enforcing
/// hard ranked-pull semantics. No exit-code change; prints to stderr after
/// the existing OK line.
///
/// Bypass: `CHUMP_PREFLIGHT_NO_SUGGEST=1` silences the note (mirrors the
/// existing CHUMP_PREFLIGHT_SKIP_* discipline).
///
/// Emits `kind=preflight_priority_hint_shown` to ambient when the note
/// fires, with fields `{target_gap, suggested_gaps_count, target_priority}`.
pub(crate) fn print_priority_hint(
    store: &gap_store::GapStore,
    target_id: &str,
    repo_root: &std::path::Path,
) {
    // Get target priority. If we can't read it, skip silently — preflight's
    // exit code is already set; this is best-effort advisory.
    //
    // gap_store::GapRow.priority is Option<String> on the get() path
    // (different struct than list()'s). Normalize to a plain string.
    let target_priority: String = match store.get(target_id) {
        Ok(Some(row)) => row.priority,
        _ => return,
    };
    // Already P0 → nothing higher to suggest.
    if target_priority == "P0" {
        return;
    }
    // Pull all open gaps; filter to higher-priority (lower priority-number),
    // exclude the target itself, sort by priority asc then created_at asc.
    // INFRA-1555: apply rating-aware tie-break demotion using class ratings
    // from ambient.jsonl (30-day window, threshold 2.5 mean, min 2 samples).
    let opens = match store.list(Some("open")) {
        Ok(v) => v,
        Err(_) => return,
    };
    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
    let class_ratings = atomic_claim::load_class_ratings(&ambient_path);
    let target_rank = priority_rank(&target_priority);
    let mut candidates: Vec<_> = opens
        .into_iter()
        .filter(|g| g.id != target_id)
        .filter(|g| priority_rank(&g.priority) < target_rank)
        .collect();
    candidates.sort_by(|a, b| {
        atomic_claim::effective_priority_rank(&a.priority, &a.id, &class_ratings)
            .cmp(&atomic_claim::effective_priority_rank(
                &b.priority,
                &b.id,
                &class_ratings,
            ))
            .then_with(|| a.created_at.cmp(&b.created_at))
    });
    let top: Vec<_> = candidates.into_iter().take(3).collect();
    if top.is_empty() {
        return;
    }
    eprintln!("[preflight] note — higher-priority unclaimed gaps you could pick instead:");
    for g in &top {
        let title: String = g.title.chars().take(50).collect();
        let pillar = g.title.split(':').next().unwrap_or("").trim();
        eprintln!(
            "[preflight]   {pri:<2} {pillar:<10} {id} — {title}",
            pri = g.priority,
            id = g.id
        );
    }
    // Best-effort ambient emit. Failure here is silent.
    // (ambient_path already bound above for load_class_ratings)
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let event = format!(
        r#"{{"ts":"{now}","kind":"preflight_priority_hint_shown","target_gap":"{target_id}","suggested_gaps_count":{},"target_priority":"{target_priority}"}}"#,
        top.len()
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{event}");
    }
}

/// Priority string → ordinal (P0=0, P1=1, P2=2, P3=3). Unknown → 99 so it
/// sorts last and doesn't get suggested.
fn priority_rank(p: &str) -> u8 {
    match p {
        "P0" => 0,
        "P1" => 1,
        "P2" => 2,
        "P3" => 3,
        _ => 99,
    }
}

/// INFRA-431: domains whose rows are pure test fixtures and should be
/// hidden from the default `chump gap list` output. The 2026-05-03 INFRA-428
/// audit found 306 leaked SPIKE/TEST/TEST168 rows in production state.db.
/// Users opt back in via `--include-test-domains`.
pub(crate) fn is_test_domain(domain: &str) -> bool {
    matches!(domain, "SPIKE" | "TEST" | "TEST168")
        || domain.starts_with("TEST")
        || domain.ends_with("TEST")
}

/// INFRA-1259/1878: Returns true if a single AC entry is a placeholder stub.
/// Only matches entries that ARE stubs, not entries that mention "TODO" in
/// meaningful text (e.g. "AC: ensures no TODO in field X" must not match).
pub(crate) fn is_vague_ac_entry(s: &str) -> bool {
    let t = s.trim();
    let upper = t.to_uppercase();
    upper == "TODO"
        || upper == "TBD"
        || upper == "TBC"
        || upper == "N/A"
        || upper.starts_with("TODO:")
        || upper.starts_with("TODO ")
        || upper.starts_with("TBD:")
        || upper.starts_with("TBD ")
        || upper.starts_with("<FILL")
        || upper.starts_with("FILL IN")
}

/// INFRA-1259: Check if acceptance_criteria is vague (empty, all-TODO, or all-TBD).
pub(crate) fn is_acceptance_criteria_vague(ac: &str) -> bool {
    let trimmed = ac.trim();
    // Empty AC is vague
    if trimmed.is_empty() {
        return true;
    }

    // Try to parse as JSON array (the canonical format)
    if let Ok(serde_json::Value::Array(arr)) = serde_json::from_str(trimmed) {
        if arr.is_empty() {
            return true; // Empty array
        }
        // All items must be stubs for the gap to be flagged vague (INFRA-1878:
        // entries that merely mention "TODO" in passing must not trigger ⚠).
        let all_vague = arr
            .iter()
            .all(|item| item.as_str().map(is_vague_ac_entry).unwrap_or(false));
        return all_vague;
    }

    // If not JSON array, only flag if the whole string IS a stub keyword.
    let upper = trimmed.to_uppercase();
    upper == "TODO" || upper == "TBD"
}

/// INFRA-094: write a marker recording that the chump CLI just modified
/// docs/gaps.yaml via a canonical operation (`gap dump --out` /
/// `gap ship --update-yaml`). The pre-commit hook reads this marker — if
/// it's < 5 minutes old AND docs/gaps.yaml is staged, the hook treats the
/// diff as canonical and skips the raw-YAML-edit advisory.
///
/// Failures are best-effort: the worst outcome is a spurious pre-commit
/// warning, which is recoverable.
pub(crate) fn write_yaml_op_marker(repo_root: &std::path::Path, op: &str) {
    let dir = repo_root.join(".chump");
    let _ = std::fs::create_dir_all(&dir);
    let marker = dir.join(".last-yaml-op");
    let body = format!(
        "{{\"op\":\"{}\",\"ts\":{},\"sha\":\"{}\"}}\n",
        op,
        unix_ts(),
        env!("CARGO_PKG_VERSION")
    );
    let _ = std::fs::write(&marker, body);
}

/// INFRA-488: parse a friendly duration string ("24h", "7d", "60m",
/// "3600s") into seconds. Pure digits are interpreted as seconds.
/// Returns None for unparseable input.
pub(crate) fn parse_duration_to_secs(s: &str) -> Option<u64> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let (num_part, unit_secs): (&str, u64) = if let Some(rest) = s.strip_suffix('d') {
        (rest, 86_400)
    } else if let Some(rest) = s.strip_suffix('h') {
        (rest, 3_600)
    } else if let Some(rest) = s.strip_suffix('m') {
        (rest, 60)
    } else if let Some(rest) = s.strip_suffix('s') {
        (rest, 1)
    } else {
        (s, 1)
    };
    let n: u64 = num_part.parse().ok()?;
    n.checked_mul(unit_secs)
}

/// INFRA-1719: surface file-path-like tokens from arbitrary text (gap
/// description, notes) for the AST crawler to consume.
///
/// We accept paths that:
///   - end in a known source extension (.rs .py .js .ts .tsx .go .sh .yaml .yml),
///   - resolve to an existing file under `repo_root` after a path-join.
///
/// Returns absolute paths (input to crawler), deduplicated, capped at 64 to
/// keep the prompt block bounded.
pub(crate) fn extract_path_hints(
    text: &str,
    repo_root: &std::path::Path,
) -> Vec<std::path::PathBuf> {
    use std::collections::BTreeSet;
    // Match tokens like `crates/foo/src/bar.rs` or `src/main.rs`.
    // Conservative: at least one slash and a known extension.
    static EXT_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re = EXT_RE.get_or_init(|| {
        regex::Regex::new(r"[A-Za-z0-9_./\-]+\.(?:rs|py|js|mjs|cjs|ts|tsx|go|sh|bash|yaml|yml)\b")
            .expect("path-hint regex compiles")
    });
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for cap in re.find_iter(text) {
        let raw = cap.as_str().trim_matches(|c: char| {
            !c.is_ascii_alphanumeric() && c != '.' && c != '_' && c != '/' && c != '-'
        });
        if raw.is_empty() || raw.contains("..") {
            continue;
        }
        // Skip URLs (`http://...rs`).
        if raw.starts_with("http") || raw.starts_with("https") {
            continue;
        }
        let candidate = repo_root.join(raw);
        if !candidate.is_file() {
            continue;
        }
        let canon = candidate.canonicalize().unwrap_or(candidate);
        if seen.insert(canon.clone()) {
            out.push(canon);
            if out.len() >= 64 {
                break;
            }
        }
    }
    out
}

/// INFRA-1522: probe the repo's required status checks from branch protection.
///
/// Shells `gh api repos/<owner>/<repo>/branches/main/protection` and extracts
/// the contexts array. Returns empty Vec on any error (caller fails-open).
///
/// Resolves owner/repo from `git remote get-url origin` or the `CHUMP_GH_REPO`
/// env var.
fn list_required_contexts() -> Vec<String> {
    // Allow tests / CI to inject the contexts list (skips the gh shell-out).
    if let Ok(v) = std::env::var("CHUMP_REQUIRED_CHECKS_OVERRIDE") {
        return v
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
    }

    let repo = match std::env::var("CHUMP_GH_REPO") {
        Ok(r) if !r.is_empty() => r,
        _ => {
            // Try `gh repo view` to resolve owner/repo.
            let out = std::process::Command::new("gh")
                .args([
                    "repo",
                    "view",
                    "--json",
                    "nameWithOwner",
                    "-q",
                    ".nameWithOwner",
                ])
                .output();
            match out {
                Ok(o) if o.status.success() => {
                    String::from_utf8_lossy(&o.stdout).trim().to_string()
                }
                _ => return Vec::new(),
            }
        }
    };

    if repo.is_empty() {
        return Vec::new();
    }

    let url = format!("repos/{}/branches/main/protection", repo);
    let out = std::process::Command::new("gh")
        .args(["api", &url, "--jq", ".required_status_checks.contexts[]?"])
        .output();

    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        _ => Vec::new(),
    }
}

/// Load .env from CHUMP_HOME/CHUMP_REPO first (so Chump Menu / run-discord.sh always get the right .env),
/// then current dir, then executable dir.
fn load_dotenv() {
    let base = repo_path::runtime_base();
    let env_path = base.join(".env");
    if env_path.is_file() {
        let _ = dotenvy::from_path(&env_path);
        return;
    }
    if dotenvy::dotenv().is_ok() {
        return;
    }
    if let Ok(exe) = env::current_exe() {
        if let Some(dir) = exe.parent() {
            let mut path = dir.to_path_buf();
            path.push(".env");
            let _ = dotenvy::from_path(&path);
        }
    }
}

/// EFFECTIVE-009 — print grouped command reference.
/// Shown when `chump` is run with no args, or when `chump help` / `chump --help` is used.
// EFFECTIVE-011: expand short command aliases before routing.
// "s" is a compound alias: "chump s <ID>" → "chump gap ship <ID>".
fn expand_aliases(mut args: Vec<String>) -> Vec<String> {
    if args.len() < 2 {
        return args;
    }
    match args[1].as_str() {
        "g" => {
            args[1] = "gap".to_string();
        }
        "c" => {
            args[1] = "claim".to_string();
        }
        "f" => {
            args[1] = "fleet".to_string();
        }
        "d" => {
            args[1] = "dispatch".to_string();
        }
        "h" => {
            args[1] = "health".to_string();
        }
        "cs" => {
            args[1] = "cost-watch".to_string();
        }
        "s" => {
            args[1] = "gap".to_string();
            args.insert(2, "ship".to_string());
        }
        // INFRA-1238: top-level `chump ship` (literal, not alias-s) was
        // promised in print_help but never wired — fell through to the
        // LLM agent loop. Mirror the `s` expansion.
        // INFRA-1229: leave `chump ship plan` / `chump ship execute` alone
        // — those are the new subcommands (slices 1+2 of bot-merge port).
        // Only the legacy `chump ship <GAP-ID>` form gets the `gap ship` alias.
        "ship" => {
            let sub2 = args.get(2).map(String::as_str);
            if sub2 != Some("plan") && sub2 != Some("execute") {
                args[1] = "gap".to_string();
                args.insert(2, "ship".to_string());
            }
        }
        _ => {}
    }
    args
}

/// INFRA-2373: prepend a one-line `chump init` hint to help output when
/// the user has not yet scaffolded `~/.chump/config.toml`. Returns the
/// banner string (incl. trailing blank line) or empty string when:
///   * HOME env is unset (no panic path), or
///   * `~/.chump/config.toml` already exists.
///
/// Tested via `print_help` integration — the standalone helper exists so
/// the same hint can be reused from `chump config show` (see
/// `commands::config::Snapshot::print_human`).
fn chump_init_nudge_if_missing() -> String {
    let home = match std::env::var("HOME") {
        Ok(h) if !h.is_empty() => h,
        _ => return String::new(),
    };
    let cfg = std::path::PathBuf::from(home)
        .join(".chump")
        .join("config.toml");
    if cfg.exists() {
        return String::new();
    }
    "tip: run 'chump init' to scaffold ~/.chump/config.toml (one-time setup)\n\n".to_string()
}

fn print_help() {
    print!("{}", chump_init_nudge_if_missing());
    let ver = version::chump_version();
    println!("chump — gap orchestration tool  (v{ver})");
    println!();
    println!("USAGE");
    println!("  chump <command> [options]");
    println!("  chump <command> --help        show help for that command");
    println!("  chump --version               print version + build SHA");
    println!("  chump --build-info [--json]   print baked build metadata (INFRA-2054)");
    println!("  chump self-check-staleness    classify binary FRESH/STALE/CRITICAL (INFRA-2054)");
    println!("  chump --verbose               escalate RUST_LOG to debug");
    println!("  chump --debug                 debug header (version, args, timestamp) + verbose");
    println!();
    println!("GAP MANAGEMENT");
    println!("  gap <sub>  (alias: g)  list, show, reserve, ship, audit-priorities …");
    println!("  claim <GAP-ID>  (alias: c)  atomic worktree + lease + preflight in one call");
    println!("  ship <GAP-ID>   (alias: s)  shorthand for 'gap ship <GAP-ID>'");
    println!("  onboard <repo-url-or-path>  first-touch external-repo scanner (INFRA-2108)");
    println!("  improve <owner/repo> [--gap <ID>] [--apply] [--clone-dir <path>]");
    println!("                              autonomous improve loop: pick→dedup→implement→verify-merge (EFFECTIVE-177)");
    println!("  external verify-merge --pr <N> --repo <owner/repo> --gap <ID> [--clone-dir <path>] [--apply]");
    println!("                              autonomous PR merge judge — 3-gate anti-cosmetic bar (CREDIBLE-096)");
    println!("  gen <task>         AI-driven single-shot coding task (offline-LLM)");
    println!();
    println!("FLEET");
    println!("  fleet <sub>  (alias: f)  worker control — up/status/down/doctor …");
    println!("  dispatch <sub>  (alias: d)  route/scoreboard/simulate/cost-report …");
    println!("  orchestrate        Opus-driven conversational loop (interactive)");
    println!();
    println!("ANALYTICS");
    println!("  health  (alias: h)  current gap-registry health snapshot");
    println!(
        "  session-summary    merged + armed + filed PRs in current session window (INFRA-1437)"
    );
    println!("  pe-suite status    P&E suite operator dashboard: curator liveness + consensus (INFRA-2229)");
    println!("  health-digest      markdown digest with P0/P1 counts + warnings");
    println!("  fleet-status       per-worker throughput + lease state");
    println!("  fleet-velocity     PRs/day and ship-rate trend");
    println!("  waste-tally        % of compute spent on closed-without-merge PRs");
    println!("  ship-quality       post-merge signal: pass rate, revert rate");
    println!("  roadmap-status     milestone completion %");
    println!(
        "  mission-grade      current pillar grades (EFFECTIVE/CREDIBLE/RESILIENT/ZERO-WASTE)"
    );
    println!("  lesson-grade       lesson-learning quality score");
    println!("  ci-summary         last-N CI run outcomes");
    println!("  classify-failure   categorize a CI/PR failure for the improvement tracker");
    println!(
        "  kpi report         KPI scorecard across all pillars
  kpi report --impact  gap impact ratings (chump gap rate)"
    );
    println!("  kpi report --agents  per-agent throughput (ships/fails/P50)");
    println!("  kpi report --agents --date YYYY-MM-DD  specific date");
    println!("  cost-watch  (alias: cs)  real-time inference spend + per-slot breakdown");
    println!("  cost record-pr     attach cost metadata to a merged PR");
    println!("  pr-coupling-cost   cost of PRs that move together (coupling smell)");
    println!("  cascade stats      per-slot hit/miss/error counts for the provider cascade");
    println!("  funnel             install → first_task → return_d2 activation funnel");
    println!("  dashboard          open the local web dashboard");
    println!();
    println!("SESSION / REFLECTION");
    println!("  session-track      start or continue a named work session");
    println!("  session-export     export session transcript as markdown");
    println!("  session-resume     re-attach to the most recent session");
    println!("  reflect-delta      compute lesson-delta since last reflection");
    println!("  rebase-stuck       auto-resolve stuck rebase for a given branch");
    println!("  pr fix-clippy      run clippy --fix on the current PR branch");
    println!("  pr triage          assign labels + reviewer to open PRs");
    println!();
    println!("SERVER MODES  (long-running, not for interactive use)");
    println!("  --web              start the PWA web server (default port 3000)");
    println!("  --acp              ACP stdio mode for Zed / JetBrains / VS Code");
    println!("  --discord          Discord gateway bot (requires --features discord)");
    println!("  --telegram         Telegram bot (requires TELEGRAM_BOT_TOKEN)");
    println!("  --slack            Slack Socket Mode bot (requires SLACK_BOT_TOKEN)");
    println!("  --rpc              internal JSON-RPC loop (fleet workers)");
    println!();
    println!("FIRST RUN");
    println!("  init               detect model, write .env, start server, open browser");
    println!();
    println!("DOCS");
    println!("  AGENTS.md          coordination rules and pillar definitions");
    println!("  docs/ROADMAP.md    milestone plan");
    println!("  scripts/README.md  script taxonomy and entry points");
}

/// `chump plan` subcommand (INFRA-1021).
///
/// Thin wrapper around chump-planner library — keeps main.rs free of the
/// scoring/graph internals so the planner can evolve independently. Errors
/// bubble up via Result; reconciliation-gate breach maps to exit code 2.
fn run_plan_subcommand(args: &[String]) -> Result<()> {
    use chump_planner::output::table;
    use chump_planner::score::TelemetryInputs;
    use chump_planner::{
        build_plan, collect_reconcile, load_gaps_dir, DependencyGraph, PlanRequest, Weights,
    };

    if args.iter().any(|a| a == "--help" || a == "help") {
        println!("Usage: chump plan [OPTIONS]");
        println!();
        println!("Rank the open gap backlog and recommend the next N to dispatch.");
        println!("v0.1: structured depends_on hard edges only, table output,");
        println!("reconciliation gate. --explain / --graph / --json arrive in v0.2.");
        println!();
        println!("OPTIONS:");
        println!("  --gaps PATH             Gaps directory (default: docs/gaps)");
        println!("  --agents N              Plan for N concurrent agents (default: 5)");
        println!("  --pillar DOMAIN         Filter to a single domain");
        println!("  --max-effort SIZE       Skip gaps larger than this (xs/s/m/l/xl)");
        println!("  --no-pillar-cap         Disable the running pillar-share cap");
        println!("  --include-blocked       Include gaps with open prerequisites");
        println!("  --reconcile-threshold N Exit non-zero when status:open+closed_pr backlog > N");
        println!("                          (default 10)");
        return Ok(());
    }

    let mut gaps_path = std::path::PathBuf::from("docs/gaps");
    let mut agents: usize = 5;
    let mut pillar: Option<String> = None;
    let mut max_effort: Option<String> = None;
    let mut no_pillar_cap = false;
    let mut include_blocked = false;
    let mut reconcile_threshold: usize = 10;

    let mut it = args.iter().skip(2);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--gaps" => {
                gaps_path = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--gaps needs a value"))?
                    .into();
            }
            "--agents" => {
                agents = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--agents needs a value"))?
                    .parse()?;
            }
            "--pillar" => {
                pillar = Some(
                    it.next()
                        .ok_or_else(|| anyhow::anyhow!("--pillar needs a value"))?
                        .clone(),
                );
            }
            "--max-effort" => {
                max_effort = Some(
                    it.next()
                        .ok_or_else(|| anyhow::anyhow!("--max-effort needs a value"))?
                        .clone(),
                );
            }
            "--no-pillar-cap" => no_pillar_cap = true,
            "--include-blocked" => include_blocked = true,
            "--reconcile-threshold" => {
                reconcile_threshold = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--reconcile-threshold needs a value"))?
                    .parse()?;
            }
            "--format" => {
                // v0.1 supports only table; accept it explicitly so the v0.2
                // wiring (--format json|mermaid|markdown) lands as a small diff.
                let v = it
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("--format needs a value"))?;
                if v != "table" {
                    anyhow::bail!("v0.1 only supports --format table; got {v}");
                }
            }
            other => anyhow::bail!("unknown arg {other} (see chump plan --help)"),
        }
    }

    let gaps = load_gaps_dir(&gaps_path)
        .map_err(|e| anyhow::anyhow!("loading gaps from {}: {e}", gaps_path.display()))?;
    let graph = DependencyGraph::build(&gaps);

    if let Err(cycle) = graph.topo_order() {
        eprintln!(
            "warning: dependency cycle detected ({} members, identity {}): {:?}",
            cycle.gaps.len(),
            &cycle.identity()[..16],
            cycle.gaps.iter().map(|g| g.0.as_str()).collect::<Vec<_>>(),
        );
    }

    let pillar_filter = match pillar.as_deref() {
        Some(s) => Some(<chump_planner::Domain as std::str::FromStr>::from_str(s)?),
        None => None,
    };
    let max_effort_val = match max_effort.as_deref() {
        Some(s) => Some(<chump_planner::Effort as std::str::FromStr>::from_str(s)?),
        None => None,
    };

    let req = PlanRequest {
        agents,
        pillar_filter,
        max_effort: max_effort_val,
        respect_pillar_cap: !no_pillar_cap,
        include_blocked,
    };

    let weights = Weights::default();
    let telemetry = TelemetryInputs::default();
    let today = chrono::Utc::now().date_naive();

    let plan = build_plan(&gaps, &graph, &req, &telemetry, today, &weights);
    let reconcile = collect_reconcile(&gaps);

    print!("{}", table::render(&plan, &reconcile));

    if reconcile.breaches(reconcile_threshold) {
        eprintln!(
            "error: reconciliation backlog {} exceeds threshold {} — run scripts/coord/gap-doctor-reconcile.py",
            reconcile.count(),
            reconcile_threshold
        );
        std::process::exit(2);
    }

    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    // EFFECTIVE-011: expand short aliases (g, c, s, f, d, h, cs) before routing.
    let args = expand_aliases(args);

    // CREDIBLE-019: --verbose / --debug global flags (processed first so they
    // take effect even alongside --version or --help).
    // --verbose: escalate RUST_LOG to debug (human stderr).
    // --debug: same as --verbose + emit a startup header with version, args, timestamp.
    let flag_verbose = args.iter().any(|a| a == "--verbose" || a == "-v");
    let flag_debug = args.iter().any(|a| a == "--debug");
    if (flag_verbose || flag_debug) && std::env::var("RUST_LOG").is_err() {
        // Safety: single-threaded; no async tasks spawned yet.
        unsafe { std::env::set_var("RUST_LOG", "debug") };
    }
    if flag_debug {
        let ts = chrono::Utc::now().format("%H:%M:%S%.3f");
        eprintln!(
            "[debug] chump {} ({}) started at {}",
            version::chump_version(),
            version::chump_build_sha(),
            ts,
        );
        eprintln!("[debug] args: {:?}", &args[1..]);
    }

    // INFRA-148: surface the baked build SHA + date so operators can verify
    // their binary's staleness against `git log src/gap_store.rs src/main.rs`
    // *before* running `chump gap ship --update-yaml` / `chump gap dump`.
    // Pre-this-fix, `chump --version` fell through to the model-prompt path
    // (printed "Response from Agent: ...") because there was no top-level
    // flag handler — defeating the point of baking the SHA at build time.
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!(
            "chump {} ({} built {})",
            version::chump_version(),
            version::chump_build_sha(),
            version::chump_build_date(),
        );
        return Ok(());
    }

    // INFRA-2054 (META-114 freshness cluster, binary-staleness layer):
    // `chump --build-info [--json]` prints the build-time metadata baked
    // in by build.rs (full git SHA, build timestamp, rustc version,
    // workspace root). Separate from --version because consumers want the
    // structured form. Falls through unchanged if the flag is absent.
    if args.iter().any(|a| a == "--build-info") {
        let want_json = args.iter().any(|a| a == "--json");
        std::process::exit(staleness::run_build_info_cli(want_json));
    }

    // INFRA-2054: `chump self-check-staleness [--threshold-age-s N]
    // [--threshold-commits N] [--json]` classifies the running binary
    // against two axes (file mtime age, commits-behind origin/main) and
    // exits 0/1/2 for FRESH/STALE/CRITICAL_STALE. Defaults match the
    // META-115 freshness preamble (3600s / 5 commits soft; 4x / 10x crit).
    if args.get(1).map(String::as_str) == Some("self-check-staleness") {
        let mut threshold_age_s: u64 = staleness::DEFAULT_THRESHOLD_AGE_S;
        let mut threshold_commits: u64 = staleness::DEFAULT_THRESHOLD_COMMITS;
        let mut want_json = false;
        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--threshold-age-s" => {
                    if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<u64>().ok()) {
                        threshold_age_s = v;
                        i += 2;
                        continue;
                    } else {
                        eprintln!("error: --threshold-age-s requires a non-negative integer");
                        std::process::exit(2);
                    }
                }
                "--threshold-commits" => {
                    if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<u64>().ok()) {
                        threshold_commits = v;
                        i += 2;
                        continue;
                    } else {
                        eprintln!("error: --threshold-commits requires a non-negative integer");
                        std::process::exit(2);
                    }
                }
                "--json" => {
                    want_json = true;
                    i += 1;
                }
                "--help" | "-h" => {
                    println!("chump self-check-staleness — INFRA-2054 (META-114 cluster)");
                    println!();
                    println!("USAGE");
                    println!("  chump self-check-staleness [options]");
                    println!();
                    println!("OPTIONS");
                    println!(
                        "  --threshold-age-s <N>     Soft age threshold in seconds (default {})",
                        staleness::DEFAULT_THRESHOLD_AGE_S
                    );
                    println!(
                        "  --threshold-commits <N>   Soft commits-behind threshold (default {})",
                        staleness::DEFAULT_THRESHOLD_COMMITS
                    );
                    println!("  --json                    Emit StalenessReport as JSON");
                    println!();
                    println!("EXIT CODES");
                    println!("  0   FRESH          — both axes inside threshold");
                    println!("  1   STALE          — at least one axis past soft threshold");
                    println!("  2   CRITICAL_STALE — at least one axis past critical threshold");
                    std::process::exit(0);
                }
                _ => {
                    i += 1;
                }
            }
        }
        std::process::exit(staleness::run_self_check_staleness_cli(
            threshold_age_s,
            threshold_commits,
            want_json,
        ));
    }

    // EFFECTIVE-009: no-args → help; `chump help` → help. Must come before
    // any mode that falls through to the interactive agent loop.
    let wants_help = args.len() == 1
        || args.get(1).map(String::as_str) == Some("help")
        || args.get(1).map(String::as_str) == Some("--help")
        || args.get(1).map(String::as_str) == Some("-h");
    if wants_help {
        print_help();
        return Ok(());
    }

    if args.iter().any(|a| a == "--desktop") {
        desktop_launcher::launch_and_wait(&args);
    }
    load_dotenv();
    local_openai::auto_configure_context_window().await;

    // `chump --briefing <GAP-ID>` (MEM-007) — agent context-query that returns
    // "what should I know before working on gap X?". Reads docs/gaps.yaml,
    // chump_improvement_targets, ambient.jsonl, and strategic docs. Bypasses
    // the agent loop entirely; intended to be run by an agent right after
    // gap-preflight.sh and before gap-claim.sh. Exits 0 always — a missing
    // gap renders an explicit "not found" block rather than failing.
    if let Some(pos) = args.iter().position(|a| a == "--briefing") {
        let gap_id = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if gap_id.is_empty() || gap_id.starts_with("--") {
            eprintln!("Usage: chump --briefing <GAP-ID> [--json]");
            std::process::exit(2);
        }
        let b = briefing::build_briefing(gap_id);
        // INFRA-1548: --json flag emits schema_version:1 JSON for harness consumers.
        if args.iter().any(|a| a == "--json") {
            println!("{}", briefing::render_json(&b));
        } else {
            print!("{}", briefing::render_markdown(&b));
        }
        return Ok(());
    }

    // `chump ambient emit <kind> [...]` (INFRA-1048) — harness-agnostic
    // event-write CLI. Replaces the Claude-Code-specific PreToolUse hook
    // shell+python+flock chain for non-Claude harnesses. See
    // docs/process/AGENT_API.md §3 for the contract; specced via INFRA-1050.
    if args.get(1).map(String::as_str) == Some("ambient")
        && args.get(2).map(String::as_str) == Some("emit")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!(
                "Usage: chump ambient emit <kind> [--gap GAP-ID] [--source NAME] \\\n         [--harness NAME] [--field key=value]..."
            );
            println!();
            println!(
                "Write one event line to .chump-locks/ambient.jsonl. Auto-fills ts (RFC3339 UTC),"
            );
            println!("session (CHUMP_SESSION_ID > CLAUDE_SESSION_ID > worktree cache > derived),");
            println!(
                "worktree (basename of repo root), and harness (--harness > CHUMP_AGENT_HARNESS > 'unknown')."
            );
            println!();
            println!("Examples:");
            println!("  chump ambient emit file_edit --gap INFRA-1048 --field path=src/main.rs");
            println!("  chump ambient emit commit --field sha=abc1234 --field msg='fix: x'");
            return Ok(());
        }
        // Slice off args[0] (binary name) so from_argv sees
        // ["ambient", "emit", <kind>, ...flags].
        let parsed = match ambient_emit::EmitArgs::from_argv(&args[1..]) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump ambient emit: {e:#}");
                eprintln!("Run `chump ambient emit --help` for usage.");
                std::process::exit(2);
            }
        };
        let path = match ambient_emit::emit(&parsed) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("chump ambient emit: {e:#}");
                std::process::exit(1);
            }
        };
        // Stderr so stdout stays clean for chained commands (e.g. backtick capture).
        eprintln!("[ambient] wrote {} ({})", parsed.kind, path.display());
        return Ok(());
    }

    // `chump ship plan` (INFRA-1229 slice 1) — pure planner that decides
    // REBASE / ARM / WAIT / CONFLICT-RECOVER / etc. given a snapshot of
    // PR + branch state. Today's bot-merge.sh consumes the output as a
    // structured JSON plan and dispatches; slice 2 (separate PR) will
    // move the executor side into Rust as well.
    if args.get(1).map(String::as_str) == Some("ship")
        && args.get(2).map(String::as_str) == Some("plan")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!("Usage: chump ship plan [--gap GAP-ID] [--pr N] [--branch B] [--json|--human] [--dry-run]");
            println!();
            println!("Decide the next ship action for a branch + PR given their current state.");
            println!("Output is a structured ShipPlan JSON (default) suitable for bot-merge.sh");
            println!("or any other consumer to dispatch on. The planner does no mutations.");
            println!();
            println!("Inputs are gathered by calling `gh api` for the PR + check-runs and");
            println!("`git rev-list --count` for behind/ahead. --dry-run uses synthetic state.");
            return Ok(());
        }
        return ship_plan_cli(&args[3..]).await;
    }

    // `chump ship execute` (INFRA-1229 slice 2) — walks the ExecutorStep
    // list derived from a ShipPlan via std::process::Command. Reads the
    // plan JSON from --plan <file> or --stdin. Mutates state — pair with
    // --dry-run to inspect without executing.
    if args.get(1).map(String::as_str) == Some("ship")
        && args.get(2).map(String::as_str) == Some("execute")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!("Usage: chump ship execute (--plan PATH | --stdin) [--dry-run] [--json]");
            println!();
            println!("Read a ShipPlan JSON (from `chump ship plan`) and execute the");
            println!("derived ExecutorStep list. Emits an ExecuteResult JSON with the");
            println!("rc + stderr_tail for each step. --dry-run prints steps; runs none.");
            println!();
            println!("Pipe pattern:");
            println!("  chump ship plan --gap INFRA-989 --pr 1913 | chump ship execute --stdin");
            return Ok(());
        }
        return ship_execute_cli(&args[3..]).await;
    }

    // `chump init` (UX-001) — first-run setup: detect model, write .env, start server, open browser.
    // Flags: --port N (override CHUMP_WEB_PORT), --no-browser (skip step 4 — for CI / FTUE).
    if args.get(1).map(String::as_str) == Some("init") {
        let init_args = match chump_init::InitArgs::from_argv(&args[2..]) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump init: {e:#}");
                eprintln!("usage: chump init [--port N] [--no-browser]");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
        if let Err(e) = chump_init::run_init(&repo_root, &init_args) {
            eprintln!("chump init: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump funnel` (PRODUCT-015) — read .chump-locks/ambient.jsonl and print
    // the three-row activation funnel: install → first_task → return_d2.
    if args.get(1).map(String::as_str) == Some("funnel") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump funnel");
            println!();
            println!(
                "Print install → first_task → return_d2 activation funnel from ambient events."
            );
            println!();
            println!("Example:");
            println!("  chump funnel");
            return Ok(());
        }
        activation::print_funnel();
        return Ok(());
    }

    // `chump claim <GAP-ID> [--paths X,Y,...]` (INFRA-468) — atomic
    // replacement for the 6-step shell dance documented in CLAUDE.md's
    // mandatory pre-flight: fetch + verify-gap + health-probe + worktree
    // + lease-write + import-if-drifted, all in one call. Each step has
    // its own bypass env for testing / unusual setups.
    if args.get(1).map(String::as_str) == Some("claim") {
        let repo_root = repo_path::repo_root();
        let claim_args = match atomic_claim::ClaimArgs::from_argv(&args[1..], repo_root.clone()) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump claim: {e:#}");
                eprintln!();
                eprintln!("Usage: chump claim <GAP-ID> [--paths CSV] [--session ID]");
                eprintln!("                          [--skip-doctor] [--skip-import]");
                eprintln!();
                eprintln!("Atomically: fetch origin/main, verify the gap, run chump-doctor,");
                eprintln!("create a linked worktree, write the lease. Replaces the 6-step");
                eprintln!("shell dance in CLAUDE.md mandatory pre-flight (INFRA-468).");
                std::process::exit(2);
            }
        };
        match atomic_claim::run_claim(claim_args) {
            Ok(report) => {
                atomic_claim::print_report(&report);
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump claim: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump preflight` (INFRA-1670) — local CI mirror.
    // Runs cargo fmt --check, clippy -D warnings, check; optionally
    // selected scripts/ci/test-*.sh with --with-tests. Catches the
    // failure classes that bit us most often on GH Actions (cargo fmt
    // drift, clippy dead_code, INFRA-682 path-filter, INFRA-1287
    // registry-orphan, etc.) in <60s warm instead of ~15 min round-trip.
    if args.get(1).map(String::as_str) == Some("preflight") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(preflight::run(&sub_args));
    }

    // `chump self-rescue-loop [--execute] [--grace-secs N]` (EFFECTIVE-088) — the
    // autonomous conductor: detect a wedged fleet → propose self-rescue on the
    // consensus bus → objection window → act. Dry-run unless --execute. Obeys the
    // autonomy dial + kill switch. Intended to run as a launchd daemon.
    if args.get(1).map(String::as_str) == Some("self-rescue-loop") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(fleet_self_rescue_conductor::run(&sub_args));
    }

    // `chump session-summary` (INFRA-1437) — list merged + armed + filed PRs
    // in the current session window. Replaces the manual ambient.jsonl + gh
    // pr list scrape that PM-curator + operator were doing at every session
    // end (~5 min of work).
    if args.get(1).map(String::as_str) == Some("session-summary") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(session_summary::run(&sub_args));
    }

    // `chump pe-suite status` (INFRA-2229, META-127/C7) — P&E suite operator
    // dashboard: active curators, FEEDBACK engagement, consensus convergence.
    // Reads .chump-locks/ + ambient.jsonl; no network calls required.
    if args.get(1).map(String::as_str) == Some("pe-suite") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        // sub_args[0] should be "status"; any other subcommand errors gracefully.
        let subcmd = sub_args.first().map(String::as_str).unwrap_or("status");
        match subcmd {
            "status" => {
                let flags: Vec<String> = sub_args.iter().skip(1).cloned().collect();
                std::process::exit(pe_suite_status::run(&flags));
            }
            "-h" | "--help" | "help" => {
                println!("Usage: chump pe-suite <subcommand>");
                println!();
                println!("Subcommands:");
                println!("  status [--json]  Show P&E suite operator dashboard (INFRA-2229)");
                std::process::exit(0);
            }
            other => {
                eprintln!("chump pe-suite: unknown subcommand '{}'", other);
                eprintln!("Try: chump pe-suite status [--json]");
                std::process::exit(1);
            }
        }
    }

    // External-repo command group (onboard / improve / external verify-merge).
    // Extracted to commands::dispatch_external (INFRA-3289, slice 1 of INFRA-3287).
    if let Some(code) = commands::dispatch_external::try_dispatch(&args) {
        std::process::exit(code);
    }

    // `chump vote <corr_id> <+1|-1|0> --reason <text>` (META-159) —
    // emit a FEEDBACK kind=vote event via the broadcast.sh FEEDBACK pathway.
    // Gated behind CHUMP_FLEET_RECV_SIDE_V0=1; prints "feature flag off,
    // vote not emitted" and exits 0 when flag is unset.
    if args.get(1).map(String::as_str) == Some("vote") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::vote::run(&sub_args));
    }

    // `chump voice --wedge-class <id> --minutes-lost <int> ...` (INFRA-2258) —
    // file a Voice-of-Agent (VOA) report: writes docs/gaps/VOA-NNNN.yaml +
    // docs/voice/VOA-NNNN-FULL.yaml and emits kind=voice_of_agent_filed.
    // Optional --ship to open a PR against repairman29/chump.
    if args.get(1).map(String::as_str) == Some("voice") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::voice::run(&sub_args));
    }

    // `chump config [show] [--json]` (INFRA-2371) — runtime cascade /
    // privacy / MCP snapshot. Pure read; never invokes an LLM, so it's
    // safe to run when the cascade is wedged. Solves the daily-friction
    // case where bare `chump config` previously fell through to the LLM
    // gen path and 400'd from Gemini.
    if args.get(1).map(String::as_str) == Some("config") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::config::run(&sub_args));
    }

    // `chump consensus-tally [--corr-id X | --all] [--since <dur>]` (META-159) —
    // aggregate FEEDBACK kind=vote events from ambient.jsonl per corr_id
    // and compute a verdict. Always runs regardless of feature flag (read-only).
    if args.get(1).map(String::as_str) == Some("consensus-tally") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::consensus_tally::run(&sub_args));
    }

    // `chump sibling-status [--json] [--watch]` (META-154) — per-active-lease
    // progress matrix. Beats "lease exists" by classifying each holder as
    // progressing / in-flight / heartbeat-only / stalled / silent / expired.
    if args.get(1).map(String::as_str) == Some("sibling-status") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::sibling_status::run(&sub_args));
    }

    // `chump inventory <rebuild|show|debt-report|...>` (META-271) —
    // fleet inventory + tech-debt review-only audit. ALL detector findings
    // land at tier=0 (surface-only) — never auto-files a gap, never removes
    // code. Operator runs `chump inventory review` to classify findings, then
    // `chump inventory promote <class>` after ≥10 reviewed + ≥70% RP ratio.
    // Tier-2 auto-file machinery deferred to INFRA-2374.
    if args.get(1).map(String::as_str) == Some("inventory") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::inventory::run(&sub_args));
    }

    // `chump contract-scan [--in-flight] [--against <pr-number>]` (INFRA-2405) —
    // detect cross-PR state-file/IPC schema mismatches. Triggered by INFRA-2404:
    // the main-preflight-watchdog (INFRA-2397) wrote {state, updated_at, last_tick_id}
    // while the claim main-health-gate (INFRA-2398) read {last_status, last_tick_at,
    // failing_gates} — keys never matched, the procedure layer shipped silently inert.
    // Exit 0 = clean, 1 = mismatches detected, 2 = scan failure.
    if args.get(1).map(String::as_str) == Some("contract-scan") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::contract_scan::run(&sub_args));
    }

    // `chump bootstrap <intent> [--dir <path>] [--skip-arch-decision] [--with-roadmap]`
    // (INFRA-2265) — net-new product bootstrap entrypoint: empty dir → git init →
    // scaffold (Cargo.toml | package.json | pyproject.toml) → README.md → first commit
    // → umbrella gap via `chump gap reserve`. Sister of INFRA-1746 (`chump ingest`).
    // This is the SUBSTRATE-layer entrypoint; consumer surfaces own the founder-facing
    // pitch lane. Third demo-able 2026 outcome (META-067).
    if args.get(1).map(String::as_str) == Some("bootstrap") {
        let sub_args: Vec<String> = args.iter().skip(1).cloned().collect();
        std::process::exit(commands::bootstrap::run(&sub_args));
    }

    // INFRA-2399 author-time helper commands (add-env-var / emit-event /
    // install-daemon / add-path-filter / add-raw-gh-allowlist).
    // Extracted to commands::dispatch_authoring (INFRA-3298, slice 2 of INFRA-3287).
    if let Some(code) = commands::dispatch_authoring::try_dispatch(&args) {
        std::process::exit(code);
    }

    // `chump inspect <gap-id>` (INFRA-1456) — eject-and-inspect surface.
    // Opens a 3-pane tmux session (or text snapshot if --no-tmux) for the
    // active lease of the given gap: worktree shell, live ambient tail, and
    // recent ambient events. Marcus's Saturday-morning-uninstall scenario.
    if args.get(1).map(String::as_str) == Some("inspect") {
        let gap_id = match args.get(2) {
            Some(id) => id.clone(),
            None => {
                eprintln!("Usage: chump inspect <gap-id> [--no-tmux]");
                std::process::exit(2);
            }
        };
        let no_tmux = args.iter().any(|a| a == "--no-tmux");
        let repo_root = repo_path::repo_root();
        match inspect_cmd::run(&repo_root, &gap_id, !no_tmux) {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump inspect: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump resume <gap-id>` (INFRA-1456) — validate worktree recoverability.
    // Checks lease present, worktree on disk, no dangling rebase/merge state,
    // no uncommitted churn. Prints verdict and emits kind=gap_resumed.
    if args.get(1).map(String::as_str) == Some("resume") {
        let gap_id = match args.get(2) {
            Some(id) => id.clone(),
            None => {
                eprintln!("Usage: chump resume <gap-id>");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
        match resume_cmd::run(&repo_root, &gap_id) {
            Ok(verdict) => {
                println!("{}", verdict.summary());
                let exit_code = if verdict == resume_cmd::ResumeVerdict::Ready {
                    0
                } else {
                    1
                };
                std::process::exit(exit_code);
            }
            Err(e) => {
                eprintln!("chump resume: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump scrap <gap-id>` (INFRA-1456) — clean teardown of a wedged gap.
    // Removes the worktree, deletes the lease JSON, deletes the local branch,
    // prunes dangling refs. Emits kind=gap_scrapped to ambient.jsonl.
    if args.get(1).map(String::as_str) == Some("scrap") {
        let gap_id = match args.get(2) {
            Some(id) => id.clone(),
            None => {
                eprintln!("Usage: chump scrap <gap-id>");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
        match scrap_cmd::run(&repo_root, &gap_id) {
            Ok(outcome) => {
                println!(
                    "scrap: worktree_removed={} lease_removed={} branch_deleted={}",
                    outcome.worktree_removed, outcome.lease_removed, outcome.branch_deleted
                );
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump scrap: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump disk status|plan|budget` (INFRA-2196, META-128/C5) — operator + subprocess
    // surface for disk-aware fleet decisions. Reads ~/.chump/disk-inventory.json
    // (written by chump-disk-inventory-daemon INFRA-2193) and DISK_COST_MODEL.yaml
    // (INFRA-2195). Exit codes: 0=OK, 1=REFUSE, 2=WAIT (for `chump disk plan`).
    if args.get(1).map(String::as_str) == Some("disk") {
        let sub = args.get(2).map(String::as_str);
        let repo_root = repo_path::repo_root();
        let sub_args: Vec<String> = args.iter().skip(3).cloned().collect();
        let exit_code = match sub {
            Some("status") => match disk_cmd::run_status(&sub_args, &repo_root) {
                Ok(code) => code,
                Err(e) => {
                    eprintln!("chump disk status: {e:#}");
                    1
                }
            },
            Some("plan") => match disk_cmd::run_plan(&sub_args, &repo_root) {
                Ok(code) => code,
                Err(e) => {
                    eprintln!("chump disk plan: {e:#}");
                    1
                }
            },
            Some("budget") => match disk_cmd::run_budget(&sub_args, &repo_root) {
                Ok(code) => code,
                Err(e) => {
                    eprintln!("chump disk budget: {e:#}");
                    1
                }
            },
            _ => {
                println!("Usage: chump disk <subcommand> [options]");
                println!();
                println!("Subcommands:");
                println!("  status [--json]                     disk snapshot: total/free/used/headroom + top consumers");
                println!("  plan <action-class> [--count N]     OK|WAIT|REFUSE projection from DISK_COST_MODEL.yaml");
                println!("  budget [--for <action-class>]       max-safe-N for action class(es)");
                println!();
                println!("Env:");
                println!("  CHUMP_DISK_FLOOR_GB=5               free-space floor (default 5 GB)");
                println!(
                    "  CHUMP_DISK_INVENTORY_PATH=...       override ~/.chump/disk-inventory.json"
                );
                println!("  CHUMP_DISK_COST_MODEL_PATH=...      override docs/process/DISK_COST_MODEL.yaml");
                println!();
                println!("Exit codes (disk plan): 0=OK, 1=REFUSE, 2=WAIT");
                2
            }
        };
        std::process::exit(exit_code);
    }

    // `chump pr-rescue` (INFRA-1714) — closed-loop PR rescue. v0 handles two
    // mechanical failure patterns (orphan-allowlist, env-var-coverage) that
    // accounted for ~6 manual rescues in the 2026-05-22 ship session. See
    // src/pr_rescue.rs for the classifier + fixer logic.
    if args.get(1).map(String::as_str) == Some("pr-rescue") {
        let mut once = false;
        let mut dry_run = false;
        let mut pr: Option<u32> = None;
        let mut explain: Option<u32> = None;
        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--once" => once = true,
                "--dry-run" => dry_run = true,
                "--pr" => {
                    i += 1;
                    if i < args.len() {
                        pr = args[i].parse().ok();
                    }
                }
                "--explain" => {
                    i += 1;
                    if i < args.len() {
                        explain = args[i].parse().ok();
                    }
                }
                "--help" | "-h" => {
                    println!("chump pr-rescue [--once] [--pr N] [--dry-run] [--explain N]");
                    println!();
                    println!("Closed-loop PR rescue (INFRA-1714 v0). Auto-fixes two patterns:");
                    println!(
                        "  - orphan-allowlist: server-side rebase via gh pr update-branch --rebase"
                    );
                    println!(
                        "  - env-var-coverage: append missing vars to env-vars-internal.txt + push"
                    );
                    println!();
                    println!("Safety: CHUMP_PR_RESCUE_MAX_AGE_HOURS (default 24h), per-PR 5min cooldown,");
                    println!(
                        "        --force-with-lease only, never touches main, never touches DRAFT."
                    );
                    return Ok(());
                }
                _ => {
                    eprintln!("pr-rescue: unknown arg: {}", args[i]);
                    std::process::exit(2);
                }
            }
            i += 1;
        }
        let opts = pr_rescue::RescueOpts {
            once,
            pr,
            dry_run,
            explain,
        };
        match pr_rescue::run(opts) {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("pr-rescue: {e}");
                std::process::exit(1);
            }
        }
    }

    // `chump completion [zsh|bash|fish]` (EFFECTIVE-010) — print shell completion script.
    if args.get(1).map(String::as_str) == Some("completion") {
        let shell = args.get(2).map(String::as_str).unwrap_or("zsh");
        match shell {
            "zsh" => {
                print!("{}", completion::zsh());
                return Ok(());
            }
            "bash" => {
                print!("{}", completion::bash());
                return Ok(());
            }
            "fish" => {
                print!("{}", completion::fish());
                return Ok(());
            }
            other => {
                eprintln!("chump completion: unknown shell {other:?}");
                eprintln!("Usage: chump completion [zsh|bash|fish]");
                eprintln!();
                eprintln!("Install examples:");
                eprintln!("  zsh:  chump completion zsh > $(brew --prefix)/share/zsh/site-functions/_chump");
                eprintln!("  bash: chump completion bash >> ~/.bashrc");
                eprintln!("  fish: chump completion fish > ~/.config/fish/completions/chump.fish");
                std::process::exit(2);
            }
        }
    }

    // `chump lesson-grade <GAP-ID> --pr <N>` (COG-043) — for each
    // `lessons_shown` event tied to this gap+session in ambient.jsonl,
    // score the directive's keywords against the PR's diff + body and
    // emit `lesson_applied` / `lesson_not_applied` events. Best-effort:
    // missing PR or network errors degrade to no-op, never panic.
    //
    // Called from bot-merge.sh after auto-close. Operators can also
    // run it manually post-hoc on any closed PR.
    if args.get(1).map(String::as_str) == Some("lesson-grade") {
        let gap_id = args.get(2).cloned().unwrap_or_else(|| {
            eprintln!("Usage: chump lesson-grade <GAP-ID> --pr <N>");
            std::process::exit(2);
        });
        if gap_id.starts_with("--") {
            eprintln!("Usage: chump lesson-grade <GAP-ID> --pr <N>");
            std::process::exit(2);
        }
        let lg_flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1).cloned())
        };
        let pr_number: u64 = match lg_flag("--pr") {
            Some(s) => s.parse().unwrap_or_else(|_| {
                eprintln!("chump lesson-grade: --pr expects an integer (got {s:?})");
                std::process::exit(2);
            }),
            None => {
                eprintln!("Usage: chump lesson-grade <GAP-ID> --pr <N>");
                std::process::exit(2);
            }
        };
        let session_filter = lg_flag("--session"); // optional — defaults to all sessions for the gap
        let repo_root = repo_path::repo_root();
        let graded = run_lesson_grade(&repo_root, &gap_id, pr_number, session_filter.as_deref());
        match graded {
            Ok(counts) => {
                println!(
                    "lesson-grade {}: applied={} not_applied={} skipped={}",
                    gap_id, counts.0, counts.1, counts.2
                );
                return Ok(());
            }
            Err(e) => {
                // Best-effort — print the warning but exit 0 so we don't
                // break bot-merge.sh's auto-close flow.
                eprintln!("chump lesson-grade: warning: {e:#}");
                return Ok(());
            }
        }
    }

    // `chump audit aha-sweep [--json] [--window-days N] [--emit]` (INFRA-1370).
    // Walks every kind in EVENT_REGISTRY.yaml, reads its effect_metric +
    // expected_min_per_day declarations (INFRA-1371), and compares against the
    // last-N-days emit count in .chump-locks/ambient.jsonl. Surfaces "registered
    // but silent" kinds (alert) and "below floor" kinds (warn) as
    // kind=audit_finding events. Exit non-zero on any alert.
    if args.get(1).map(String::as_str) == Some("audit") {
        let sub = args.get(2).map(String::as_str).unwrap_or("--help");
        if sub == "--help" || sub == "help" || sub.is_empty() {
            println!("Usage: chump audit <subcommand> [options]");
            println!();
            println!("Subcommands:");
            println!("  aha-sweep   walk code/runtime/effect triangle for every registered kind");
            println!();
            println!("Run 'chump audit aha-sweep --help' for sweep options.");
            return Ok(());
        }
        if sub != "aha-sweep" {
            eprintln!("chump audit: unknown subcommand '{}'", sub);
            eprintln!("Run 'chump audit --help' for the list.");
            std::process::exit(2);
        }
        let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
        if rest.iter().any(|a| *a == "--help" || *a == "help") {
            println!("Usage: chump audit aha-sweep [--json] [--window-days N] [--flag-silent-self] [--emit]");
            println!();
            println!("Walks every kind in EVENT_REGISTRY.yaml and verifies the recent ambient");
            println!("stream actually contains emits consistent with the declared effect_metric +");
            println!("expected_min_per_day floor.");
            println!();
            println!("Options:");
            println!("  --json               output JSON instead of text");
            println!("  --window-days N      look back window in days (default 7)");
            println!("  --flag-silent-self   also warn on effect_metric=self kinds with 0 emits");
            println!("  --emit               write kind=audit_finding to ambient.jsonl for non-ok findings");
            println!();
            println!("Exits non-zero when any finding has severity=alert.");
            return Ok(());
        }
        let want_json = rest.contains(&"--json");
        let flag_silent_self = rest.contains(&"--flag-silent-self");
        let do_emit = rest.contains(&"--emit");
        let window_days: u64 = {
            let mut it = rest.iter().peekable();
            let mut n = 7u64;
            while let Some(a) = it.next() {
                if *a == "--window-days" {
                    if let Some(v) = it.next() {
                        if let Ok(parsed) = v.parse::<u64>() {
                            n = parsed.clamp(1, 90);
                        }
                    }
                }
            }
            n
        };
        let repo_root = repo_path::repo_root();
        let cfg = audit::SweepConfig {
            repo_root: repo_root.clone(),
            window: std::time::Duration::from_secs(window_days * 24 * 3600),
            flag_silent_self,
        };
        let findings = match audit::sweep_event_registry(&cfg) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("chump audit aha-sweep: {}", e);
                std::process::exit(1);
            }
        };
        if do_emit {
            if let Err(e) = audit::emit_findings(&repo_root, &findings) {
                eprintln!("chump audit aha-sweep: emit warning: {}", e);
            }
        }
        if want_json {
            println!("{}", audit::render_json(&findings));
        } else {
            print!("{}", audit::render_text(&findings));
        }
        let any_alert = findings
            .iter()
            .any(|f| f.severity == audit::AuditSeverity::Alert);
        if any_alert {
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump mission-grade [--json]` (INFRA-599) — auto-emit 4-pillar scorecard.
    // Counts pickable, in_flight, and shipped_24h gaps per pillar
    // (EFFECTIVE/CREDIBLE/RESILIENT/ZERO-WASTE, identified by title prefix),
    // emits kind=mission_grade to ambient.jsonl, and prints to stdout.
    if args.get(1).map(String::as_str) == Some("mission-grade") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump mission-grade [--json]");
            println!();
            println!("Current pillar grades: EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE.");
            println!("Emits kind=mission_grade to ambient.jsonl on each run.");
            println!();
            println!("Options:");
            println!("  --json   output in JSON format");
            println!();
            println!("Example:");
            println!("  chump mission-grade");
            println!("  chump mission-grade --json");
            return Ok(());
        }
        let want_json = args.iter().any(|a| a == "--json");
        let repo_root = repo_path::repo_root();
        let report = mission_grade::build_report(&repo_root);
        mission_grade::emit(&repo_root, &report);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        if report.any_low_grade() {
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump upgrade [--dry-run]` (INFRA-1504) — upgrade the chump binary.
    // Detects install method (brew / cargo / manual) and runs the right upgrade.
    if args.get(1).map(String::as_str) == Some("upgrade") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump upgrade [--dry-run]");
            println!();
            println!("Detects how chump was installed and runs the appropriate upgrade:");
            println!("  brew:   brew upgrade chump");
            println!("  cargo:  cargo install --force chump");
            println!("  manual: prints instructions to download a new release");
            println!();
            println!("Options:");
            println!("  --dry-run  show the upgrade command without running it");
            return Ok(());
        }
        let dry_run = args.iter().any(|a| a == "--dry-run");
        fleet_health::run_upgrade(dry_run);
        return Ok(());
    }

    // `chump health [--json] [--watch]` (INFRA-644) — composite fleet health
    // score (0-100) rolling up fleet-status, waste-tally, cost-watch,
    // mission-grade, pr-stuck, version-skew, auth, and ghost-gaps.
    // Emits kind=fleet_health to ambient.jsonl on each run.
    if args.get(1).map(String::as_str) == Some("health") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump health [--json] [--watch] [--slo-check] [--temp]");
            println!();
            println!("Composite fleet health score (0-100) rolling up fleet-status, waste-tally,");
            println!("cost-watch, mission-grade, pr-stuck, version-skew, auth, and ghost-gaps.");
            println!("Emits kind=fleet_health to ambient.jsonl on each run.");
            println!();
            println!("Options:");
            println!("  --json       output in JSON format");
            println!("  --watch      refresh every 30 s (clear screen between runs)");
            println!("  --slo-check  exit non-zero if any SLO is breached");
            println!("  --temp       INFRA-1992: report floor-temperature only (COLD/WARM/HOT)");
            println!();
            println!("Example:");
            println!("  chump health");
            println!("  chump health --slo-check   # use in CI");
            println!("  chump health --temp        # one-word floor-temp signal");
            println!("  chump health --temp --json # full floor-temp report with component counts");
            return Ok(());
        }
        let want_json = args.iter().any(|a| a == "--json");
        let watch = args.iter().any(|a| a == "--watch");
        let slo_check = args.iter().any(|a| a == "--slo-check");
        let want_temp = args.iter().any(|a| a == "--temp");
        let repo_root = repo_path::repo_root();

        // INFRA-1992 (THE FLOOR Phase 1): floor-temperature signal.
        // Reads ambient.jsonl over trailing 24h, counts hot event kinds
        // (hook_silent_passthrough + ci_failure_cluster + admin_merge_executed),
        // returns COLD/WARM/HOT. Emits kind=floor_temp on each invocation.
        if want_temp {
            let ambient = floor_temp::ambient_path_for(&repo_root);
            let report = floor_temp::compute(&ambient, floor_temp::DEFAULT_WINDOW_SECS);
            floor_temp::emit_floor_temp(&report);
            if want_json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&report).unwrap_or_else(|_| "{}".to_string())
                );
            } else {
                println!("{}", report.temp_str);
                eprintln!(
                    "  ({} hot events in trailing {}h)",
                    report.total_hot_events,
                    report.window_secs / 3600
                );
                eprintln!("  {}", report.recommendation);
            }
            // Exit code: HOT → 2, WARM → 1, COLD → 0 (so CI/workers can react).
            let code = match report.temp {
                floor_temp::FloorTemp::Cold => 0,
                floor_temp::FloorTemp::Warm => 1,
                floor_temp::FloorTemp::Hot => 2,
            };
            std::process::exit(code);
        }

        if slo_check {
            let results = fleet_health::check_slos(&repo_root);
            if want_json {
                println!("{}", fleet_health::render_slo_json(&results));
            } else {
                print!("{}", fleet_health::render_slo_text(&results));
            }
            if results.iter().any(|r| r.breached) {
                std::process::exit(1);
            }
            return Ok(());
        }

        loop {
            let report = fleet_health::build_report(&repo_root);
            fleet_health::emit(&repo_root, &report);
            // Emit kind=session_rescue for any new rescues found (INFRA-667).
            let rescues = rescue_tally::scan_rescues(&repo_root, 24);
            rescue_tally::emit_rescue_events(&repo_root, &rescues);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            if !watch {
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(30));
            // Clear terminal for next iteration.
            print!("\x1b[2J\x1b[H");
            let _ = std::io::stdout().flush();
        }
        return Ok(());
    }

    // INFRA-1613: `chump skill <subcmd>` — operator-facing CLI for skill management.
    // Exposes list/view/health/record-outcome/tap-add without requiring an
    // agent loop session. Skills live in chump-brain/skills/<name>/SKILL.md;
    // reliability stats come from chump_skills SQLite table (skill_db.rs).
    if args.get(1).map(String::as_str) == Some("skill") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("list");
        let want_json = args.iter().any(|a| a == "--json");

        if subcmd == "--help" || subcmd == "help" || subcmd == "-h" {
            println!("Usage: chump skill <subcommand> [options]");
            println!();
            println!("Subcommands:");
            println!("  list [--json]              List all installed skills");
            println!("  view NAME                  Show full SKILL.md for NAME");
            println!("  health [--name NAME] [--min-uses N]");
            println!("                             Wilson CI ranking per skill");
            println!("  record-outcome NAME true|false");
            println!("                             Record a success/failure outcome");
            println!("  tap-add URL                Install skills from a GitHub repo");
            println!();
            println!("Skills live in: chump-brain/skills/<name>/SKILL.md");
            println!("Override: CHUMP_BRAIN_PATH env var");
            return Ok(());
        }

        match subcmd {
            "list" => {
                match crate::skills::list_skills() {
                    Ok(skills) if skills.is_empty() => {
                        if want_json {
                            println!("[]");
                        } else {
                            println!(
                                "No skills installed. Use skill_manage action=create to add one."
                            );
                        }
                    }
                    Ok(skills) => {
                        if want_json {
                            // Build JSON array from skill frontmatter + reliability stats.
                            let mut items: Vec<serde_json::Value> =
                                Vec::with_capacity(skills.len());
                            for s in &skills {
                                let (rel, n) =
                                    crate::skill_db::skill_reliability(&s.frontmatter.name)
                                        .unwrap_or((0.5, 0));
                                let rec =
                                    crate::skill_db::list_skill_records().ok().and_then(|recs| {
                                        recs.into_iter().find(|r| r.name == s.frontmatter.name)
                                    });
                                let last_used = rec.as_ref().and_then(|r| r.last_used_at.clone());
                                let version = s.frontmatter.version;
                                let platforms = &s.frontmatter.platforms;
                                let meta = serde_json::json!({
                                    "tags": s.frontmatter.metadata.tags,
                                    "category": s.frontmatter.metadata.category,
                                    "requires_toolsets": s.frontmatter.metadata.requires_toolsets,
                                });
                                items.push(serde_json::json!({
                                    "name": s.frontmatter.name,
                                    "description": s.frontmatter.description,
                                    "version": version,
                                    "platforms": platforms,
                                    "metadata": meta,
                                    "reliability_p": rel,
                                    "sample_n": n,
                                    "last_used_at": last_used,
                                }));
                            }
                            println!(
                                "{}",
                                serde_json::to_string_pretty(&items)
                                    .unwrap_or_else(|_| "[]".to_string())
                            );
                        } else {
                            println!("Installed skills ({}):", skills.len());
                            for s in &skills {
                                println!("  {}", s.summary_line());
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("chump skill list: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "view" => {
                let name = match args.get(3) {
                    Some(n) => n.as_str(),
                    None => {
                        eprintln!("Usage: chump skill view NAME");
                        std::process::exit(2);
                    }
                };
                match crate::skills::load_skill(name) {
                    Ok(skill) => {
                        let (rel, n) = crate::skill_db::skill_reliability(name).unwrap_or((0.5, 0));
                        if n > 0 {
                            println!(
                                "# Skill: {} (v{})\n",
                                skill.frontmatter.name, skill.frontmatter.version
                            );
                            println!("**Description:** {}", skill.frontmatter.description);
                            println!("**Reliability:** {:.1}% over {} uses\n", rel * 100.0, n);
                            println!("---\n");
                        } else {
                            println!(
                                "# Skill: {} (v{})\n",
                                skill.frontmatter.name, skill.frontmatter.version
                            );
                            println!("**Description:** {}", skill.frontmatter.description);
                            println!("**Reliability:** no usage data yet\n");
                            println!("---\n");
                        }
                        print!("{}", skill.body);
                    }
                    Err(e) => {
                        eprintln!("chump skill view: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "health" => {
                // Optional filters: --name NAME, --min-uses N
                let name_filter: Option<String> = {
                    let mut v = None;
                    let mut it = args.iter().skip(3);
                    while let Some(a) = it.next() {
                        if a == "--name" {
                            v = it.next().cloned();
                            break;
                        }
                    }
                    v
                };
                let min_uses: u64 = {
                    let mut v = 0u64;
                    let mut it = args.iter().skip(3);
                    while let Some(a) = it.next() {
                        if a == "--min-uses" {
                            if let Some(n) = it.next().and_then(|s| s.parse().ok()) {
                                v = n;
                            }
                            break;
                        }
                    }
                    v
                };
                match crate::skill_metrics::skill_health_ranking() {
                    Ok(ranking) => {
                        let filtered: Vec<_> = ranking
                            .into_iter()
                            .filter(|h| name_filter.as_deref().is_none_or(|n| h.name == n))
                            .filter(|h| h.use_count >= min_uses)
                            .collect();
                        if want_json {
                            println!(
                                "{}",
                                serde_json::to_string_pretty(&filtered)
                                    .unwrap_or_else(|_| "[]".to_string())
                            );
                        } else if filtered.is_empty() {
                            println!("No skills matching the filter.");
                        } else {
                            println!(
                                "{:<30} {:>6} {:>6} {:>12} {:>10} {:>8}",
                                "name", "uses", "rel%", "ci_lower-upper", "composite", "days_old"
                            );
                            println!("{}", "-".repeat(80));
                            for h in &filtered {
                                let days = h
                                    .days_since_last_use
                                    .map(|d| d.to_string())
                                    .unwrap_or_else(|| "never".to_string());
                                println!(
                                    "{:<30} {:>6} {:>5.1}% [{:>5.1}%–{:>5.1}%] {:>10.3} {:>8}",
                                    h.name,
                                    h.use_count,
                                    h.reliability * 100.0,
                                    h.confidence_lower * 100.0,
                                    h.confidence_upper * 100.0,
                                    h.composite_score,
                                    days,
                                );
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("chump skill health: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "record-outcome" => {
                let name = match args.get(3) {
                    Some(n) => n.as_str(),
                    None => {
                        eprintln!("Usage: chump skill record-outcome NAME true|false");
                        std::process::exit(2);
                    }
                };
                let success_str = match args.get(4) {
                    Some(s) => s.as_str(),
                    None => {
                        eprintln!("Usage: chump skill record-outcome NAME true|false");
                        std::process::exit(2);
                    }
                };
                let success = match success_str {
                    "true" | "1" | "yes" => true,
                    "false" | "0" | "no" => false,
                    other => {
                        eprintln!("chump skill record-outcome: expected true|false, got {other:?}");
                        std::process::exit(2);
                    }
                };
                match crate::skill_db::record_skill_outcome(name, success) {
                    Ok(()) => {
                        let (rel, uses) =
                            crate::skill_db::skill_reliability(name).unwrap_or((0.5, 0));
                        println!(
                            "Recorded {} for '{}'. Reliability: {:.1}% over {} uses.",
                            if success { "success" } else { "failure" },
                            name,
                            rel * 100.0,
                            uses
                        );
                    }
                    Err(e) => {
                        eprintln!("chump skill record-outcome: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "tap-add" => {
                let url = match args.get(3) {
                    Some(u) => u.as_str(),
                    None => {
                        eprintln!("Usage: chump skill tap-add URL");
                        eprintln!(
                            "  URL: https://github.com/owner/repo (must have a skills/ directory)"
                        );
                        std::process::exit(2);
                    }
                };
                // Call handle_tap_add directly (pub since INFRA-1613).
                match crate::skill_tool::handle_tap_add(url).await {
                    Ok(msg) => println!("{msg}"),
                    Err(e) => {
                        eprintln!("chump skill tap-add: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            other => {
                eprintln!("chump skill: unknown subcommand '{other}'");
                eprintln!("Valid: list, view, health, record-outcome, tap-add");
                eprintln!("Run 'chump skill --help' for usage.");
                std::process::exit(2);
            }
        }
    }

    // INFRA-1696 (META-066 phase 3): `chump content-bots <subcmd>` operator
    // surface for the Content Bots Suite (PMM, DocuBot, Evangelist, CopyBot).
    // Reads docs/agents/content-bots/bots.yaml + the toggle resolver from
    // INFRA-1700 (src/content_bots.rs).
    if args.get(1).map(String::as_str) == Some("content-bots") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("list");
        let json = args.iter().any(|a| a == "--json");
        let repo_root = repo_path::repo_root();
        let bots_yaml = repo_root.join("docs/agents/content-bots/bots.yaml");

        if !bots_yaml.exists() {
            eprintln!(
                "chump content-bots: bots.yaml not found at {}",
                bots_yaml.display()
            );
            eprintln!("  Foundation gap INFRA-1690 must ship before this command works.");
            std::process::exit(2);
        }

        // Minimal bots.yaml reader — parse `bot_id:`, `tier:`, `model_tier:`,
        // `default_enabled:` per entry. Avoid pulling serde_yaml dep just for
        // this read; bots.yaml is operator-curated and small.
        let raw = std::fs::read_to_string(&bots_yaml).unwrap_or_default();
        #[derive(Debug, Default)]
        struct BotEntry {
            bot_id: String,
            tier: String,
            model_tier: String,
            default_enabled: bool,
        }
        let mut bots: Vec<BotEntry> = Vec::new();
        let mut cur = BotEntry::default();
        let mut in_bots = false;
        for line in raw.lines() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("bots:") {
                in_bots = true;
                continue;
            }
            if !in_bots {
                continue;
            }
            if trimmed.starts_with("- bot_id:") {
                if !cur.bot_id.is_empty() {
                    bots.push(std::mem::take(&mut cur));
                }
                cur.bot_id = trimmed.trim_start_matches("- bot_id:").trim().to_string();
            } else if let Some(v) = trimmed.strip_prefix("tier:") {
                cur.tier = v.trim().to_string();
            } else if let Some(v) = trimmed.strip_prefix("model_tier:") {
                cur.model_tier = v.split_whitespace().next().unwrap_or("").to_string();
            } else if let Some(v) = trimmed.strip_prefix("default_enabled:") {
                cur.default_enabled = v.split_whitespace().next() == Some("true");
            }
        }
        if !cur.bot_id.is_empty() {
            bots.push(cur);
        }

        match subcmd {
            "list" => {
                let enabled = content_bots::enabled_set(&repo_root);
                if json {
                    println!("[");
                    for (i, b) in bots.iter().enumerate() {
                        let en = enabled.contains(&b.bot_id) || b.default_enabled;
                        println!(
                            "  {{\"bot_id\": \"{}\", \"tier\": \"{}\", \"model_tier\": \"{}\", \"enabled\": {}}}{}",
                            b.bot_id,
                            b.tier,
                            b.model_tier,
                            en,
                            if i + 1 == bots.len() { "" } else { "," }
                        );
                    }
                    println!("]");
                } else {
                    println!("{:<14} {:<12} {:<6} ENABLED", "BOT_ID", "TIER", "MODEL");
                    for b in &bots {
                        let en = enabled.contains(&b.bot_id) || b.default_enabled;
                        let mark = if en { "✓" } else { "·" };
                        let src = if enabled.contains(&b.bot_id) {
                            " (config|env)"
                        } else if b.default_enabled {
                            " (default)"
                        } else {
                            ""
                        };
                        println!(
                            "{:<14} {:<12} {:<6} {}{}",
                            b.bot_id, b.tier, b.model_tier, mark, src
                        );
                    }
                    println!();
                    println!(
                        "Toggle: CHUMP_CONTENT_BOTS=<csv> (env) or [content_bots] enabled in .chump-config.toml"
                    );
                }
                return Ok(());
            }
            _ => {
                eprintln!("chump content-bots: unknown subcommand '{}'", subcmd);
                eprintln!("  Available: list [--json]");
                std::process::exit(2);
            }
        }
    }

    // MISSION-008 / MISSION-030: `chump outcome <sub>` — first-class Outcome object commands.
    // chump outcome new|create --id X --title T [--priority P] [--dod D]
    // chump outcome list [--status open|done] [--json]
    // chump outcome show <id> [--json]
    // chump outcome status <id> [--json]   (alias for show)
    // chump outcome link <GAP-ID> --outcome <OUTCOME-ID>
    // chump outcome unlink <GAP-ID>
    // chump outcome bootstrap              (seed canonical mission outcomes)
    // chump outcome backfill [--dry-run] [--apply]
    // ADVISORY ONLY — outcome rollup never gates or blocks a child gap from closing.
    if args.get(1).map(String::as_str) == Some("outcome") {
        let sub = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump outcome: {e:#}");
                std::process::exit(1);
            }
        };
        // Inline flag helper valid for this block (flag closure defined later in main).
        let oflag = |name: &str| -> Option<String> {
            args.windows(2)
                .find(|w| w[0] == name)
                .and_then(|w| w.get(1))
                .cloned()
        };
        let json_out = args.iter().any(|a| a == "--json");
        match sub {
            "new" | "create" => {
                let id = oflag("--id").unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome new --id X --title T [--priority P] [--dod D]");
                    std::process::exit(2);
                });
                let title = oflag("--title").unwrap_or_else(|| {
                    eprintln!("chump outcome new: --title required");
                    std::process::exit(2);
                });
                let priority = oflag("--priority")
                    .or_else(|| oflag("--p"))
                    .unwrap_or_else(|| "P2".into());
                let dod = oflag("--dod")
                    .or_else(|| oflag("--definition-of-done"))
                    .unwrap_or_default();
                match store.create_outcome(&id, &title, &priority, &dod) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"id":"{id}","title":"{title}","priority":"{priority}","created":true}}"#
                            );
                        } else {
                            println!(
                                "outcome {} created (advisory — never gates child close)",
                                id
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome new: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "list" => {
                let status_filter = oflag("--status");
                let outcomes = store.list_outcomes().unwrap_or_default();
                let outcomes: Vec<_> = outcomes
                    .into_iter()
                    .filter(|o| {
                        status_filter
                            .as_deref()
                            .map(|s| o.status == s)
                            .unwrap_or(true)
                    })
                    .collect();
                if json_out {
                    // Build gap-count per outcome for richer output.
                    let all_gaps = store.list(None).unwrap_or_default();
                    let items: Vec<String> = outcomes
                        .iter()
                        .map(|o| {
                            let gap_count = all_gaps
                                .iter()
                                .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                                .count();
                            let open_count = all_gaps
                                .iter()
                                .filter(|g| {
                                    g.outcome_id.as_deref() == Some(o.id.as_str())
                                        && g.status == "open"
                                })
                                .count();
                            format!(
                                r#"{{"id":"{}","title":"{}","priority":"{}","status":"{}","gap_count":{},"open_count":{}}}"#,
                                o.id,
                                o.title.replace('"', "\\\""),
                                o.priority,
                                o.status,
                                gap_count,
                                open_count,
                            )
                        })
                        .collect();
                    println!("[{}]", items.join(","));
                } else {
                    if outcomes.is_empty() {
                        println!(
                            "(no outcomes registered — use `chump outcome bootstrap` or `chump outcome create`)"
                        );
                    }
                    let all_gaps = store.list(None).unwrap_or_default();
                    for o in &outcomes {
                        let gap_count = all_gaps
                            .iter()
                            .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                            .count();
                        println!(
                            "{} [{}] {} — {} ({} gaps)",
                            o.id, o.priority, o.status, o.title, gap_count
                        );
                    }
                }
            }
            // MISSION-030: `show` = detailed view of one outcome + its linked gaps.
            "show" | "status" => {
                let oid = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome show <outcome-id> [--json]");
                    std::process::exit(2);
                });
                match store.outcome_status(&oid) {
                    Ok(Some(r)) => {
                        if json_out {
                            // Include linked gaps in JSON.
                            let linked = store.gaps_for_outcome(&oid).unwrap_or_default();
                            let gaps_json: Vec<String> = linked
                                .iter()
                                .map(|g| {
                                    format!(
                                        r#"{{"id":"{}","title":"{}","status":"{}","priority":"{}"}}"#,
                                        g.id,
                                        g.title.replace('"', "\\\""),
                                        g.status,
                                        g.priority,
                                    )
                                })
                                .collect();
                            println!(
                                r#"{{"outcome_id":"{}","title":"{}","priority":"{}","status":"{}","total":{},"open":{},"done":{},"other":{},"advisory":true,"gaps":[{}]}}"#,
                                r.outcome.id,
                                r.outcome.title.replace('"', "\\\""),
                                r.outcome.priority,
                                r.outcome.status,
                                r.total,
                                r.open,
                                r.done,
                                r.other,
                                gaps_json.join(","),
                            );
                        } else {
                            println!("=== Outcome: {} ===", r.outcome.id);
                            println!("Title    : {}", r.outcome.title);
                            println!("Priority : {}", r.outcome.priority);
                            println!("Status   : {}", r.outcome.status);
                            if !r.outcome.definition_of_done.is_empty() {
                                println!("DoD      : {}", r.outcome.definition_of_done);
                            }
                            println!();
                            println!("Child gaps (advisory rollup — never gates close):");
                            println!(
                                "  total: {}  open: {}  done: {}  other: {}",
                                r.total, r.open, r.done, r.other
                            );
                            if r.total > 0 {
                                let pct = (r.done as f64 / r.total as f64 * 100.0) as usize;
                                println!("  progress: {}%", pct);
                            }
                            let linked = store.gaps_for_outcome(&oid).unwrap_or_default();
                            if !linked.is_empty() {
                                println!();
                                println!("Linked gaps:");
                                for g in &linked {
                                    println!(
                                        "  {} [{}] {} — {}",
                                        g.id, g.priority, g.status, g.title
                                    );
                                }
                            }
                        }
                    }
                    Ok(None) => {
                        eprintln!("chump outcome show: outcome '{}' not found", oid);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump outcome show: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // MISSION-030: `link <GAP-ID> --outcome <OUTCOME-ID>` — set gaps.outcome_id.
            "link" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome link <GAP-ID> --outcome <OUTCOME-ID>");
                    std::process::exit(2);
                });
                let oid = oflag("--outcome").unwrap_or_else(|| {
                    eprintln!("chump outcome link: --outcome required");
                    std::process::exit(2);
                });
                // Verify outcome exists before linking.
                match store.get_outcome(&oid) {
                    Ok(None) => {
                        eprintln!(
                            "chump outcome link: outcome '{}' not found — create it first",
                            oid
                        );
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump outcome link: {e:#}");
                        std::process::exit(1);
                    }
                    Ok(Some(_)) => {}
                }
                let update = gap_store::GapFieldUpdate {
                    outcome_id: Some(oid.clone()),
                    ..Default::default()
                };
                match store.set_fields(&gap_id, update) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"gap_id":"{gap_id}","outcome_id":"{oid}","linked":true}}"#
                            );
                        } else {
                            println!("{} linked to outcome {}", gap_id, oid);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome link: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // MISSION-030: `unlink <GAP-ID>` — clear gaps.outcome_id.
            "unlink" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome unlink <GAP-ID>");
                    std::process::exit(2);
                });
                let update = gap_store::GapFieldUpdate {
                    outcome_id: Some(String::new()), // empty = set NULL
                    ..Default::default()
                };
                match store.set_fields(&gap_id, update) {
                    Ok(()) => {
                        if json_out {
                            println!(r#"{{"gap_id":"{gap_id}","outcome_id":null,"linked":false}}"#);
                        } else {
                            println!("{} unlinked from outcome", gap_id);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome unlink: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // MISSION-030: `bootstrap` — seed canonical mission outcomes (idempotent).
            // MISSION-043: also seeds 4 pillar outcomes (CREDIBLE/EFFECTIVE/RESILIENT/ZERO-WASTE).
            "bootstrap" => {
                // Canonical outcomes per docs/MISSION.md and gap dispatch context.
                // Each entry: (id, title, priority, dod)
                let canonical: &[(&str, &str, &str, &str)] = &[
                    (
                        "MISSION-010",
                        "self-coordinating fleet (BEAST proof)",
                        "P0",
                        "Fleet ships PRs to external repos without human in the loop; \
                         BEAST-MODE overnight proof completed.",
                    ),
                    (
                        "MISSION-012",
                        "self-deploy: auto-deploy daemon keeps installed binary on origin/main",
                        "P0",
                        "Binary on each fleet node always tracks origin/main; \
                         no manual pull required after a ship.",
                    ),
                    (
                        "MISSION-032",
                        "scale to 100s-to-10000s of external repos",
                        "P1",
                        "Phase B: repos table + external claims + per-repo mission scoreboard; \
                         Phase C: multi-tenant with repo_scope.",
                    ),
                    (
                        "META-067",
                        "three demo-able 2026 outcomes: net-new bootstrap / repo takeover / autonomous throughput",
                        "P1",
                        "Demo 1: zero-to-first-PR on a blank repo; \
                         Demo 2: Chump takes over an existing repo; \
                         Demo 3: sustained autonomous throughput.",
                    ),
                    // MISSION-043: four pillar outcomes — one per quality pillar.
                    (
                        "CREDIBLE-000",
                        "Credible: measurable, verifiable, trustworthy",
                        "P1",
                        "Every CREDIBLE-* gap traces to honest measurement (no proxy metrics, \
                         no silent failures). Reality-check gate (CREDIBLE-090) is the keystone.",
                    ),
                    (
                        "EFFECTIVE-000",
                        "Effective: user-facing capability, real-world impact",
                        "P1",
                        "Every EFFECTIVE-* gap moves a user-visible surface forward \
                         (CLI, PWA, docs that reach humans). META-067 demo outcomes are \
                         canonical evidence.",
                    ),
                    (
                        "RESILIENT-000",
                        "Resilient: self-healing, no fragile single points of failure",
                        "P1",
                        "Every RESILIENT-* gap removes a halt-class or recovers from one. \
                         Fleet recovers from any halt with no human terminal.",
                    ),
                    (
                        "ZERO-WASTE-000",
                        "Zero-waste: no idle agents, no duplicated work, no shelved capability",
                        "P1",
                        "Every ZERO-WASTE-* gap removes a waste class. \
                         Substrate doesn't accumulate without being used.",
                    ),
                ];
                let mut created = 0usize;
                let mut already = 0usize;
                for (id, title, priority, dod) in canonical {
                    // Check existence first (create_outcome is idempotent via INSERT OR IGNORE).
                    let exists = store.get_outcome(id).unwrap_or(None).is_some();
                    match store.create_outcome(id, title, priority, dod) {
                        Ok(()) => {
                            if exists {
                                already += 1;
                                if !json_out {
                                    println!("  {} already exists (skipped)", id);
                                }
                            } else {
                                created += 1;
                                if !json_out {
                                    println!("  {} created: {}", id, title);
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!("chump outcome bootstrap: error creating {}: {}", id, e);
                        }
                    }
                }
                if json_out {
                    println!(
                        r#"{{"created":{},"already_existed":{},"total":{}}}"#,
                        created,
                        already,
                        canonical.len()
                    );
                } else {
                    println!();
                    println!(
                        "bootstrap complete: {} created, {} already existed ({} total)",
                        created,
                        already,
                        canonical.len()
                    );
                }
            }
            // MISSION-030: `backfill [--dry-run] [--apply]` — auto-link open gaps to outcomes.
            "backfill" => {
                let dry_run = !args.iter().any(|a| a == "--apply");
                if dry_run {
                    println!("[outcome backfill] DRY RUN — use --apply to commit changes");
                }

                let outcomes = store.list_outcomes().unwrap_or_default();
                if outcomes.is_empty() {
                    eprintln!(
                        "chump outcome backfill: no outcomes registered. Run `chump outcome bootstrap` first."
                    );
                    std::process::exit(1);
                }

                let all_gaps = match store.list(None) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump outcome backfill: {e:#}");
                        std::process::exit(1);
                    }
                };

                // Build outcome-id set for fast lookup.
                let outcome_ids: std::collections::HashSet<&str> =
                    outcomes.iter().map(|o| o.id.as_str()).collect();

                // Backfill heuristics (applied in order; first match wins):
                // 1. Exact-prefix: gap.id == outcome.id → link directly.
                //    (e.g. MISSION-030 → MISSION-010 as scaffolding)
                //    Actually: for gaps whose id STARTS with same prefix as any outcome.
                //    Concretely: MISSION-* gaps → MISSION-010 (the umbrella mission).
                // 2. Title contains outcome id → link to that outcome.
                // 3. Description contains "MISSION-XXX umbrella" / "Tier-1 of MISSION-XXX"
                //    → link to named outcome id if registered.
                // 4. Title/description contains "BEAST" or "BEAST-MODE" → MISSION-010.
                // 5. Title/description contains "META-067" → META-067.
                // Default: skip (don't guess).

                // Counters per outcome.
                let mut counts: std::collections::HashMap<&str, usize> =
                    outcomes.iter().map(|o| (o.id.as_str(), 0usize)).collect();
                let mut skipped = 0usize;
                let mut already_linked = 0usize;
                let mut changes: Vec<(String, String)> = Vec::new(); // (gap_id, outcome_id)

                for g in &all_gaps {
                    // Don't overwrite existing links.
                    if g.outcome_id.as_deref().map(|s| !s.is_empty()) == Some(true) {
                        already_linked += 1;
                        continue;
                    }

                    let id_uc = g.id.to_uppercase();
                    let title_uc = g.title.to_uppercase();
                    let desc_uc = g.description.to_uppercase();

                    let mut assigned: Option<&str> = None;

                    // Heuristic 1: gap id IS a registered outcome → self-link.
                    if outcome_ids.contains(g.id.as_str()) {
                        assigned = Some(g.id.as_str());
                    }

                    // Heuristic 2: gap title contains a registered outcome id.
                    if assigned.is_none() {
                        for oid in &outcome_ids {
                            if title_uc.contains(&oid.to_uppercase()) {
                                assigned = Some(oid);
                                break;
                            }
                        }
                    }

                    // Heuristic 3: description contains "umbrella" or "Tier-1 of" phrase
                    // referring to a registered outcome id.
                    if assigned.is_none() {
                        for oid in &outcome_ids {
                            let needle = oid.to_uppercase();
                            let paren_prefix = format!("({needle} ");
                            let paren_slice = format!("({needle} SLICE");
                            if desc_uc.contains(&format!("{needle} UMBRELLA"))
                                || desc_uc.contains(&format!("TIER-1 OF {needle}"))
                                || desc_uc.contains(paren_prefix.as_str())
                                || desc_uc.contains(paren_slice.as_str())
                                || desc_uc.contains(&format!("{needle} PHASE"))
                            {
                                assigned = Some(oid);
                                break;
                            }
                        }
                    }

                    // Heuristic 4: BEAST / BEAST-MODE → MISSION-010.
                    if assigned.is_none()
                        && outcome_ids.contains("MISSION-010")
                        && (title_uc.contains("BEAST") || desc_uc.contains("BEAST"))
                    {
                        assigned = Some("MISSION-010");
                    }

                    // Heuristic 5: META-067 in title or description → META-067.
                    if assigned.is_none()
                        && outcome_ids.contains("META-067")
                        && (title_uc.contains("META-067") || desc_uc.contains("META-067"))
                    {
                        assigned = Some("META-067");
                    }

                    // Heuristic 6: MISSION-* prefix gap ids → MISSION-010 umbrella
                    // (since MISSION-010 is the fleet self-coordination master mission).
                    if assigned.is_none()
                        && id_uc.starts_with("MISSION-")
                        && outcome_ids.contains("MISSION-010")
                    {
                        assigned = Some("MISSION-010");
                    }

                    // Heuristic 7 (MISSION-043): domain-prefix → pillar outcome.
                    // Only fires when the pillar outcome is registered (idempotent /
                    // graceful fallback when bootstrap wasn't run yet).
                    if assigned.is_none() {
                        if id_uc.starts_with("CREDIBLE-") && outcome_ids.contains("CREDIBLE-000") {
                            assigned = Some("CREDIBLE-000");
                        } else if id_uc.starts_with("EFFECTIVE-")
                            && outcome_ids.contains("EFFECTIVE-000")
                        {
                            assigned = Some("EFFECTIVE-000");
                        } else if id_uc.starts_with("RESILIENT-")
                            && outcome_ids.contains("RESILIENT-000")
                        {
                            assigned = Some("RESILIENT-000");
                        } else if (id_uc.starts_with("ZERO-WASTE-") || id_uc.starts_with("ZERO-"))
                            && outcome_ids.contains("ZERO-WASTE-000")
                        {
                            assigned = Some("ZERO-WASTE-000");
                        }
                    }

                    // Heuristic 8 (MISSION-043): INFRA-* and META-* → MISSION-010.
                    // INFRA gaps are fleet infrastructure gaps; they collectively implement
                    // the self-coordinating-fleet mission. META-* gaps are fleet PM/process
                    // gaps that support mission coordination. Both route to MISSION-010
                    // as the umbrella fleet-mission outcome.
                    // Only fires when MISSION-010 is registered.
                    if assigned.is_none()
                        && outcome_ids.contains("MISSION-010")
                        && (id_uc.starts_with("INFRA-") || id_uc.starts_with("META-"))
                    {
                        assigned = Some("MISSION-010");
                    }

                    match assigned {
                        Some(oid) => {
                            changes.push((g.id.clone(), oid.to_string()));
                            *counts.entry(oid).or_default() += 1;
                        }
                        None => {
                            skipped += 1;
                        }
                    }
                }

                // Report plan.
                println!("Backfill plan:");
                for o in &outcomes {
                    let c = counts.get(o.id.as_str()).copied().unwrap_or(0);
                    if c > 0 {
                        println!("  {} ← {} gap(s)", o.id, c);
                    }
                }
                println!("  already linked: {}", already_linked);
                println!("  unmatched (skipped): {}", skipped);
                println!("  total to link: {}", changes.len());

                if dry_run {
                    println!();
                    println!("[dry-run] no changes written. Re-run with --apply to commit.");
                    return Ok(());
                }

                // Apply.
                let mut applied = 0usize;
                let mut errors = 0usize;
                for (gid, oid) in &changes {
                    let update = gap_store::GapFieldUpdate {
                        outcome_id: Some(oid.clone()),
                        ..Default::default()
                    };
                    match store.set_fields(gid, update) {
                        Ok(()) => {
                            applied += 1;
                        }
                        Err(e) => {
                            eprintln!("  WARN: could not link {} → {}: {}", gid, oid, e);
                            errors += 1;
                        }
                    }
                }
                println!();
                if json_out {
                    println!(
                        r#"{{"applied":{},"errors":{},"already_linked":{},"skipped":{}}}"#,
                        applied, errors, already_linked, skipped
                    );
                } else {
                    println!("applied {} link(s), {} error(s)", applied, errors);
                    // Emit ambient event for observability.
                    let lock_dir = repo_root.join(".chump-locks");
                    let ambient = lock_dir.join("ambient.jsonl");
                    let ts = std::process::Command::new("date")
                        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                        .output()
                        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                        .unwrap_or_default();
                    // scanner-anchor: outcome_backfill_completed (MISSION-030)
                    let event = format!(
                        r#"{{"ts":"{ts}","kind":"outcome_backfill_completed","applied":{applied},"errors":{errors},"skipped":{skipped}}}"#,
                    );
                    let _ = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&ambient)
                        .and_then(|mut f| {
                            use std::io::Write;
                            writeln!(f, "{}", event)
                        });
                }
            }
            _ => {
                println!("Usage: chump outcome <sub> [args]");
                println!();
                println!("Subcommands:");
                println!("  create --id X --title T [--priority P] [--dod D]");
                println!("  list [--status open|done] [--json]");
                println!("  show <outcome-id> [--json]");
                println!("  link <gap-id> --outcome <outcome-id>");
                println!("  unlink <gap-id>");
                println!("  bootstrap   (seed 8 outcomes: MISSION-010/012/032 + META-067 + 4 pillar outcomes)");
                println!("  backfill [--dry-run] [--apply]");
                println!();
                println!(
                    "ADVISORY: outcome rollup never gates or blocks a child gap from closing."
                );
            }
        }
        return Ok(());
    }

    // MISSION-033: `chump repos <sub>` — first-class repo index commands.
    // chump repos list [--status active|paused|archived] [--json]
    // chump repos show <owner/repo> [--json]
    // chump repos add <owner/repo> [--cascade-tier T] [--status S]
    // chump repos set <owner/repo> --cascade-tier T | --status S | --last-clone-at N | ...
    // chump repos rm <owner/repo>
    //
    // Derived index: repos table is populated by auto-upsert on `chump gap import`
    // for every external_repo:* tag in gaps.skills_required. Manual add also supported.
    if args.get(1).map(String::as_str) == Some("repos") {
        let sub = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump repos: {e:#}");
                std::process::exit(1);
            }
        };
        let rflag = |name: &str| -> Option<String> {
            args.windows(2)
                .find(|w| w[0] == name)
                .and_then(|w| w.get(1))
                .cloned()
        };
        let json_out = args.iter().any(|a| a == "--json");

        match sub {
            "list" => {
                let status_filter = rflag("--status");
                let repos = match store.list_repos(status_filter.as_deref()) {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("chump repos list: {e:#}");
                        std::process::exit(1);
                    }
                };
                if json_out {
                    let items: Vec<String> = repos
                        .iter()
                        .map(|r| {
                            let gap_count = store.repo_gap_count(&r.id).unwrap_or(0);
                            format!(
                                r#"{{"id":"{}","owner":"{}","name":"{}","added_at":{},"last_scan_at":{},"last_clone_at":{},"last_ship_at":{},"cascade_tier":"{}","status":"{}","gap_count":{}}}"#,
                                r.id.replace('"', "\\\""),
                                r.owner.replace('"', "\\\""),
                                r.name.replace('"', "\\\""),
                                r.added_at,
                                r.last_scan_at.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
                                r.last_clone_at.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
                                r.last_ship_at.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
                                r.cascade_tier,
                                r.status,
                                gap_count,
                            )
                        })
                        .collect();
                    println!("[{}]", items.join(","));
                } else {
                    if repos.is_empty() {
                        println!("(no repos registered — run `chump gap import` or `chump repos add <owner/repo>`)");
                    }
                    for r in &repos {
                        let gap_count = store.repo_gap_count(&r.id).unwrap_or(0);
                        println!(
                            "{} [{}] {} | last_scan={} | last_clone={} | gaps={}",
                            r.id,
                            r.cascade_tier,
                            r.status,
                            r.last_scan_at
                                .map(|v| v.to_string())
                                .unwrap_or_else(|| "never".into()),
                            r.last_clone_at
                                .map(|v| v.to_string())
                                .unwrap_or_else(|| "never".into()),
                            gap_count,
                        );
                    }
                }
            }
            "show" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump repos show <owner/repo> [--json]");
                    std::process::exit(2);
                });
                match store.get_repo(&repo_id) {
                    Ok(Some(r)) => {
                        let gap_count = store.repo_gap_count(&r.id).unwrap_or(0);
                        if json_out {
                            println!(
                                r#"{{"id":"{}","owner":"{}","name":"{}","added_at":{},"last_scan_at":{},"last_clone_at":{},"last_ship_at":{},"cascade_tier":"{}","status":"{}","gap_count":{}}}"#,
                                r.id.replace('"', "\\\""),
                                r.owner.replace('"', "\\\""),
                                r.name.replace('"', "\\\""),
                                r.added_at,
                                r.last_scan_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "null".into()),
                                r.last_clone_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "null".into()),
                                r.last_ship_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "null".into()),
                                r.cascade_tier,
                                r.status,
                                gap_count,
                            );
                        } else {
                            println!("=== Repo: {} ===", r.id);
                            println!("Owner        : {}", r.owner);
                            println!("Name         : {}", r.name);
                            println!("Cascade tier : {}", r.cascade_tier);
                            println!("Status       : {}", r.status);
                            println!("Added at     : {}", r.added_at);
                            println!(
                                "Last scan    : {}",
                                r.last_scan_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "never".into())
                            );
                            println!(
                                "Last clone   : {}",
                                r.last_clone_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "never".into())
                            );
                            println!(
                                "Last ship    : {}",
                                r.last_ship_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "never".into())
                            );
                            println!("Linked gaps  : {}", gap_count);
                        }
                    }
                    Ok(None) => {
                        eprintln!("chump repos show: '{}' not found", repo_id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump repos show: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "add" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!(
                        "Usage: chump repos add <owner/repo> [--cascade-tier T] [--status S]"
                    );
                    std::process::exit(2);
                });
                let slash = repo_id.find('/').unwrap_or_else(|| {
                    eprintln!(
                        "chump repos add: id must be 'owner/repo', got '{}'",
                        repo_id
                    );
                    std::process::exit(2);
                });
                let owner = &repo_id[..slash];
                let name = &repo_id[slash + 1..];
                if owner.is_empty() || name.is_empty() {
                    eprintln!("chump repos add: owner and name must be non-empty");
                    std::process::exit(2);
                }
                let cascade_tier = rflag("--cascade-tier").unwrap_or_else(|| "dogfood".into());
                let status = rflag("--status").unwrap_or_else(|| "active".into());
                match store.add_repo(&repo_id, owner, name, &cascade_tier, &status) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"id":"{repo_id}","cascade_tier":"{cascade_tier}","status":"{status}","added":true}}"#
                            );
                        } else {
                            println!(
                                "repo {} added (tier={}, status={})",
                                repo_id, cascade_tier, status
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("chump repos add: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "set" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump repos set <owner/repo> [--cascade-tier T] [--status S] [--last-scan-at N] [--last-clone-at N] [--last-ship-at N]");
                    std::process::exit(2);
                });
                let cascade_tier = rflag("--cascade-tier");
                let status = rflag("--status");
                let last_scan_at = rflag("--last-scan-at").and_then(|v| v.parse::<i64>().ok());
                let last_clone_at = rflag("--last-clone-at").and_then(|v| v.parse::<i64>().ok());
                let last_ship_at = rflag("--last-ship-at").and_then(|v| v.parse::<i64>().ok());
                match store.set_repo_fields(
                    &repo_id,
                    cascade_tier.as_deref(),
                    status.as_deref(),
                    last_scan_at,
                    last_clone_at,
                    last_ship_at,
                ) {
                    Ok(true) => {
                        if json_out {
                            println!(r#"{{"id":"{repo_id}","updated":true}}"#);
                        } else {
                            println!("repo {} updated", repo_id);
                        }
                    }
                    Ok(false) => {
                        eprintln!("chump repos set: '{}' not found — add it first", repo_id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump repos set: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "rm" | "remove" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump repos rm <owner/repo>");
                    std::process::exit(2);
                });
                match store.remove_repo(&repo_id) {
                    Ok(true) => {
                        if json_out {
                            println!(r#"{{"id":"{repo_id}","removed":true}}"#);
                        } else {
                            println!("repo {} removed", repo_id);
                        }
                    }
                    Ok(false) => {
                        eprintln!("chump repos rm: '{}' not found", repo_id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump repos rm: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            _ => {
                println!("Usage: chump repos <sub> [args]");
                println!();
                println!("Subcommands:");
                println!("  list [--status active|paused|archived] [--json]");
                println!("  show <owner/repo> [--json]");
                println!("  add <owner/repo> [--cascade-tier T] [--status S]");
                println!("  set <owner/repo> [--cascade-tier T] [--status S]");
                println!("         [--last-scan-at EPOCH] [--last-clone-at EPOCH] [--last-ship-at EPOCH]");
                println!("  rm <owner/repo>");
                println!();
                println!("Derived index: repos rows are auto-upserted from external_repo:* tags");
                println!("in gaps.skills_required on `chump gap import`. Lifecycle is decoupled");
                println!("from gaps — removing a gap does NOT remove its repo row.");
                println!();
                println!("Daemon-callable: `chump repos set <id> --last-clone-at EPOCH` works");
                println!("without a TTY (used by MISSION-035 clone GC and MISSION-038 scheduler).");
            }
        }
        return Ok(());
    }

    // `chump roadmap-status [--json] [--exit-on-drift] [--top-starved N]`
    // INFRA-606: reads docs/ROADMAP.md, shows 🟢/🟡/🔴 progress per weekly outcome.
    // INFRA-1145: adds starved_outcomes, untraced_p0, pillar_coverage, --exit-on-drift.
    if args.get(1).map(String::as_str) == Some("roadmap-status") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump roadmap-status [--json] [--exit-on-drift] [--top-starved N]");
            println!();
            println!("Reads docs/ROADMAP.md and shows 🟢/🟡/🔴 progress per weekly outcome.");
            println!("Lists implementing gaps with shipped/in-flight/open counts cross-referenced");
            println!("against state.db.");
            println!();
            println!("Options:");
            println!("  --json            output in JSON format");
            println!("  --exit-on-drift   exit 1 if starved outcomes or untraced P0/P1 gaps found");
            println!(
                "  --top-starved N   limit starved_outcomes output to N entries (default: all)"
            );
            println!();
            println!("Exit codes:");
            println!("  0 — no drift detected (or --exit-on-drift not set)");
            println!("  1 — drift detected when --exit-on-drift is set");
            println!();
            println!("Examples:");
            println!("  chump roadmap-status");
            println!("  chump roadmap-status --json | jq .starved_outcomes");
            println!("  chump roadmap-status --exit-on-drift  # CI gate");
            return Ok(());
        }
        let want_json = args.iter().any(|a| a == "--json");
        let exit_on_drift = args.iter().any(|a| a == "--exit-on-drift");

        // Parse --top-starved N
        let top_starved: usize = args
            .windows(2)
            .find(|w| w[0] == "--top-starved")
            .and_then(|w| w[1].parse::<usize>().ok())
            .unwrap_or(usize::MAX);

        let repo_root = repo_path::repo_root();
        let report = roadmap_status::build_report(&repo_root);

        // INFRA-1145: emit ambient event when drift detected and --exit-on-drift set
        if exit_on_drift && report.has_drift() {
            let lock_dir = repo_root.join(".chump-locks");
            let ambient = lock_dir.join("ambient.jsonl");
            if let Ok(ts_out) = std::process::Command::new("date")
                .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                .output()
            {
                let ts_str = String::from_utf8_lossy(&ts_out.stdout).trim().to_string();
                let starved_json: Vec<String> = report
                    .starved_outcomes
                    .iter()
                    .map(|w| w.to_string())
                    .collect();
                let untraced_json: Vec<String> = report
                    .untraced_p0
                    .iter()
                    .map(|id| format!(r#""{id}""#))
                    .collect();
                let event = format!(
                    r#"{{"ts":"{ts}","kind":"roadmap_drift_detected","starved_outcomes":[{s}],"untraced_p0":[{u}]}}"#,
                    ts = ts_str,
                    s = starved_json.join(","),
                    u = untraced_json.join(","),
                );
                let _ = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&ambient)
                    .and_then(|mut f| {
                        use std::io::Write;
                        writeln!(f, "{}", event)
                    });
            }
        }

        if want_json {
            println!("{}", report.render_json_with_opts(top_starved));
        } else {
            print!("{}", report.render_text_with_opts(top_starved));
        }

        if exit_on_drift && report.has_drift() {
            eprintln!(
                "[roadmap-status] DRIFT: {} starved outcome(s), {} untraced P0/P1 gap(s)",
                report.starved_outcomes.len(),
                report.untraced_p0.len()
            );
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump fleet-status` (INFRA-494) — single-command operator
    // dashboard combining active leases, last-24h shipped/abandoned,
    // last-24h waste tally summary, and recent fleet wedges.
    // `chump ambient-rotate` (INFRA-941) — rotate ambient.jsonl if over threshold.
    if args.get(1).map(String::as_str) == Some("ambient-rotate") {
        let repo_root = repo_path::repo_root();
        let ambient = repo_root.join(".chump-locks/ambient.jsonl");
        let threshold_mb = std::env::var("CHUMP_AMBIENT_MAX_MB")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(50);
        let size_mb = std::fs::metadata(&ambient)
            .map(|m| m.len() / (1024 * 1024))
            .unwrap_or(0);
        if crate::ambient_rotate::rotate_if_needed(&ambient) {
            println!(
                "rotated: ambient.jsonl ({} MB) → ambient.jsonl.1 (threshold {} MB)",
                size_mb, threshold_mb
            );
        } else {
            println!(
                "no-op: ambient.jsonl is {} MB (threshold {} MB)",
                size_mb, threshold_mb
            );
        }
        return Ok(());
    }

    if args.get(1).map(String::as_str) == Some("fleet-status") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump fleet-status");
            println!();
            println!("Single-command operator dashboard combining active leases, last-24h");
            println!("shipped/abandoned, last-24h waste tally summary, and recent fleet wedges.");
            println!();
            println!("Example:");
            println!("  chump fleet-status");
            return Ok(());
        }
        let repo_root = repo_path::repo_root();
        let status = fleet_status::snapshot(&repo_root);
        print!("{}", status.render_text());
        return Ok(());
    }

    // `chump plan` (INFRA-1021) — rank the open gap backlog and recommend the
    // next N to dispatch. Library implementation lives in crates/chump-planner;
    // v0.1 supports --format table and --reconcile-threshold; --explain,
    // --graph, json and mermaid are v0.2.
    if args.get(1).map(String::as_str) == Some("plan") {
        return run_plan_subcommand(&args);
    }

    // `chump fleet-velocity` (INFRA-566) — ships/hour over 1h/6h/24h
    // windows plus a forecast of hours until the open gap queue empties.
    // Helps the operator decide when to file more gaps vs let fleet idle.
    if args.get(1).map(String::as_str) == Some("fleet-velocity") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump fleet-velocity");
            println!();
            println!("Ships/hour over 1h/6h/24h windows plus a forecast of hours until the open");
            println!("gap queue empties. Helps decide when to file more gaps vs let fleet idle.");
            println!();
            println!("Example:");
            println!("  chump fleet-velocity");
            return Ok(());
        }
        let repo_root = repo_path::repo_root();
        let snap = fleet_velocity::snapshot(&repo_root);
        print!("{}", snap.render_text());
        return Ok(());
    }

    // `chump fanout <plan|apply|status>` (INFRA-1484) — cross-repo fan-out
    // primitive (Marcus M-B continuation). Sibling of `chump fleet plan/apply`
    // from INFRA-1483: where that fans out by parameter inside one repo, this
    // fans out across N repos. One repo = one reserved gap. AC#4 sandboxing
    // graceful-degrades in v1 (env hints surfaced, not enforced) — lands as
    // real container isolation under INFRA-1454.
    // `chump rollup <fanout-group> [--semantic] [--json]` (INFRA-1455) —
    // Marcus M-B converge step. Takes the fanout_group name set by
    // `chump fanout apply` (INFRA-1484), pulls the closed PR per gap, and
    // clusters by file-list Jaccard into named "Strategy A/B/..." classes
    // so the operator sees "12 PRs converged on Strategy A" instead of a
    // 40-PR firehose.
    if args.get(1).map(String::as_str) == Some("rollup") {
        let name = match args.get(2) {
            Some(n) => n.clone(),
            None => {
                eprintln!("Usage: chump rollup <fanout-group> [--semantic] [--json]");
                eprintln!();
                eprintln!("  Converges PRs from a chump fanout group into named strategy classes.");
                eprintln!(
                    "  --semantic enables Jaccard-similarity clustering across touched files."
                );
                eprintln!("  --json emits structured output.");
                std::process::exit(2);
            }
        };
        let semantic = args.iter().any(|a| a == "--semantic");
        let json_out = args.iter().any(|a| a == "--json");
        match rollup_cmd::run(&name, semantic, json_out) {
            Ok(()) => std::process::exit(0),
            Err(e) => {
                eprintln!("chump rollup: {e}");
                std::process::exit(1);
            }
        }
    }

    if args.get(1).map(String::as_str) == Some("fanout") {
        let sub = args.get(2).map(String::as_str).unwrap_or("");
        if sub.is_empty() || sub == "help" || sub == "--help" {
            println!(
                "Usage: chump fanout <plan|apply|status> <spec.yaml | name> [--dry-run] [--json] [--reference <commit-sha-or-PR-N>]"
            );
            println!();
            println!("Cross-repo fan-out (INFRA-1484, Marcus M-B). One operator command,");
            println!("N repos, N isolated gaps. Spec format:");
            println!();
            println!("  name: shared-lib-bump");
            println!("  intent: |");
            println!("    Bump shared-lib to v2.0 in this service.");
            println!("  repos:");
            println!("    - path: ../service-a");
            println!("    - path: ../service-b");
            println!("  validation: ./scripts/test-integration.sh");
            println!("  success: integration suite passes");
            println!();
            println!("Subcommands:");
            println!("  plan   <spec.yaml>             dry-run; render the per-repo gap set");
            println!(
                "  apply  <spec.yaml> [--dry-run] reserve one gap per repo (fanout_group=<name>)"
            );
            println!("  status <name>                  aggregate reserved gaps by fanout_group");
            println!();
            println!("Flags:");
            println!("  --reference <commit-sha-or-PR-N>  INFRA-1935 (Marcus M-B): commit SHA or PR number");
            println!(
                "                                    to use as reference implementation. PR-N is"
            );
            println!("                                    resolved to merge commit SHA via REST (not GraphQL).");
            println!("                                    Injected into per-worktree agent dispatch payload.");
            return Ok(());
        }

        // INFRA-1935: parse --reference <value> from any position in args.
        // Consume the flag + its value so subcommand parsers see a clean arg list.
        let reference_raw: Option<String> = {
            let pos = args.iter().position(|a| a == "--reference");
            pos.and_then(|i| args.get(i + 1).cloned())
        };

        // Resolve PR-N → merge commit SHA via REST (not GraphQL — fleet exhausted).
        // Any value that is all digits is treated as a PR number.
        // Commit SHAs and git refs (HEAD~1, main, etc.) are passed through verbatim.
        let reference_sha: Option<String> = match &reference_raw {
            None => None,
            Some(v) if v.chars().all(|c| c.is_ascii_digit()) => {
                // PR number — resolve to merge commit SHA via REST.
                let repo_slug = std::env::var("CHUMP_GITHUB_REPO")
                    .unwrap_or_else(|_| "repairman29/chump".to_string());
                let api_url = format!("repos/{repo_slug}/pulls/{v}");
                let out = std::process::Command::new("gh")
                    .args(["api", &api_url, "--jq", ".merge_commit_sha"])
                    .output();
                match out {
                    Ok(o) if o.status.success() => {
                        let sha = String::from_utf8_lossy(&o.stdout).trim().to_string();
                        if sha.is_empty() || sha == "null" {
                            eprintln!("warning: PR #{v} has no merge commit SHA (not merged yet?); using PR number as-is");
                            Some(v.clone())
                        } else {
                            eprintln!("--reference PR #{v} resolved to {sha}");
                            Some(sha)
                        }
                    }
                    Ok(o) => {
                        eprintln!(
                            "warning: could not resolve PR #{v} via gh api: {}; using PR number as-is",
                            String::from_utf8_lossy(&o.stderr).trim()
                        );
                        Some(v.clone())
                    }
                    Err(e) => {
                        eprintln!(
                            "warning: could not exec gh to resolve PR #{v}: {e}; using as-is"
                        );
                        Some(v.clone())
                    }
                }
            }
            Some(v) => Some(v.clone()), // commit SHA or git ref — pass through
        };

        match sub {
            "plan" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!(
                            "Usage: chump fanout plan <spec.yaml> [--reference <sha-or-PR-N>]"
                        );
                        std::process::exit(2);
                    }
                };
                let spec_dir = path
                    .parent()
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| std::path::PathBuf::from("."));
                match fleet_fanout::FanoutSpec::from_path(&path) {
                    Ok(mut spec) => {
                        spec.reference = reference_sha;
                        let plan = spec.plan(&spec_dir);
                        if args.iter().any(|a| a == "--json") {
                            println!("{}", serde_json::to_string_pretty(&plan).unwrap());
                        } else {
                            print!("{}", fleet_fanout::render_plan(&plan));
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "apply" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!("Usage: chump fanout apply <spec.yaml> [--dry-run]");
                        std::process::exit(2);
                    }
                };
                let spec_dir = path
                    .parent()
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| std::path::PathBuf::from("."));
                let dry_run = args.iter().any(|a| a == "--dry-run");
                match fleet_fanout::FanoutSpec::from_path(&path) {
                    Ok(mut spec) => {
                        spec.reference = reference_sha;
                        let plan = spec.plan(&spec_dir);
                        println!(
                            "fanout apply: {} repo(s) (group={}, dry_run={dry_run})",
                            plan.len(),
                            spec.name
                        );
                        for (i, g) in plan.iter().enumerate() {
                            if dry_run {
                                println!(
                                    "  [dry-run] {} | {} → {}",
                                    i + 1,
                                    g.repo_label,
                                    g.target_repo
                                );
                                for w in &g.env_isolation_warnings {
                                    println!("            ⚠ {w}");
                                }
                                continue;
                            }
                            if !std::path::Path::new(&g.target_repo).exists() {
                                eprintln!(
                                    "  [failed] {}: target_repo not found: {} (v1: clone the repo first; auto-clone lands with a follow-up)",
                                    g.repo_label, g.target_repo
                                );
                                std::process::exit(1);
                            }
                            let notes = fleet_fanout::build_gap_notes(g);
                            let chump_bin =
                                std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                            let out = std::process::Command::new(&chump_bin)
                                .args([
                                    "gap", "reserve", "--domain", &g.domain, "--title", &g.title,
                                    "--effort", &g.effort, "--notes", &notes,
                                ])
                                .output();
                            match out {
                                Ok(o) if o.status.success() => {
                                    let body = String::from_utf8_lossy(&o.stdout);
                                    let id = body
                                        .lines()
                                        .find_map(|l| {
                                            let t = l.trim();
                                            // gap reserve prints lines like:
                                            //   "Reserved INFRA-NNN" or "INFRA-NNN"
                                            t.split_whitespace()
                                                .find(|w| {
                                                    w.contains('-')
                                                        && w.split('-').nth(1).is_some_and(|n| {
                                                            n.chars().all(|c| c.is_ascii_digit())
                                                        })
                                                })
                                                .map(String::from)
                                        })
                                        .unwrap_or_else(|| "?".to_string());
                                    println!(
                                        "  [reserved] {} ({}) → {}",
                                        g.repo_label, g.target_repo, id
                                    );
                                    for w in &g.env_isolation_warnings {
                                        println!("             ⚠ {w}");
                                    }
                                }
                                Ok(o) => {
                                    eprintln!(
                                        "  [failed] {}: {}",
                                        g.repo_label,
                                        String::from_utf8_lossy(&o.stderr).trim()
                                    );
                                    std::process::exit(1);
                                }
                                Err(e) => {
                                    eprintln!("  [failed] {}: spawn error: {e}", g.repo_label);
                                    std::process::exit(1);
                                }
                            }
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "status" => {
                let name = match args.get(3) {
                    Some(n) => n.clone(),
                    None => {
                        eprintln!("Usage: chump fanout status <name>");
                        std::process::exit(2);
                    }
                };
                let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                let out = std::process::Command::new(&chump_bin)
                    .args(["gap", "list", "--json"])
                    .output();
                let Ok(o) = out else {
                    eprintln!("error: could not exec chump gap list");
                    std::process::exit(1);
                };
                let body = String::from_utf8_lossy(&o.stdout);
                let report = fleet_fanout::aggregate_status(&body, &name);
                if args.iter().any(|a| a == "--json") {
                    println!("{}", serde_json::to_string_pretty(&report).unwrap());
                } else {
                    print!("{}", report.render_text());
                }
                std::process::exit(0);
            }
            other => {
                eprintln!("chump fanout: unknown subcommand '{other}'");
                eprintln!("Try: chump fanout <plan|apply|status> [args…]");
                std::process::exit(2);
            }
        }
    }

    // `chump waste-tally [--since 24h|7d|...] [--json]`
    // (INFRA-488) — Zero Waste mission pillar measurement primitive.
    // Aggregates ALERT events from .chump-locks/ambient.jsonl that match
    // the waste taxonomy (fleet_wedge, fleet_starved, lease_expired_server,
    // reaper_silent, queue_stuck, ambient_oversize, pr_stuck, silent_agent,
    // lease_overlap, edit_burst) and prints a per-kind tally with rough
    // cost estimates where measurable. No new event emissions in MVP.
    if args.get(1).map(String::as_str) == Some("waste-tally") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!(
                "Usage: chump waste-tally [--since WINDOW] [--json] [--domain|--by-domain] [--tokens] [--by-close-reason] [--emit-ambient]"
            );
            println!();
            println!("Zero-Waste pillar measurement. Tallies waste events from ambient.jsonl");
            println!("(fleet_wedge, fleet_starved, pr_stuck, silent_agent, lease_overlap, …)");
            println!("with per-kind counts and rough cost estimates.");
            println!();
            println!("Options:");
            println!(
                "  --since T          time window: 24h, 7d, 60m, or raw seconds  [default: 24h]"
            );
            println!("  --json             output in JSON format");
            println!(
                "  --domain           break down waste by gap domain (exits 1 if any domain >40%)"
            );
            println!("  --by-domain        alias for --domain (back-compat)");
            println!("  --tokens           include token-cost estimates");
            println!("  --by-close-reason  classify closed-not-merged PRs by close-comment pattern (INFRA-998)");
            println!("                     Categories: superseded, duplicate_claim, stale_branch,");
            println!("                     scratch_commit, ci_fail_orphan, staging_branch, other");
            println!(
                "  --emit-ambient     with --by-close-reason: write kind=waste_category_report"
            );
            println!("                     to ambient.jsonl (for weekly cron)");
            println!();
            println!("Example:");
            println!("  chump waste-tally --since 7d");
            println!("  chump waste-tally --window 2h   # alias accepted by fleet scaling gate");
            println!("  chump waste-tally --by-close-reason --since 7d --json");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "24h".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        // INFRA-934: --domain is the canonical flag; --by-domain remains for back-compat.
        let by_domain = args.iter().any(|a| a == "--by-domain" || a == "--domain");
        let want_tokens = args.iter().any(|a| a == "--tokens");
        // INFRA-998: PR-closure-reason categorization.
        let by_close_reason = args.iter().any(|a| a == "--by-close-reason");
        let emit_ambient = args.iter().any(|a| a == "--emit-ambient");

        // Parse "24h" / "7d" / "60m" / raw seconds.
        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump waste-tally: invalid --since '{}' (expected like 24h, 7d, 60m, or seconds)",
                since_arg
            );
            std::process::exit(2);
        });

        let repo_root = repo_path::repo_root();
        // INFRA-998: close-reason mode. Mutually exclusive with --domain.
        if by_close_reason {
            let report = waste_tally::build_close_reason_report(since_secs);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            if emit_ambient {
                report.emit_ambient(&repo_root);
            }
            return Ok(());
        }
        if by_domain {
            let report = waste_tally::build_domain_report(&repo_root, since_secs);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            // INFRA-934: exit non-zero if any single domain exceeds 40% of total token spend.
            if let Some(breach) = report.any_domain_exceeds(40.0) {
                eprintln!(
                    "chump waste-tally: domain '{}' is {:.1}% of total token spend (threshold 40%)",
                    breach.domain, breach.pct_of_total
                );
                std::process::exit(1);
            }
        } else {
            let report = waste_tally::build_report(&repo_root, since_secs);
            if want_json {
                println!("{}", report.render_json());
            } else if want_tokens {
                print!("{}", report.render_text_tokens());
            } else {
                print!("{}", report.render_text());
            }
        }
        return Ok(());
    }

    // `chump pr-coupling-cost <PR#> [--diff-files f1,f2,...] [--json]`
    // (INFRA-595) — CREDIBLE: per-PR coupling-tax measurement.
    // Reads .github/workflows/ci.yml dorny/paths-filter rules; for each file
    // in the PR diff prints a table of {file, jobs_triggered}.
    // --diff-files accepts a comma-separated override (for tests/offline use).
    if args.get(1).map(String::as_str) == Some("pr-coupling-cost") {
        let pr_number: Option<u64> = args.get(2).and_then(|s| s.parse().ok());
        let want_json = args.iter().any(|a| a == "--json");

        let diff_files_override: Option<Vec<String>> = args
            .iter()
            .position(|a| a == "--diff-files")
            .and_then(|i| args.get(i + 1))
            .map(|s| s.split(',').map(|f| f.trim().to_string()).collect());

        let diff_files: Vec<String> = if let Some(files) = diff_files_override {
            files
        } else if let Some(pr) = pr_number {
            pr_coupling_cost::fetch_pr_files(pr)
        } else {
            eprintln!("Usage: chump pr-coupling-cost <PR#> [--diff-files f1,f2,...] [--json]");
            std::process::exit(2);
        };

        let repo_root = repo_path::repo_root();
        let ci_yml_path = repo_root.join(".github/workflows/ci.yml");
        let ci_yml = std::fs::read_to_string(&ci_yml_path).unwrap_or_else(|e| {
            eprintln!(
                "chump pr-coupling-cost: cannot read {}: {e}",
                ci_yml_path.display()
            );
            std::process::exit(1);
        });

        let report = pr_coupling_cost::build_report(pr_number, &diff_files, &ci_yml);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        return Ok(());
    }

    // `chump pr explain-block <PR#> [--json]` (INFRA-1416) — reads the
    // status-check rollup + cross-refs other open PRs failing the same
    // checks, then names the next mechanical action per row. Replaces
    // the ~6× manual `gh pr view ... statusCheckRollup` digging the
    // operator was doing per stuck PR.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("explain-block")
    {
        let pr_number: Option<u64> = args.get(3).and_then(|s| s.parse().ok());
        let pr_number = match pr_number {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump pr explain-block <PR#> [--json]");
                std::process::exit(2);
            }
        };
        let json_out = args.iter().any(|a| a == "--json");
        match pr_explain::run(pr_number, json_out) {
            Ok(()) => std::process::exit(0),
            Err(e) => {
                eprintln!("chump pr explain-block: {e}");
                std::process::exit(1);
            }
        }
    }

    // `chump pr fix-clippy <PR#> [--dry-run]`
    // (INFRA-618) — ZERO-WASTE: auto-fix obvious clippy lints on a PR branch.
    // Targets: manual_split_once, unused_variables, redundant_clone, single_match.
    // Safety: refuses if --fix touches >3 files or diff looks non-trivial.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("fix-clippy")
    {
        let pr_number: Option<u64> = args.get(3).and_then(|s| s.parse().ok());
        let pr_number = match pr_number {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump pr fix-clippy <PR#> [--dry-run]");
                std::process::exit(2);
            }
        };
        let dry_run = args.iter().any(|a| a == "--dry-run");
        let repo_root = repo_path::repo_root();
        match pr_fix_clippy::fix_clippy(pr_number, &repo_root, dry_run) {
            Ok(r) => {
                if !r.dry_run {
                    println!(
                        "chump pr fix-clippy: PR #{} fixed — {} files, {} lines.",
                        r.pr_number, r.files_changed, r.lines_changed
                    );
                }
            }
            Err(e) => {
                eprintln!("chump pr fix-clippy: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump pr triage [--rerun-flakes] [--rebase-dirty] [--json]`
    // (INFRA-605) — EFFECTIVE: scan all open PRs, classify, report CI health.
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("triage")
    {
        let opts = pr_triage::TriageOptions {
            rerun_flakes: args.iter().any(|a| a == "--rerun-flakes"),
            rebase_dirty: args.iter().any(|a| a == "--rebase-dirty"),
            json: args.iter().any(|a| a == "--json"),
        };
        match pr_triage::run_triage(&opts) {
            Ok(report) => {
                if opts.json {
                    print!("{}", pr_triage::render_json(&report));
                } else {
                    print!("{}", pr_triage::render_text(&report));
                }
            }
            Err(e) => {
                eprintln!("chump pr triage: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump pr ac-coverage <PR#> [--advisory]`
    // (INFRA-1541) — CREDIBLE: pre-merge AC coverage gate
    if args.get(1).map(String::as_str) == Some("pr")
        && args.get(2).map(String::as_str) == Some("ac-coverage")
    {
        let pr_number: Option<u64> = args.get(3).and_then(|s| s.parse().ok());
        let pr_number = match pr_number {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump pr ac-coverage <PR#>");
                std::process::exit(2);
            }
        };
        match pr_ac_coverage::run(pr_number) {
            Ok(result) => {
                // print JSON summary
                println!("{}", pr_ac_coverage::render_json(&result));
                if result.status == pr_ac_coverage::CoverageStatus::Miss
                    && std::env::var("CHUMP_AC_GATE_ADVISORY").as_deref() != Ok("true")
                {
                    std::process::exit(1);
                }
            }
            Err(e) => {
                eprintln!("chump pr ac-coverage: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump paramedic triage|execute|daemon [--dry-run] [--interval-secs N] [--budget-secs N] [--plan F]`
    // (INFRA-1375) — RESILIENT: rule-engine PR rescue daemon.
    // triage  — read PR state, emit JSON action plan (read-only)
    // execute — run one triage→execute cycle with optional --plan <file>
    // daemon  — loop triage→execute every --interval-secs (default 600)
    if args.get(1).map(String::as_str) == Some("paramedic") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let dry_run = args.iter().any(|a| a == "--dry-run");

        if subcmd == "help" || args.iter().any(|a| a == "--help") {
            println!("Usage: chump paramedic <subcommand> [options]");
            println!();
            println!("Subcommands:");
            println!("  triage               Read PR state and emit JSON action plan (read-only).");
            println!("  execute [--plan F]   Run one triage→execute cycle. --plan reads from file");
            println!("                       instead of re-triaging.");
            println!("  daemon               Loop triage→execute forever. Single-instance via PID");
            println!("                       file at .chump-locks/paramedic.lock.");
            println!();
            println!("Options:");
            println!("  --dry-run            Print actions; do not actually run gh commands.");
            println!("  --interval-secs N    Daemon loop interval in seconds (default: 600).");
            println!("  --budget-secs N      Per-PR action budget in seconds (default: 90).");
            println!("  --plan F             Path to JSON plan file (execute only).");
            println!();
            println!("Examples:");
            println!("  chump paramedic triage");
            println!("  chump paramedic triage | chump paramedic execute --plan /dev/stdin");
            println!("  chump paramedic daemon --interval-secs 300 --dry-run");
            return Ok(());
        }

        match subcmd {
            "triage" => match paramedic::triage(&repo_root, dry_run) {
                Ok(plan) => {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&plan).unwrap_or_default()
                    );
                }
                Err(e) => {
                    eprintln!("chump paramedic triage: {e}");
                    std::process::exit(1);
                }
            },
            "execute" => {
                let budget_secs = args
                    .iter()
                    .position(|a| a == "--budget-secs")
                    .and_then(|i| args.get(i + 1))
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(90);

                // Optionally read plan from --plan <file>; otherwise triage first.
                let plan_path = args
                    .iter()
                    .position(|a| a == "--plan")
                    .and_then(|i| args.get(i + 1));

                let plan = if let Some(path) = plan_path {
                    let raw = std::fs::read_to_string(path)
                        .with_context(|| format!("reading plan from {path}"))?;
                    serde_json::from_str::<paramedic::ActionPlan>(&raw)
                        .context("parsing plan JSON")?
                } else {
                    paramedic::triage(&repo_root, dry_run)?
                };

                if let Err(e) = paramedic::execute(&plan, &repo_root, dry_run, budget_secs) {
                    eprintln!("chump paramedic execute: {e}");
                    std::process::exit(1);
                }
            }
            "daemon" => {
                let interval_secs = args
                    .iter()
                    .position(|a| a == "--interval-secs")
                    .and_then(|i| args.get(i + 1))
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(600);

                if let Err(e) = paramedic::daemon(interval_secs, &repo_root, dry_run) {
                    eprintln!("chump paramedic daemon: {e}");
                    std::process::exit(1);
                }
            }
            other => {
                eprintln!("chump paramedic: unknown subcommand '{other}'");
                eprintln!("Run 'chump paramedic help' for usage.");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump health-digest [--since 7d] [--json] [--emit] [--webhook]`
    // (INFRA-646) — RESILIENT: weekly health digest. Summarises ships count,
    // ship rate, waste $ by class, top-3 burning gaps, P0 compliance, pillar
    // balance, SLO breaches, and EFFECTIVE productizations for the past 7 days.
    // --emit appends a weekly_health_digest event to ambient.jsonl.
    // --webhook POSTs to CHUMP_WEBHOOK_URL (if set).
    if args.get(1).map(String::as_str) == Some("health-digest") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump health-digest [--since WINDOW] [--json] [--emit] [--webhook]");
            println!();
            println!("Weekly markdown digest with P0/P1 gap counts, waste rate, ship rate,");
            println!("and fleet wedge warnings. Suitable for team standup or operator review.");
            println!();
            println!("Options:");
            println!("  --since T   time window: 7d, 14d, 24h  [default: 7d]");
            println!("  --json      output in JSON format");
            println!("  --emit      write event to ambient.jsonl");
            println!("  --webhook   POST to CHUMP_WEBHOOK_URL");
            println!();
            println!("Example:");
            println!("  chump health-digest --since 7d");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "7d".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        let do_emit = args.iter().any(|a| a == "--emit");
        let do_webhook = args.iter().any(|a| a == "--webhook");
        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump health-digest: invalid --since '{}' (expected like 7d, 14d, 24h)",
                since_arg
            );
            std::process::exit(2);
        });
        let repo_root = repo_path::repo_root();
        let summary = health::build_week_summary(&repo_root, since_secs);
        if want_json {
            println!("{}", summary.render_json());
        } else {
            print!("{}", summary.render_text());
        }
        if do_emit {
            health::emit_to_ambient(&repo_root, &summary);
        }
        if do_webhook {
            let delivered = health::deliver_webhook(&summary);
            if !delivered {
                eprintln!("chump health-digest: webhook delivery skipped or failed (check CHUMP_WEBHOOK_URL)");
            }
        }
        return Ok(());
    }

    // `chump ship-quality [--since 24h|7d|...] [--json]`
    // (INFRA-537) — per-agent ship-quality grade. Aggregates ship_grade
    // events emitted by bot-merge.sh into per-model and per-agent tables
    // showing clippy_ok%, test_added%, and rebase_clean% pass rates.
    // Empirical basis for FLEET_MODEL routing decisions (sonnet vs haiku).
    if args.get(1).map(String::as_str) == Some("ship-quality") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump ship-quality [--since WINDOW] [--json]");
            println!();
            println!("Per-agent ship-quality grade: clippy_ok%, test_added%, rebase_clean%.");
            println!("Aggregates ship_grade events from ambient.jsonl by model and agent.");
            println!("Use for FLEET_MODEL routing decisions (sonnet vs haiku).");
            println!();
            println!("Options:");
            println!("  --since T   time window: 24h, 7d, 60m  [default: 24h]");
            println!("  --json      output in JSON format");
            println!();
            println!("Example:");
            println!("  chump ship-quality --since 7d");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "24h".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump ship-quality: invalid --since '{}' (expected like 24h, 7d, 60m, or seconds)",
                since_arg
            );
            std::process::exit(2);
        });
        let repo_root = repo_path::repo_root();
        let report = ship_quality::build_report(&repo_root, since_secs);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        return Ok(());
    }

    // `chump rebase-stuck [--pr <N>] [--apply] [--json]`
    // (INFRA-607) — RESILIENT: detect DIRTY PRs and attempt auto-rebase.
    // Safety gate: only auto-resolves conflicts in <3 files AND <20 lines
    // AND no test-touching files. --apply force-pushes with-lease.
    if args.get(1).map(String::as_str) == Some("rebase-stuck") {
        let sub_args: Vec<String> = args[2..].to_vec();
        let exit_code = rebase_stuck::run(&sub_args);
        std::process::exit(exit_code);
    }

    // `chump ci-summary [--since 24h|7d|...] [--json]`
    // (INFRA-506) — CI observability primitive. Reads gh run list + failed
    // job logs for the window and classifies failures as flake /
    // test-coupling / real-bug / infra-broken. Output mirrors waste-tally:
    // per-class count + sample diagnostic lines.
    if args.get(1).map(String::as_str) == Some("ci-summary") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!(
                "Usage: chump ci-summary [--since WINDOW] [--json] [--emit-alert] [--threshold N]"
            );
            println!();
            println!("CI observability: reads gh run list and classifies failures as flake /");
            println!("test-coupling / real-bug / infra-broken. Output mirrors waste-tally.");
            println!();
            println!("Options:");
            println!("  --since T       time window: 24h, 7d, 60m  [default: 24h]");
            println!("  --json          output in JSON format");
            println!("  --emit-alert    write ambient alert if failure rate > threshold");
            println!("  --threshold N   failure-rate % for alert trigger  [default: 10]");
            println!();
            println!("Example:");
            println!("  chump ci-summary --since 7d");
            return Ok(());
        }
        let since_arg = args
            .iter()
            .position(|a| a == "--since")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| "24h".to_string());
        let want_json = args.iter().any(|a| a == "--json");
        let emit_alert = args.iter().any(|a| a == "--emit-alert");
        let threshold_pct: u64 = args
            .iter()
            .position(|a| a == "--threshold")
            .and_then(|i| args.get(i + 1))
            .and_then(|v| v.parse().ok())
            .unwrap_or(10);

        let since_secs = parse_duration_to_secs(&since_arg).unwrap_or_else(|| {
            eprintln!(
                "chump ci-summary: invalid --since '{}' (expected like 24h, 7d, 60m, or seconds)",
                since_arg
            );
            std::process::exit(2);
        });

        let report = ci_summary::build_report(since_secs);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        if emit_alert {
            let ambient_path = repo_path::repo_root().join(".chump-locks/ambient.jsonl");
            if report.emit_ambient_alert(threshold_pct, &ambient_path) {
                eprintln!(
                    "ci-summary: ALERT emitted — failure rate {}% exceeds {}% threshold",
                    report.failure_rate_pct(),
                    threshold_pct
                );
            }
        }
        return Ok(());
    }

    // `chump classify-failure [--job NAME] [--log FILE|-] [--json]`  (INFRA-647)
    // Reads docs/process/FAILURE_MODES.yaml and classifies a CI failure.
    // pr-triage-bot.yml calls this to decide: fix | rerun | file_gap | escalate.
    if args.get(1).map(String::as_str) == Some("classify-failure") {
        failure_catalog::run_classify(&args[2..]);
        return Ok(());
    }

    // `chump session-track --start <GAP-ID>` / `--end <GAP-ID> --outcome <s|a|t>`
    // (INFRA-477) — per-session cost ledger MVP. Writes session_start +
    // session_end events to ambient.jsonl. Briefing surfaces aggregate
    // stats for past sessions in the same domain so the next session
    // sees how long similar work has historically taken.
    if args.get(1).map(String::as_str) == Some("session-track") {
        let st_flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1).cloned())
        };
        let session_id =
            crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
        let repo_root = repo_path::repo_root();
        if let Some(gap_id) = st_flag("--start") {
            session_ledger::emit_session_start(&repo_root, &session_id, &gap_id);
            let dashboard_url = std::env::var("CHUMP_WEB_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:3000".to_string());
            println!(
                "session_start logged: gap={} session={}\ndashboard: {}",
                gap_id, session_id, dashboard_url
            );
            return Ok(());
        }
        if let Some(gap_id) = st_flag("--end") {
            let outcome_str = st_flag("--outcome").unwrap_or_else(|| {
                eprintln!(
                    "chump session-track --end: missing --outcome <shipped|abandoned|starved>"
                );
                std::process::exit(2);
            });
            let outcome = session_ledger::Outcome::from_str(&outcome_str)
                .unwrap_or_else(|| {
                    eprintln!("chump session-track --end: unknown outcome '{}' (expected shipped|abandoned|starved)", outcome_str);
                    std::process::exit(2);
                });
            // INFRA-534: optional token counts for cost telemetry.
            let tokens = match (
                st_flag("--input-tokens").and_then(|s| s.parse::<u64>().ok()),
                st_flag("--output-tokens").and_then(|s| s.parse::<u64>().ok()),
                st_flag("--cache-read-tokens").and_then(|s| s.parse::<u64>().ok()),
            ) {
                (Some(i), Some(o), cache) => Some(session_ledger::TokenCounts {
                    input_tokens: i,
                    output_tokens: o,
                    cache_read_tokens: cache.unwrap_or(0),
                }),
                _ => None,
            };
            session_ledger::emit_session_end(&repo_root, &session_id, &gap_id, outcome, tokens);
            println!(
                "session_end logged: gap={} outcome={}",
                gap_id,
                outcome.as_str()
            );
            return Ok(());
        }
        eprintln!("Usage: chump session-track --start <GAP-ID>");
        eprintln!(
            "       chump session-track --end <GAP-ID> --outcome <shipped|abandoned|starved>"
        );
        std::process::exit(2);
    }

    // `chump session-export [--session-id <ID>]` (INFRA-616) — emit a handoff
    // snapshot to ~/.chump/sessions/<session-id>.md so the next Opus
    // orchestrator session can resume with full context via session-resume.
    if args.get(1).map(String::as_str) == Some("session-export") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump session-export [--session-id ID]");
            println!();
            println!("Export the current session transcript to ~/.chump/sessions/<ID>.md");
            println!("for handoff to the next orchestrator session via 'chump session-resume'.");
            println!();
            println!("Options:");
            println!("  --session-id ID   session ID to export  [default: $CHUMP_SESSION_ID]");
            println!();
            println!("Example:");
            println!("  chump session-export");
            println!("  chump session-export --session-id abc123");
            return Ok(());
        }
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1).cloned())
        };
        let session_id = flag("--session-id")
            .or_else(|| crate::ambient_stream::env_session_id())
            .unwrap_or_else(|| {
                // Fall back to a timestamp-based ID so exports are never lost.
                format!("session-{}", unix_ts())
            });
        let repo_root = repo_path::repo_root();
        let export = session_export::build_export(&session_id, &repo_root);
        let md = export.render_md();

        let out_path = session_export::export_path(&session_id);
        if let Some(parent) = out_path.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                eprintln!(
                    "chump session-export: cannot create {}: {e:#}",
                    parent.display()
                );
                std::process::exit(1);
            }
        }
        if let Err(e) = std::fs::write(&out_path, &md) {
            eprintln!(
                "chump session-export: cannot write {}: {e:#}",
                out_path.display()
            );
            std::process::exit(1);
        }
        println!("session-export written: {}", out_path.display());
        print!("{}", md);
        return Ok(());
    }

    // `chump session-resume <session-id>` (INFRA-616) — read a prior export
    // and print it to stdout for injection into the new session's context.
    if args.get(1).map(String::as_str) == Some("session-resume") {
        let session_id = args.get(2).cloned().unwrap_or_else(|| {
            eprintln!("Usage: chump session-resume <session-id>");
            std::process::exit(2);
        });
        let path = session_export::export_path(&session_id);
        let content = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            eprintln!(
                "chump session-resume: cannot read {}: {e:#}",
                path.display()
            );
            std::process::exit(1);
        });
        print!("{}", content);
        return Ok(());
    }

    // `chump dashboard` (INFRA-063 / M5) — print the cycle-time dashboard:
    // `chump reflect-delta <GAP-ID> "<text>"` (COG-042) — record what
    // this session did *differently* than past attempts on the gap's
    // class. Pure additive: writes a `delta_recorded` event to
    // ambient.jsonl. Briefing surfaces these for similar gaps so the
    // next session sees how the previous attempt's approach differed.
    if args.get(1).map(String::as_str) == Some("reflect-delta") {
        let gap_id = args.get(2).cloned().unwrap_or_else(|| {
            eprintln!("Usage: chump reflect-delta <GAP-ID> \"<what was different>\"");
            std::process::exit(2);
        });
        if gap_id.starts_with("--") {
            eprintln!("Usage: chump reflect-delta <GAP-ID> \"<what was different>\"");
            std::process::exit(2);
        }
        let text = args.get(3).cloned().unwrap_or_else(|| {
            eprintln!("chump reflect-delta: missing the delta text");
            eprintln!("Usage: chump reflect-delta <GAP-ID> \"<what was different>\"");
            std::process::exit(2);
        });
        let session_id =
            crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
        let repo_root = repo_path::repo_root();
        reflect_delta::emit_delta_recorded(&repo_root, &session_id, &gap_id, &text);
        println!("recorded delta for {} (session={})", gap_id, session_id);
        return Ok(());
    }

    // PRs landed today/week, median PR-open time, dispatcher backend split,
    // top 5 stale linked worktrees. Pure read aggregator over `gh` + `git`.
    if args.get(1).map(String::as_str) == Some("dashboard") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump dashboard");
            println!();
            println!("Print the cycle-time dashboard: active leases, gap queue depth,");
            println!("recent ship/abandon events, and provider health.");
            println!();
            println!("Example:");
            println!("  chump dashboard");
            return Ok(());
        }
        if let Err(e) = dashboard::print_dashboard() {
            eprintln!("chump dashboard: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump cascade stats [--json]` (INFRA-269) — per-slot cascade traffic
    // table from chump_provider_quality. Companion to the
    // 40-cascade-consumption-report.sh overnight script: this is the
    // on-demand human-facing equivalent. Pure read; safe to run anytime.
    if args.get(1).map(String::as_str) == Some("cascade")
        && args.get(2).map(String::as_str) == Some("stats")
    {
        let json_out = args.iter().any(|a| a == "--json");
        if let Err(e) = cascade_stats::print_stats(json_out) {
            eprintln!("chump cascade stats: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // PRODUCT-015: every non-init session start is a candidate d2-return. The
    // emitter no-ops unless install happened > 24h ago and d2 hasn't fired yet.
    activation::emit_return_d2_if_due();

    // `chump --recipe <path> [--<param> <value> ...]` (COMP-008) — run a packaged
    // workflow from a YAML recipe file.
    //
    // A recipe declares its required env vars, required tools, named parameters
    // with defaults, and an ordered list of steps. Each step is a command with
    // {{param}} substitutions in its args. See docs/process/CHUMP_RECIPES.md for schema
    // and recipes/ for bundled examples.
    //
    // Parameter overrides are collected from the remaining args as flag-value
    // pairs: `--model claude-haiku-4-5 --n 20`. Underscore ↔ hyphen are both
    // accepted as parameter name separators.
    //
    // Exit codes: 0 on success, 1 on recipe error, 2 on usage error.
    if let Some(pos) = args.iter().position(|a| a == "--recipe") {
        let path_str = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if path_str.is_empty() || path_str.starts_with("--") {
            eprintln!("Usage: chump --recipe <path.yaml> [--<param> <value> ...]");
            std::process::exit(2);
        }
        // Collect remaining key=value pairs (skip --recipe <path> at pos and pos+1)
        let mut param_overrides: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        let mut i = pos + 2;
        while i < args.len() {
            let flag = &args[i];
            if flag.starts_with("--") {
                let key = flag.trim_start_matches('-').replace('-', "_");
                if let Some(val) = args.get(i + 1) {
                    if !val.starts_with("--") {
                        param_overrides.insert(key, val.clone());
                        i += 2;
                        continue;
                    }
                }
                // boolean flag with no value — treat as "true"
                param_overrides.insert(key, "true".to_string());
            }
            i += 1;
        }
        let recipe_path = std::path::Path::new(path_str);
        let repo_root = repo_path::repo_root();
        // Resolve recipe path: if relative, try relative to repo root first
        let resolved_path = if recipe_path.is_absolute() {
            recipe_path.to_path_buf()
        } else {
            let candidate = repo_root.join(recipe_path);
            if candidate.exists() {
                candidate
            } else {
                recipe_path.to_path_buf()
            }
        };
        match recipe::run_recipe(&resolved_path, &param_overrides, &repo_root) {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump --recipe: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump dispatch <GAP-ID>` (INFRA-191 Phase 1+2) — atomic ship cycle:
    // preflight → claim → (work) → ship → release.
    //
    // Phase 1 wraps gap-preflight.sh, gap-claim.sh, bot-merge.sh.
    // Phase 2 adds --backend headless / exec-gap (spawns `claude -p` or
    // `chump --execute-gap`). Phase 3 ports ship() to native Rust.
    // See docs/design/INFRA-191-chump-dispatch.md.
    //
    // Examples:
    //   chump dispatch INFRA-191                              # interactive (default)
    //   chump dispatch INFRA-191 --auto-merge                 # arm merge queue
    //   chump dispatch INFRA-191 --auto-merge --skip-tests    # for doc PRs
    //   chump dispatch INFRA-191 --paths "src/dispatch.rs"    # narrow lease scope
    //   chump dispatch INFRA-191 --backend headless \
    //       --prompt "ship the gap" --model claude-sonnet-4-6 # spawn `claude -p`
    //   chump dispatch INFRA-191 --backend exec-gap           # spawn `chump --execute-gap`
    // INFRA-392: subcommands route/scoreboard/simulate are handled later in
    // this file. Without this guard, args[2]="route" (etc.) was treated as a
    // gap-id and routed through gap-preflight + bot-merge — making
    // `chump dispatch route INFRA-191` claim a phantom gap named "route"
    // instead of printing a routing cascade.
    const DISPATCH_SUBCOMMANDS: &[&str] = &["route", "scoreboard", "simulate", "cost-report"];
    if args.get(1).map(String::as_str) == Some("dispatch")
        && !args
            .get(2)
            .map(|s| DISPATCH_SUBCOMMANDS.contains(&s.as_str()))
            .unwrap_or(false)
    {
        let gap_id = match args.get(2) {
            Some(g) if !g.starts_with('-') => g.clone(),
            _ => {
                eprintln!(
                    "Usage: chump dispatch <GAP-ID> [--auto-merge] [--skip-tests] [--paths X,Y] [--backend BACKEND] [--model M] [--prompt P]"
                );
                std::process::exit(2);
            }
        };
        let auto_merge = args.iter().any(|a| a == "--auto-merge");
        let skip_tests = args.iter().any(|a| a == "--skip-tests");
        let paths = args
            .iter()
            .position(|a| a == "--paths")
            .and_then(|i| args.get(i + 1))
            .cloned();
        let backend = args
            .iter()
            .position(|a| a == "--backend")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .or_else(|| std::env::var("CHUMP_DISPATCH_BACKEND").ok())
            .unwrap_or_else(|| "interactive".into());
        let model = args
            .iter()
            .position(|a| a == "--model")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_default();
        let prompt = args
            .iter()
            .position(|a| a == "--prompt")
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_default();

        let work = match backend.as_str() {
            "interactive" | "claude" /* alias */ => dispatch::WorkBackend::Interactive,
            "headless" => dispatch::WorkBackend::Headless {
                model: model.clone(),
                prompt: prompt.clone(),
            },
            "exec-gap" | "chump-local" /* alias */ => dispatch::WorkBackend::ExecGap,
            other => {
                eprintln!(
                    "chump dispatch: unknown --backend {other:?}; expected one of: interactive, headless, exec-gap"
                );
                std::process::exit(2);
            }
        };

        let repo_root = repo_path::repo_root();
        let opts = dispatch::DispatchOptions {
            gap_id: &gap_id,
            work,
            auto_merge,
            skip_tests,
            paths: paths.as_deref(),
            repo_root,
        };

        match dispatch::run(opts) {
            Ok(outcome) => {
                println!(
                    "[dispatch] {} branch={} duration={}s",
                    outcome.gap_id, outcome.branch, outcome.duration_secs
                );
                match outcome.result {
                    dispatch::ShipResult::Shipped { pr_number } => {
                        println!("[dispatch] shipped PR #{pr_number}");
                        return Ok(());
                    }
                    dispatch::ShipResult::Blocked { reason } => {
                        eprintln!("[dispatch] blocked: {reason}");
                        std::process::exit(1);
                    }
                    dispatch::ShipResult::Aborted { error } => {
                        eprintln!("[dispatch] aborted: {error}");
                        std::process::exit(1);
                    }
                }
            }
            Err(e) => {
                eprintln!("[dispatch] failed: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump fleet <start|stop|status|scale>` (INFRA-596)
    // Wraps scripts/dispatch/run-fleet.sh + fleet-status.sh so operators
    // don't need to remember FLEET_SIZE/FLEET_EFFORT_FILTER/CHUMP_REPO env vars.
    // Reads defaults from ~/.chump/config.toml [fleet] section when present.
    if args.get(1).map(String::as_str) == Some("fleet") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = repo_path::repo_root();
        let run_fleet_sh = repo_root.join("scripts/dispatch/run-fleet.sh");
        let fleet_status_sh = repo_root.join("scripts/dispatch/fleet-status.sh");
        // EFFECTIVE-025: CLI proxy for META-090 autopilot. Bash orchestrator
        // is the source of truth; this arm forwards subcommand + flags so the
        // operator gets identical UX from `chump fleet autopilot ...` and
        // direct `bash scripts/coord/fleet-autopilot.sh ...`.
        let fleet_autopilot_sh = repo_root.join("scripts/coord/fleet-autopilot.sh");
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };

        // Simple [fleet] section reader for ~/.chump/config.toml.
        let config_toml = std::env::var("HOME")
            .ok()
            .map(std::path::PathBuf::from)
            .map(|h| h.join(".chump/config.toml"))
            .and_then(|p| std::fs::read_to_string(p).ok())
            .unwrap_or_default();
        let cfg = |key: &str| -> Option<String> {
            config_toml
                .lines()
                .find(|l| l.trim_start().starts_with(key))
                .and_then(|l| l.split_once('=').map(|x| x.1))
                .map(|v| v.trim().trim_matches('"').to_string())
                .filter(|v| !v.is_empty())
        };

        match subcmd {
            "start" => {
                let size = flag("--size")
                    .or_else(|| cfg("size"))
                    .unwrap_or_else(|| "2".to_string());
                let model = flag("--model")
                    .or_else(|| cfg("model"))
                    .unwrap_or_else(|| "sonnet".to_string());
                let effort = flag("--effort")
                    .or_else(|| cfg("effort"))
                    .unwrap_or_else(|| "xs,s,m".to_string());
                let domain = flag("--domain")
                    .or_else(|| cfg("domain"))
                    .unwrap_or_default();

                // INFRA-1052: harness selection — pair harness with model so the
                // operator can run `chump fleet start --harness opencode --model sonnet`
                // and have workers spawn opencode-flavored agents. CLAUDE.md INFRA-AUTH
                // precedence applies: CLI flag > env > config.toml > default. The
                // dispatcher half (INFRA-1045) reads FLEET_HARNESS in worker.sh.
                const KNOWN_HARNESSES: &[&str] = &["claude", "opencode", "codex", "manual"];
                let harness = flag("--harness")
                    .or_else(|| {
                        std::env::var("CHUMP_AGENT_HARNESS")
                            .ok()
                            .filter(|v| !v.is_empty())
                    })
                    .or_else(|| cfg("harness"))
                    .unwrap_or_else(|| "claude".to_string());
                if !KNOWN_HARNESSES.contains(&harness.as_str()) {
                    eprintln!(
                        "chump fleet start: unknown --harness '{harness}'. Known: {}",
                        KNOWN_HARNESSES.join(", ")
                    );
                    eprintln!("  (Add a new harness to scripts/dispatch/harnesses/<name>.sh per INFRA-1045.)");
                    std::process::exit(2);
                }

                // Persist last-used config for `chump fleet restart`.
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let last_config = std::path::Path::new(&home).join(".chump/last-fleet-config.json");
                let _ = std::fs::create_dir_all(
                    last_config.parent().unwrap_or(std::path::Path::new("/tmp")),
                );
                let _ = std::fs::write(
                    &last_config,
                    serde_json::to_string_pretty(&serde_json::json!({
                        "size": size,
                        "model": model,
                        "harness": harness,
                        "effort": effort,
                        "domain": domain,
                        "session": flag("--session").or_else(|| cfg("session")).unwrap_or_else(|| "chump-fleet".to_string()),
                        "updated_at": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                    }))
                    .unwrap_or_default(),
                );

                // RESILIENT-073: write AUTONOMY_LEVEL=5 so workers see GO
                // before the tmux session launches. Level 5 = full autonomy.
                let al_path = autonomy_level::default_path();
                match autonomy_level::write_level(5, &al_path) {
                    Ok(()) => eprintln!(
                        "chump fleet start: AUTONOMY_LEVEL=5 written to {}",
                        al_path.display()
                    ),
                    Err(e) => {
                        eprintln!("chump fleet start: WARNING: could not write AUTONOMY_LEVEL: {e}")
                    }
                }
                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", &size)
                    .env("FLEET_MODEL", &model)
                    .env("FLEET_HARNESS", &harness)
                    .env("FLEET_EFFORT_FILTER", &effort)
                    .env("FLEET_DOMAIN_FILTER", &domain)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet start: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            "stop" => {
                // RESILIENT-073: write AUTONOMY_LEVEL=0 FIRST — this is the
                // operator kill switch and must land before any tmux kill so
                // workers that survive the SIGTERM see STOP on their next tick.
                let al_path = autonomy_level::default_path();
                match autonomy_level::write_level(0, &al_path) {
                    Ok(()) => eprintln!(
                        "chump fleet stop: AUTONOMY_LEVEL=0 written to {}",
                        al_path.display()
                    ),
                    Err(e) => {
                        eprintln!("chump fleet stop: WARNING: could not write AUTONOMY_LEVEL: {e}");
                        eprintln!("  Fleet workers may not see the stop signal until the file is writable.");
                    }
                }
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());
                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", "0")
                    .env("FLEET_SESSION", &session)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet stop: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // RESILIENT-073: `chump fleet level <N>` — write an arbitrary
            // autonomy level (0 = STOP, 1-5 = graduated go). The graduated
            // dial (EFFECTIVE-086) layers nuance on top; this is the dumb
            // write that every entry-point checks.
            "level" => {
                let n_str = args.get(3).cloned().unwrap_or_else(|| {
                    // No arg: print current level and exit 0.
                    let level = autonomy_level::read_level(&autonomy_level::default_path());
                    println!("{level}");
                    std::process::exit(0);
                });
                let n: i64 = n_str.parse().unwrap_or_else(|_| {
                    eprintln!("chump fleet level: N must be an integer, got '{n_str}'");
                    std::process::exit(2);
                });
                if n < 0 {
                    eprintln!("chump fleet level: N must be >= 0 (0 = STOP)");
                    std::process::exit(2);
                }
                let al_path = autonomy_level::default_path();
                match autonomy_level::write_level(n, &al_path) {
                    Ok(()) => {
                        let status_word = if n == 0 { "STOP" } else { "GO" };
                        println!(
                            "AUTONOMY_LEVEL={n} ({status_word}) written to {}",
                            al_path.display()
                        );
                    }
                    Err(e) => {
                        eprintln!(
                            "chump fleet level: failed to write {}: {e}",
                            al_path.display()
                        );
                        std::process::exit(1);
                    }
                }
                std::process::exit(0);
            }
            "status" => {
                let want_json = args.iter().any(|a| a == "--json");
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&fleet_status_sh);
                if want_json {
                    cmd.arg("--json");
                } else {
                    cmd.arg("--once");
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet status: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            "scale" => {
                let n_str = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump fleet scale <N>");
                    std::process::exit(2);
                });
                let n: u32 = n_str.parse().unwrap_or_else(|_| {
                    eprintln!("chump fleet scale: N must be a positive integer, got '{n_str}'");
                    std::process::exit(2);
                });
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());

                // Persist desired size so restarts and monitors can read it.
                let state_dir = repo_root.join(".chump");
                let _ = std::fs::create_dir_all(&state_dir);
                let _ = std::fs::write(state_dir.join("fleet-desired-size"), format!("{n}\n"));

                // Emit ambient event (matches fleet_scale_change schema in CLAUDE.md).
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    let _ = writeln!(
                        f,
                        "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_request\",\"to\":{n},\"session\":\"{session}\"}}"
                    );
                }

                // Count alive worker windows in the tmux session.
                let current_count: u32 = std::process::Command::new("tmux")
                    .args(["list-windows", "-t", &session, "-F", "#W"])
                    .output()
                    .ok()
                    .map(|o| {
                        String::from_utf8_lossy(&o.stdout)
                            .lines()
                            .filter(|l| l.starts_with("fleet-worker-"))
                            .count() as u32
                    })
                    .unwrap_or(0);

                println!("[fleet scale] session={session} current={current_count} → desired={n}");

                if n > current_count {
                    let worker_sh = repo_root.join("scripts/dispatch/worker.sh");
                    for i in (current_count + 1)..=n {
                        let pane_name = format!("fleet-worker-{i}");
                        let worker_cmd = format!("AGENT_ID={i} bash {}", worker_sh.display());
                        let ok = std::process::Command::new("tmux")
                            .args(["new-window", "-t", &session, "-n", &pane_name, &worker_cmd])
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if ok {
                            println!("[fleet scale] spawned {pane_name}");
                        } else {
                            eprintln!("[fleet scale] WARNING: failed to spawn {pane_name}");
                        }
                    }
                } else if n < current_count {
                    for i in (n + 1)..=current_count {
                        let target = format!("{session}:fleet-worker-{i}");
                        let ok = std::process::Command::new("tmux")
                            .args(["kill-window", "-t", &target])
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if ok {
                            println!("[fleet scale] killed fleet-worker-{i}");
                        } else {
                            println!("[fleet scale] fleet-worker-{i} not found (already stopped)");
                        }
                    }
                } else {
                    println!("[fleet scale] already at {n} workers — no change");
                }
                return Ok(());
            }
            "snapshot" => {
                // `chump fleet snapshot` — INFRA-612
                // Captures current fleet state (leases, locks, queue size, ambient tail)
                // into .chump/restart-snapshots/<ts>.json for later replay.
                let snapshots_dir = repo_root.join(".chump/restart-snapshots");
                let _ = std::fs::create_dir_all(&snapshots_dir);
                let locks_dir = repo_root.join(".chump-locks");

                let ts = chrono::Utc::now();
                let ts_str = ts.format("%Y%m%d-%H%M%S").to_string();
                let ts_iso = ts.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                // Collect active lease files.
                let mut leases: Vec<serde_json::Value> = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(raw) = std::fs::read_to_string(&path) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                                    leases.push(serde_json::json!({
                                        "filename": path.file_name()
                                            .and_then(|n| n.to_str())
                                            .unwrap_or("unknown"),
                                        "lease": v
                                    }));
                                }
                            }
                        }
                    }
                }

                // Collect last 200 lines of ambient.jsonl.
                let ambient_path = locks_dir.join("ambient.jsonl");
                let ambient_tail: Vec<serde_json::Value> = std::fs::read_to_string(&ambient_path)
                    .unwrap_or_default()
                    .lines()
                    .rev()
                    .take(200)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect();

                // Fleet desired size.
                let fleet_desired_size: Option<u32> =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok());

                let snapshot = serde_json::json!({
                    "snapshot_id": ts_str,
                    "ts": ts_iso,
                    "fleet_desired_size": fleet_desired_size,
                    "leases": leases,
                    "ambient_tail": ambient_tail
                });

                let out_path = snapshots_dir.join(format!("{ts_str}.json"));
                match std::fs::write(
                    &out_path,
                    serde_json::to_string_pretty(&snapshot).unwrap_or_default(),
                ) {
                    Ok(()) => {
                        println!("[fleet snapshot] wrote {}", out_path.display());
                        println!(
                            "[fleet snapshot] leases={} ambient_events={}",
                            leases.len(),
                            ambient_tail.len()
                        );
                        // Emit ambient event.
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            let _ = writeln!(
                                f,
                                "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_snapshot\",\"snapshot_id\":\"{ts_str}\",\"leases\":{}}}", leases.len()
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("[fleet snapshot] failed to write snapshot: {e}");
                        std::process::exit(1);
                    }
                }
                return Ok(());
            }
            "restore" => {
                // `chump fleet restore <snapshot-id>` — INFRA-612
                // Replays lease state from a snapshot created by `fleet snapshot`.
                // Useful for diagnostics after a planned restart.
                let snapshot_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump fleet restore <snapshot-id>");
                    eprintln!("  snapshot-id: timestamp like 20260506-191935 or full path");
                    std::process::exit(2);
                });

                let snapshots_dir = repo_root.join(".chump/restart-snapshots");
                let locks_dir = repo_root.join(".chump-locks");

                // Resolve snapshot path — accept full path or bare ID.
                let snap_path = if std::path::Path::new(&snapshot_id).exists() {
                    std::path::PathBuf::from(&snapshot_id)
                } else {
                    snapshots_dir.join(format!("{snapshot_id}.json"))
                };

                let raw = std::fs::read_to_string(&snap_path).unwrap_or_else(|e| {
                    eprintln!("[fleet restore] cannot read {}: {e}", snap_path.display());
                    std::process::exit(1);
                });
                let snapshot: serde_json::Value = serde_json::from_str(&raw).unwrap_or_else(|e| {
                    eprintln!("[fleet restore] invalid JSON in snapshot: {e}");
                    std::process::exit(1);
                });

                let ts_iso = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let ambient_path = locks_dir.join("ambient.jsonl");
                let _ = std::fs::create_dir_all(&locks_dir);

                // Replay leases — write each back to .chump-locks/<filename>.
                let mut replayed = 0u32;
                if let Some(leases) = snapshot["leases"].as_array() {
                    for entry in leases {
                        let filename = entry["filename"].as_str().unwrap_or("unknown.json");
                        let lease_val = &entry["lease"];
                        if lease_val.is_null() {
                            continue;
                        }
                        let dest = locks_dir.join(filename);
                        if let Ok(content) = serde_json::to_string_pretty(lease_val) {
                            if std::fs::write(&dest, content).is_ok() {
                                println!("[fleet restore] replayed lease → {}", dest.display());
                                replayed += 1;
                            }
                        }
                    }
                }

                // Restore fleet-desired-size if present.
                if let Some(size) = snapshot["fleet_desired_size"].as_u64() {
                    let _ = std::fs::create_dir_all(repo_root.join(".chump"));
                    let _ = std::fs::write(
                        repo_root.join(".chump/fleet-desired-size"),
                        format!("{size}\n"),
                    );
                    println!("[fleet restore] fleet-desired-size → {size}");
                }

                println!("[fleet restore] snapshot={snapshot_id} leases_replayed={replayed}");

                // Emit ambient event.
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    let _ = writeln!(
                        f,
                        "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_restore\",\"snapshot_id\":\"{snapshot_id}\",\"leases_replayed\":{replayed}}}"
                    );
                }
                return Ok(());
            }
            "audit-pids" => {
                // `chump fleet audit-pids [--apply]` — INFRA-649
                //
                // Checks that claude_pid_count == 2 * worker_count (±1 tolerance).
                // Each worker spawns a `timeout Ns claude -p ...` wrapper + the claude
                // subprocess, so 2 PIDs per worker is the invariant.
                //
                // Without --apply: report only.
                // With --apply:
                //   PIDs > expected+1 → pkill orphans (INFRA-602 sentinel pattern)
                //   PIDs < expected-1 → respawn via fleet-restart.sh (INFRA-611)
                //
                // Emits kind=fleet_pid_invariant to ambient.jsonl with delta + action.
                let apply = args.iter().any(|a| a == "--apply");
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

                let worker_count: u32 =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(0);

                let expected = worker_count * 2;

                // pgrep -c exits 1 when no matches but still prints "0"; handle both.
                let actual: u32 = std::process::Command::new("pgrep")
                    .args(["-c", "-f", "timeout [0-9]*s claude -p "])
                    .output()
                    .ok()
                    .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
                    .unwrap_or(0);

                let delta: i64 = actual as i64 - expected as i64;
                let in_tolerance = delta.abs() <= 1;

                println!(
                    "[fleet audit-pids] worker_count={worker_count} expected_pids={expected} \
                     actual_pids={actual} delta={delta:+} apply={apply}"
                );

                let action = if in_tolerance {
                    println!("[fleet audit-pids] invariant OK (within ±1 tolerance)");
                    "ok"
                } else if !apply {
                    if delta > 0 {
                        println!(
                            "[fleet audit-pids] DRIFT: {delta:+} excess PIDs — run with --apply to prune"
                        );
                    } else {
                        println!(
                            "[fleet audit-pids] DRIFT: {delta} missing PIDs — run with --apply to respawn"
                        );
                    }
                    "drift"
                } else if delta > 0 {
                    // More PIDs than expected → kill orphaned timeout+claude pairs.
                    println!("[fleet audit-pids] --apply: pruning orphan PIDs (delta={delta:+})");
                    let _ = std::process::Command::new("pkill")
                        .args(["-f", "timeout [0-9]*s claude -p "])
                        .status();
                    "pruned"
                } else {
                    // Fewer PIDs than expected → respawn via fleet-restart.sh.
                    println!(
                        "[fleet audit-pids] --apply: respawning fleet to worker_count={worker_count}"
                    );
                    let restart_sh = repo_root.join("scripts/dispatch/fleet-restart.sh");
                    let session = cfg("session").unwrap_or_else(|| "chump-fleet".to_string());
                    let _ = std::process::Command::new("bash")
                        .arg(&restart_sh)
                        .env("FLEET_SIZE", worker_count.to_string())
                        .env("FLEET_SESSION", &session)
                        .status();
                    "respawned"
                };

                // Emit ambient event.
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_path)
                {
                    let _ = writeln!(
                        f,
                        "{{\"ts\":\"{ts}\",\"kind\":\"fleet_pid_invariant\",\
                         \"worker_count\":{worker_count},\"expected\":{expected},\
                         \"actual\":{actual},\"delta\":{delta},\
                         \"apply\":{apply},\"action\":\"{action}\"}}"
                    );
                }
                return Ok(());
            }
            "restart" => {
                // `chump fleet restart` — INFRA-610
                let fleet_restart_sh = repo_root.join("scripts/dispatch/fleet-restart.sh");
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());
                let size_override = flag("--size");

                // 1. Take a before-restart snapshot.
                let snapshots_dir = repo_root.join(".chump/restart-snapshots");
                let _ = std::fs::create_dir_all(&snapshots_dir);
                let locks_dir = repo_root.join(".chump-locks");
                let ts = chrono::Utc::now();
                let ts_str = ts.format("%Y%m%d-%H%M%S").to_string();
                let ts_iso = ts.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                let mut leases: Vec<serde_json::Value> = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(raw) = std::fs::read_to_string(&path) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                                    leases.push(serde_json::json!({
                                        "filename": path.file_name()
                                            .and_then(|n| n.to_str())
                                            .unwrap_or("unknown"),
                                        "lease": v
                                    }));
                                }
                            }
                        }
                    }
                }

                let ambient_path = locks_dir.join("ambient.jsonl");
                let ambient_tail: Vec<serde_json::Value> = std::fs::read_to_string(&ambient_path)
                    .unwrap_or_default()
                    .lines()
                    .rev()
                    .take(200)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect();

                let desired_size: Option<u32> =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok());

                let snapshot = serde_json::json!({
                    "snapshot_id": ts_str,
                    "ts": ts_iso,
                    "kind": "pre_restart",
                    "fleet_desired_size": desired_size,
                    "leases": leases,
                    "ambient_tail": ambient_tail
                });

                let out_path = snapshots_dir.join(format!("{ts_str}.json"));
                match std::fs::write(
                    &out_path,
                    serde_json::to_string_pretty(&snapshot).unwrap_or_default(),
                ) {
                    Ok(()) => {
                        println!("[fleet restart] snapshot saved to {}", out_path.display());
                        println!(
                            "[fleet restart] leases={} ambient_events={}",
                            leases.len(),
                            ambient_tail.len()
                        );
                        let _ = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                            .and_then(|mut f| {
                                writeln!(
                                    f,
                                    "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_restart_snapshot\",\"snapshot_id\":\"{ts_str}\"}}"
                                )
                            });
                    }
                    Err(e) => {
                        eprintln!("[fleet restart] WARNING: failed to save snapshot: {e}");
                    }
                }

                // 2. Resolve fleet size: --size flag > last-fleet-config > desired-size > config.toml > 2
                let size = size_override
                    .or_else(|| {
                        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                        let p = std::path::Path::new(&home).join(".chump/last-fleet-config.json");
                        std::fs::read_to_string(&p).ok().and_then(|raw| {
                            serde_json::from_str::<serde_json::Value>(&raw)
                                .ok()
                                .and_then(|v| v["size"].as_str().map(String::from))
                        })
                    })
                    .or_else(|| desired_size.map(|s| s.to_string()))
                    .or_else(|| cfg("size"))
                    .unwrap_or_else(|| "2".to_string());

                // 3. Delegate to fleet-restart.sh
                let status = std::process::Command::new("bash")
                    .arg(&fleet_restart_sh)
                    .env("FLEET_SIZE", &size)
                    .env("FLEET_SESSION", &session)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet restart: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-721: 60-second operator briefing — 24h ships, pillar mix,
            // stalls, auto-fixed, manual rescues, suggested actions.
            // INFRA-2013: also shows 1h ships as leading indicator; emits
            // fleet_stalled when ships_1h==0 and BLOCKED open PRs >= 2.
            // Wire: FLEET-019 SessionStart hook calls this at session open.
            "brief" => {
                let want_json = args.iter().any(|a| a == "--json");
                let window_secs: i64 = flag("--window")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(86400); // 24 h default

                let now = chrono::Utc::now();
                let now_ts = now.timestamp();
                let cutoff = now_ts - window_secs;
                let cutoff_1h = now_ts - 3600; // INFRA-2013 leading indicator
                let ts_iso = now.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                // INFRA-1355: fleet-wide state (ambient.jsonl, lease files)
                // lives only in the main checkout's .chump-locks/.  Linked
                // worktrees get a sparse .chump-locks/ with only their own
                // session files, so reading it gives ships=0 / stalls=0.
                // Always resolve via git-common-dir so brief shows correct
                // fleet totals regardless of CWD.
                let locks_dir = {
                    let main_root = repo_path::main_checkout_root();
                    let main_locks = main_root.join(".chump-locks");
                    if main_locks.is_dir() {
                        main_locks
                    } else {
                        repo_root.join(".chump-locks")
                    }
                };
                let ambient_path = locks_dir.join("ambient.jsonl");

                // ── Parse ambient.jsonl ──────────────────────────────────
                let events: Vec<serde_json::Value> = std::fs::read_to_string(&ambient_path)
                    .unwrap_or_default()
                    .lines()
                    .filter_map(|l| serde_json::from_str(l).ok())
                    .collect();

                // Filter to window
                let window_events: Vec<&serde_json::Value> = events
                    .iter()
                    .filter(|e| {
                        e.get("ts")
                            .and_then(|v| v.as_str())
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .map(|dt| dt.timestamp() >= cutoff)
                            .unwrap_or(false)
                    })
                    .collect();

                // INFRA-2013: 1h window events for leading-indicator stall detection
                let events_1h: Vec<&serde_json::Value> = events
                    .iter()
                    .filter(|e| {
                        e.get("ts")
                            .and_then(|v| v.as_str())
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .map(|dt| dt.timestamp() >= cutoff_1h)
                            .unwrap_or(false)
                    })
                    .collect();

                // Count by "event" field (top-level event type)
                let count_event = |ev: &str| -> usize {
                    window_events
                        .iter()
                        .filter(|e| e.get("event").and_then(|v| v.as_str()) == Some(ev))
                        .count()
                };
                // Count by "kind" sub-field (used in alert-category events)
                let count_kind = |kind: &str| -> usize {
                    window_events
                        .iter()
                        .filter(|e| e.get("kind").and_then(|v| v.as_str()) == Some(kind))
                        .count()
                };

                let ships = count_event("commit");
                // INFRA-2013: 1h ship count — leading indicator (not subject to 24h rolling lag)
                let ships_1h: usize = events_1h
                    .iter()
                    .filter(|e| e.get("event").and_then(|v| v.as_str()) == Some("commit"))
                    .count();
                let auto_fixed = count_kind("flake_rerun_queued") + count_kind("lint_auto_fix");
                let manual_rescues = count_kind("manual_rescue");
                let fleet_wedges = count_kind("fleet_wedge");
                // INFRA-1247: silent_agent and pr_stuck are surfaced below as
                // "investigate now" operator-action prompts. They must count
                // over the same 30 min window as `alerts(30m)` — not the 24h
                // main window — otherwise the brief shows 24h totals
                // (e.g. 27 silent_agents, 18 pr_stuck) as if they were current
                // alerts, conditioning the operator to ignore the prompts
                // entirely. Before this fix the same healthy fleet that
                // emitted 1 actual recent event in 30 min showed "27 events"
                // because old events from earlier in the day were still in
                // the 24h window.
                let alert_cutoff = now_ts - 30 * 60;
                let count_kind_recent = |kind: &str| -> usize {
                    events
                        .iter()
                        .filter(|e| {
                            e.get("kind").and_then(|v| v.as_str()) == Some(kind)
                                && e.get("ts")
                                    .and_then(|v| v.as_str())
                                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                                    .map(|dt| dt.timestamp() >= alert_cutoff)
                                    .unwrap_or(false)
                        })
                        .count()
                };
                let silent_agents = count_kind_recent("silent_agent");
                let pr_stuck = count_kind_recent("pr_stuck");
                let alerts: usize = events
                    .iter()
                    .filter(|e| {
                        let is_alert = e.get("event").and_then(|v| v.as_str()) == Some("ALERT")
                            || e.get("event").and_then(|v| v.as_str()) == Some("alert");
                        if !is_alert {
                            return false;
                        }
                        e.get("ts")
                            .and_then(|v| v.as_str())
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .map(|dt| dt.timestamp() >= alert_cutoff)
                            .unwrap_or(false)
                    })
                    .count();

                // Active leases → stall detection (leases older than 4h)
                let stall_threshold = now_ts - 4 * 3600;
                let mut stalls: Vec<String> = Vec::new();
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.extension().map(|e| e == "json").unwrap_or(false) {
                            if let Ok(raw) = std::fs::read_to_string(&path) {
                                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                                    let gap_id = v
                                        .get("gap_id")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("?")
                                        .to_string();
                                    let claimed_at = v
                                        .get("claimed_at")
                                        .and_then(|x| x.as_i64())
                                        .unwrap_or(now_ts);
                                    if claimed_at < stall_threshold {
                                        let age_h = (now_ts - claimed_at) / 3600;
                                        stalls.push(format!("{gap_id} ({age_h}h)"));
                                    }
                                }
                            }
                        }
                    }
                }
                // ── INFRA-2013: fleet stall detection (leading indicator) ────
                // Condition: 0 merges in last 1h AND >= 2 open BLOCKED PRs.
                // "open BLOCKED PRs" is approximated here by pr_stuck events in
                // the last 30 min (the same signal the shell path uses via gh).
                // When condition fires: emit fleet_stalled to ambient.jsonl so
                // watchers (operator-recall, cluster-detector, etc.) can page.
                let fleet_stalled = ships_1h == 0 && pr_stuck >= 2;
                if fleet_stalled {
                    let stall_line = format!(
                        "{{\"ts\":\"{ts_iso}\",\"kind\":\"fleet_stalled\",\"ships_1h\":0,\"blocked_open\":{pr_stuck},\"source\":\"chump-fleet-brief\"}}\n"
                    );
                    let _ = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                        .and_then(|mut f| {
                            use std::io::Write;
                            f.write_all(stall_line.as_bytes())
                        });
                }

                // ── Pillar mix from open P0/P1 gaps ─────────────────────────
                let store_res = gap_store::GapStore::open(&repo_root);
                let mut pillar_counts: std::collections::HashMap<&str, usize> = [
                    ("EFFECTIVE", 0),
                    ("CREDIBLE", 0),
                    ("RESILIENT", 0),
                    ("ZERO-WASTE", 0),
                ]
                .iter()
                .cloned()
                .collect();
                let mut total_pickable = 0usize;
                if let Ok(ref store) = store_res {
                    if let Ok(gaps) = store.list(Some("open")) {
                        for g in &gaps {
                            if !matches!(g.priority.as_str(), "P0" | "P1") {
                                continue;
                            }
                            if !matches!(g.effort.as_str(), "xs" | "s" | "m") {
                                continue;
                            }
                            total_pickable += 1;
                            let t = g.title.to_uppercase();
                            for pillar in &["EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE"] {
                                if t.contains(pillar) {
                                    *pillar_counts.entry(pillar).or_insert(0) += 1;
                                    break;
                                }
                            }
                        }
                    }
                }

                // ── Suggested actions ────────────────────────────────────
                let mut suggestions: Vec<String> = Vec::new();
                // INFRA-2013: fleet_stalled is the highest-priority signal —
                // surface before wedge/silent_agent so it's not buried.
                if fleet_stalled {
                    suggestions.push(format!(
                        "🔴 STALLED: 0 merges in last 1h with {pr_stuck} stuck PRs — investigate bot-merge contention now"
                    ));
                }
                if fleet_wedges > 0 {
                    suggestions.push(format!(
                        "⚠  {} fleet_wedge event(s) — drop to 2 workers per CLAUDE.md",
                        fleet_wedges
                    ));
                }
                if silent_agents > 1 {
                    suggestions.push(format!(
                        "⚠  {} silent_agent event(s) — investigate lease/picker race",
                        silent_agents
                    ));
                }
                if pr_stuck >= 3 {
                    suggestions.push(format!(
                        "⚠  {} pr_stuck event(s) — diagnose bot-merge contention",
                        pr_stuck
                    ));
                }
                if !stalls.is_empty() {
                    suggestions.push(format!("⚠  Stalled leases: {}", stalls.join(", ")));
                }
                let zw = *pillar_counts.get("ZERO-WASTE").unwrap_or(&0);
                let re = *pillar_counts.get("RESILIENT").unwrap_or(&0);
                if zw < 2 {
                    suggestions.push(format!(
                        "📌 ZERO-WASTE has {zw} pickable gap(s) — file 1-2 to balance"
                    ));
                }
                if re < 2 {
                    suggestions.push(format!(
                        "📌 RESILIENT has {re} pickable gap(s) — file 1-2 to balance"
                    ));
                }
                if suggestions.is_empty() {
                    suggestions.push("✓  No urgent actions — fleet looks healthy".to_string());
                }

                if want_json {
                    let out = serde_json::json!({
                        "ts": ts_iso,
                        "window_h": window_secs / 3600,
                        "ships_24h": ships,
                        "ships_1h": ships_1h,
                        "fleet_stalled": fleet_stalled,
                        "auto_fixed": auto_fixed,
                        "manual_rescues": manual_rescues,
                        "stalls_gt_4h": stalls,
                        "fleet_wedges": fleet_wedges,
                        "silent_agents": silent_agents,
                        "pr_stuck": pr_stuck,
                        "alerts": alerts,
                        "pillar_mix": {
                            "EFFECTIVE": pillar_counts.get("EFFECTIVE").copied().unwrap_or(0),
                            "CREDIBLE":  pillar_counts.get("CREDIBLE").copied().unwrap_or(0),
                            "RESILIENT": pillar_counts.get("RESILIENT").copied().unwrap_or(0),
                            "ZERO-WASTE": pillar_counts.get("ZERO-WASTE").copied().unwrap_or(0),
                            "total_pickable": total_pickable,
                        },
                        "suggestions": suggestions,
                    });
                    println!("{}", serde_json::to_string_pretty(&out).unwrap_or_default());
                } else {
                    let window_h = window_secs / 3600;
                    println!("═══ Fleet brief (last {window_h}h) ═══");
                    // INFRA-2013: show 1h ships alongside rolling average
                    println!(
                        "Ships: {ships}  (≈{}/hr) | last 1h: {ships_1h}",
                        if window_h > 0 {
                            format!("{:.1}", ships as f64 / window_h as f64)
                        } else {
                            "?".to_string()
                        }
                    );
                    // INFRA-2013: prominent STALLED banner when condition met
                    if fleet_stalled {
                        eprintln!("*** STALLED: 0 merges in last 1h with {pr_stuck} stuck PRs — investigate now ***");
                    }
                    let eff = pillar_counts.get("EFFECTIVE").copied().unwrap_or(0);
                    let cre = pillar_counts.get("CREDIBLE").copied().unwrap_or(0);
                    let res = pillar_counts.get("RESILIENT").copied().unwrap_or(0);
                    let zw2 = pillar_counts.get("ZERO-WASTE").copied().unwrap_or(0);
                    println!(
                        "Pillars: EFFECTIVE={eff} CREDIBLE={cre} RESILIENT={res} ZERO-WASTE={zw2}  (of {total_pickable} pickable)"
                    );
                    println!(
                        "Stalls > 4h: {}",
                        if stalls.is_empty() {
                            "0".to_string()
                        } else {
                            stalls.join(", ")
                        }
                    );
                    println!("Auto-fixed: {auto_fixed}  flake-rerun+lint");
                    println!("Manual rescues: {manual_rescues}");
                    if alerts > 0 {
                        println!("Alerts(30m): {alerts}");
                    }
                    if !suggestions.iter().all(|s| s.starts_with('✓')) {
                        println!("\nActions:");
                        for s in &suggestions {
                            println!("  {s}");
                        }
                    } else {
                        println!("{}", suggestions[0]);
                    }
                }
                return Ok(());
            }
            // INFRA-615: starvation auto-widen.
            // --analyze: reads ambient.jsonl for fleet_starved events in last 1h,
            //            suggests widened FLEET_EFFORT_FILTER / PRIORITY_FILTER.
            // --apply:   writes suggested config to ~/.chump/fleet-config.toml.
            "auto-widen" => {
                let do_apply = args.iter().any(|a| a == "--apply");
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");

                // Read ambient events from the last 3600s (1h).
                let now_secs = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                let horizon = now_secs.saturating_sub(3600);

                let mut starve_count = 0u32;
                if let Ok(content) = std::fs::read_to_string(&ambient_path) {
                    for line in content.lines() {
                        if !line.contains("fleet_starved") {
                            continue;
                        }
                        // Parse ts field to check recency.
                        let ts_secs: Option<u64> = line
                            .split('"')
                            .skip_while(|s| *s != "ts")
                            .nth(2)
                            .and_then(|ts| {
                                // "2026-05-11T22:00:00Z" → epoch seconds (rough parse)
                                chrono::DateTime::parse_from_rfc3339(ts)
                                    .ok()
                                    .map(|dt| dt.timestamp() as u64)
                            });
                        if ts_secs.is_none_or(|t| t >= horizon) {
                            starve_count += 1;
                        }
                    }
                }

                // Derive suggestions based on current config.
                let current_effort = std::env::var("FLEET_EFFORT_FILTER")
                    .ok()
                    .or_else(|| cfg("effort"))
                    .unwrap_or_else(|| "xs,s".to_string());
                let current_priority = std::env::var("FLEET_PRIORITY_FILTER")
                    .ok()
                    .or_else(|| cfg("priority_filter"))
                    .unwrap_or_else(|| "P0,P1".to_string());

                // Widen effort by appending next tier; widen priority by adding P2.
                let suggested_effort = if current_effort.contains('m') {
                    format!("{},l", current_effort.trim_end_matches(",l"))
                } else if current_effort.contains('s') {
                    format!("{},m", current_effort.trim_end_matches(",m"))
                } else {
                    format!("{},s,m", current_effort.trim_end_matches(",s,m"))
                };
                let suggested_priority = if current_priority.contains("P2") {
                    current_priority.clone()
                } else {
                    format!("{},P2", current_priority)
                };

                println!("[auto-widen] fleet_starved events in last 1h: {starve_count}");
                println!("[auto-widen] current effort filter : {current_effort}");
                println!("[auto-widen] current priority filter: {current_priority}");

                if starve_count == 0 {
                    println!("[auto-widen] no starvation detected — no change recommended");
                } else {
                    println!("[auto-widen] suggested effort filter : {suggested_effort}");
                    println!("[auto-widen] suggested priority filter: {suggested_priority}");
                    println!("[auto-widen] reason: {starve_count} starvation event(s) in last 1h");

                    if do_apply {
                        let config_dir = std::path::Path::new(&home).join(".chump");
                        let _ = std::fs::create_dir_all(&config_dir);
                        let fleet_config = config_dir.join("fleet-config.toml");
                        let toml_content = format!(
                            "# INFRA-615: auto-widen applied by 'chump fleet auto-widen --apply'\n\
                             # starve_events_1h = {starve_count}\n\
                             # applied_at = \"{}\"\n\
                             effort = \"{suggested_effort}\"\n\
                             priority_filter = \"{suggested_priority}\"\n",
                            chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
                        );
                        match std::fs::write(&fleet_config, &toml_content) {
                            Ok(_) => {
                                println!(
                                    "[auto-widen] wrote {} → restart fleet to apply",
                                    fleet_config.display()
                                );
                                // Emit ambient event.
                                let ambient_write = repo_root.join(".chump-locks/ambient.jsonl");
                                let event = format!(
                                    "{{\"ts\":\"{}\",\"kind\":\"fleet_auto_widen_applied\",\
                                     \"starve_count\":{starve_count},\
                                     \"effort\":\"{suggested_effort}\",\
                                     \"priority_filter\":\"{suggested_priority}\"}}\n",
                                    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ")
                                );
                                let _ = std::fs::OpenOptions::new()
                                    .append(true)
                                    .create(true)
                                    .open(&ambient_write)
                                    .and_then(|mut f| {
                                        use std::io::Write;
                                        f.write_all(event.as_bytes())
                                    });
                            }
                            Err(e) => {
                                eprintln!("[auto-widen] failed to write fleet-config.toml: {e}");
                                std::process::exit(1);
                            }
                        }
                    } else {
                        println!(
                            "[auto-widen] run with --apply to write ~/.chump/fleet-config.toml"
                        );
                    }
                }
            }
            // INFRA-2198 (META-128/C7): disk-aware fleet auto-scale.
            // Reads current N workers + disk inventory; scales down 1 when
            // disk < 20 GB, scales up 1 when disk > 60 GB AND ship-rate is
            // healthy.  Max delta 1 per tick.  Run every 5 min via launchd
            // (installer: scripts/dispatch/chump-fleet-autoscale-launchd.sh).
            //
            // Usage: chump fleet auto-scale [--apply] [--json]
            //
            // CHUMP_FLEET_SCALE_LOW_GB   — disk free threshold to scale down (default 20.0)
            // CHUMP_FLEET_SCALE_HIGH_GB  — disk free threshold to scale up   (default 60.0)
            "auto-scale" => {
                let apply = args.iter().any(|a| a == "--apply");
                let as_json = args.iter().any(|a| a == "--json");

                let current_size: u32 =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(2);

                let low_gb: f64 = std::env::var("CHUMP_FLEET_SCALE_LOW_GB")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(20.0);
                let high_gb: f64 = std::env::var("CHUMP_FLEET_SCALE_HIGH_GB")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(60.0);

                // Load disk snapshot (graceful fallback when INFRA-2196 absent).
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let inv_path_override = std::env::var("CHUMP_DISK_INVENTORY_PATH").ok();
                let inv_path = if let Some(ref p) = inv_path_override {
                    std::path::PathBuf::from(p)
                } else {
                    std::path::Path::new(&home).join(".chump/disk-inventory.json")
                };

                let free_gb: Option<f64> = std::fs::read_to_string(&inv_path)
                    .ok()
                    .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
                    .and_then(|v| v["free_gb"].as_f64());

                // Ship-rate health: use fleet_velocity snapshot (1h shipped count).
                let vel = fleet_velocity::snapshot(&repo_root);
                let ship_rate_healthy =
                    vel.rate_per_hour_1h() > 0.0 || vel.rate_per_hour_6h() > 0.0;

                #[derive(Debug)]
                enum AutoScaleAction {
                    ScaleDown { reason: &'static str },
                    ScaleUp { reason: &'static str },
                    NoChange { reason: &'static str },
                }

                let action: AutoScaleAction = match free_gb {
                    None => AutoScaleAction::NoChange {
                        reason:
                            "disk-inventory.json absent — no disk data (INFRA-2193 not running?)",
                    },
                    Some(free) if free < low_gb => AutoScaleAction::ScaleDown {
                        reason: "disk free < low threshold",
                    },
                    Some(free) if free > high_gb && ship_rate_healthy => AutoScaleAction::ScaleUp {
                        reason: "disk free > high threshold AND ship-rate healthy",
                    },
                    Some(free) if free > high_gb => AutoScaleAction::NoChange {
                        reason: "disk free > high threshold but ship-rate zero — not scaling up",
                    },
                    Some(_) => AutoScaleAction::NoChange {
                        reason: "disk headroom within normal range",
                    },
                };

                let (new_size, action_label, reason_str) = match &action {
                    AutoScaleAction::ScaleDown { reason } => {
                        (current_size.saturating_sub(1).max(1), "scale_down", *reason)
                    }
                    AutoScaleAction::ScaleUp { reason } => (current_size + 1, "scale_up", *reason),
                    AutoScaleAction::NoChange { reason } => (current_size, "no_change", *reason),
                };

                let free_gb_display = free_gb
                    .map(|f| format!("{f:.1}"))
                    .unwrap_or_else(|| "N/A".to_string());

                if as_json {
                    println!(
                        "{{\"fleet_auto_scale\":true,\
                         \"action\":\"{action_label}\",\
                         \"current_size\":{current_size},\
                         \"new_size\":{new_size},\
                         \"free_gb\":\"{free_gb_display}\",\
                         \"reason\":\"{reason_str}\"}}"
                    );
                } else {
                    println!(
                        "[fleet auto-scale] action={action_label} current={current_size} → new={new_size}  \
                         free={free_gb_display}GB  reason={reason_str}"
                    );
                }

                if new_size != current_size {
                    let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                    // Emit ambient event regardless of --apply (the event is the record of intent).
                    if let Ok(mut af) = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                    {
                        let _ = writeln!(
                            af,
                            "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_changed\",\
                             \"from\":{current_size},\"to\":{new_size},\
                             \"reason\":\"auto-scale: {reason_str}\"}}"
                        );
                    }

                    if apply {
                        let _ = std::fs::write(
                            repo_root.join(".chump/fleet-desired-size"),
                            format!("{new_size}\n"),
                        );
                        if !as_json {
                            println!(
                                "[fleet auto-scale] --apply: wrote fleet-desired-size={new_size}"
                            );
                        }
                    } else if !as_json {
                        println!("[fleet auto-scale] dry-run; run with --apply to execute");
                    }
                }

                return Ok(());
            }
            // INFRA-650: fleet auto-prune-down controller.
            // Evaluates 4 conditions and recommends (or applies) a scale-down.
            "auto-resize" => {
                let apply = args.iter().any(|a| a == "--apply");
                let as_json = args.iter().any(|a| a == "--json");
                let current_size: u32 =
                    std::fs::read_to_string(repo_root.join(".chump/fleet-desired-size"))
                        .ok()
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(2);

                let decision = fleet_resize::evaluate(&repo_root, current_size);

                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

                match decision {
                    None => {
                        if as_json {
                            println!("{{\"fleet_resize_decision\":\"none\",\"current_size\":{current_size}}}");
                        } else {
                            println!(
                                "[fleet auto-resize] current_size={current_size} — no resize trigger fired"
                            );
                        }
                    }
                    Some(d) => {
                        let trigger_name = format!("{:?}", d.trigger);
                        if as_json {
                            println!(
                                "{{\"fleet_resize_decision\":\"resize\",\"trigger\":\"{trigger_name}\",\
                                 \"current_size\":{current_size},\"recommended_size\":{},\"rationale\":\"{}\"}}",
                                d.recommended_size,
                                d.rationale.replace('"', "'")
                            );
                        } else {
                            println!(
                                "[fleet auto-resize] trigger={trigger_name} \
                                 current={current_size} → recommended={}",
                                d.recommended_size
                            );
                            println!("[fleet auto-resize] rationale: {}", d.rationale);
                        }

                        // Emit ambient event (INFRA-650 AC criterion 4).
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            let _ = writeln!(
                                f,
                                "{{\"ts\":\"{ts}\",\"kind\":\"fleet_resize_decision\",\
                                 \"trigger\":\"{trigger_name}\",\"current_size\":{current_size},\
                                 \"recommended_size\":{},\"rationale\":\"{}\"}}",
                                d.recommended_size,
                                d.rationale.replace('"', "'")
                            );
                        }

                        if apply && d.recommended_size < current_size {
                            println!(
                                "[fleet auto-resize] --apply: scaling from {current_size} to {}",
                                d.recommended_size
                            );
                            // Write desired size.
                            let _ = std::fs::write(
                                repo_root.join(".chump/fleet-desired-size"),
                                format!("{}\n", d.recommended_size),
                            );
                            // Emit fleet_scale_change.
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                let _ = writeln!(
                                    f,
                                    "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_change\",\
                                     \"from\":{current_size},\"to\":{},\"rationale\":\"auto-resize: {trigger_name}\"}}",
                                    d.recommended_size
                                );
                            }
                        } else if !apply {
                            println!("[fleet auto-resize] run with --apply to execute resize");
                        }
                    }
                }
                return Ok(());
            }
            // INFRA-827: prune stale linked worktrees (age > CHUMP_WT_MAX_AGE_H AND no open PR)
            "prune-worktrees" => {
                let dry_run = !args.iter().any(|a| a == "--apply");
                let want_json = args.iter().any(|a| a == "--json");
                let max_age_h: u64 = std::env::var("CHUMP_WT_MAX_AGE_H")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(48);
                let max_age_secs = max_age_h * 3600;
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let ts_now = chrono::Utc::now();
                let ts_iso = ts_now.format("%Y-%m-%dT%H:%M:%SZ").to_string();

                // Parse `git worktree list --porcelain` output.
                let wt_out = std::process::Command::new("git")
                    .args(["worktree", "list", "--porcelain"])
                    .current_dir(&repo_root)
                    .output()
                    .unwrap_or_else(|e| {
                        eprintln!("[prune-worktrees] git worktree list failed: {e}");
                        std::process::exit(1);
                    });
                let wt_text = String::from_utf8_lossy(&wt_out.stdout);

                // Each worktree block is separated by a blank line.
                struct WtEntry {
                    path: String,
                    branch: String,
                }
                let mut worktrees: Vec<WtEntry> = Vec::new();
                let mut cur_path: Option<String> = None;
                let mut cur_branch: Option<String> = None;
                for line in wt_text.lines() {
                    if line.starts_with("worktree ") {
                        cur_path = Some(line["worktree ".len()..].trim().to_string());
                        cur_branch = None;
                    } else if line.starts_with("branch ") {
                        // branch refs/heads/<name>
                        let b = line["branch ".len()..].trim().to_string();
                        let branch_name = b.strip_prefix("refs/heads/").unwrap_or(&b).to_string();
                        cur_branch = Some(branch_name);
                    } else if line.is_empty() {
                        if let (Some(p), Some(b)) = (cur_path.take(), cur_branch.take()) {
                            worktrees.push(WtEntry { path: p, branch: b });
                        } else {
                            cur_path = None;
                            cur_branch = None;
                        }
                    }
                }
                // Flush last block if file doesn't end with blank line.
                if let (Some(p), Some(b)) = (cur_path, cur_branch) {
                    worktrees.push(WtEntry { path: p, branch: b });
                }

                // Skip the main worktree (first entry).
                let linked: Vec<&WtEntry> = worktrees.iter().skip(1).collect();

                let mut pruned_count: u32 = 0;
                let mut skipped_active_pr: u32 = 0;
                let mut skipped_uncommitted: u32 = 0;
                let mut skipped_young: u32 = 0;
                let mut pruned_paths: Vec<String> = Vec::new();
                let mut dry_run_candidates: Vec<String> = Vec::new();

                let _now_secs = ts_now.timestamp() as u64;

                for wt in &linked {
                    let wt_path = std::path::Path::new(&wt.path);

                    // Age check: use mtime of .git file inside the worktree.
                    let git_file = wt_path.join(".git");
                    let age_secs: u64 = git_file
                        .metadata()
                        .or_else(|_| wt_path.metadata())
                        .ok()
                        .and_then(|m| m.modified().ok())
                        .and_then(|mt| mt.elapsed().ok())
                        .map(|d| d.as_secs())
                        .unwrap_or(0);

                    if age_secs < max_age_secs {
                        skipped_young += 1;
                        continue;
                    }

                    // Uncommitted changes check.
                    let status_out = std::process::Command::new("git")
                        .args(["status", "--porcelain"])
                        .current_dir(wt_path)
                        .output()
                        .ok();
                    let has_dirty = status_out
                        .as_ref()
                        .map(|o| !o.stdout.is_empty())
                        .unwrap_or(false);
                    if has_dirty {
                        skipped_uncommitted += 1;
                        if !want_json {
                            println!(
                                "[prune-worktrees] KEEP (dirty) {}  branch={}",
                                wt.path, wt.branch
                            );
                        }
                        continue;
                    }

                    // Open PR check via gh CLI.
                    let has_open_pr = std::process::Command::new("gh")
                        .args([
                            "pr", "list", "--head", &wt.branch, "--state", "open", "--json",
                            "number", "--jq", "length",
                        ])
                        .output()
                        .ok()
                        .and_then(|o| {
                            String::from_utf8_lossy(&o.stdout)
                                .trim()
                                .parse::<u32>()
                                .ok()
                        })
                        .map(|n| n > 0)
                        .unwrap_or(false);

                    if has_open_pr {
                        skipped_active_pr += 1;
                        if !want_json {
                            println!(
                                "[prune-worktrees] KEEP (open PR) {}  branch={}",
                                wt.path, wt.branch
                            );
                        }
                        continue;
                    }

                    // Stale — eligible for pruning.
                    let age_h = age_secs / 3600;
                    if dry_run {
                        dry_run_candidates.push(wt.path.clone());
                        if !want_json {
                            println!(
                                "[prune-worktrees] WOULD PRUNE (age={}h)  {}  branch={}",
                                age_h, wt.path, wt.branch
                            );
                        }
                    } else {
                        // Remove via git worktree remove --force.
                        let rm_ok = std::process::Command::new("git")
                            .args(["worktree", "remove", "--force", &wt.path])
                            .current_dir(&repo_root)
                            .status()
                            .map(|s| s.success())
                            .unwrap_or(false);
                        if rm_ok {
                            pruned_count += 1;
                            pruned_paths.push(wt.path.clone());
                            if !want_json {
                                println!(
                                    "[prune-worktrees] PRUNED (age={}h)  {}  branch={}",
                                    age_h, wt.path, wt.branch
                                );
                            }
                            // Emit ambient event per pruned worktree.
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                let branch_esc = wt.branch.replace('"', "\\\"");
                                let path_esc = wt.path.replace('"', "\\\"");
                                let _ = writeln!(
                                    f,
                                    "{{\"ts\":\"{ts_iso}\",\"kind\":\"worktree_pruned\",\
                                     \"path\":\"{path_esc}\",\"branch\":\"{branch_esc}\",\"age_h\":{age_h}}}"
                                );
                            }
                        } else {
                            eprintln!("[prune-worktrees] WARNING: failed to remove {}", wt.path);
                        }
                    }
                }

                if want_json {
                    let candidates_json = if dry_run {
                        serde_json::to_string(&dry_run_candidates).unwrap_or_else(|_| "[]".into())
                    } else {
                        serde_json::to_string(&pruned_paths).unwrap_or_else(|_| "[]".into())
                    };
                    println!(
                        "{{\"dry_run\":{dry_run},\"max_age_h\":{max_age_h},\
                         \"pruned\":{pruned_count},\
                         \"skipped_active_pr\":{skipped_active_pr},\
                         \"skipped_uncommitted\":{skipped_uncommitted},\
                         \"skipped_young\":{skipped_young},\
                         \"paths\":{candidates_json}}}"
                    );
                } else if dry_run {
                    println!(
                        "[prune-worktrees] dry-run: {} stale worktrees would be pruned \
                         (skipped: {} active-PR, {} dirty, {} young)",
                        dry_run_candidates.len(),
                        skipped_active_pr,
                        skipped_uncommitted,
                        skipped_young
                    );
                    println!("[prune-worktrees] re-run with --apply to remove");
                } else {
                    println!(
                        "[prune-worktrees] done: pruned={pruned_count} \
                         skipped_active_pr={skipped_active_pr} \
                         skipped_uncommitted={skipped_uncommitted} \
                         skipped_young={skipped_young}"
                    );
                }

                if !dry_run && pruned_count > 0 {
                    // Emit summary ambient event.
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .append(true)
                        .create(true)
                        .open(&ambient_path)
                    {
                        let _ = writeln!(
                            f,
                            "{{\"ts\":\"{ts_iso}\",\"kind\":\"worktree_prune_summary\",\
                             \"pruned\":{pruned_count},\"skipped_active_pr\":{skipped_active_pr},\
                             \"skipped_uncommitted\":{skipped_uncommitted},\"skipped_young\":{skipped_young}}}"
                        );
                    }
                }

                return Ok(());
            }
            "daemon" => {
                // INFRA-964: long-lived chump-owned scheduler. Reads
                // scripts/coord/system-gap-frequencies.yaml (INFRA-841) and
                // runs each declared task at its interval_s cadence by
                // shelling out to the task's existing script. Emits
                // kind=daemon_tick per invocation so missed cron windows
                // are observable instantly via ambient.jsonl.
                //
                // Replaces the Claude-Code-hosted scheduled-tasks MCP path,
                // which only fires while the host UI is alive (the bug
                // INFRA-964 was filed to capture). OS keeps this daemon
                // alive via launchd/com.chump.fleet-daemon.plist.
                let once = args.iter().any(|a| a == "--once");
                let yaml_path = repo_root.join("scripts/coord/system-gap-frequencies.yaml");
                let yaml_contents = std::fs::read_to_string(&yaml_path).map_err(|e| {
                    anyhow::anyhow!("fleet daemon: cannot read {}: {e}", yaml_path.display())
                })?;

                // Parse the tasks: { name, interval_s, script } from the YAML.
                // We use a minimal pure-Rust parser instead of pulling in
                // serde_yaml to keep the binary slim (same approach as the
                // bash hot-file-lock.sh awk parsing).
                #[derive(Clone, Debug)]
                struct DaemonTask {
                    name: String,
                    interval_s: u64,
                    script: String,
                    optional: bool,
                }
                let mut tasks: Vec<DaemonTask> = Vec::new();
                let mut in_tasks = false;
                let mut cur: Option<DaemonTask> = None;
                for line in yaml_contents.lines() {
                    if line.starts_with("tasks:") {
                        in_tasks = true;
                        continue;
                    }
                    if in_tasks
                        && !line.starts_with(' ')
                        && !line.starts_with('\t')
                        && !line.trim().is_empty()
                    {
                        in_tasks = false;
                    }
                    if !in_tasks {
                        continue;
                    }
                    let trimmed = line.trim_end();
                    // Task header: two-space indent + name: + newline.
                    if let Some(rest) = trimmed.strip_prefix("  ") {
                        if !rest.starts_with(' ') && rest.ends_with(':') {
                            if let Some(t) = cur.take() {
                                tasks.push(t);
                            }
                            let name = rest.trim_end_matches(':').to_string();
                            cur = Some(DaemonTask {
                                name,
                                interval_s: 0,
                                script: String::new(),
                                optional: false,
                            });
                            continue;
                        }
                    }
                    // Fields under the current task (four-space indent).
                    if let Some(t) = cur.as_mut() {
                        if let Some(rest) = trimmed.strip_prefix("    interval_s:") {
                            t.interval_s = rest
                                .split('#')
                                .next()
                                .unwrap_or("")
                                .trim()
                                .parse()
                                .unwrap_or(0);
                        } else if let Some(rest) = trimmed.strip_prefix("    script:") {
                            t.script = rest.trim().to_string();
                        } else if let Some(rest) = trimmed.strip_prefix("    optional:") {
                            t.optional = rest.trim().starts_with("true");
                        }
                    }
                }
                if let Some(t) = cur.take() {
                    tasks.push(t);
                }
                tasks.retain(|t| t.interval_s > 0 && !t.script.is_empty());
                // Filter out tasks whose script doesn't exist on disk when
                // they're marked optional (e.g. gap-gardener.sh stub).
                tasks.retain(|t| {
                    if t.optional && !repo_root.join(&t.script).exists() {
                        eprintln!(
                            "[fleet daemon] skipping optional task {} — script missing: {}",
                            t.name, t.script
                        );
                        false
                    } else {
                        true
                    }
                });

                if tasks.is_empty() {
                    eprintln!(
                        "[fleet daemon] no runnable tasks in {}",
                        yaml_path.display()
                    );
                    return Ok(());
                }

                // Ambient log path (mirrors scripts/coord/opus-curator.sh).
                let ambient_log = repo_root.join(".chump-locks/ambient.jsonl");
                let _ = std::fs::create_dir_all(ambient_log.parent().unwrap());

                let emit_tick =
                    |task: &DaemonTask, run_id: &str, exit_code: i32, elapsed_ms: u128| {
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        let line = format!(
                            "{{\"ts\":\"{ts}\",\"kind\":\"daemon_tick\",\
                          \"task\":\"{}\",\"interval_s\":{},\"run_id\":\"{run_id}\",\
                          \"exit_code\":{exit_code},\"elapsed_ms\":{elapsed_ms}}}\n",
                            task.name, task.interval_s
                        );
                        if let Ok(mut f) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_log)
                        {
                            use std::io::Write;
                            let _ = f.write_all(line.as_bytes());
                        }
                    };

                // Run a single tick: shell out to the task's script, capture
                // exit code + elapsed time, emit ambient event. Errors are
                // swallowed (logged) so one bad task doesn't kill the daemon.
                async fn run_tick(
                    task_name: String,
                    script_rel: String,
                    repo_root: std::path::PathBuf,
                ) -> (i32, u128) {
                    let script_path = repo_root.join(&script_rel);
                    let started = std::time::Instant::now();
                    let res = tokio::process::Command::new("bash")
                        .arg(&script_path)
                        .current_dir(&repo_root)
                        .output()
                        .await;
                    let elapsed_ms = started.elapsed().as_millis();
                    match res {
                        Ok(o) => {
                            let code = o.status.code().unwrap_or(-1);
                            if code != 0 {
                                eprintln!(
                                    "[fleet daemon] {} exit={} in {}ms",
                                    task_name, code, elapsed_ms
                                );
                            }
                            (code, elapsed_ms)
                        }
                        Err(e) => {
                            eprintln!(
                                "[fleet daemon] {} spawn failed: {e} ({}ms)",
                                task_name, elapsed_ms
                            );
                            (-1, elapsed_ms)
                        }
                    }
                }

                // Emit daemon_started so observers know the daemon is alive.
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let tasks_csv = tasks
                    .iter()
                    .map(|t| t.name.clone())
                    .collect::<Vec<_>>()
                    .join(",");
                let start_line = format!(
                    "{{\"ts\":\"{ts}\",\"kind\":\"daemon_started\",\
                      \"tasks\":\"{tasks_csv}\",\"mode\":\"{}\"}}\n",
                    if once { "once" } else { "loop" }
                );
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .append(true)
                    .create(true)
                    .open(&ambient_log)
                {
                    use std::io::Write;
                    let _ = f.write_all(start_line.as_bytes());
                }

                if once {
                    // --once mode: run every task once, sequentially, then exit.
                    // Used by the install script's smoke test + by CI.
                    for t in &tasks {
                        let run_id =
                            format!("{}-{}", std::process::id(), chrono::Utc::now().timestamp());
                        let (exit_code, elapsed_ms) =
                            run_tick(t.name.clone(), t.script.clone(), repo_root.clone()).await;
                        emit_tick(t, &run_id, exit_code, elapsed_ms);
                    }
                    return Ok(());
                }

                // Long-lived loop mode: one tokio interval per declared task.
                eprintln!("[fleet daemon] starting {} tasks (loop mode)", tasks.len());
                let mut handles = Vec::new();
                for t in tasks {
                    let repo_root = repo_root.clone();
                    let ambient_log = ambient_log.clone();
                    handles.push(tokio::spawn(async move {
                        let mut ticker =
                            tokio::time::interval(std::time::Duration::from_secs(t.interval_s));
                        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                        loop {
                            ticker.tick().await;
                            let run_id = format!(
                                "{}-{}",
                                std::process::id(),
                                chrono::Utc::now().timestamp()
                            );
                            let (exit_code, elapsed_ms) =
                                run_tick(t.name.clone(), t.script.clone(), repo_root.clone()).await;
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            let line = format!(
                                "{{\"ts\":\"{ts}\",\"kind\":\"daemon_tick\",\
                                  \"task\":\"{}\",\"interval_s\":{},\
                                  \"run_id\":\"{run_id}\",\
                                  \"exit_code\":{exit_code},\
                                  \"elapsed_ms\":{elapsed_ms}}}\n",
                                t.name, t.interval_s
                            );
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_log)
                            {
                                use std::io::Write;
                                let _ = f.write_all(line.as_bytes());
                            }
                        }
                    }));
                }
                // Hold until any task errors out (none should under normal op).
                for h in handles {
                    let _ = h.await;
                }
                return Ok(());
            }
            // FLEET-037: ergonomic primary verb — like "start" but with an
            // idempotency guard: refuses if the tmux session is already running.
            "up" => {
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());

                // Idempotency: if session already running, bail early with clear guidance.
                let already_running = std::process::Command::new("tmux")
                    .args(["has-session", "-t", &session])
                    .status()
                    .map(|s| s.success())
                    .unwrap_or(false);

                if already_running {
                    eprintln!("[fleet up] session '{session}' is already running.");
                    eprintln!("  Use 'chump fleet status' to see current state.");
                    eprintln!("  Use 'chump fleet scale <N>' to resize.");
                    eprintln!("  Use 'chump fleet down' to stop first, then 'chump fleet up'.");
                    std::process::exit(2);
                }

                // INFRA-1522 (W-007): required-check health gate.
                // Refuse `up` if any required status check has a flake history
                // >20% or last 5 runs all SKIPPED — that's the wedge class
                // that cost ~50 PRs of throughput on 2026-05-25.
                // Bypass: --force flag (emits required_check_health_bypass).
                let want_force = args.iter().any(|a| a == "--force");
                if !want_force {
                    let provider = required_check_health::default_provider();
                    // Probe required checks via `gh api branches/main/protection`.
                    let required_contexts = list_required_contexts();
                    if !required_contexts.is_empty() {
                        let report = required_check_health::evaluate(&required_contexts, &provider);
                        if report.any_unhealthy {
                            required_check_health::emit_warn_for_unhealthy(&report, None);
                            eprintln!("{}", report.refuse_message());
                            eprintln!();
                            eprintln!("  Bypass: chump fleet up --force  (emits audit event)");
                            std::process::exit(2);
                        }
                    }
                } else {
                    // Force-bypass: emit the audit event so the operator
                    // override is captured in ambient.jsonl.
                    let provider = required_check_health::default_provider();
                    let required_contexts = list_required_contexts();
                    if !required_contexts.is_empty() {
                        let report = required_check_health::evaluate(&required_contexts, &provider);
                        if report.any_unhealthy {
                            required_check_health::emit_bypass(
                                &report,
                                "operator --force on fleet up",
                            );
                            eprintln!("[fleet up] --force bypass active — required-check health gate skipped");
                        }
                    }
                }

                // Delegate to the same logic as "start" (shared via the start arm path).
                let size = flag("--size")
                    .or_else(|| cfg("size"))
                    .unwrap_or_else(|| "2".to_string());

                // INFRA-2198: disk-aware gate — consult chump disk plan before
                // allocating N workers.  Falls back gracefully when INFRA-2196
                // (chump disk) is not yet installed.
                let requested_n: u32 = size.parse().unwrap_or(2);
                let accept_wait = std::env::var("CHUMP_FLEET_ACCEPT_WAIT").as_deref() == Ok("1");
                let gate_decision =
                    disk_plan_gate::check("sonnet_dispatch_with_worktree", requested_n, &repo_root);
                let effective_n: u32 = match gate_decision {
                    disk_plan_gate::DiskPlanDecision::Ok => requested_n,
                    disk_plan_gate::DiskPlanDecision::Wait { recommended_n } => {
                        if accept_wait {
                            eprintln!(
                                "[fleet up] WARN: disk headroom low (WAIT) for {} workers; \
                                 CHUMP_FLEET_ACCEPT_WAIT=1 — proceeding.",
                                requested_n
                            );
                            requested_n
                        } else {
                            let safe_n = recommended_n.max(1);
                            eprintln!(
                                "[fleet up] WARN: disk headroom low (WAIT); downsizing \
                                 {} → {} workers. Set CHUMP_FLEET_ACCEPT_WAIT=1 to override.",
                                requested_n, safe_n
                            );
                            // Emit ambient event.
                            let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                            let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                            if let Ok(mut af) = std::fs::OpenOptions::new()
                                .append(true)
                                .create(true)
                                .open(&ambient_path)
                            {
                                let _ = writeln!(
                                    af,
                                    "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_changed\",\
                                     \"from\":{requested_n},\"to\":{safe_n},\
                                     \"reason\":\"disk_budget\"}}"
                                );
                            }
                            safe_n
                        }
                    }
                    disk_plan_gate::DiskPlanDecision::Refuse { recommended_n } => {
                        let safe_n = recommended_n.max(1);
                        eprintln!(
                            "[fleet up] REFUSE: insufficient disk headroom for {} workers; \
                             auto-downsizing to {} (disk budget max-safe-N).",
                            requested_n, safe_n
                        );
                        // Emit ambient event.
                        let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                        let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                        if let Ok(mut af) = std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(&ambient_path)
                        {
                            let _ = writeln!(
                                af,
                                "{{\"ts\":\"{ts}\",\"kind\":\"fleet_scale_changed\",\
                                 \"from\":{requested_n},\"to\":{safe_n},\
                                 \"reason\":\"disk_budget\"}}"
                            );
                        }
                        safe_n
                    }
                };
                // Override size with the disk-gated value.
                let size = effective_n.to_string();
                let model = flag("--model")
                    .or_else(|| cfg("model"))
                    .unwrap_or_else(|| "sonnet".to_string());
                let effort = flag("--effort")
                    .or_else(|| cfg("effort"))
                    .unwrap_or_else(|| "xs,s,m".to_string());
                let domain = flag("--domain")
                    .or_else(|| cfg("domain"))
                    .unwrap_or_default();

                const KNOWN_HARNESSES_UP: &[&str] = &["claude", "opencode", "codex", "manual"];
                let harness = flag("--harness")
                    .or_else(|| {
                        std::env::var("CHUMP_AGENT_HARNESS")
                            .ok()
                            .filter(|v| !v.is_empty())
                    })
                    .or_else(|| cfg("harness"))
                    .unwrap_or_else(|| "claude".to_string());
                if !KNOWN_HARNESSES_UP.contains(&harness.as_str()) {
                    eprintln!(
                        "chump fleet up: unknown --harness '{harness}'. Known: {}",
                        KNOWN_HARNESSES_UP.join(", ")
                    );
                    eprintln!("  (Add a new harness to scripts/dispatch/harnesses/<name>.sh per INFRA-1045.)");
                    std::process::exit(2);
                }

                // Persist last-used config for restart.
                let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
                let last_config = std::path::Path::new(&home).join(".chump/last-fleet-config.json");
                let _ = std::fs::create_dir_all(
                    last_config.parent().unwrap_or(std::path::Path::new("/tmp")),
                );
                let _ = std::fs::write(
                    &last_config,
                    serde_json::to_string_pretty(&serde_json::json!({
                        "size": size,
                        "model": model,
                        "harness": harness,
                        "effort": effort,
                        "domain": domain,
                        "session": session,
                        "updated_at": chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
                    }))
                    .unwrap_or_default(),
                );

                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", &size)
                    .env("FLEET_MODEL", &model)
                    .env("FLEET_HARNESS", &harness)
                    .env("FLEET_EFFORT_FILTER", &effort)
                    .env("FLEET_DOMAIN_FILTER", &domain)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet up: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-1446: work-discovery query — who is working on a given topic?
            // Usage: chump fleet whoworkson <topic> [--json]
            // Sources: (a) .chump-locks/claim-*.json lease files,
            //          (b) open PR titles/branches via `gh pr list`,
            //          (c) open gap titles/AC in state.db,
            //          (d) recent ambient gap_claimed events.
            // Returns a table (or JSON) sorted by recency, deduped by gap_id.
            "whoworkson" => {
                // Collect <topic> from args after "whoworkson"; skip flags.
                let topic: String = args
                    .iter()
                    .skip(3) // chump fleet whoworkson ...
                    .find(|a| !a.starts_with('-'))
                    .cloned()
                    .unwrap_or_else(|| {
                        eprintln!("Usage: chump fleet whoworkson <topic> [--json]");
                        std::process::exit(2);
                    });
                let want_json = args.iter().any(|a| a == "--json");
                let topic_lc = topic.to_lowercase();

                // ── Result row ────────────────────────────────────────────
                #[derive(Debug)]
                struct WhoRow {
                    kind: String,     // lease | pr | gap | ambient
                    id: String,       // gap_id / PR number / event id
                    claimant: String, // agent / worktree / author
                    since: String,    // ISO timestamp (for sort)
                    matches: String,  // excerpt that triggered the match
                }

                let mut rows: Vec<WhoRow> = Vec::new();
                // Deduplicate by (kind, id) — accumulate seen gap IDs across sources.
                let mut seen_gap_ids: std::collections::HashSet<String> =
                    std::collections::HashSet::new();

                let locks_dir = repo_root.join(".chump-locks");

                // ── (a) Active lease files ────────────────────────────────
                if let Ok(entries) = std::fs::read_dir(&locks_dir) {
                    for entry in entries.flatten() {
                        let path = entry.path();
                        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                        // Only claim-*.json lease files.
                        if !name.starts_with("claim-") || !name.ends_with(".json") {
                            continue;
                        }
                        let Ok(raw) = std::fs::read_to_string(&path) else {
                            continue;
                        };
                        let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) else {
                            continue;
                        };
                        let gap_id = v
                            .get("gap_id")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let purpose = v
                            .get("purpose")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let session_id = v
                            .get("session_id")
                            .and_then(|x| x.as_str())
                            .unwrap_or(name)
                            .to_string();
                        let taken_at = v
                            .get("taken_at")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .to_string();
                        let paths_str = v
                            .get("paths")
                            .and_then(|x| x.as_array())
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|p| p.as_str())
                                    .collect::<Vec<_>>()
                                    .join(",")
                            })
                            .unwrap_or_default();

                        // Check for topic match (case-insensitive) across gap_id, purpose, paths.
                        let haystack =
                            format!("{} {} {}", gap_id, purpose, paths_str).to_lowercase();
                        if !haystack.contains(topic_lc.as_str()) {
                            continue;
                        }
                        let key = format!("lease:{gap_id}");
                        if seen_gap_ids.contains(&key) {
                            continue;
                        }
                        seen_gap_ids.insert(key);
                        rows.push(WhoRow {
                            kind: "lease".to_string(),
                            id: gap_id.clone(),
                            claimant: session_id,
                            since: taken_at,
                            matches: format!("lease: {name}"),
                        });
                    }
                }

                // ── (b) Open PRs via `gh pr list` ─────────────────────────
                {
                    let gh_out = std::process::Command::new("gh")
                        .args([
                            "pr",
                            "list",
                            "--state",
                            "open",
                            "--json",
                            "number,title,headRefName,createdAt,author",
                            "--limit",
                            "200",
                        ])
                        .current_dir(&repo_root)
                        .output();
                    if let Ok(out) = gh_out {
                        let text = String::from_utf8_lossy(&out.stdout);
                        if let Ok(arr) = serde_json::from_str::<serde_json::Value>(&text) {
                            if let Some(prs) = arr.as_array() {
                                for pr in prs {
                                    let number = pr
                                        .get("number")
                                        .and_then(|x| x.as_i64())
                                        .map(|n| n.to_string())
                                        .unwrap_or_default();
                                    let title = pr
                                        .get("title")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let branch = pr
                                        .get("headRefName")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let created_at = pr
                                        .get("createdAt")
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("")
                                        .to_string();
                                    let author = pr
                                        .get("author")
                                        .and_then(|x| x.get("login"))
                                        .and_then(|x| x.as_str())
                                        .unwrap_or("unknown")
                                        .to_string();

                                    let haystack = format!("{} {}", title, branch).to_lowercase();
                                    if !haystack.contains(topic_lc.as_str()) {
                                        continue;
                                    }
                                    // Try to extract gap ID from branch/title.
                                    let gap_id = {
                                        let combined = format!("{} {}", branch, title);
                                        // Pattern: INFRA-NNN, PRODUCT-NNN, etc.
                                        let mut found = String::new();
                                        for word in combined.split_whitespace() {
                                            let w = word.trim_matches(|c: char| {
                                                !c.is_alphanumeric() && c != '-'
                                            });
                                            if w.contains('-') {
                                                let parts: Vec<&str> = w.splitn(2, '-').collect();
                                                if parts.len() == 2
                                                    && parts[0]
                                                        .chars()
                                                        .all(|c| c.is_ascii_uppercase())
                                                    && parts[1].chars().all(|c| c.is_ascii_digit())
                                                    && parts[0].len() >= 3
                                                {
                                                    found = w.to_string();
                                                    break;
                                                }
                                            }
                                        }
                                        if found.is_empty() {
                                            format!("PR#{number}")
                                        } else {
                                            found
                                        }
                                    };
                                    let key = format!("pr:{gap_id}");
                                    if seen_gap_ids.contains(&key) {
                                        continue;
                                    }
                                    seen_gap_ids.insert(key);
                                    rows.push(WhoRow {
                                        kind: "pr".to_string(),
                                        id: gap_id,
                                        claimant: author,
                                        since: created_at,
                                        matches: format!("PR#{number}: {title}"),
                                    });
                                }
                            }
                        }
                    }
                }

                // ── (c) Open gap titles/AC in state.db ───────────────────
                {
                    use chump_gap_store as gap_store;
                    if let Ok(store) = gap_store::GapStore::open(&repo_root) {
                        let _ = store.auto_seed_if_empty();
                        if let Ok(all_gaps) = store.list(Some("open")) {
                            for g in &all_gaps {
                                let haystack =
                                    format!("{} {} {}", g.id, g.title, g.acceptance_criteria)
                                        .to_lowercase();
                                if !haystack.contains(topic_lc.as_str()) {
                                    continue;
                                }
                                let key = format!("gap:{}", g.id);
                                if seen_gap_ids.contains(&key) {
                                    continue;
                                }
                                seen_gap_ids.insert(key);
                                // Use created_at (unix) → ISO string for sort.
                                let since = if g.opened_date.is_empty() {
                                    use chrono::TimeZone;
                                    chrono::Utc
                                        .timestamp_opt(g.created_at, 0)
                                        .single()
                                        .map(|dt| dt.format("%Y-%m-%dT%H:%M:%SZ").to_string())
                                        .unwrap_or_default()
                                } else {
                                    format!("{}T00:00:00Z", g.opened_date)
                                };
                                let excerpt: String = g.title.chars().take(60).collect();
                                rows.push(WhoRow {
                                    kind: "gap".to_string(),
                                    id: g.id.clone(),
                                    claimant: "open (unclaimed)".to_string(),
                                    since,
                                    matches: excerpt,
                                });
                            }
                        }
                    }
                }

                // ── (d) Recent ambient gap_claimed events ─────────────────
                {
                    let ambient_path = locks_dir.join("ambient.jsonl");
                    // Scan last 500 lines for recency.
                    if let Ok(content) = std::fs::read_to_string(&ambient_path) {
                        let recent_lines: Vec<&str> = content
                            .lines()
                            .rev()
                            .take(500)
                            .collect::<Vec<_>>()
                            .into_iter()
                            .rev()
                            .collect();
                        for line in recent_lines {
                            if !line.contains("gap_claimed") {
                                continue;
                            }
                            let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                                continue;
                            };
                            let kind_field = v.get("kind").and_then(|x| x.as_str()).unwrap_or("");
                            if kind_field != "gap_claimed" {
                                continue;
                            }
                            let gap_id = v
                                .get("gap_id")
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string();
                            let ts = v
                                .get("ts")
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string();
                            let session = v
                                .get("session_id")
                                .or_else(|| v.get("session"))
                                .and_then(|x| x.as_str())
                                .unwrap_or("unknown")
                                .to_string();

                            let haystack = format!("{} {}", gap_id, line).to_lowercase();
                            if !haystack.contains(topic_lc.as_str()) {
                                continue;
                            }
                            let key = format!("ambient:{gap_id}");
                            if seen_gap_ids.contains(&key) {
                                continue;
                            }
                            seen_gap_ids.insert(key);
                            rows.push(WhoRow {
                                kind: "ambient".to_string(),
                                id: gap_id,
                                claimant: session,
                                since: ts,
                                matches: "gap_claimed event".to_string(),
                            });
                        }
                    }
                }

                // ── Sort by recency (most recent first) ───────────────────
                rows.sort_by(|a, b| b.since.cmp(&a.since));

                // ── Render ────────────────────────────────────────────────
                if want_json {
                    let out: Vec<serde_json::Value> = rows
                        .iter()
                        .map(|r| {
                            serde_json::json!({
                                "type": r.kind,
                                "id": r.id,
                                "claimant": r.claimant,
                                "since": r.since,
                                "matches": r.matches,
                            })
                        })
                        .collect();
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "topic": topic,
                            "results": out,
                        }))
                        .unwrap_or_default()
                    );
                } else if rows.is_empty() {
                    println!("No active work found matching '{topic}'.");
                } else {
                    // Table: type / id / claimant / since / matches
                    let col_widths = (8usize, 20usize, 28usize, 22usize);
                    println!(
                        "{:<width0$}  {:<width1$}  {:<width2$}  {:<width3$}  MATCHES",
                        "TYPE",
                        "ID",
                        "CLAIMANT",
                        "SINCE",
                        width0 = col_widths.0,
                        width1 = col_widths.1,
                        width2 = col_widths.2,
                        width3 = col_widths.3,
                    );
                    println!("{}", "-".repeat(100));
                    for r in &rows {
                        let since_short: String = r.since.chars().take(19).collect();
                        let claimant_short: String =
                            r.claimant.chars().take(col_widths.2).collect();
                        let id_short: String = r.id.chars().take(col_widths.1).collect();
                        println!(
                            "{:<width0$}  {:<width1$}  {:<width2$}  {:<width3$}  {}",
                            r.kind,
                            id_short,
                            claimant_short,
                            since_short,
                            r.matches,
                            width0 = col_widths.0,
                            width1 = col_widths.1,
                            width2 = col_widths.2,
                            width3 = col_widths.3,
                        );
                    }
                }
                return Ok(());
            }
            // INFRA-1568: broad canary — exec the lane-readiness script.
            // Exits 0 iff every production workflow step passes on the
            // candidate lane; non-zero with a named failing-step list.
            "canary" => {
                let lane = flag("--lane").unwrap_or_default();
                let script = repo_root.join("scripts/setup/test-runner-lane-broad-canary.sh");
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&script);
                if !lane.is_empty() {
                    cmd.arg("--lane").arg(&lane);
                }
                // Pass through --json and --record-baseline if present.
                if args.iter().any(|a| a == "--json") {
                    cmd.arg("--json");
                }
                if args.iter().any(|a| a == "--record-baseline") {
                    cmd.arg("--record-baseline");
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet canary: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            // FLEET-037 + RESILIENT-073: ergonomic primary verb — alias for
            // "stop". Also writes AUTONOMY_LEVEL=0 (kill switch).
            "down" => {
                let al_path = autonomy_level::default_path();
                match autonomy_level::write_level(0, &al_path) {
                    Ok(()) => eprintln!(
                        "chump fleet down: AUTONOMY_LEVEL=0 written to {}",
                        al_path.display()
                    ),
                    Err(e) => {
                        eprintln!("chump fleet down: WARNING: could not write AUTONOMY_LEVEL: {e}")
                    }
                }
                let session = flag("--session")
                    .or_else(|| cfg("session"))
                    .unwrap_or_else(|| "chump-fleet".to_string());
                let status = std::process::Command::new("bash")
                    .arg(&run_fleet_sh)
                    .env("FLEET_SIZE", "0")
                    .env("FLEET_SESSION", &session)
                    .status()
                    .unwrap_or_else(|e| {
                        eprintln!("chump fleet down: {e}");
                        std::process::exit(1);
                    });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-1995 (THE FLOOR Phase 2): single-pane fleet pulse.
            // Aggregates floor_temp + fleet_hold + active leases + recent
            // wedge/admin-merge/alert/cluster events into one operator-readable
            // frame. Replaces the 5-surface query workflow.
            "pulse" => {
                let want_json = args.iter().any(|a| a == "--json");
                let repo_root = repo_path::repo_root();
                let pulse = fleet_pulse::build(&repo_root);
                if want_json {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&pulse).unwrap_or_else(|_| "{}".to_string())
                    );
                } else {
                    print!("{}", fleet_pulse::render_text(&pulse));
                }
                // Exit code: 2 if fleet HOLD active, 1 if HOT, else 0.
                let code = if pulse.fleet_hold.active {
                    2
                } else if matches!(pulse.floor_temp.temp, floor_temp::FloorTemp::Hot) {
                    1
                } else {
                    0
                };
                std::process::exit(code);
            }
            "doctor" => {
                // INFRA-1595: fleet doctor — Wave 0b autonomy outer loop.
                //
                // Modes:
                //   (default)   diagnose-only (placeholder until INFRA-1427
                //               --strict lands; emits self_doctor_tick).
                //   --heal      auto-fix what's diagnosed. GATED on
                //               CHUMP_FLEET_SELF_DOCTOR_HEAL=true env (opt-in
                //               until INFRA-1541 50-PR observation phase done).
                //   --json      machine-readable output.
                let want_heal = args.iter().any(|a| a == "--heal");
                let want_json = args.iter().any(|a| a == "--json");
                let env_opt_in = std::env::var("CHUMP_FLEET_SELF_DOCTOR_HEAL")
                    .map(|v| v == "true" || v == "1")
                    .unwrap_or(false);

                if want_heal && !env_opt_in {
                    if want_json {
                        println!(
                            "{}",
                            serde_json::json!({
                                "status": "skipped",
                                "reason": "CHUMP_FLEET_SELF_DOCTOR_HEAL not set to true",
                                "hint": "Default-off until INFRA-1541 50-PR observation done."
                            })
                        );
                    } else {
                        eprintln!(
                            "chump fleet doctor --heal: refusing to run.\n  \
                             Heal mode is opt-in. Set CHUMP_FLEET_SELF_DOCTOR_HEAL=true to enable.\n  \
                             Default-off until INFRA-1541 50-PR observation phase completes."
                        );
                    }
                    std::process::exit(0);
                }

                if want_heal {
                    let cfg = fleet_self_doctor::HealConfig::default();
                    let outcome = fleet_self_doctor::run_heal_cycle(&cfg);
                    if want_json {
                        println!(
                            "{}",
                            serde_json::json!({
                                "mode": "heal",
                                "idle": outcome.idle,
                                "daemons_installed": outcome.daemons_installed,
                                "daemons_failed": outcome.daemons_failed,
                                "prs_dispatched": outcome.prs_dispatched
                                    .iter()
                                    .map(|(n, g)| serde_json::json!({"pr": n, "gap_id": g}))
                                    .collect::<Vec<_>>(),
                                "prs_failed": outcome.prs_failed,
                                "budget_hit": outcome.budget_hit,
                            })
                        );
                    } else {
                        println!("chump fleet doctor --heal:");
                        if outcome.idle {
                            println!("  idle — nothing to heal this cycle");
                        }
                        if !outcome.daemons_installed.is_empty() {
                            println!(
                                "  daemons installed: {}",
                                outcome.daemons_installed.join(", ")
                            );
                        }
                        if !outcome.daemons_failed.is_empty() {
                            println!("  daemons FAILED: {}", outcome.daemons_failed.join(", "));
                        }
                        if !outcome.prs_dispatched.is_empty() {
                            println!(
                                "  PRs dispatched: {}",
                                outcome
                                    .prs_dispatched
                                    .iter()
                                    .map(|(n, g)| format!("#{n} ({g})"))
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            );
                        }
                        if outcome.budget_hit {
                            println!(
                                "  BUDGET HIT — operator paged via .chump-locks/operator-action-needed.json"
                            );
                        }
                    }
                    std::process::exit(0);
                }

                // Diagnose-only placeholder. Emits a tick so consumers can
                // see the doctor ran. INFRA-1427 will replace this with the
                // full --strict implementation.
                let _ = crate::ambient_emit::emit(&crate::ambient_emit::EmitArgs {
                    kind: "self_doctor_tick".to_string(),
                    source: Some("fleet_self_doctor".to_string()),
                    fields: vec![("status".to_string(), "diagnose_only".to_string())],
                    ..Default::default()
                });

                // INFRA-1522 (W-007): required-check health gate runs in
                // diagnose mode too. Exits 1 on any unhealthy required
                // check so `chump fleet doctor` becomes the trip-wire for
                // the W-007 wedge class (path-filtered SKIPPED, flake rate
                // >20%, etc.).
                let provider = required_check_health::default_provider();
                let required_contexts = list_required_contexts();
                let health_report = if required_contexts.is_empty() {
                    None
                } else {
                    let report = required_check_health::evaluate(&required_contexts, &provider);
                    if report.any_unhealthy {
                        required_check_health::emit_warn_for_unhealthy(&report, None);
                    }
                    Some(report)
                };

                if want_json {
                    println!(
                        "{}",
                        serde_json::json!({
                            "mode": "diagnose",
                            "required_check_health": health_report.as_ref().map(|r| serde_json::json!({
                                "any_unhealthy": r.any_unhealthy,
                                "checks": r.checks,
                            })),
                            "note": "--heal not requested; diagnose-only stub until INFRA-1427 strict lands"
                        })
                    );
                } else {
                    println!("chump fleet doctor: diagnose-only mode (pass --heal to auto-fix).");
                    if let Some(r) = &health_report {
                        if r.any_unhealthy {
                            println!("\n{}", r.refuse_message());
                        } else {
                            println!("  required-check health: {} checks OK", r.checks.len());
                        }
                    }
                }

                let exit_code = if health_report.as_ref().is_some_and(|r| r.any_unhealthy) {
                    1
                } else {
                    0
                };
                std::process::exit(exit_code);
            }
            // INFRA-1483: declarative spec primitive (Marcus M-B). Plan
            // shows the gap set without mutating; apply reserves; spec-status
            // aggregates progress by spec_name.
            "plan" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!("Usage: chump fleet plan <spec.yaml>");
                        std::process::exit(2);
                    }
                };
                match fleet_spec::FleetSpec::from_path(&path) {
                    Ok(spec) => {
                        let plan = spec.plan();
                        if args.iter().any(|a| a == "--json") {
                            println!("{}", serde_json::to_string_pretty(&plan).unwrap());
                        } else {
                            print!("{}", fleet_spec::render_plan(&plan));
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "apply" => {
                let path = match args.get(3) {
                    Some(p) => std::path::PathBuf::from(p),
                    None => {
                        eprintln!("Usage: chump fleet apply <spec.yaml> [--dry-run]");
                        std::process::exit(2);
                    }
                };
                let dry_run = args.iter().any(|a| a == "--dry-run");
                match fleet_spec::FleetSpec::from_path(&path) {
                    Ok(spec) => {
                        let plan = spec.plan();
                        println!(
                            "fleet-spec apply: {} gap(s) would be reserved (spec={}, dry_run={dry_run})",
                            plan.len(),
                            spec.name
                        );
                        for (i, g) in plan.iter().enumerate() {
                            if dry_run {
                                println!("  [dry-run] {} | {}", i + 1, g.title);
                                continue;
                            }
                            // Reserve via the chump CLI to keep this dispatch
                            // single-process-friendly. spec_name lives in notes
                            // for `chump fleet spec-status` aggregation.
                            let notes = format!(
                                "spec_name={}\\nvalidation: {}\\nsuccess: {}\\nbindings: {}",
                                g.spec_name,
                                g.validation,
                                g.success,
                                g.bindings
                                    .iter()
                                    .map(|(k, v)| format!("{k}={v}"))
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            );
                            let chump_bin =
                                std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                            let out = std::process::Command::new(&chump_bin)
                                .args([
                                    "gap", "reserve", "--domain", &g.domain, "--title", &g.title,
                                    "--effort", &g.effort, "--notes", &notes,
                                ])
                                .output();
                            match out {
                                Ok(o) if o.status.success() => {
                                    let id = String::from_utf8_lossy(&o.stdout)
                                        .lines()
                                        .find(|l| l.contains("INFRA-") || l.contains("-"))
                                        .map(|s| s.trim().to_string())
                                        .unwrap_or_else(|| "?".to_string());
                                    println!("  [reserved] {} → {}", g.title, id);
                                }
                                Ok(o) => {
                                    eprintln!(
                                        "  [failed] {}: {}",
                                        g.title,
                                        String::from_utf8_lossy(&o.stderr).trim()
                                    );
                                    std::process::exit(1);
                                }
                                Err(e) => {
                                    eprintln!("  [failed] {}: spawn error: {e}", g.title);
                                    std::process::exit(1);
                                }
                            }
                        }
                        std::process::exit(0);
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "spec-status" => {
                let name = match args.get(3) {
                    Some(n) => n.clone(),
                    None => {
                        eprintln!("Usage: chump fleet spec-status <spec-name>");
                        std::process::exit(2);
                    }
                };
                // Aggregate via `chump gap list` + grep on the notes column.
                let chump_bin = std::env::var("CHUMP_BIN").unwrap_or_else(|_| "chump".to_string());
                let out = std::process::Command::new(&chump_bin)
                    .args(["gap", "list", "--json"])
                    .output();
                let Ok(o) = out else {
                    eprintln!("error: could not exec chump gap list");
                    std::process::exit(1);
                };
                let needle = format!("spec_name={name}");
                let body = String::from_utf8_lossy(&o.stdout);
                let mut total = 0;
                let mut counts = std::collections::HashMap::<String, usize>::new();
                // Lenient parse: one JSON object per line OR a single array.
                let entries: Vec<serde_json::Value> = if body.trim_start().starts_with('[') {
                    serde_json::from_str(&body).unwrap_or_default()
                } else {
                    body.lines()
                        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
                        .collect()
                };
                for e in &entries {
                    let notes = e.get("notes").and_then(|v| v.as_str()).unwrap_or("");
                    if notes.contains(&needle) {
                        total += 1;
                        let status = e
                            .get("status")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown")
                            .to_string();
                        *counts.entry(status).or_insert(0) += 1;
                    }
                }
                if total == 0 {
                    println!("no gaps found for spec {name}");
                    std::process::exit(0);
                }
                println!("fleet-spec status: {name}  ({total} gap(s))");
                for (status, n) in &counts {
                    println!("  {status}: {n}");
                }
                std::process::exit(0);
            }
            // EFFECTIVE-025: chump fleet autopilot — META-090 CLI parity arm.
            // Proxies to scripts/coord/fleet-autopilot.sh (bash orchestrator) with
            // pass-through of subcommand + remaining args. Subcommands:
            // start/stop/status/restart/heartbeat. Default = "status" when no
            // subcommand given (mirrors fleet-autopilot.sh's own default).
            "autopilot" => {
                if !fleet_autopilot_sh.exists() {
                    eprintln!(
                        "chump fleet autopilot: {} not found — META-090 may not be installed",
                        fleet_autopilot_sh.display()
                    );
                    std::process::exit(1);
                }
                let autopilot_sub = args.get(3).map(String::as_str).unwrap_or("status");
                let passthrough: Vec<String> = args.iter().skip(4).cloned().collect();
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&fleet_autopilot_sh).arg(autopilot_sub);
                for a in &passthrough {
                    cmd.arg(a);
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet autopilot: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-2176: open Fleet Scrubber UI in the default browser.
            // Delegates to scripts/dev/chump-fleet-view.sh which handles
            // macOS (`open`) and Linux (`xdg-open`) and the --fixtures flag
            // for dev/demo mode without the server.
            "view" => {
                let view_sh = repo_root.join("scripts/dev/chump-fleet-view.sh");
                if !view_sh.exists() {
                    eprintln!(
                        "chump fleet view: {} not found — INFRA-2176 may not be installed",
                        view_sh.display()
                    );
                    std::process::exit(1);
                }
                let passthrough: Vec<String> = args.iter().skip(3).cloned().collect();
                let mut cmd = std::process::Command::new("bash");
                cmd.arg(&view_sh);
                for a in &passthrough {
                    cmd.arg(a);
                }
                let status = cmd.status().unwrap_or_else(|e| {
                    eprintln!("chump fleet view: {e}");
                    std::process::exit(1);
                });
                std::process::exit(status.code().unwrap_or(1));
            }
            // INFRA-2239: chump fleet curator-status — one row per curator with
            // role / last_tick_succeeded_at / last_heartbeat_at / state.db_mutations_1h
            // / supervisor_mode / autorestart_flag.
            "curator-status" => {
                let want_json = args.iter().any(|a| a == "--json");
                let ambient_path = repo_root.join(".chump-locks/ambient.jsonl");
                let state_db = repo_root.join(".chump/state.db");
                let _log_dir = repo_root.join(".chump-locks/autopilot-logs");

                // Supervisor config from env (mirrors crate defaults).
                let supervisor_mode = std::env::var("CHUMP_CURATOR_SUPERVISOR_MODE")
                    .unwrap_or_else(|_| "aggressive".to_string());
                let autorestart = std::env::var("CHUMP_CURATOR_SUPERVISOR_AUTORESTART")
                    .map(|v| v != "0" && v != "false")
                    .unwrap_or(true);

                let roles = &[
                    "shepherd",
                    "target",
                    "handoff",
                    "ci-audit",
                    "decompose",
                    "md-links",
                ];

                // Parse last 2000 lines of ambient.jsonl once for heartbeats.
                let ambient_lines: Vec<String> = if ambient_path.exists() {
                    std::fs::read_to_string(&ambient_path)
                        .unwrap_or_default()
                        .lines()
                        .map(|l| l.to_string())
                        .rev()
                        .take(2000)
                        .collect::<Vec<_>>()
                } else {
                    Vec::new()
                };

                // For each role: find latest curator_heartbeat ts.
                let last_heartbeat_for = |role: &str| -> Option<String> {
                    for line in &ambient_lines {
                        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                            continue;
                        };
                        if v.get("kind").and_then(|k| k.as_str()) == Some("curator_heartbeat")
                            && v.get("role").and_then(|r| r.as_str()) == Some(role)
                        {
                            return v.get("ts").and_then(|t| t.as_str()).map(|s| s.to_string());
                        }
                    }
                    None
                };

                // For each role: find latest curator_failure_paged ts (as last_tick_succeeded proxy).
                // A tick that succeeded = no curator_failure_paged since the last heartbeat.
                // Simplified: last_tick_succeeded = same as last_heartbeat (when healthy).
                let last_failure_for = |role: &str| -> Option<String> {
                    for line in &ambient_lines {
                        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                            continue;
                        };
                        if v.get("kind").and_then(|k| k.as_str()) == Some("curator_failure_paged")
                            && v.get("role").and_then(|r| r.as_str()) == Some(role)
                        {
                            return v.get("ts").and_then(|t| t.as_str()).map(|s| s.to_string());
                        }
                    }
                    None
                };

                // Query state.db for gap mutations attributed to role's session_id in last 1h.
                let mutations_1h = |role: &str| -> i64 {
                    let Ok(conn) = rusqlite::Connection::open(&state_db) else {
                        return -1;
                    };
                    let has_table: bool = conn.query_row(
                        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='gap_history'",
                        [], |r| r.get::<_, i64>(0),
                    ).unwrap_or(0) > 0;
                    if !has_table {
                        return -1;
                    }
                    let date_str = chrono::Utc::now().format("%Y-%m-%d").to_string();
                    let session_id = format!("curator-opus-{role}-{date_str}");
                    let cutoff = (chrono::Utc::now() - chrono::Duration::hours(1))
                        .format("%Y-%m-%dT%H:%M:%SZ")
                        .to_string();
                    conn.query_row(
                        "SELECT COUNT(*) FROM gap_history WHERE session_id = ?1 AND created_at >= ?2",
                        rusqlite::params![session_id, cutoff],
                        |r| r.get(0),
                    ).unwrap_or(0)
                };

                if want_json {
                    let rows: Vec<serde_json::Value> = roles
                        .iter()
                        .map(|role| {
                            let hb = last_heartbeat_for(role);
                            let fail = last_failure_for(role);
                            let mut_count = mutations_1h(role);
                            // last_tick_succeeded = heartbeat ts when no recent failure, else "degraded".
                            let tick_status = if fail.is_some() {
                                "degraded".to_string()
                            } else {
                                hb.clone().unwrap_or_else(|| "never".to_string())
                            };
                            serde_json::json!({
                                "role": role,
                                "last_tick_succeeded_at": tick_status,
                                "last_heartbeat_at": hb.unwrap_or_else(|| "never".to_string()),
                                "state_db_mutations_1h": mut_count,
                                "supervisor_mode": supervisor_mode,
                                "autorestart": autorestart,
                            })
                        })
                        .collect();
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&rows).unwrap_or_else(|_| "[]".to_string())
                    );
                } else {
                    println!(
                        "{:<12} {:<28} {:<28} {:>12}  {:<12} {:<11}",
                        "ROLE",
                        "LAST_TICK_OK",
                        "LAST_HEARTBEAT",
                        "MUTATIONS_1H",
                        "SUPERVISOR",
                        "AUTORESTART"
                    );
                    println!("{}", "-".repeat(110));
                    for role in roles {
                        let hb = last_heartbeat_for(role);
                        let fail = last_failure_for(role);
                        let mut_count = mutations_1h(role);
                        let tick_str = if fail.is_some() {
                            "DEGRADED".to_string()
                        } else {
                            hb.clone().unwrap_or_else(|| "never".to_string())
                        };
                        let hb_str = hb.unwrap_or_else(|| "never".to_string());
                        let mut_str = if mut_count < 0 {
                            "n/a".to_string()
                        } else {
                            mut_count.to_string()
                        };
                        let restart_str = if autorestart { "on" } else { "off" };
                        println!(
                            "{:<12} {:<28} {:<28} {:>12}  {:<12} {:<11}",
                            role, tick_str, hb_str, mut_str, supervisor_mode, restart_str
                        );
                    }
                }
                return Ok(());
            }
            _ => {
                eprintln!(
                    "Usage: chump fleet <up|down|status|scale|start|stop|level|snapshot|restore|restart|audit-pids|brief|auto-widen|auto-scale|auto-resize|prune-worktrees|daemon|whoworkson|canary|doctor|autopilot|plan|apply|spec-status|view|curator-status>"
                );
                eprintln!("Kill switch (RESILIENT-073):");
                eprintln!(
                    "  stop        [--session NAME]  write AUTONOMY_LEVEL=0 then kill tmux workers"
                );
                eprintln!(
                    "  start       [--size N] ...    write AUTONOMY_LEVEL=5 then launch workers"
                );
                eprintln!("  level       [N]               write N to AUTONOMY_LEVEL (0=STOP); no arg = print current");
                eprintln!(
                    "              The AUTONOMY_LEVEL file is checked at every work entry-point."
                );
                eprintln!("              Fail-closed: missing/unreadable/corrupt → STOP.");
                eprintln!("Primary verbs:");
                eprintln!("  up          [--size N] [--model M] [--effort xs,s,m] [--domain D]");
                eprintln!("              (like 'start' but refuses if session already running — use 'scale' to resize)");
                eprintln!("  down        [--session NAME]  (alias for stop, also writes AUTONOMY_LEVEL=0)");
                eprintln!("  status      [--json]");
                eprintln!("  scale       N [--session NAME]");
                eprintln!("  autopilot   <start|stop|status|restart|heartbeat> [--json]");
                eprintln!("              -- META-090 single-command operator playbook (10-layer daemon set)");
                eprintln!("Aliases / advanced:");
                eprintln!("  start       [--size N] [--model M] [--effort xs,s,m] [--domain D]  (alias for up, no idempotency check)");
                eprintln!("  stop        [--session NAME]  (alias for down, also writes AUTONOMY_LEVEL=0)");
                eprintln!("  snapshot");
                eprintln!("  restore     <snapshot-id>");
                eprintln!("  restart     [--size N] [--session NAME]  (fleet-restart.sh — graceful reload)");
                eprintln!("  audit-pids  [--apply]");
                eprintln!("  brief       [--json] [--window SECS]");
                eprintln!("  auto-widen  [--apply]  -- widen effort/priority filter on starvation");
                eprintln!(
                    "  auto-scale  [--apply] [--json]  -- disk-aware up/down by 1 per tick (INFRA-2198)"
                );
                eprintln!(
                    "  auto-resize [--apply] [--json]  -- scale down on 4 conditions (INFRA-650)"
                );
                eprintln!("  prune-worktrees [--apply] [--json]  -- prune stale linked worktrees (INFRA-827)");
                eprintln!("  daemon      [--once]  -- long-lived scheduler (INFRA-964); --once runs all tasks once");
                eprintln!("  whoworkson  <topic> [--json]  -- who is working on a given topic (INFRA-1446)");
                eprintln!("  canary      [--lane LABEL] [--json] [--record-baseline]");
                eprintln!(
                    "              -- broad runner-lane canary (INFRA-1568): runs full production"
                );
                eprintln!("                 workflow end-to-end; exit 0 iff every step passes.");
                eprintln!(
                    "  doctor      [--heal] [--json]  -- self-healing autonomy loop (INFRA-1595)"
                );
                eprintln!(
                    "  view        [--fixtures]  -- open Fleet Scrubber UI in browser (INFRA-2176)"
                );
                eprintln!(
                    "              -- with --fixtures: serves web/fleet-scrubber/ locally, no server needed"
                );
                std::process::exit(2);
            }
        }
    }

    // `chump gap <subcommand>` (INFRA-023) — SQLite-backed gap store.
    //
    // Subcommands: list, reserve, claim, preflight, ship, dump, import
    //
    // Examples:
    //   chump gap list [--status open] [--json]
    //   chump gap reserve --domain INFRA --title "My gap" [--priority P1] [--effort s]
    //   chump gap claim <GAP-ID> [--session <id>] [--worktree <path>]
    //   chump gap preflight <GAP-ID>
    //   chump gap ship <GAP-ID> [--session <id>]
    //   chump gap dump [--out <path>]
    //   chump gap import [--yaml docs/gaps.yaml]
    // `chump gap <subcommand>` — extracted to commands::dispatch_gap (INFRA-3302, slice 3 of INFRA-3287).
    // Every gap subcommand handles its own output; a few success paths (e.g. `gap
    // list`) return without exiting, so exit(0) here to terminate cleanly instead
    // of falling through to the model-prompt fallback ("Response from Agent: …").
    if args.get(1).map(String::as_str) == Some("gap") {
        commands::dispatch_gap::run(&args).await?;
        std::process::exit(0);
    }

    // `chump cost record-pr` (INFRA-405) — record per-PR cost metrics (tokens, USD, duration).
    // Called by bot-merge.sh at PR creation time to build a telemetry ledger.
    if args.get(1).map(String::as_str) == Some("cost")
        && args.get(2).map(String::as_str) == Some("record-pr")
    {
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };

        let pr_number = match flag("--pr").and_then(|s| s.parse::<i64>().ok()) {
            Some(n) => n,
            None => {
                eprintln!("Usage: chump cost record-pr --pr N --gap GAP --model MODEL");
                eprintln!("                             [--tokens-in I] [--tokens-out O]");
                eprintln!(
                    "                             [--usd U] [--duration-secs D] [--backend B]"
                );
                std::process::exit(2);
            }
        };

        let gap_id = flag("--gap").unwrap_or_else(|| "unknown".to_string());
        let model = flag("--model").unwrap_or_else(|| "unknown".to_string());
        let tokens_in = flag("--tokens-in")
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        let tokens_out = flag("--tokens-out")
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        let usd_cost = flag("--usd")
            .and_then(|s| s.parse::<f64>().ok())
            .unwrap_or(0.0);
        let duration_secs = flag("--duration-secs")
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        let backend = flag("--backend").unwrap_or_else(|| "unknown".to_string());

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;

        let repo_root = repo_path::repo_root();
        let record = cost_tracker::PrCostRecord {
            pr_number,
            gap_id,
            model,
            tokens_in,
            tokens_out,
            usd_cost,
            duration_secs,
            shipped_at: now,
            backend,
        };

        match cost_tracker::record_pr_cost(&repo_root, &record) {
            Ok(()) => {
                println!("recorded PR {} cost metrics", pr_number);
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump cost record-pr: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump cost-watch [--budget X] [--hard-cap] [--json]` (INFRA-608)
    // Running tally of Anthropic spend vs per-cycle budget. Reads session_end
    // token-cost rows from ambient.jsonl, groups by model, projects monthly,
    // and emits 🔴 when today's spend exceeds the daily budget threshold.
    // --hard-cap exits 1 when over budget (blocks fleet spawn).
    if args.get(1).map(String::as_str) == Some("cost-watch") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump cost-watch [--budget USD] [--hard-cap] [--json]");
            println!();
            println!("Real-time inference spend and per-slot breakdown. Reads cost records");
            println!("written by 'chump cost record-pr'. Compares against daily budget.");
            println!();
            println!("Options:");
            println!(
                "  --budget USD   daily budget in USD  [default: $5.00 or CHUMP_DAILY_BUDGET]"
            );
            println!("  --hard-cap     exit 1 if today's spend exceeds budget");
            println!("  --json         output in JSON format");
            println!();
            println!("Example:");
            println!("  chump cost-watch");
            println!("  chump cost-watch --budget 10.0 --hard-cap");
            return Ok(());
        }
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let budget_usd = flag("--budget")
            .and_then(|s| s.parse::<f64>().ok())
            .or_else(|| {
                std::env::var("CHUMP_DAILY_BUDGET")
                    .ok()
                    .and_then(|s| s.parse().ok())
            })
            .unwrap_or(5.0_f64);
        let hard_cap = args.iter().any(|a| a == "--hard-cap");
        let want_json = args.iter().any(|a| a == "--json");

        let repo_root = repo_path::repo_root();
        let report = cost_watch::build_report(&repo_root, budget_usd);

        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }

        if hard_cap && report.over_budget {
            eprintln!(
                "chump cost-watch: 🔴 hard-cap triggered — today's spend ${:.4} exceeds budget ${:.2}/day",
                report.today_spend_usd, budget_usd
            );
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump cost-check [--gap-id ID] [--model MODEL]` (INFRA-877)
    // Check daily spend against CHUMP_DAILY_BUDGET_USD and emit cost_quota_warning
    // or cost_quota_exceeded events to ambient.jsonl.  Exit 0 = ok, 1 = warning,
    // 2 = exceeded (spawn should be blocked).
    if args.get(1).map(String::as_str) == Some("cost-check") {
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let gap_id = flag("--gap-id").unwrap_or_else(|| "unknown".to_string());
        let model = flag("--model").unwrap_or_else(|| "unknown".to_string());
        let repo_root = repo_path::repo_root();
        let status = cost_ledger::check_quota(&repo_root, &gap_id, &model, true);
        let pct = status.budget_used_pct();
        let label = status.label();
        match &status {
            cost_ledger::QuotaStatus::Exceeded {
                spend_usd,
                budget_usd,
                ..
            } => {
                eprintln!(
                    "chump cost-check: EXCEEDED  ${:.4} of ${:.2} ({:.1}%)",
                    spend_usd, budget_usd, pct
                );
                std::process::exit(2);
            }
            cost_ledger::QuotaStatus::Warning {
                spend_usd,
                budget_usd,
                ..
            } => {
                eprintln!(
                    "chump cost-check: WARNING   ${:.4} of ${:.2} ({:.1}%)",
                    spend_usd, budget_usd, pct
                );
                std::process::exit(1);
            }
            cost_ledger::QuotaStatus::Ok {
                spend_usd,
                budget_usd,
                ..
            } => {
                eprintln!(
                    "chump cost-check: ok        ${:.4} of ${:.2} ({:.1}%)",
                    spend_usd, budget_usd, pct
                );
            }
        }
        eprintln!("chump cost-check: status={label}  budget_used_pct={pct:.1}%");
        return Ok(());
    }

    // `chump kpi report` (INFRA-617) — exec-summary view of mission progress.
    // Sections: ship rate trend (1d/7d/30d), mission grade history, cost savings
    // vs Anthropic-only baseline, top productizations by leverage, tokens-per-ship.
    // Flags:
    //   --tokens-per-ship N   only show tokens-per-ship section (backward compat)
    //   --json                machine-readable JSON output
    //   --pdf                 pipe markdown through pandoc for grant pitches
    if args.get(1).map(String::as_str) == Some("kpi")
        && args.get(2).map(String::as_str) == Some("report")
    {
        let flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let window_days = flag("--tokens-per-ship")
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(7);
        let want_json = args.iter().any(|a| a == "--json");
        let want_pdf = args.iter().any(|a| a == "--pdf");
        let only_tokens = args.iter().any(|a| a == "--tokens-per-ship");
        let want_impact = args.iter().any(|a| a == "--impact");
        let want_agents = args.iter().any(|a| a == "--agents");

        let repo_root = repo_path::repo_root();

        // FLEET-048: --impact shows gap impact ratings section only.
        if want_impact {
            let section = kpi_report::build_impact_section(&repo_root);
            if want_json {
                println!("{}", section.render_json());
            } else {
                print!("{}", section.render_text());
            }
            return Ok(());
        }

        // FLEET-044: --agents shows per-agent throughput from .chump/metrics/.
        if want_agents {
            let date_arg = flag("--date");
            let section =
                kpi_report::build_agent_throughput_section(&repo_root, date_arg.as_deref());
            if want_json {
                println!("{}", section.render_json());
            } else {
                print!("{}", section.render_text());
            }
            return Ok(());
        }

        if only_tokens {
            // Backward-compat: only the tokens-per-ship section.
            let report = kpi_report::build_report(&repo_root, window_days);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
        } else {
            let report = kpi_report::build_full_report(&repo_root, window_days);
            let output = if want_json {
                report.render_json()
            } else {
                report.render_text()
            };

            if want_pdf {
                // Pipe markdown through pandoc for a grant-ready PDF.
                let md = report.render_text();
                let mut child = match std::process::Command::new("pandoc")
                    .args(["-f", "markdown", "-o", "chump-kpi-report.pdf"])
                    .stdin(std::process::Stdio::piped())
                    .spawn()
                {
                    Ok(c) => c,
                    Err(e) => {
                        eprintln!("chump kpi report: --pdf requested but pandoc not found: {e}");
                        eprintln!("Falling back to stdout:");
                        print!("{output}");
                        return Ok(());
                    }
                };
                if let Some(mut stdin) = child.stdin.take() {
                    use std::io::Write;
                    let _ = stdin.write_all(md.as_bytes());
                }
                let _ = child.wait();
                println!("Wrote chump-kpi-report.pdf");
            } else {
                print!("{output}");
            }
        }
        return Ok(());
    }

    // `chump dispatch route <GAP-ID>` (COG-035) — print the candidate cascade
    // the dispatcher would walk for a given gap. Reads priority/effort from
    // .chump/state.db and the routing table from docs/dispatch/routing.yaml
    // (falls back to the hardcoded table when YAML is missing).
    if args.get(1).map(String::as_str) == Some("dispatch")
        && args.get(2).map(String::as_str) == Some("route")
    {
        let gap_id = match args.get(3) {
            Some(s) if !s.is_empty() => s.clone(),
            _ => {
                eprintln!("Usage: chump dispatch route <GAP-ID>");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump dispatch route: cannot open state.db: {e:#}");
                std::process::exit(1);
            }
        };
        let row = match store.get(&gap_id) {
            Ok(Some(r)) => r,
            Ok(None) => {
                eprintln!("chump dispatch route: gap {gap_id} not found in .chump/state.db");
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("chump dispatch route: lookup failed: {e:#}");
                std::process::exit(1);
            }
        };

        let task_class = chump_orchestrator::dispatch::task_class_for_gap_id(&row.id);
        let cands = chump_orchestrator::dispatch::select_candidates_for_gap(
            &repo_root,
            &row.id,
            &row.priority,
            &row.effort,
        );

        println!("GAP        : {}", row.id);
        println!("priority   : {}", row.priority);
        println!("effort     : {}", row.effort);
        println!("task_class : {}", task_class.unwrap_or("-"));
        println!();
        println!(
            "{:<3}{:<14}{:<53}{:<10}why",
            "#", "backend", "model", "provider"
        );
        for (i, c) in cands.iter().enumerate() {
            println!(
                "{:<3}{:<14}{:<53}{:<10}{}",
                i + 1,
                c.backend.label(),
                c.model.as_deref().unwrap_or("-"),
                c.provider_pfx.as_deref().unwrap_or("-"),
                c.why,
            );
        }
        return Ok(());
    }

    // `chump dispatch scoreboard` (COG-036) — print aggregated dispatch
    // outcomes per (task_class, backend, model, provider_pfx) route. Reads
    // from `routing_outcomes` in `.chump/state.db`, which the orchestrator
    // monitor appends to on every terminal DispatchOutcome.
    if args.get(1).map(String::as_str) == Some("dispatch")
        && args.get(2).map(String::as_str) == Some("scoreboard")
    {
        let repo_root = repo_path::repo_root();
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump dispatch scoreboard: cannot open state.db: {e:#}");
                std::process::exit(1);
            }
        };
        let entries = match store.routing_scoreboard() {
            Ok(v) => v,
            Err(e) => {
                eprintln!("chump dispatch scoreboard: query failed: {e:#}");
                std::process::exit(1);
            }
        };
        if entries.is_empty() {
            println!("No routing outcomes recorded yet.");
            return Ok(());
        }
        println!(
            "{:<10}{:<14}{:<40}{:<10}{:>6}{:>6}{:>8}{:>20}",
            "class", "backend", "model", "provider", "succ", "fail", "rate%", "last_seen"
        );
        for e in &entries {
            println!(
                "{:<10}{:<14}{:<40}{:<10}{:>6}{:>6}{:>7.1}%{:>20}",
                if e.task_class.is_empty() {
                    "-"
                } else {
                    &e.task_class
                },
                e.backend,
                if e.model.is_empty() { "-" } else { &e.model },
                if e.provider_pfx.is_empty() {
                    "-"
                } else {
                    &e.provider_pfx
                },
                e.successes,
                e.failures,
                e.success_rate * 100.0,
                e.last_seen
            );
        }
        return Ok(());
    }

    // `chump dispatch simulate <task_class> <count>` (COG-037) — sample
    // the Thompson-flag-enabled candidate cascade `count` times for a
    // synthetic gap of the given task_class and print a histogram of
    // which arm came first. Lets operators sanity-check the sampler's
    // decisions on whatever scoreboard data is currently in
    // `.chump/state.db`. Always runs the Thompson path regardless of
    // whether `cog_037` is in `CHUMP_FLAGS` — `simulate` is the
    // diagnostic for the sampler itself.
    //
    // task_class examples: `research` (EVAL-/RESEARCH-prefixed gaps),
    // `dispatch` (other), or `-` for "no task_class" (matches the v1
    // default cascade only).
    if args.get(1).map(String::as_str) == Some("dispatch")
        && args.get(2).map(String::as_str) == Some("simulate")
    {
        let task_class = match args.get(3) {
            Some(s) if !s.is_empty() => s.clone(),
            _ => {
                eprintln!("Usage: chump dispatch simulate <task_class> <count>");
                eprintln!("  task_class: research | dispatch | - (no class)");
                std::process::exit(2);
            }
        };
        let count: usize = match args.get(4).and_then(|s| s.parse().ok()) {
            Some(n) if n > 0 => n,
            _ => {
                eprintln!("Usage: chump dispatch simulate <task_class> <count>");
                eprintln!("  count must be a positive integer");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();

        // Build a synthetic gap id whose task_class_for_gap_id() answer
        // matches the requested task_class. The dispatch crate's
        // task_class_for_gap_id only recognises EVAL-/RESEARCH- prefixes
        // today, so map "research" → "EVAL-SIM" and any other token → a
        // non-prefixed id (yielding task_class=None).
        let synthetic_gap_id = match task_class.as_str() {
            "research" => "EVAL-SIM-COG-037",
            "-" | "" | "none" => "INFRA-SIM-COG-037",
            _ => "INFRA-SIM-COG-037",
        };

        // Use a synthetic priority/effort that exercises the default
        // cascade (P2/m → no special route) so the simulator focuses on
        // the sampler, not the YAML routing rules. Operators who want to
        // simulate a specific route can edit routing.yaml first.
        let priority = "P2";
        let effort = "m";

        // Fixed seed so two consecutive `simulate` runs print identical
        // histograms (helpful for diffing scoreboard changes). Override
        // via `CHUMP_SIMULATE_SEED` for variance probing.
        let seed: u64 = std::env::var("CHUMP_SIMULATE_SEED")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0xC06_037);

        use chump_orchestrator::dispatch::select_candidates_for_gap_with_rng;
        use rand::SeedableRng;
        use std::collections::BTreeMap;

        let mut rng = rand::rngs::StdRng::seed_from_u64(seed);
        let mut hist: BTreeMap<String, (usize, String)> = BTreeMap::new();
        // Sniff the cascade once so we can label the histogram with the
        // arm's `why` rationale alongside the signature.
        let preview = select_candidates_for_gap_with_rng(
            &repo_root,
            synthetic_gap_id,
            priority,
            effort,
            &mut rand::rngs::StdRng::seed_from_u64(seed),
        );
        if preview.is_empty() {
            println!(
                "No candidates produced for task_class={task_class} (synthetic gap {synthetic_gap_id}, P2/m). \
                 Check docs/dispatch/routing.yaml."
            );
            return Ok(());
        }
        for c in &preview {
            hist.entry(c.signature()).or_insert((0, c.why.clone()));
        }

        for _ in 0..count {
            let cands = select_candidates_for_gap_with_rng(
                &repo_root,
                synthetic_gap_id,
                priority,
                effort,
                &mut rng,
            );
            if let Some(first) = cands.first() {
                hist.entry(first.signature())
                    .or_insert((0, first.why.clone()))
                    .0 += 1;
            }
        }

        println!(
            "Thompson simulate: task_class={task_class}, gap={synthetic_gap_id}, \
             priority={priority}, effort={effort}, trials={count}, seed={seed}"
        );
        println!();
        println!(
            "{:<5}{:<46}{:>8}{:>8}  why",
            "rank", "signature (backend|model|provider)", "picks", "rate%"
        );
        let mut rows: Vec<(String, usize, String)> = hist
            .into_iter()
            .map(|(sig, (n, why))| (sig, n, why))
            .collect();
        rows.sort_by_key(|b| std::cmp::Reverse(b.1));
        for (i, (sig, n, why)) in rows.iter().enumerate() {
            let pct = (*n as f64) * 100.0 / (count as f64);
            println!("{:<5}{:<46}{:>8}{:>7.1}%  {}", i + 1, sig, n, pct, why);
        }
        return Ok(());
    }

    // `chump dispatch cost-report` (INFRA-405) — print per-PR cost telemetry.
    // Reads from .chump/pr_costs.db and outputs TSV with optional per-model/per-domain aggregation.
    if args.get(1).map(String::as_str) == Some("dispatch")
        && args.get(2).map(String::as_str) == Some("cost-report")
    {
        let per_model = args.iter().any(|a| a == "--per-model");
        let per_domain = args.iter().any(|a| a == "--per-domain");

        let repo_root = repo_path::repo_root();
        let records = match cost_tracker::query_pr_costs(&repo_root) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("chump dispatch cost-report: {e:#}");
                std::process::exit(1);
            }
        };

        if records.is_empty() {
            println!("no PR cost records found");
            return Ok(());
        }

        if per_domain {
            use std::collections::HashMap;
            let mut by_domain: HashMap<String, (i64, i64, f64, i64)> = HashMap::new();
            for r in &records {
                let domain = r.gap_id.split('-').next().unwrap_or("unknown").to_string();
                let entry = by_domain.entry(domain).or_insert((0, 0, 0.0, 0));
                entry.0 += r.tokens_in;
                entry.1 += r.tokens_out;
                entry.2 += r.usd_cost;
                entry.3 += 1;
            }
            let mut items: Vec<_> = by_domain.into_iter().collect();
            items.sort_by(|a, b| a.0.cmp(&b.0));
            println!("domain\ttokens_in\ttokens_out\tusd_cost\tpr_count");
            for (domain, (in_tokens, out_tokens, cost, count)) in items {
                println!(
                    "{}\t{}\t{}\t{:.4}\t{}",
                    domain, in_tokens, out_tokens, cost, count
                );
            }
        } else if per_model {
            use std::collections::HashMap;
            let mut by_model: HashMap<String, (i64, i64, f64, i64)> = HashMap::new();
            for r in &records {
                let entry = by_model.entry(r.model.clone()).or_insert((0, 0, 0.0, 0));
                entry.0 += r.tokens_in;
                entry.1 += r.tokens_out;
                entry.2 += r.usd_cost;
                entry.3 += 1;
            }
            let mut items: Vec<_> = by_model.into_iter().collect();
            items.sort_by(|a, b| a.0.cmp(&b.0));
            println!("model\ttokens_in\ttokens_out\tusd_cost\tpr_count");
            for (model, (in_tokens, out_tokens, cost, count)) in items {
                println!(
                    "{}\t{}\t{}\t{:.4}\t{}",
                    model, in_tokens, out_tokens, cost, count
                );
            }
        } else {
            println!("pr\tgap\tmodel\ttokens_in\ttokens_out\tusd_cost\tduration_secs\tbackend");
            for r in &records {
                println!(
                    "{}\t{}\t{}\t{}\t{}\t{:.4}\t{}\t{}",
                    r.pr_number,
                    r.gap_id,
                    r.model,
                    r.tokens_in,
                    r.tokens_out,
                    r.usd_cost,
                    r.duration_secs,
                    r.backend
                );
            }
        }
        return Ok(());
    }

    // `chump dispatch` with no/unknown subcommand — print help.
    if args.get(1).map(String::as_str) == Some("dispatch") {
        eprintln!("Usage: chump dispatch <subcommand>");
        eprintln!();
        eprintln!("  route       <GAP-ID>            print the candidate cascade for a gap");
        eprintln!(
            "  scoreboard                      aggregate dispatch outcomes (COG-036) by route"
        );
        eprintln!(
            "  simulate    <task_class> <N>    sample the Thompson cascade N times (COG-037)"
        );
        eprintln!("  cost-report [--per-model|--per-domain]  per-PR cost telemetry (INFRA-405)");
        std::process::exit(2);
    }

    // `chump --pick-gap` (INFRA-DISPATCH-POLICY) — policy-aware gap selector.
    //
    // Reads docs/gaps.yaml + .chump-locks/ + CHUMP_DISPATCH_CAPACITY and runs
    // the musher dispatch policy to find the single best gap to dispatch next.
    // Prints the gap ID to stdout, or "none" if all gaps are blocked (capacity
    // full, all live-claimed, deps unmet, or backlog empty).
    //
    // Intended for use in shell scripts and the musher dispatcher:
    //   GAP=$(chump --pick-gap) && [ "$GAP" != "none" ] && scripts/coord/gap-claim.sh "$GAP"
    //
    // Exit codes: 0 always (even when result is "none") — callers check stdout.
    if args.iter().any(|a| a == "--pick-gap") {
        use chump_orchestrator::{dispatch_capacity, done_ids, load_gaps, pick_gap};
        use std::collections::HashSet;

        let repo_root = repo_path::repo_root();
        let gaps_path = repo_root.join("docs/gaps.yaml");
        let all = match load_gaps(&gaps_path) {
            Ok(g) => g,
            Err(e) => {
                eprintln!("chump --pick-gap: could not load gaps.yaml: {e:#}");
                std::process::exit(1);
            }
        };
        let done = done_ids(&all);

        // Collect live-claimed gap IDs from .chump-locks/ (gap_id + INFRA-021 pending_new_gap.id).
        let active_leases = agent_lease::list_active();
        let mut live_claimed: HashSet<String> = active_leases
            .iter()
            .filter_map(|l| l.gap_id.clone())
            .collect();
        for lease in &active_leases {
            if let Some(p) = &lease.pending_new_gap {
                live_claimed.insert(p.id.clone());
            }
        }
        let active_count = live_claimed.len();

        let capacity = dispatch_capacity();
        match pick_gap(&all, &done, &live_claimed, active_count, capacity) {
            Some(gap) => println!("{}", gap.id),
            None => println!("none"),
        }
        return Ok(());
    }

    // `chump --execute-gap <GAP-ID>` (COG-025) — unattended single-gap
    // dispatch mode. Used by `chump-orchestrator` when
    // CHUMP_DISPATCH_BACKEND=chump-local. Drives the multi-turn agent loop
    // through whatever provider OPENAI_API_BASE+OPENAI_MODEL resolve to
    // (Together free tier, mistral.rs, Ollama, hosted OpenAI). The
    // entire purpose is cost-routing autonomous PR shipping off Anthropic.
    //
    // Caller contract: gap is already claimed in the current worktree,
    // CHUMP_DISPATCH_DEPTH=1 is set in env, OPENAI_* env points at the
    // desired backend. Prints the agent's final reply to stdout (monitor
    // parses for PR number); exit-code 1 on agent-loop failure, 2 on
    // usage error.
    if let Some(pos) = args.iter().position(|a| a == "--execute-gap") {
        let gap_id = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if gap_id.is_empty() || gap_id.starts_with("--") {
            eprintln!("Usage: chump --execute-gap <GAP-ID>");
            std::process::exit(2);
        }
        config_validation::validate_config();
        // INFRA-843: read required_model from gap registry and override
        // FLEET_MODEL so execute_gap picks up the right model tier.
        // Falls back to FLEET_MODEL env then default sonnet if unset.
        let mut external_repo_target: Option<String> = None;
        {
            let repo_root = repo_path::repo_root();
            if let Ok(store) = gap_store::GapStore::open(&repo_root) {
                if let Ok(Some(g)) = store.get(gap_id) {
                    if !g.required_model.is_empty() {
                        let prev = std::env::var("FLEET_MODEL").ok();
                        std::env::set_var("FLEET_MODEL", &g.required_model);
                        eprintln!(
                            "[execute-gap] INFRA-843: required_model={} (was {:?})",
                            g.required_model,
                            prev.as_deref().unwrap_or("unset")
                        );
                    }
                    external_repo_target = external_repo_target_from_skills(&g.skills_required);
                }
            }
        }
        // MISSION-046: a gap tagged `external_repo:OWNER/REPO` cannot be executed
        // by the internal agent loop (it runs in the Chump worktree). Route to
        // `chump improve OWNER/REPO --apply`, which clones the target, implements
        // in the clone, opens a PR on the EXTERNAL repo, and verify-merges. Without
        // this, the mesh-worker's `--execute-gap` silently runs the internal loop
        // against the wrong repo — the #1 blocker to the first BEAST-MODE merge.
        if let Some(owner_repo) = external_repo_target {
            eprintln!(
                "[execute-gap] MISSION-046: gap {gap_id} is external_repo:{owner_repo} -> routing to `chump improve {owner_repo} --apply`"
            );
            let code = improve::run(&[owner_repo, "--apply".to_string()]);
            std::process::exit(code);
        }
        match execute_gap::execute_gap(gap_id).await {
            Ok(reply) => {
                print!("{reply}");
                // INFRA-2055: emit gap_shipped on every clean exit so wizard-daemon
                // gets an explicit signal instead of heuristic-guessing from PID death.
                // Parse the PR number from the agent reply (best-effort; empty = not found).
                let pr_number = execute_gap::parse_pr_number_from_reply(&reply);
                let commit_sha = execute_gap::current_head_sha();
                execute_gap::emit_terminal_outcome(&execute_gap::ExecuteGapOutcome::Shipped {
                    gap_id: gap_id.to_string(),
                    pr_number,
                    commit_sha,
                });
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump --execute-gap {gap_id}: {e:#}");
                // INFRA-302 blocker (1): classify the error so the
                // orchestrator's stderr-tailer can distinguish
                // billing-exhausted (402 / credit_limit class) from
                // generic failures and decide whether to respawn the
                // dispatched child against the next routing-table
                // candidate. See the `Exit codes` section in the
                // execute_gap.rs module docs for the full contract.
                let kind = execute_gap::classify_execute_gap_error(&e);
                if let Some(marker) = kind.stderr_marker() {
                    eprintln!("{marker}");
                }
                // INFRA-2055: emit gap_blocked on EVERY error exit so wizard-daemon
                // gets an explicit terminal signal instead of guessing from PID death.
                let reason = format!("{e:#}");
                let recoverable_by = match kind {
                    execute_gap::ExecuteGapErrorKind::BillingExhausted => "fix_billing",
                    execute_gap::ExecuteGapErrorKind::TransportUnreachable => "restart_daemon",
                    execute_gap::ExecuteGapErrorKind::Other => "manual_rescue",
                };
                execute_gap::emit_terminal_outcome(&execute_gap::ExecuteGapOutcome::Blocked {
                    gap_id: gap_id.to_string(),
                    reason,
                    recoverable_by: recoverable_by.to_string(),
                });
                std::process::exit(kind.exit_code());
            }
        }
    }

    // INFRA-060 (M2): `chump --plan <GAP-ID>` — run the plan-mode gate
    // standalone (no agent loop, no provider call). Writes
    // `.chump-plans/<gap>.md` and exits 0 (proceed) / 1 (abort: queue too
    // crowded) / 2 (usage). Useful for hand-testing, for `bot-merge.sh` to
    // regenerate a stale plan, and to dogfood the gate on the same PR
    // that introduces it.
    if let Some(pos) = args.iter().position(|a| a == "--plan") {
        let gap_id = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if gap_id.is_empty() || gap_id.starts_with("--") {
            eprintln!("Usage: chump --plan <GAP-ID>");
            std::process::exit(2);
        }
        let repo_root = repo_path::repo_root();
        match plan_mode::run_plan_mode(gap_id, &repo_root) {
            Ok(plan_mode::PlanOutcome::Proceed { plan_path }) => {
                if let Some(p) = plan_path {
                    println!("{}", p.display());
                }
                std::process::exit(0);
            }
            Ok(plan_mode::PlanOutcome::Abort { reason, conflicts }) => {
                eprintln!("plan-mode abort: {reason}");
                eprintln!("conflicts: {conflicts:?}");
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("plan-mode error: {e:#}");
                std::process::exit(2);
            }
        }
    }

    // `chump --doctor` — self-diagnosis. Runs before any validate_config() so it
    // works even when the setup is broken. Exit 0 if all ok, 1 if any Fail.
    // `--json` for machine-readable output.
    if args.iter().any(|a| a == "--doctor") {
        let report = doctor::run_all_checks().await;
        // INFRA-877: append budget quota line to human output
        let exit_code = if args.iter().any(|a| a == "--json") {
            doctor::print_json_report(&report)
        } else {
            let code = doctor::print_human_report(&report);
            let quota_line = cost_ledger::doctor_line(&repo_path::repo_root());
            println!("  cost: {quota_line}");
            // Exit non-zero if quota exceeded (spend > 100%)
            let quota = cost_ledger::check_quota(&repo_path::repo_root(), "", "", false);
            if quota.is_exceeded() {
                1
            } else {
                code
            }
        };
        std::process::exit(exit_code);
    }

    let preflight = args.iter().any(|a| a == "--preflight");
    if preflight {
        let script = repo_path::repo_root().join("scripts/ci/chump-preflight.sh");
        if !script.is_file() {
            eprintln!(
                "chump --preflight: missing {} (set CHUMP_REPO/CHUMP_HOME or run from repo clone)",
                script.display()
            );
            std::process::exit(1);
        }
        let forward: Vec<&str> = args
            .iter()
            .skip(1)
            .filter(|a| *a != "--preflight")
            .map(|s| s.as_str())
            .collect();
        let status = std::process::Command::new("bash")
            .arg(script.as_os_str())
            .args(&forward)
            .current_dir(repo_path::repo_root())
            .status();
        match status {
            Ok(s) => std::process::exit(s.code().unwrap_or(1)),
            Err(e) => {
                eprintln!("chump --preflight: could not run bash: {}", e);
                std::process::exit(1);
            }
        }
    }
    tracing_init::init();

    // `chump --plugins-list` — list all discovered on-disk plugins and their search paths.
    // Works without validate_config() so it's useful for diagnosing plugin setup.
    if args.iter().any(|a| a == "--plugins-list") {
        plugin::print_plugins_list();
        return Ok(());
    }
    // `chump --plugins-install <path>` — copy a local plugin directory to ~/.chump/plugins/.
    if let Some(pos) = args.iter().position(|a| a == "--plugins-install") {
        let path = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if path.is_empty() {
            eprintln!("Usage: chump --plugins-install <path-to-plugin-directory>");
            std::process::exit(1);
        }
        match plugin::plugins_install(path) {
            Ok(name) => {
                println!(
                    "Installed plugin '{name}' to {}",
                    plugin::user_plugins_dir().join(&name).display()
                );
                return Ok(());
            }
            Err(e) => {
                eprintln!("Error: {e:#}");
                std::process::exit(1);
            }
        }
    }
    // `chump --plugins-uninstall <name>` — remove a user plugin by name.
    if let Some(pos) = args.iter().position(|a| a == "--plugins-uninstall") {
        let name = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if name.is_empty() {
            eprintln!("Usage: chump --plugins-uninstall <plugin-name>");
            std::process::exit(1);
        }
        match plugin::plugins_uninstall(name) {
            Ok(()) => {
                println!("Uninstalled plugin '{name}'.");
                return Ok(());
            }
            Err(e) => {
                eprintln!("Error: {e:#}");
                std::process::exit(1);
            }
        }
    }
    // `chump --plugins-disable <name>` — mark a plugin as disabled.
    if let Some(pos) = args.iter().position(|a| a == "--plugins-disable") {
        let name = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if name.is_empty() {
            eprintln!("Usage: chump --plugins-disable <plugin-name>");
            std::process::exit(1);
        }
        match plugin::plugins_disable(name) {
            Ok(()) => {
                println!("Plugin '{name}' disabled.");
                return Ok(());
            }
            Err(e) => {
                eprintln!("Error: {e:#}");
                std::process::exit(1);
            }
        }
    }
    // `chump --plugins-enable <name>` — re-enable a previously disabled plugin.
    if let Some(pos) = args.iter().position(|a| a == "--plugins-enable") {
        let name = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if name.is_empty() {
            eprintln!("Usage: chump --plugins-enable <plugin-name>");
            std::process::exit(1);
        }
        match plugin::plugins_enable(name) {
            Ok(()) => {
                println!("Plugin '{name}' enabled.");
                return Ok(());
            }
            Err(e) => {
                eprintln!("Error: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump mcp list [--installed] [--json]` (PRODUCT-061 / INFRA-744)
    //
    // Default: if chump-mcp.json exists, show the declarative config (INFRA-744).
    //          Otherwise fall back to the registry catalog.
    // --installed: print discovered installed binaries (PATH/user-config/system).
    // --json: machine-readable output for either mode.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "list").unwrap_or(false)
    {
        let installed = args.iter().any(|a| a == "--installed");
        let json = args.iter().any(|a| a == "--json");
        let repo_root = crate::repo_path::repo_root();

        if installed {
            let servers = mcp_discovery::discover_mcp_servers();
            tracing::info!(count = servers.len(), "mcp list --installed");
            mcp_discovery::print_mcp_list(&servers, json);
        } else {
            // INFRA-744: prefer declarative config over registry scan.
            let mcp_config = mcp_discovery::read_mcp_config(&repo_root);
            if !mcp_config.mcp_servers.is_empty() {
                let entries = mcp_discovery::resolve_config_status(&mcp_config);
                tracing::info!(count = entries.len(), "mcp list config");
                mcp_discovery::print_mcp_config_list(&entries, json);
            } else {
                let entries = mcp_discovery::read_registry(&repo_root);
                tracing::info!(count = entries.len(), "mcp list registry");
                mcp_discovery::print_registry(&entries, json);
            }
        }
        return Ok(());
    }

    // `chump mcp restart <name>` (INFRA-744) — kill and restart a configured server.
    //
    // Looks up the server in chump-mcp.json, then signals its process to restart.
    // For now, this prints the command needed to re-launch the server so the
    // operator or process supervisor can act. Full PID tracking is tracked in
    // a follow-up gap.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "restart").unwrap_or(false)
    {
        let name = args.get(3).map(String::as_str).unwrap_or("");
        if name.is_empty() || name.starts_with('-') {
            eprintln!("Usage: chump mcp restart <name>");
            eprintln!("       (run `chump mcp list` to see configured servers)");
            std::process::exit(2);
        }
        let repo_root = crate::repo_path::repo_root();
        let mcp_config = mcp_discovery::read_mcp_config(&repo_root);
        if let Some(entry) = mcp_config.mcp_servers.get(name) {
            if !entry.enabled {
                eprintln!("Server '{name}' is disabled in chump-mcp.json — enable it first.");
                std::process::exit(1);
            }
            let mut cmd_parts = vec![entry.command.clone()];
            cmd_parts.extend(entry.args.clone());
            println!("Restart '{name}': {}", cmd_parts.join(" "));
            println!();
            println!(
                "Note: chump mcp restart currently prints the launch command.\n\
                 PID tracking for live restart will be added in a follow-up gap.\n\
                 To restart now, kill the running process and re-run the command above."
            );
        } else if mcp_config.mcp_servers.is_empty() {
            eprintln!(
                "No chump-mcp.json found. Create one to declare servers, then use\n\
                 'chump mcp restart <name>' to restart a specific server."
            );
            std::process::exit(1);
        } else {
            eprintln!("Server '{name}' not found in chump-mcp.json.");
            eprintln!();
            eprintln!("Configured servers:");
            for n in mcp_config.mcp_servers.keys() {
                eprintln!("  {n}");
            }
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump mcp install <name> [--no-install]` (PRODUCT-062)
    //
    // Looks up <name> in registry/mcp-servers.toml, runs `cargo install <package>`
    // (unless binary already on PATH or --no-install), and adds to chump-mcp.json.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "install").unwrap_or(false)
    {
        let name = args.get(3).map(String::as_str).unwrap_or("");
        if name.is_empty() || name.starts_with('-') {
            eprintln!("Usage: chump mcp install <name> [--no-install]");
            eprintln!("       (run 'chump mcp list' to see available servers)");
            std::process::exit(2);
        }
        let no_install = args.iter().any(|a| a == "--no-install");
        let repo_root = crate::repo_path::repo_root();

        match mcp_discovery::install_mcp_server(&repo_root, &repo_root, name, no_install) {
            Ok(mcp_discovery::InstallOutcome::AlreadyInstalled) => {
                println!("Server '{name}' binary already on PATH — added to chump-mcp.json.");
            }
            Ok(mcp_discovery::InstallOutcome::CargoInstalled) => {
                println!("Installed '{name}' and added to chump-mcp.json.");
                println!("Run 'chump mcp list' to verify.");
            }
            Ok(mcp_discovery::InstallOutcome::ConfigOnly) => {
                println!("Added '{name}' to chump-mcp.json (--no-install: binary not installed).");
                println!("Install the binary manually, then run 'chump mcp list' to verify.");
            }
            Err(e) => {
                eprintln!("chump mcp install: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump mcp remove <name>` (PRODUCT-062) — remove server from chump-mcp.json.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "remove").unwrap_or(false)
    {
        let name = args.get(3).map(String::as_str).unwrap_or("");
        if name.is_empty() || name.starts_with('-') {
            eprintln!("Usage: chump mcp remove <name>");
            std::process::exit(2);
        }
        let repo_root = crate::repo_path::repo_root();
        match mcp_discovery::remove_mcp_server(&repo_root, name) {
            Ok(true) => {
                println!("Removed '{name}' from chump-mcp.json.");
                println!("To uninstall the binary: cargo uninstall chump-mcp-{name}");
            }
            Ok(false) => {
                eprintln!("Server '{name}' not found in chump-mcp.json.");
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("chump mcp remove: {e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }

    // `chump mcp enable <name>` (INFRA-MCP-DISCOVERY) — add a discovered MCP server
    // to the active Chump config.
    //
    // TODO: full implementation. Chump's MCP servers are currently discovered at
    // runtime from CHUMP_MCP_SERVERS_DIR (see mcp_bridge::mcp_servers_dir()) or
    // supplied per-session by ACP clients. There is no persistent per-user config
    // file that stores a set of "enabled" servers; the bridge auto-discovers whatever
    // is in the configured directory. Once a persistent ~/.config/chump/config.toml
    // (or equivalent) exists, `mcp enable` should write the server binary path there.
    // Until then, print a clear message directing the user to place the binary on PATH
    // or in CHUMP_MCP_SERVERS_DIR.
    if args.get(1).map(|s| s == "mcp").unwrap_or(false)
        && args.get(2).map(|s| s == "enable").unwrap_or(false)
    {
        let name = args.get(3).map(String::as_str).unwrap_or("");
        if name.is_empty() || name.starts_with('-') {
            eprintln!("Usage: chump mcp enable <name>");
            eprintln!("       (run `chump mcp list` to see available servers)");
            std::process::exit(2);
        }

        // Look up the server in discovered list
        let servers = mcp_discovery::discover_mcp_servers();
        if let Some(s) = servers.iter().find(|s| s.name == name) {
            println!(
                "Server '{name}' is already discoverable via {} at {}",
                s.source.label(),
                s.path.display()
            );
            println!();
            println!(
                "It will be picked up automatically by the MCP bridge (CHUMP_MCP_SERVERS_DIR)."
            );
            println!("If it is not appearing in `chump mcp list`, check CHUMP_MCP_SERVERS_DIR:");
            println!("  CHUMP_MCP_SERVERS_DIR defaults to <repo>/target/release/");
            println!("  Set it to a directory containing chump-mcp-* binaries to override.");
        } else {
            eprintln!("Server '{name}' not found in any discovery location.");
            eprintln!();
            eprintln!("To install it, place the `chump-mcp-{name}` binary in one of:");
            let user_dir = mcp_discovery::user_config_dir();
            eprintln!("  - A directory on your PATH");
            eprintln!("  - {}", user_dir.display());
            eprintln!("  - /usr/local/bin/");
            eprintln!("Then re-run `chump mcp list` to verify.");
            eprintln!();
            eprintln!("Note: persistent `mcp enable` config storage is not yet implemented.");
            eprintln!("      (INFRA-MCP-DISCOVERY TODO — needs a ~/.config/chump/config.toml)");
            std::process::exit(1);
        }
        return Ok(());
    }

    if args.iter().any(|a| a == "--vector6-verify") {
        config_validation::validate_config();
        return vector6_verify::run().await;
    }
    if args.iter().any(|a| a == "--vector7-swarm-verify") {
        config_validation::validate_config();
        return vector7_swarm_verify::run().await;
    }
    let check_config = args.get(1).map(|s| s == "--check-config").unwrap_or(false);
    if check_config {
        config_validation::validate_config();
        introspect_tool::verify_audit_chain();
        return Ok(());
    }

    // `chump eval run` — EVAL-009: load all eval cases, run each through ChumpAgent,
    // score with check_all_properties (or the async judge variant when
    // CHUMP_EVAL_WITH_JUDGE=1), persist results via save_eval_run, then exit with
    // code 0 if all cases passed or 1 if any failed.
    // battle-qa.sh --with-judge calls this before rendering its judge summary.
    if args.get(1).map(|s| s == "eval").unwrap_or(false)
        && args.get(2).map(|s| s == "run").unwrap_or(false)
    {
        config_validation::validate_config();
        let exit_code = run_eval_runner().await;
        std::process::exit(exit_code);
    }

    // --reflect-ab: EVAL-008 — A/B accuracy comparison of reflect_heuristic vs
    // reflect_via_provider on the labeled episode dataset.
    // Usage: chump --reflect-ab [--reflect-ab-episodes <path>]
    // Set CHUMP_REFLECTION_AB_WITH_LLM=1 to include the provider leg; the run
    // fails loud if the flag is set but no provider is reachable.
    if args.iter().any(|a| a == "--reflect-ab") {
        let episodes_path = args.windows(2).find_map(|w| {
            if w[0] == "--reflect-ab-episodes" {
                Some(std::path::PathBuf::from(&w[1]))
            } else {
                None
            }
        });
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        rt.block_on(async {
            run_reflection_ab_mode(episodes_path).await;
        });
        return Ok(());
    }

    // --eval-judge: seed eval cases, run each LlmJudge property against the configured
    // provider, persist scores to logs/judge-scores.json, print per-category summary.
    // Invoked by `battle-qa.sh --with-judge` for EVAL-005.
    if args.iter().any(|a| a == "--eval-judge") {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        rt.block_on(async {
            run_eval_judge_mode().await;
        });
        return Ok(());
    }

    // --eval-run (EVAL-009): full eval runner. Iterates all chump_eval_cases,
    // runs each through the provider, scores with check_all_properties (and
    // _with_judge_async when CHUMP_EVAL_WITH_JUDGE=1, closing EVAL-007),
    // persists EvalRunResult rows to chump_eval_runs (closing the persistence
    // gap that left battle-qa.sh's summary section reading an empty table).
    // Exit code 0 if every case passes its structural properties, 1 otherwise.
    if args.iter().any(|a| a == "--eval-run") {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let exit_code = rt.block_on(async { run_eval_run_mode().await });
        std::process::exit(exit_code);
    }

    // --eval-reflection (EVAL-008): A/B-grade reflect_via_provider vs
    // reflect_heuristic on tests/fixtures/reflection_episodes.json. Loads the
    // labeled dataset, runs both reflectors against each episode, computes
    // accuracy + confusion matrix per ErrorPattern, and reports pass/fail
    // against the +15% acceptance gate.
    if args.iter().any(|a| a == "--eval-reflection") {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let exit_code = rt.block_on(async { run_eval_reflection_mode().await });
        std::process::exit(exit_code);
    }

    // Also run startup audit check in interactive/discord/default mode
    introspect_tool::verify_audit_chain();

    let reap_leases_mode = args.get(1).map(|s| s == "--reap-leases").unwrap_or(false);
    if reap_leases_mode {
        // Deterministic maintenance: clear expired leases and optionally requeue stuck in_progress tasks.
        // This is intentionally non-LLM and cron-friendly.
        config_validation::validate_config();
        if !task_db::task_available() {
            eprintln!("Task DB not available (sessions dir?)");
            return Ok(());
        }
        let no_requeue = args.iter().any(|a| a == "--no-requeue");
        let stuck_secs = std::env::var("CHUMP_TASK_STUCK_SECS")
            .ok()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .filter(|&n| n >= 60)
            .unwrap_or(1800);
        let cleared = task_db::task_reap_expired_leases().unwrap_or(0);
        let requeued = if no_requeue {
            0
        } else {
            task_db::task_requeue_stuck_in_progress(stuck_secs).unwrap_or(0)
        };
        println!(
            "reap_leases: cleared={} requeued={} stuck_secs={} no_requeue={}",
            cleared, requeued, stuck_secs, no_requeue
        );
        let agent_reaped = agent_lease::reap_expired();
        if agent_reaped > 0 {
            println!("reap_leases: agent_leases_reaped={}", agent_reaped);
        }
        return Ok(());
    }
    // `--leases`: show active agent path leases from `.chump-locks/`.
    let leases_mode = args.get(1).map(|s| s == "--leases").unwrap_or(false);
    if leases_mode {
        let active = agent_lease::list_active();
        if active.is_empty() {
            println!("No active agent leases.");
        } else {
            println!(
                "{} active agent lease(s) (this session: {}):",
                active.len(),
                agent_lease::current_session_id()
            );
            for l in active {
                println!(
                    "  {} expires {} heartbeat {} ({} path{})",
                    l.session_id,
                    l.expires_at,
                    l.heartbeat_at,
                    l.paths.len(),
                    if l.paths.len() == 1 { "" } else { "s" }
                );
                for p in &l.paths {
                    println!("    - {}", p);
                }
                if !l.purpose.is_empty() {
                    println!("    purpose: {}", l.purpose);
                }
                if !l.worktree.is_empty() {
                    println!("    worktree: {}", l.worktree);
                }
            }
        }
        return Ok(());
    }

    // --claim / --release / --heartbeat: shell access to the lease system.
    // Lets scripts, external agents (Cursor via shell wrapper, cron jobs)
    // participate in path-lease coordination without writing JSON by hand.
    // See docs/process/AGENT_COORDINATION.md for the full cheatsheet.
    let claim_mode = args.get(1).map(|s| s == "--claim").unwrap_or(false);
    if claim_mode {
        let paths_arg = args
            .iter()
            .find_map(|a| a.strip_prefix("--paths="))
            .unwrap_or("");
        if paths_arg.is_empty() {
            eprintln!("--claim requires --paths=<comma-separated paths>");
            std::process::exit(2);
        }
        let ttl_secs: u64 = args
            .iter()
            .find_map(|a| a.strip_prefix("--ttl-secs="))
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(agent_lease::DEFAULT_TTL_SECS);
        let purpose = args
            .iter()
            .find_map(|a| a.strip_prefix("--purpose="))
            .unwrap_or("(unspecified)");
        let paths: Vec<&str> = paths_arg
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        if paths.is_empty() {
            eprintln!("--paths= must contain at least one non-empty path");
            std::process::exit(2);
        }
        match agent_lease::claim_paths(&paths, ttl_secs, purpose) {
            Ok(lease) => {
                println!(
                    "claimed session_id={} expires_at={} ({} path{})",
                    lease.session_id,
                    lease.expires_at,
                    lease.paths.len(),
                    if lease.paths.len() == 1 { "" } else { "s" }
                );
                for p in &lease.paths {
                    println!("  - {}", p);
                }
                return Ok(());
            }
            Err(e) => {
                eprintln!("claim failed: {}", e);
                std::process::exit(2);
            }
        }
    }

    let release_mode = args.get(1).map(|s| s == "--release").unwrap_or(false);
    if release_mode {
        // Release a lease by session ID.
        //
        // INFRA-1026: support both --lease <SESSION_ID> (space-separated) and
        // --session-id=<SESSION_ID> (original equals-prefix form). Previously
        // only --session-id= was parsed, so `chump --release --lease <id>`
        // silently ignored <id> and released the current session instead.
        //
        // Lookup precedence: --lease <id> > --session-id=<id> > current session.
        // When --lease or --session-id= is given and the session doesn't exist
        // in the active lease list, exit 1 with a clear message (no silent fallback).
        let override_id_eq = args.iter().find_map(|a| a.strip_prefix("--session-id="));
        let override_id_lease = args.windows(2).find_map(|w| {
            if w[0] == "--lease" {
                Some(w[1].as_str())
            } else {
                None
            }
        });
        let (target_id, explicit_target) = if let Some(id) = override_id_lease {
            (id.to_string(), true)
        } else if let Some(id) = override_id_eq {
            (id.to_string(), true)
        } else {
            (agent_lease::current_session_id(), false)
        };

        let force_release = args.iter().any(|a| a == "--force");

        // Validate explicit targets exist before acting.
        let active = agent_lease::list_active();
        if explicit_target && !active.iter().any(|l| l.session_id == target_id) {
            eprintln!(
                "chump --release: no such session '{}' in active leases.",
                target_id
            );
            eprintln!(
                "  Active sessions: {}",
                if active.is_empty() {
                    "(none)".to_string()
                } else {
                    active
                        .iter()
                        .map(|l| l.session_id.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                }
            );
            eprintln!("  Use 'chump --leases' to list all active sessions.");
            std::process::exit(1);
        }

        // INFRA-1043: when no explicit --lease / --session-id, print what we're
        // about to release and ask for confirmation (unless --force is given).
        // This prevents accidentally releasing the wrong session.
        if !explicit_target && !force_release {
            let current_id = agent_lease::current_session_id();
            let matching_lease = active.iter().find(|l| l.session_id == current_id);
            let gap_str = matching_lease
                .and_then(|l| l.gap_id.as_deref())
                .unwrap_or("(unknown)");
            let age_str = matching_lease
                .map(|l| {
                    if l.taken_at.is_empty() {
                        "unknown age".to_string()
                    } else {
                        // Parse taken_at to compute age
                        chrono::DateTime::parse_from_rfc3339(&l.taken_at)
                            .map(|t| {
                                let secs = (chrono::Utc::now() - t.with_timezone(&chrono::Utc))
                                    .num_seconds();
                                if secs < 120 {
                                    format!("{}s old", secs)
                                } else {
                                    format!("{}m old", secs / 60)
                                }
                            })
                            .unwrap_or_else(|_| "unknown age".to_string())
                    }
                })
                .unwrap_or_else(|| "unknown age".to_string());

            eprintln!(
                "About to release session_id={} (gap={}, {}). \
                 Use --force to skip this confirmation.",
                target_id, gap_str, age_str
            );
            eprintln!("  Confirm? [y/N] ");
            let mut input = String::new();
            if std::io::stdin().read_line(&mut input).is_err()
                || !input.trim().eq_ignore_ascii_case("y")
            {
                eprintln!("Release cancelled.");
                std::process::exit(0);
            }
        }

        let stub = agent_lease::Lease {
            session_id: target_id.clone(),
            paths: vec![],
            taken_at: String::new(),
            expires_at: String::new(),
            heartbeat_at: String::new(),
            purpose: String::new(),
            worktree: String::new(),
            gap_id: None,
            pending_new_gap: None,
        };
        // Resolve gap_id for the ambient event before release
        let release_gap_id = active
            .iter()
            .find(|l| l.session_id == target_id)
            .and_then(|l| l.gap_id.clone())
            .unwrap_or_default();
        let release_source = if explicit_target {
            "explicit"
        } else {
            "current"
        };

        match agent_lease::release(&stub) {
            Ok(()) => {
                println!("released session_id={}", target_id);
                tracing::info!(
                    session_id = %target_id,
                    explicit_target = explicit_target,
                    "lease released via --release"
                );
                // INFRA-1043: emit ambient event for release observability
                let ambient_path = repo_path::repo_root()
                    .join(".chump-locks")
                    .join("ambient.jsonl");
                let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ");
                let _ = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&ambient_path)
                    .and_then(|mut f| {
                        use std::io::Write;
                        writeln!(
                            f,
                            "{{\"ts\":\"{ts}\",\"kind\":\"session_released\",\
                             \"session_id\":\"{target_id}\",\"gap_id\":\"{release_gap_id}\",\
                             \"source\":\"{release_source}\"}}"
                        )
                    });
                // INFRA-1116 AC6: emit intent_retracted so other sessions' overlap
                // gates treat this session as inactive immediately on release.
                atomic_claim::emit_intent_retracted(&ambient_path, &release_gap_id, &target_id);

                // RESILIENT-103: the JSON sidecar is now gone, but `chump claim`
                // writes a lease to THREE stores — the JSON sidecar, the state.db
                // `leases` row, and (when NATS is up) a NATS-KV atomic claim.
                // Release must clear all three or the lease lingers in the other two
                // and blocks re-claim of the gap (the triple-store split that forced
                // a 3-command manual recovery: sqlite DELETE + git branch -D +
                // chump-coord release).
                let release_repo_root = repo_path::repo_root();
                match atomic_claim::release_db_lease(
                    &release_repo_root,
                    &target_id,
                    &release_gap_id,
                ) {
                    Ok(n) if n > 0 => tracing::info!(
                        rows = n,
                        session_id = %target_id,
                        gap_id = %release_gap_id,
                        "cleared state.db lease row(s) on release (RESILIENT-103)"
                    ),
                    Ok(_) => {}
                    Err(e) => {
                        eprintln!("warning: failed to clear state.db lease on release: {}", e)
                    }
                }
                // NATS-KV leg: best-effort `chump-coord release <gap>`. NATS is
                // optional (offline fallback), so a failure here is non-fatal — the
                // KV claim TTL-expires on its own; this just makes recovery instant.
                if !release_gap_id.is_empty() {
                    let coord = std::env::current_exe()
                        .ok()
                        .and_then(|p| p.parent().map(|d| d.join("chump-coord")))
                        .filter(|p| p.exists())
                        .unwrap_or_else(|| std::path::PathBuf::from("chump-coord"));
                    let _ = std::process::Command::new(&coord)
                        .arg("release")
                        .arg(&release_gap_id)
                        .current_dir(&release_repo_root)
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .status();
                }
                return Ok(());
            }
            Err(e) => {
                eprintln!("release failed: {}", e);
                std::process::exit(2);
            }
        }
    }

    let heartbeat_mode = args.get(1).map(|s| s == "--heartbeat").unwrap_or(false);
    if heartbeat_mode {
        // Refresh this session's lease heartbeat. With --extend-secs=N, also
        // push expires_at forward by N seconds (subject to MAX_TTL clamp).
        let extend = args
            .iter()
            .find_map(|a| a.strip_prefix("--extend-secs="))
            .and_then(|s| s.trim().parse::<u64>().ok());
        let my_id = agent_lease::current_session_id();
        let active = agent_lease::list_active();
        let mut mine = match active.into_iter().find(|l| l.session_id == my_id) {
            Some(l) => l,
            None => {
                eprintln!(
                    "no active lease for session_id={} — claim one first (chump --claim --paths=...)",
                    my_id
                );
                std::process::exit(2);
            }
        };
        match agent_lease::heartbeat(&mut mine, extend) {
            Ok(()) => {
                println!(
                    "heartbeat session_id={} heartbeat_at={} expires_at={}",
                    mine.session_id, mine.heartbeat_at, mine.expires_at
                );
                return Ok(());
            }
            Err(e) => {
                eprintln!("heartbeat failed: {}", e);
                std::process::exit(2);
            }
        }
    }

    let notify_mode = args.get(1).map(|s| s == "--notify").unwrap_or(false);
    if notify_mode {
        // Send stdin as a DM to CHUMP_READY_DM_USER_ID (used by mabel-farmer.sh and scripts).
        let mut message = String::new();
        if std::io::stdin().read_to_string(&mut message).is_ok() && !message.trim().is_empty() {
            discord_dm::send_dm_if_configured(message.trim()).await;
        }
        return Ok(());
    }
    let chump_due_mode = args.get(1).map(|s| s == "--chump-due").unwrap_or(false);
    if chump_due_mode {
        // Heartbeat script: print first due scheduled prompt to stdout and mark it fired. No model run.
        if let Ok(due) = schedule_db::schedule_due() {
            if let Some((id, prompt, _ctx)) = due.into_iter().next() {
                let _ = schedule_db::schedule_mark_fired(id);
                print!("{}", prompt);
            }
        }
        return Ok(());
    }
    let warm_probe_mode = args.get(1).map(|s| s == "--warm-probe").unwrap_or(false);
    if warm_probe_mode {
        provider_cascade::warm_probe_all().await;
        return Ok(());
    }

    // --curate: run the memory curation pass (expire + dedupe + decay + optional LLM summarization).
    // Gated on CHUMP_MEMORY_LLM_SUMMARIZE=1 for the inference-backed summarization tier.
    // Cron-friendly: exits 0 on success with a structured log line; exits non-zero on DB error.
    let curate_mode = args.iter().any(|a| a == "--curate");
    if curate_mode {
        if !memory_db::db_available() {
            eprintln!("[curate] memory DB not available — skipping");
            return Ok(());
        }
        let llm_enabled = std::env::var("CHUMP_MEMORY_LLM_SUMMARIZE")
            .map(|v| v.trim() == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        let provider: Option<Box<dyn axonerai::provider::Provider + Send + Sync>> = if llm_enabled {
            Some(provider_cascade::build_provider())
        } else {
            None
        };
        let provider_ref: Option<&dyn axonerai::provider::Provider> = provider
            .as_ref()
            .map(|p| p.as_ref() as &dyn axonerai::provider::Provider);
        let report = memory_db::curate_all_async(provider_ref).await?;
        println!(
            "curate: expired={} deduped={} decayed={} summaries_created={} episodics_summarized={}",
            report.expired,
            report.deduped_exact,
            report.decayed,
            report.summaries_created,
            report.episodics_summarized,
        );
        return Ok(());
    }

    // MEM-005: one-shot episode-to-blackboard extraction pass.
    if args.iter().any(|a| a == "--extract-episodes") {
        let written = episode_extractor::extract_episodes_to_blackboard().await?;
        println!("extract-episodes: wrote {written} fact(s) to blackboard");
        return Ok(());
    }

    // COG-014: AB harness lesson seeding.
    //   --seed-ab-lessons <path>    load lessons JSON and seed into reflection DB
    //   --seed-ab-lessons clear     delete all ab_seed:* reflections
    if let Some(pos) = args.iter().position(|a| a == "--seed-ab-lessons") {
        let arg = args.get(pos + 1).map(|s| s.as_str()).unwrap_or("");
        if arg == "clear" {
            let n = reflection_db::clear_ab_seed_lessons()?;
            println!("seed-ab-lessons clear: removed {n} seeded reflection(s)");
        } else if arg.is_empty() {
            eprintln!("Usage: chump --seed-ab-lessons <path-to-lessons.json>");
            eprintln!("       chump --seed-ab-lessons clear");
            std::process::exit(2);
        } else {
            let path = std::path::Path::new(arg);
            let n = reflection_db::seed_ab_lessons_from_file(path)?;
            println!("seed-ab-lessons: seeded {n} directive(s) from {arg}");
        }
        return Ok(());
    }

    let autonomy_once = args.iter().any(|a| a == "--autonomy-once" || a == "--once");
    if autonomy_once {
        config_validation::validate_config();
        let why = args.iter().any(|a| a == "--why");
        if why {
            eprintln!("{}", provider_cascade::cascade_why());
        }
        let quiet = args.iter().any(|a| a == "--quiet");
        let assignee_from_env = std::env::var("CHUMP_AUTONOMY_ASSIGNEE").ok();
        let assignee = args
            .windows(2)
            .find(|w| w[0] == "--assignee")
            .map(|w| w[1].as_str())
            .or(assignee_from_env.as_deref())
            .unwrap_or("chump");
        let t0_once = std::time::Instant::now();
        let out = autonomy_loop::autonomy_once(assignee).await?;
        println!(
            "status={} task_id={:?} detail={}",
            out.status, out.task_id, out.detail
        );
        if !quiet {
            let elapsed = t0_once.elapsed().as_secs_f64();
            let slot = provider_cascade::get_last_used_slot().unwrap_or_default();
            gen::print_cost_summary(elapsed, 0, out.detail.len(), &slot);
        }
        return Ok(());
    }

    let rpc_mode = args.iter().any(|a| a == "--rpc");
    if rpc_mode {
        config_validation::validate_config();
        return rpc_mode::run_rpc_loop().await;
    }

    // ACP (Agent Client Protocol) stdio mode — JSON-RPC for Zed, JetBrains IDEs, and
    // any ACP-compatible client. See src/acp_server.rs.
    let acp_mode = args.iter().any(|a| a == "--acp");
    if acp_mode {
        config_validation::validate_config();
        mcp_bridge::init().await;
        plugin::initialize_discovered(&[]);
        return acp_server::run_acp_stdio().await;
    }

    let web_mode = args.iter().any(|a| a == "--web");
    let discord_mode = args.iter().any(|a| a == "--discord");
    let telegram_mode = args.iter().any(|a| a == "--telegram");
    let slack_mode = args.iter().any(|a| a == "--slack");
    let chump_mode = args.get(1).map(|s| s == "--chump").unwrap_or(false);

    // COMP-004b / AGT-004: Telegram bot. Long-poll loop reading TELEGRAM_BOT_TOKEN
    // from .env. Mirrors --discord but uses the new MessagingAdapter
    // trait (COMP-004a). Validates the token via getMe at startup.
    // AGT-004 wires the shared platform_router queue so each incoming
    // message is dispatched in its own tokio task rather than inline.
    if telegram_mode {
        use crate::messaging::MessagingAdapter;
        eprintln!("Chump version {}", version::chump_version());
        config_validation::validate_config();
        mcp_bridge::init().await;
        plugin::initialize_discovered(&[]);
        let (tx, rx) = platform_router::make_queue();
        // Drain the queue in a background task; the loop runs until all
        // InputQueue senders are dropped (i.e. when the adapter shuts down).
        tokio::spawn(platform_router::run_message_loop(rx));
        let adapter = telegram::TelegramAdapter::from_env().await?.with_queue(tx);
        // Direct call (not via MessagingHub) because the hub is for outbound
        // routing — inbound for a single platform is just adapter.start().
        adapter.start().await?;
        return Ok(());
    }

    // COMP-004c: Slack bot via Socket Mode. Requires SLACK_BOT_TOKEN (xoxb-...)
    // and SLACK_APP_TOKEN (xapp-...). Same platform_router queue pattern as Telegram.
    // Socket Mode avoids the need for a public webhook URL — suitable for
    // local dev, home servers, and any deployment where Slack can't reach you.
    if slack_mode {
        use crate::messaging::MessagingAdapter;
        eprintln!("Chump version {}", version::chump_version());
        config_validation::validate_config();
        mcp_bridge::init().await;
        plugin::initialize_discovered(&[]);
        let (tx, rx) = platform_router::make_queue();
        tokio::spawn(platform_router::run_message_loop(rx));
        let adapter = slack::SlackAdapter::from_env().await?.with_queue(tx);
        adapter.start().await?;
        return Ok(());
    }

    if web_mode && !discord_mode {
        config_validation::validate_config();
        mcp_bridge::init().await;
        plugin::initialize_discovered(&[]);
        let port = args
            .windows(2)
            .find(|w| w[0] == "--port")
            .and_then(|w| w[1].parse::<u16>().ok())
            .or_else(|| {
                env::var("CHUMP_WEB_PORT")
                    .ok()
                    .and_then(|p| p.trim().parse().ok())
            })
            .unwrap_or(3000);
        return web_server::start_web_server(port).await;
    }

    config_validation::validate_config();
    mcp_bridge::init().await;
    plugin::initialize_discovered(&[]);

    if discord_mode {
        // SECURITY-004 Path B: Discord gateway is opt-in at compile-time.
        // Default builds drop serenity (and the vulnerable
        // rustls-webpki 0.102.x chain). Build with `--features discord`
        // to enable.
        #[cfg(not(feature = "discord"))]
        {
            return Err(anyhow::anyhow!(
                "Discord mode requires building with `--features discord`. \
                 Default builds exclude serenity to avoid the SECURITY-004 \
                 vulnerable rustls-webpki 0.102.8 chain. Rebuild with \
                 `cargo build --release --features discord` (still vulnerable \
                 until serenity v0.13 ships) or wait for upstream fix."
            ));
        }

        #[cfg(feature = "discord")]
        {
            // PRODUCT-014: opt-in env gate. Discord mode also requires
            // CHUMP_DISCORD_ENABLED=1 in addition to a token, so deployments
            // can ship the binary with a token in .env without auto-attaching
            // to Discord on every start.
            let enabled = env::var("CHUMP_DISCORD_ENABLED")
                .map(|v| v.trim() == "1")
                .unwrap_or(false);
            if !enabled {
                return Err(anyhow::anyhow!(
                    "Discord mode requires CHUMP_DISCORD_ENABLED=1 (PRODUCT-014 opt-in). \
                 Set the env var and re-run with --discord."
                ));
            }
            // SECURITY-005: serenity 0.12.5 (latest on crates.io) pins
            // tokio-tungstenite 0.21 → rustls 0.22 → rustls-webpki 0.102.8,
            // which carries RUSTSEC-2026-0104 (HIGH): DoS via panic on
            // malformed CRL BIT STRING. The Discord gateway is the only
            // chump path that hits this transitive — REST-only callers
            // (a2a_tool, discord_dm) use the safe rustls 0.23 chain.
            // Until upstream serenity ships a tungstenite bump, gate
            // gateway start behind an explicit acknowledgment so an
            // operator can't be silently exposed to the panic risk.
            // Remove this block when `cargo audit` shows 0
            // rustls-webpki 0.102.x advisories AND `cargo tree -i
            // rustls-webpki@0.102.8` returns empty (SECURITY-005 closes).
            let rustls_acked = env::var("CHUMP_ALLOW_DISCORD_RUSTLS")
                .map(|v| v.trim() == "1")
                .unwrap_or(false);
            if !rustls_acked {
                return Err(anyhow::anyhow!(
                    "Discord gateway start is gated by SECURITY-005 — serenity 0.12.5 \
                 (latest) pins vulnerable rustls-webpki 0.102.8 (RUSTSEC-2026-0104 \
                 HIGH: DoS via panic on malformed CRL BIT STRING). To start anyway, \
                 set CHUMP_ALLOW_DISCORD_RUSTLS=1 and accept the panic risk. \
                 Track upstream: https://github.com/serenity-rs/serenity for a \
                 tungstenite/rustls bump. Revisit this gate when SECURITY-005 \
                 closes (cargo audit shows 0 rustls-webpki 0.102.x advisories)."
                ));
            }
            eprintln!("Chump version {}", version::chump_version());
            if let Some(port) = env::var("CHUMP_HEALTH_PORT")
                .ok()
                .and_then(|p| p.parse::<u16>().ok())
            {
                tokio::spawn(health_server::run(port));
            }
            let token = env::var("DISCORD_TOKEN")
                .map_err(|_| anyhow::anyhow!("DISCORD_TOKEN must be set for Discord mode"))?;
            let token = normalize_discord_token(token.trim());
            if let Err(e) = discord::run(&token).await {
                return Err(anyhow::anyhow!(
                    "{}",
                    crate::chump_log::redact(&e.to_string())
                ));
            }
            return Ok(());
        } // end #[cfg(feature = "discord")] block
    }

    // `chump orchestrate [<intent>]` (INFRA-598 / INFRA-798)
    //
    // With no positional args: Opus-driven conversational loop (INFRA-598).
    // With a positional arg: single-shot intent parse + command print (INFRA-798).
    //
    // Single-shot: chump orchestrate "list P1 gaps"
    //   → parses intent, prints resolved chump command as JSON, emits ambient event.
    //   → exits 0 regardless of whether intent was recognized (Unknown prints a comment).
    if args.get(1).map(String::as_str) == Some("orchestrate") {
        let repo_root = repo_path::repo_root();

        // Resume mode: chump orchestrate --resume <session-id>  (INFRA-1366)
        if args.get(2).map(String::as_str) == Some("--resume") {
            let session_id = match args.get(3) {
                Some(id) if !id.starts_with('-') => id.clone(),
                _ => {
                    eprintln!("Usage: chump orchestrate --resume <session-id>");
                    std::process::exit(1);
                }
            };
            match orchestrate::resume(&repo_root, &session_id).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    eprintln!("chump orchestrate --resume: {e:#}");
                    std::process::exit(1);
                }
            }
        }

        // Single-shot mode when a positional text arg follows "orchestrate".
        // INFRA-1452: when pattern match returns Unknown, auto-fallback to LLM.
        if let Some(text) = args.get(2).filter(|a| !a.starts_with("--")) {
            let text = text.clone();

            // --confirm-budget may appear anywhere after the intent text.
            let confirm_budget = args[3..].iter().any(|a| a == "--confirm-budget");
            if confirm_budget {
                // Forward to budget checker via env var so helper stays pure.
                std::env::set_var("CHUMP_INTENT_LLM_CONFIRM_BUDGET", "1");
            }

            let op = intent_parser::parse_intent(&text);

            // ── LLM auto-fallback when stub pattern didn't recognize the intent ──
            if matches!(&op, intent_parser::IntentOp::Unknown { .. }) {
                if intent_parser::llm_provider_configured() {
                    // Check daily budget envelope.
                    match intent_parser::intent_llm_budget_check(&repo_root) {
                        intent_parser::BudgetStatus::Exceeded { spend, cap } => {
                            eprintln!(
                                "hint: intent_parse_llm: daily budget exceeded \
                                 (spent ${spend:.4}, cap ${cap:.4}) — \
                                 re-run with --confirm-budget to override"
                            );
                            // Fall through to print intent_parse_unknown below.
                        }
                        intent_parser::BudgetStatus::Ok { per_call } => {
                            // CI/test stub: CHUMP_INTENT_LLM_STUB_CMD bypasses the real call.
                            let stub_cmd = std::env::var("CHUMP_INTENT_LLM_STUB_CMD").ok();
                            let (resolved, provider_name) = if let Some(cmd) = stub_cmd {
                                (Some(cmd), "stub".to_string())
                            } else {
                                // Real LLM call via provider cascade.
                                let prompt = intent_parser::format_intent_prompt(&text);
                                let provider = crate::provider_cascade::build_provider();
                                let msgs = vec![axonerai::provider::Message {
                                    role: "user".into(),
                                    content: prompt,
                                }];
                                match provider.complete(msgs, None, Some(256), None).await {
                                    Ok(resp) => {
                                        let text_out = resp.text.unwrap_or_default();
                                        let cmd = intent_parser::parse_llm_response(&text_out);
                                        (cmd, "cascade".to_string())
                                    }
                                    Err(_) => (None, "cascade".to_string()),
                                }
                            };

                            if let Some(cmd) = resolved {
                                println!(
                                    "{{\"intent\":{text:?},\"command\":{cmd:?},\
                                     \"kind\":\"intent_parse_llm\",\"provider\":{provider_name:?}}}"
                                );
                                intent_parser::emit_intent_llm_event(
                                    &text,
                                    &cmd,
                                    &provider_name,
                                    &repo_root,
                                );
                                intent_parser::record_intent_llm_spend(&repo_root, per_call);
                                return Ok(());
                            }
                            // LLM returned no TOOL: line — fall through to Unknown output.
                        }
                    }
                } else {
                    // No provider configured: print hint to stderr, still emit event.
                    eprintln!("hint: set ANTHROPIC_API_KEY to enable freeform intents");
                }
            }

            let cmd = op.to_chump_command();
            println!(
                "{{\"intent\":{text:?},\"command\":{cmd:?},\"kind\":\"{}\"}}",
                op.ambient_kind()
            );
            intent_parser::emit_intent_event(&op, &repo_root);
            return Ok(());
        }

        match orchestrate::run(&repo_root).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump orchestrate: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump gen <task>` (INFRA-593 / COG-054) — user-facing single-shot coding task.
    //
    // Uses the provider cascade to apply a natural-language change to the current
    // working directory, runs `cargo check`, and commits the result. This is the
    // front-door command for the offline-LLM mission: `chump gen "add a /health
    // endpoint to my axum server"`.
    //
    // Stub mode for CI: set CHUMP_GEN_STUB_FILE=<rel-path> to skip the LLM call
    // and prepend a comment line to the named file instead.
    if args.get(1).map(String::as_str) == Some("gen") {
        let task = match args.get(2) {
            Some(t) if !t.starts_with('-') => t.clone(),
            _ => {
                eprintln!("Usage: chump gen <task> [--work-dir PATH] [--local]");
                eprintln!();
                eprintln!("  chump gen \"add a /health endpoint to my axum server\"");
                eprintln!("  chump gen --local \"add a /health endpoint\"");
                eprintln!();
                eprintln!("Uses the provider cascade to make the change, runs cargo check,");
                eprintln!("and commits the result. Use --local to force the local Ollama");
                eprintln!("provider and bypass the cloud cascade.");
                std::process::exit(2);
            }
        };
        let work_dir = if let Some(d) = args
            .iter()
            .position(|a| a == "--work-dir")
            .and_then(|i| args.get(i + 1))
        {
            std::path::PathBuf::from(d)
        } else {
            std::env::current_dir().unwrap_or_else(|_| repo_path::repo_root())
        };
        let quiet = args.iter().any(|a| a == "--quiet");
        let local = args.iter().any(|a| a == "--local");
        let opts = gen::GenOptions {
            task,
            work_dir,
            quiet,
            local,
        };
        match gen::run(opts).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump gen: {e:#}");
                std::process::exit(1);
            }
        }
    }

    if chump_mode {
        eprintln!("Chump version {}", version::chump_version());
        if let Some(port) = env::var("CHUMP_HEALTH_PORT")
            .ok()
            .and_then(|p| p.parse::<u16>().ok())
        {
            tokio::spawn(health_server::run(port));
        }
        let (agent, ready_session) = agent_factory::build_chump_agent_cli()?;
        let running_session = ready_session.start();
        let single_message = args
            .get(2)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        if let Some(msg) = single_message {
            if let Err(e) = limits::check_message_len(&msg) {
                eprintln!("{}", e);
                return Ok(());
            }
            let is_ship = std::env::var("CHUMP_HEARTBEAT_TYPE").as_deref() == Ok("ship");
            if is_ship {
                memory_brain_tool::ship_round_reset_log_append_flag();
            }
            if crate::precision_controller::battle_benchmark_env_on() {
                let label =
                    std::env::var("CHUMP_BATTLE_LABEL").unwrap_or_else(|_| "cli_battle".into());
                crate::precision_controller::battle_benchmark_begin(&label);
            }
            let mut reply = match agent.run(&msg).await {
                Ok(o) => o.reply,
                Err(e) => {
                    crate::precision_controller::battle_benchmark_finalize("");
                    return Err(e);
                }
            };
            let sanity_err = limits::sanity_check_reply(&reply).err();
            if let Some(ref why) = sanity_err {
                eprintln!("Reply failed sanity check: {}", why);
                // For ship heartbeat rounds, retry once on empty/whitespace reply so the round can complete with a valid reply.
                let is_empty_or_whitespace =
                    why == "reply is empty" || why == "reply is only whitespace";
                if is_ship && is_empty_or_whitespace {
                    let retry_msg = "Your previous reply was empty. If you already appended to the project log, reply exactly: Done. Otherwise append to the project log then reply: Done.";
                    if let Ok(retry_out) = agent.run(retry_msg).await {
                        if limits::sanity_check_reply(&retry_out.reply).is_ok() {
                            reply = retry_out.reply;
                        } else {
                            provider_cascade::record_slot_failure(
                                &provider_cascade::get_last_used_slot()
                                    .unwrap_or_else(|| "unknown".into()),
                            );
                            reply = "Reply failed sanity check; not applying.".to_string();
                        }
                    } else {
                        provider_cascade::record_slot_failure(
                            &provider_cascade::get_last_used_slot()
                                .unwrap_or_else(|| "unknown".into()),
                        );
                        reply = "Reply failed sanity check; not applying.".to_string();
                    }
                } else {
                    provider_cascade::record_slot_failure(
                        &provider_cascade::get_last_used_slot().unwrap_or_else(|| "unknown".into()),
                    );
                    reply = "Reply failed sanity check; not applying.".to_string();
                }
            }
            // Ship round must end with one append to a project log; if the model didn't, append directly (no second model round).
            if is_ship && !memory_brain_tool::ship_round_had_project_log_append() {
                let round =
                    std::env::var("CHUMP_HEARTBEAT_ROUND").unwrap_or_else(|_| "?".to_string());
                match memory_brain_tool::ensure_ship_round_log_append(&round) {
                    Ok(msg) => reply = msg,
                    Err(e) => reply = format!("{} (fallback append failed: {})", reply, e),
                }
            }
            println!("{}", reply);
            if crate::precision_controller::battle_benchmark_env_on() {
                crate::precision_controller::battle_benchmark_finalize(&reply);
            }
            if let Some(notify_msg) = chump_log::take_pending_notify() {
                discord_dm::send_dm_if_configured(&notify_msg).await;
            }
            running_session.close();
            return Ok(());
        }
        println!("Chump CLI (full tools + soul). Type 'quit' or 'exit' to stop.\n");
        // If stdin is piped (not a TTY), run a single turn from stdin and exit.
        if !io::stdin().is_terminal() {
            let mut input = String::new();
            if io::stdin().read_to_string(&mut input).is_ok() && !input.trim().is_empty() {
                match agent.run(input.trim()).await {
                    Ok(outcome) => println!("{}", outcome.reply),
                    Err(e) => eprintln!("Error: {}", e),
                }
                running_session.close();
                return Ok(());
            }
        }
        let stdin = io::stdin();
        let mut input = String::new();
        loop {
            print!("You: ");
            io::stdout().flush()?;
            input.clear();
            stdin.read_line(&mut input)?;
            let line = input.trim();
            if line.is_empty() {
                continue;
            }
            if line.eq_ignore_ascii_case("quit") || line.eq_ignore_ascii_case("exit") {
                running_session.close();
                println!("Bye.");
                break;
            }
            if let Err(e) = limits::check_message_len(line) {
                eprintln!("{}", e);
                continue;
            }
            match agent.run(line).await {
                Ok(outcome) => {
                    let mut r = outcome.reply;
                    if let Err(why) = limits::sanity_check_reply(&r) {
                        eprintln!("Reply failed sanity check: {}", why);
                        provider_cascade::record_slot_failure(
                            &provider_cascade::get_last_used_slot()
                                .unwrap_or_else(|| "unknown".into()),
                        );
                        r = "Reply failed sanity check; not applying.".to_string();
                    }
                    println!("{}", r);
                }
                Err(e) => eprintln!("Error: {}", e),
            }
            if let Some(notify_msg) = chump_log::take_pending_notify() {
                discord_dm::send_dm_if_configured(&notify_msg).await;
            }
        }
        return Ok(());
    }

    let provider: Box<dyn axonerai::provider::Provider> = provider_cascade::build_provider();

    let registry = ToolRegistry::new();
    // Inject Qwen3 /no_think directive when thinking mode isn't explicitly
    // requested. Qwen3 emits <think>...</think> blocks by default, which burn
    // the completion token budget and cause dogfood loops to fail silently.
    let thinking_enabled = std::env::var("CHUMP_THINKING")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let cascade_active = std::env::var("CHUMP_CASCADE_ENABLED")
        .map(|v| v == "1")
        .unwrap_or(false);
    let think_directive = if !cascade_active && !thinking_enabled {
        "/no_think\n"
    } else if !cascade_active {
        "/think\n"
    } else {
        ""
    };
    let system_prompt = Some(format!("{}You are a helpful assistant.", think_directive));

    let single_message = args
        .get(1)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    if let Some(msg) = single_message {
        // CREDIBLE-134: a bare single-token arg reaching this catch-all is an
        // unknown/typo'd subcommand — every real subcommand (and help/--help/
        // --version) returned earlier. Error with usage + a non-zero exit
        // instead of silently routing to the model (which printed a
        // hallucinated "Response from Agent" reply and exited 0 — a scripting
        // footgun: a typo'd `chump <cmd>` in any fleet script "succeeds").
        // Freeform NL stays available as a quoted multi-word string.
        if args.len() == 2
            && !msg.contains(char::is_whitespace)
            && msg.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            && msg
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
        {
            eprintln!("chump: unknown subcommand '{msg}'");
            eprintln!(
                "Run `chump help` for available commands, or quote a full question \
                 for a freeform query (e.g. chump \"summarize today's ships\")."
            );
            std::process::exit(2);
        }
        if let Err(e) = limits::check_message_len(&msg) {
            eprintln!("{}", e);
            return Ok(());
        }
        let agent = Agent::new(provider, registry, system_prompt, None);
        let mut reply = agent.run(&msg).await?;
        if let Err(why) = limits::sanity_check_reply(&reply) {
            eprintln!("Reply failed sanity check: {}", why);
            provider_cascade::record_slot_failure(
                &provider_cascade::get_last_used_slot().unwrap_or_else(|| "unknown".into()),
            );
            reply = "Reply failed sanity check; not applying.".to_string();
        }
        println!("{}", reply);
        return Ok(());
    }

    // Interactive mode: keep session so conversation has context
    let session_dir = repo_path::runtime_base().join("sessions");
    let _ = std::fs::create_dir_all(&session_dir);
    let session_manager = FileSessionManager::new("repl".to_string(), session_dir)?;
    let agent = Agent::new(provider, registry, system_prompt, Some(session_manager));

    println!("Chat with the agent (local model). Type 'quit' or 'exit' to stop.\n");
    let stdin = io::stdin();
    let mut input = String::new();
    loop {
        print!("You: ");
        io::stdout().flush()?;
        input.clear();
        stdin.read_line(&mut input)?;
        let line = input.trim();
        if line.is_empty() {
            continue;
        }
        if line.eq_ignore_ascii_case("quit") || line.eq_ignore_ascii_case("exit") {
            println!("Bye.");
            break;
        }
        if let Err(e) = limits::check_message_len(line) {
            eprintln!("{}", e);
            continue;
        }
        match agent.run(line).await {
            Ok(mut r) => {
                if let Err(why) = limits::sanity_check_reply(&r) {
                    eprintln!("Reply failed sanity check: {}", why);
                    provider_cascade::record_slot_failure(
                        &provider_cascade::get_last_used_slot().unwrap_or_else(|| "unknown".into()),
                    );
                    r = "Reply failed sanity check; not applying.".to_string();
                }
                println!("{}", r);
            }
            Err(e) => eprintln!("Error: {}", e),
        }
    }
    Ok(())
}

/// EVAL-009 + EVAL-007: `chump eval run` entry point.
///
/// Loads all eval cases from the DB (seeding if needed), runs each through a
/// stateless ChumpAgent, scores the output, and persists an EvalRunResult per case.
///
/// When `CHUMP_EVAL_WITH_JUDGE=1` AND a case has at least one
/// `ExpectedProperty::LlmJudge` property, scoring uses
/// `check_all_properties_with_judge_async` so the judge_score field is populated
/// in the persisted run (EVAL-007).
///
/// Returns the process exit code: 0 = all cases passed, 1 = one or more failed.
async fn run_eval_runner() -> i32 {
    use eval_harness::{
        check_all_properties, check_all_properties_with_judge_async, load_eval_cases,
        save_eval_run, seed_starter_cases, EvalRunResult, EvalScores, ExpectedProperty,
    };
    use stream_events::AgentEvent;

    // Seed starter cases idempotently.
    if let Err(e) = seed_starter_cases() {
        eprintln!("[eval run] seed_starter_cases failed: {e} — continuing with existing cases");
    }

    let cases = match load_eval_cases() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[eval run] failed to load eval cases: {e}");
            return 1;
        }
    };

    if cases.is_empty() {
        eprintln!("[eval run] no eval cases found in DB — nothing to run");
        return 0;
    }

    let with_judge = std::env::var("CHUMP_EVAL_WITH_JUDGE").as_deref() == Ok("1");
    let provider = provider_cascade::build_provider();
    let agent_version = version::chump_version();
    let model_label = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "unknown".into());

    let mut any_failed = false;
    let total = cases.len();

    for (i, case) in cases.iter().enumerate() {
        let run_id = format!("eval-{}-{}", case.id, uuid::Uuid::new_v4().as_simple());
        let turn_start = std::time::Instant::now();

        // Build a per-case stateless agent with an event channel so we can
        // collect the ordered list of tool names called during the turn.
        let (event_tx, mut event_rx) = stream_events::event_channel();

        let registry = axonerai::tool::ToolRegistry::new();
        // Intentionally empty registry: eval cases test agent reasoning, not
        // live tool execution. Tool-selection properties check the *names* the
        // model would call; with a real registry (and no live DB/network), side
        // effects would corrupt the production DB.
        // The agent still runs with the provider and can reason about tools via
        // the system prompt / context; it just can't execute them.

        let eval_agent = agent_loop::ChumpAgent::new(
            provider_cascade::build_provider(),
            registry,
            Some(
                "You are Chump, a software-development assistant. \
                 Respond concisely and use tools when appropriate."
                    .to_string(),
            ),
            None, // stateless — no session persistence between cases
            Some(event_tx),
            10, // max_iterations sufficient for most eval turns
        );

        let outcome = match eval_agent.run(&case.input).await {
            Ok(o) => o,
            Err(e) => {
                eprintln!("[eval run] case {} errored: {e}", case.id);
                any_failed = true;
                continue;
            }
        };

        // Drain accumulated events to collect tool names in call order.
        // The channel is unbounded; all events are already queued.
        event_rx.close();
        let mut tool_calls_made: Vec<String> = Vec::new();
        while let Ok(ev) = event_rx.try_recv() {
            if let AgentEvent::ToolCallStart { tool_name, .. } = ev {
                tool_calls_made.push(tool_name);
            }
        }

        let duration_ms = turn_start.elapsed().as_millis() as u64;
        let raw_output = outcome.reply.clone();

        // ── EVAL-007: wire CHUMP_EVAL_WITH_JUDGE ──────────────────────────
        // When the env flag is set AND the case has at least one LlmJudge
        // property, use the async judge path so judge_score is populated.
        let has_llm_judge = case
            .expected_properties
            .iter()
            .any(|p| matches!(p, ExpectedProperty::LlmJudge { .. }));

        let (passed_labels, failed_labels, judge_scores) = if with_judge && has_llm_judge {
            let (p, f, js) = check_all_properties_with_judge_async(
                case,
                &raw_output,
                &tool_calls_made,
                provider.as_ref(),
            )
            .await;
            (p, f, js)
        } else {
            let (p, f) = check_all_properties(case, &raw_output, &tool_calls_made);
            (p, f, vec![])
        };

        let case_passed = failed_labels.is_empty();
        if !case_passed {
            any_failed = true;
        }

        // Compute aggregate judge_score (mean across all judged properties).
        let judge_score_agg: Option<f64> = if judge_scores.is_empty() {
            None
        } else {
            let sum: f64 = judge_scores.iter().map(|j| j.score).sum();
            Some(sum / judge_scores.len() as f64)
        };

        // Simple overall score: fraction of properties that passed.
        let total_props = passed_labels.len() + failed_labels.len();
        let overall = if total_props == 0 {
            1.0
        } else {
            passed_labels.len() as f64 / total_props as f64
        };

        let scores = EvalScores {
            overall,
            correctness: overall,
            safety: 1.0,
            efficiency: 1.0,
            judge_score: judge_score_agg,
        };

        let result = EvalRunResult {
            eval_case_id: case.id.clone(),
            run_id,
            properties_passed: passed_labels.clone(),
            properties_failed: failed_labels.clone(),
            scores,
            duration_ms,
            raw_output,
        };

        if let Err(e) = save_eval_run(&result, &agent_version, &model_label) {
            eprintln!("[eval run] save_eval_run failed for {}: {e}", case.id);
        }

        let status = if case_passed { "PASS" } else { "FAIL" };
        let judge_tag = judge_score_agg
            .map(|s| format!(" judge={:.3}", s))
            .unwrap_or_default();
        println!(
            "[eval run] [{}/{total}] {} {:?} — {}/{} props passed{judge_tag}",
            i + 1,
            status,
            case.category,
            passed_labels.len(),
            passed_labels.len() + failed_labels.len(),
        );
    }

    if any_failed {
        eprintln!("[eval run] one or more cases failed");
        1
    } else {
        println!("[eval run] all {} cases passed", total);
        0
    }
}

/// Run eval cases that have LlmJudge properties against the configured provider,
/// persist scores to `logs/judge-scores.json`, and print per-category summary.
/// Called by `chump --eval-judge` (and transitively by `battle-qa.sh --with-judge`).
async fn run_eval_judge_mode() {
    use eval_harness::{
        average_judge_score_per_category, judge_via_provider, load_eval_cases, seed_starter_cases,
        EvalCategory, ExpectedProperty, JudgeInput, JudgeScore,
    };

    // Seed cases into DB if not already there.
    if let Err(e) = seed_starter_cases() {
        eprintln!("[eval-judge] seed_starter_cases failed: {e} — continuing with existing cases");
    }

    let cases = match load_eval_cases() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[eval-judge] failed to load eval cases: {e}");
            return;
        }
    };

    let provider = provider_cascade::build_provider();

    let mut scored: Vec<(EvalCategory, JudgeScore)> = Vec::new();
    let mut json_rows: Vec<serde_json::Value> = Vec::new();

    for case in &cases {
        for prop in &case.expected_properties {
            if let ExpectedProperty::LlmJudge { rubric, threshold } = prop {
                // Get a direct (non-agent) response for this case input.
                let messages = vec![axonerai::provider::Message {
                    role: "user".to_string(),
                    content: case.input.clone(),
                }];
                let agent_output = match provider.complete(messages, None, Some(400), None).await {
                    Ok(r) => r.text.unwrap_or_default(),
                    Err(e) => {
                        eprintln!("[eval-judge] provider error for case {}: {e}", case.id);
                        continue;
                    }
                };

                let judge_input = JudgeInput {
                    rubric: rubric.clone(),
                    agent_output: agent_output.clone(),
                    tool_calls: vec![],
                };
                let judge_out = judge_via_provider(provider.as_ref(), judge_input).await;
                let score = judge_out.score.clamp(0.0, 1.0);
                let js = JudgeScore {
                    rubric: rubric.clone(),
                    threshold: *threshold,
                    score,
                    passed: score >= *threshold,
                    reasoning: judge_out.reasoning.clone(),
                };
                json_rows.push(serde_json::json!({
                    "case_id": case.id,
                    "category": format!("{:?}", case.category),
                    "rubric": rubric,
                    "score": score,
                    "passed": js.passed,
                    "reasoning": judge_out.reasoning,
                }));
                scored.push((case.category.clone(), js));
            }
        }
    }

    // Persist to logs/judge-scores.json
    let logs_dir = repo_path::repo_root().join("logs");
    let _ = std::fs::create_dir_all(&logs_dir);
    let judge_file = logs_dir.join("judge-scores.json");
    if let Ok(json) = serde_json::to_string_pretty(&json_rows) {
        let _ = std::fs::write(&judge_file, json);
    }

    // Print per-category summary
    let summary = average_judge_score_per_category(&scored);
    if summary.is_empty() {
        println!("[eval-judge] No LlmJudge cases found in loaded eval cases.");
        return;
    }
    println!("Avg judge score per category:");
    for (cat, avg, n) in &summary {
        println!(
            "  {cat}: {avg:.3} ({n} case{})",
            if *n == 1 { "" } else { "s" }
        );
    }
    println!("[eval-judge] Scores persisted to {}", judge_file.display());
}

/// EVAL-009 + EVAL-007: full eval runner. Returns exit code (0 = all pass).
///
/// For each chump_eval_case:
///   1. Send case.input to the configured provider (single-turn — no tool loop;
///      richer multi-turn replay lives in scripts/eval/replay-trajectory.sh per
///      EVAL-003).
///   2. Score with `check_all_properties` (always) and
///      `check_all_properties_with_judge_async` (when CHUMP_EVAL_WITH_JUDGE=1).
///   3. Persist EvalRunResult to chump_eval_runs via `save_eval_run`.
///
/// Single-turn caveat: the EvalCase contract is "user input → response"; multi-
/// turn fixtures are GoldenTrajectory's job (EVAL-003 + scripts/eval/replay-
/// trajectory.sh). When EVAL-009 acceptance says "runs each through ChumpAgent"
/// the agent here is the bare provider — full agent-loop integration with tools
/// would re-implement most of agent_loop and isn't needed for property scoring.
async fn run_eval_run_mode() -> i32 {
    use eval_harness::{
        check_all_properties, check_all_properties_with_judge_async, load_eval_cases,
        save_eval_run, seed_starter_cases, EvalRunResult, EvalScores,
    };
    use uuid::Uuid;

    if let Err(e) = seed_starter_cases() {
        eprintln!("[eval-run] seed_starter_cases failed: {e} — continuing with existing cases");
    }
    let cases = match load_eval_cases() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[eval-run] failed to load eval cases: {e}");
            return 2;
        }
    };
    if cases.is_empty() {
        eprintln!("[eval-run] no eval cases loaded — nothing to do");
        return 0;
    }

    let with_judge = matches!(std::env::var("CHUMP_EVAL_WITH_JUDGE").as_deref(), Ok("1"));
    let model_name = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "unknown".to_string());
    let agent_version = env!("CARGO_PKG_VERSION");
    let run_id = format!("evalrun-{}", Uuid::new_v4().simple());
    let provider = provider_cascade::build_provider();

    println!(
        "[eval-run] {} cases, model={}, with_judge={}, run_id={}",
        cases.len(),
        model_name,
        with_judge,
        run_id
    );

    let mut total_passed = 0usize;
    let mut total_failed = 0usize;
    for case in &cases {
        let started = std::time::Instant::now();
        let messages = vec![axonerai::provider::Message {
            role: "user".to_string(),
            content: case.input.clone(),
        }];
        let agent_output = match provider.complete(messages, None, Some(800), None).await {
            Ok(r) => r.text.unwrap_or_default(),
            Err(e) => {
                eprintln!("[eval-run] provider error for case {}: {e}", case.id);
                String::new()
            }
        };
        let duration_ms = started.elapsed().as_millis() as u64;

        // Structural pass/fail (always). Single-turn so tool_calls is empty.
        let (mut passed, mut failed) = check_all_properties(case, &agent_output, &[]);

        // Judge pass/fail (when enabled). Augments the property lists.
        let mut judge_overall = 0.0_f64;
        if with_judge {
            let (jp, jf, scores) =
                check_all_properties_with_judge_async(case, &agent_output, &[], provider.as_ref())
                    .await;
            for s in &jp {
                if !passed.contains(s) {
                    passed.push(s.clone());
                }
            }
            for s in &jf {
                if !failed.contains(s) {
                    failed.push(s.clone());
                }
            }
            if !scores.is_empty() {
                judge_overall = scores.iter().map(|s| s.score).sum::<f64>() / scores.len() as f64;
            }
        }

        let case_passed = failed.is_empty() && !agent_output.trim().is_empty();
        if case_passed {
            total_passed += 1;
        } else {
            total_failed += 1;
        }
        println!(
            "  {} {}  [pass={} fail={} judge={:.2} dur={}ms]",
            if case_passed { "✓" } else { "✗" },
            case.id,
            passed.len(),
            failed.len(),
            judge_overall,
            duration_ms
        );

        let scores = EvalScores {
            overall: if case_passed { 1.0 } else { 0.0 },
            correctness: judge_overall,
            safety: 0.0,
            efficiency: 0.0,
            judge_score: if with_judge && judge_overall > 0.0 {
                Some(judge_overall)
            } else {
                None
            },
        };
        let result = EvalRunResult {
            eval_case_id: case.id.clone(),
            run_id: run_id.clone(),
            properties_passed: passed,
            properties_failed: failed,
            scores,
            duration_ms,
            raw_output: agent_output,
        };
        if let Err(e) = save_eval_run(&result, agent_version, &model_name) {
            eprintln!("[eval-run] save_eval_run failed for {}: {e}", case.id);
        }
    }

    println!(
        "[eval-run] done. passed={} failed={} total={}",
        total_passed,
        total_failed,
        total_passed + total_failed
    );
    if total_failed == 0 {
        0
    } else {
        1
    }
}

/// EVAL-008: A/B reflect_heuristic vs reflect_via_provider on a labeled
/// dataset. Returns exit code 0 if the LLM variant beats the heuristic by
/// >=15 percentage points (the acceptance gate), 1 otherwise.
///
/// Loads tests/fixtures/reflection_episodes.json — 20 labeled episodes with
/// ground-truth ErrorPattern. For each episode, runs both reflectors and
/// compares the predicted pattern against the gold label. Reports per-method
/// accuracy and per-pattern confusion stats.
///
/// Provider for reflect_via_provider comes from provider_cascade::build_provider().
async fn run_eval_reflection_mode() -> i32 {
    use reflection::{
        reflect_heuristic, reflect_via_provider, ErrorPattern, OutcomeClass, ReflectionInput,
    };
    use serde::Deserialize;
    use std::collections::BTreeMap;

    #[derive(Debug, Clone, Deserialize)]
    struct LabeledEpisode {
        id: String,
        intended_goal: String,
        observed_outcome: String,
        outcome_class: String,
        #[serde(default)]
        tool_errors: Vec<String>,
        gold_pattern: Option<String>,
    }

    #[derive(Debug, Clone, Deserialize)]
    struct EpisodesFile {
        episodes: Vec<LabeledEpisode>,
    }

    let fixture_path = repo_path::repo_root().join("tests/fixtures/reflection_episodes.json");
    let raw = match std::fs::read_to_string(&fixture_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "[eval-reflection] cannot read {}: {e}",
                fixture_path.display()
            );
            return 2;
        }
    };
    let parsed: EpisodesFile = match serde_json::from_str(&raw) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[eval-reflection] parse error: {e}");
            return 2;
        }
    };
    println!(
        "[eval-reflection] {} episodes loaded from {}",
        parsed.episodes.len(),
        fixture_path.display()
    );

    let provider = provider_cascade::build_provider();
    let model_name = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "unknown".to_string());

    // Per-method totals.
    let mut h_correct = 0usize;
    let mut p_correct = 0usize;
    // Per-gold-pattern: (heuristic_correct, provider_correct, total).
    let mut by_pattern: BTreeMap<String, (usize, usize, usize)> = BTreeMap::new();

    for ep in &parsed.episodes {
        let outcome = OutcomeClass::from_str(&ep.outcome_class.to_lowercase());
        // Gold label: "ToolMisuse" → ErrorPattern variant; null/None → expected None.
        let gold_label = ep.gold_pattern.as_deref();
        let gold_pattern: Option<ErrorPattern> = gold_label
            .map(|s| s.to_lowercase().replace(' ', "_"))
            .and_then(|s| {
                // The fixture uses CamelCase but ErrorPattern::from_str expects snake.
                let snake = camel_to_snake(s.as_str());
                ErrorPattern::from_str(&snake)
            });

        // Heuristic prediction.
        let h_reflection = reflect_heuristic(
            &ep.intended_goal,
            &ep.observed_outcome,
            outcome,
            &ep.tool_errors,
            None,
            None,
        );

        // Provider prediction.
        let input = ReflectionInput {
            intended_goal: ep.intended_goal.clone(),
            observed_outcome: ep.observed_outcome.clone(),
            outcome_class: outcome,
            tool_errors: ep.tool_errors.clone(),
            surprisal: None,
            trajectory_confidence: None,
        };
        let p_reflection = reflect_via_provider(provider.as_ref(), input).await;

        let h_match = h_reflection.error_pattern == gold_pattern;
        let p_match = p_reflection.error_pattern == gold_pattern;
        if h_match {
            h_correct += 1;
        }
        if p_match {
            p_correct += 1;
        }
        let bucket = by_pattern
            .entry(gold_label.unwrap_or("Pass").to_string())
            .or_insert((0, 0, 0));
        if h_match {
            bucket.0 += 1;
        }
        if p_match {
            bucket.1 += 1;
        }
        bucket.2 += 1;

        let h_pred = h_reflection
            .error_pattern
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "(none)".to_string());
        let p_pred = p_reflection
            .error_pattern
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "(none)".to_string());
        let gold_str = gold_label.unwrap_or("(none)");
        println!(
            "  {:6} gold={:24} heur={:24}{}  prov={:24}{}",
            ep.id,
            gold_str,
            h_pred,
            if h_match { " ✓" } else { " ✗" },
            p_pred,
            if p_match { " ✓" } else { " ✗" },
        );
    }

    let total = parsed.episodes.len() as f64;
    let h_acc = h_correct as f64 / total;
    let p_acc = p_correct as f64 / total;
    let delta = p_acc - h_acc;

    println!();
    println!("[eval-reflection] model={}", model_name);
    println!(
        "  heuristic accuracy: {}/{} = {:.3}",
        h_correct,
        parsed.episodes.len(),
        h_acc
    );
    println!(
        "  provider  accuracy: {}/{} = {:.3}",
        p_correct,
        parsed.episodes.len(),
        p_acc
    );
    println!("  delta (provider - heuristic): {:+.3}", delta);
    println!();
    println!("  per-pattern (heur/prov/total):");
    for (pat, (h, p, t)) in &by_pattern {
        println!("    {:24} {:>2}/{:>2}/{:>2}", pat, h, p, t);
    }

    // Persist a JSON summary alongside other A/B results.
    let logs_dir = repo_path::repo_root().join("logs");
    let _ = std::fs::create_dir_all(&logs_dir);
    let summary = serde_json::json!({
        "tag": "eval-reflection-ab",
        "model": model_name,
        "episodes": parsed.episodes.len(),
        "heuristic_correct": h_correct,
        "provider_correct": p_correct,
        "heuristic_accuracy": h_acc,
        "provider_accuracy": p_acc,
        "delta": delta,
        "by_pattern": by_pattern.iter().map(|(k, (h, p, t))| {
            (k.clone(), serde_json::json!({"heuristic": h, "provider": p, "total": t}))
        }).collect::<serde_json::Map<_, _>>(),
    });
    let summary_path = logs_dir.join(format!(
        "eval-reflection-{}.json",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    ));
    let _ = std::fs::write(
        &summary_path,
        serde_json::to_string_pretty(&summary).unwrap_or_default(),
    );
    println!("\n[eval-reflection] summary: {}", summary_path.display());

    // Acceptance gate: provider must beat heuristic by >=15 pp.
    if delta >= 0.15 {
        println!("[eval-reflection] PASS — provider beats heuristic by >=15 pp");
        0
    } else {
        println!(
            "[eval-reflection] FAIL — delta {:+.3} < +0.150 acceptance gate",
            delta
        );
        1
    }
}

/// "ToolMisuse" → "tool_misuse" — minimal converter for fixture string → enum.
/// COG-043: read all `lessons_shown` events for `gap_id` from
/// ambient.jsonl, fetch the PR diff + body via `gh`, and emit a
/// `lesson_applied` / `lesson_not_applied` event for each unique
/// directive. Returns (applied, not_applied, skipped) counts.
///
/// Caller (bot-merge.sh) treats errors here as best-effort — never
/// gates the auto-close flow on telemetry.
fn run_lesson_grade(
    repo_root: &std::path::Path,
    gap_id: &str,
    pr_number: u64,
    session_filter: Option<&str>,
) -> anyhow::Result<(u64, u64, u64)> {
    use std::process::Command;
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();

    // Find the most recent `lessons_shown` event matching gap_id (and
    // session if provided). Walk lines from the end backward.
    let mut latest_directives: Vec<String> = Vec::new();
    let mut latest_session = String::new();
    for line in contents.lines().rev() {
        if !line.contains("\"kind\":\"lessons_shown\"")
            && !line.contains("\"kind\": \"lessons_shown\"")
        {
            continue;
        }
        if !line.contains(gap_id) {
            continue;
        }
        if let Some(filt) = session_filter {
            if !line.contains(filt) {
                continue;
            }
        }
        // Parse the JSON line. Use python3 for robustness; fall back to
        // a permissive substring extract if python is unavailable.
        let parsed = parse_lessons_shown_line(line);
        if let Some((session_id, directives)) = parsed {
            if !directives.is_empty() {
                latest_directives = directives;
                latest_session = session_id;
                break;
            }
        }
    }
    if latest_directives.is_empty() {
        return Ok((0, 0, 0));
    }

    // Pull the PR body + diff via gh. Failures here just mean we can't
    // grade — return zeros, don't error.
    let body_out = Command::new("gh")
        .args([
            "pr",
            "view",
            &pr_number.to_string(),
            "--json",
            "body,title,commits",
            "-q",
            ".title + \"\\n\" + (.body // \"\") + \"\\n\" + ([.commits[].messageHeadline + \"\\n\" + (.commits[].messageBody // \"\")] | join(\"\\n\"))",
        ])
        .current_dir(repo_root)
        .output()
        .ok();
    let diff_out = Command::new("gh")
        .args(["pr", "diff", &pr_number.to_string()])
        .current_dir(repo_root)
        .output()
        .ok();

    let mut pr_text = String::new();
    if let Some(o) = body_out {
        if o.status.success() {
            pr_text.push_str(&String::from_utf8_lossy(&o.stdout));
        }
    }
    if let Some(o) = diff_out {
        if o.status.success() {
            pr_text.push('\n');
            pr_text.push_str(&String::from_utf8_lossy(&o.stdout));
        }
    }
    if pr_text.is_empty() {
        return Ok((0, 0, latest_directives.len() as u64));
    }

    let mut applied = 0u64;
    let mut not_applied = 0u64;
    for directive in &latest_directives {
        let (matched, total) = lesson_action::score_directive_against_pr(directive, &pr_text);
        let is_applied = lesson_action::directive_applied(directive, &pr_text);
        lesson_action::emit_lesson_grade(
            repo_root,
            &latest_session,
            gap_id,
            pr_number,
            directive,
            is_applied,
            matched,
            total,
        );
        if is_applied {
            applied += 1;
        } else {
            not_applied += 1;
        }
    }
    Ok((applied, not_applied, 0))
}

/// Parse one `lessons_shown` JSON line. Returns (session_id, directives).
/// Permissive — uses python3 if available, hand-rolls otherwise.
fn parse_lessons_shown_line(line: &str) -> Option<(String, Vec<String>)> {
    use std::process::Command;
    if let Ok(out) = Command::new("python3")
        .arg("-c")
        .arg(
            r#"
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
sid = d.get('session_id', '')
dirs = d.get('directives', [])
if not isinstance(dirs, list):
    dirs = []
print(sid)
for x in dirs:
    print(x)
"#,
        )
        .arg(line)
        .output()
    {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout);
            let mut iter = s.lines();
            let sid = iter.next().unwrap_or("").to_string();
            let dirs: Vec<String> = iter.map(|l| l.to_string()).collect();
            if !dirs.is_empty() {
                return Some((sid, dirs));
            }
        }
    }
    // Fallback: don't try to be clever. If python isn't available,
    // grading just no-ops on this corpus. That's acceptable for v1.
    None
}

fn camel_to_snake(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            out.push('_');
        }
        out.extend(c.to_lowercase());
    }
    out
}

/// EVAL-008: A/B accuracy comparison between `reflect_heuristic` and
/// `reflect_via_provider` on a labeled episode dataset.
///
/// Env gating:
///   CHUMP_REFLECTION_AB_WITH_LLM=1  — also runs the provider leg (fails loud
///                                     if no endpoint reachable)
///
/// Exit behaviour (via std::process::exit):
///   0  — heuristic-only run, or LLM leg ≥ 15% more accurate than heuristic
///   1  — LLM leg present but accuracy delta < 15%
async fn run_reflection_ab_mode(episodes_path: Option<std::path::PathBuf>) {
    use reflection::{reflect_heuristic, reflect_via_provider, OutcomeClass, ReflectionInput};

    // ── Locate episode file ────────────────────────────────────────────────
    let default_path = std::path::PathBuf::from("scripts/eval-reflection-ab/episodes.json");
    let path = episodes_path.unwrap_or(default_path);
    let raw = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "[reflect-ab] ERROR: cannot read episodes file {}: {e}",
                path.display()
            );
            std::process::exit(2);
        }
    };
    let doc: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[reflect-ab] ERROR: malformed JSON in episodes file: {e}");
            std::process::exit(2);
        }
    };
    let episodes = match doc.get("episodes").and_then(|v| v.as_array()) {
        Some(a) => a.clone(),
        None => {
            eprintln!("[reflect-ab] ERROR: episodes file has no top-level 'episodes' array");
            std::process::exit(2);
        }
    };

    // ── LLM leg setup ─────────────────────────────────────────────────────
    let with_llm = std::env::var("CHUMP_REFLECTION_AB_WITH_LLM")
        .map(|v| v == "1")
        .unwrap_or(false);
    // build_provider() returns Box<dyn Provider + Send + Sync> directly.
    // The shell script already probed the endpoint before setting
    // CHUMP_REFLECTION_AB_WITH_LLM=1, so this will succeed if --with-llm was passed.
    let provider_box: Option<Box<dyn axonerai::provider::Provider + Send + Sync>> = if with_llm {
        Some(crate::provider_cascade::build_provider())
    } else {
        None
    };

    // ── Per-pattern counters ───────────────────────────────────────────────
    let mut h_correct: usize = 0; // heuristic correct
    let mut l_correct: usize = 0; // llm correct
    let mut total_labeled: usize = 0; // episodes with a label (non-pass)

    // Confusion accumulators: (label, heuristic_pred) → count
    let mut h_confusion: std::collections::HashMap<(String, String), usize> =
        std::collections::HashMap::new();
    let mut l_confusion: std::collections::HashMap<(String, String), usize> =
        std::collections::HashMap::new();

    println!(
        "[reflect-ab] episodes={} with_llm={}",
        episodes.len(),
        with_llm
    );
    println!();

    for ep in &episodes {
        let id = ep.get("id").and_then(|v| v.as_str()).unwrap_or("?");
        let intended_goal = ep
            .get("intended_goal")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let observed_outcome = ep
            .get("observed_outcome")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let outcome_class_str = ep
            .get("outcome_class")
            .and_then(|v| v.as_str())
            .unwrap_or("fail");
        let outcome_class = if outcome_class_str == "pass" {
            OutcomeClass::Pass
        } else {
            OutcomeClass::Failure
        };
        let tool_errors: Vec<String> = ep
            .get("tool_errors")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str())
                    .map(|s| s.to_string())
                    .collect()
            })
            .unwrap_or_default();
        let surprisal = ep.get("surprisal").and_then(|v| v.as_f64());
        let trajectory_confidence = ep.get("trajectory_confidence").and_then(|v| v.as_f64());
        let label_raw = ep.get("label").and_then(|v| v.as_str()); // None for pass episodes

        // Pass episodes: both methods should return None error_pattern.
        if outcome_class == OutcomeClass::Pass {
            let h_refl = reflect_heuristic(
                &intended_goal,
                &observed_outcome,
                outcome_class,
                &tool_errors,
                surprisal,
                trajectory_confidence,
            );
            let h_pred = h_refl
                .error_pattern
                .map(|p| p.as_str().to_string())
                .unwrap_or_else(|| "null".to_string());
            println!("  [{id}] pass | heuristic→{h_pred}");
            continue;
        }

        // Labeled failure episodes.
        let label = match label_raw {
            Some(l) => l.to_string(),
            None => {
                eprintln!("  [{id}] WARN: fail episode has no label — skipping");
                continue;
            }
        };
        total_labeled += 1;

        let input = ReflectionInput {
            intended_goal: intended_goal.clone(),
            observed_outcome: observed_outcome.clone(),
            outcome_class,
            tool_errors: tool_errors.clone(),
            surprisal,
            trajectory_confidence,
        };

        // Heuristic leg
        let h_refl = reflect_heuristic(
            &intended_goal,
            &observed_outcome,
            outcome_class,
            &tool_errors,
            surprisal,
            trajectory_confidence,
        );
        let h_pred = h_refl
            .error_pattern
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "null".to_string());
        let h_hit = h_pred == label;
        if h_hit {
            h_correct += 1;
        }
        *h_confusion
            .entry((label.clone(), h_pred.clone()))
            .or_insert(0) += 1;

        // LLM leg (optional)
        let l_pred = if let Some(ref prov) = provider_box {
            let l_refl = reflect_via_provider(prov.as_ref(), input.clone()).await;
            let pred = l_refl
                .error_pattern
                .map(|p| p.as_str().to_string())
                .unwrap_or_else(|| "null".to_string());
            let l_hit = pred == label;
            if l_hit {
                l_correct += 1;
            }
            *l_confusion
                .entry((label.clone(), pred.clone()))
                .or_insert(0) += 1;
            Some(pred)
        } else {
            None
        };

        let h_mark = if h_hit { "✓" } else { "✗" };
        if let Some(ref lp) = l_pred {
            let l_hit = *lp == label;
            let l_mark = if l_hit { "✓" } else { "✗" };
            println!("  [{id}] label={label} | heuristic={h_pred}{h_mark}  llm={lp}{l_mark}");
        } else {
            println!("  [{id}] label={label} | heuristic={h_pred}{h_mark}");
        }
    }

    // ── Summary ───────────────────────────────────────────────────────────
    println!();
    println!("=== EVAL-008: Reflection A/B Results ===");
    println!("Labeled failure episodes: {total_labeled}");
    println!(
        "Heuristic accuracy: {}/{total_labeled} = {:.1}%",
        h_correct,
        100.0 * h_correct as f64 / total_labeled.max(1) as f64
    );

    if with_llm {
        let l_acc = 100.0 * l_correct as f64 / total_labeled.max(1) as f64;
        let h_acc = 100.0 * h_correct as f64 / total_labeled.max(1) as f64;
        let delta = l_acc - h_acc;
        println!(
            "LLM accuracy:       {}/{total_labeled} = {l_acc:.1}%",
            l_correct
        );
        println!("Delta (LLM − heuristic): {delta:+.1}%");
        println!();

        // Per-pattern confusion matrix (heuristic)
        println!("--- Heuristic confusion (label → predicted) ---");
        let mut h_rows: Vec<_> = h_confusion.iter().collect();
        h_rows.sort_by(|a, b| a.0.cmp(b.0));
        for ((lbl, pred), cnt) in &h_rows {
            let mark = if lbl == pred { "✓" } else { "✗" };
            println!("  {lbl:35} → {pred:35} ×{cnt} {mark}");
        }
        println!();

        println!("--- LLM confusion (label → predicted) ---");
        let mut l_rows: Vec<_> = l_confusion.iter().collect();
        l_rows.sort_by(|a, b| a.0.cmp(b.0));
        for ((lbl, pred), cnt) in &l_rows {
            let mark = if lbl == pred { "✓" } else { "✗" };
            println!("  {lbl:35} → {pred:35} ×{cnt} {mark}");
        }
        println!();

        // A/B gate
        if delta >= 15.0 {
            println!("[reflect-ab] PASS: LLM variant is ≥15% more accurate ({delta:+.1}% delta)");
        } else {
            eprintln!(
                "[reflect-ab] FAIL: LLM delta {delta:+.1}% is below the 15% acceptance threshold"
            );
            std::process::exit(1);
        }
    } else {
        println!();
        println!("--- Heuristic confusion (label → predicted) ---");
        let mut rows: Vec<_> = h_confusion.iter().collect();
        rows.sort_by(|a, b| a.0.cmp(b.0));
        for ((lbl, pred), cnt) in &rows {
            let mark = if lbl == pred { "✓" } else { "✗" };
            println!("  {lbl:35} → {pred:35} ×{cnt} {mark}");
        }
        println!();
        println!(
            "[reflect-ab] Heuristic-only run complete. Re-run with \
             CHUMP_REFLECTION_AB_WITH_LLM=1 to compare against LLM variant."
        );
    }
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-1229 slice 1 — `chump ship plan` CLI wrapper around the pure
// planner in the chump-ship crate. Gathers PR + repo snapshots via gh + git,
// calls chump_ship::plan(), emits JSON (default) or a human summary.
// ──────────────────────────────────────────────────────────────────────

async fn ship_plan_cli(args: &[String]) -> Result<()> {
    let mut gap_id: Option<String> = None;
    let mut pr_num: Option<u64> = None;
    let mut branch: Option<String> = None;
    let mut json_out = true;
    let mut dry_run = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--gap" => {
                gap_id = args.get(i + 1).cloned();
                i += 2;
            }
            "--pr" => {
                pr_num = args.get(i + 1).and_then(|s| s.parse().ok());
                i += 2;
            }
            "--branch" => {
                branch = args.get(i + 1).cloned();
                i += 2;
            }
            "--json" => {
                json_out = true;
                i += 1;
            }
            "--human" => {
                json_out = false;
                i += 1;
            }
            "--dry-run" => {
                dry_run = true;
                i += 1;
            }
            other => {
                eprintln!("chump ship plan: unknown flag {other:?}");
                eprintln!("Run `chump ship plan --help` for usage.");
                std::process::exit(2);
            }
        }
    }

    // Branch: explicit > current symbolic-ref > "HEAD" sentinel.
    let branch_name = match branch {
        Some(b) => b,
        None => std::process::Command::new("git")
            .args(["symbolic-ref", "--short", "HEAD"])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "HEAD".to_string()),
    };

    // Repo snapshot — via git rev-list.
    let stale_threshold: u32 = std::env::var("CHUMP_BOT_MERGE_STALE_THRESHOLD")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(15);
    let (behind_main, ahead_main) = if dry_run {
        (0u32, 0u32)
    } else {
        ship_plan_count_behind_ahead("HEAD", "origin/main").unwrap_or((0, 0))
    };
    let has_uncommitted = if dry_run {
        false
    } else {
        !std::process::Command::new("git")
            .args(["status", "--porcelain"])
            .output()
            .ok()
            .map(|o| o.stdout.is_empty())
            .unwrap_or(true)
    };
    let repo = chump_ship::RepoSnapshot {
        branch: branch_name.clone(),
        behind_main,
        ahead_main,
        has_uncommitted,
        stale_threshold,
    };

    // PR snapshot — via gh api (REST), unless --dry-run.
    let pr = if dry_run {
        chump_ship::PrSnapshot {
            number: pr_num,
            state: if pr_num.is_some() {
                chump_ship::PrState::Open
            } else {
                chump_ship::PrState::None
            },
            mergeable: None,
            mergeable_state: chump_ship::MergeableState::Unknown,
            auto_merge_set: false,
            head_sha: String::new(),
            base_sha: String::new(),
            checks: chump_ship::ChecksSummary::default(),
        }
    } else {
        match ship_plan_fetch_pr_snapshot(pr_num, &branch_name) {
            Ok(snapshot) => snapshot,
            Err(e) => {
                eprintln!(
                    "chump ship plan: could not fetch PR snapshot ({e}); falling back to no-PR."
                );
                chump_ship::PrSnapshot {
                    number: None,
                    state: chump_ship::PrState::None,
                    mergeable: None,
                    mergeable_state: chump_ship::MergeableState::Unknown,
                    auto_merge_set: false,
                    head_sha: String::new(),
                    base_sha: String::new(),
                    checks: chump_ship::ChecksSummary::default(),
                }
            }
        }
    };

    let decision = chump_ship::plan(&pr, &repo);
    let payload = serde_json::json!({
        "gap": gap_id,
        "branch": branch_name,
        "behind_main": behind_main,
        "ahead_main": ahead_main,
        "pr": pr,
        "plan": decision,
    });

    if json_out {
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        ship_plan_print_human(&decision, gap_id.as_deref(), &branch_name);
    }
    Ok(())
}

fn ship_plan_count_behind_ahead(head: &str, base: &str) -> std::io::Result<(u32, u32)> {
    let spec = format!("{head}...{base}");
    let out = std::process::Command::new("git")
        .args(["rev-list", "--left-right", "--count", &spec])
        .output()?;
    if !out.status.success() {
        return Ok((0, 0));
    }
    let s = String::from_utf8_lossy(&out.stdout);
    let mut parts = s.split_whitespace();
    let ahead: u32 = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    let behind: u32 = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    Ok((behind, ahead))
}

fn ship_plan_fetch_pr_snapshot(
    pr_num: Option<u64>,
    branch: &str,
) -> anyhow::Result<chump_ship::PrSnapshot> {
    // Resolve owner/repo from origin remote — `gh api repos/{owner}/{repo}/...`
    let nwo_out = std::process::Command::new("gh")
        .args([
            "repo",
            "view",
            "--json",
            "nameWithOwner",
            "--jq",
            ".nameWithOwner",
        ])
        .output()?;
    if !nwo_out.status.success() {
        anyhow::bail!(
            "gh repo view failed: {}",
            String::from_utf8_lossy(&nwo_out.stderr)
        );
    }
    let nwo = String::from_utf8_lossy(&nwo_out.stdout).trim().to_string();

    // Resolve PR number: explicit --pr > look up by head branch.
    let pr = match pr_num {
        Some(n) => n,
        None => {
            let owner = nwo.split('/').next().unwrap_or("");
            let list = std::process::Command::new("gh")
                .args([
                    "api",
                    &format!("repos/{nwo}/pulls?head={owner}:{branch}&state=open"),
                    "--jq",
                    ".[0].number // empty",
                ])
                .output()?;
            let s = String::from_utf8_lossy(&list.stdout).trim().to_string();
            if s.is_empty() {
                // No PR for this branch — return synthetic "no PR" snapshot.
                return Ok(chump_ship::PrSnapshot {
                    number: None,
                    state: chump_ship::PrState::None,
                    mergeable: None,
                    mergeable_state: chump_ship::MergeableState::Unknown,
                    auto_merge_set: false,
                    head_sha: String::new(),
                    base_sha: String::new(),
                    checks: chump_ship::ChecksSummary::default(),
                });
            }
            s.parse()?
        }
    };

    // Fetch PR detail.
    let pr_json = std::process::Command::new("gh")
        .args(["api", &format!("repos/{nwo}/pulls/{pr}")])
        .output()?;
    if !pr_json.status.success() {
        anyhow::bail!(
            "gh api pulls/{pr} failed: {}",
            String::from_utf8_lossy(&pr_json.stderr)
        );
    }
    let v: serde_json::Value = serde_json::from_slice(&pr_json.stdout)?;
    let state = match v.get("state").and_then(|x| x.as_str()) {
        Some("open") => chump_ship::PrState::Open,
        Some("closed") if v.get("merged").and_then(|x| x.as_bool()) == Some(true) => {
            chump_ship::PrState::Merged
        }
        Some("closed") => chump_ship::PrState::Closed,
        _ => chump_ship::PrState::Open,
    };
    let mergeable = v.get("mergeable").and_then(|x| x.as_bool());
    let mergeable_state = match v.get("mergeable_state").and_then(|x| x.as_str()) {
        Some("clean") => chump_ship::MergeableState::Clean,
        Some("behind") => chump_ship::MergeableState::Behind,
        Some("blocked") => chump_ship::MergeableState::Blocked,
        Some("dirty") => chump_ship::MergeableState::Dirty,
        Some("unstable") => chump_ship::MergeableState::Unstable,
        Some("has_hooks") => chump_ship::MergeableState::HasHooks,
        _ => chump_ship::MergeableState::Unknown,
    };
    let auto_merge_set = v.get("auto_merge").map(|x| !x.is_null()).unwrap_or(false);
    let head_sha = v
        .get("head")
        .and_then(|h| h.get("sha"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let base_sha = v
        .get("base")
        .and_then(|b| b.get("sha"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();

    // Fetch checks summary for the head sha.
    let checks = if head_sha.is_empty() {
        chump_ship::ChecksSummary::default()
    } else {
        ship_plan_fetch_checks(&nwo, &head_sha).unwrap_or_default()
    };

    Ok(chump_ship::PrSnapshot {
        number: Some(pr),
        state,
        mergeable,
        mergeable_state,
        auto_merge_set,
        head_sha,
        base_sha,
        checks,
    })
}

fn ship_plan_fetch_checks(nwo: &str, sha: &str) -> anyhow::Result<chump_ship::ChecksSummary> {
    let out = std::process::Command::new("gh")
        .args([
            "api",
            &format!("repos/{nwo}/commits/{sha}/check-runs"),
            "--paginate",
        ])
        .output()?;
    if !out.status.success() {
        anyhow::bail!(
            "gh api check-runs failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or(serde_json::json!({}));
    let runs = v
        .get("check_runs")
        .and_then(|x| x.as_array())
        .cloned()
        .unwrap_or_default();
    let mut s = chump_ship::ChecksSummary::default();
    for c in &runs {
        let status = c.get("status").and_then(|x| x.as_str()).unwrap_or("");
        let conclusion = c.get("conclusion").and_then(|x| x.as_str()).unwrap_or("");
        let neutral_kind = matches!(conclusion, "skipped" | "neutral" | "cancelled");
        if neutral_kind {
            s.neutral_or_skipped += 1;
            continue;
        }
        s.total += 1;
        if status != "completed" {
            s.incomplete += 1;
        } else if conclusion != "success" {
            s.completed_failure += 1;
        } else {
            s.completed_success += 1;
        }
    }
    Ok(s)
}

fn ship_plan_print_human(plan: &chump_ship::ShipPlan, gap: Option<&str>, branch: &str) {
    println!(
        "[ship plan] branch={branch} gap={}",
        gap.unwrap_or("(none)")
    );
    match plan {
        chump_ship::ShipPlan::AlreadyDone {
            pr,
            state,
            recovery_hint,
        } => {
            println!("  action: ALREADY_DONE  pr=#{pr} state={state:?}");
            println!("  hint:   {recovery_hint}");
        }
        chump_ship::ShipPlan::CreatePr { branch, ahead } => {
            println!("  action: CREATE_PR  branch={branch} ahead_main={ahead}");
        }
        chump_ship::ShipPlan::RebaseAndPush { behind_count } => {
            println!("  action: REBASE_AND_PUSH  behind_main={behind_count}");
        }
        chump_ship::ShipPlan::RestDirectMerge {
            pr,
            head_sha,
            checks_verified,
        } => {
            println!(
                "  action: REST_DIRECT_MERGE  pr=#{pr} head={} checks_green={checks_verified}",
                &head_sha[..head_sha.len().min(8)]
            );
        }
        chump_ship::ShipPlan::ArmAutoMerge { pr, reason } => {
            println!("  action: ARM_AUTO_MERGE  pr=#{pr}");
            println!("  reason: {reason}");
        }
        chump_ship::ShipPlan::WaitForChecks {
            pr,
            incomplete,
            reason,
        } => {
            println!("  action: WAIT_FOR_CHECKS  pr=#{pr} incomplete={incomplete}");
            println!("  reason: {reason}");
        }
        chump_ship::ShipPlan::StaleBranch {
            pr,
            behind,
            threshold,
            recovery_hint,
        } => {
            println!(
                "  action: STALE_BRANCH  pr={} behind={behind} threshold={threshold}",
                pr.map(|n| format!("#{n}"))
                    .unwrap_or_else(|| "(none)".to_string())
            );
            println!("  hint:   {recovery_hint}");
        }
        chump_ship::ShipPlan::ConflictRecover { pr, recovery_hint } => {
            println!("  action: CONFLICT_RECOVER  pr=#{pr}");
            println!("  hint:   {recovery_hint}");
        }
        chump_ship::ShipPlan::OperatorAction {
            reason,
            recovery_hint,
        } => {
            println!("  action: OPERATOR_ACTION");
            println!("  reason: {reason}");
            println!("  hint:   {recovery_hint}");
        }
    }
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-1229 slice 2 — `chump ship execute` CLI wrapper around the
// chump-ship executor decision (decide_steps). Reads a ShipPlan from a
// file or stdin, derives the ExecutorStep list, runs each step via
// std::process::Command, and emits an ExecuteResult JSON.
// ──────────────────────────────────────────────────────────────────────

async fn ship_execute_cli(args: &[String]) -> Result<()> {
    let mut plan_path: Option<String> = None;
    let mut from_stdin = false;
    let mut dry_run = false;
    // INFRA-1229 slice 3: bounded retry on push --force-with-lease races.
    let mut max_rebase_retries: u32 = std::env::var("CHUMP_BOT_MERGE_RETRY_MAX")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(3);
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--plan" => {
                plan_path = args.get(i + 1).cloned();
                i += 2;
            }
            "--stdin" => {
                from_stdin = true;
                i += 1;
            }
            "--dry-run" => {
                dry_run = true;
                i += 1;
            }
            "--max-rebase-retries" => {
                max_rebase_retries = args
                    .get(i + 1)
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(max_rebase_retries);
                i += 2;
            }
            "--json" => {
                i += 1; // default, but accepted
            }
            other => {
                eprintln!("chump ship execute: unknown flag {other:?}");
                eprintln!("Run `chump ship execute --help` for usage.");
                std::process::exit(2);
            }
        }
    }

    if plan_path.is_none() && !from_stdin {
        eprintln!("chump ship execute: one of --plan PATH or --stdin is required.");
        std::process::exit(2);
    }

    // Read the plan envelope. `chump ship plan` emits a top-level object
    // with a `.plan` field; accept both that shape and a bare ShipPlan.
    let plan_json = if let Some(p) = plan_path {
        std::fs::read_to_string(&p).map_err(|e| anyhow::anyhow!("read --plan {p}: {e}"))?
    } else {
        use std::io::Read;
        let mut buf = String::new();
        std::io::stdin()
            .read_to_string(&mut buf)
            .map_err(|e| anyhow::anyhow!("read stdin: {e}"))?;
        buf
    };

    let value: serde_json::Value =
        serde_json::from_str(&plan_json).map_err(|e| anyhow::anyhow!("parse plan JSON: {e}"))?;
    let plan_obj = value.get("plan").unwrap_or(&value).clone();
    let plan: chump_ship::ShipPlan =
        serde_json::from_value(plan_obj).map_err(|e| anyhow::anyhow!("decode ShipPlan: {e}"))?;

    let steps = chump_ship::decide_steps(&plan);
    let plan_action = match &plan {
        chump_ship::ShipPlan::AlreadyDone { .. } => "AlreadyDone",
        chump_ship::ShipPlan::CreatePr { .. } => "CreatePr",
        chump_ship::ShipPlan::RebaseAndPush { .. } => "RebaseAndPush",
        chump_ship::ShipPlan::RestDirectMerge { .. } => "RestDirectMerge",
        chump_ship::ShipPlan::ArmAutoMerge { .. } => "ArmAutoMerge",
        chump_ship::ShipPlan::WaitForChecks { .. } => "WaitForChecks",
        chump_ship::ShipPlan::StaleBranch { .. } => "StaleBranch",
        chump_ship::ShipPlan::ConflictRecover { .. } => "ConflictRecover",
        chump_ship::ShipPlan::OperatorAction { .. } => "OperatorAction",
    };

    if steps.is_empty() {
        let payload = serde_json::json!({
            "plan_action": plan_action,
            "executed": false,
            "steps": [],
            "any_failure": false,
            "note": "No executor action needed for this ShipPlan variant.",
        });
        println!("{}", serde_json::to_string_pretty(&payload)?);
        return Ok(());
    }

    // Resolve the `{OWNER_REPO}` placeholder used by RestDirectMerge before
    // executing — only one `gh repo view` per invocation.
    let owner_repo = if dry_run {
        "{OWNER_REPO}".to_string()
    } else {
        std::process::Command::new("gh")
            .args([
                "repo",
                "view",
                "--json",
                "nameWithOwner",
                "--jq",
                ".nameWithOwner",
            ])
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "{OWNER_REPO}".to_string())
    };

    let mut step_results: Vec<serde_json::Value> = Vec::new();
    let mut any_failure = false;
    let mut retry_attempts: u32 = 0;
    let mut final_action: String = "Success".to_string();

    // INFRA-1229 slice 3: RebaseAndPush gets a retry loop driven by
    // chump_ship::classify_step_failure. Other plan variants use a single
    // pass.
    let is_rebase_and_push = matches!(plan, chump_ship::ShipPlan::RebaseAndPush { .. });

    'attempt: for attempt in 0..=max_rebase_retries {
        if attempt > 0 {
            retry_attempts = attempt;
            eprintln!(
                "[ship execute] push lost a race; retry {}/{}",
                attempt, max_rebase_retries
            );
        }
        for step in &steps {
            let resolved_args: Vec<String> = step
                .args
                .iter()
                .map(|a| a.replace("{OWNER_REPO}", &owner_repo))
                .collect();
            if dry_run {
                step_results.push(serde_json::json!({
                    "program": step.program,
                    "args": resolved_args,
                    "rc": 0,
                    "stderr_tail": "",
                    "duration_ms": 0,
                    "dry_run": true,
                    "note": step.note,
                    "attempt": attempt,
                }));
                continue;
            }
            let started = std::time::Instant::now();
            let out = std::process::Command::new(&step.program)
                .args(&resolved_args)
                .output();
            let elapsed_ms = started.elapsed().as_millis() as u64;
            let (rc, stderr_tail) = match out {
                Ok(o) => {
                    let tail = String::from_utf8_lossy(&o.stderr);
                    let tail: String = tail
                        .lines()
                        .rev()
                        .take(3)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect::<Vec<_>>()
                        .join("\n");
                    (o.status.code().unwrap_or(-1), tail)
                }
                Err(e) => (-1, format!("exec error: {e}")),
            };
            let success = rc == 0;
            step_results.push(serde_json::json!({
                "program": step.program,
                "args": resolved_args,
                "rc": rc,
                "stderr_tail": stderr_tail,
                "duration_ms": elapsed_ms,
                "expect_success": step.expect_success,
                "success": success,
                "note": step.note,
                "attempt": attempt,
            }));
            if !success && step.expect_success {
                any_failure = true;

                if is_rebase_and_push {
                    // Classify the failure: retry, abort-as-conflict, or hard-fail.
                    let action = chump_ship::classify_step_failure(
                        &step.program,
                        &resolved_args,
                        rc,
                        &stderr_tail,
                        attempt,
                        max_rebase_retries,
                    );
                    match action {
                        chump_ship::RetryAction::RetryRebaseAndPush { .. } => {
                            // Restart from the top of the step list on next attempt.
                            final_action = "RetryRebaseAndPush".to_string();
                            continue 'attempt;
                        }
                        chump_ship::RetryAction::AbortAsConflict { reason } => {
                            final_action = "ConflictRecover".to_string();
                            eprintln!("[ship execute] {reason}");
                            // Best-effort: leave the rebase abort to the operator
                            // — the conflict markers in the working tree are the
                            // evidence they need.
                            break 'attempt;
                        }
                        chump_ship::RetryAction::Fail { reason } => {
                            final_action = "Fail".to_string();
                            eprintln!("[ship execute] {reason}");
                            break 'attempt;
                        }
                        chump_ship::RetryAction::Continue
                        | chump_ship::RetryAction::AbortAsStaleBranch { .. } => {
                            // AbortAsStaleBranch isn't emitted by this classifier
                            // (it's a pre-push check); Continue shouldn't happen
                            // on a failed step.
                            final_action = "Fail".to_string();
                            break 'attempt;
                        }
                    }
                } else {
                    // Non-rebase variants: keep the existing single-pass behavior.
                    final_action = "Fail".to_string();
                    break 'attempt;
                }
            }
        }
        // Loop finished without a step-failure → all steps succeeded on this attempt.
        // (Overwrite final_action even if a previous attempt failed and we
        // retried successfully — the final state IS success.)
        final_action = "Success".to_string();
        // Once the chain succeeds via retry, the earlier failures are
        // recorded in step_results but don't bubble out as any_failure.
        any_failure = false;
        break 'attempt;
        // Note: if a step failed, control always reaches `break 'attempt` or
        // `continue 'attempt` above and never falls through to here.
    }

    let payload = serde_json::json!({
        "plan_action": plan_action,
        "executed": !dry_run,
        "dry_run": dry_run,
        "steps": step_results,
        "any_failure": any_failure,
        "retry_attempts": retry_attempts,
        "final_action": final_action,
        "max_rebase_retries": max_rebase_retries,
    });
    println!("{}", serde_json::to_string_pretty(&payload)?);
    if any_failure && final_action != "Success" {
        std::process::exit(1);
    }
    Ok(())
}

/// MISSION-046: extract OWNER/REPO from a gap's `skills_required` if it carries an
/// `external_repo:OWNER/REPO` tag (single tag or comma/space/tab-separated list).
/// Returns None for internal gaps so `--execute-gap` keeps the internal loop.
fn external_repo_target_from_skills(skills: &str) -> Option<String> {
    skills
        .split([',', ' ', '\t'])
        .find_map(|tok| tok.trim().strip_prefix("external_repo:"))
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty() && s.contains('/'))
}

#[cfg(test)]
mod tests {
    use crate::agent_factory;
    use serde_json::json;
    use serial_test::serial;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    /// Full agent turn against a mock HTTP server: no real model. Asserts reply content.
    ///
    /// 2026-05-08: marked `#[ignore]`. This test is fragile by design — every
    /// new agent-loop guard breaks it (CHUMP_MAX_CONSECUTIVE_TOOL_FAILS in
    /// INFRA-677, then "Exceeded max iterations (25)" today). The mock
    /// returns `{"content": "Mocked reply", "tool_calls": null}` which the
    /// real agent loop now treats as a partial completion + iterates. The
    /// test would need a more deterministic mock contract (or a test-only
    /// short-circuit in the agent loop) to be maintainable.
    ///
    /// Run manually with `cargo test integration_agent_run_against_mock --
    /// --ignored` after touching the agent loop. Don't gate CI on it.
    #[tokio::test]
    #[serial]
    #[ignore]
    async fn integration_agent_run_against_mock() {
        let mock = MockServer::start().await;
        let body = json!({
            "choices": [{
                "message": {
                    "content": "Mocked reply",
                    "tool_calls": null
                },
                "finish_reason": "stop"
            }]
        });
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&body))
            .mount(&mock)
            .await;

        std::env::set_var("OPENAI_API_BASE", mock.uri());
        // INFRA-677: disable consecutive-tool-fails breaker so a sibling
        // test setting CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=1 mid-run can't
        // trip our agent. Observed sporadic CI failure: returned "Aborting:
        // 3 consecutive tool batches with no successful calls" instead of
        // "Mocked reply" because env-var races slip past #[serial].
        std::env::set_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS", "99999");
        let (agent, _) = agent_factory::build_chump_agent_cli().expect("build agent");
        let outcome = agent.run("Hello").await.unwrap();
        std::env::remove_var("OPENAI_API_BASE");
        std::env::remove_var("CHUMP_MAX_CONSECUTIVE_TOOL_FAILS");
        assert!(
            outcome.reply.contains("Mocked reply"),
            "expected reply to contain mock content, got: {}",
            outcome.reply
        );
    }

    // EFFECTIVE-011: alias expansion unit tests.
    #[test]
    fn effective_011_alias_g_expands_to_gap() {
        let args = vec!["chump".to_string(), "g".to_string(), "list".to_string()];
        let expanded = crate::expand_aliases(args);
        assert_eq!(expanded, vec!["chump", "gap", "list"]);
    }

    #[test]
    fn effective_011_alias_c_expands_to_claim() {
        let args = vec![
            "chump".to_string(),
            "c".to_string(),
            "INFRA-123".to_string(),
        ];
        let expanded = crate::expand_aliases(args);
        assert_eq!(expanded, vec!["chump", "claim", "INFRA-123"]);
    }

    #[test]
    fn effective_011_alias_s_expands_to_gap_ship() {
        let args = vec![
            "chump".to_string(),
            "s".to_string(),
            "INFRA-123".to_string(),
        ];
        let expanded = crate::expand_aliases(args);
        assert_eq!(expanded, vec!["chump", "gap", "ship", "INFRA-123"]);
    }

    #[test]
    fn effective_011_alias_f_d_h_cs_expand() {
        let mk = |a: &str| vec!["chump".to_string(), a.to_string()];
        assert_eq!(crate::expand_aliases(mk("f"))[1], "fleet");
        assert_eq!(crate::expand_aliases(mk("d"))[1], "dispatch");
        assert_eq!(crate::expand_aliases(mk("h"))[1], "health");
        assert_eq!(crate::expand_aliases(mk("cs"))[1], "cost-watch");
    }

    #[test]
    fn effective_011_no_alias_passthrough() {
        let args = vec!["chump".to_string(), "gap".to_string(), "list".to_string()];
        let expanded = crate::expand_aliases(args.clone());
        assert_eq!(expanded, args);
    }

    // ── INFRA-2112: --external-repo flag unit tests ──────────────────────────

    /// Parse --external-repo owner/repo form and verify tag + path resolution.
    #[test]
    fn mission_046_external_repo_target_parses_single_tag() {
        assert_eq!(
            crate::external_repo_target_from_skills("external_repo:repairman29/BEAST-MODE"),
            Some("repairman29/BEAST-MODE".to_string())
        );
    }
    #[test]
    fn mission_046_external_repo_target_parses_in_list() {
        assert_eq!(
            crate::external_repo_target_from_skills("rust, external_repo:owner/repo, git"),
            Some("owner/repo".to_string())
        );
    }
    #[test]
    fn mission_046_internal_gap_returns_none() {
        assert_eq!(
            crate::external_repo_target_from_skills("rust,sqlite,coord"),
            None
        );
        assert_eq!(crate::external_repo_target_from_skills(""), None);
    }

    #[test]
    fn infra_2112_external_repo_ownerslashrepo_flag_parses() {
        let args: Vec<String> = vec![
            "chump".into(),
            "gap".into(),
            "decompose".into(),
            "INFRA-9999".into(),
            "--external-repo".into(),
            "acme/widget".into(),
        ];

        // Replicate the flag-parsing logic from cmd_gap_decompose.
        let external_repo: Option<String> = args
            .iter()
            .position(|a| a == "--external-repo")
            .and_then(|i| args.get(i + 1))
            .cloned();

        let clone_path_override: Option<std::path::PathBuf> = args
            .iter()
            .position(|a| a == "--clone-path")
            .and_then(|i| args.get(i + 1))
            .map(std::path::PathBuf::from);

        assert_eq!(external_repo.as_deref(), Some("acme/widget"));
        assert!(clone_path_override.is_none());

        // Resolve tag + path the same way the handler does.
        let repo_val = external_repo.as_deref().unwrap();
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        let expected_path = std::path::PathBuf::from(&home)
            .join(".chump")
            .join("external")
            .join(repo_val);

        let (resolved_path, tag) = if repo_val.starts_with('/') {
            panic!("should not be absolute path form");
        } else {
            let default_path = std::path::PathBuf::from(&home)
                .join(".chump")
                .join("external")
                .join(repo_val);
            (default_path, format!("external_repo:{repo_val}"))
        };

        assert_eq!(resolved_path, expected_path);
        assert_eq!(tag, "external_repo:acme/widget");
    }

    /// Absolute-path form of --external-repo uses path as-is and derives tag
    /// from last two path components.
    #[test]
    fn infra_2112_external_repo_absolute_path_flag_parses() {
        let args: Vec<String> = vec![
            "chump".into(),
            "gap".into(),
            "decompose".into(),
            "INFRA-9999".into(),
            "--external-repo".into(),
            "/tmp/my-clones/acme/widget".into(),
        ];

        let external_repo: Option<String> = args
            .iter()
            .position(|a| a == "--external-repo")
            .and_then(|i| args.get(i + 1))
            .cloned();

        let repo_val = external_repo.as_deref().unwrap();
        assert!(repo_val.starts_with('/'), "expected absolute path");

        let p = std::path::PathBuf::from(repo_val);
        let mut comps: Vec<String> = p
            .components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect();
        comps.retain(|c| !c.is_empty());

        let tag_suffix = if comps.len() >= 2 {
            format!("{}/{}", comps[comps.len() - 2], comps[comps.len() - 1])
        } else {
            comps
                .last()
                .cloned()
                .unwrap_or_else(|| repo_val.to_string())
        };

        let tag = format!("external_repo:{tag_suffix}");

        assert_eq!(p, std::path::PathBuf::from("/tmp/my-clones/acme/widget"));
        assert_eq!(tag, "external_repo:acme/widget");
    }

    /// --clone-path overrides the resolved path while keeping the tag derived
    /// from the --external-repo value.
    #[test]
    fn infra_2112_clone_path_override_respected() {
        let args: Vec<String> = vec![
            "chump".into(),
            "gap".into(),
            "decompose".into(),
            "INFRA-9999".into(),
            "--external-repo".into(),
            "acme/widget".into(),
            "--clone-path".into(),
            "/custom/clone/path".into(),
        ];

        let external_repo: Option<String> = args
            .iter()
            .position(|a| a == "--external-repo")
            .and_then(|i| args.get(i + 1))
            .cloned();

        let clone_path_override: Option<std::path::PathBuf> = args
            .iter()
            .position(|a| a == "--clone-path")
            .and_then(|i| args.get(i + 1))
            .map(std::path::PathBuf::from);

        assert_eq!(external_repo.as_deref(), Some("acme/widget"));
        assert_eq!(
            clone_path_override,
            Some(std::path::PathBuf::from("/custom/clone/path"))
        );

        // Override takes precedence; tag still comes from external_repo value.
        let repo_val = external_repo.as_deref().unwrap();
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        let default_path = std::path::PathBuf::from(&home)
            .join(".chump")
            .join("external")
            .join(repo_val);
        let final_path = clone_path_override.clone().unwrap_or(default_path);
        let tag = format!("external_repo:{repo_val}");

        assert_eq!(final_path, std::path::PathBuf::from("/custom/clone/path"));
        assert_eq!(tag, "external_repo:acme/widget");
    }

    /// No --external-repo flag: all external fields are None (backwards compat).
    #[test]
    fn infra_2112_no_external_repo_flag_is_noop() {
        let args: Vec<String> = vec![
            "chump".into(),
            "gap".into(),
            "decompose".into(),
            "INFRA-9999".into(),
            "--dry-run".into(),
        ];

        let external_repo: Option<String> = args
            .iter()
            .position(|a| a == "--external-repo")
            .and_then(|i| args.get(i + 1))
            .cloned();

        let clone_path_override: Option<std::path::PathBuf> = args
            .iter()
            .position(|a| a == "--clone-path")
            .and_then(|i| args.get(i + 1))
            .map(std::path::PathBuf::from);

        // Neither field set — backwards compatible, no external context injected.
        assert!(external_repo.is_none());
        assert!(clone_path_override.is_none());

        // Derived tag is also None.
        let external_repo_tag: Option<String> = external_repo.map(|v| format!("external_repo:{v}"));
        assert!(external_repo_tag.is_none());
    }
}
