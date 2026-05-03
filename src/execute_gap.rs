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
use crate::model_overlay::maybe_overlay_from_env;
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
    format!(
        "{overlay}{rules}You are a Chump dispatched agent working on gap {gap}. \
The gap is already claimed in this worktree. \
Read the gap entry in docs/gaps.yaml for full acceptance criteria. \
Do the work, then ship via:\n  scripts/coord/bot-merge.sh --gap {gap} --auto-merge\n\
After ship, exit. Reply ONLY with the PR number.",
        overlay = overlay_block,
        rules = rules_block,
        gap = gap_id
    )
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

    // INFRA-060 (M2): plan-mode gate. Enumerate likely files, scan open
    // PRs, write `.chump-plans/<gap>.md`. Abort *before* spinning up the
    // provider+agent if the queue is too crowded — saves provider cost.
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

    let (agent, _ready_session) = build_chump_agent_cli()
        .context("building Chump agent for --execute-gap (provider config? OPENAI_API_BASE?)")?;
    let prompt = build_execute_gap_prompt(gap_id, &repo_root);

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

/// INFRA-302 blocker (1): classification of errors returned by
/// [`execute_gap`].
///
/// Today only two variants — billing-exhausted vs everything-else —
/// because that's the discriminator the orchestrator-level
/// cascade-respawn (filed separately) needs. Keep narrow until the
/// orchestrator side actually reads more variants; a wider taxonomy
/// without consumers is dead carrying capacity.
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
    /// Anything else — generic agent-loop failure (network blip,
    /// max-iterations cap, tool storm, model crash, etc.). Maps to
    /// the legacy exit code 1 so existing operator tooling that
    /// `if [ $? -ne 0 ]` keeps working unchanged.
    Other,
}

impl ExecuteGapErrorKind {
    /// Per-class exit code for `chump --execute-gap`'s main-process
    /// exit. `75` follows BSD `EX_TEMPFAIL` from `sysexits.h` — chosen
    /// because it's outside the 0–2 range existing tooling uses for
    /// usage / generic-failure, distinct enough that the orchestrator
    /// can pattern-match on it, and semantically correct (the failure
    /// IS temporary at the dispatched-child level — different provider
    /// or topped-up credits would succeed). Stays `1` for the generic
    /// case so `bot-merge.sh` and other shell-level callers see no
    /// behavioral change.
    pub fn exit_code(self) -> i32 {
        match self {
            Self::BillingExhausted => 75,
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
            Self::Other => None,
        }
    }
}

/// INFRA-302 blocker (1): inspect an [`anyhow::Error`] from
/// [`execute_gap`] and classify it for exit-code mapping.
///
/// Walks the formatted error chain (using `format!("{err:#}")` so the
/// full Context-wrapped chain is visible) and matches against
/// [`crate::provider_cascade::is_billing_exhausted_error_string`].
/// Returns [`ExecuteGapErrorKind::BillingExhausted`] on match,
/// [`ExecuteGapErrorKind::Other`] otherwise.
///
/// Centralizing this on the formatted chain (not the typed `&Error`)
/// matches the existing INFRA-300 cascade predicate's contract —
/// HTTP-error-bearing strings carry the discriminator (`402`,
/// `credit_limit`, ...) regardless of which transport layer wrapped
/// them, so a string-based check is correct AND robust to the
/// provider library swapping its concrete error type.
pub fn classify_execute_gap_error(err: &anyhow::Error) -> ExecuteGapErrorKind {
    let chain_str = format!("{err:#}");
    if crate::provider_cascade::is_billing_exhausted_error_string(&chain_str) {
        ExecuteGapErrorKind::BillingExhausted
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
        for s in [
            "agent loop failed for gap INFRA-247: max iterations (50) reached without an answer",
            "agent loop failed for gap INFRA-247: HTTP 500 Internal Server Error",
            "agent loop failed for gap INFRA-247: Connection refused (os error 61)",
            "agent loop failed for gap INFRA-247: tool storm: 5 consecutive failed batches",
            "agent loop failed for gap INFRA-247: HTTP 400 Bad Request: missing field 'tools'",
        ] {
            let e = anyhow::anyhow!("{s}");
            assert_eq!(
                classify_execute_gap_error(&e),
                ExecuteGapErrorKind::Other,
                "{s:?} must route to Other (not billing-exhausted)"
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
}
