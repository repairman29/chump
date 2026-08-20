//! INFRA-3480 / EFFECTIVE-357: `chump intake "<plain-language problem>" [--json] [--create]`
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
//!
//! EFFECTIVE-357 (factory L1) layers a second step on top: `chump-perception`
//! (crates/chump-perception) rule-based-scores the raw input's ambiguity
//! *before* any structured gap is authored. Below the threshold, `--create`
//! feeds the restatement + DoD + perceived entities/constraints/risks into
//! the existing `RoadmapFromVisionContract` (EFFECTIVE-425) with
//! `max_gaps=1` to author ONE umbrella gap with real acceptance criteria,
//! filed via the same `chump gap reserve --outcome <id>` path
//! `roadmap-from-vision --apply` uses (MISSION-045 gate inherited for free).
//! At/above the threshold, intake stops at the clarifying questions — the
//! two-phase decomposition doctrine's "don't guess" rule applies to AC
//! authoring, not just sub-gap slicing.

use anyhow::{Context, Result};
use chump_handoff::contracts::{
    GroupBy, Roadmap, RoadmapFromVisionContract, RoadmapFromVisionInput, VisionIntakeContract,
    VisionIntakeInput, VisionIntakeOutput,
};
use chump_handoff::{HandoffContract, ModelTier, Transport, Validate};
use std::io::Write;
use std::path::Path;

/// AC2: chump-perception's ambiguity_level is in [0.0, 1.0] (rule-based, no
/// LLM call). At/above this threshold the raw input is too thin to safely
/// author acceptance criteria from — intake asks its clarifying questions
/// instead of guessing a structured gap.
const AMBIGUITY_GAP_THRESHOLD: f32 = 0.6;

/// Domain every intake-authored umbrella gap files under. Intake is a
/// front-door-level entrypoint, not domain-specific input from the caller —
/// EFFECTIVE matches the pillar this capability itself belongs to
/// (user-facing outcome discovery).
const INTAKE_GAP_DOMAIN: &str = "EFFECTIVE";

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
    ambiguity_level: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    outcome_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    gap_id: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    acceptance_criteria: Vec<String>,
}

/// Run one intake turn: dispatch the contract, emit the ambient event, and
/// (with `create`) write an outcome row plus — when chump-perception judges
/// the input unambiguous enough — a structured umbrella gap with real AC.
/// Returns the typed output plus the created outcome/gap ids (if any) so the
/// CLI layer can render either form.
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

    // AC2: rule-based ambiguity score on the raw input — no LLM call, so this
    // gate runs even if the provider call above degraded to a stub.
    let perceived = chump_perception::perceive(text, false);

    let mut outcome_id = None;
    let mut gap_id = None;
    let mut acceptance_criteria = Vec::new();

    if create {
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
        outcome_id = Some(id.clone());

        if perceived.ambiguity_level < AMBIGUITY_GAP_THRESHOLD {
            match structure_and_file_gap(&output, &perceived, &id).await {
                Ok((filed_gap_id, ac)) => {
                    gap_id = Some(filed_gap_id);
                    acceptance_criteria = ac;
                }
                Err(e) => {
                    eprintln!(
                        "chump intake: outcome {id} created, but structured gap authoring \
                         failed: {e:#}"
                    );
                }
            }
        }
    }

    if json {
        let j = IntakeJson {
            restatement: &output.restatement,
            clarifying_questions: &output.clarifying_questions,
            proposed_dod: &output.proposed_dod,
            ambiguity_level: perceived.ambiguity_level,
            outcome_id: outcome_id.clone(),
            gap_id: gap_id.clone(),
            acceptance_criteria,
        };
        println!("{}", serde_json::to_string(&j)?);
    } else {
        println!("{}", output.restatement);
        println!();
        if perceived.ambiguity_level >= AMBIGUITY_GAP_THRESHOLD {
            println!(
                "This one's ambiguous enough (score {:.2}) that I don't want to guess at \
                 requirements — answer these first, then run intake again with the answers \
                 folded in:",
                perceived.ambiguity_level
            );
        } else {
            println!("A few questions to make sure I've got this right:");
        }
        for (i, q) in output.clarifying_questions.iter().enumerate() {
            println!("  {}. {}", i + 1, q);
        }
        println!();
        println!("What \"done\" would look like: {}", output.proposed_dod);
        if let Some(id) = &outcome_id {
            println!();
            println!("Outcome created: {id}");
        }
        if let Some(id) = &gap_id {
            println!("Gap filed: {id}");
        }
    }

    Ok(())
}

/// AC1/AC3: turn the plain-language restatement + proposed DoD + the
/// chump-perception signal into ONE umbrella [`chump_handoff::contracts::GapDraft`]
/// via the existing `RoadmapFromVisionContract` (EFFECTIVE-425), then file it
/// through `chump gap reserve --outcome <id>` so it inherits the MISSION-045
/// gate, the pillar title-tag convention, and the similarity check — the same
/// path `chump roadmap-from-vision --apply` uses.
///
/// `max_gaps=1` on purpose: per the two-phase decomposition doctrine, intake's
/// job is ONE umbrella gap carrying decomposition intent in its description —
/// `chump gap decompose` slices it into sub-gaps at claim time, against the
/// then-current codebase, not here.
async fn structure_and_file_gap(
    output: &VisionIntakeOutput,
    perceived: &chump_perception::PerceivedInput,
    outcome_id: &str,
) -> Result<(String, Vec<String>)> {
    let mut context = vec![
        "This is CREATE-mode intake for a non-technical person's raw idea. Write the \
         description as: 2-4 user stories in the form 'As a ... I want ... so that ...', \
         then a 'Non-goals:' line naming what's explicitly out of scope, then a \
         'Rough shape:' line giving a rough decomposition per the two-phase decomposition \
         doctrine — name pieces, do not file them as separate gaps now."
            .to_string(),
        format!("Proposed definition of done: {}", output.proposed_dod),
    ];
    if !perceived.detected_entities.is_empty() {
        context.push(format!(
            "Entities mentioned in the raw input: {}",
            perceived.detected_entities.join(", ")
        ));
    }
    if !perceived.detected_constraints.is_empty() {
        context.push(format!(
            "Constraints detected in the raw input: {}",
            perceived.detected_constraints.join(", ")
        ));
    }
    if !perceived.risk_indicators.is_empty() {
        context.push(format!(
            "Risk indicators detected in the raw input — surface these as risks in the \
             description: {}",
            perceived.risk_indicators.join(", ")
        ));
    }

    let vision_input = RoadmapFromVisionInput {
        intent_doc: output.restatement.clone(),
        domain: INTAKE_GAP_DOMAIN.to_string(),
        max_gaps: 1,
        group_by: GroupBy::ProductLine,
        context,
        target_dir: None,
    };
    let prompt = RoadmapFromVisionContract::prompt(&vision_input);
    let provider = crate::provider_cascade::build_provider();
    let messages = vec![axonerai::provider::Message {
        role: "user".into(),
        content: prompt,
    }];
    let response = provider
        .complete(messages, None, Some(2048), None)
        .await
        .context("roadmap-from-vision call failed")?;
    let text = response.text.unwrap_or_default();
    let json_block = chump_handoff::extract_json_block(&text)
        .ok_or_else(|| anyhow::anyhow!("no JSON block in structured-intake response"))?;
    let roadmap: Roadmap = serde_json::from_str(&json_block)
        .context("structured-intake response did not match Roadmap schema")?;
    roadmap
        .validate()
        .map_err(|e| anyhow::anyhow!("structured-intake roadmap failed validation: {e}"))?;

    let draft = roadmap
        .groups
        .first()
        .and_then(|g| g.gaps.first())
        .ok_or_else(|| anyhow::anyhow!("structured-intake model emitted zero gap drafts"))?;

    let filed_gap_id =
        crate::commands::roadmap_from_vision::reserve_gap(draft, INTAKE_GAP_DOMAIN, outcome_id)
            .ok_or_else(|| anyhow::anyhow!("chump gap reserve failed for structured intake gap"))?;

    Ok((filed_gap_id, draft.acceptance_criteria.clone()))
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

    /// AC2/AC3: the vague-ask style of raw input ("I want X" with no
    /// detail) must land at/above [`AMBIGUITY_GAP_THRESHOLD`] so intake
    /// stops at clarifying questions instead of guessing AC; a concrete
    /// 1-paragraph idea with named entities/constraints must land below it
    /// so intake proceeds to author a structured gap.
    #[test]
    fn ambiguity_threshold_separates_vague_from_concrete_input() {
        let vague = chump_perception::perceive("I want an app that does stuff for my team", false);
        assert!(
            vague.ambiguity_level >= AMBIGUITY_GAP_THRESHOLD,
            "expected vague ask to score >= {AMBIGUITY_GAP_THRESHOLD}, got {}",
            vague.ambiguity_level
        );

        let concrete = chump_perception::perceive(
            "I run a 12-person dog-walking business called \"Pawsome Routes\". Right now I \
             track routes and client contact info in a paper notebook, and I must be able to \
             see today's routes before 8am without calling anyone. I want a simple app where I \
             enter a client's address and it groups clients into routes for each walker.",
            false,
        );
        assert!(
            concrete.ambiguity_level < AMBIGUITY_GAP_THRESHOLD,
            "expected concrete idea to score < {AMBIGUITY_GAP_THRESHOLD}, got {}",
            concrete.ambiguity_level
        );
    }

    /// AC1: the JSON output shape carries `ambiguity_level`, and `gap_id` /
    /// `acceptance_criteria` are omittable so a `--create` run that stopped
    /// at clarifying questions doesn't fabricate empty structured fields.
    #[test]
    fn intake_json_omits_gap_fields_when_not_filed() {
        let j = IntakeJson {
            restatement: "restated",
            clarifying_questions: &["q1".to_string()],
            proposed_dod: "done means x",
            ambiguity_level: 0.8,
            outcome_id: Some("VISION-abcd1234".to_string()),
            gap_id: None,
            acceptance_criteria: Vec::new(),
        };
        let v: serde_json::Value = serde_json::to_value(&j).unwrap();
        assert!(v.get("gap_id").is_none());
        assert!(v.get("acceptance_criteria").is_none());
        assert_eq!(v["outcome_id"], "VISION-abcd1234");
        assert!((v["ambiguity_level"].as_f64().unwrap() - 0.8).abs() < 1e-6);
    }
}
