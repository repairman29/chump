//! INFRA-1720: typed contracts for parent → subagent handoffs.
//!
//! ## Why this exists
//!
//! Subagent handoffs today are markdown text:
//!
//! ```text
//! parent: writes prompt (free-form) → spawns Sonnet/Haiku → parses free-form text reply.
//! ```
//!
//! Failure modes that bite us repeatedly:
//!
//! * subagent returns the right *idea* but the wrong *shape* (missing field, extra
//!   field, wrong nesting),
//! * subagent hallucinates a file path that doesn't exist,
//! * subagent's text includes the JSON we want but wraps it in extra commentary,
//! * parent assumes a key is present and panics downstream.
//!
//! Caught by CI when the bad code fails compile/lint — but that's a *whole CI
//! round-trip* (~5 min) past the agent boundary. Each round-trip is wasted
//! tokens, wasted operator attention, and a stale lease.
//!
//! ## What this crate does
//!
//! Defines a [`HandoffContract`] trait. The implementor supplies an `Input`
//! (Serialize) and an `Output` (DeserializeOwned + [`Validate`]). Spawning a
//! subagent goes through [`dispatch`], which:
//!
//! 1. Renders the contract's prompt template, injecting the `Input` JSON.
//! 2. Spawns the subagent via the harness's `Agent` tool (or a stub in tests).
//! 3. Extracts the first JSON code block from stdout.
//! 4. Deserializes into `Output` — schema mismatch → [`HandoffError::SchemaMismatch`].
//! 5. Calls `Output::validate()` — semantic violation → [`HandoffError::ValidationFailed`].
//! 6. On any error, emits `kind=handoff_contract_violation` to ambient + returns
//!    `Result<_, HandoffError>` — never `Result<_, String>`.
//!
//! ## Migration path (see README.md for the long version)
//!
//! * Existing markdown-prompt subagent spawns in `src/agent_factory.rs` keep
//!   working unchanged.
//! * New code call sites adopt `HandoffContract` types.
//! * Once 50% of subagent calls have been migrated, the markdown-prompt path is
//!   marked `#[deprecated]`. At 90% it is removed in a major version bump.
//!
//! ## Pairs with
//!
//! * INFRA-1719 — typed inputs from AST crawler (this is the *output* side of
//!   the same shape conversation).
//! * INFRA-1714 — pr-rescue daemon (its handlers are good candidates for
//!   contract-typed handoff to a Sonnet retry-agent).

#![deny(missing_docs)]

use async_trait::async_trait;
use serde::{de::DeserializeOwned, Serialize};
use std::path::PathBuf;
use thiserror::Error;

pub mod contracts;
pub mod external_repo_schema;
pub mod transport;
pub mod validate;

pub use validate::{Validate, ValidationError};

/// Model tier hint for the dispatched subagent.
///
/// Surfaced to the transport so the underlying spawn (Claude Code Agent tool,
/// opencode, etc.) can pick the right backend. Defaults to [`ModelTier::Sonnet`]
/// which is appropriate for ~80% of typed-handoff work; reserve [`ModelTier::Opus`]
/// for synthesis where Sonnet routinely hallucinates shape, and
/// [`ModelTier::Haiku`] for fully-deterministic conversions (e.g. format-only
/// transforms with no judgement).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelTier {
    /// Cheapest tier — good for mechanical transforms with no judgement.
    Haiku,
    /// Default — broad capability without Opus burn rate.
    #[default]
    Sonnet,
    /// Reserved for cases Sonnet has been shown to fail on.
    Opus,
}

/// A typed contract for spawning a subagent and validating its return.
///
/// Implementors describe the I/O shape; the [`dispatch`] function handles the
/// spawn + parse + validate pipeline so individual call sites don't reinvent
/// it (and don't drift in error-handling discipline).
///
/// ### Implementing
///
/// ```rust,ignore
/// use chump_handoff::{HandoffContract, ModelTier, Validate, ValidationError};
/// use serde::{Deserialize, Serialize};
///
/// #[derive(Serialize)]
/// pub struct MyInput { pub gap_id: String }
///
/// #[derive(Deserialize, Debug)]
/// pub struct MyOutput { pub verdict: String, pub reasoning: String }
///
/// impl Validate for MyOutput {
///     fn validate(&self) -> Result<(), ValidationError> {
///         if self.verdict.is_empty() {
///             return Err(ValidationError::new("verdict cannot be empty"));
///         }
///         Ok(())
///     }
/// }
///
/// pub struct MyContract;
/// impl HandoffContract for MyContract {
///     type Input = MyInput;
///     type Output = MyOutput;
///     fn name() -> &'static str { "MyContract" }
///     fn prompt(input: &Self::Input) -> String {
///         format!("Review gap {} and emit a JSON block: {{\"verdict\":\"...\",\"reasoning\":\"...\"}}", input.gap_id)
///     }
/// }
/// ```
pub trait HandoffContract {
    /// Typed input shape sent to the subagent (serialised + injected into prompt).
    type Input: Serialize + Send + Sync;
    /// Typed output shape expected back; validation runs after deserialisation.
    type Output: DeserializeOwned + Validate + Send + Sync;

    /// Stable identifier used in ambient events. Convention: `PascalCase`,
    /// matches the impl struct name. Surfaces in
    /// `handoff_contract_violation` so observability can route by contract.
    fn name() -> &'static str;

    /// Render the prompt that goes to the subagent. Implementations MUST
    /// instruct the subagent to emit a single fenced JSON block matching
    /// `Output`'s schema; the prompt template is the contract author's chance
    /// to be explicit about that shape.
    fn prompt(input: &Self::Input) -> String;

    /// Model tier hint. Default: Sonnet.
    fn model_tier() -> ModelTier {
        ModelTier::default()
    }
}

/// Failure modes from [`dispatch`]. Never a stringly-typed error.
#[derive(Debug, Error)]
pub enum HandoffError {
    /// Subagent output failed JSON deserialisation against `Output`'s schema.
    /// The most common cause: subagent hallucinated a field or wrapped JSON
    /// in extra commentary the extractor couldn't peel.
    #[error("handoff schema mismatch ({contract}): {error}")]
    SchemaMismatch {
        /// Which contract failed (matches `HandoffContract::name`).
        contract: &'static str,
        /// Serde error text.
        error: String,
        /// First 100 chars of raw subagent output (for telemetry without leaking PII).
        raw_output_first_100: String,
    },

    /// Output deserialised cleanly but `Output::validate()` rejected it
    /// (e.g. business rule violated, referenced file path doesn't exist).
    #[error("handoff validation failed ({contract}): {error}")]
    ValidationFailed {
        /// Which contract failed.
        contract: &'static str,
        /// `ValidationError` message.
        error: String,
    },

    /// Transport-level failure (subagent spawn errored, no output captured,
    /// JSON extractor found no fenced block, etc.).
    #[error("handoff dispatch error ({contract}): {source}")]
    DispatchError {
        /// Which contract failed.
        contract: &'static str,
        /// Underlying error.
        #[source]
        source: anyhow::Error,
    },
}

/// Trait abstracting the subagent-spawn transport. The default
/// [`transport::AgentToolTransport`] shells out to the Claude Code Agent tool
/// via `chump-agent-cli`; tests use a stubbed transport so contract logic can
/// be exercised without a live LLM call.
#[async_trait]
pub trait Transport: Send + Sync {
    /// Spawn a subagent with the rendered prompt and return its raw stdout.
    ///
    /// `agent_id` is opaque routing metadata (e.g. a session ID); the
    /// transport may emit it to ambient for traceability.
    async fn dispatch(
        &self,
        agent_id: &str,
        contract_name: &str,
        prompt: String,
        tier: ModelTier,
    ) -> anyhow::Result<String>;
}

/// Spawn a subagent under `C`'s contract, parse + validate its output, and
/// return the typed result.
///
/// On any error path emits `kind=handoff_contract_violation` to ambient with
/// `{contract_name, error, raw_output_first_100}` so dashboards can flag the
/// contract for prompt refinement.
///
/// The transport is provided by the caller so production and test paths share
/// the same dispatch pipeline.
pub async fn dispatch<C: HandoffContract>(
    transport: &dyn Transport,
    agent_id: &str,
    input: C::Input,
) -> Result<C::Output, HandoffError> {
    let contract_name = C::name();
    let prompt = C::prompt(&input);
    let tier = C::model_tier();

    let raw = transport
        .dispatch(agent_id, contract_name, prompt, tier)
        .await
        .map_err(|e| {
            emit_violation(contract_name, &format!("dispatch error: {e}"), "");
            HandoffError::DispatchError {
                contract: contract_name,
                source: e,
            }
        })?;

    let json_str = extract_json_block(&raw).ok_or_else(|| {
        let raw_prefix = first_n_chars(&raw, 100);
        emit_violation(
            contract_name,
            "no JSON block in subagent output",
            &raw_prefix,
        );
        HandoffError::SchemaMismatch {
            contract: contract_name,
            error: "no JSON block in subagent output".to_string(),
            raw_output_first_100: raw_prefix,
        }
    })?;

    let parsed: C::Output = serde_json::from_str(&json_str).map_err(|e| {
        let raw_prefix = first_n_chars(&raw, 100);
        emit_violation(contract_name, &format!("deserialize: {e}"), &raw_prefix);
        HandoffError::SchemaMismatch {
            contract: contract_name,
            error: e.to_string(),
            raw_output_first_100: raw_prefix,
        }
    })?;

    if let Err(ve) = parsed.validate() {
        emit_violation(
            contract_name,
            &format!("validate: {ve}"),
            &first_n_chars(&raw, 100),
        );
        return Err(HandoffError::ValidationFailed {
            contract: contract_name,
            error: ve.to_string(),
        });
    }

    Ok(parsed)
}

/// Extract the first fenced JSON code block from a subagent reply.
///
/// Matches the common shapes:
///
/// 1. ```` ```json\n{...}\n``` ```` — preferred (explicit language tag)
/// 2. ```` ```\n{...}\n``` ```` — fallback (untagged)
/// 3. raw JSON on its own (no fences) — last-resort
///
/// Returns the inner JSON text without the fences. Used by [`dispatch`] but
/// exposed publicly so callers writing custom transports can reuse the same
/// extraction discipline.
pub fn extract_json_block(s: &str) -> Option<String> {
    // Preferred: ```json fences.
    if let Some(start) = s.find("```json") {
        let after = &s[start + "```json".len()..];
        if let Some(end) = after.find("```") {
            return Some(after[..end].trim().to_string());
        }
    }
    // Fallback: bare ``` fences (only if the inside looks JSON-ish).
    if let Some(start) = s.find("```") {
        let after = &s[start + 3..];
        if let Some(end) = after.find("```") {
            let candidate = after[..end].trim();
            if candidate.starts_with('{') || candidate.starts_with('[') {
                return Some(candidate.to_string());
            }
        }
    }
    // Last resort: trim + check if the whole string is JSON.
    let trimmed = s.trim();
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        return Some(trimmed.to_string());
    }
    None
}

fn first_n_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

fn emit_violation(contract: &str, error: &str, raw_first_100: &str) {
    let path = ambient_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let event = serde_json::json!({
        "ts": now,
        "kind": "handoff_contract_violation",
        "contract_name": contract,
        "error": error,
        "raw_output_first_100": raw_first_100,
    });
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write;
        let _ = writeln!(f, "{event}");
    }
}

fn ambient_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_AMBIENT_LOG") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let root = std::env::var("CHUMP_REPO_ROOT").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(root).join(".chump-locks/ambient.jsonl")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_json_from_fenced_json_block() {
        let s = "Some prelude.\n```json\n{\"k\":1}\n```\nTrailing chatter.";
        let got = extract_json_block(s).unwrap();
        assert_eq!(got, "{\"k\":1}");
    }

    #[test]
    fn extracts_json_from_bare_fenced_block() {
        let s = "```\n{\"k\":2}\n```";
        assert_eq!(extract_json_block(s).unwrap(), "{\"k\":2}");
    }

    #[test]
    fn extracts_raw_json_when_no_fences() {
        let s = "  {\"a\":3}  ";
        assert_eq!(extract_json_block(s).unwrap(), "{\"a\":3}");
    }

    #[test]
    fn rejects_non_json_text() {
        assert!(extract_json_block("here is some plain prose").is_none());
        assert!(extract_json_block("```\nnot json content\n```").is_none());
    }
}
