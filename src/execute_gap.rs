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

/// Build the dispatched-subagent prompt. Mirrors `chump_orchestrator::dispatch::build_prompt`
/// so reflection rows from both backends compare apples-to-apples on COG-026 A/B.
/// Reads `docs/CHUMP_DISPATCH_RULES.md` from `repo_root` and injects it inline so
/// the chump-local backend receives coordination rules regardless of whether it
/// reads files unprompted.
pub fn build_execute_gap_prompt(gap_id: &str, repo_root: &std::path::Path) -> String {
    let rules =
        std::fs::read_to_string(repo_root.join("docs/CHUMP_DISPATCH_RULES.md")).unwrap_or_default();
    let rules_block = if rules.is_empty() {
        String::new()
    } else {
        format!("{rules}\n\n---\n\n")
    };
    format!(
        "{rules}You are a Chump dispatched agent working on gap {gap}. \
The gap is already claimed in this worktree. \
Read the gap entry in docs/gaps.yaml for full acceptance criteria. \
Do the work, then ship via:\n  scripts/bot-merge.sh --gap {gap} --auto-merge\n\
After ship, exit. Reply ONLY with the PR number.",
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
}
