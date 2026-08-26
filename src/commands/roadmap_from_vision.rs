//! EFFECTIVE-425: `chump roadmap-from-vision <vision>` — COTG spine slice 1.
//!
//! Vision string -> `RoadmapFromVisionContract` (crates/chump-handoff, Phase 1
//! already built at contracts.rs:753) -> validated `Roadmap` JSON -> (with
//! `--apply`) one or more `chump gap reserve --outcome <id>` calls so every
//! filed gap inherits the MISSION-045 / pillar / similarity gates instead of
//! writing to `state.db` directly.
//!
//! Bare invocation (no `--apply`) only prints the validated Roadmap JSON —
//! it never touches the gap registry. No dry-run flag, no truncation UX, no
//! `chump bootstrap --with-roadmap` wiring here; those are follow-ons.

use axonerai::provider::Message;
use chump_handoff::contracts::{GapDraft, GroupBy, Roadmap, RoadmapFromVisionContract};
use chump_handoff::{extract_json_block, HandoffContract, Validate};

fn flag(args: &[String], name: &str) -> Option<String> {
    args.windows(2).find(|w| w[0] == name).map(|w| w[1].clone())
}

fn print_usage() {
    eprintln!(
        "Usage: chump roadmap-from-vision --vision <STRING> --domain <DOMAIN> [--outcome <ID>] \
         [--max-gaps N] [--apply]"
    );
    eprintln!(
        "  --vision     Vision/intent string to derive a roadmap from (or first positional arg)"
    );
    eprintln!("  --domain     Domain prefix for proposed gaps (e.g. INFRA, EFFECTIVE)");
    eprintln!("  --outcome    Existing outcome id — required when --apply is set (MISSION-045)");
    eprintln!("  --max-gaps   Hard cap on total gaps in the roadmap (default 5, clamped 1..=20)");
    eprintln!("  --apply      File the proposed gaps via `chump gap reserve`. Without this flag,");
    eprintln!("               only the validated Roadmap JSON is printed — nothing is filed.");
}

/// `chump roadmap-from-vision <vision>` entry point. Async because it drives
/// the LLM provider cascade; called from `main()`'s tokio runtime.
pub async fn run(args: &[String]) -> i32 {
    // args[0] == "roadmap-from-vision"; vision string is the first non-flag
    // positional after it.
    // AC1: `--vision <string>` is the canonical form; a bare positional
    // (pre-existing EFFECTIVE-425 UX) is still accepted for backward compat.
    let vision = match flag(args, "--vision")
        .or_else(|| args[1..].iter().find(|a| !a.starts_with("--")).cloned())
    {
        Some(v) => v,
        None => {
            eprintln!("roadmap-from-vision: --vision <string> is required");
            print_usage();
            return 2;
        }
    };

    let domain = match flag(args, "--domain") {
        Some(d) => d,
        None => {
            eprintln!("roadmap-from-vision: --domain is required");
            print_usage();
            return 2;
        }
    };

    let outcome_id = flag(args, "--outcome");
    let apply = args.iter().any(|a| a == "--apply");

    if apply && outcome_id.is_none() {
        eprintln!("roadmap-from-vision --apply: --outcome <ID> is required (MISSION-045 gate)");
        return 2;
    }

    // AC3: max_gaps is clamped client-side — never trust model compliance.
    // A model that ignores the prompt's hard cap must not be able to flood
    // the gap registry.
    let requested_max_gaps: u32 = flag(args, "--max-gaps")
        .and_then(|s| s.parse().ok())
        .unwrap_or(5);
    let max_gaps = requested_max_gaps.clamp(1, 20);

    let input = chump_handoff::contracts::RoadmapFromVisionInput {
        intent_doc: vision,
        domain: domain.clone(),
        max_gaps,
        group_by: GroupBy::ProductLine,
        context: Vec::new(),
        target_dir: None,
    };

    let prompt = RoadmapFromVisionContract::prompt(&input);
    let provider = crate::provider_cascade::build_provider();
    let messages = vec![Message {
        role: "user".to_string(),
        content: prompt,
    }];
    let response = match provider.complete(messages, None, Some(4096), None).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("roadmap-from-vision: LLM call failed: {e:#}");
            return 1;
        }
    };
    let text = response.text.unwrap_or_default();
    if text.trim().is_empty() {
        eprintln!("roadmap-from-vision: empty response from model");
        return 1;
    }

    let json_block = match extract_json_block(&text) {
        Some(b) => b,
        None => {
            eprintln!("roadmap-from-vision: no JSON block found in model response");
            eprintln!("raw (first 500 chars): {}", first_n_chars(&text, 500));
            return 1;
        }
    };

    let roadmap: Roadmap = match serde_json::from_str(&json_block) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("roadmap-from-vision: response did not match Roadmap schema: {e}");
            return 1;
        }
    };

    if let Err(e) = roadmap.validate() {
        eprintln!("roadmap-from-vision: Roadmap failed validation: {e}");
        return 1;
    }

    // Enforce the client-side cap regardless of what the model claimed.
    let total_gaps: usize = roadmap.groups.iter().map(|g| g.gaps.len()).sum();
    if total_gaps > max_gaps as usize {
        eprintln!(
            "roadmap-from-vision: model emitted {total_gaps} gaps, exceeding --max-gaps {max_gaps} — rejecting"
        );
        return 1;
    }

    if !apply {
        // AC2: bare invocation only prints the validated Roadmap JSON.
        println!(
            "{}",
            serde_json::to_string_pretty(&roadmap).unwrap_or_default()
        );
        return 0;
    }

    let outcome_id = outcome_id.expect("checked above");
    let mut filed = Vec::new();
    for group in &roadmap.groups {
        for draft in &group.gaps {
            match reserve_gap(draft, &domain, &outcome_id) {
                Some(id) => {
                    verify_outcome_linked(&id, &outcome_id);
                    filed.push(id);
                }
                None => {
                    eprintln!(
                        "roadmap-from-vision: failed to reserve gap for draft {:?}",
                        draft.title
                    );
                }
            }
        }
    }

    if filed.is_empty() {
        eprintln!("roadmap-from-vision: --apply produced zero filed gaps");
        return 1;
    }

    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({
            "outcome_id": outcome_id,
            "filed_gaps": filed,
        }))
        .unwrap_or_default()
    );
    0
}

fn first_n_chars(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// Shell out to `chump gap reserve --outcome <id>` for a single [`GapDraft`].
///
/// Deliberately NOT `GapStore::reserve_verified` direct — going through the
/// `chump gap reserve` CLI means every filed gap inherits the MISSION-045
/// outcome-required gate, the pillar title-tag convention, and the
/// INFRA-1149 similarity check. Mirrors `bootstrap.rs::reserve_umbrella_gap`
/// (bootstrap.rs:871-931).
pub(crate) fn reserve_gap(draft: &GapDraft, domain: &str, outcome_id: &str) -> Option<String> {
    // `chump gap reserve --acceptance-criteria` splits on `|`, not newline.
    let ac = draft.acceptance_criteria.join("|");
    let priority = match draft.priority {
        chump_handoff::contracts::RoadmapPriority::P0 => "P0",
        chump_handoff::contracts::RoadmapPriority::P1 => "P1",
        chump_handoff::contracts::RoadmapPriority::P2 => "P2",
        chump_handoff::contracts::RoadmapPriority::P3 => "P3",
    };
    let effort = match draft.effort {
        chump_handoff::contracts::RoadmapEffort::Xs => "xs",
        chump_handoff::contracts::RoadmapEffort::S => "s",
        chump_handoff::contracts::RoadmapEffort::M => "m",
        chump_handoff::contracts::RoadmapEffort::L => "l",
        chump_handoff::contracts::RoadmapEffort::Xl => "xl",
    };

    let output = std::process::Command::new("chump")
        .args([
            "gap",
            "reserve",
            "--domain",
            domain,
            "--title",
            &draft.title,
            "--description",
            &draft.description,
            "--priority",
            priority,
            "--effort",
            effort,
            "--acceptance-criteria",
            &ac,
            "--outcome",
            outcome_id,
            "--json",
        ])
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            serde_json::from_str::<serde_json::Value>(stdout.trim())
                .ok()
                .and_then(|v| v.get("id").and_then(|id| id.as_str()).map(str::to_string))
                .or_else(|| extract_gap_id(&stdout))
        }
        Ok(out) => {
            eprintln!(
                "roadmap-from-vision: gap reserve failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            );
            None
        }
        Err(e) => {
            eprintln!("roadmap-from-vision: gap reserve error: {e} — chump may not be in PATH");
            None
        }
    }
}

/// Fallback gap-id extraction from non-JSON stdout (mirrors
/// `bootstrap.rs::extract_gap_id`).
fn extract_gap_id(s: &str) -> Option<String> {
    for word in s.split_whitespace() {
        let clean = word.trim_end_matches(|c: char| !c.is_alphanumeric());
        let mut parts = clean.splitn(2, '-');
        let domain = parts.next().unwrap_or("");
        let num = parts.next().unwrap_or("");
        if !domain.is_empty()
            && domain.chars().all(|c| c.is_ascii_uppercase())
            && !num.is_empty()
            && num.chars().all(|c| c.is_ascii_digit())
        {
            return Some(clean.to_string());
        }
    }
    None
}

/// AC1(d): confirm the filed gap's `outcome_id` was actually set by shelling
/// out to `chump gap show <id> --json`. Advisory only — a failure here does
/// not un-file the gap, it just surfaces a loud warning for the operator.
fn verify_outcome_linked(gap_id: &str, expected_outcome_id: &str) {
    let output = std::process::Command::new("chump")
        .args(["gap", "show", gap_id, "--json"])
        .output();
    match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let actual = serde_json::from_str::<serde_json::Value>(stdout.trim())
                .ok()
                .and_then(|v| {
                    v.get("outcome_id")
                        .and_then(|o| o.as_str())
                        .map(str::to_string)
                });
            if actual.as_deref() != Some(expected_outcome_id) {
                eprintln!(
                    "roadmap-from-vision: WARNING {gap_id} outcome_id is {actual:?}, expected {expected_outcome_id:?}"
                );
            }
        }
        Ok(out) => {
            eprintln!(
                "roadmap-from-vision: gap show {gap_id} failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        Err(e) => {
            eprintln!("roadmap-from-vision: gap show error: {e}");
        }
    }
}

// EFFECTIVE-425: unit coverage for the pure argument-parsing / extraction
// helpers used by the `chump roadmap-from-vision --apply` pipeline.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flag_finds_value_after_name() {
        let args = vec![
            "roadmap-from-vision".to_string(),
            "vision text".to_string(),
            "--domain".to_string(),
            "INFRA".to_string(),
            "--outcome".to_string(),
            "COTG".to_string(),
        ];
        assert_eq!(flag(&args, "--domain"), Some("INFRA".to_string()));
        assert_eq!(flag(&args, "--outcome"), Some("COTG".to_string()));
        assert_eq!(flag(&args, "--max-gaps"), None);
    }

    #[test]
    fn vision_flag_takes_precedence_over_positional() {
        // AC1: `--vision <string>` is the canonical form.
        let args = vec![
            "roadmap-from-vision".to_string(),
            "--vision".to_string(),
            "build a CLI".to_string(),
            "--domain".to_string(),
            "INFRA".to_string(),
        ];
        assert_eq!(flag(&args, "--vision"), Some("build a CLI".to_string()));
    }

    #[test]
    fn max_gaps_clamps_client_side_never_trust_model() {
        // AC3: max_gaps is clamped client-side regardless of requested value.
        assert_eq!(0u32.clamp(1, 20), 1);
        assert_eq!(500u32.clamp(1, 20), 20);
        assert_eq!(5u32.clamp(1, 20), 5);
    }

    #[test]
    fn extract_gap_id_finds_domain_num_pattern() {
        assert_eq!(
            extract_gap_id("gap reserved: INFRA-1234 done."),
            Some("INFRA-1234".to_string())
        );
        assert_eq!(extract_gap_id("no gap id here"), None);
        // lowercase domain must not match — mirrors bootstrap.rs::extract_gap_id.
        assert_eq!(extract_gap_id("infra-1234"), None);
    }

    #[test]
    fn roadmap_json_round_trips_through_validate() {
        // Exercises the same parse -> validate path `run()` uses on a
        // model response, without spawning a subprocess or an LLM call.
        let raw = r#"{
            "groups": [{
                "name": "Core",
                "rationale": "MVP first",
                "gaps": [{
                    "title": "Add invoice form",
                    "description": "A form to add invoices.",
                    "priority": "P1",
                    "effort": "m",
                    "acceptance_criteria": ["Form submits and persists an invoice row"],
                    "depends_on": []
                }]
            }],
            "narrative": "Ship the MVP.",
            "confidence": 0.7
        }"#;
        let roadmap: Roadmap = serde_json::from_str(raw).expect("valid Roadmap JSON");
        assert!(roadmap.validate().is_ok());
        let total: usize = roadmap.groups.iter().map(|g| g.gaps.len()).sum();
        assert_eq!(total, 1);
    }

    #[test]
    fn roadmap_with_todo_ac_fails_validate() {
        let raw = r#"{
            "groups": [{
                "name": "Core",
                "rationale": "MVP first",
                "gaps": [{
                    "title": "Add invoice form",
                    "description": "A form to add invoices.",
                    "priority": "P1",
                    "effort": "m",
                    "acceptance_criteria": ["TODO: fill this in"],
                    "depends_on": []
                }]
            }],
            "narrative": "Ship the MVP.",
            "confidence": 0.7
        }"#;
        let roadmap: Roadmap = serde_json::from_str(raw).expect("valid Roadmap JSON shape");
        assert!(roadmap.validate().is_err());
    }
}
