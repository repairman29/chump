//! `chump --execute-gap <GAP-ID>` — unattended single-gap dispatch mode.
//!
//! COG-025: lets `chump-orchestrator` route a dispatched subagent through
//! Chump's own multi-turn agent loop (and therefore through any
//! OpenAI-compatible backend — Together, mistral.rs, Ollama) instead of
//! shelling out to the Anthropic-only `claude -p` CLI. Cost-routing path
//! for autonomous PR shipping; pairs with `CHUMP_DISPATCH_BACKEND=chump-local`
//! in `crates/chump-orchestrator/src/dispatch.rs`.
//!
//! ## Contract (mirrors `chump_orchestrator::dispatch::build_prompt`)
//!
//! 1. Read `docs/gaps.yaml` for the gap entry (acceptance criteria).
//! 2. Build the same dispatched-agent prompt the `claude` baseline sees.
//! 3. Drive `ChumpAgent::run` with that prompt — single user turn,
//!    multi-iteration tool-use loop. Provider is whatever
//!    `provider_cascade::build_provider()` resolves from `OPENAI_API_BASE` +
//!    `OPENAI_MODEL` env (Together, mistral.rs, Ollama, hosted OpenAI…).
//! 4. Print the agent's final reply to stdout. Caller (orchestrator monitor)
//!    parses the PR number from the reply or polls `gh pr list` like the
//!    `claude` path.
//!
//! ## Exit codes
//!
//! * `0` — agent loop returned a reply (success, regardless of whether the
//!   reply contains a PR number — monitor parses).
//! * `1` — agent loop errored, generic class (provider unreachable,
//!   max iterations, cancellation, network timeout, etc.).
//! * `2` — usage error (missing or malformed gap id).
//! * `75` — agent loop errored with **billing-exhausted** class (HTTP 402,
//!   `credit_limit`, `insufficient_quota`, `payment required`). Distinct from
//!   `1` so the orchestrator's stderr-tailer (see
//!   `crates/chump-orchestrator/src/dispatch.rs:766`) can detect this
//!   specifically and decide whether to respawn the dispatched child against
//!   the next routing-table candidate (TOGETHER → GROQ → Claude). Matches
//!   `EX_TEMPFAIL` per `sysexits.h`. INFRA-302 blocker (1).
//!
//!   Today the cascade-respawn lives only at the per-call layer
//!   (`provider_cascade::should_cascade_on_error_string`, INFRA-300 PR #890).
//!   This exit-code-plus-stderr-marker contract is the *signal* the
//!   orchestrator-level cascade-respawn (filed separately) needs to act on
//!   — without it, the orchestrator can't tell a billing-exhausted Together
//!   exit from a network blip from a tool-format failure, and either retries
//!   the same provider blindly (worsens the credit hole) or gives up
//!   uniformly (the 2026-05-02 dogfood failure mode).
//!
//! ## Why no per-tool approval gating
//!
//! [`crate::agent_loop::ChumpAgent`] only prompts for tool approval when
//! `CHUMP_TOOLS_ASK` is set. Dispatched runs leave it unset, so the loop
//! runs unattended end-to-end (mirrors `--dangerously-skip-permissions`
//! on the `claude` baseline — see dispatch.rs INFRA-DISPATCH-PERMISSIONS-FLAG
//! comment).
//!
//! ## Gemini tool-call validation (EFFECTIVE-007)
//!
//! Gemini 2.5 Flash has been validated (2026-05-15) as the preferred sonnet-tier
//! provider for autonomous dispatch. Tool-call quality verified equal to or better
//! than Llama 3.3 70B: proper OpenAI-format tool_calls, valid unified diffs on
//! first attempt, no fuzzy-match fallback needed. See docs/architecture/FREE_TIER_PROVIDER_COMPAT.md
//! for test methodology and full results.

use anyhow::{anyhow, Context, Result};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio_util::sync::CancellationToken;

use crate::agent_factory::build_chump_agent_cli;
use crate::agent_loop::ChumpAgent;
use crate::ambient_stream::locate_ambient;
use crate::model_overlay::{detect_model_family, maybe_overlay_from_env, ModelFamily};
use crate::plan_mode::{self, PlanOutcome};

// ──────────────────────────────────────────────────────────────────────
// INFRA-2055 — terminal outcome emission
// Every exit path from chump --execute-gap MUST emit exactly one of:
//   gap_shipped  — PR opened, status flipped to done
//   gap_blocked  — any non-clean exit (error, timeout, panic, signal)
//   gap_deferred — agent explicitly punted to wait for external event
//
// This is the authoritative fix for the wizard wheel-spin: wizard-daemon
// was re-dispatching the same gap forever because chump --execute-gap
// could exit silently with no structured outcome. Now wizard reads the
// explicit kind instead of heuristic-guessing from PID death + PR state.
// ──────────────────────────────────────────────────────────────────────

/// The three terminal outcome kinds a chump --execute-gap run can emit.
/// # scanner-anchor: "kind":"gap_shipped"
/// # scanner-anchor: "kind":"gap_blocked"
/// # scanner-anchor: "kind":"gap_deferred"
#[derive(Debug, Clone)]
pub enum ExecuteGapOutcome {
    /// Happy path: PR was opened and gap status flipped to done.
    Shipped {
        gap_id: String,
        /// PR number parsed from the agent reply (empty string if not found).
        pr_number: String,
        /// HEAD commit SHA at ship time (empty string if unavailable).
        commit_sha: String,
    },
    /// Any non-clean exit: uncaught error, timeout, panic, signal, or
    /// an explicit "I can't make progress" return.
    Blocked {
        gap_id: String,
        /// Human-readable reason phrase (max ~200 chars).
        reason: String,
        /// Optional hint for recovery (e.g. "wait_for_ci", "fix_billing",
        /// "manual_rescue"). Empty string when unknown.
        recoverable_by: String,
    },
    /// Agent decided to pause and wait for an external event.
    Deferred {
        gap_id: String,
        reason: String,
        /// Name of the event the agent is waiting on (e.g. "upstream_pr_landed").
        defer_until_event: String,
    },
}

/// Emit one terminal outcome to ambient.jsonl. Call this ONCE per
/// `chump --execute-gap` run, immediately before process exit.
///
/// Best-effort: write failures are silently discarded so they can never
/// prevent the parent process from exiting with the right code.
pub fn emit_terminal_outcome(outcome: &ExecuteGapOutcome) {
    use std::io::Write;
    let cwd = std::env::current_dir().unwrap_or_default();
    let ambient =
        locate_ambient(&cwd).unwrap_or_else(|| cwd.join(".chump-locks").join("ambient.jsonl"));
    let _ = std::fs::create_dir_all(ambient.parent().unwrap_or(&cwd));
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let session = crate::ambient_stream::env_session_id().unwrap_or_default();
    let line = match outcome {
        ExecuteGapOutcome::Shipped {
            gap_id,
            pr_number,
            commit_sha,
        } => format!(
            "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"gap_shipped\",\
             \"gap_id\":\"{gap_id}\",\"pr_number\":\"{pr_number}\",\
             \"commit_sha\":\"{commit_sha}\",\"emitter\":\"execute_gap\"}}"
        ),
        ExecuteGapOutcome::Blocked {
            gap_id,
            reason,
            recoverable_by,
        } => {
            let reason_esc = escape_json(reason);
            let rec_esc = escape_json(recoverable_by);
            format!(
                "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"gap_blocked\",\
                 \"gap_id\":\"{gap_id}\",\"reason\":\"{reason_esc}\",\
                 \"recoverable_by\":\"{rec_esc}\",\"emitter\":\"execute_gap\"}}"
            )
        }
        ExecuteGapOutcome::Deferred {
            gap_id,
            reason,
            defer_until_event,
        } => {
            let reason_esc = escape_json(reason);
            let evt_esc = escape_json(defer_until_event);
            format!(
                "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"gap_deferred\",\
                 \"gap_id\":\"{gap_id}\",\"reason\":\"{reason_esc}\",\
                 \"defer_until_event\":\"{evt_esc}\",\"emitter\":\"execute_gap\"}}"
            )
        }
    };
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Minimal JSON string escaping for the reason/event fields.
/// Only handles the subset that can appear in error messages and gap IDs.
fn escape_json(s: &str) -> String {
    s.chars()
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            '\n' => vec!['\\', 'n'],
            '\r' => vec!['\\', 'r'],
            '\t' => vec!['\\', 't'],
            c => vec![c],
        })
        .collect()
}

/// Parse a PR number from the agent reply string. Returns empty string if
/// not found. Accepts numeric sequences that follow "PR #NNN", "#NNN", or
/// are standalone digit-only tokens.
pub fn parse_pr_number_from_reply(reply: &str) -> String {
    // Try "PR #NNN" or "#NNN" first (most common agent reply shapes).
    for token in reply.split_whitespace() {
        let digits = token.trim_start_matches('#');
        if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
            // Only accept if the preceding token was "PR" or token starts with '#'
            if token.starts_with('#') {
                return digits.to_string();
            }
        }
    }
    // Fallback: first standalone number in the reply
    for token in reply.split_whitespace() {
        if !token.is_empty() && token.chars().all(|c| c.is_ascii_digit()) {
            return token.to_string();
        }
    }
    String::new()
}

/// Read HEAD commit SHA from git. Returns empty string if git is unavailable.
pub fn current_head_sha() -> String {
    std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout)
                    .ok()
                    .map(|s| s.trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_default()
}

/// Build the dispatched-subagent prompt. Mirrors `chump_orchestrator::dispatch::build_prompt`
/// so reflection rows from both backends compare apples-to-apples on COG-026 A/B.
/// Reads `docs/process/CHUMP_DISPATCH_RULES.md` from `repo_root` and injects it inline so
/// the chump-local backend receives coordination rules regardless of whether it
/// reads files unprompted.
///
/// COG-031 step 1: when `OPENAI_MODEL` matches a known non-Sonnet family, a
/// model-shape overlay (from [`crate::model_overlay`]) is prepended ahead of
/// the rules block. The overlay addresses the specific failure modes observed
/// in the COG-026 V2-V5 trials (read-loop iter-cap on chat-Instruct, chatty
/// "Would you like me to..." exit on coder-Instruct). Sonnet and unknown
/// models get no overlay (Sonnet ships fine on the bare prompt; Other lacks
/// empirical signal to justify a guess).
pub fn build_execute_gap_prompt(gap_id: &str, repo_root: &std::path::Path) -> String {
    let rules = std::fs::read_to_string(repo_root.join("docs/process/CHUMP_DISPATCH_RULES.md"))
        .unwrap_or_default();
    let rules_block = if rules.is_empty() {
        String::new()
    } else {
        format!("{rules}\n\n---\n\n")
    };
    let overlay_block = maybe_overlay_from_env().unwrap_or_default();
    // INFRA-332: subagent-shipping-epilogue (canonical token). Same
    // injection as crates/chump-orchestrator/src/dispatch.rs::build_prompt
    // so both backends present an identical recovery / final-report
    // contract. Closes the META-025 25-33% self-ship gap.
    let epilogue =
        std::fs::read_to_string(repo_root.join("scripts/dispatch/subagent-shipping-epilogue.md"))
            .unwrap_or_default();
    let epilogue_block = if epilogue.is_empty() {
        String::new()
    } else {
        format!("\n\n---\n\n{epilogue}")
    };
    format!(
        "{overlay}{rules}You are a Chump dispatched agent working on gap {gap}. \
The gap is already claimed in this worktree. \
Read the gap entry in docs/gaps/<ID>.yaml for full acceptance criteria. \
Do the work, then ship via:\n  scripts/coord/bot-merge.sh --gap {gap} --auto-merge\n\
After ship, exit. Reply ONLY with the PR number.{epilogue}",
        overlay = overlay_block,
        rules = rules_block,
        gap = gap_id,
        epilogue = epilogue_block,
    )
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-733: free-tier dispatch harness (Groq, Cerebras, NVIDIA, etc.)
// ──────────────────────────────────────────────────────────────────────

/// Detect whether `OPENAI_MODEL` + `OPENAI_API_BASE` point at a non-Claude
/// free-tier provider. When true, `execute_gap` uses a slim 5-tool profile
/// and a simplified prompt that avoids confusing non-Claude models.
fn is_free_tier_model() -> bool {
    let model = std::env::var("OPENAI_MODEL")
        .unwrap_or_default()
        .to_lowercase();
    let base = std::env::var("OPENAI_API_BASE")
        .unwrap_or_default()
        .to_lowercase();

    // Anything that resolves to a non-Claude family is free-tier candidate
    let family = detect_model_family(&model);
    let is_non_claude = !matches!(family, ModelFamily::Sonnet | ModelFamily::OtherClaude);

    // Double-check: base URL must point at a known free-tier endpoint, not Ollama
    let is_cloud_endpoint = base.contains("groq.com")
        || base.contains("cerebras.ai")
        || base.contains("together.xyz")
        || base.contains("nvidia.com")
        || base.contains("openrouter.ai")
        || base.contains("github.ai")
        || base.contains("googleapis.com")
        || base.contains("hyperbolic.xyz");

    is_non_claude && is_cloud_endpoint
}

// ──────────────────────────────────────────────────────────────────────
// EFFECTIVE-002: free-tier provider rotation
// ──────────────────────────────────────────────────────────────────────

/// One entry in the ordered rotation list.
struct FreeTierProviderSpec {
    model: String,
    base_url: String,
    /// Name of the env var holding the API key for this provider
    /// (e.g. `"GROQ_API_KEY"`).  Falls back to `OPENAI_API_KEY` when unset.
    api_key_env: String,
}

/// Parse `CHUMP_FREE_TIER_PROVIDERS` (format: `model@base_url:KEY_ENV,...`)
/// or return the built-in Groq → Cerebras → NVIDIA default order.
fn parse_free_tier_providers() -> Vec<FreeTierProviderSpec> {
    const DEFAULTS: &str = concat!(
        "llama-3.3-70b-versatile@https://api.groq.com/openai/v1:GROQ_API_KEY,",
        "llama-3.3-70b@https://api.cerebras.ai/v1:CEREBRAS_API_KEY,",
        "meta/llama-3.3-70b-instruct@https://integrate.api.nvidia.com/v1:NVIDIA_API_KEY"
    );
    let raw = std::env::var("CHUMP_FREE_TIER_PROVIDERS").unwrap_or_else(|_| DEFAULTS.to_string());
    raw.split(',')
        .filter_map(|entry| {
            let entry = entry.trim();
            // Split on last ':' to get KEY_ENV, then '@' to get model vs base_url
            let (model_base, key_env) = entry.rsplit_once(':')?;
            let (model, base_url) = model_base.split_once('@')?;
            if model.is_empty() || base_url.is_empty() || key_env.is_empty() {
                return None;
            }
            Some(FreeTierProviderSpec {
                model: model.trim().to_string(),
                base_url: base_url.trim().to_string(),
                api_key_env: key_env.trim().to_string(),
            })
        })
        .collect()
}

/// Point env vars at `spec` so `build_provider_single_pub` picks it up.
fn activate_free_tier_provider(spec: &FreeTierProviderSpec) {
    std::env::set_var("OPENAI_API_BASE", &spec.base_url);
    std::env::set_var("OPENAI_MODEL", &spec.model);
    // Prefer the provider-specific key; fall back to the generic one.
    if let Ok(key) = std::env::var(&spec.api_key_env) {
        std::env::set_var("OPENAI_API_KEY", key);
    }
    // Re-evaluate free-tier detection so is_free_tier_model() stays consistent.
    std::env::set_var("CHUMP_FREE_TIER_MODE", "1");
}

/// Build a simplified prompt for free-tier models. Key differences from
/// `build_execute_gap_prompt`:
///
/// 1. Inlines the gap YAML directly (no "read the file" indirection)
/// 2. Lists only the 4 available tools with clear descriptions
/// 3. Explicit step-by-step workflow: read → patch → commit → reply "done"
/// 4. No defensive SCOPE-REFUSE clauses (Llama hallucinated refusals)
/// 5. No `run_cli`/`run_test`/`git_push` — push + PR creation is handled
///    by `execute_gap` as post-processing after the agent returns "done"
///    (INFRA-733 follow-up: free-tier models must not call push tools —
///    too many schema tokens and observed hallucination of wrong tool names)
fn build_free_tier_prompt(gap_id: &str, repo_root: &std::path::Path) -> String {
    // EFFECTIVE-311: the per-file YAML mirrors were retired — reading them
    // handed every open-model dispatch "(gap YAML not found)" as its ENTIRE
    // task spec, so models explored read-only and shipped nothing. state.db
    // is canonical; the YAML file remains only as a legacy fallback.
    // Follow-up (same gap): dispatches run INSIDE a linked worktree where
    // <worktree>/.chump/state.db doesn't exist — GapStore::open would create
    // an EMPTY db there and the model stayed blind. Resolve the MAIN checkout
    // (shared .git parent), which owns the canonical state.db.
    let canonical_root = crate::repo_path::main_checkout_root();
    let gap_yaml = chump_gap_store::GapStore::open(&canonical_root)
        .ok()
        .and_then(|store| store.get(gap_id).ok().flatten())
        .map(|row| {
            format!(
                "id: {}\ntitle: {}\npriority: {}\neffort: {}\ndescription: |\n  {}\nacceptance_criteria: |\n  {}",
                row.id,
                row.title,
                row.priority,
                row.effort,
                row.description.replace('\n', "\n  "),
                row.acceptance_criteria.replace('\n', "\n  "),
            )
        })
        .or_else(|| {
            std::fs::read_to_string(repo_root.join(format!("docs/gaps/{gap_id}.yaml"))).ok()
        })
        .unwrap_or_else(|| format!("(gap spec not found — work on gap {gap_id})"));

    let overlay = maybe_overlay_from_env().unwrap_or_default();

    format!(
        "{overlay}You are a code agent working in a Rust repository. \
Your ONLY job is to make code changes that satisfy the gap below, then commit.

## Gap
```yaml
{gap_yaml}
```

## Workflow (follow exactly, ONE tool call per response)
Step 1: read_file — read the file that needs changing.
Step 2: patch_file — apply your change as a unified diff patch. \
   Provide the old text and new text. Do NOT rewrite the entire file.
Step 3: git_commit — commit with message \"{gap_id}: <short summary>\". \
   This automatically stages modified files.
Step 4: Respond with the single word: done

## Rules
- ONE tool call per response. Do NOT call multiple tools at once.
- NEVER write documentation, plans, or markdown files.
- NEVER explain what you will do — just call the tool.
- NEVER create new files (no chump-plan.md, no docs/*.md).
- Use patch_file for ALL modifications — it only changes what you specify.
- You MUST read a file with read_file BEFORE patching it.
- After git_commit succeeds, respond \"done\" and stop.",
        overlay = overlay,
        gap_yaml = gap_yaml,
        gap_id = gap_id,
    )
}

/// Build a [`ChumpAgent`] with the slim 5-tool free-tier profile.
/// Bypasses the full system prompt and session manager — free-tier runs
/// are single-shot (no conversation history needed).
fn build_free_tier_agent() -> Result<ChumpAgent> {
    // Force cascade OFF for free-tier — we want direct-to-provider, not
    // cascading through 8 slots with varying rate limits.
    std::env::set_var("CHUMP_CASCADE_ENABLED", "0");

    // Clear tool approval gating — unattended dispatch must not wait for
    // human approval. The .env may have CHUMP_TOOLS_ASK=write_file,...
    // which blocks write_file/patch_file/git_commit indefinitely when
    // there's no event channel to receive approval.
    std::env::remove_var("CHUMP_TOOLS_ASK");

    let provider: Box<dyn axonerai::provider::Provider + Send + Sync> =
        crate::provider_cascade::build_provider_single_pub();

    let mut registry = axonerai::tool::ToolRegistry::new();
    crate::tool_inventory::register_free_dispatch_tools(&mut registry);

    let max_iter = std::env::var("CHUMP_AGENT_MAX_ITER")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(30);

    Ok(ChumpAgent::new(
        provider, registry, None, // no system prompt — user message IS the full prompt
        None, // no session manager — single-shot
        None, // no event channel for CLI
        max_iter,
    ))
}

/// Push the current branch and open a PR via `bot-merge.sh`.
///
/// Called by `execute_gap` after the free-tier agent returns "done".
/// The agent can only commit (no `git_push`/`run_cli` in its tool set);
/// this function owns the push+PR step so the orchestrator can find a PR to poll.
/// Uses `--fast` to skip local clippy/test — CI is the gate, and free-tier
/// dispatch runs against tight task-budget walls (INFRA-252 / INFRA-733).
async fn free_tier_ship(gap_id: &str, repo_root: &std::path::Path) -> Result<()> {
    // INFRA-3406: the agent run pins CHUMP_REPO to the worktree so file
    // tools write HERE — but bot-merge's claim/registry paths need the MAIN
    // checkout. Restore it for the ship subprocess.
    std::env::set_var("CHUMP_REPO", crate::repo_path::main_checkout_root());
    // EFFECTIVE-312: open models routinely patch_file and then skip the
    // git_commit step (observed: first sighted M3 cycle patched 1 file,
    // committed nothing). Uncommitted agent work would either vanish or be
    // swept into an INFRA-472 staging commit that INFRA-997 then refuses to
    // ship. Auto-commit it honestly instead so real work reaches the PR.
    let dirty = tokio::process::Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(repo_root)
        .output()
        .await
        .map(|o| !o.stdout.is_empty())
        .unwrap_or(false);
    if dirty {
        eprintln!("[execute-gap] EFFECTIVE-312: uncommitted agent changes — auto-committing");
        let _ = tokio::process::Command::new("git")
            .args(["add", "-A"])
            .current_dir(repo_root)
            .status()
            .await;
        let _ = tokio::process::Command::new("git")
            .args([
                "-c",
                "user.name=chump-fleet",
                "-c",
                "user.email=fleet@chump.local",
                "commit",
                "-m",
                &format!("{gap_id}: agent changes (auto-committed — model skipped git_commit)"),
            ])
            .current_dir(repo_root)
            .status()
            .await;
    }
    let script = repo_root.join("scripts/coord/bot-merge.sh");
    eprintln!("[execute-gap] free-tier ship: bot-merge.sh --gap {gap_id} --fast --auto-merge");
    let status = tokio::process::Command::new("bash")
        .arg(&script)
        .arg("--gap")
        .arg(gap_id)
        .arg("--fast")
        .arg("--auto-merge")
        .current_dir(repo_root)
        .status()
        .await
        .with_context(|| format!("launching bot-merge.sh for {gap_id}"))?;
    if !status.success() {
        return Err(anyhow!(
            "bot-merge.sh exited {} for gap {}",
            status.code().unwrap_or(-1),
            gap_id
        ));
    }
    Ok(())
}

/// Minimal gap-id syntactic check (INFRA-630). Accepts:
///   - Classic `DOMAIN-NUMBER` form: `[A-Z][A-Z0-9]+-\d+` (e.g. INFRA-630)
///   - Full RFC-4122 UUID: 8-4-4-4-12 lowercase hex (e.g. 8d3f2c0e-9f5b-4e1a-b2c3-d4e5f6a7b8c9)
///   - 8-char hex short-prefix used by chump-proprietary display (e.g. 8d3f2c0e)
///
/// Fails the run early if the caller passed garbage so we don't waste a
/// provider call building a prompt for a non-gap.
fn validate_gap_id(gap_id: &str) -> Result<()> {
    if gap_id.is_empty() {
        return Err(anyhow!("gap id is empty"));
    }

    // INFRA-630: accept 8-char hex short-prefix (chump-proprietary display form)
    if gap_id.len() == 8 && gap_id.chars().all(|c| c.is_ascii_hexdigit()) {
        tracing::debug!(gap_id, "INFRA-630: UUID short-prefix gap id accepted");
        return Ok(());
    }

    // INFRA-630: accept full RFC-4122 UUID (8-4-4-4-12 hex groups, lowercase)
    // Pattern: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    let parts: Vec<&str> = gap_id.split('-').collect();
    if parts.len() == 5 {
        let lengths = [8usize, 4, 4, 4, 12];
        if parts
            .iter()
            .zip(lengths.iter())
            .all(|(p, &len)| p.len() == len && p.chars().all(|c| c.is_ascii_hexdigit()))
        {
            tracing::debug!(gap_id, "INFRA-630: RFC-4122 UUID gap id accepted");
            return Ok(());
        }
    }

    // Classic DOMAIN-NUMBER form. INFRA-3404: split on the LAST hyphen so
    // double-hyphen domains (ZERO-WASTE-015) validate; the prefix charset
    // therefore admits '-' as well.
    let Some((prefix, num)) = gap_id.rsplit_once('-') else {
        return Err(anyhow!("gap id missing '-': {gap_id}"));
    };
    if prefix.is_empty()
        || !prefix
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '-')
    {
        return Err(anyhow!(
            "gap id prefix must be uppercase letters/digits: {gap_id}"
        ));
    }
    if num.is_empty() || !num.chars().all(|c| c.is_ascii_digit()) {
        return Err(anyhow!("gap id suffix must be digits: {gap_id}"));
    }
    Ok(())
}

/// INFRA-2056: emit a subagent heartbeat to ambient.jsonl.
/// Writes kind=subagent_heartbeat so wizard-daemon can detect stalled agents
/// within 2min (heartbeat >120s stale → infer dying/dead).
///
/// Fields match the INFRA-2056 AC:
///   gap_id, pid, last_action (last tool name), iter_count (tool call count)
fn emit_subagent_heartbeat(gap_id: &str, pid: u32, last_action: &str, iter_count: u64) {
    use std::io::Write;
    let cwd = std::env::current_dir().unwrap_or_default();
    let ambient =
        locate_ambient(&cwd).unwrap_or_else(|| cwd.join(".chump-locks").join("ambient.jsonl"));
    let _ = std::fs::create_dir_all(ambient.parent().unwrap_or(&cwd));
    let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let session = crate::ambient_stream::env_session_id().unwrap_or_default();
    // Sanitise last_action: strip any chars that would break JSON (quotes, backslashes)
    let safe_action: String = last_action
        .chars()
        .map(|c| if c == '"' || c == '\\' { '_' } else { c })
        .take(64)
        .collect();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"session\":\"{session}\",\"kind\":\"subagent_heartbeat\",\
         \"gap_id\":\"{gap_id}\",\"pid\":{pid},\"last_action\":\"{safe_action}\",\
         \"iter_count\":{iter_count}}}"
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{line}");
    }
}

/// Run the agent loop on the dispatched-gap prompt. Used by main.rs's
/// `--execute-gap` arm. Returns `Ok(reply)` on success.
pub async fn execute_gap(gap_id: &str) -> Result<String> {
    validate_gap_id(gap_id).with_context(|| format!("validating gap id {gap_id:?}"))?;

    // Mirror the contract in dispatch.rs: subagents must not recursively
    // dispatch. The orchestrator sets CHUMP_DISPATCH_DEPTH=1 in the env;
    // we honor it as a tripwire here too (defensive — if a chump-local
    // subagent somehow respawns chump --execute-gap, we'd recurse).
    if std::env::var("CHUMP_DISPATCH_DEPTH")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .map(|d| d >= 2)
        .unwrap_or(false)
    {
        return Err(anyhow!(
            "CHUMP_DISPATCH_DEPTH >= 2 — refusing to recurse (subagents must not dispatch further subagents)"
        ));
    }

    let repo_root = std::env::current_dir().unwrap_or_default();

    // INFRA-733: detect free-tier model before plan-mode (skip plan-mode
    // for free-tier — plan_mode calls `gh pr list` and reads DISPATCH_RULES
    // which confuses non-Claude models).
    let free_tier = is_free_tier_model();
    if free_tier {
        let model = std::env::var("OPENAI_MODEL").unwrap_or_default();
        eprintln!("[execute-gap] free-tier mode: model={model}, 5-tool slim profile");
        // INFRA-3406: file tools (read/patch/git_commit) resolve paths via
        // CHUMP_REPO — inherited as the MAIN checkout from worker env, so
        // every model patch and commit landed OUTSIDE the dispatch worktree
        // (found stranded in /root/Chump after 15 cycles of "zero-commit
        // branch"). Point the tools at THIS worktree; the canonical state.db
        // is still resolved via main_checkout_root() (git-common-dir),
        // unaffected.
        if let Ok(cwd) = std::env::current_dir() {
            std::env::set_var("CHUMP_REPO", &cwd);
            eprintln!(
                "[execute-gap] INFRA-3406: tool root pinned to worktree {}",
                cwd.display()
            );
        }
        // INFRA-784: signal the agent loop to insert inter-request delays so we
        // don't exhaust the provider's RPM quota on multi-step dispatches.
        // CHUMP_FREE_TIER_DELAY_MS takes precedence if set; this is the fallback
        // that triggers the default 5 000 ms delay when neither flag was set
        // explicitly by the operator.
        std::env::set_var("CHUMP_FREE_TIER_MODE", "1");
    }

    // INFRA-060 (M2): plan-mode gate. Skip for free-tier — saves latency
    // and avoids `gh pr list` hangs in cold worktrees.
    if !free_tier {
        match plan_mode::run_plan_mode(gap_id, &repo_root)? {
            PlanOutcome::Proceed { plan_path } => {
                if let Some(p) = plan_path {
                    eprintln!("[execute-gap] plan-mode: wrote {}", p.display());
                }
            }
            PlanOutcome::Abort { reason, conflicts } => {
                return Err(anyhow!(
                    "plan-mode aborted: {reason}\nconflicts: {conflicts:?}"
                ));
            }
        }
    }

    let prompt = if free_tier {
        build_free_tier_prompt(gap_id, &repo_root)
    } else {
        build_execute_gap_prompt(gap_id, &repo_root)
    };

    if free_tier {
        // EFFECTIVE-002: rotate through Groq → Cerebras → NVIDIA on 429/exhaustion.
        let providers = parse_free_tier_providers();
        // Start from the provider already configured (match by base URL), or index 0.
        let current_base = std::env::var("OPENAI_API_BASE")
            .unwrap_or_default()
            .to_lowercase();
        let start = providers
            .iter()
            .position(|s| current_base.contains(&s.base_url.to_lowercase()))
            .unwrap_or(0);

        let mut last_err: Option<anyhow::Error> = None;
        let total = providers.len();
        for offset in 0..total {
            let idx = (start + offset) % total;
            let spec = &providers[idx];

            // Skip providers whose API key is not available.
            let has_key = std::env::var(&spec.api_key_env).is_ok()
                || std::env::var("OPENAI_API_KEY")
                    .map(|k| !k.is_empty())
                    .unwrap_or(false);
            if !has_key {
                eprintln!(
                    "[execute-gap] free-tier rotation: skipping {} — no key ({} unset)",
                    spec.model, spec.api_key_env
                );
                continue;
            }

            activate_free_tier_provider(spec);
            eprintln!(
                "[execute-gap] free-tier: trying provider {}/{} — {}",
                offset + 1,
                total,
                spec.model
            );

            let agent = build_free_tier_agent()
                .with_context(|| format!("building free-tier agent for {}", spec.model))?;

            // INFRA-2056: background heartbeat task for this provider attempt.
            // Shared state updated by the agent loop (see iter_count_ft / last_action_ft).
            let ft_iter_count = Arc::new(AtomicU64::new(0));
            let ft_last_action: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
            let ft_hb_cancel = CancellationToken::new();
            let ft_hb_handle = {
                let cancel = ft_hb_cancel.clone();
                let gid = gap_id.to_string();
                let pid = std::process::id();
                let iter_count_ref = Arc::clone(&ft_iter_count);
                let last_action_ref = Arc::clone(&ft_last_action);
                tokio::spawn(async move {
                    let interval = std::env::var("CHUMP_SUBAGENT_HEARTBEAT_SECS")
                        .ok()
                        .and_then(|s| s.parse::<u64>().ok())
                        .unwrap_or(60);
                    loop {
                        tokio::select! {
                            _ = cancel.cancelled() => break,
                            _ = tokio::time::sleep(std::time::Duration::from_secs(interval)) => {
                                let count = iter_count_ref.load(Ordering::Relaxed);
                                let action = last_action_ref
                                    .lock()
                                    .map(|g| g.clone())
                                    .unwrap_or_default();
                                emit_subagent_heartbeat(&gid, pid, &action, count);
                            }
                        }
                    }
                })
            };

            match agent.run(&prompt).await {
                Ok(outcome) => {
                    ft_hb_cancel.cancel();
                    let _ = ft_hb_handle.await;
                    free_tier_ship(gap_id, &repo_root)
                        .await
                        .with_context(|| format!("free-tier ship step failed for gap {gap_id}"))?;
                    return Ok(outcome.reply);
                }
                Err(e) => {
                    ft_hb_cancel.cancel();
                    let _ = ft_hb_handle.await;
                    let e_str = format!("{e:#}");
                    if crate::provider_cascade::should_cascade_on_error_string(&e_str)
                        && offset + 1 < total
                    {
                        eprintln!(
                            "[execute-gap] free-tier rotation: {} exhausted ({e_str:.120}), \
                             trying next provider",
                            spec.model
                        );
                        last_err = Some(e);
                        continue;
                    }
                    return Err(e).with_context(|| format!("agent loop failed for gap {gap_id}"));
                }
            }
        }
        return Err(last_err
            .unwrap_or_else(|| anyhow!("no free-tier providers with API keys configured"))
            .context(format!(
                "all free-tier providers exhausted for gap {gap_id}"
            )));
    }

    let (agent, _ready_session) = build_chump_agent_cli()
        .context("building Chump agent for --execute-gap (provider config? OPENAI_API_BASE?)")?;

    // INFRA-2056: background heartbeat task — emits kind=subagent_heartbeat every 60s.
    // Shared atomic state lets the agent loop update last_action/iter_count without
    // the heartbeat task holding a lock during the sleep interval.
    let hb_iter_count = Arc::new(AtomicU64::new(0));
    let hb_last_action: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
    let hb_cancel = CancellationToken::new();
    let hb_handle = {
        let cancel = hb_cancel.clone();
        let gid = gap_id.to_string();
        let pid = std::process::id();
        let iter_count_ref = Arc::clone(&hb_iter_count);
        let last_action_ref = Arc::clone(&hb_last_action);
        tokio::spawn(async move {
            let interval = std::env::var("CHUMP_SUBAGENT_HEARTBEAT_SECS")
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(60);
            loop {
                tokio::select! {
                    _ = cancel.cancelled() => break,
                    _ = tokio::time::sleep(std::time::Duration::from_secs(interval)) => {
                        let count = iter_count_ref.load(Ordering::Relaxed);
                        let action = last_action_ref
                            .lock()
                            .map(|g| g.clone())
                            .unwrap_or_default();
                        emit_subagent_heartbeat(&gid, pid, &action, count);
                    }
                }
            }
        })
    };

    let outcome = agent
        .run(&prompt)
        .await
        .with_context(|| format!("agent loop failed for gap {gap_id}"))?;

    // Cancel heartbeat task once agent completes.
    hb_cancel.cancel();
    let _ = hb_handle.await;

    Ok(outcome.reply)
}

/// Same as [`execute_gap`] but lets tests inject a pre-built [`ChumpAgent`]
/// (avoiding a real provider). Production caller uses [`execute_gap`].
pub async fn execute_gap_with_agent(agent: &ChumpAgent, gap_id: &str) -> Result<String> {
    validate_gap_id(gap_id)?;
    let repo_root = std::env::current_dir().unwrap_or_default();
    let prompt = build_execute_gap_prompt(gap_id, &repo_root);

    // INFRA-2056: background heartbeat task for test-scoped subagents.
    let hb_iter_count = Arc::new(AtomicU64::new(0));
    let hb_last_action: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
    let hb_cancel = CancellationToken::new();
    let hb_handle = {
        let cancel = hb_cancel.clone();
        let gid = gap_id.to_string();
        let pid = std::process::id();
        let iter_count_ref = Arc::clone(&hb_iter_count);
        let last_action_ref = Arc::clone(&hb_last_action);
        tokio::spawn(async move {
            let interval = std::env::var("CHUMP_SUBAGENT_HEARTBEAT_SECS")
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(60);
            loop {
                tokio::select! {
                    _ = cancel.cancelled() => break,
                    _ = tokio::time::sleep(std::time::Duration::from_secs(interval)) => {
                        let count = iter_count_ref.load(Ordering::Relaxed);
                        let action = last_action_ref
                            .lock()
                            .map(|g| g.clone())
                            .unwrap_or_default();
                        emit_subagent_heartbeat(&gid, pid, &action, count);
                    }
                }
            }
        })
    };

    let outcome = agent.run(&prompt).await?;

    hb_cancel.cancel();
    let _ = hb_handle.await;

    Ok(outcome.reply)
}

// ──────────────────────────────────────────────────────────────────────
// INFRA-302 blocker (1) — agent-loop-boundary error classification
// ──────────────────────────────────────────────────────────────────────
//
// The agent loop today (`src/agent_loop/iteration_controller.rs:191`)
// bubbles ALL provider errors uniformly via `result?`. When the
// dispatched child (`chump --execute-gap`) is wired to a single
// non-cascading provider — the typical free-tier setup, since
// `CHUMP_CASCADE_ENABLED=1` requires explicit slot configuration —
// every provider error escapes as a generic anyhow::Error and main.rs
// exits 1.
//
// Result on the 2026-05-02 dogfood run (filed as INFRA-302):
// Together returned HTTP 402 / credit_limit on the first call; the
// agent loop bailed; the orchestrator's stderr-tailer captured the
// "ERROR" line but had no way to distinguish "billing exhausted —
// switch routing candidate" from "network blip — retry same provider"
// from "tool format failure — try a different model family".
//
// The full fix (orchestrator-level cascade-respawn across routing
// candidates, mapping `provider_pfx` → API base/key) is multi-PR and
// touches `crates/chump-orchestrator/src/dispatch.rs:710` —
// `spawn_chump_local`. This PR ships the upstream half:
// classify the error at the execute-gap exit boundary so a
// distinguishable exit code (75 = `EX_TEMPFAIL`) and a single-line
// structured stderr marker reach the orchestrator's tailer. The
// orchestrator then has the signal it needs to do the cascade-respawn
// in the follow-up PR — without it, no amount of orchestrator-side
// retry logic can work, because every dispatched-child failure looks
// the same.

/// INFRA-302 blocker (1) / INFRA-347: classification of errors returned by
/// [`execute_gap`].
///
/// Three variants — billing-exhausted, transport-unreachable, and
/// everything-else — because those are the discriminators the
/// orchestrator-level cascade-respawn needs:
///
/// * [`BillingExhausted`]: provider returned 402 / credit_limit → switch
///   provider or top up credits.
/// * [`TransportUnreachable`]: local daemon is down or the network path to
///   `OPENAI_API_BASE` is broken → restart the daemon, or cascade to a
///   cloud slot via `CHUMP_CASCADE_ENABLED=1`. INFRA-347: this was
///   previously classified as `Other` (exit 1), making it
///   indistinguishable from a tool storm. Now distinct (exit 76) so the
///   orchestrator can respawn against a reachable provider.
/// * [`Other`]: generic failure (max iterations, tool storm, bad request,
///   model crash). Legacy exit code 1 so existing tooling is unaffected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecuteGapErrorKind {
    /// HTTP 402 / credit_limit / insufficient_quota / payment required /
    /// billing-exhausted class. Operator/orchestrator should switch
    /// provider, top up credits, or cascade to the next routing
    /// candidate. Detected via
    /// [`crate::provider_cascade::is_billing_exhausted_error_string`]
    /// — the same predicate INFRA-300 (PR #890) added the per-call
    /// cascade fail-over for, factored out so it can be reused above
    /// the cascade layer.
    BillingExhausted,
    /// Local daemon unreachable / transport-level failure — "connection
    /// refused", "error sending request", "model HTTP unreachable",
    /// "operation timed out", "no route to host", etc. INFRA-347:
    /// factored out of the per-call cascade predicate so the
    /// orchestrator-level cascade-respawn (exit code 76) can distinguish
    /// "Ollama down" from "billing exhausted" (exit 75) and from generic
    /// failures (exit 1). Detected via
    /// [`crate::provider_cascade::is_transport_unreachable_error_string`].
    TransportUnreachable,
    /// Anything else — generic agent-loop failure (network blip,
    /// max-iterations cap, tool storm, model crash, etc.). Maps to
    /// the legacy exit code 1 so existing operator tooling that
    /// `if [ $? -ne 0 ]` keeps working unchanged.
    Other,
}

impl ExecuteGapErrorKind {
    /// Per-class exit code for `chump --execute-gap`'s main-process
    /// exit. `75` follows BSD `EX_TEMPFAIL` from `sysexits.h` for
    /// billing-exhausted. `76` (`EX_PROTOCOL` — "remote error in
    /// protocol") is the analogous code for transport-unreachable:
    /// the local daemon or the network path is broken, not the
    /// orchestrator's logic. Both are outside the 0–2 range existing
    /// tooling uses for usage / generic-failure, distinct enough that
    /// the orchestrator can pattern-match on each. Stays `1` for the
    /// generic case so `bot-merge.sh` and other shell-level callers
    /// see no behavioral change. INFRA-347 adds the
    /// `TransportUnreachable → 76` mapping.
    pub fn exit_code(self) -> i32 {
        match self {
            Self::BillingExhausted => 75,
            Self::TransportUnreachable => 76,
            Self::Other => 1,
        }
    }

    /// One-line structured marker the orchestrator's stderr-tailer (see
    /// `crates/chump-orchestrator/src/dispatch.rs:766`) can grep for
    /// when deciding whether to respawn the dispatched child against
    /// the next routing-table candidate. Returns `None` for the
    /// `Other` variant so we don't spam stderr on every generic
    /// failure — the marker is a dedicated signal, not a log line.
    ///
    /// Format is intentionally stable (one greppable token at column 1
    /// followed by `:` and human-readable context) so future
    /// orchestrator-side parsers can rely on it.
    pub fn stderr_marker(self) -> Option<&'static str> {
        match self {
            Self::BillingExhausted => Some(
                "BILLING_EXHAUSTED: provider returned 402 / credit_limit class; \
                 orchestrator should respawn against next routing-table candidate \
                 (TOGETHER → GROQ → Claude). INFRA-302 blocker (1).",
            ),
            Self::TransportUnreachable => Some(
                "TRANSPORT_UNREACHABLE: local daemon is down or network path to \
                 OPENAI_API_BASE is broken (connection refused, error sending request, \
                 model HTTP unreachable, operation timed out, etc.); orchestrator \
                 should restart the daemon or respawn against a reachable provider \
                 slot. INFRA-347.",
            ),
            Self::Other => None,
        }
    }
}

/// INFRA-302 blocker (1) / INFRA-347: inspect an [`anyhow::Error`] from
/// [`execute_gap`] and classify it for exit-code mapping.
///
/// Walks the formatted error chain (using `format!("{err:#}")` so the
/// full Context-wrapped chain is visible) and matches against
/// [`crate::provider_cascade::is_billing_exhausted_error_string`] and
/// [`crate::provider_cascade::is_transport_unreachable_error_string`].
///
/// Priority: billing-exhausted is checked first (more specific signal for
/// the orchestrator); transport-unreachable second; everything else
/// falls through to `Other`.
///
/// Centralizing this on the formatted chain (not the typed `&Error`)
/// matches the existing INFRA-300 cascade predicate's contract —
/// HTTP-error-bearing strings carry the discriminator (`402`,
/// `credit_limit`, `connection refused`, ...) regardless of which
/// transport layer wrapped them, so a string-based check is correct AND
/// robust to the provider library swapping its concrete error type.
pub fn classify_execute_gap_error(err: &anyhow::Error) -> ExecuteGapErrorKind {
    let chain_str = format!("{err:#}");
    if crate::provider_cascade::is_billing_exhausted_error_string(&chain_str) {
        ExecuteGapErrorKind::BillingExhausted
    } else if crate::provider_cascade::is_transport_unreachable_error_string(&chain_str) {
        ExecuteGapErrorKind::TransportUnreachable
    } else {
        ExecuteGapErrorKind::Other
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn prompt_contains_gap_id_and_ship_command() {
        let p = build_execute_gap_prompt("COG-025", std::path::Path::new("/nonexistent"));
        assert!(p.contains("COG-025"));
        assert!(p.contains("scripts/coord/bot-merge.sh --gap COG-025 --auto-merge"));
        assert!(p.contains("PR number"));
    }

    #[test]
    fn prompt_shape_with_rules_file() {
        // When rules file is present it is injected before the task instruction.
        // The orchestrator's COG-026 A/B measures model performance, not prompt
        // shape, so both backends may include the rules block.
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs").join("process");
        std::fs::create_dir_all(&docs).unwrap();
        std::fs::write(
            docs.join("CHUMP_DISPATCH_RULES.md"),
            "## rules\n- test rule\n",
        )
        .unwrap();
        let p = build_execute_gap_prompt("AUTO-013", dir.path());
        assert!(p.contains("AUTO-013"));
        assert!(p.contains("test rule"), "dispatch rules must be injected");
        assert!(p.contains("bot-merge.sh"));
    }

    #[test]
    fn validate_gap_id_accepts_canonical() {
        assert!(validate_gap_id("COG-025").is_ok());
        assert!(validate_gap_id("AUTO-013").is_ok());
        assert!(validate_gap_id("EVAL-031").is_ok());
    }

    #[test]
    fn validate_gap_id_accepts_double_hyphen_domains() {
        // INFRA-3404: split on the LAST hyphen, not the first.
        assert!(validate_gap_id("ZERO-WASTE-015").is_ok());
        assert!(validate_gap_id("ZERO-WASTE-1").is_ok());
    }

    #[test]
    fn validate_gap_id_accepts_uuid_forms() {
        // INFRA-630: full RFC-4122 UUID
        assert!(validate_gap_id("8d3f2c0e-9f5b-4e1a-b2c3-d4e5f6a7b8c9").is_ok());
        assert!(validate_gap_id("00000000-0000-0000-0000-000000000000").is_ok());
        // INFRA-630: 8-char hex short-prefix (chump-proprietary display form)
        assert!(validate_gap_id("8d3f2c0e").is_ok());
        assert!(validate_gap_id("deadbeef").is_ok());
    }

    #[test]
    fn validate_gap_id_rejects_garbage() {
        assert!(validate_gap_id("").is_err());
        assert!(validate_gap_id("nodash").is_err());
        assert!(validate_gap_id("lowercase-001").is_err());
        assert!(validate_gap_id("COG-").is_err());
        assert!(validate_gap_id("-001").is_err());
        assert!(validate_gap_id("COG-abc").is_err());
    }

    #[test]
    fn validate_gap_id_rejects_recursion_in_prompt() {
        let p = build_execute_gap_prompt("COG-025", std::path::Path::new("/nonexistent"));
        assert!(
            !p.contains("--execute-gap"),
            "prompt accidentally tells agent to re-dispatch"
        );
    }

    /// COG-031 step 1: when OPENAI_MODEL matches a known non-Sonnet family,
    /// the model-shape overlay must be prepended. Uses `#[serial(openai_model_env)]`
    /// because both this test and `overlay_skipped_for_sonnet_baseline` mutate
    /// OPENAI_MODEL — without serialization they race and corrupt each other's
    /// env state under cargo's parallel test runner.
    #[test]
    #[serial(openai_model_env)]
    fn overlay_prepended_for_known_problem_model() {
        let prev = std::env::var("OPENAI_MODEL").ok();
        std::env::set_var("OPENAI_MODEL", "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8");

        let p = build_execute_gap_prompt("COG-031", std::path::Path::new("/nonexistent"));
        assert!(
            p.to_lowercase().contains("autonomous job"),
            "expected COG-031 model overlay to be prepended for Qwen-Coder"
        );
        assert!(
            p.to_lowercase().contains("would you like me to"),
            "Qwen-Coder overlay must call out the chatty-exit failure phrase"
        );
        // Original task content must still be present.
        assert!(p.contains("scripts/coord/bot-merge.sh --gap COG-031 --auto-merge"));

        // Restore env so we don't leak to other tests.
        match prev {
            Some(v) => std::env::set_var("OPENAI_MODEL", v),
            None => std::env::remove_var("OPENAI_MODEL"),
        }
    }

    #[test]
    #[serial(openai_model_env)]
    fn overlay_skipped_for_sonnet_baseline() {
        let prev = std::env::var("OPENAI_MODEL").ok();
        std::env::set_var("OPENAI_MODEL", "claude-sonnet-4-5-20250929");

        let p = build_execute_gap_prompt("COG-031", std::path::Path::new("/nonexistent"));
        assert!(
            !p.to_lowercase().contains("autonomous job"),
            "Sonnet baseline must not get an overlay (ships fine on bare prompt)"
        );
        assert!(p.contains("COG-031"));

        match prev {
            Some(v) => std::env::set_var("OPENAI_MODEL", v),
            None => std::env::remove_var("OPENAI_MODEL"),
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // INFRA-302 blocker (1) — error classification at the
    // execute-gap exit boundary.
    // ──────────────────────────────────────────────────────────────────

    #[test]
    fn classify_billing_exhausted_real_dispatch_incident_string() {
        // Verbatim error from /tmp/dispatch-infra-247.log of the
        // 2026-05-02 dogfood run that motivated INFRA-302. The agent
        // loop wraps the provider error with `with_context("agent loop
        // failed for gap {gap_id}")`, so the formatted chain looks like:
        let raw = anyhow::anyhow!(
            "Local API error 402 Payment Required: {{\n  \"id\": \"ohYGX6i-2kFHot-9f5b21e0e8bcaf3a\",\n  \"error\": {{\n    \"message\": \"Credit limit exceeded, please [add credits](https://api.together.ai/settings/billing). If you've already made a payment, please wait up to 5 minutes for balances to update and try again.\",\n    \"type\": \"credit_limit\",\n    \"param\": null,\n    \"code\": null\n  }}\n}}"
        );
        let wrapped = raw.context("agent loop failed for gap INFRA-247");
        assert_eq!(
            classify_execute_gap_error(&wrapped),
            ExecuteGapErrorKind::BillingExhausted,
            "the exact 2026-05-02 incident string MUST classify as BillingExhausted — \
             this is the regression test for INFRA-302 blocker (1)"
        );
    }

    #[test]
    fn classify_billing_exit_code_is_75_ex_tempfail() {
        assert_eq!(
            ExecuteGapErrorKind::BillingExhausted.exit_code(),
            75,
            "75 = EX_TEMPFAIL per BSD sysexits.h; the orchestrator's \
             stderr-tailer pattern-matches on this to decide cascade-respawn"
        );
    }

    #[test]
    fn classify_other_exit_code_unchanged_at_1() {
        assert_eq!(
            ExecuteGapErrorKind::Other.exit_code(),
            1,
            "generic failures must keep exit code 1 — bot-merge.sh and \
             other shell-level callers expect that contract"
        );
    }

    #[test]
    fn classify_billing_emits_structured_stderr_marker() {
        let m = ExecuteGapErrorKind::BillingExhausted
            .stderr_marker()
            .expect("billing-exhausted must emit a marker");
        // Stable column-1 token the orchestrator's stderr-tailer can grep:
        assert!(
            m.starts_with("BILLING_EXHAUSTED:"),
            "marker must start with the stable token at column 1; got: {m:?}"
        );
        // Human-readable rationale must mention the cascade direction:
        assert!(m.contains("TOGETHER"));
        assert!(m.contains("GROQ"));
        assert!(m.contains("Claude"));
        assert!(m.contains("INFRA-302"));
    }

    #[test]
    fn classify_other_emits_no_marker() {
        assert!(
            ExecuteGapErrorKind::Other.stderr_marker().is_none(),
            "generic failures must NOT spam stderr with a marker — the marker is \
             a dedicated cascade-respawn signal, not a log line"
        );
    }

    #[test]
    fn classify_negative_cases_route_to_other() {
        // These must NOT be classified as BillingExhausted or TransportUnreachable.
        for s in [
            "agent loop failed for gap INFRA-247: max iterations (50) reached without an answer",
            "agent loop failed for gap INFRA-247: HTTP 500 Internal Server Error",
            "agent loop failed for gap INFRA-247: tool storm: 5 consecutive failed batches",
            "agent loop failed for gap INFRA-247: HTTP 400 Bad Request: missing field 'tools'",
        ] {
            let e = anyhow::anyhow!("{s}");
            assert_eq!(
                classify_execute_gap_error(&e),
                ExecuteGapErrorKind::Other,
                "{s:?} must route to Other (not billing-exhausted or transport-unreachable)"
            );
        }
    }

    #[test]
    fn classify_billing_positive_cases() {
        for s in [
            "Local API error 402 Payment Required",
            "openai/quota error: insufficient_quota",
            "Provider error: billing required",
            "CREDIT_LIMIT exceeded",
            "Payment Required",
        ] {
            let e = anyhow::anyhow!("{s}");
            assert_eq!(
                classify_execute_gap_error(&e),
                ExecuteGapErrorKind::BillingExhausted,
                "{s:?} must classify as BillingExhausted"
            );
        }
    }

    #[test]
    fn classify_walks_full_anyhow_context_chain() {
        // The agent loop's `result?` bubbles the provider error;
        // execute_gap wraps with `with_context("agent loop failed for
        // gap {gap_id}")`. The classifier must see the WRAPPED chain,
        // not just the top-level message — otherwise it'd miss every
        // real-world dispatched-child failure (the top-level is always
        // the with_context message; the discriminator is one layer
        // deeper).
        let inner = anyhow::anyhow!(
            "Local API error 402 Payment Required: {{\"error\": {{\"type\": \"credit_limit\"}}}}"
        );
        let wrapped = inner.context("agent loop failed for gap INFRA-247");
        // Sanity check: the top-level message alone does NOT contain "402".
        assert!(
            !wrapped.to_string().contains("402"),
            "preconditions for the test changed — top-level no longer hides 402"
        );
        // The classifier must still detect billing-exhausted via the chain.
        assert_eq!(
            classify_execute_gap_error(&wrapped),
            ExecuteGapErrorKind::BillingExhausted,
            "classifier must walk the full anyhow context chain, not just the top message"
        );
    }

    // ──────────────────────────────────────────────────────────────────
    // INFRA-347 — TransportUnreachable classification at the
    // execute-gap exit boundary.
    // ──────────────────────────────────────────────────────────────────

    #[test]
    fn classify_transport_real_dogfood_incident_string() {
        // Verbatim error from the 2026-05-02 dogfood repro (INFRA-347 /
        // INFRA-348). The agent loop wraps the provider error with
        // `with_context("agent loop failed for gap {gap_id}")`, so
        // the formatted chain is:
        let raw = anyhow::anyhow!(
            "error sending request for url (http://127.0.0.1:11434/v1/chat/completions) \
             — model HTTP unreachable (daemon down, crashed, or still starting). \
             Ollama: brew services start ollama (or restart); probe: curl -s \
             http://127.0.0.1:11434/api/tags."
        );
        let wrapped = raw.context("agent loop failed for gap INFRA-234");
        assert_eq!(
            classify_execute_gap_error(&wrapped),
            ExecuteGapErrorKind::TransportUnreachable,
            "exact 2026-05-02 dogfood repro string (Ollama down, INFRA-347) MUST classify \
             as TransportUnreachable — this is the regression test for INFRA-347"
        );
    }

    #[test]
    fn classify_transport_exit_code_is_76_ex_protocol() {
        assert_eq!(
            ExecuteGapErrorKind::TransportUnreachable.exit_code(),
            76,
            "76 = EX_PROTOCOL per BSD sysexits.h; orchestrator pattern-matches on this \
             to distinguish transport-unreachable (daemon down) from billing-exhausted (75) \
             and generic failures (1). INFRA-347."
        );
    }

    #[test]
    fn classify_transport_emits_structured_stderr_marker() {
        let m = ExecuteGapErrorKind::TransportUnreachable
            .stderr_marker()
            .expect("transport-unreachable must emit a marker");
        assert!(
            m.starts_with("TRANSPORT_UNREACHABLE:"),
            "marker must start with the stable column-1 token; got: {m:?}"
        );
        assert!(
            m.contains("INFRA-347"),
            "marker must cite INFRA-347 for traceability; got: {m:?}"
        );
    }

    #[test]
    fn classify_transport_positive_cases() {
        for (s, label) in [
            (
                "agent loop failed for gap INFRA-234: connection refused (os error 61)",
                "connection refused",
            ),
            (
                "agent loop failed for gap INFRA-234: error sending request for url (http://127.0.0.1:11434/v1/chat/completions)",
                "error sending request",
            ),
            (
                "agent loop failed for gap INFRA-234: model HTTP unreachable",
                "model HTTP unreachable",
            ),
            (
                "agent loop failed for gap INFRA-234: operation timed out connecting to 127.0.0.1:11434",
                "operation timed out",
            ),
            (
                "agent loop failed for gap INFRA-234: no route to host",
                "no route to host",
            ),
            (
                "agent loop failed for gap INFRA-234: name resolution failed for localhost",
                "name resolution failed",
            ),
            (
                "agent loop failed for gap INFRA-234: tcp connect error (os error 61)",
                "tcp connect error",
            ),
            (
                "agent loop failed for gap INFRA-234: model temporarily unavailable",
                "model temporarily unavailable",
            ),
        ] {
            let e = anyhow::anyhow!("{s}");
            assert_eq!(
                classify_execute_gap_error(&e),
                ExecuteGapErrorKind::TransportUnreachable,
                "{label:?} ({s:?}) must classify as TransportUnreachable — \
                 INFRA-347: before this fix these exited 1 (Other), \
                 indistinguishable from a tool storm"
            );
        }
    }

    #[test]
    fn classify_transport_does_not_overlap_billing() {
        // Billing-exhausted takes priority over transport in the classifier.
        // A string that matches BOTH (pathological but possible if a provider
        // embeds "connection refused" in a 402 body) classifies as billing
        // because that's the more actionable signal.
        let s = "Local API error 402 Payment Required: connection refused";
        let e = anyhow::anyhow!("{s}");
        assert_eq!(
            classify_execute_gap_error(&e),
            ExecuteGapErrorKind::BillingExhausted,
            "billing-exhausted should take priority over transport-unreachable \
             when both patterns match"
        );
    }

    #[test]
    fn classify_transport_context_chain_visible() {
        // Same as classify_walks_full_anyhow_context_chain but for transport.
        // The "connection refused" discriminator is inside the provider error;
        // the top-level is the with_context wrapper.
        let inner = anyhow::anyhow!("connection refused (os error 61)");
        let wrapped = inner.context("agent loop failed for gap INFRA-234");
        assert!(
            !wrapped.to_string().contains("connection refused"),
            "precondition: top-level Display must hide the inner message"
        );
        assert_eq!(
            classify_execute_gap_error(&wrapped),
            ExecuteGapErrorKind::TransportUnreachable,
            "classifier must walk the full chain to find 'connection refused' \
             even when it is wrapped by with_context"
        );
    }

    // ──────────────────────────────────────────────────────────────────
    // CREDIBLE-011 — free-tier dispatch integration tests
    // Mock OpenAI-compat server verifies the tool loop end-to-end.
    // ──────────────────────────────────────────────────────────────────

    fn restore_env_var(key: &str, val: Option<String>) {
        match val {
            Some(v) => std::env::set_var(key, v),
            None => std::env::remove_var(key),
        }
    }

    #[test]
    #[serial(openai_model_env)]
    fn credible011_is_free_tier_model_true_for_groq_llama() {
        let prev_model = std::env::var("OPENAI_MODEL").ok();
        let prev_base = std::env::var("OPENAI_API_BASE").ok();
        std::env::set_var("OPENAI_MODEL", "llama-3.3-70b");
        std::env::set_var("OPENAI_API_BASE", "https://api.groq.com/openai/v1");
        let result = is_free_tier_model();
        restore_env_var("OPENAI_MODEL", prev_model);
        restore_env_var("OPENAI_API_BASE", prev_base);
        assert!(
            result,
            "Groq endpoint + non-Claude model must detect as free-tier"
        );
    }

    #[test]
    #[serial(openai_model_env)]
    fn credible011_is_free_tier_model_false_for_claude_on_groq() {
        let prev_model = std::env::var("OPENAI_MODEL").ok();
        let prev_base = std::env::var("OPENAI_API_BASE").ok();
        std::env::set_var("OPENAI_MODEL", "claude-sonnet-4-5-20250929");
        std::env::set_var("OPENAI_API_BASE", "https://api.groq.com/openai/v1");
        let result = is_free_tier_model();
        restore_env_var("OPENAI_MODEL", prev_model);
        restore_env_var("OPENAI_API_BASE", prev_base);
        assert!(
            !result,
            "Claude model must never be classified as free-tier"
        );
    }

    #[test]
    #[serial(openai_model_env)]
    fn credible011_is_free_tier_model_false_for_llama_on_ollama() {
        let prev_model = std::env::var("OPENAI_MODEL").ok();
        let prev_base = std::env::var("OPENAI_API_BASE").ok();
        std::env::set_var("OPENAI_MODEL", "llama-3.3-70b");
        std::env::set_var("OPENAI_API_BASE", "http://localhost:11434/v1");
        let result = is_free_tier_model();
        restore_env_var("OPENAI_MODEL", prev_model);
        restore_env_var("OPENAI_API_BASE", prev_base);
        assert!(!result, "Local Ollama is not a free-tier cloud endpoint");
    }

    /// Integration test: mock OpenAI-compat server → native tool_call for
    /// read_file → tool executes → model replies "done" → loop terminates.
    /// Verifies the complete provider → tool-dispatch → reply cycle without
    /// a real model or any cloud dependency.
    #[tokio::test]
    #[serial]
    async fn credible011_free_tier_tool_loop_read_file_then_done() {
        use serde_json::json;
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let dir =
            std::env::temp_dir().join(format!("credible011_{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        std::fs::write(
            dir.join("hello.txt"),
            "hello from free-tier integration test\n",
        )
        .expect("write test file");

        let mock = MockServer::start().await;

        // Turn 1: native tool_call asking for read_file.
        // Priority 1 = highest precedence in wiremock (lower number = matched first).
        // up_to_n_times(1) exhausts this mock after the first request.
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [{
                            "id": "call_001",
                            "type": "function",
                            "function": {
                                "name": "read_file",
                                "arguments": "{\"path\": \"hello.txt\"}"
                            }
                        }]
                    },
                    "finish_reason": "tool_calls"
                }],
                "model": "llama-3.3-70b",
                "usage": {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}
            })))
            .up_to_n_times(1)
            .with_priority(1)
            .mount(&mock)
            .await;

        // Turn 2 (after tool result): model terminates with "done".
        // Priority 2 = lower precedence, acts as fallback once turn-1 is exhausted.
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": "done",
                        "tool_calls": null
                    },
                    "finish_reason": "stop"
                }],
                "model": "llama-3.3-70b",
                "usage": {"prompt_tokens": 150, "completion_tokens": 5, "total_tokens": 155}
            })))
            .with_priority(2)
            .mount(&mock)
            .await;

        let prev_base = std::env::var("OPENAI_API_BASE").ok();
        let prev_model = std::env::var("OPENAI_MODEL").ok();
        let prev_repo = std::env::var("CHUMP_REPO").ok();
        let prev_home = std::env::var("CHUMP_HOME").ok();

        std::env::set_var("OPENAI_API_BASE", mock.uri());
        std::env::set_var("OPENAI_MODEL", "llama-3.3-70b");
        std::env::set_var("CHUMP_REPO", &dir);
        std::env::set_var("CHUMP_HOME", &dir);

        let agent = build_free_tier_agent().expect("build free-tier agent");
        let outcome = agent.run("Read hello.txt then reply done.").await;

        restore_env_var("OPENAI_API_BASE", prev_base);
        restore_env_var("OPENAI_MODEL", prev_model);
        restore_env_var("CHUMP_REPO", prev_repo);
        restore_env_var("CHUMP_HOME", prev_home);
        let _ = std::fs::remove_dir_all(&dir);

        let reply = outcome.expect("agent run must not error").reply;
        assert!(
            reply.contains("done"),
            "expected final reply to contain 'done'; got: {reply:?}"
        );

        // Verify the mock received the post-tool follow-up call: at least 2 requests.
        let received = mock.received_requests().await.unwrap_or_default();
        assert!(
            received.len() >= 2,
            "expected ≥2 model calls (initial + after read_file result); got {}",
            received.len()
        );
    }

    // ── EFFECTIVE-002: provider rotation ──────────────────────────────────

    #[test]
    #[serial(free_tier_env)]
    fn effective002_parse_defaults_returns_three_providers() {
        // Without CHUMP_FREE_TIER_PROVIDERS set the default list has 3 entries.
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        let specs = parse_free_tier_providers();
        assert_eq!(specs.len(), 3, "default rotation must have 3 providers");
        assert!(
            specs[0].base_url.contains("groq.com"),
            "first default must be Groq"
        );
        assert!(
            specs[1].base_url.contains("cerebras.ai"),
            "second default must be Cerebras"
        );
        assert!(
            specs[2].base_url.contains("nvidia.com"),
            "third default must be NVIDIA"
        );
    }

    #[test]
    #[serial(free_tier_env)]
    fn effective002_parse_custom_env_overrides_defaults() {
        std::env::set_var(
            "CHUMP_FREE_TIER_PROVIDERS",
            "my-model@https://api.example.com/v1:MY_KEY",
        );
        let specs = parse_free_tier_providers();
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        assert_eq!(specs.len(), 1);
        assert_eq!(specs[0].model, "my-model");
        assert_eq!(specs[0].base_url, "https://api.example.com/v1");
        assert_eq!(specs[0].api_key_env, "MY_KEY");
    }

    #[test]
    #[serial(free_tier_env)]
    fn effective002_parse_skips_malformed_entries() {
        std::env::set_var(
            "CHUMP_FREE_TIER_PROVIDERS",
            // Second entry is malformed (no '@'), third is good
            "good-model@https://api.example.com/v1:KEY,bad-entry,other@https://b.com/v1:K2",
        );
        let specs = parse_free_tier_providers();
        std::env::remove_var("CHUMP_FREE_TIER_PROVIDERS");
        assert_eq!(specs.len(), 2, "malformed entry must be silently skipped");
        assert_eq!(specs[0].model, "good-model");
        assert_eq!(specs[1].model, "other");
    }

    #[test]
    #[serial(openai_model_env)]
    fn effective002_activate_sets_env_vars() {
        let orig_base = std::env::var("OPENAI_API_BASE").ok();
        let orig_model = std::env::var("OPENAI_MODEL").ok();
        let orig_key = std::env::var("OPENAI_API_KEY").ok();

        std::env::set_var("MY_TEST_KEY_002", "sk-test-token");
        let spec = FreeTierProviderSpec {
            model: "llama-test".to_string(),
            base_url: "https://api.test.com/v1".to_string(),
            api_key_env: "MY_TEST_KEY_002".to_string(),
        };
        activate_free_tier_provider(&spec);

        assert_eq!(
            std::env::var("OPENAI_API_BASE").unwrap(),
            "https://api.test.com/v1"
        );
        assert_eq!(std::env::var("OPENAI_MODEL").unwrap(), "llama-test");
        assert_eq!(std::env::var("OPENAI_API_KEY").unwrap(), "sk-test-token");

        // Restore
        restore_env_var("OPENAI_API_BASE", orig_base);
        restore_env_var("OPENAI_MODEL", orig_model);
        restore_env_var("OPENAI_API_KEY", orig_key);
        std::env::remove_var("MY_TEST_KEY_002");
    }
}
