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

use anyhow::{anyhow, Context, Result};

use crate::agent_factory::build_chump_agent_cli;
use crate::agent_loop::ChumpAgent;
use crate::model_overlay::{detect_model_family, maybe_overlay_from_env, ModelFamily};
use crate::plan_mode::{self, PlanOutcome};

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

/// Build a simplified prompt for free-tier models. Key differences from
/// `build_execute_gap_prompt`:
///
/// 1. Inlines the gap YAML directly (no "read the file" indirection)
/// 2. Lists only the 5 available tools with clear descriptions
/// 3. Explicit step-by-step workflow: read → edit → commit → ship
/// 4. No defensive SCOPE-REFUSE clauses (Llama hallucinated refusals)
/// 5. No `run_cli`/`run_test` — CI tests after PR opens
fn build_free_tier_prompt(gap_id: &str, repo_root: &std::path::Path) -> String {
    // Try to read the gap YAML to inline it
    let gap_yaml = std::fs::read_to_string(repo_root.join(format!("docs/gaps/{gap_id}.yaml")))
        .unwrap_or_else(|_| format!("(gap YAML not found — work on gap {gap_id})"));

    let overlay = maybe_overlay_from_env().unwrap_or_default();

    format!(
        "{overlay}You are a code agent working in a Rust repository. \
Your ONLY job is to make code changes that satisfy the gap below, then commit.

## Gap
```yaml
{gap_yaml}
```

## Workflow (follow exactly)
1. read_file — read the file(s) that need changing (e.g. Cargo.toml, src/*.rs).
2. write_file — write the ENTIRE modified file back to the SAME path. \
   You must include ALL original content with only your targeted changes applied. \
   Do NOT create new files unless the gap specifically requires it.
3. patch_file — alternative to write_file for small changes (preferred for large files).
4. git_commit — commit with message \"{gap_id}: <short summary of what changed>\". \
   This automatically stages modified files.
5. Respond with the single word: done

## Rules
- NEVER write documentation, plans, or markdown files. ONLY modify source/config files.
- NEVER explain what you will do. Every response = one tool call.
- NEVER create files like chump-plan.md, docs/<ID>.md, or similar.
- write_file REPLACES the file at the given path. Include the full file content.
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

/// Minimal gap-id syntactic check — must match `[A-Z][A-Z0-9]+-\d+`-ish
/// (DOMAIN-NUMBER). Fails the run early if the caller passed garbage so we
/// don't waste a provider call building a prompt for a non-gap.
fn validate_gap_id(gap_id: &str) -> Result<()> {
    if gap_id.is_empty() {
        return Err(anyhow!("gap id is empty"));
    }
    let Some((prefix, num)) = gap_id.split_once('-') else {
        return Err(anyhow!("gap id missing '-': {gap_id}"));
    };
    if prefix.is_empty()
        || !prefix
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
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

    let agent = if free_tier {
        build_free_tier_agent().context("building free-tier agent for --execute-gap (INFRA-733)")?
    } else {
        let (a, _ready_session) = build_chump_agent_cli().context(
            "building Chump agent for --execute-gap (provider config? OPENAI_API_BASE?)",
        )?;
        a
    };

    let prompt = if free_tier {
        build_free_tier_prompt(gap_id, &repo_root)
    } else {
        build_execute_gap_prompt(gap_id, &repo_root)
    };

    let outcome = agent
        .run(&prompt)
        .await
        .with_context(|| format!("agent loop failed for gap {gap_id}"))?;

    Ok(outcome.reply)
}

/// Same as [`execute_gap`] but lets tests inject a pre-built [`ChumpAgent`]
/// (avoiding a real provider). Production caller uses [`execute_gap`].
pub async fn execute_gap_with_agent(agent: &ChumpAgent, gap_id: &str) -> Result<String> {
    validate_gap_id(gap_id)?;
    let repo_root = std::env::current_dir().unwrap_or_default();
    let prompt = build_execute_gap_prompt(gap_id, &repo_root);
    let outcome = agent.run(&prompt).await?;
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
}
