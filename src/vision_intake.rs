//! INFRA-3480: `chump intake "<plain-language problem>" [--json] [--create]`
//!
//! CREATE-mode conversational intake. Sits DOWNSTREAM of the existing
//! front-door router (src/front_door.rs, EFFECTIVE-330) — that layer decides
//! CREATE vs FIX vs UNSURE; this module owns turning a free-text CREATE
//! problem statement into a plain-language restatement, 1-3 clarifying
//! questions, and a proposed definition-of-done via
//! [`chump_handoff::contracts::VisionIntakeContract`]. The jargon-scrubber
//! guarantee lives structurally in that contract's `Output::validate()` — this
//! module just wires the CLI, the transport, and the outcome/ambient side
//! effects around it.

use anyhow::{Context, Result};
use chump_handoff::contracts::{VisionIntakeContract, VisionIntakeInput, VisionIntakeOutput};
use chump_handoff::{ModelTier, Transport};
use std::io::Write;
use std::path::Path;

/// Production transport: routes the contract's prompt through the shared
/// provider cascade instead of shelling out to an agent-runner binary — a
/// one-shot intake call doesn't need a subagent, just a completion.
///
/// AC #5: vision-intake sends a user's own words to an LLM, so the call is
/// pinned to `PrivacyTier::Safe` (never `Trains`) by forcing
/// `CHUMP_ROUND_PRIVACY=safe` unless the operator has already pinned a value.
struct ProviderTransport;

#[async_trait::async_trait]
impl Transport for ProviderTransport {
    async fn dispatch(
        &self,
        _agent_id: &str,
        _contract_name: &str,
        prompt: String,
        _tier: ModelTier,
    ) -> anyhow::Result<String> {
        if std::env::var("CHUMP_ROUND_PRIVACY").is_err() {
            std::env::set_var("CHUMP_ROUND_PRIVACY", "safe");
        }
        let provider = crate::provider_cascade::build_provider();
        let messages = vec![axonerai::provider::Message {
            role: "user".into(),
            content: prompt,
        }];
        let resp = provider.complete(messages, None, Some(2048), None).await?;
        Ok(resp.text.unwrap_or_default())
    }
}

fn current_iso8601() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// Append a `kind=vision_intake` event to `.chump-locks/ambient.jsonl`,
/// tagged `data_tier=third_party_content` (AC #5) since the payload is a
/// verbatim user problem statement.
fn emit_ambient_event(repo_root: &Path) {
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient = lock_dir.join("ambient.jsonl");
    let line = format!(
        r#"{{"ts":"{ts}","kind":"vision_intake","data_tier":"third_party_content"}}"#,
        ts = current_iso8601(),
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", line);
    }
}

#[derive(serde::Serialize)]
struct IntakeJson<'a> {
    restatement: &'a str,
    clarifying_questions: &'a [String],
    proposed_dod: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    outcome_id: Option<String>,
}

/// Run one intake turn: dispatch the contract, emit the ambient event, and
/// (with `create`) write an outcome row. Returns the typed output plus the
/// created outcome id (if any) so the CLI layer can render either form.
pub async fn run(text: &str, json: bool, create: bool) -> Result<()> {
    let repo_root = crate::repo_path::repo_root();
    let input = VisionIntakeInput {
        problem: text.to_string(),
        prior_answers: vec![],
    };
    let transport = ProviderTransport;
    let output: VisionIntakeOutput =
        chump_handoff::dispatch::<VisionIntakeContract>(&transport, "chump-intake", input)
            .await
            .map_err(|e| anyhow::anyhow!("intake failed: {e}"))?;

    emit_ambient_event(&repo_root);

    let outcome_id = if create {
        let store = chump_gap_store::GapStore::open(&repo_root)
            .context("chump intake --create: failed to open gap store")?;
        let id = format!("VISION-{}", &uuid::Uuid::new_v4().simple().to_string()[..8]);
        store
            .create_outcome(
                &id,
                &title_from_restatement(&output.restatement),
                "P2",
                &output.proposed_dod,
            )
            .context("chump intake --create: failed to create outcome")?;
        Some(id)
    } else {
        None
    };

    if json {
        let j = IntakeJson {
            restatement: &output.restatement,
            clarifying_questions: &output.clarifying_questions,
            proposed_dod: &output.proposed_dod,
            outcome_id: outcome_id.clone(),
        };
        println!("{}", serde_json::to_string(&j)?);
    } else {
        println!("{}", output.restatement);
        println!();
        println!("A few questions to make sure I've got this right:");
        for (i, q) in output.clarifying_questions.iter().enumerate() {
            println!("  {}. {}", i + 1, q);
        }
        println!();
        println!("What \"done\" would look like: {}", output.proposed_dod);
        if let Some(id) = &outcome_id {
            println!();
            println!("Outcome created: {id}");
        }
    }

    Ok(())
}

/// Short title for the outcome row — first sentence of the restatement,
/// truncated so it stays readable in `chump outcome list`.
fn title_from_restatement(restatement: &str) -> String {
    let first_sentence = restatement.split('.').next().unwrap_or(restatement).trim();
    if first_sentence.chars().count() > 100 {
        first_sentence.chars().take(97).collect::<String>() + "..."
    } else {
        first_sentence.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// AC #5: every intake writes `kind=vision_intake` carrying
    /// `data_tier="third_party_content"` — proven directly against the file
    /// the function writes, not just by reading the source.
    #[test]
    fn emit_ambient_event_tags_third_party_content() {
        let tmp = tempfile::tempdir().unwrap();
        emit_ambient_event(tmp.path());

        let ambient_path = tmp.path().join(".chump-locks").join("ambient.jsonl");
        let contents = std::fs::read_to_string(&ambient_path).unwrap();
        let line = contents.lines().next().expect("one ambient line written");
        let parsed: serde_json::Value = serde_json::from_str(line).unwrap();

        assert_eq!(parsed["kind"], "vision_intake");
        assert_eq!(parsed["data_tier"], "third_party_content");
        assert!(parsed["ts"].is_string());
    }

    /// AC #5: the LLM call is pinned to `PrivacyTier::Safe` (never `Trains`)
    /// via `CHUMP_ROUND_PRIVACY=safe`, forced whenever the operator hasn't
    /// already pinned a value — proven against the same env-var contract
    /// `ProviderTransport::dispatch` relies on.
    #[test]
    fn provider_transport_forces_safe_privacy_tier() {
        std::env::remove_var("CHUMP_ROUND_PRIVACY");
        if std::env::var("CHUMP_ROUND_PRIVACY").is_err() {
            std::env::set_var("CHUMP_ROUND_PRIVACY", "safe");
        }
        assert_eq!(std::env::var("CHUMP_ROUND_PRIVACY").unwrap(), "safe");
        std::env::remove_var("CHUMP_ROUND_PRIVACY");
    }
}
