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
//! * `1` — agent loop errored (provider unreachable, max iterations,
//!   cancellation, etc.).
//! * `2` — usage error (missing or malformed gap id).
//!
//! ## Why no per-tool approval gating
//!
//! [`crate::agent_loop::ChumpAgent`] only prompts for tool approval when
//! `CHUMP_TOOLS_ASK` is set. Dispatched runs leave it unset, so the loop
//! runs unattended end-to-end (mirrors `--dangerously-skip-permissions`
//! on the `claude` baseline — see dispatch.rs INFRA-DISPATCH-PERMISSIONS-FLAG
//! comment).

use anyhow::{anyhow, Context, Result};

use crate::agent_loop::ChumpAgent;
use crate::discord::build_chump_agent_cli;
use crate::model_overlay::maybe_overlay_from_env;

/// Build the dispatched-subagent prompt. Mirrors `chump_orchestrator::dispatch::build_prompt`
/// so reflection rows from both backends compare apples-to-apples on COG-026 A/B.
/// Reads `docs/CHUMP_DISPATCH_RULES.md` from `repo_root` and injects it inline so
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
    let rules =
        std::fs::read_to_string(repo_root.join("docs/CHUMP_DISPATCH_RULES.md")).unwrap_or_default();
    let rules_block = if rules.is_empty() {
        String::new()
    } else {
        format!("{rules}\n\n---\n\n")
    };
    let overlay_block = maybe_overlay_from_env().unwrap_or("");
    format!(
        "{overlay}{rules}You are a Chump dispatched agent working on gap {gap}. \
The gap is already claimed in this worktree. \
Read the gap entry in docs/gaps.yaml for full acceptance criteria. \
Do the work, then ship via:\n  scripts/bot-merge.sh --gap {gap} --auto-merge\n\
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

    let (agent, _ready_session) = build_chump_agent_cli()
        .context("building Chump agent for --execute-gap (provider config? OPENAI_API_BASE?)")?;
    let repo_root = std::env::current_dir().unwrap_or_default();
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_contains_gap_id_and_ship_command() {
        let p = build_execute_gap_prompt("COG-025", std::path::Path::new("/nonexistent"));
        assert!(p.contains("COG-025"));
        assert!(p.contains("scripts/bot-merge.sh --gap COG-025 --auto-merge"));
        assert!(p.contains("PR number"));
    }

    #[test]
    fn prompt_shape_with_rules_file() {
        // When rules file is present it is injected before the task instruction.
        // The orchestrator's COG-026 A/B measures model performance, not prompt
        // shape, so both backends may include the rules block.
        let dir = tempfile::tempdir().unwrap();
        let docs = dir.path().join("docs");
        std::fs::create_dir(&docs).unwrap();
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
    /// the model-shape overlay must be prepended. We avoid `#[serial]` here
    /// because there is no shared serial-test key for OPENAI_MODEL across
    /// crates; the test brackets its env mutation with set + restore so it's
    /// safe under cargo's parallel test runner *for the case where no other
    /// concurrent test in this binary mutates OPENAI_MODEL*. If a future
    /// test does, mark both `#[serial(openai_model_env)]`.
    #[test]
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
        assert!(p.contains("scripts/bot-merge.sh --gap COG-031 --auto-merge"));

        // Restore env so we don't leak to other tests.
        match prev {
            Some(v) => std::env::set_var("OPENAI_MODEL", v),
            None => std::env::remove_var("OPENAI_MODEL"),
        }
    }

    #[test]
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
}
